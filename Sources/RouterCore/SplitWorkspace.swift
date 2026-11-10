import Foundation

/// Display clients only. Controller panes stay on their original server, untouched.
enum SplitWorkspace {
    static let socket = "agentrouter-views-v1"
    private static let owner = "AgentRouter.Split.v1"
    private struct Pane { let id: String; let dead: Bool; let command: String; let tty: String; let pid: Int32 }

    private static func run(_ tmux: String, _ args: [String]) throws -> String {
        let result = try ProcessRunner.run(tmux, ["-u", "-L", socket, "-f", "/dev/null"] + args)
        guard result.status == 0 else { throw RouterError.message("Split view: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return result.output
    }
    private static func find(_ tmux: String, name: String, pair: String) throws -> String? {
        let result = try ProcessRunner.run(tmux, ["-L", socket, "-f", "/dev/null", "list-sessions", "-F", "#{session_name}|#{session_id}|#{@ar_split_owner}|#{@ar_split_pair}"])
        if result.status != 0 {
            if ["no server running", "No such file or directory", "Connection refused"].contains(where: result.error.contains) { return nil }
            throw RouterError.message("Cannot inspect split views: \(result.error)")
        }
        for line in result.output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.first == name else { continue }
            guard fields.count == 4, fields[2] == owner, fields[3] == pair else {
                throw RouterError.message("Split-view name collision. The existing session was not changed.")
            }
            return fields[1]
        }
        return nil
    }
    private static func panes(_ tmux: String, session: String, allowLaunching: Bool = false) throws -> [Pane] {
        let output = try run(tmux, ["list-panes", "-s", "-t", session, "-F", "#{pane_id}|#{pane_dead}|#{pane_current_command}|#{pane_tty}|#{pane_pid}"])
        let panes = try output.split(separator: "\n").map { line -> Pane in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, fields[0].hasPrefix("%"), fields[1] == "0" || fields[1] == "1",
                  let pid = Int32(fields[4]) ?? (fields[1] == "1" ? 0 : nil) else {
                throw RouterError.message("Cannot verify split-view pane identity.")
            }
            return Pane(id: fields[0], dead: fields[1] == "1", command: fields[2], tty: fields[3], pid: pid)
        }
        guard panes.count == 2, panes.allSatisfy({ $0.dead || $0.command == "tmux" || (allowLaunching && ["sleep", "env"].contains($0.command)) }) else {
            throw RouterError.message("The split workspace was changed manually. No panes were replaced or closed.")
        }
        return panes
    }
    private static func bindingsMatch(_ tmux: String, session: String, controllerSocket: String,
                                      expected: [String], allowLaunching: Bool = false) throws -> Bool {
        let display = try panes(tmux, session: session, allowLaunching: allowLaunching)
        let result = try ProcessRunner.run(tmux, ["-u", "-L", controllerSocket, "-f", "/dev/null", "list-clients",
                                                  "-F", "#{client_tty}|#{client_pid}|#{session_id}"])
        guard result.status == 0 else { throw RouterError.message("Cannot verify the split clients' actual controller sessions. No split was opened.") }
        var clients: [String: [(pid: Int32, session: String)]] = [:]
        for line in result.output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let pid = Int32(fields[1]) else { throw RouterError.message("Unrecognized split client identity; opening refused.") }
            clients[fields[0], default: []].append((pid, fields[2]))
        }
        return zip(display, expected).allSatisfy { item in
            let (pane, target) = item
            guard !pane.dead, pane.tty.hasPrefix("/dev/"), let matches = clients[pane.tty], matches.count == 1 else { return false }
            return matches[0].pid == pane.pid && matches[0].session == target
        }
    }
    static func target(tmux: String, controllerSocket: String, first: Project, second: Project,
                       firstBinding: Binding, secondBinding: Binding, balance: Bool) throws -> TerminalTarget {
        let pair = first.id.uuidString + ":" + second.id.uuidString
        let name = "ar-" + first.id.uuidString + "-" + second.id.uuidString
        let runs = firstBinding.runID + ":" + secondBinding.runID
        let session: String
        var created = false
        if let existing = try find(tmux, name: name, pair: pair) { session = existing }
        else {
            let output = try run(tmux, ["new-session", "-d", "-P", "-F", "#{session_id}", "-s", name,
                                        "-x", "180", "-y", "45", "/bin/sleep", "86400"])
            session = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard session.hasPrefix("$"), Int(session.dropFirst()) != nil else { throw RouterError.message("No exact split session identity was returned.") }
            created = true
        }
        do {
            if created {
                _ = try run(tmux, ["set-option", "-t", session, "@ar_split_owner", owner])
                _ = try run(tmux, ["set-option", "-t", session, "@ar_split_pair", pair])
                _ = try run(tmux, ["set-option", "-w", "-t", session, "remain-on-exit", "on"])
                _ = try run(tmux, ["set-option", "-t", session, "mouse", "on"])
                _ = try run(tmux, ["set-option", "-t", session, "prefix", "C-a"])
                _ = try run(tmux, ["set-option", "-w", "-t", session, "pane-border-status", "top"])
                _ = try run(tmux, ["set-option", "-w", "-t", session, "pane-border-format", " #{pane_index}: #{@ar_view_label} "])
                _ = try run(tmux, ["set-option", "-t", session, "status-left", " Split View · Ctrl-a d detaches "])
                _ = try run(tmux, ["set-option", "-t", session, "status-left-length", "45"])
                _ = try run(tmux, ["split-window", "-d", "-h", "-t", session, "/bin/sleep", "86400"])
            }
            // New placeholders are created by us; reused panes must only be tmux clients or dead.
            let viewPanes = try panes(tmux, session: session, allowLaunching: created)
            let oldRuns = try run(tmux, ["show-options", "-qv", "-t", session, "@ar_split_runs"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = [firstBinding.sessionID, secondBinding.sessionID]
            let exactTargets: Bool
            if created { exactTargets = false }
            else { exactTargets = try bindingsMatch(tmux, session: session, controllerSocket: controllerSocket, expected: expected) }
            if created || oldRuns != runs || viewPanes.contains(where: \.dead) || !exactTargets {
                for (pane, project, binding) in [(viewPanes[0], first, firstBinding), (viewPanes[1], second, secondBinding)] {
                    let label = String(String.UnicodeScalarView(project.name.unicodeScalars.filter {
                        $0.value >= 32 && !((127...159).contains($0.value)) && $0.value != 35
                    }).prefix(80))
                    _ = try run(tmux, ["set-option", "-p", "-t", pane.id, "@ar_view_label", label])
                    _ = try run(tmux, ["respawn-pane", "-k", "-t", pane.id, "/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE",
                                        tmux, "-u", "-L", controllerSocket, "-f", "/dev/null", "attach-session", "-t", binding.sessionID])
                }
                _ = try run(tmux, ["set-option", "-t", session, "@ar_split_runs", runs])
                var verified = false
                for _ in 0..<20 {
                    if try bindingsMatch(tmux, session: session, controllerSocket: controllerSocket, expected: expected, allowLaunching: true) {
                        verified = true; break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard verified else { throw RouterError.message("Split clients did not attach to the exact expected controllers. Opening refused; agents were not changed.") }
            }
            if created || balance { _ = try run(tmux, ["select-layout", "-t", session, "even-horizontal"]) }
            let clients = try run(tmux, ["list-clients", "-F", "#{session_id}|#{client_tty}"])
            let ttys = clients.split(separator: "\n").compactMap { line -> String? in
                let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                guard fields.count == 2, fields[0] == session, fields[1].hasPrefix("/dev/") else { return nil }
                return String(fields[1])
            }
            let command = [tmux, "-L", socket, "attach-session", "-t", session].map(LifecycleManager.shellQuote).joined(separator: " ")
            return TerminalTarget(command: command, attachedTTYs: ttys)
        } catch {
            if created, let output = try? run(tmux, ["list-panes", "-s", "-t", session, "-F", "#{pane_dead}|#{pane_current_command}"]) {
                let rows = output.split(separator: "\n")
                let onlyViewProcesses = !rows.isEmpty && rows.count <= 2 && rows.allSatisfy { line in
                    let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                    return fields.count == 2 && (fields[0] == "1" || ["sleep", "tmux"].contains(String(fields[1])))
                }
                if onlyViewProcesses { _ = try? run(tmux, ["kill-session", "-t", session]) }
            }
            throw error
        }
    }
    static func close(tmux: String, first: UUID, second: UUID) throws {
        let pair = first.uuidString + ":" + second.uuidString
        let name = "ar-" + first.uuidString + "-" + second.uuidString
        guard let session = try find(tmux, name: name, pair: pair) else { return }
        _ = try panes(tmux, session: session)
        _ = try run(tmux, ["kill-session", "-t", session]) // Dedicated view server; only attach clients.
    }
}
