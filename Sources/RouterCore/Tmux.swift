import Foundation

public struct Destination: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var session: String
    public init(id: Int, name: String, session: String) {
        self.id = id; self.name = name; self.session = session
    }
    public static let defaults = [
        Destination(id: 1, name: "Project 1", session: "agent-1"),
        Destination(id: 2, name: "Project 2", session: "agent-2"),
        Destination(id: 3, name: "Project 3", session: "agent-3")
    ]
}

public struct Pane: Identifiable, Equatable, Sendable {
    public let session: String
    public let id: String
    public let command: String
    public let dead: Bool
    public let inMode: Bool
    public let bracketedPaste: Bool
    public let inputOff: Bool
    public var label: String { "\(id) · \(command)" }
}

public enum RouterError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

/// An actor keeps all process I/O off the UI executor and serializes deliveries.
public actor Tmux {
    private let executable: String
    private let prefix: [String]
    private let allowedCommands: Set<String>
    private static let format = "#{session_name}\t#{pane_id}\t#{pane_current_command}\t#{pane_dead}\t#{pane_in_mode}\t#{bracket_paste_flag}\t#{pane_input_off}"

    public init(executable: String = "/opt/homebrew/bin/tmux", socket: String? = nil,
                allowedCommands: Set<String> = ["codex", "claude"]) {
        self.executable = executable
        self.prefix = socket.map { ["-L", $0] } ?? []
        self.allowedCommands = allowedCommands
    }

    /// Arguments are passed directly to tmux. Prompt bytes go only to stdin.
    private func run(_ arguments: [String], input: Data? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = prefix + arguments
        let stdin = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = stdin; process.standardOutput = output; process.standardError = errors
        // Bound every subprocess; output from these commands is small.
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: watchdog)
        defer { watchdog.cancel() }
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RouterError.message(String(data: error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "tmux failed or timed out.")
        }
        return String(decoding: result, as: UTF8.self)
    }

    public static func parse(_ output: String) -> [Pane] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7, f[1].first == "%" else { return nil }
            return Pane(session: f[0], id: f[1], command: f[2], dead: f[3] != "0",
                        inMode: f[4] != "0", bracketedPaste: f[5] == "1", inputOff: f[6] != "0")
        }
    }

    public func discover() throws -> [Pane] {
        Self.parse(try run(["list-panes", "-a", "-F", Self.format]))
    }

    public func health(_ pane: Pane) -> String? {
        if pane.dead { return "Pane is dead." }
        if pane.inMode { return "Pane is in copy or another tmux mode." }
        if pane.inputOff { return "Pane input is disabled." }
        if !allowedCommands.contains(pane.command) { return "Expected codex or claude; found \(pane.command). Shells and wrappers are refused." }
        if !pane.bracketedPaste { return "Agent has not enabled bracketed paste." }
        return nil
    }

    public static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RouterError.message("The preview is empty.") }
        guard text.utf8.count <= 64 * 1024 else { throw RouterError.message("Prompt exceeds the 64 KiB limit.") }
        guard !text.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || (127...159).contains($0.value) }) else {
            throw RouterError.message("Prompt contains terminal control characters. Remove them before delivery.")
        }
    }

    public func paste(_ text: String, session: String, paneID: String, confirmedReady: Bool) throws {
        guard confirmedReady else { throw RouterError.message("Confirm that the agent is idle and its input is ready.") }
        try Self.validateText(text)
        guard !session.isEmpty else { throw RouterError.message("Configure a session name first.") }
        func checkedPane() throws -> Pane {
            // Enumerate and compare literal names: never let tmux resolve a session prefix or fallback.
            guard let pane = try discover().first(where: { $0.session == session && $0.id == paneID }) else {
                throw RouterError.message("The exact configured session and pane no longer exist. Refresh and select again.")
            }
            if let issue = health(pane) { throw RouterError.message(issue) }
            return pane
        }
        _ = try checkedPane()
        let buffer = "agentrouter-" + UUID().uuidString
        defer { _ = try? run(["delete-buffer", "-b", buffer]) }
        _ = try run(["load-buffer", "-b", buffer, "-"], input: Data(text.utf8))
        _ = try checkedPane()
        _ = try run(["paste-buffer", "-d", "-p", "-r", "-b", buffer, "-t", paneID])
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
