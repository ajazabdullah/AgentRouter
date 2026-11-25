import XCTest
@testable import RouterCore

final class ClaudeChannelTests: XCTestCase {
    func testOptInIsBackwardCompatibleAndInheritedByAdditionalClaude() throws {
        let original = Project(name: "Legacy", directory: "/private/tmp", cli: .claude)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        data.removeValue(forKey: "claudeChannel")
        let legacy = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertNil(legacy.claudeChannel)
        var enabled = legacy; enabled.claudeChannel = true
        var workspace = Workspace(projects: [enabled])
        workspace.instances = [AgentInstance(projectID: enabled.id, name: "Claude 2", cli: .claude, executable: enabled.executable)]
        XCTAssertEqual(workspace.controllers.last?.claudeChannel, true)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(enabled)).claudeChannel, true)
    }
    actor ReceiptFixture {
        var received: [String: String] = [:]
        var acknowledged = false
        var statusDelay: Duration = .zero
        var statusCalls = 0
        func delayStatus(_ duration: Duration) { statusDelay = duration }
        func handle(_ data: Data) async -> Bool {
            guard let request = try? JSONDecoder().decode([String: String].self, from: data), let id = request["id"] else { return false }
            switch request["operation"] {
            case "ready": return true
            case "submit": received[id] = request["text"]; return true
            case "status":
                statusCalls += 1
                try? await Task.sleep(for: statusDelay)
                return acknowledged && received[id] != nil
            default: return false
            }
        }
        func acknowledge() { acknowledged = true }
    }
    func testRunBoundDeliverySurvivesAppRecreationAndBlocksResendUntilAcknowledged() async throws {
        let f = try LifecycleTests.Fixture(cli: .claude); defer { f.cleanup() }
        var p = f.project; p.claudeChannel = true
        try f.store.save(Workspace(projects: [p]))
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/AgentRouterHook").path
        let manager = try LifecycleManager(store: f.store, socket: f.socket, hookHelper: helper)
        try await manager.start(p.id)
        for _ in 0..<50 {
            if try await manager.health()[p.id]?.agentHealthy == true { break }
            try await Task.sleep(for: .milliseconds(80))
        }
        let health = try await manager.health()[p.id]
        XCTAssertEqual(health?.agentHealthy, true)
        let snapshot = await manager.snapshot()
        let binding = try XCTUnwrap(snapshot.bindings[p.id.uuidString])
        let receipt = ReceiptFixture()
        let server = try HookServer(path: ClaudeChannel.socket(run: binding.runID)) { data, _ in await receipt.handle(data) }
        defer { server.stop(); try? FileManager.default.removeItem(at: ClaudeChannel.directory(run: binding.runID)) }
        for oversized in [String(repeating: "x", count: 65536), String(repeating: "\"", count: 33000)] {
            XCTAssertNoThrow(try Tmux.validateText(oversized))
            do { try await manager.sendChannel(oversized, projectID: p.id); XCTFail("Encoded envelope must be rejected") } catch {}
            let rejected = await manager.snapshot()
            XCTAssertNil(rejected.bindings[p.id.uuidString]?.pendingChannelMessage)
            XCTAssertNil(try f.store.load(defaults: []).bindings[p.id.uuidString]?.pendingChannelMessage)
        }
        let before = await receipt.received
        XCTAssertTrue(before.isEmpty, "Rejected frames must not reach helper")
        try await manager.sendChannel("literal prompt", projectID: p.id)
        let pendingSnapshot = await manager.snapshot()
        XCTAssertNotNil(pendingSnapshot.bindings[p.id.uuidString]?.pendingChannelMessage)
        let recreated = try LifecycleManager(store: f.store, socket: f.socket, hookHelper: helper)
        do { try await recreated.sendChannel("do not duplicate", projectID: p.id); XCTFail("Must block unacknowledged resend") } catch {}
        await receipt.acknowledge()
        await receipt.delayStatus(.milliseconds(1500))
        _ = try await recreated.health()
        for _ in 0..<50 {
            if await receipt.statusCalls > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let startedCalls = await receipt.statusCalls
        XCTAssertEqual(startedCalls, 1)
        let start = Date()
        _ = await recreated.snapshot()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "Receipt timeout must not occupy lifecycle actor")
        _ = try await recreated.health()
        let inFlightCalls = await receipt.statusCalls
        XCTAssertEqual(inFlightCalls, 1, "Overlapping health calls must share one in-flight receipt poll")
        for _ in 0..<100 {
            if await recreated.snapshot().bindings[p.id.uuidString]?.pendingChannelMessage == nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let final = await recreated.snapshot()
        XCTAssertNil(final.bindings[p.id.uuidString]?.pendingChannelMessage)
        XCTAssertEqual(final.history.last?.kind, .messageReceived)
        let received = await receipt.received
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.values.first, "literal prompt")
        // A slow reply must not delay Stop or clear pending state after stopping.
        try await recreated.sendChannel("second prompt", projectID: p.id)
        _ = try await recreated.health()
        for _ in 0..<50 {
            if await receipt.statusCalls > 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stopStart = Date()
        try await recreated.stop(p.id, confirmedInterrupt: true)
        XCTAssertLessThan(Date().timeIntervalSince(stopStart), 1, "Stop must not wait for receipt socket timeout")
        try await Task.sleep(for: .milliseconds(1700))
        let stopped = await recreated.snapshot()
        XCTAssertTrue(stopped.bindings[p.id.uuidString]?.stopRequested == true)
        XCTAssertNotNil(stopped.bindings[p.id.uuidString]?.pendingChannelMessage, "Late receipt after Stop must be ignored")
        XCTAssertEqual(stopped.history.filter { $0.kind == .messageReceived }.count, 1)
    }
    func testEncodedFrameBoundaryIncludesEscapingAndEnvelope() throws {
        let token = String(repeating: "x", count: 72), id = UUID().uuidString
        let overhead = try ClaudeChannel.encodeRequest(credential: token, operation: "submit", id: id, text: "").count
        let boundary = String(repeating: "a", count: LocalIPC.maximumBytes - overhead)
        XCTAssertEqual(try ClaudeChannel.encodeRequest(credential: token, operation: "submit", id: id, text: boundary).count, LocalIPC.maximumBytes)
        XCTAssertThrowsError(try ClaudeChannel.encodeRequest(credential: token, operation: "submit", id: id, text: boundary + "a"))
        XCTAssertThrowsError(try ClaudeChannel.encodeRequest(credential: token, operation: "submit", id: id, text: String(repeating: "\"", count: 33000)))
    }
    func testLaunchConfigContainsOnlyRunScopedHelperAndNoPermissionBypass() throws {
        let args = try ClaudeChannel.arguments(helper: "/usr/bin/true", run: UUID().uuidString, credential: "test")
        XCTAssertTrue(args.contains("server:agentrouter"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args[1].utf8)) as? [String: Any])
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["agentrouter"])
        XCTAssertThrowsError(try ClaudeChannel.arguments(helper: "/not/installed", run: "x", credential: "test"))
        XCTAssertLessThan(ClaudeChannel.socket(run: UUID().uuidString).utf8.count, 104)
    }
}
