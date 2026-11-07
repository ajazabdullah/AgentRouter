import XCTest
@testable import RouterCore

final class NativeCLITests: XCTestCase {
    func testInstalledCLIsStartupWithoutPrompts() async throws {
        guard ProcessInfo.processInfo.environment["AGENTROUTER_NATIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in real CLI startup: AGENTROUTER_NATIVE_TESTS=1 swift test --filter NativeCLITests") }
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/AgentRouterHook").path
        for cli in CLIKind.allCases {
            if let selected = ProcessInfo.processInfo.environment["AGENTROUTER_NATIVE_CLI"], selected != cli.rawValue { continue }
            guard !cli.detectedPath.isEmpty else { XCTFail("\(cli.title) not installed"); continue }
            let directory = URL(fileURLWithPath: "/private/tmp/ar-native-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let socket = "ar-native-" + UUID().uuidString
            defer {
                _ = try? ProcessRunner.run("/opt/homebrew/bin/tmux", ["-L", socket, "kill-server"])
                try? FileManager.default.removeItem(at: directory)
            }
            let p = Project(name: "Disposable native \(cli.title)", directory: directory.path, cli: cli, session: "native")
            let m = try LifecycleManager(store: ProjectStore(url: directory.appendingPathComponent("settings.json")), defaults: [p], socket: socket, hookHelper: helper, ipcPath: directory.appendingPathComponent("e.sock").path)
            let server = try HookServer(path: directory.appendingPathComponent("e.sock").path) { data, pid in await m.ingest(data, peerPID: pid) }
            defer { server.stop() }
            try await m.start(p.id)
            var verified = false
            for _ in 0..<80 {
                let state = try await m.health()[p.id]
                if state?.agentHealthy == true { verified = true; break }
                if state?.state == .failed || state?.state == .stopped { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(verified, "Installed \(cli.title) must launch as the owned CLI process")
            // Wait for initialization without supplying a prompt or acknowledging any trust/login dialogs.
            try await Task.sleep(for: .seconds(2))
            let settledHealth = try await m.health()[p.id]
            XCTAssertTrue(settledHealth?.agentHealthy == true, "Installed CLI must remain alive after startup")
            let snapshot = await m.snapshot()
            let b = try XCTUnwrap(snapshot.bindings[p.id.uuidString])
            let screen = try ProcessRunner.run("/opt/homebrew/bin/tmux", ["-L", socket, "capture-pane", "-p", "-t", b.paneID]).output
            if settledHealth?.agentHealthy != true {
                print("Disposable startup failure: \(screen.prefix(3000))")
            }
            XCTAssertFalse(screen.contains("error parsing config"), "Generated hook configuration must be accepted")
            XCTAssertFalse(screen.contains("unexpected argument"), "Generated launch arguments must be accepted")
            let activity = await m.activities()[p.id]
            print("Native \(cli.title): processVerified=\(verified), hookSignal=\(activity?.evidence ?? "none"), submitReady=\(activity?.canSubmit(now: Date()) ?? false), startupScreenBytes=\(screen.utf8.count), mentionsTrust=\(screen.lowercased().contains("trust")), mentionsHooks=\(screen.lowercased().contains("hook")), mentionsLogin=\(screen.lowercased().contains("sign in") || screen.lowercased().contains("login"))")
            let attach = try await m.terminalCommand(p.id)
            XCTAssertTrue(attach.contains(b.sessionID))
            // Exercise the actual installed CLI after Stop -> Start and Stop -> Restart.
            // Run this test with PATH=/usr/bin:/bin to reproduce Finder's environment.
            var previousRun = b.runID
            for restarting in [false, true] {
                try await m.stop(p.id, confirmedInterrupt: true)
                var stopped = false
                for _ in 0..<80 {
                    if try await m.health()[p.id]?.paneDead == true { stopped = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTAssertTrue(stopped, "Installed CLI must stop gracefully before replacement")
                guard stopped else { return }
                if restarting { try await m.restart(p.id, mode: .fresh) }
                else { try await m.start(p.id, mode: .fresh) }
                try await Task.sleep(for: .seconds(2))
                let health = try await m.health()[p.id]
                XCTAssertEqual(health?.agentHealthy, true, "Installed CLI must survive \(restarting ? "Restart" : "Start after Stop")")
                let next = await m.snapshot()
                let bound = try XCTUnwrap(next.bindings[p.id.uuidString])
                XCTAssertNotEqual(previousRun, bound.runID)
                previousRun = bound.runID
                let output = try await m.captureOutput(p.id)
                XCTAssertFalse(output.contains("env: node: No such file or directory"))
                let target = try await m.terminalTarget(p.id)
                XCTAssertTrue(target.command.contains(bound.sessionID))
            }
            try await m.stop(p.id, confirmedInterrupt: true)
        }
    }
}
