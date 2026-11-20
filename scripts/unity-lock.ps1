# Unity Editor lock, one per Unity project: sessions on different projects never block each other.
# Modes: pre (PreToolUse hook), stop (Stop hook: 1 minute grace), release [sessionId] (SessionEnd hook, or by hand), status,
#        wait [project], force [project] [sessionId] (manual takeover, hands the lock to sessionId),
#        priority <high|normal> <sessionId> (records the playtest priority of a session).
# [project] is a Unity project folder; omitted = the project around the current folder.
# A session outside any Unity project never takes or waits on a lock.
param([string]$Mode = 'status', [string]$Arg1 = '', [string]$Arg2 = '')

$lockDir = Join-Path $env:USERPROFILE '.claude\locks'
$holdMinutes = 5
$graceSeconds = 60
$corruptSeconds = 5
$hardCapMinutes = 30
$priorityMinutes = 30
$escalateMinutes = 10
$mutexWaitMs = 10000
$scriptPath = $PSCommandPath -replace '\\', '/'
$runCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
# Shell token separator: blanks or a line continuation (bash \ or PowerShell `).
$sep = '(?:[ \t]|\\\r?\n|`\r?\n)+'
New-Item -ItemType Directory -Force $lockDir | Out-Null

$clock = [System.Diagnostics.Stopwatch]::StartNew()
$raw = ''
# Hooks pipe JSON on stdin; a manual call has none, so never wait on the console.
# A manual call from a tool shell can hold an open, never-closing stdin pipe: read it with a time limit.
$readStdin = ($Mode -eq 'pre' -or $Mode -eq 'stop' -or ($Mode -eq 'release' -and -not $Arg1)) -and [Console]::IsInputRedirected
if ($readStdin) {
	# Raw stream: Console.In's own ReadToEndAsync is synchronous in .NET Framework and would ignore the time limit.
	$task = (New-Object System.IO.StreamReader([Console]::OpenStandardInput())).ReadToEndAsync()
	if ($task.Wait(3000)) { $raw = $task.Result }
}
$data = $null
if ($raw) { try { $data = $raw | ConvertFrom-Json } catch {} }
$sessionId = if ($data -and $data.session_id) { [string]$data.session_id } elseif ($Mode -eq 'release' -and $Arg1) { $Arg1 } else { 'unknown' }

# Full path without trailing slash ('C:\' stays), resolved against $base when relative; $null if unparsable.
function Get-FullPath($path, $base = $null) {
	try {
		if ($base -and -not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $base $path }
		$full = [System.IO.Path]::GetFullPath($path).TrimEnd('\', '/')
		if ($full -match ':$') { $full += '\' }
		return $full
	} catch { return $null }
}

# Walks up from $dir to the first folder holding ProjectSettings\ProjectVersion.txt; $null if there is none.
function Find-ProjectRoot($dir) {
	try {
		$dir = if ($dir) { Get-FullPath $dir } else { $null }
		while ($dir) {
			if (Test-Path -LiteralPath (Join-Path $dir 'ProjectSettings\ProjectVersion.txt')) { return $dir }
			$dir = [System.IO.Path]::GetDirectoryName($dir)
		}
	} catch {}
	return $null
}

# The project a Unity command targets, in the Unity CLI's own order: --project-path, UNITY_PROJECT_PATH, auto-detect.
function Get-CommandProject($command, $cwd) {
	$m = [regex]::Match($command, '--project-path(?:=|' + $sep + ')(?:"([^"]*)"|''([^'']*)''|([^\s;&|)]+))')
	$given = if ($m.Success) { ($m.Groups[1..3] | Where-Object { $_.Success } | Select-Object -First 1).Value } else { $env:UNITY_PROJECT_PATH }
	# A value the shell still expands (~, $var, %VAR%) cannot be resolved here: use the cwd project instead.
	if ($given -and $given -notmatch '^~|[$%]') { $full = Get-FullPath $given $cwd; if ($full) { return $full } }
	return Find-ProjectRoot $cwd
}

# Project argument of wait/force: a folder (taken as is); omitted = the project around the current folder.
# $null for anything else, so an old-style 'force <sessionId>' cannot clear a made-up project.
function Resolve-ProjectArg($value) {
	if (-not $value) { return Find-ProjectRoot $PWD.Path }
	$full = Get-FullPath $value $PWD.Path
	if ($full -and ([System.IO.Path]::IsPathRooted($value) -or (Test-Path -LiteralPath $full -PathType Container))) { return $full }
	return $null
}

# Project as a command argument: forward slashes, so it pastes into bash and PowerShell alike.
function Format-ProjectArg($project) { return '"' + ($project -replace '\\', '/') + '"' }

# Named mutex open to everyone, so a session running at another privilege level can still use it.
# If it cannot be created or opened at all, run without mutual exclusion rather than failing every Unity call.
function Open-Mutex($name) {
	try {
		$mutexSecurity = New-Object System.Security.AccessControl.MutexSecurity
		$everyone = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::WorldSid, $null)
		$mutexSecurity.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule($everyone, 'FullControl', 'Allow')))
		$mutexCreated = $false
		return New-Object System.Threading.Mutex($false, $name, [ref]$mutexCreated, $mutexSecurity)
	} catch {
		try { return [System.Threading.Mutex]::OpenExisting($name) } catch {}
	}
	if ($Mode -ne 'status') { [Console]::Error.WriteLine("unity-lock: named mutex $name unavailable (another Claude process may run elevated); continuing without mutual exclusion.") }
	return $null
}
function Enter-Mutex($mutex) {
	if ($null -eq $mutex) { return $true }
	try { return $mutex.WaitOne($mutexWaitMs) } catch [System.Threading.AbandonedMutexException] { return $true }
}
function Exit-Mutex($mutex) {
	if ($null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
}

# A slot is one project's lock file plus its mutex, both named by a short hash of the lowercased project key.
function New-Slot($project, $path, $mutexName) { return [pscustomobject]@{ project = $project; path = $path; mutex = (Open-Mutex $mutexName) } }
function Get-Slot($project) {
	$sha = [System.Security.Cryptography.SHA256]::Create()
	$bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($project.ToLowerInvariant()))
	$hash = -join ($bytes[0..5] | ForEach-Object { $_.ToString('x2') })
	return New-Slot $project (Join-Path $lockDir "unity-editor-$hash.lock") "Global\ClaudeUnityEditorLock-$hash"
}
# Every per-project lock file on disk (the legacy global unity-editor.lock does not match).
function Get-LockFiles { return @(Get-ChildItem -Path $lockDir -Filter 'unity-editor-*.lock' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^unity-editor-[0-9a-f]+\.lock$' }) }
function Get-AllSlots { foreach ($file in Get-LockFiles) { New-Slot $null $file.FullName ('Global\ClaudeUnityEditorLock-' + $file.BaseName.Substring(13)) } }

# Returns $null (no lock), a lock object, or a lock object with corrupt=$true (unparsable/incomplete file).
function Read-Lock($lockFile) {
	if (-not (Test-Path -LiteralPath $lockFile)) { return $null }
	try { $mtime = (Get-Item -LiteralPath $lockFile).LastWriteTime } catch { return $null }
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

# Write via temp file + swap so the lock file is never half-written. Call inside the slot's mutex.
function Write-Lock($slot, $session, $cwd, $purpose, $expires, $time = $null, $priority = 'normal') {
	if (-not $time) { $time = (Get-Date).ToString('o') }
	$lockFile = $slot.path
	$json = @{ project = $slot.project; session = $session; cwd = $cwd; purpose = $purpose; time = $time; expires = $expires.ToString('o'); priority = $priority } | ConvertTo-Json
	$tmp = "$lockFile.$PID.tmp"
	Set-Content -Path $tmp -Value $json -Encoding utf8
	for ($attempt = 1; $attempt -le 5; $attempt++) {
		try {
			if (Test-Path -LiteralPath $lockFile) { [System.IO.File]::Replace($tmp, $lockFile, [NullString]::Value) } else { [System.IO.File]::Move($tmp, $lockFile) }
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

# Runs an Editor command, trying the next (older CLI) name only when the CLI does not know the current one.
# Returns @{ state = 'ok' | 'closed' | 'error'; result }: 'closed' = no Editor runs for the project,
# 'error' = anything else (timeout, Editor stuck in a reload, unparsable reply).
function Invoke-EditorCommand($project, [string[]]$names) {
	foreach ($name in $names) {
		try {
			$words = $name -split ' '
			$reply = (& unity command --project-path $project @words --json --timeout 10 2>$null | Out-String) | ConvertFrom-Json
			if ($reply.success) { return @{ state = 'ok'; result = $reply.data.result } }
			$why = ($reply.errors | ForEach-Object { $_.message }) -join ' '
			if ($why -match 'No Pipeline instance found') { return @{ state = 'closed' } }
			if ($why -notmatch 'Command Not Found') { break }
		} catch { break }
	}
	return @{ state = 'error' }
}

# True unless the Editor is closed, or answers that it is in edit mode, not compiling/reloading and runs no test.
# A closed Editor has nothing to protect; one that does not answer properly counts as busy.
function Test-EditorBusy($project) {
	$editor = Invoke-EditorCommand $project 'editor status', 'editor_status'
	if ($editor.state -eq 'closed') { return $false }
	if ($editor.state -ne 'ok') { return $true }
	$e = $editor.result
	if ($e.playMode -ne 'stopped' -or $e.compiling -or $e.domainReloadInProgress) { return $true }
	$tests = Invoke-EditorCommand $project 'test status', 'test_status'
	return ($tests.state -ne 'ok' -or $tests.result.status -ne 'no_tests')
}

function Stop-EditorActivity($project) {
	$null = Invoke-EditorCommand $project 'test cancel', 'cancel_tests'
	$null = Invoke-EditorCommand $project 'editor playmode stop', 'editor_stop'
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
		$lines = foreach ($file in Get-LockFiles) {
			$lock = Read-Lock $file.FullName
			if ($lock -and $lock.corrupt) {
				"Corrupt lock file $($file.Name); the next Unity command takes it over automatically."
			} elseif ($lock) {
				$project = [string]$lock.project
				"Unity Editor lock for project $project held by $(Get-HolderLabel $lock.session $lock.cwd) since $($lock.time) (priority $(Get-LockPriority $lock)), expires $($lock.expires) ($($lock.purpose)) in $($lock.cwd). To take over: $runCmd force $(Format-ProjectArg $project) <your session id>"
			}
		}
		if ($lines) { $lines } else { 'Unity Editor is free (no project locks held).' }
	}
	'wait' {
		# Polls (up to ~100s per call) until the project's lock is free or takeable; does not take it. Exit 0 = free, 3 = still held.
		$project = Resolve-ProjectArg $Arg1
		if (-not $project) { 'Usage: wait [project folder] (run it inside a Unity project or pass its folder)'; exit 1 }
		$slot = Get-Slot $project
		$deadline = (Get-Date).AddSeconds(100)
		while ($true) {
			$lock = Read-Lock $slot.path
			$busy = $true
			if ($lock -and -not $lock.corrupt) {
				$timing = Get-LockTiming $lock
				if ($timing.expired -and -not $timing.pastCap) { $busy = Test-EditorBusy $project }
			}
			if (Test-CanTake $lock $busy) { "Unity Editor of project $project is free now. Retry your command."; exit 0 }
			if ((Get-Date) -gt $deadline) { "Still held by $(Get-HolderLabel $lock.session $lock.cwd) until about $($lock.expires). Run wait again, and tell the user in one line that you are still waiting."; exit 3 }
			Start-Sleep -Seconds 5
		}
	}
	'force' {
		$project = Resolve-ProjectArg $Arg1
		if (-not $project) { 'Usage: force [project folder] [sessionId] (run it inside a Unity project or pass its folder)'; exit 1 }
		$slot = Get-Slot $project
		Stop-EditorActivity $project
		$got = Enter-Mutex $slot.mutex
		try {
			$lock = Read-Lock $slot.path
			if (Test-Path -LiteralPath $slot.path) { Remove-Item -LiteralPath $slot.path -Force }
			if ($Arg2) { $fp = Read-Priority $Arg2; Write-Lock $slot $Arg2 '' 'took over via force' (Get-Date).AddMinutes($holdMinutes) $null $(if ($fp) { [string]$fp.value } else { 'normal' }) }
		} finally { if ($got) { Exit-Mutex $slot.mutex } }
		$who = if ($lock) { "session $($lock.session)" } else { 'nobody' }
		"Cancelled running tests, stopped play mode and cleared the lock of project $project held by $who." + $(if ($Arg2) { " The lock now belongs to session $Arg2." } else { ' No session id was given, so the lock is free.' })
	}
	'priority' {
		if (($Arg1 -ne 'high' -and $Arg1 -ne 'normal') -or -not $Arg2) { 'Usage: priority <high|normal> <sessionId>'; exit 1 }
		Save-Priority $Arg2 $Arg1
		"Priority of session $Arg2 set to $Arg1. Retry your Unity command."
	}
	'release' {
		if ($sessionId -eq 'unknown') { 'Usage: release <sessionId> (frees every Unity Editor lock that session holds)'; exit 1 }
		$released = 0
		Remove-Item (Get-PriorityFile $sessionId) -Force -ErrorAction SilentlyContinue
		$slots = @(Get-AllSlots)
		# A lock left by version 1.2 or older is dropped too, but only when this session owns it.
		$legacy = Join-Path $lockDir 'unity-editor.lock'
		if (Test-Path -LiteralPath $legacy) { $slots += New-Slot $null $legacy 'Global\ClaudeUnityEditorLock' }
		foreach ($slot in $slots) {
			$got = Enter-Mutex $slot.mutex
			if ($got) {
				try {
					$lock = Read-Lock $slot.path
					if ($lock -and -not $lock.corrupt -and $lock.session -eq $sessionId) { Remove-Item -LiteralPath $slot.path -Force; $released++ }
				} catch {} finally { Exit-Mutex $slot.mutex }
			}
		}
		if (-not $data) { "Released $released Unity Editor lock(s) held by session $sessionId." }
	}
	'stop' {
		foreach ($slot in Get-AllSlots) {
			$got = Enter-Mutex $slot.mutex
			if ($got) {
				try {
					$lock = Read-Lock $slot.path
					if ($lock -and -not $lock.corrupt -and $lock.session -eq $sessionId) {
						$graceEnd = (Get-Date).AddSeconds($graceSeconds)
						$slot.project = [string]$lock.project
						if ([datetime]::Parse($lock.expires) -gt $graceEnd) { Write-Lock $slot $sessionId $lock.cwd $lock.purpose $graceEnd ([string]$lock.time) (Get-LockPriority $lock) }
					}
				} catch {} finally { Exit-Mutex $slot.mutex }
			}
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
		$opts = '(?:-\S+(?:' + $sep + '(?:"[^"]*"|''[^'']*''|[^-\s;&|"'']\S*))?' + $sep + ')*'
		# Not a lock: discovery calls ('command --query play', '--tag x') and scene files ('Level.unity').
		$notQuery = '(?<!(?:--query|--tags?|-q)[ \t]+)'
		$unityPattern = '(?<![\w.-])(?:unity|[Uu]nity\.exe)["'']?' + $sep + '(?:(?:[^\s;&|]+' + $sep + '){0,8}?(?:command|cmd)' + $sep + $opts + $notQuery + '["'']?[A-Za-z_]|' + $opts + '["'']?(?:recompile|test|close|shell|job|watch|open|run|build)(?=["'']?(?:\s|$|[;&|)}><,])))'
		$isUnity = $isShell -and ($command -cmatch $unityPattern)
		if (-not ($isComputerUse -or $isUnity)) { exit 0 }
		$cwd = if ($data) { [string]$data.cwd } else { '' }
		# Computer use has no project argument, so it locks the session's own project.
		$project = if ($isUnity) { Get-CommandProject $command $cwd } else { Find-ProjectRoot $cwd }
		# Outside any Unity project there is no Editor to share: no lock, no priority question.
		if (-not $project) { exit 0 }
		$purpose = if ($isComputerUse) { "computer use ($toolName)" } else { ($command -replace '\s+', ' ') }
		if ($purpose.Length -gt 80) { $purpose = $purpose.Substring(0, 80) }

		$message = $null
		$capTakeover = $false
		$myPrio = Read-Priority $sessionId
		$prioCmd = "$runCmd priority"
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
			$slot = Get-Slot $project
			# First read under a brief mutex hold; the slow Editor check runs outside the mutex and only when it can matter.
			$first = $null
			$gotFirst = Enter-Mutex $slot.mutex
			try { if ($gotFirst) { $first = Read-Lock $slot.path } } finally { if ($gotFirst) { Exit-Mutex $slot.mutex } }
			$busy = $true
			if ($first -and -not $first.corrupt -and $first.session -ne $sessionId) {
				$timing = Get-LockTiming $first
				# Past 30s of the hook budget, skip the slow check and stay safe by treating the Editor as busy.
				if ($timing.expired -and -not $timing.pastCap -and $clock.Elapsed.TotalSeconds -lt 30) { $busy = Test-EditorBusy $project }
			}

			$got = Enter-Mutex $slot.mutex
			if (-not $got) { $message = 'Unity Editor lock is being updated by another session. Wait and retry in a few seconds.' }
			try {
				if ($got) {
					$lock = Read-Lock $slot.path
					$changed = (($null -eq $lock) -ne ($null -eq $first)) -or ($lock -and $first -and ($lock.time -ne $first.time -or $lock.session -ne $first.session))
					if ($changed -and $lock -and -not $lock.corrupt -and $lock.session -ne $sessionId) {
						$message = "Unity Editor lock of project $project just changed hands (now held by session $($lock.session)). Wait and retry in a minute."
					} elseif (Test-CanTake $lock $busy) {
						if ($lock -and -not $lock.corrupt -and $lock.session -ne $sessionId -and (Get-LockTiming $lock).pastCap) { $capTakeover = $true }
						Write-Lock $slot $sessionId $cwd $purpose (Get-Date).AddMinutes($holdMinutes) $null $myLevel
						if ($waitSinceOld) { Save-Priority $sessionId $myLevel }
					} else {
						$holder = Get-HolderLabel $lock.session $lock.cwd
						$tellUser = if ($holder -match '^\[') { "pasting this link exactly as written: $holder" } else { "describing it exactly like this so they can find that session: $holder" }
						$holderLevel = Get-LockPriority $lock
						$levels = "(holder priority $holderLevel, yours $myLevel)"
						$waitCmd = "$runCmd wait $(Format-ProjectArg $project)"
						if (-not ($myLevel -eq 'high' -and $holderLevel -eq 'normal')) {
							$since = if ($waitSinceOld) { $waitSinceOld } else { (Get-Date).ToString('o') }
							if (-not $waitSinceOld) { Save-Priority $sessionId $myLevel $since }
							$waited = ((Get-Date) - [datetime]::Parse($since)).TotalMinutes
							if ($waited -gt $escalateMinutes) {
								$message = "UNITY EDITOR LOCK: you have waited over $escalateMinutes minutes for the Editor of project $project, held by $holder $levels. Tell the user in your next message, $tellUser , then ask with the AskUserQuestion tool (BUTTONS, not plain text; load it with ToolSearch query select:AskUserQuestion if deferred): options 'Keep waiting' and 'Give up for now'. Keep waiting: run $prioCmd $myLevel $sessionId (resets the timer), then $waitCmd (repeat while it exits 3), then retry. Give up: stop trying the Editor and say so. Do NOT force."
							} else {
								$message = "UNITY EDITOR LOCK: the Editor of project $project is in use by $holder $levels (running '$($lock.purpose)'). Your priority is not higher, so DO NOT ask the user and do NOT force. But keep the user informed in chat: (1) say now, in one short line, that you are waiting for the Unity Editor and who holds it, $tellUser . (2) Run $waitCmd (repeat while it exits 3, and after each round say in one short line that you are still waiting). (3) When it exits 0, say in one line that the Editor is free and retry your command."
							}
						} else {
						$message = "UNITY EDITOR LOCK: your playtest/Unity command on project $project is blocked by $holder $levels (running '$($lock.purpose)' since $($lock.time)). The lock frees by itself once that session's lock has lapsed and the Editor is idle.`n" +
							"DO THIS NOW: (1) tell the user in your next message that you are blocked and by which session, $tellUser . (2) Ask the user with the AskUserQuestion tool so they get BUTTONS, never as plain text (if the tool is deferred, load it first with ToolSearch query select:AskUserQuestion): one question, multiSelect false, two options: label 'Wait' (description: wait until that session's lock ends, then continue) and label 'Force takeover' (description: cancels that session's running test and stops play mode, then takes the Editor). Do NOT force without the user's answer.`n" +
							"If the user chooses Wait: run $waitCmd (repeat while it exits 3), then retry your command.`n" +
							"If the user chooses Force: run $runCmd force $(Format-ProjectArg $project) $sessionId , then retry your command."
						}
					}
				}
			} finally { if ($got) { Exit-Mutex $slot.mutex } }
			# A lock that lapsed long ago may have left a test or play mode running: clean up for the new owner.
			if ($capTakeover -and $clock.Elapsed.TotalSeconds -lt 60) { Stop-EditorActivity $project }
		} catch {
			$message = "Unity lock hook error: $($_.Exception.Message). Wait a few seconds and retry."
		}
		if ($message) { [Console]::Error.WriteLine($message); exit 2 }
	}
}
exit 0
