# Verification — 2026-11-06

## Verification scope

Some workflow changes originally received compilation checks only. Later targeted lifecycle and installed-UI checks are documented in [the code review](REVIEW-2026-11-07.md). These checks do not establish that every vendor event produces a reliable notification in a live model turn.

Recorded development environment: macOS 26.1, Apple Silicon, Xcode 26.2, Swift 6.2.3, tmux 3.8, Codex 0.166.0, Claude Code 2.1.319.

## Automatically checked

- Release app and signed hook helper build successfully. The main regression run executed 11 tests: 10 passed, 1 opt-in real-CLI test skipped, no failures.
- The opt-in installed-CLI test was run separately and passed for both Codex and Claude: owned process stayed alive after startup, generated arguments/configuration were accepted, exact attach commands were produced, and shutdown was requested. No prompts were submitted; no trust or login dialogs were accepted. Claude displayed a trust prompt. Neither run established hook-driven input readiness.
- Disposable fixtures verify start, duplicate refusal, automatic pane binding, settings persistence, stop confirmation, restart, fresh/resume mode distinction, stale-session recovery, exact Unicode/multiline delivery, and refusal to target/stop unowned or extra-pane sessions.
- Authenticated hook tests verify Unix-socket transport, same-user descendant identity, run credentials, replay rejection, event classification, notification queueing, permission-dialog refusal, and single-use submission readiness. Fixture reply delivery matches the exact bracketed text plus one Enter.
- Running-app smoke check: added and started a disposable project, automatically bound its pane, opened its exact tmux session, sent a synthetic reply from the widget, stopped the controller with confirmation, and removed the disposable project. Received reply bytes matched exactly. Existing project settings were retained.
- Native notification authorization now reports **authorized**. A test request was accepted without errors and appeared in `UNUserNotificationCenter`'s delivered-notification list. This supersedes the earlier authorization failure.
- Visibility update: the new build launched with no floating window; explicit reopen revealed it. The UI confirms **Show widget automatically when copying = OFF** and **Hide widget after sending = ON**. Hide persisted `widgetVisible = 0`, and AgentRouter remained running. Visibility inspection through desktop automation can itself reopen the app, so the final hidden-state check read the saved flag without another UI activation.

## Manually confirmed

The user clicked the delivered Project 1 test notification and confirmed that AgentRouter reopened with **Project 1** selected. This confirms native notification click navigation on this machine.

## Notification support and limits

The table describes implemented native-event mappings. Apart from the native delivery/click check above, vendor turn-event generation was exercised with disposable hook fixtures, not authenticated live model turns. Do not treat fixture success as proof that a vendor's hooks have been trusted or enabled in a particular real session.

| Status | Codex | Claude Code |
| --- | --- | --- |
| TURN_FINISHED | Native Stop mapping; not overall completion | Native Stop mapping; not overall completion |
| APPROVAL_REQUIRED | Native PermissionRequest mapping; widget input blocked | PermissionRequest / permission notification mapping; widget input blocked |
| NEEDS_INPUT | Final-message question inference; dedicated structured question coverage not established | AskUserQuestion / input-dialog notifications mapped; generic terminal replies to dialogs blocked |
| COMPLETED | Explicit final-message claim can be labelled inferred; no generic verified task-completion event | TaskCompleted identifies an individual tracked task; whole-project completion remains unverified |
| BLOCKED | Explicit blocker claim can be labelled inferred; no general semantic blocker hook | StopFailure identifies a failed turn; semantic blockers otherwise inferred from explicit claims |
| UNKNOWN | Unclassified signals, missing trust/readiness, lost connection | Same |
| EXITED | Owned pane/process exit monitoring | Same |
| Send & Submit readiness | Not established by the current hook adapter; disabled | Native idle_prompt may grant a short lease if pane identity, terminal state and output generation remain verified |

Reliable native turn-to-banner checks on real agents still require completing normal CLI authentication/workspace trust and, where requested, Codex hook review. No trust bypass, automatic approval, production configuration overwrite, or terminal-text readiness guessing was used.

## Remaining manual checks

- Copy from each actual desktop app while typing elsewhere; confirm focus stays there and the full widget remains hidden with automatic opening off. Only the temporary AR dot should appear.
- Check AR toggling, title-bar close, and Hide during an actual agent run; monitoring should continue. Hide-after-send uses the same hide action after successful prompt/reply delivery.
- Test a real trusted CLI turn and a structured question/approval. Questions and approvals must not silently become plain text submissions.
- Terminal's UI could not be inspected because desktop automation denied access for safety reasons; the Open action's exact-session attachment was verified through tmux client metadata.

Synthetic UI smoke-test history may remain clearly labelled with the removed disposable project. Production settings/history were not erased as part of cleanup.
