import XCTest
@testable import RouterCore

final class RouterCoreTests: XCTestCase {
    func testParsingAndValidation() throws {
        let panes = Tmux.parse("agent-1\t%42\tcodex\t0\t0\t1\t0\ninvalid\n")
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0].session, "agent-1")
        XCTAssertEqual(panes[0].id, "%42")
        XCTAssertTrue(panes[0].bracketedPaste)
        for text in ["", "  \n", "bad\u{1b}[201~", "bad\r", "bad\u{0}", String(repeating: "a", count: 65_537)] {
            XCTAssertThrowsError(try Tmux.validateText(text))
        }
        try Tmux.validateText("Unicode 🧭\n$(touch /tmp/never-run)\t`echo literal`")
    }

    func testHealthGates() async throws {
        let router = Tmux()
        let samples = [
            ("codex", "0", "0", "1", "0", true),
            ("claude", "0", "0", "1", "0", true),
            ("zsh", "0", "0", "1", "0", false),
            ("codex", "1", "0", "1", "0", false),
            ("codex", "0", "1", "1", "0", false),
            ("codex", "0", "0", "0", "0", false),
            ("codex", "0", "0", "1", "1", false)
        ]
        for (command, dead, mode, bracket, inputOff, expected) in samples {
            let line = ["agent-1", "%1", command, dead, mode, bracket, inputOff].joined(separator: "\t")
            let pane = try XCTUnwrap(Tmux.parse(line).first)
            let issue = await router.health(pane)
            XCTAssertEqual(issue == nil, expected, line)
        }
    }

    func testDisposableTmuxDelivery() async throws {
        let path = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let path else { throw XCTSkip("tmux is not installed") }
        let socket = "agentrouter-test-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func command(_ args: [String]) throws -> String {
            let p = Process(), output = Pipe()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-L", socket] + args
            p.standardOutput = output; p.standardError = FileHandle.nullDevice
            try p.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw RouterError.message("Test tmux command failed: \(args.first ?? "")") }
            return String(decoding: data, as: UTF8.self)
        }
        defer { _ = try? command(["kill-server"]) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let receiver = root.appendingPathComponent("scripts/test-receiver.py").path
        let result = directory.appendingPathComponent("result.json")
        // Only fixed executable paths and generated test paths enter this startup command.
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        _ = try command(["-f", "/dev/null", "new-session", "-d", "-s", "receiver", "python3 \(quote(receiver)) \(quote(result.path))"])
        let router = Tmux(executable: path, socket: socket, allowedCommands: ["python3", "Python"])
        var target: Pane?
        for _ in 0..<40 {
            let panes = try await router.discover()
            if let p = panes.first, await router.health(p) == nil { target = p; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let pane = try XCTUnwrap(target, "Receiver must enable bracketed paste")
        let marker = directory.appendingPathComponent("must-not-exist").path
        let prompt = "Literal 🧭\n$(touch \(marker))\n`touch \(marker)`\n; echo not-a-command\n"
        do {
            try await router.paste(prompt, session: "receiv", paneID: pane.id, confirmedReady: true)
            XCTFail("A prefix must not match the exact session")
        } catch {}
        do {
            try await router.paste(prompt, session: "receiver", paneID: pane.id, confirmedReady: false)
            XCTFail("Readiness must be explicit")
        } catch {}
        do {
            try await router.paste(prompt, session: "receiver", paneID: "%999999", confirmedReady: true)
            XCTFail("A missing pane must never fall back to the active pane")
        } catch {}
        try await router.paste(prompt, session: "receiver", paneID: pane.id, confirmedReady: true)
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: result.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: result)) as! [String: Any]
        let expected = Data(("\u{1b}[200~" + prompt + "\u{1b}[201~").utf8)
        XCTAssertEqual(report["bytes"] as? Int, expected.count)
        XCTAssertEqual(report["sha256"] as? String, sha256(expected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        XCTAssertEqual(try command(["list-buffers", "-F", "#{buffer_name}"]).trimmingCharacters(in: .whitespacesAndNewlines), "")
        _ = try command(["kill-session", "-t", "=receiver"])
        do {
            try await router.paste(prompt, session: "receiver", paneID: pane.id, confirmedReady: true)
            XCTFail("Missing target must fail")
        } catch {}
    }
}

import CryptoKit
private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
