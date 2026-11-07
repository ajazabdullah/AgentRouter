import XCTest
import Darwin
@testable import RouterCore

final class EventTests: XCTestCase {
    func testHookSemanticsNeverEquateTurnWithTaskCompletion() {
        func payload(_ event: String, _ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
            extra.merging(["hook_event_name": .string(event)]) { _, b in b }
        }
        for cli in CLIKind.allCases {
            XCTAssertEqual(HookAdapter.interpret(payload("Stop"), cli: cli).kind, .turnFinished)
            XCTAssertFalse(HookAdapter.interpret(payload("Stop"), cli: cli).idleTextEditor)
            XCTAssertEqual(HookAdapter.interpret(payload("PermissionRequest"), cli: cli).kind, .approvalRequired)
            XCTAssertTrue(HookAdapter.interpret(payload("PermissionRequest"), cli: cli).modal)
            XCTAssertEqual(HookAdapter.interpret(payload("UnknownVendorEvent"), cli: cli).kind, .unknown)
            let question = HookAdapter.interpret(payload("Stop", ["last_assistant_message": .string("Which folder?")]), cli: cli)
            XCTAssertEqual(question.kind, .needsInput)
            XCTAssertTrue(question.evidence.contains("inferred"))
            XCTAssertFalse(question.idleTextEditor)
        }
        let complete = HookAdapter.interpret(payload("TaskCompleted"), cli: .claude)
        XCTAssertEqual(complete.kind, .completed)
        XCTAssertTrue(complete.evidence.contains("individual task"))
        XCTAssertEqual(HookAdapter.interpret(payload("TaskCompleted"), cli: .codex).kind, .unknown)
        XCTAssertEqual(HookAdapter.interpret(payload("StopFailure"), cli: .claude).kind, .blocked)
        XCTAssertFalse(HookAdapter.interpret(payload("Notification", ["notification_type": .string("elicitation_dialog")]), cli: .claude).idleTextEditor)
        XCTAssertTrue(HookAdapter.interpret(payload("Notification", ["notification_type": .string("idle_prompt")]), cli: .claude).idleTextEditor)
    }
    func testAuthenticatedEventsAndFailClosedSubmission() async throws {
        let f = try LifecycleTests.Fixture(cli: .claude); defer { f.cleanup() }
        try await f.manager.start(f.project.id); try await f.wait(.running)
        let snapshot = await f.manager.snapshot()
        let b = try XCTUnwrap(snapshot.bindings[f.project.id.uuidString])
        func envelope(_ event: String, extra: [String: JSONValue] = [:]) throws -> Data {
            let payload = extra.merging(["hook_event_name": .string(event), "session_id": .string("native-main")]) { _, b in b }
            return try JSONEncoder().encode(HookEnvelope(projectID: f.project.id, runID: b.runID, credential: b.credential, paneID: b.paneID, payload: payload))
        }
        let working = try envelope("UserPromptSubmit")
        let rejectedPeer = await f.manager.ingest(working, peerPID: getpid())
        XCTAssertFalse(rejectedPeer)
        let accepted = await f.manager.ingest(working, peerPID: b.pid)
        XCTAssertTrue(accepted)
        let duplicate = await f.manager.ingest(working, peerPID: b.pid)
        XCTAssertFalse(duplicate)
        var wrong = try JSONDecoder().decode(HookEnvelope.self, from: envelope("Stop"))
        wrong.credential = "wrong"
        let wrongToken = await f.manager.ingest(try JSONEncoder().encode(wrong), peerPID: b.pid)
        XCTAssertFalse(wrongToken)
        wrong.credential = b.credential; wrong.runID = "stale"
        let wrongRun = await f.manager.ingest(try JSONEncoder().encode(wrong), peerPID: b.pid)
        XCTAssertFalse(wrongRun)
        let question = await f.manager.ingest(try envelope("Stop", extra: ["last_assistant_message": .string("SECRET-QUESTION: Which folder?")]), peerPID: b.pid)
        XCTAssertTrue(question)
        var activity = await f.manager.activities()[f.project.id]
        XCTAssertEqual(activity?.kind, .needsInput)
        XCTAssertFalse(activity?.canSubmit(now: Date()) ?? true)
        let idle = await f.manager.ingest(try envelope("Notification", extra: ["notification_type": .string("idle_prompt")]), peerPID: b.pid)
        XCTAssertTrue(idle)
        activity = await f.manager.activities()[f.project.id]
        XCTAssertTrue(activity?.canSubmit(now: Date()) == true)
        try await f.manager.paste("synthetic reply", projectID: f.project.id, confirmedReady: true, submit: true, replyingTo: activity?.questionID)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("received.bin")), Data("\u{1b}[200~synthetic reply\u{1b}[201~\r".utf8))
        do { try await f.manager.paste("duplicate", projectID: f.project.id, confirmedReady: true, submit: true); XCTFail("Lease must be consumed") } catch {}
        let approval = await f.manager.ingest(try envelope("PermissionRequest"), peerPID: b.pid)
        XCTAssertTrue(approval)
        do { try await f.manager.paste("yes", projectID: f.project.id, confirmedReady: true); XCTFail("Never paste into approvals") } catch {}
        let disk = try String(contentsOf: f.store.url, encoding: .utf8)
        XCTAssertFalse(disk.contains("SECRET-QUESTION")); XCTAssertFalse(disk.contains("synthetic reply"))
        let persisted = try f.store.load(defaults: [])
        XCTAssertEqual(persisted.history.map(\.kind), [.needsInput, .needsInput, .approvalRequired])
    }
    func testRealHelperToUnixSocketAndPeerAncestry() async throws {
        for cli in CLIKind.allCases {
        let f = try LifecycleTests.Fixture(cli: cli); defer { f.cleanup() }
        var project = f.project
        project.notifications.enabled = true
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/AgentRouterHook").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Build AgentRouterHook first") }
        try helper.write(to: f.directory.appendingPathComponent("helper-path"), atomically: true, encoding: .utf8)
        let path = f.directory.appendingPathComponent("events.sock").path
        let m = try LifecycleManager(store: f.store, defaults: [project], socket: f.socket, hookHelper: helper, ipcPath: path)
        let server = try HookServer(path: path) { data, pid in await m.ingest(data, peerPID: pid) }
        defer { server.stop() }
        try await m.start(f.project.id)
        let payload = "{\"hook_event_name\":\"Stop\",\"session_id\":\"main\",\"last_assistant_message\":\"Synthetic turn ended\",\"prompt\":\"DO-NOT-STORE\"}"
        try payload.write(to: f.directory.appendingPathComponent("hook.json"), atomically: true, encoding: .utf8)
        var received = false
        for _ in 0..<60 {
            if await m.activities()[f.project.id]?.kind == .turnFinished { received = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(received, "A descendant helper should authenticate through the Unix socket")
        let queued = await m.drainNotifications()
        XCTAssertEqual(queued.map(\.kind), [.turnFinished], "\(cli.title) Stop must queue its native notification")
        XCTAssertFalse(try String(contentsOf: f.store.url, encoding: .utf8).contains("DO-NOT-STORE"))
        XCTAssertThrowsError(try HookServer(path: path) { _, _ in true }, "Second listener must not replace a live one")
        }
    }

    func testInvocationOnlyHookConfiguration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ar-config-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let codex = try HookConfiguration.arguments(for: .codex, helper: "/test path/AgentRouterHook", directory: folder)
        XCTAssertFalse(codex.joined().contains("bypass"))
        XCTAssertTrue(codex.contains { $0.hasPrefix("hooks.PermissionRequest=") })
        let claude = try HookConfiguration.arguments(for: .claude, helper: "/test path/AgentRouterHook", directory: folder)
        XCTAssertEqual(claude.first, "--settings")
        let settings = try String(contentsOfFile: claude[1], encoding: .utf8)
        XCTAssertTrue(settings.contains("PermissionRequest"))
        XCTAssertFalse(settings.contains("permissionDecision"))
    }
}
