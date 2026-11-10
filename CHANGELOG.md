# Changelog

## 2026-11-10 — Multiple CLIs, safer quitting, and a simpler workspace

### Added

- Multiple independent Codex or Claude Code CLI instances per project, each with its own session, exact pane binding, hook identity and status. Project selection remembers the last chosen CLI; the AR menu lists individual instances.
- Safe quit review with **Cancel**, **Export Checkpoint…**, **Keep Running & Quit**, and **Stop Agents & Quit…**. Graceful shutdown requires confirmation; force-stopping remaining original runs requires separate confirmation.
- Owner-only, atomic Markdown checkpoint export containing all configured CLIs, sampled status and available verified completed replies. Clipboard contents, unsent drafts and IPC credentials are excluded.
- An interactive single-view design demo and editable layout JSON under `docs/ui-demo/`.

### Changed

- One main view combines selectable project rows, CLI chips, prompt routing and output. Each project's gear opens lifecycle controls, configuration and side-by-side settings. History and application preferences open from the header.
- **Send & Open CLI** reads the latest clipboard and submits only when readiness is verified. Manual Paste Only and existing reply controls remain available.
- Body/output text uses 16 pt, supporting text 15 pt, with larger headings and controls. Counts distinguish running CLIs from configured CLIs.
- Quit confirmation and force-stop consent are bound to exact CLI runs. Restarted or unverified runs are never silently substituted.

### Fixed

- Split-view reuse verifies the actual nested tmux client TTY, PID and session identity, rather than relying on its process name.
- Quit review blocks new routing/selection operations and preserves widget visibility while existing operations finish.
- Missing sessions are considered stopped only after checking the original controller process; failed stop signals restore the previous stop-request state.

### Validation and limitations

- Latest release compilation passed. No new automated tests, UI automation or live-session shutdown checks were run for these changes; runtime behavior remains for manual verification.
- Read-only reviews: GPT-6.1 Sol medium for multiple-CLI/quit behavior, and Claude Sonnet medium for shutdown. Findings were addressed; detailed evidence and review limits are in `docs/VERIFICATION.md`.
- Codex hooks currently do not establish safe automatic submission readiness. Use confirmed Paste Only and submit manually when readiness is unavailable. No permission request is automatically approved.
- Additional CLIs share a working directory; AgentRouter does not isolate simultaneous edits with worktrees.
- Creating an additional CLI upgrades workspace settings to version 3. Existing version-2 settings load without changing project names or original bindings. Older app versions cannot read version 3.

## Earlier updates — Complete replies, permissions, and split views

- **Copy Output** reads complete latest completed assistant replies from verified native transcripts; retained terminal-screen copying remains separate.
- Notification clicks select the exact controller and open its CLI in Terminal, showing AgentRouter for errors or a busy operation. This remains the default behavior.
- Project-specific Codex approval/sandbox launch overrides, without modifying native CLI configuration files.
- Optional reusable side-by-side Terminal views with resizable panes and independent standalone CLI windows.
- Native lifecycle notifications/history, manual clipboard routing, exact tmux ownership checks, Terminal tab reuse, and persistent hide/shortcut preferences.
