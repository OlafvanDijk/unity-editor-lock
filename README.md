# unity-editor-lock

A Claude Code plugin (Windows, PowerShell 5.1) that stops parallel Claude sessions from interrupting each other's Unity Editor testing.

## What it does
- Every `unity command ...` call (also `cmd`, `recompile`, `test`, `close`, `shell`, `job`, `watch`, `open`, `run`, `build`) and every computer-use call takes an exclusive lock. Read-only commands count too, so nobody changes or reads Editor state during someone else's playtest.
- A blocked session must tell the user which session blocks it (clickable link in the Claude desktop app) and ask with buttons: **Wait** (`wait` mode polls until the lock is free) or **Force takeover** (cancels the holder's tests, stops play mode, takes the lock).
- The lock is shared by all sessions and worktrees: it lives in `%USERPROFILE%\.claude\locks`, not in the project.

## Lock rules
- Owner commands refresh the lock to 5 minutes. When a turn ends (Stop hook) the lock shrinks to a 60 second grace; the session ending releases it.
- Another session may take over only when the lock has lapsed AND the Editor is idle (play mode stopped, not compiling/reloading, no test running; unreachable counts as busy), or when it lapsed more than 30 minutes ago, or when the lock file is corrupt.
- Everything runs under a named mutex; hook errors become a block (exit 2) with a retry message.

## Script modes
`pre`, `stop`, `release` (hooks), plus manual `status`, `wait`, `force [sessionId]`.

## Known limits
- A plain capital `Unity command x`, and variable-as-program calls (`& $u command`), are not detected.
- A dead session that left play mode on blocks others until `force` or the 30-minute cap.
- Background subagents lose the lock after the 60 second grace when they make no Unity calls.
- Link lookup reads the app's own session files (`cliSessionId`); if that layout changes the block message falls back to the bare session id.
