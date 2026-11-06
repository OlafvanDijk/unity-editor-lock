# Shared Unity Editor lock.
# Modes: pre (PreToolUse hook), stop (Stop hook: 1 minute grace), release (SessionEnd hook),
#        force [sessionId] (manual takeover, hands the lock to sessionId), status, wait,
#        priority <high|normal> <sessionId> (records the playtest priority of a session).
param([string]$Mode = 'status', [string]$ForceSession = '', [string]$Extra = '')

$lockDir = Join-Path $env:USERPROFILE '.claude\locks'
$lockFile = Join-Path $lockDir 'unity-editor.lock'
$holdMinutes = 5
$graceSeconds = 60
$corruptSeconds = 5
$hardCapMinutes = 30
$priorityMinutes = 30
$escalateMinutes = 10
$mutexWaitMs = 10000
$scriptPath = $PSCommandPath -replace '\\', '/'
New-Item -ItemType Directory -Force $lockDir | Out-Null

$clock = [System.Diagnostics.Stopwatch]::StartNew()
$raw = ''
if ($Mode -ne 'status' -and $Mode -ne 'force' -and $Mode -ne 'wait' -and $Mode -ne 'priority') { $raw = [Console]::In.ReadToEnd() }
$data = $null
if ($raw) { try { $data = $raw | ConvertFrom-Json } catch {} }
$sessionId = if ($data -and $data.session_id) { [string]$data.session_id } else { 'unknown' }

# Named mutex open to everyone, so a session running at another privilege level can still use it.
# If it cannot be created or opened at all, run without mutual exclusion rather than failing every Unity call.
$mutex = $null
try {
	$mutexSecurity = New-Object System.Security.AccessControl.MutexSecurity
	$everyone = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::WorldSid, $null)
	$mutexSecurity.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule($everyone, 'FullControl', 'Allow')))
	$mutexCreated = $false
	$mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeUnityEditorLock', [ref]$mutexCreated, $mutexSecurity)
} catch {
	try { $mutex = [System.Threading.Mutex]::OpenExisting('Global\ClaudeUnityEditorLock') } catch { $mutex = $null }
}
if ($null -eq $mutex -and $Mode -ne 'status') { [Console]::Error.WriteLine('unity-lock: named mutex unavailable (another Claude process may run elevated); continuing without mutual exclusion.') }
function Enter-Mutex {
	if ($null -eq $mutex) { return $true }
	try { return $mutex.WaitOne($mutexWaitMs) } catch [System.Threading.AbandonedMutexException] { return $true }
}
function Exit-Mutex {
	if ($null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
}

# Returns $null (no lock), a lock object, or a lock object with corrupt=$true (unparsable/incomplete file).
function Read-Lock {
	if (-not (Test-Path $lockFile)) { return $null }
	try { $mtime = (Get-Item $lockFile).LastWriteTime } catch { return $null }
	try {
		# Open with delete-sharing so a concurrent File.Replace by another session cannot fail on us.
		$stream = [System.IO.File]::Open($lockFile, 'Open', 'Read', [System.IO.FileShare]'ReadWrite,Delete')
		try { $text = (New-Object System.IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
		$lock = $text | ConvertFrom-Json
		if (-not $lock.session) { throw 'no session' }
		$null = [datetime]::Parse($lock.time)
		$null = [datetime]::Parse($lock.expires)
		return $lock
	} catch {
		return [pscustomobject]@{ corrupt = $true; session = 'unknown'; cwd = ''; purpose = 'corrupt lock file'; time = $mtime.ToString('o'); expires = $mtime.ToString('o'); ageSeconds = ((Get-Date) - $mtime).TotalSeconds }
	}
}

# Write via temp file + swap so the lock file is never half-written. Call inside the mutex.
function Write-Lock($session, $cwd, $purpose, $expires, $time = $null, $priority = 'normal') {
	if (-not $time) { $time = (Get-Date).ToString('o') }
	$json = @{ session = $session; cwd = $cwd; purpose = $purpose; time = $time; expires = $expires.ToString('o'); priority = $priority } | ConvertTo-Json
	$tmp = "$lockFile.$PID.tmp"
	Set-Content -Path $tmp -Value $json -Encoding utf8
	for ($attempt = 1; $attempt -le 5; $attempt++) {
		try {
			if (Test-Path $lockFile) { [System.IO.File]::Replace($tmp, $lockFile, [NullString]::Value) } else { [System.IO.File]::Move($tmp, $lockFile) }
			return
		} catch {
			if ($attempt -eq 5) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; throw }
			Start-Sleep -Milliseconds 50
		}
	}
}

# Per-session playtest priority answer (high|normal), valid 30 minutes sliding. $null = not answered / expired = ask again.
function Get-PriorityFile($id) { return Join-Path $lockDir ('priority-' + ($id -replace '[^\w-]', '_') + '.json') }
function Read-Priority($id) {
	try {
		$rec = Get-Content (Get-PriorityFile $id) -Raw -ErrorAction Stop | ConvertFrom-Json
		if (((Get-Date) - [datetime]::Parse($rec.time)).TotalMinutes -gt $priorityMinutes) { return $null }
		return $rec
	} catch { return $null }
}
function Save-Priority($id, $value, $waitSince = $null) {
	$rec = @{ value = $value; time = (Get-Date).ToString('o') }
	if ($waitSince) { $rec.waitSince = $waitSince }
	Set-Content -Path (Get-PriorityFile $id) -Value ($rec | ConvertTo-Json) -Encoding utf8
}
function Get-LockPriority($lock) { if ($lock -and $lock.priority -eq 'high') { return 'high' } else { return 'normal' } }

# True unless the Editor clearly reports: edit mode, not compiling/reloading, no test running. Unreachable counts as busy.
function Test-EditorBusy {
	try {
		$out = & unity command editor_status --json --timeout 10 2>$null | Out-String
		$editor = ($out | ConvertFrom-Json).data.result
		if ($editor.playMode -ne 'stopped' -or $editor.compiling -or $editor.domainReloadInProgress) { return $true }
		$out = & unity command test_status --json --timeout 10 2>$null | Out-String
		return ((($out | ConvertFrom-Json).data.result.status) -ne 'no_tests')
	} catch { return $true }
}

function Stop-EditorActivity {
	& unity command cancel_tests --timeout 10 2>$null | Out-Null
	& unity command editor_stop --timeout 10 2>$null | Out-Null
}

function Get-LockTiming($lock) {
	$now = Get-Date
	$expires = [datetime]::Parse($lock.expires)
	return @{ expired = ($expires -lt $now); pastCap = ($expires.AddMinutes($hardCapMinutes) -lt $now) }
}

# Can this session take the lock that is currently held? $busy is the Editor-busy result.
function Test-CanTake($lock, $busy) {
	if ($null -eq $lock) { return $true }
	if ($lock.corrupt) { return ($lock.ageSeconds -gt $corruptSeconds) }
	if ($lock.session -eq $sessionId) { return $true }
	$timing = Get-LockTiming $lock
	if ($timing.pastCap) { return $true }
	return ($timing.expired -and -not $busy)
}

# Looks up the app session that owns a hook session id, so the user gets a clickable link to the blocker.
# Uses the app's own session files (cliSessionId); falls back to the bare id if that layout ever changes.
function Get-HolderLabel($cliId, $holderCwd = '') {
	try {
		$pattern = Join-Path $env:LOCALAPPDATA 'Claude-Data\*\claude-code-sessions\*\*\local_*.json'
		$needle = '"cliSessionId":"' + $cliId + '"'
		$hit = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-String -SimpleMatch $needle -List | Select-Object -First 1
		if ($hit) {
			$appId = [System.IO.Path]::GetFileNameWithoutExtension($hit.Path)
			$titleHit = Select-String -Path $hit.Path -Pattern '"title":"([^"]*)"' -List | Select-Object -First 1
			$title = if ($titleHit) { $titleHit.Matches[0].Groups[1].Value } else { $appId }
			return "[$title](#$appId)"
		}
	} catch {}
	# Terminal (CLI) sessions have no app link: describe the session from its transcript instead.
	try {
		$transcript = Get-ChildItem -Path (Join-Path $env:USERPROFILE ".claude\projects\*\$cliId.jsonl") -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($transcript) {
			$name = $null
			$titleHit = Select-String -Path $transcript.FullName -Pattern '"customTitle":"((?:[^"\\]|\\.)*)"' | Select-Object -Last 1
			if ($titleHit) { $name = $titleHit.Matches[0].Groups[1].Value }
			if (-not $name) {
				$promptHit = Select-String -Path $transcript.FullName -Pattern '"type":"user".*?"content":"((?:[^"\\]|\\.){1,80})' | Select-Object -First 1
				if ($promptHit) { $name = $promptHit.Matches[0].Groups[1].Value }
			}
			if (-not $name) { $name = 'untitled' }
			$name = ($name -replace '\\[nrt]', ' ') -replace '\\"', '"'
			$folder = if ($holderCwd) { $holderCwd } else { 'unknown folder' }
			return "session `"$name`" (id $($cliId.Substring(0, [Math]::Min(8, $cliId.Length))), folder $folder, last active $($transcript.LastWriteTime.ToString('HH:mm'))); in a terminal, look for the Claude window in that folder, or open it with: claude --resume $cliId"
		}
	} catch {}
	return "session $cliId (no session description found)"
}

switch ($Mode) {
	'status' {
		$lock = Read-Lock
		if ($lock) { "Unity Editor lock held by $(Get-HolderLabel $lock.session $lock.cwd) since $($lock.time) (priority $(Get-LockPriority $lock)), expires $($lock.expires) ($($lock.purpose)) in $($lock.cwd). To take over: powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" force <your session id>" } else { 'Unity Editor is free.' }
	}
	'wait' {
		# Polls (up to ~100s per call) until the lock is free or takeable; does not take it. Exit 0 = free, 3 = still held.
		$deadline = (Get-Date).AddSeconds(100)
		while ($true) {
			$lock = Read-Lock
			$busy = $true
			if ($lock -and -not $lock.corrupt) {
				$timing = Get-LockTiming $lock
				if ($timing.expired -and -not $timing.pastCap) { $busy = Test-EditorBusy }
			}
			if (Test-CanTake $lock $busy) { 'Unity Editor is free now. Retry your command.'; exit 0 }
			if ((Get-Date) -gt $deadline) { "Still held by $(Get-HolderLabel $lock.session $lock.cwd) until about $($lock.expires). Run wait again, and tell the user in one line that you are still waiting."; exit 3 }
			Start-Sleep -Seconds 5
		}
	}
	'force' {
		Stop-EditorActivity
		$got = Enter-Mutex
		try {
			$lock = Read-Lock
			if (Test-Path $lockFile) { Remove-Item $lockFile -Force }
			if ($ForceSession) { $fp = Read-Priority $ForceSession; Write-Lock $ForceSession '' 'took over via force' (Get-Date).AddMinutes($holdMinutes) $null $(if ($fp) { [string]$fp.value } else { 'normal' }) }
		} finally { if ($got) { Exit-Mutex } }
		$who = if ($lock) { "session $($lock.session)" } else { 'nobody' }
		"Cancelled running tests, stopped play mode and cleared the lock held by $who." + $(if ($ForceSession) { " The lock now belongs to session $ForceSession." } else { ' No session id was given, so the lock is free.' })
	}
	'priority' {
		if (($ForceSession -ne 'high' -and $ForceSession -ne 'normal') -or -not $Extra) { 'Usage: priority <high|normal> <sessionId>'; exit 1 }
		Save-Priority $Extra $ForceSession
		"Priority of session $Extra set to $ForceSession. Retry your Unity command."
	}
	'release' {
		Remove-Item (Get-PriorityFile $sessionId) -Force -ErrorAction SilentlyContinue
		$got = Enter-Mutex
		if ($got) {
			try {
				$lock = Read-Lock
				if ($lock -and -not $lock.corrupt -and $lock.session -eq $sessionId) { Remove-Item $lockFile -Force }
			} catch {} finally { Exit-Mutex }
		}
	}
	'stop' {
		$got = Enter-Mutex
		if ($got) {
			try {
				$lock = Read-Lock
				if ($lock -and -not $lock.corrupt -and $lock.session -eq $sessionId) {
					$graceEnd = (Get-Date).AddSeconds($graceSeconds)
					if ([datetime]::Parse($lock.expires) -gt $graceEnd) { Write-Lock $sessionId $lock.cwd $lock.purpose $graceEnd ([string]$lock.time) (Get-LockPriority $lock) }
				}
			} catch {} finally { Exit-Mutex }
		}
	}
	'pre' {
		$toolName = if ($data -and $data.tool_name) { [string]$data.tool_name } else { 'Bash' }
		$command = if ($data -and $data.tool_input) { [string]$data.tool_input.command } else { '' }
		$isShell = $toolName -eq 'Bash' -or $toolName -eq 'PowerShell' -or $toolName -eq 'Monitor'
		$isComputerUse = $toolName -match '^mcp__(computer-use|remote-devices__computer)'
		# Every 'unity command|cmd [options] <name>' counts, read-only ones too (bare listing/--help does not), and so do the
		# subcommands that drive the live Editor (recompile, test, close, shell, job, watch, open, run, build).
		# Case-sensitive on purpose (prose like "Fix Unity command handling" must not lock); Unity.exe is accepted.
		$sep = '(?:[ \t]|\\\r?\n|`\r?\n)+'
		$opts = '(?:-\S+(?:' + $sep + '(?:"[^"]*"|''[^'']*''|[^-\s;&|"'']\S*))?' + $sep + ')*'
		# Not a lock: discovery calls ('command --query play', '--tag x') and scene files ('Level.unity').
		$notQuery = '(?<!(?:--query|--tags?|-q)[ \t]+)'
		$unityPattern = '(?<![\w.-])(?:unity|[Uu]nity\.exe)["'']?' + $sep + '(?:(?:[^\s;&|]+' + $sep + '){0,8}?(?:command|cmd)' + $sep + $opts + $notQuery + '["'']?[A-Za-z_]|' + $opts + '["'']?(?:recompile|test|close|shell|job|watch|open|run|build)(?=["'']?(?:\s|$|[;&|)}><,])))'
		$isUnity = $isShell -and ($command -cmatch $unityPattern)
		if (-not ($isComputerUse -or $isUnity)) { exit 0 }
		$cwd = if ($data) { [string]$data.cwd } else { '' }
		$purpose = if ($isComputerUse) { "computer use ($toolName)" } else { ($command -replace '\s+', ' ') }
		if ($purpose.Length -gt 80) { $purpose = $purpose.Substring(0, 80) }

		$message = $null
		$capTakeover = $false
		$myPrio = Read-Priority $sessionId
		$prioCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" priority"
		if ($null -eq $myPrio -and $sessionId -ne 'unknown') {
			[Console]::Error.WriteLine("UNITY EDITOR LOCK: a new playtest starts, so the user may set its priority first (a high priority session may force a normal one, otherwise it waits silently).`n" +
				"DO THIS NOW: ask the user with the AskUserQuestion tool so they get BUTTONS (if deferred, load it with ToolSearch query select:AskUserQuestion): one question, multiSelect false, three options: 'Normal' (waits for other sessions), 'High' (may force a normal session off the Editor) and 'You decide' (you rate it yourself). If AskUserQuestion is unavailable (e.g. you are a background subagent), use normal.`n" +
				"Then run: $prioCmd <high|normal> $sessionId . For Normal use normal, for High use high. For 'You decide' use high only if the user is actively waiting on this result right now or this is a quest checkpoint, otherwise normal. Then retry your command.")
			exit 2
		}
		$myLevel = if ($myPrio) { [string]$myPrio.value } else { 'normal' }
		$waitSinceOld = if ($myPrio -and $myPrio.waitSince) { [string]$myPrio.waitSince } else { $null }
		if ($myPrio) { Save-Priority $sessionId $myLevel $waitSinceOld }
		try {
			# First read under a brief mutex hold; the slow Editor check runs outside the mutex and only when it can matter.
			$first = $null
			$gotFirst = Enter-Mutex
			try { if ($gotFirst) { $first = Read-Lock } } finally { if ($gotFirst) { Exit-Mutex } }
			$busy = $true
			if ($first -and -not $first.corrupt -and $first.session -ne $sessionId) {
				$timing = Get-LockTiming $first
				# Past 30s of the hook budget, skip the slow check and stay safe by treating the Editor as busy.
				if ($timing.expired -and -not $timing.pastCap -and $clock.Elapsed.TotalSeconds -lt 30) { $busy = Test-EditorBusy }
			}

			$got = Enter-Mutex
			if (-not $got) { $message = 'Unity Editor lock is being updated by another session. Wait and retry in a few seconds.' }
			try {
				if ($got) {
					$lock = Read-Lock
					$changed = (($null -eq $lock) -ne ($null -eq $first)) -or ($lock -and $first -and ($lock.time -ne $first.time -or $lock.session -ne $first.session))
					if ($changed -and $lock -and -not $lock.corrupt -and $lock.session -ne $sessionId) {
						$message = "Unity Editor lock just changed hands (now held by session $($lock.session)). Wait and retry in a minute."
					} elseif (Test-CanTake $lock $busy) {
						if ($lock -and -not $lock.corrupt -and $lock.session -ne $sessionId -and (Get-LockTiming $lock).pastCap) { $capTakeover = $true }
						Write-Lock $sessionId $cwd $purpose (Get-Date).AddMinutes($holdMinutes) $null $myLevel
						if ($waitSinceOld) { Save-Priority $sessionId $myLevel }
					} else {
						$holder = Get-HolderLabel $lock.session $lock.cwd
						$tellUser = if ($holder -match '^\[') { "pasting this link exactly as written: $holder" } else { "describing it exactly like this so they can find that session: $holder" }
						$holderLevel = Get-LockPriority $lock
						$levels = "(holder priority $holderLevel, yours $myLevel)"
						$waitCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" wait"
						if (-not ($myLevel -eq 'high' -and $holderLevel -eq 'normal')) {
							$since = if ($waitSinceOld) { $waitSinceOld } else { (Get-Date).ToString('o') }
							if (-not $waitSinceOld) { Save-Priority $sessionId $myLevel $since }
							$waited = ((Get-Date) - [datetime]::Parse($since)).TotalMinutes
							if ($waited -gt $escalateMinutes) {
								$message = "UNITY EDITOR LOCK: you have waited over $escalateMinutes minutes for $holder $levels. Tell the user in your next message, $tellUser , then ask with the AskUserQuestion tool (BUTTONS, not plain text; load it with ToolSearch query select:AskUserQuestion if deferred): options 'Keep waiting' and 'Give up for now'. Keep waiting: run $prioCmd $myLevel $sessionId (resets the timer), then $waitCmd (repeat while it exits 3), then retry. Give up: stop trying the Editor and say so. Do NOT force."
							} else {
								$message = "UNITY EDITOR LOCK: the Editor is in use by $holder $levels (running '$($lock.purpose)'). Your priority is not higher, so DO NOT ask the user and do NOT force. But keep the user informed in chat: (1) say now, in one short line, that you are waiting for the Unity Editor and who holds it, $tellUser . (2) Run $waitCmd (repeat while it exits 3, and after each round say in one short line that you are still waiting). (3) When it exits 0, say in one line that the Editor is free and retry your command."
							}
						} else {
						$message = "UNITY EDITOR LOCK: your playtest/Unity command is blocked by $holder $levels (running '$($lock.purpose)' since $($lock.time)). The lock frees by itself once that session's lock has lapsed and the Editor is idle.`n" +
							"DO THIS NOW: (1) tell the user in your next message that you are blocked and by which session, $tellUser . (2) Ask the user with the AskUserQuestion tool so they get BUTTONS, never as plain text (if the tool is deferred, load it first with ToolSearch query select:AskUserQuestion): one question, multiSelect false, two options: label 'Wait' (description: wait until that session's lock ends, then continue) and label 'Force takeover' (description: cancels that session's running test and stops play mode, then takes the Editor). Do NOT force without the user's answer.`n" +
							"If the user chooses Wait: run powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" wait (repeat while it exits 3), then retry your command.`n" +
							"If the user chooses Force: run powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" force $sessionId , then retry your command."
						}
					}
				}
			} finally { if ($got) { Exit-Mutex } }
			# A lock that lapsed long ago may have left a test or play mode running: clean up for the new owner.
			if ($capTakeover -and $clock.Elapsed.TotalSeconds -lt 60) { Stop-EditorActivity }
		} catch {
			$message = "Unity lock hook error: $($_.Exception.Message). Wait a few seconds and retry."
		}
		if ($message) { [Console]::Error.WriteLine($message); exit 2 }
	}
}
exit 0
