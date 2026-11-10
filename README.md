# AgentRouter

A native macOS menu bar app for managing local Codex and Claude Code sessions across projects.

**Experimental software.** Select a project, route a prompt manually, and watch its exact CLI in Terminal. Clipboard capture never chooses a project, submits automatically, or approves permissions. See [CHANGELOG.md](CHANGELOG.md) for important updates and [verification](docs/VERIFICATION.md) for evidence and limits.

## Features

- A single main view with project rows, CLI selection chips, prompt routing, and output copying. Body/output text uses 16 pt; supporting text uses 15 pt.
- Multiple independent Codex or Claude Code CLI instances per project, with separate tmux sessions, exact pane identities, hook metadata, and live status.
- A gear beside each project for Start, Open CLI, Stop, Restart, New CLI, configuration, notification preferences, and side-by-side views.
- Persistent AR menu access, one additional selected-running-project item, remembered CLI selection and optional keyboard shortcuts.
- Automatic clipboard capture from the supported desktop apps; manual **Send & Open CLI** and **Paste Only** actions.
- Complete latest-reply copying from verified native transcripts, plus a separate retained terminal-screen viewer.
- Native lifecycle notifications, timestamped history and interactive replies where readiness permits. Notification clicks open the exact CLI in Terminal, with UI fallback for errors or busy operations.
- Resizable side-by-side Terminal views while retaining separate CLI windows.
- Safe quit review, local Markdown checkpoint export, confirmed graceful shutdown and separately confirmed force-stop retries.

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
4. Click a project row and a CLI chip to select/open its existing session. Selection never starts a stopped agent automatically. The prompt area identifies the selected destination.
5. Use the project's gear for lifecycle controls, **Edit Configuration…**, **New CLI**, or **Work side by side**. The gear opens controls without opening Terminal by itself.

Additional CLIs share the same checkout. They are separate conversations, not isolated worktrees, and can edit the same files. Directory changes/removing a project require all of its CLIs to be stopped. Creating an additional instance upgrades settings to version 3; older app versions cannot read that format.

## Send prompts and receive output

Copy a prompt, select a project/CLI, and click **Send & Open CLI**. It snapshots the latest clipboard, submits only when readiness is verified, and opens the exact Terminal session. A stopped CLI offers **Start & Send**, with a bounded readiness wait. No delayed background send remains queued after failure.

**Current limitation:** Codex hooks do not establish safe Enter readiness in this implementation. Use **Manual paste & submit → Paste Only** after confirming the displayed CLI is idle, then submit manually in Terminal. Claude's native `idle_prompt` may grant a short, single-use readiness lease. Structured questions and approvals must be handled in the CLI; AgentRouter never automatically approves them.

The output follows the selected project/CLI. **Latest reply → Copy Output** reads the complete latest completed assistant text from the verified native session transcript, without trimming or a length cap. A missing or mismatched transcript is an error, never a guessed conversation. Existing running sessions need a fresh authenticated hook event to bind their transcript metadata.

**Terminal screen → Copy Screen** instead copies retained tmux output, preserving colors in the viewer. Full-screen redraws/history limits can hide earlier terminal text. Output copying never sends content to a desktop app; paste it yourself.

## Notifications, settings and shortcuts

Enable project events under its gear → **Edit Configuration…**, save, and use **Allow macOS Notifications…** for system permission. **Test Notification** checks permission/request delivery without attaching hooks. Hook settings are scoped to AgentRouter launches and do not overwrite native CLI configuration. Native authentication and hook trust still apply.

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

## Privacy and safety

AgentRouter uses exact tmux ownership/run/pane/process identities, never an active Terminal window or guessed pane. Unowned collisions, stale/ambiguous targets and uncertain readiness fail closed. Clipboard bytes enter tmux through a named buffer, never a shell command; no prompt is submitted automatically.

Local settings/binding metadata/history live under `~/Library/Application Support/AgentRouter/` with owner-only permissions. Hook IPC uses a local Unix socket. The router opens no network listener; native CLIs retain their own network and history behavior. No conversation-to-project detection, automatic routing, queues or automatic security approvals are implemented.

## Validation and contributions

The current update compiled successfully. New multi-CLI, quit/shutdown and merged-UI behavior has received static reviews and compilation checks, **not full runtime or automated-test verification**. See [architecture](docs/ARCHITECTURE.md), [verification](docs/VERIFICATION.md) and [review](docs/REVIEW-2026-11-07.md). An optional local design simulation and editable placement JSON are in `docs/ui-demo/`; they do not control real sessions.

For contributors who want to run the existing tests themselves:

```sh
swift test
# Opt-in native CLI startup smoke checks; no submitted tasks:
AGENTROUTER_NATIVE_TESTS=1 swift test --filter NativeCLITests
```

## Stay updated

Choose **Watch → Custom → Releases** on GitHub to subscribe to published release announcements. Cloning or starring alone is not a release subscription. Important changes are recorded in [CHANGELOG.md](CHANGELOG.md). A local source checkout can be updated with `git pull --ff-only`, then rebuilt using the commands above. AgentRouter has no automatic update checker.

Use GitHub Issues for reproducible bugs and feature requests. Remove tokens, private prompts and personal project paths before sharing logs. MIT licensed; see [LICENSE](LICENSE).
