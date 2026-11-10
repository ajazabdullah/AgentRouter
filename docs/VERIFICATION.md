# Verification

## Split View update — 2026-11-10

The optional two-project display workspace compiled successfully in the release
app. The Applications copy was updated without launching it or stopping existing
agents. No unit tests, integration tests, desktop automation or runtime tmux
operations were run for this change. The checks below remain manual and are not
claimed as passing results:

- Open a split for two already-running projects; confirm both display panes show
  the intended existing agents and standalone Open Terminal still works.
- Drag the divider, resize Terminal and use Balance 50/50; confirm both CLIs redraw.
- Reopen the same pair; confirm its existing Terminal attachment and layout are
  reused. Close Split View and confirm both agents continue running separately.
- Confirm AgentRouter's routing Destination stays explicit when clicking either
  display pane; split-pane focus must not reroute clipboard sends.

The split lives on `agentrouter-views-v1`; controllers remain on
`agentrouter-managed-v2`. Only view-client panes are created/replaced/closed by the
split controls. Manually changed view workspaces are refused.

## Earlier verification — 2026-11-06

## Latest workflow update

Send & Open CLI, bounded start-and-send, exact-pane output viewing and verbatim Copy Output were added as a focused change. At the user's request, no unit/integration/UI tests, desktop automation, app launch, tmux interaction or manual runtime verification were performed for this update. Only one compilation build was requested. Results below describe earlier work and are not runtime verification of the new workflow.

Environment: macOS 26.1, Apple Silicon, Xcode 26.2, Swift 6.2.3, tmux 3.8, Codex 0.166.0, Claude Code 2.1.319.

## Automatically checked

- Release app and signed hook helper build successfully. The main regression run executed 11 tests: 10 passed, 1 opt-in real-CLI test skipped, no failures.
- The opt-in installed-CLI test was run separately and passed for both Codex and Claude: owned process stayed alive after startup, generated arguments/configuration were accepted, exact attach commands were produced, and shutdown was requested. No prompts were submitted; no trust or login dialogs were accepted. Claude displayed a trust prompt. Neither run established hook-driven input readiness.
- Disposable fixtures verify start, duplicate refusal, automatic pane binding, settings persistence, stop confirmation, restart, fresh/resume mode distinction, stale-session recovery, exact Unicode/multiline delivery, and refusal to target/stop unowned or extra-pane sessions.
- Authenticated hook tests verify Unix-socket transport, same-user descendant identity, run credentials, replay rejection, event classification, notification queueing, permission-dialog refusal, and single-use submission readiness. Fixture reply delivery matches the exact bracketed text plus one Enter.
- Running-app smoke check: added and started a disposable project, automatically bound its pane, opened its exact tmux session, sent a synthetic reply from the widget, stopped the controller with confirmation, and removed the disposable project. Received reply bytes matched exactly. Existing project settings were retained.
- Native notification authorization now reports **authorized**. Test request `70200164-6747-46E2-8C89-F6039469298D` was accepted without errors and appeared in `UNUserNotificationCenter`'s delivered-notification list. This supersedes the earlier authorization failure.
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

## Multiple CLIs per project — 2026-11-10

A read-only Codex review was requested and performed with GPT-6.1 Sol, medium effort,
on the multi-CLI diff. It found one P2: shared Codex permission selectors were
hidden when Main was Claude and an extra CLI was Codex. The condition was corrected
to show them for either a Codex Main or any Codex child. No other concrete findings
were reported; the reviewer did not run tests, builds, apps or tmux commands.

This change is receiving a compilation check only. No native CLI sessions, saved
settings or running application were manipulated for runtime verification. Manual
checks remain: migration retaining Main; spawning/selecting mixed CLIs through the
widget and AR; per-instance routing/lifecycle isolation; shared-directory edit and
removal guards; last-CLI memory; notification navigation and same-project Split View.

Compilation result: the first release build reached SwiftUI's expression
complexity limit in RouterWidget. Project selectors and project rows were extracted
into smaller view components without changing their behavior. The user approved
one additional compilation, which passed in 6.89 seconds. No tests or runtime
session operations were performed. The reviewer did not independently re-review
the fix/refactor; successful compilation does not verify multi-CLI runtime behavior.

## Follow-up split target-identity finding

A separate read-only review of committed versions reported P2: the display pane's
`tmux` command name and unchanged controller run IDs did not prove which session
the nested client was actually showing. A user could switch the inner client via
Ctrl-b s, then reopen the pair and retain another controller under the old label.
This was a code-inspection finding, not runtime-reproduced in this session.

The source now matches each outer display pane's TTY and root PID against the
controller server's actual client TTY, client PID and session ID before reuse.
A mismatch causes only the display clients to be reattached to their exact expected
sessions. After reattachment, a short bounded registration check must succeed
before returning a Terminal target; missing or ambiguous identities fail closed.
No agent pane, controller process, hook configuration or prompt is modified.

This follow-up has not been built or runtime-tested. The previous compilation
allowance was exhausted; an additional build requires the user's approval.

The user subsequently approved one compilation and installation for this follow-up.
The release build passed in 12.25 seconds, and the Applications bundle was replaced
without launching it or stopping apps/agents. No runtime tests or live tmux queries
were performed, so the redirected-pane scenario remains a manual verification item.

## Safe quit and local checkpoint (2026-11-10)

Read-only GPT-6.1 Sol medium review found two P2 issues: external selection routes
could change the target during review, and finishing sends could hide the widget.
Both were fixed with review guards on selection/external routes and widget
visibility changes. The reviewer reread the fixes and reported no remaining concrete
findings in this feature's scope. This is static review, not runtime verification.

No unit, integration or UI tests, app launches, desktop automation, live tmux
queries, or session changes were performed for this feature. Manual checks remain:

- Quit from widget, AR menu and Cmd-Q with an active/unknown CLI, drafts or open settings;
  inspect states, cancel, and confirm the widget retains its prior visibility.
- Quit while an operation finishes: final quit/export stay disabled; new actions
  cannot start; hooks/history continue. Repeat quit requests reuse one review.
- Export all configured CLIs, including stopped/extra instances; inspect identities,
  complete available replies and unavailable markers. Check file mode 0600, then
  cancel save or try an unwritable path; the app stays open and reports failures.
- After successful export, verify the review stays open. Choose Keep Running & Quit,
  confirm agents remain in Terminal and AR notifications stop. Reopen AgentRouter.
- With all CLIs verified stopped and no drafts/settings/operations, quit immediately.

Build result: the sandbox blocked Swift's compiler cache before source compilation.
The authorized compilation outside the sandbox passed in 22.71 seconds and produced
the signed `.build/AgentRouter.app` bundle. One non-fatal deprecation warning remains
for `String(cString:)` in the temporary-file path conversion. No further compilation
or runtime verification was performed.

## Widget readability and layout refresh (2026-11-10)

The widget uses Workspace, Projects, History and Settings navigation, separate
cards, larger controls, 13 pt minimum supporting text and 14 pt body/output text.
Project management stays expanded on its page; settings use a scrolling sheet
with fixed Save/Cancel controls. Existing model actions and confirmation/readiness
checks are reused. Project counts now distinguish running and configured CLIs.

One requested screenshot attempt failed because the native computer-use connection
could not start; no screenshot was obtained and desktop automation was not retried.
One release compilation passed in 16.55 seconds. No tests, app launch, or tmux
queries/changes were performed. Visual layout, keyboard navigation, scrolling and
tab interactions remain for manual verification after reopening the app.

## Stop Agents & Quit and larger type (2026-11-10)

Claude Sonnet (`claude-sonnet-5-5`), medium effort, performed a read-only review.
It found missing sessions blocking shutdown, stale names in the force-stop list,
and stale stopRequested state after failed signals. These were addressed with
original-process checks for missing panes, freshly narrowed force targets, and
stop-flag rollback. Identity-verification errors are retried during the bounded
exit wait and never counted as stopped. The reviewer did not re-review the fixes.

Typography now uses 15 pt supporting text and 16 pt body/output, with larger
headings, a 640 pt widget and separate rows for lifecycle controls. No tests,
app launches, desktop automation or live session changes were performed.
Manual checks: cancel graceful/force confirmations; stop multiple disposable
CLIs; a refused graceful stop stays open; explicitly confirmed force stop affects
only remaining original runs; a restarted run/unowned collision is rejected;
missing sessions with surviving original processes block quit; existing keep-running,
checkpoint and larger-font navigation continue to work.

The single release compilation passed in 23.46 seconds. The existing non-fatal
String(cString:) deprecation warning in Checkpoint.swift remains. The compiled
bundle was installed without launching it; runtime shutdown and visual behavior
remain unverified.

## Destination-control redundancy cleanup (2026-11-10)

Workspace keeps the routing destination/CLI selectors and Open CLI. Projects uses
the selectable project list, then a selected-project heading and management CLI
selector instead of another destination dropdown. Add Project, Project Settings,
New CLI and Start Agent live on Projects. The send action's verified startup offer
and independent output selector remain. One release compilation passed in 15.65
seconds; no tests, app launch, automation or live-session changes were performed.

## Merged project workspace and design demo (2026-11-10)

The main view now shows project rows with CLI chips, a prompt/send area and output.
Destination and independent output dropdowns were removed; output follows the
explicit selected controller. Each project gear selects its remembered controller
without opening Terminal and opens lifecycle/configuration controls and split
view settings. Header buttons open history/app preferences with Back navigation.
New views reuse existing lifecycle, routing, readiness and confirmation logic.

The user confirmed AR reappeared after quitting other menu-bar apps, consistent
with crowding. Existing AR/active-project item behavior was preserved. The local
interactive demo and layout.json use sample data only. No tests, live-session
queries or app launch were performed; the demo was inspected as source, not
browser-rendered. Runtime layout and keyboard behavior remain manual checks.

The single release compilation passed in 10.42 seconds. The bundle was installed
without launching AgentRouter or changing any CLI session.
