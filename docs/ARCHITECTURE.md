# Architecture

## Components

- `Projects.swift`: projects, launch modes, preferences, persisted bindings and owner-only atomic settings storage.
- `LifecycleManager.swift`: serialized lifecycle operations, exact ownership checks, process health, delivery and event reduction. A private tmux server loads `/dev/null` configuration, leaving ordinary sessions and tmux configuration untouched.
- `ProcessRunner.swift`: argument-based subprocess execution with concurrent pipe draining and a timeout for helper commands. A timeout kills only the helper process, never an agent. Broken pipes become recoverable errors.
- `AgentEvents.swift`: passive native-hook configuration, event interpretation and memory-only question/readiness state.
- `LocalIPC.swift` and `AgentRouterHook`: bounded Unix-socket frames, owner-only directory/socket, kernel peer UID/PID, per-run credential and descendant-process validation. No network listener. The helper strips prompt/transcript data and emits no hook decisions or model instructions.
- `RouterModel`, `RouterWidget`, `Notifications`, `AppDelegate`: main-actor UI, clipboard polling, explicit selection, lifecycle confirmations, native notification delivery/click handling, settings and nonactivating panel. Background health polling does not disable user controls. Hiding orders only the panel out and saves visibility; it does not tear down the model or services. Automatic capture uses the saved opening preference, default OFF, and otherwise only updates a temporary status-item dot. Successful delivery optionally invokes the same hide action, default ON. Notification selection opens the exact project Terminal target and hides the panel on success. Missing projects, busy operations, stale identities and Terminal errors reveal the panel as a fallback; notification clicks do not start controllers or send input.
- `Tmux.swift`: retained Phase 1 transport/validation compatibility; the current UI routes exclusively through the ownership-enforcing lifecycle manager.

## Ownership and lifecycle

Start validates the project and rejects existing names or controller ownership collisions. It creates an inert sleep placeholder, records session/pane/run markers, enables remain-on-exit, and directly respawns that exact newly created pane with `/usr/bin/env` and the CLI executable as separate arguments. No shell evaluates the launch arguments. The placeholder is the only process forcibly replaced during startup.

A binding includes project/run identity, credential, server PID/start time, session ID, pane ID, root process PID/start time, launch mode and launch configuration. Operations enumerate and compare literal identities, require exactly one pane, and inspect the actual CLI process tree. A live tmux server is not proof of a live CLI, and a live CLI is not proof of authentication, idleness or task success.

Stop revalidates the owned process and group leader, persists the stop request, then sends SIGTERM after UI confirmation. A separate confirmation is required for SIGKILL. Restart never escalates; it proceeds only after exit. Removing/editing live launch configuration is refused. Missing old sessions can be started afresh; replacement or ambiguous sessions are never adopted or killed. A partially completed/crashed startup may require manual inspection rather than unsafe recovery.

## Events and submission

The normal Send & Open CLI action captures the latest clipboard on click and snapshots the explicitly selected project. It uses the existing authoritative readiness checks, submits once, and opens the exact bound Terminal session. A stopped CLI requires a startup confirmation; its memory-only prompt waits at most 10 seconds for readiness and is discarded as a pending action on timeout. No automatic project inference or durable prompt queue was added. Failure after successful submission is labelled explicitly to prevent resubmission merely because Terminal failed to open.

The Terminal screen view reads capture-pane from the validated owned pane, checks identity again, and keeps a memory-only snapshot tagged with its project. Copy Screen copies that snapshot without trimming or size limits; selecting another output project disables copying an old mismatched snapshot. This is retained terminal output, not a conversation transcript, and does not modify tmux history or existing sessions.

Accepted hook events must match a live owned run, pane, native session, same-user descendant peer, credential and fresh timestamp. Replay and out-of-order events are rejected. App restart drops all readiness grants. Notifications and history distinguish TURN_FINISHED, COMPLETED, BLOCKED, NEEDS_INPUT, APPROVAL_REQUIRED, UNKNOWN and EXITED; WORKING tracks activity. TaskCompleted means an individual Claude task, not entire-project completion. Explicit textual claims/questions are marked inferred.

Stop, SessionStart, bracketed paste, and an alive process alone never authorize Enter. Only Claude's idle_prompt notification currently grants a short single-use text-input lease. Generation changes, expiry, working events and dialog events revoke it. Structured dialogs and approvals are latched and blocked until a subsequent working signal establishes progress; idle notifications cannot unlock approval input. Input requires an explicit user action and destination/readiness confirmation. The lease is consumed before paste and the identity is checked again before a single Enter.

There is no atomic editor-ready/submit transaction exposed by a generic tmux terminal. External interaction between preflight and delivery remains a race; do not type into the same CLI while sending from the widget. Reliable structured-dialog replies or broader Codex submission readiness need a vendor-supported interaction protocol, rather than more terminal guessing. There is no screen-text readiness heuristic.

## Privacy

Projects/bindings and bounded history metadata persist; clipboard previews, questions and replies do not. History and notification banners omit message bodies. Working directories and repositories are not changed by the router. Native CLIs may maintain their own normal history/configuration and run existing user hooks under their own trust policies. IPC authenticates local controller membership, not a malicious process with full access to the same user's account and credentials.

## Complete latest reply

Authenticated hook events relay native session_id and transcript_path metadata. The binding persists these identifiers, never the reply text. An authenticated SessionStart can transition to another native conversation while clearing readiness and question state. The application reads only owner-owned JSONL files inside the configured vendor history roots, verifies session identity and working directory, and extracts completed assistant reply text. It does not infer the conversation from directory/mtime. Parsing runs off the lifecycle actor; the run, session and exact owned pane are revalidated afterward. File size/mtime caching avoids reparsing unchanged transcripts. No tool output or hidden thinking is copied. The existing tmux screen viewer remains selectable separately and is not represented as a complete reply.

## Optional split display

`SplitWorkspace.swift` manages display clients on the separate `agentrouter-views-v1` server. LifecycleManager verifies both original controller bindings and process health before constructing a split target, and rechecks ownership afterward. Each display pane directly executes a tmux attach client to an exact original session ID. No original controller pane is joined, moved, split or respawned. Ownership markers and the expected two display-client panes are validated before reusing/closing a workspace. Existing layout widths are retained on reopen unless the user chooses Balance 50/50. A restarted controller's run ID invalidates the old display clients, which are replaced only on explicit reopening. The normal Terminal launcher reuses a tab attached to the split workspace where available. Separate project Terminal views remain independent attachments to the same agent. Widget routing never follows the focused display pane automatically.

## Project groups and CLI instances

Workspace stores root Projects plus AgentInstance records (parent project ID,
instance ID/name, CLI executable/kind and unique session). Its controllers projection
produces the launch configuration consumed by the existing ownership-enforcing
lifecycle manager. The root project's original ID is its Main controller ID; extra
instances have independent IDs, bindings and AR_PROJECT hook identities. Shared
working directory, notification preferences and Codex launch choices are resolved
from the parent. Every lifecycle operation still validates an exact controller.

The UI presents root project groups and explicit CLI selectors. Remembered CLI IDs
are validated against their parent before opening; there is no missing-instance
fallback. Menus for individual CLIs and notifications use literal controller IDs.
Removing a parent preflights all affected controllers; only stopped/dead bindings
can be released. The schema accepts version 2 and version 3, defaults missing
instance lists to empty, and writes version 3 when adding instances to prevent
older builds from discarding their metadata.

Split reopening also validates actual nested attachments, not merely a tmux process
name: each display pane's TTY and root PID must match exactly one controller-side
client with the expected session ID. An inner-client session switch is restored to
the requested pair on explicit reopening, with post-attachment verification.
This does not prevent a user from deliberately switching sessions manually while
an already-open split is in use; inner tmux's session/status UI remains authoritative.

## Safe quit and explicit checkpoint export

AppDelegate centralizes ordinary termination in applicationShouldTerminate.
QuitCoordinator owns a single review panel; repeated quit requests reuse it.
RouterModel.quitReviewActive blocks new lifecycle/delivery operations, clipboard
capture, selection/open routes and automatic widget visibility changes. Existing
operations finish normally; the separate busy flag disables final quit/export.
Health polling, hook IPC and notifications continue during review. Cancel releases
the review lock without changing the widget's previous visibility. Explicit quit
authorization exits the app without invoking lifecycle stop or killing tmux.

CheckpointEntry is a whitelisted Sendable export DTO, never a serialized Workspace
or Binding. The model samples every controller in project order and uses the
existing exact-binding/latestReply reader, with explicit unavailable replies and
no screen fallback. State is a sequential snapshot, not a transactional proof of
completion. Markdown formatting and file writes run off the main actor; a private
mkstemp file is synchronized and renamed atomically over the user-selected path.
No settings migration or automatic checkpoint/draft persistence is introduced.

The optional Stop Agents & Quit path snapshots QuitStopTarget identities before
confirmation. The lifecycle actor revalidates run ID, pane ownership, process
start time and process group before signalling. A bounded exit wait checks all
configured controllers, including runs not covered by the original consent;
those new runs prevent quitting and are never auto-stopped. Missing panes count
as stopped only after original-process absence/reuse is verified. Errors remain
visible in the review. A force-stop retry filters fresh identities against the
original confirmed remaining runs and requires a second confirmation. Failed
signal delivery rolls back the stopRequested flag. No kill-session/kill-server
or Terminal window closing is used.
