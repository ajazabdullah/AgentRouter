# Architecture

## Components

- `Projects.swift`: projects, launch modes, preferences, persisted bindings and owner-only atomic settings storage.
- `LifecycleManager.swift`: serialized lifecycle operations, exact ownership checks, process health, delivery and event reduction. A private tmux server loads `/dev/null` configuration, leaving ordinary sessions and tmux configuration untouched.
- `ProcessRunner.swift`: argument-based subprocess execution with concurrent pipe draining and a timeout for helper commands. A timeout kills only the helper process, never an agent. Broken pipes become recoverable errors.
- `AgentEvents.swift`: passive native-hook configuration, event interpretation and memory-only question/readiness state.
- `LocalIPC.swift` and `AgentRouterHook`: bounded Unix-socket frames, owner-only directory/socket, kernel peer UID/PID, per-run credential and descendant-process validation. No network listener. The helper strips prompt/transcript data and emits no hook decisions or model instructions.
- `RouterModel`, `RouterWidget`, `Notifications`, `AppDelegate`: main-actor UI, clipboard polling, explicit selection, lifecycle confirmations, native notification delivery/click handling, settings and nonactivating panel. Background health polling does not disable user controls. Hiding orders only the panel out and saves visibility; it does not tear down the model or services. Automatic capture uses the saved opening preference, default OFF, and otherwise only updates a temporary status-item dot. Successful delivery optionally invokes the same hide action, default ON. Notification selection explicitly reopens the panel after validating the project.
- `Tmux.swift`: retained Phase 1 transport/validation compatibility; the current UI routes exclusively through the ownership-enforcing lifecycle manager.

## Ownership and lifecycle

Start validates the project and rejects existing names or controller ownership collisions. It creates an inert sleep placeholder, records session/pane/run markers, enables remain-on-exit, and directly respawns that exact newly created pane with `/usr/bin/env` and the CLI executable as separate arguments. No shell evaluates the launch arguments. The placeholder is the only process forcibly replaced during startup.

A binding includes project/run identity, credential, server PID/start time, session ID, pane ID, root process PID/start time, launch mode and launch configuration. Operations enumerate and compare literal identities, require exactly one pane, and inspect the actual CLI process tree. A live tmux server is not proof of a live CLI, and a live CLI is not proof of authentication, idleness or task success.

Stop revalidates the owned process and group leader, persists the stop request, then sends SIGTERM after UI confirmation. A separate confirmation is required for SIGKILL. Restart never escalates; it proceeds only after exit. Removing/editing live launch configuration is refused. Missing old sessions can be started afresh; replacement or ambiguous sessions are never adopted or killed. A partially completed/crashed startup may require manual inspection rather than unsafe recovery.

## Events and submission

The normal Send & Open CLI action captures the latest clipboard on click and snapshots the explicitly selected project. It uses the existing authoritative readiness checks, submits once, and opens the exact bound Terminal session. A stopped CLI requires a startup confirmation; its memory-only prompt waits at most 10 seconds for readiness and is discarded as a pending action on timeout. No automatic project inference or durable prompt queue was added. Failure after successful submission is labelled explicitly to prevent resubmission merely because Terminal failed to open.

The output viewer reads capture-pane from the validated owned pane, checks identity again, and keeps a memory-only snapshot tagged with its project. Copy Output copies that snapshot without trimming or size limits; selecting another output project disables copying an old mismatched snapshot. This is retained terminal output, not a conversation transcript, and does not modify tmux history or existing sessions.

Accepted hook events must match a live owned run, pane, native session, same-user descendant peer, credential and fresh timestamp. Replay and out-of-order events are rejected. App restart drops all readiness grants. Notifications and history distinguish TURN_FINISHED, COMPLETED, BLOCKED, NEEDS_INPUT, APPROVAL_REQUIRED, UNKNOWN and EXITED; WORKING tracks activity. TaskCompleted means an individual Claude task, not entire-project completion. Explicit textual claims/questions are marked inferred.

Stop, SessionStart, bracketed paste, and an alive process alone never authorize Enter. Only Claude's idle_prompt notification currently grants a short single-use text-input lease. Generation changes, expiry, working events and dialog events revoke it. Structured dialogs and approvals are latched and blocked until a subsequent working signal establishes progress; idle notifications cannot unlock approval input. Input requires an explicit user action and destination/readiness confirmation. The lease is consumed before paste and the identity is checked again before a single Enter.

There is no atomic editor-ready/submit transaction exposed by a generic tmux terminal. External interaction between preflight and delivery remains a race; do not type into the same CLI while sending from the widget. Reliable structured-dialog replies or broader Codex submission readiness need a vendor-supported interaction protocol, rather than more terminal guessing. There is no screen-text readiness heuristic.

## Privacy

Projects/bindings and bounded history metadata persist; clipboard previews, questions and replies do not. History and notification banners omit message bodies. Working directories and repositories are not changed by the router. Native CLIs may maintain their own normal history/configuration and run existing user hooks under their own trust policies. IPC authenticates local controller membership, not a malicious process with full access to the same user's account and credentials.
