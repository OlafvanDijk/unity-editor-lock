# unity-editor-lock

A Claude Code plugin that stops parallel Claude sessions from interrupting each other's Unity Editor testing. One session at a time holds an exclusive lock on the Editor. A blocked session tells you which session blocks it and lets you choose **Wait** or **Force takeover** with buttons. It works in both the Claude desktop app and the Claude Code terminal, and sessions of both kinds on the same PC share one lock.

## Requirements
- Windows with Windows PowerShell 5.1 (included with Windows 10/11).
- Claude Code (terminal CLI or desktop app). In the desktop app the blocker is shown as a clickable session link. In the terminal there is no link, so the message describes the blocking session instead: its title or first prompt, a short id, its folder, when it was last active, and the `claude --resume <id>` command to open it.
- The Unity CLI (`unity`) on your PATH. The lock detects `unity command ...` calls and asks the Editor whether it is idle.
- Git, to let Claude Code clone the plugin.

## Install
```
claude plugin marketplace add OlafvanDijk/unity-editor-lock
claude plugin install unity-editor-lock@unity-editor-lock
```
Restart any running Claude sessions: sessions that were open before the install do not have the plugin's hooks.

Update: `claude plugin marketplace update unity-editor-lock`, then `claude plugin update unity-editor-lock@unity-editor-lock`.
Uninstall: `claude plugin uninstall unity-editor-lock@unity-editor-lock`.

## What it does
- Every `unity command ...` call (also `cmd`, `recompile`, `test`, `close`, `shell`, `job`, `watch`, `open`, `run`, `build`) and every computer-use call takes the lock. Read-only commands count too, so nobody changes or reads Editor state during someone else's playtest.
- A blocked session must tell you who blocks it and ask with buttons:
  - **Wait**: it polls with `wait` until the lock is free, then retries.
  - **Force takeover**: it cancels the holder's tests, stops play mode and takes the lock.
- The lock is shared by every session and worktree on the same PC: it lives in `%USERPROFILE%\.claude\locks`, not in the project. It does **not** coordinate between different computers; each PC has its own Editor and its own lock.

## Lock rules
- A command by the owner refreshes the lock to 5 minutes. When a turn ends the lock shrinks to a 60 second grace, and ending the session releases it.
- Another session takes over automatically only when the lock has lapsed AND the Editor is idle (play mode stopped, not compiling or reloading, no test running; an unreachable Editor counts as busy). A lock that lapsed more than 30 minutes ago, or a corrupt lock file, is also taken over.
- All reads and writes run under a named mutex. If the hook itself fails on a matched call, that call is blocked with a retry message instead of running unlocked.

## Script modes
`pre`, `stop`, `release` are used by the hooks. Manual modes: `status`, `wait`, `force [sessionId]`, run as
`powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin folder>/scripts/unity-lock.ps1" status`.

## Terminal notes
- Closing a terminal abruptly (window close, Ctrl+C) may skip the SessionEnd hook. The orphaned lock then lapses on its own within about 5 minutes, or you can pick **Force takeover** in the next blocked session.
- The Wait / Force buttons use Claude Code's `AskUserQuestion` tool, which shows as a menu in the terminal.

## Known limits
- A plain capital-U `Unity command x` and variable-as-program calls (`& $u command`) are not detected.
- A dead session that left play mode on blocks others until `force` or the 30 minute cap.
- Background subagents lose the lock after the 60 second grace when they make no Unity calls.
- The session link lookup reads the Claude desktop app's own session files; if that layout changes, the message falls back to the bare session id.
- Windows only.

## License
MIT
