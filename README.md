# AgentRouter

A native macOS menu bar utility for managing local Codex and Claude Code sessions across projects.

**Experimental software.** Start agents, switch between their Terminal sessions, route clipboard prompts manually, and copy their output back to your architecture conversation. AgentRouter does not choose a project from your copied text or automatically approve agent requests.

## Features

- Add projects with a working directory, CLI executable, session name, and notification preferences.
- Start, stop with confirmation, and restart agents in exact, owned tmux panes.
- Open the selected agent in Terminal.app; reuse an attached tab when available.
- Keep **AR** in the menu bar, with one additional button for the selected running project.
- Automatically capture text copied while ChatGPT Desktop or Claude Desktop is active.
- **Send Clipboard & Open Terminal** reads the current clipboard, submits only when readiness is verified, and opens the selected session.
- **Paste Only** provides a manual fallback without pressing Enter.
- View retained terminal output and use **Copy Output** to copy plain text.
- Receive native notifications and inspect project event history.
- Hide the widget while monitoring continues; reopen it from AR or **Option–Command–R**.

## Requirements

- macOS 14 or later and a Swift 6 toolchain, such as Xcode's command-line tools.
- tmux. The development environment uses tmux 3.8.
- Codex CLI and/or Claude Code installed and authenticated separately.
- A working Node runtime for npm-installed CLI launchers. AgentRouter checks Homebrew Node runtimes because an executable symlink can still have broken library dependencies.

No third-party Swift packages are required. Current runtime discovery favors Homebrew installations; other layouts may require configuring an absolute CLI executable path. Intel Macs have not received the same runtime testing as Apple Silicon.

## Build and install

Clone this repository and run:

```sh
cd AgentRouter
./scripts/build-app.sh
open .build/AgentRouter.app
```

The script creates an ad-hoc signed app bundle. No notarized download is provided. To install locally, quit any running AgentRouter app first, then copy the bundle:

```sh
ditto .build/AgentRouter.app /Applications/AgentRouter.app
open /Applications/AgentRouter.app
```

You can also open `Package.swift` in Xcode. To sign with your own existing identity, set `AGENTROUTER_SIGN_IDENTITY` when invoking the build script. The script does not create certificates or alter macOS security settings.

## Set up a project

1. Open AgentRouter. Its widget appears on launch.
2. Select an example project and click **Settings**, or use **+** to add one.
3. Choose a name, an existing absolute working directory, Codex or Claude Code, an absolute CLI executable, and a unique tmux session identifier. Save.
4. Click **Start Agent**. The app creates and binds the pane, checks startup health, and opens Terminal. Complete CLI authentication, workspace trust, and hook review there if required.
5. Use **Stop** or **Restart** in Project management. Shutdown requires confirmation and never escalates to a force stop automatically. Choose a fresh conversation or the CLI's conversation resume picker before starting/restarting.

The default example names are **Project 1**, **Project 2**, and **Project 3**. Existing installations retain their saved project names and settings.

## Send a prompt

1. Copy a prompt in your desktop conversation.
2. Open AgentRouter and select the destination. Its name, directory, CLI, and session are displayed before sending.
3. Click **Send Clipboard & Open Terminal**.

If the selected agent is stopped, the app offers **Start & Send**, then waits briefly for verified readiness. If readiness is uncertain, it refuses submission and offers **Open Terminal**. No background send remains queued after the startup wait expires.

**Current limitation:** Codex's implemented hook adapter does not establish safe Enter readiness, so automatic submission stays blocked for Codex. Use **Paste Only** after confirming the displayed destination is idle, then submit manually in Terminal. Claude's native `idle_prompt` may grant a short, single-use readiness window; authentication, trust prompts, questions, and approvals can still prevent submission.

## Receive output and notifications

The output project's dropdown can follow the selected destination or show another configured project. **Copy Output** copies the displayed plain text without a length cap or trimming. Paste it into your desktop conversation yourself; AgentRouter never sends output to ChatGPT Desktop or Claude Desktop.

The viewer is a tmux snapshot, not a full terminal emulator or conversation archive. It supports colors, bold, and italics, but tmux history limits and full-screen redraws can remove earlier output. Some terminal features, including OSC hyperlink sequences, remain incomplete.

Manage notifications in **Project Settings**. Enable project events and save; use **Allow macOS Notifications…** for system permission, and **Test Notification** for a delivery check. Clicking a notification selects its project and reveals the widget. Hooks are supplied when AgentRouter launches a CLI; enabling notifications does not retrofit hooks into an unrelated running agent.

A finished turn is labelled separately from successful task completion. Some questions and blockers are inferred and labelled accordingly. Structured dialogs and permission requests must be handled in Terminal; AgentRouter does not approve them. See the [support matrix](docs/VERIFICATION.md) for the distinction between implemented mappings and verified live behavior.

## Window and keyboard behavior

**Hide** and the title-bar close button hide only the widget. Quitting AgentRouter also leaves tmux agents running. Reopening the app revalidates their bindings.

Under **Window behavior**, automatic widget opening on copy defaults OFF, and hiding after a successful send defaults ON. The last selected project is remembered.

Optional global **F7/F8/F9** shortcuts open the first three mapped projects. If those keys control media, hold Fn or configure standard function keys in macOS Keyboard settings. AgentRouter does not change those system settings. **Option–Command–R** reveals the widget; optional **Option–Command–1…9** project shortcuts work while the widget receives keyboard input.

## Local storage and safety

AgentRouter uses a private tmux server, `agentrouter-managed-v2`, and targets exact session, pane, process, and run identities. Missing, stale, ambiguous, and unrelated targets are refused. It never executes clipboard contents as shell commands. Clipboard text is passed through a temporary named tmux buffer, and Enter requires an explicit action plus verified readiness.

Settings, bindings, and bounded event metadata live in `~/Library/Application Support/AgentRouter/`. Clipboard previews, replies, and output snapshots stay in memory. The downstream CLIs and tmux retain their normal history and persistence behavior. AgentRouter makes no routing/IPC network requests; the CLIs use their normal network connections. Clipboard-source attribution is a frontmost-application heuristic.

Hooks use an owner-only Unix socket and per-run credentials, not a network port. This is a same-user/controller-process-tree trust boundary, not isolation from malicious software running as the same macOS user. Existing CLI configuration files are not overwritten; native hook-trust policies still apply.

## Development and known limitations

```sh
swift test
# Opt-in installed CLI lifecycle test: no model prompts are submitted.
AGENTROUTER_NATIVE_TESTS=1 swift test --filter NativeCLITests
# Reproduce Finder-like startup conditions using only the installed Codex CLI:
/usr/bin/env PATH=/usr/bin:/bin LC_ALL=C LANG=C \
  AGENTROUTER_NATIVE_TESTS=1 AGENTROUTER_NATIVE_CLI=codex \
  /usr/bin/swift test --filter NativeCLITests
```

Tests use disposable projects and isolated tmux servers. Native CLI checks may display trust or authentication prompts; they do not accept them automatically.

See [architecture](docs/ARCHITECTURE.md), [verification and notification support](docs/VERIFICATION.md), and the [code review with unresolved findings](docs/REVIEW-2026-11-07.md). Known issues include partial-start cleanup, hook tracking when a conversation changes within an existing CLI process, repeated exit notifications after app relaunch, and malformed unrelated pane metadata. Treat this as an experimental source release, not a hardened agent supervisor.

## License

[MIT](LICENSE). Contributions and focused bug reports are welcome. Do not include prompts, credentials, local settings, or private project data in public reports.
