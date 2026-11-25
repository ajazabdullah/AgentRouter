# Changelog

## v0.3.0 — 2026-11-25 — Two-pane workspace, CLI handoff and Claude Channels

### Added

- Large resizable workspace with a project sidebar, adjustable prompt/output panes and an always-visible Send bar directly below the prompt preview. Window size and position are remembered; native full screen remains optional.
- Dock and Command–Tab presence. Activating AgentRouter restores a hidden or minimized workspace while menu-bar access and background monitoring continue.
- Optional draggable floating AR circle over Terminal (default ON) with a saved position.
- Optional **Expand CLI to fill screen after sending** (default OFF), resizing only the verified target Terminal window without creating a separate full-screen Space.
- **Claude Channels (preview):** opt-in, per-project Claude submission through a bundled native `AgentRouterChannel` MCP helper over private, run-scoped Unix sockets. Includes message-ID acknowledgment, persistent pending-delivery protection, `MESSAGE_RECEIVED` History entries and Terminal startup guidance. Manual permission handling and existing non-channel submission paths are unchanged.

### Changed

- Project rows and CLI chips select without opening Terminal. A separate **Go to CLI** action opens the remembered CLI. Stale remembered IDs show explicit CLI choices instead of opening another target.
- Compact single-row header; prompt **Clear** at the top of the editor.
- Successful delivery focuses Terminal before hiding the UI, respecting the hide preference. Attached split views are found by identity and the correct pane is selected and highlighted; stale or ambiguous views fail closed.
- Quit review groups three equal-width, color-coded actions with separate checkpoint export, explicit shutdown confirmation and visible wait progress.
- **Send preview** keeps the manual idle confirmation and readiness checks; **Send & Open CLI** still reads the latest clipboard.

### Fixed

- Channel message size is validated before saving pending delivery, so a rejected prompt cannot block later sends.
- The channel helper recovers from malformed MCP input without losing its acknowledgment ledger.
- Receipt polling runs outside the lifecycle actor, deduplicates concurrent polls and ignores stale receipts after Stop or run changes.

### Validation and limitations

- `swift test` adds channel coverage (settings migration, inheritance, pending persistence, duplicate blocking, acknowledgment History); `scripts/test-channel.py` checks the real helper's protocol and socket. One live Claude Code channel smoke test confirmed delivery and acknowledgment.
- Workspace, AR circle and handoff changes received a scoped Claude Sonnet medium review and a release compilation; no UI automation or full runtime tests. See `docs/VERIFICATION.md`.
- Custom Claude channels currently require Claude's development-channel flag and are subject to organization policy.

## 2026-11-10 — Multiple CLIs, safer quitting, and a simpler workspace

### Added

- Multiple independent Codex or Claude Code CLI instances per project, each with its own session, exact pane binding, hook identity and status. Project selection remembers the last chosen CLI; the AR menu lists individual instances.
- Safe quit review with **Cancel**, **Export Checkpoint…**, **Keep Running & Quit**, and **Stop Agents & Quit…**. Graceful shutdown requires confirmation; force-stopping remaining original runs requires separate confirmation.
- Owner-only, atomic Markdown checkpoint export containing all configured CLIs, sampled status and available verified completed replies. Clipboard contents, unsent drafts and IPC credentials are excluded.
- An interactive single-view design demo and editable layout JSON under `docs/ui-demo/`.

### Changed

- README explains agent notification clicks, permission/running requirements,
  and the separate GitHub release-subscription workflow for software updates.

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
