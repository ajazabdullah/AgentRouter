import XCTest
@testable import RouterCore

final class LifecycleTests: XCTestCase {
    func testInteractiveAgentIgnoresInheritedNoColorWithoutChangingServer() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        XCTAssertEqual(try f.tmux(["new-session", "-d", "-s", "seed", "/bin/sleep", "86400"]).status, 0)
        XCTAssertEqual(try f.tmux(["set-environment", "-g", "NO_COLOR", "1"]).status, 0)
        try await f.manager.start(f.project.id)
        try await f.wait(.running)
        XCTAssertEqual(try String(contentsOf: f.directory.appendingPathComponent("color-environment.txt"), encoding: .utf8), "enabled")
        let output = try await f.manager.captureOutput(f.project.id, includeColors: true)
        XCTAssertTrue(output.contains("\u{1B}[31m"))
        XCTAssertTrue(output.contains("COLOR"))
        XCTAssertEqual(try f.tmux(["show-environment", "-g", "NO_COLOR"]).output.trimmingCharacters(in: .whitespacesAndNewlines), "NO_COLOR=1")
    }
    func testPaneIdentityParsingPreservesEmptyFieldsAndLineEndings() throws {
        let fields = ["controller_with_underscores", "$1", "%2", "123:456", "project", "run", "run", "789", "0", "1", "0", "0", "", ""]
        let row = fields.joined(separator: "|")
        for newline in ["\n", "\r\n"] {
            let panes = try LifecycleManager.parsePanes(row + newline + row + newline)
            XCTAssertEqual(panes.count, 2)
            XCTAssertEqual(panes[0].pid, 789)
            XCTAssertEqual(panes[0].session, "controller_with_underscores")
            XCTAssertEqual(panes[0].paneID, "%2")
            XCTAssertEqual(panes[0].exitStatus, "")
            XCTAssertEqual(panes[0].outputGeneration, "")
        }
        XCTAssertThrowsError(try LifecycleManager.parsePanes("invalid\n"))
        var invalid = fields; invalid[7] = "not-a-pid"
        XCTAssertThrowsError(try LifecycleManager.parsePanes(invalid.joined(separator: "|")))
        invalid[7] = ""; invalid[8] = "1"
        XCTAssertTrue(try XCTUnwrap(LifecycleManager.parsePanes(invalid.joined(separator: "|")).first).dead)
    }
    struct Fixture {
        let directory: URL
        let store: ProjectStore
        let socket: String
        let project: Project
        let manager: LifecycleManager
        init(cli: CLIKind = .codex) throws {
            directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ar-life-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/agent.c")
            let binary = directory.appendingPathComponent(cli.rawValue).path
            let compile = try ProcessRunner.run("/usr/bin/clang", [source.path, "-o", binary])
            guard compile.status == 0 else { throw RouterError.message(compile.error) }
            store = ProjectStore(url: directory.appendingPathComponent("state.json"))
            socket = "ar-life-" + UUID().uuidString
            project = Project(name: "Disposable \(cli.title)", directory: directory.path, cli: cli, executable: binary, session: "controller")
            manager = try LifecycleManager(store: store, defaults: [project], socket: socket)
        }
        func tmux(_ args: [String]) throws -> CommandResult { try ProcessRunner.run("/opt/homebrew/bin/tmux", ["-L", socket, "-f", "/dev/null"] + args) }
        func cleanup() { _ = try? tmux(["kill-server"]); try? FileManager.default.removeItem(at: directory) }
        func wait(_ state: LifecycleState) async throws {
            for _ in 0..<50 {
                let health = try await manager.health()[project.id]
                if health?.state == state && (state != .running || health?.bracketedPaste == true) { return }
                try await Task.sleep(for: .milliseconds(80))
            }
            let health = try await manager.health()[project.id]
            XCTFail("Expected \(state), got \(String(describing: health))")
        }
    }
    func testManagedStartPasteStopRestartAndRecovery() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try await f.manager.start(f.project.id)
        try await f.wait(.running)
        let initialSnapshot = await f.manager.snapshot()
        let initial = try XCTUnwrap(initialSnapshot.bindings[f.project.id.uuidString])
        XCTAssertFalse(initial.paneID.isEmpty)
        do { try await f.manager.start(f.project.id); XCTFail("Duplicate start") } catch {}
        let recovered = try LifecycleManager(store: f.store, defaults: [], socket: f.socket)
        let recoveredHealth = try await recovered.health()
        XCTAssertEqual(recoveredHealth[f.project.id]?.state, .running)
        let command = try await recovered.terminalCommand(f.project.id)
        XCTAssertTrue(command.contains("'" + initial.sessionID + "'"))
        XCTAssertTrue(command.contains("'" + f.socket + "'"))
        // An unrelated session on the SAME server is still protected.
        XCTAssertEqual(try f.tmux(["new-session", "-d", "-s", "unrelated", "/bin/sleep", "86400"]).status, 0)
        var unrelated = Project(name: "Unowned", directory: f.directory.path, executable: f.project.executable, session: "unrelated")
        try await recovered.saveProject(unrelated)
        do { try await recovered.stop(unrelated.id, confirmedInterrupt: true); XCTFail("Unowned stop") } catch {}
        do { try await recovered.start(unrelated.id); XCTFail("Unowned collision") } catch {}
        do { try await recovered.paste("no", projectID: unrelated.id, confirmedReady: true); XCTFail("Unowned send") } catch {}
        do { try await recovered.stop(f.project.id, confirmedInterrupt: false); XCTFail("Unconfirmed stop") } catch {}
        let prompt = "Literal 🧭\n$(touch never)\n`echo test`\n"
        try await recovered.paste(prompt, projectID: f.project.id, confirmedReady: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("received.bin")), Data(("\u{1b}[200~" + prompt + "\u{1b}[201~").utf8))
        do { try await recovered.paste("no submit", projectID: f.project.id, confirmedReady: true, submit: true); XCTFail("No readiness") } catch {}
        do { try await recovered.removeProject(f.project.id); XCTFail("Cannot remove live agent") } catch {}
        try await recovered.stop(f.project.id, confirmedInterrupt: true)
        for _ in 0..<50 {
            if try await recovered.health()[f.project.id]?.state == .stopped { break }
            try await Task.sleep(for: .milliseconds(80))
        }
        try await recovered.restart(f.project.id, mode: .resumePicker)
        let nextSnapshot = await recovered.snapshot()
        let next = try XCTUnwrap(nextSnapshot.bindings[f.project.id.uuidString])
        XCTAssertNotEqual(initial.runID, next.runID)
        XCTAssertEqual(next.mode, .resumePicker)
        // Replacing the named session must not adopt the replacement even if names match.
        XCTAssertEqual(try f.tmux(["kill-session", "-t", next.sessionID]).status, 0)
        XCTAssertEqual(try f.tmux(["new-session", "-d", "-s", f.project.session, "/bin/sleep", "86400"]).status, 0)
        let staleHealth = try await recovered.health()
        XCTAssertEqual(staleHealth[f.project.id]?.state, .disconnected)
        do { try await recovered.stop(f.project.id, confirmedInterrupt: true); XCTFail("Stale stop") } catch {}
        do { try await recovered.forceStop(f.project.id, confirmed: true); XCTFail("Stale force stop") } catch {}
        do { try await recovered.paste("bad", projectID: f.project.id, confirmedReady: true); XCTFail("Stale send") } catch {}
        XCTAssertEqual(try f.tmux(["has-session", "-t", "=unrelated"]).status, 0)
        XCTAssertEqual(try f.tmux(["kill-session", "-t", "=" + f.project.session]).status, 0)
        try await recovered.start(f.project.id)
        unrelated.name = "Renamed"
        try await recovered.saveProject(unrelated)
    }
    func testClaudeLifecycleAndAmbiguousPaneRefusal() async throws {
        let f = try Fixture(cli: .claude); defer { f.cleanup() }
        try await f.manager.start(f.project.id)
        try await f.wait(.running)
        let snapshot = await f.manager.snapshot()
        let b = try XCTUnwrap(snapshot.bindings[f.project.id.uuidString])
        XCTAssertEqual(try f.tmux(["split-window", "-d", "-t", b.paneID, "/bin/sleep", "86400"]).status, 0)
        do { try await f.manager.stop(f.project.id, confirmedInterrupt: true); XCTFail("Ambiguous pane") } catch {}
        do { try await f.manager.paste("bad", projectID: f.project.id, confirmedReady: true); XCTFail("Ambiguous pane") } catch {}
    }
    func testProjectValidationAndSettingsPersistence() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        var p = f.project
        p.directory = "relative"; XCTAssertThrowsError(try p.validate())
        p = f.project; p.session = "bad:session"; XCTAssertThrowsError(try p.validate())
        p = f.project; p.executable = "/not-installed"; XCTAssertThrowsError(try p.validate())
        p = f.project; p.name = "Edited"; p.notifications.enabled = true
        try await f.manager.saveProject(p)
        XCTAssertEqual(try f.store.load(defaults: []).projects, [p])
        try await f.manager.removeProject(p.id)
        let emptySnapshot = await f.manager.snapshot()
        XCTAssertTrue(emptySnapshot.projects.isEmpty)
    }
}
