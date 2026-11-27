# AgentRouter

AgentRouter keeps your Codex and Claude Code projects one click away in the Mac menu bar.

Copy a prompt from ChatGPT or Claude, choose the project you want to work on, and send it to your coding assistant. Open its Terminal window to follow the work, then copy the assistant’s reply back into your chat when you’re ready.

Keep several projects open, switch between their assistants, and get notified when they need your attention. You choose where each prompt goes and when it is sent.

See the [changelog](CHANGELOG.md) for what’s new and [verification notes](docs/VERIFICATION.md) for what has been checked and what still needs manual testing.

## Features

- A resizable workspace with a project sidebar, prompt editor, always-visible Send bar and CLI output. It lives in the Dock and the menu bar.
- Multiple independent Codex or Claude Code CLI instances per project, with separate tmux sessions, exact pane identities, hook metadata, and live status.
- A gear beside each project for Start, Open CLI, Stop, Restart, New CLI, configuration, notification preferences, and side-by-side views.
- Persistent AR menu access, one additional selected-running-project item, remembered CLI selection and optional keyboard shortcuts.
- Automatic clipboard capture from the supported desktop apps; manual **Send & Open CLI** and **Paste Only** actions.
- Complete latest-reply copying from verified native transcripts, plus a separate retained terminal-screen viewer.
- Native lifecycle notifications, timestamped history and interactive replies where readiness permits. Notification clicks open the exact CLI in Terminal, with UI fallback for errors or busy operations.
- Resizable side-by-side Terminal views while retaining separate CLI windows.
- Safe quit review, local Markdown checkpoint export, confirmed graceful shutdown and separately confirmed force-stop retries.
- An optional floating AR circle over Terminal, and optional fill-screen resizing of the target Terminal window after sending.
- Claude Channels (preview): opt-in delivery into a running Claude Code conversation with receipt acknowledgment.

## Requirements

- macOS 14 or later and Swift 6/Xcode command-line tools.
- tmux; development used version 3.8.
- Codex CLI and/or Claude Code installed and authenticated separately.
- A working Node runtime for npm-based CLI launchers.

There are no third-party Swift packages. Runtime discovery favors Homebrew paths; other installations may require an absolute executable path. Intel Macs have not received the same runtime checks as Apple Silicon.

## Build and install

```sh
./scripts/build-app.sh
open .build/AgentRouter.app
```

The script creates an ad-hoc signed bundle. No notarized binary download is provided. To install, quit AgentRouter using **Keep Running & Quit** if you want to preserve live CLIs, then copy the bundle:

```sh
ditto .build/AgentRouter.app /Applications/AgentRouter.app
open /Applications/AgentRouter.app
```

You can open `Package.swift` in Xcode. Set `AGENTROUTER_SIGN_IDENTITY` to use your own existing signing identity; the script does not create certificates or change security settings.

## Set up and select projects

1. Open AgentRouter and click **Add**. Its generic initial examples are Project 1, Project 2 and Project 3; existing saved settings keep their names and IDs.
2. Set a project name, existing absolute working directory, Codex or Claude Code, an installed absolute executable path, and a unique tmux session name. Save.
3. Use the gear beside the project, then **Start Agent**. Complete login, directory trust and hook review in **Open CLI** if required.
4. Click a project row and a CLI chip to select it inside AgentRouter; this does not open Terminal. Use the project's **Go to CLI** button to open its remembered CLI. Icons beside it start (▶), stop (■) or restart (↻) that CLI without opening the gear; stop and restart ask first. Restart also recovers a CLI whose session was lost, for example after tmux restarted. Selection never starts a stopped agent automatically. If a remembered CLI was removed, the row offers explicit CLI choices instead of a fallback.
5. Use the project's gear for lifecycle controls, **Edit Configuration…**, **New CLI**, or **Work side by side**. The gear opens controls without opening Terminal by itself.

Additional CLIs share the same checkout. They are separate conversations, not isolated worktrees, and can edit the same files. Directory changes/removing a project require all of its CLIs to be stopped. Creating an additional instance upgrades settings to version 3; older app versions cannot read that format.

## Send prompts and receive output

Copy a prompt, select a project/CLI, and click **Send & Open CLI**. It snapshots the latest clipboard, submits only when readiness is verified, and opens the exact Terminal session. A stopped CLI offers **Start & Send**, with a bounded readiness wait. No delayed background send remains queued after failure.

**Current limitation:** Codex hooks do not establish safe Enter readiness in this implementation. Use **Manual paste & submit → Paste Only** after confirming the displayed CLI is idle, then submit manually in Terminal. Claude's native `idle_prompt` may grant a short, single-use readiness lease. Structured questions and approvals must be handled in the CLI; AgentRouter never automatically approves them.

The output follows the selected project/CLI. **Latest reply → Copy Output** reads the complete latest completed assistant text from the verified native session transcript, without trimming or a length cap. A missing or mismatched transcript is an error, never a guessed conversation. Existing running sessions need a fresh authenticated hook event to bind their transcript metadata.

**Terminal screen → Copy Screen** instead copies retained tmux output, preserving colors in the viewer. Full-screen redraws/history limits can hide earlier terminal text. Output copying never sends content to a desktop app; paste it yourself.

## Agent notification behavior

AgentRouter must be running for hook monitoring and native notifications; it can
be hidden. Enable and save each project's event preferences and allow macOS
notifications. Quitting AgentRouter stops its monitoring/notifications even if the
underlying CLI sessions remain alive.

Clicking an agent notification opens its exact CLI in Terminal, reusing an attached
tab when available. If the target is unavailable, Terminal cannot open, or the app
is busy, AgentRouter shows the problem. Clicking does not start a stopped CLI,
submit text, approve permissions or route to another project. There is currently
no setting to change the notification-click behavior.

A finished turn is not proof the task succeeded. Native events, inferred questions
and unsupported completion/blocker cases are distinguished in the
[notification support matrix](docs/VERIFICATION.md). Questions can be answered in
the widget only under its readiness checks; structured dialogs and approvals need
manual CLI interaction.

## Workspace and window

AgentRouter opens as a large, resizable workspace: projects on the left, the prompt editor above and CLI output below a draggable divider. The Send bar stays directly below the prompt preview, and **Clear** sits at the top of the editor. Window size and position are remembered; native macOS full screen is optional.

AgentRouter appears in the Dock and Command–Tab as well as the menu bar. Switching back restores a hidden or minimized workspace. Closing or hiding the window keeps monitoring running; use Quit to exit.

After a successful send and Terminal handoff, **Hide widget after sending** hides AgentRouter. Errors keep it visible, and a delivered prompt is never queued for retry. If exactly one verified split view contains the target CLI, its pane is focused and highlighted; stale or ambiguous split views block sending.

- **Expand CLI to fill screen after sending** (default OFF) resizes only the matched Terminal window to the display's usable area. It does not create a separate full-screen Space or need Accessibility access.
- **Show floating AR circle over Terminal** (default ON) shows a small draggable circle while Terminal or AgentRouter is active. Click it to show/hide the workspace. Its position is saved. Turn it off in App settings; AR and **Option–Command–R** still work.

## AR menu

Click **AR** in the menu bar. **Running CLIs** at the top lists every live CLI as *Project · CLI — state*; one click opens it in Terminal. A green dot marks a CLI that is working on a turn and an orange dot one that needs your input or approval; those CLIs, and their projects, are listed first. Idle and stopped CLIs are unmarked. Each entry names its state (Working, Needs you, Idle, Stopped…). Activity comes from CLI hooks, so a CLI without a recent hook event shows as Idle. Project submenus still offer **Start new … CLI**.

## Notifications, settings and shortcuts

Enable project events under its gear → **Edit Configuration…**, save, and use **Allow macOS Notifications…** for system permission. **Test Notification** checks permission/request delivery without attaching hooks. Hook settings are scoped to AgentRouter launches and do not overwrite native CLI configuration. Native authentication and hook trust still apply.

Finished-turn notifications show the last sentence of the latest verified reply, so you can tell "still working" from "needs you" without opening Terminal. The preview is not stored in History; turn it off under App settings → **Show reply preview in notifications**.

Clicking a notification opens the corresponding CLI in Terminal, reusing an attached tab where possible. If that cannot proceed, AgentRouter displays the problem. Notification clicks do not start a CLI or send input. History stores metadata rather than prompt/reply bodies.

The header opens history and application settings; Back returns to the project list. **Show widget automatically when copying** defaults OFF; **Hide widget after sending** defaults ON. Hide/title-bar close leave monitoring and agents running. Reopen through AR or **Option–Command–R**. macOS may hide menu-bar items when crowded.

Optional **Option–Command–1–9** shortcuts select projects while the widget is active. Global F7/F8/F9 are assigned to the first three project IDs on initial setup and remember those IDs; hold Fn if your keyboard uses media keys. Missing assignments never choose a fallback project.

Codex approval (`on-request`, `never`) and sandbox (`read-only`, `workspace-write`, `danger-full-access`) choices are launch-only overrides set in project configuration. They apply on the next Start/Restart. `never` does not grant access beyond the selected sandbox; login/trust prompts can still require interaction.

## Quitting and checkpoints

- **Cancel** is the quit review's default.
- **Export Checkpoint…** saves a private Markdown file with all configured CLIs, sampled identities/status and available verified completed replies; it returns to review. This is a checkpoint, not an agent-written handoff or proof work was saved.
- **Keep Running & Quit** stops only AgentRouter. CLI sessions continue; AgentRouter monitoring and notifications stop until reopening.
- **Stop Agents & Quit…** separately confirms graceful SIGTERM to verified owned CLI groups and waits for verified exit. If it fails, the app stays open.
- **Force Stop Remaining…** requires another confirmation and only targets remaining originally confirmed runs. A restarted/unverified run cannot inherit consent. Terminal windows are not closed.

Drafts are not persisted or included in checkpoints. Exported replies can themselves contain sensitive material; review before sharing. Logout/shutdown/force quit can affect session survival independently of AgentRouter.

## Claude Channels (preview)

For a stopped Claude project, enable **Submit through Claude Channels (preview)** in its settings, then start a new session. Additional Claude CLIs inherit the setting on their next start; existing sessions are not converted. Accept Claude's folder and development-channel trust prompts in Terminal. Custom channels currently require Claude's development flag and remain subject to organization policy.

**Send & Open CLI** then delivers the prompt through the bundled native `AgentRouterChannel` helper into the same interactive conversation, so you can keep typing in Terminal. The helper uses a run-scoped, owner-only Unix socket with same-user peer checks and a run credential. No Node/npm or TCP port is needed.

A delivered message is not a receipt. Claude is asked to call the helper's `acknowledge` tool with the message ID (this tool may itself need your approval in Terminal). AgentRouter shows a pending notice until then and records `MESSAGE_RECEIVED` in History, which says nothing about task completion. Only one unacknowledged message is allowed per run, and pending IDs survive app restarts. There is no automatic retry, permission approval or keystroke fallback; if delivery is uncertain, check Terminal before retrying.

Stop the main CLI before changing the setting. Projects without it keep the existing submission path, and Paste Only remains available. Build with `scripts/build-app.sh` so both helpers are bundled. To check the helper locally: `swift test`, then `python3 scripts/test-channel.py` against the debug build (no model requests).

## Privacy and safety

AgentRouter uses exact tmux ownership/run/pane/process identities, never an active Terminal window or guessed pane. Unowned collisions, stale/ambiguous targets and uncertain readiness fail closed. Clipboard bytes enter tmux through a named buffer, never a shell command; no prompt is submitted automatically.

Local settings/binding metadata/history live under `~/Library/Application Support/AgentRouter/` with owner-only permissions. Hook IPC uses a local Unix socket. The router opens no network listener; native CLIs retain their own network and history behavior. No conversation-to-project detection, automatic routing, queues or automatic security approvals are implemented.

## Validation and contributions

The current release compiled successfully and `swift test` covers core channel and lifecycle logic. Workspace, AR circle, quit and multi-CLI UI behavior has received static reviews, **not full runtime or UI-automation verification**. See [architecture](docs/ARCHITECTURE.md), [verification](docs/VERIFICATION.md) and [review](docs/REVIEW-2026-11-07.md). An optional local design simulation and editable placement JSON are in `docs/ui-demo/`; they do not control real sessions.

For contributors who want to run the existing tests themselves:

```sh
swift test
# Opt-in native CLI startup smoke checks; no submitted tasks:
AGENTROUTER_NATIVE_TESTS=1 swift test --filter NativeCLITests
```

## Stay updated

Choose **Watch → Custom → Releases** on GitHub to subscribe to published release announcements. Cloning or starring alone is not a release subscription. A code push does not create a release announcement; a GitHub Release must actually be published for release subscribers. Important changes are recorded in [CHANGELOG.md](CHANGELOG.md). A local source checkout can be updated with `git pull --ff-only`, then rebuilt using the commands above. AgentRouter has no automatic update checker.

Use GitHub Issues for reproducible bugs and feature requests. Remove tokens, private prompts and personal project paths before sharing logs. MIT licensed; see [LICENSE](LICENSE).
