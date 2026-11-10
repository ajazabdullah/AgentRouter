import Foundation
import Darwin

enum LatestReply {
    struct Stamp: Equatable, Sendable {
        let path: String
        let size: UInt64
        let modified: Date
    }

    static func stamp(path: String, cli: CLIKind) throws -> Stamp {
        let fm = FileManager.default
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let root = cli == .codex ? (env["CODEX_HOME"] ?? home + "/.codex") : (env["CLAUDE_CONFIG_DIR"] ?? home + "/.claude")
        let directories = cli == .codex ? [root + "/sessions", root + "/archived_sessions"] : [root + "/projects"]
        guard path.hasPrefix("/"), file.pathExtension == "jsonl", directories.contains(where: {
            file.path.hasPrefix(URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path + "/")
        }) else { throw RouterError.message("The verified hook's transcript is outside the supported CLI history directory. Use Terminal screen view instead.") }
        let attributes = try fm.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else {
            throw RouterError.message("Cannot verify ownership of the agent transcript.")
        }
        return Stamp(path: file.path, size: size, modified: modified)
    }

    /// Reads native text only; never terminal controls, thinking, tool output, or a guessed session.
    static func read(_ stamp: Stamp, cli: CLIKind, sessionID: String, directory: String) throws -> String {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: stamp.path))
        defer { try? file.close() }
        var pending = Data(), remaining = stamp.size
        var identityVerified = false
        var latest: String?
        var messageID: String?
        var textBlocks: [Int: String] = [:]
        let expectedDirectory = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
        func matchingDirectory(_ value: String?) -> Bool {
            guard let value, value.hasPrefix("/") else { return false }
            return URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path == expectedDirectory
        }
        func consume(_ data: Data) throws {
            guard !data.isEmpty else { return }
            guard let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw RouterError.message("The transcript contains an unreadable record. No partial reply was copied.")
            }
            if cli == .codex {
                let payload = row["payload"] as? [String: Any] ?? [:]
                if row["type"] as? String == "session_meta" {
                    guard payload["id"] as? String == sessionID, matchingDirectory(payload["cwd"] as? String) else {
                        throw RouterError.message("The Codex transcript does not match this project's verified session.")
                    }
                    identityVerified = true
                }
                guard identityVerified else { return }
                if row["type"] as? String == "event_msg", payload["type"] as? String == "task_complete",
                   let text = payload["last_agent_message"] as? String, !text.isEmpty { latest = text }
                if row["type"] as? String == "response_item", payload["role"] as? String == "assistant",
                   let phase = payload["phase"] as? String, ["final", "final_answer"].contains(phase),
                   payload["status"] == nil || payload["status"] as? String == "completed" {
                    let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { part -> String? in
                        guard ["output_text", "text"].contains(part["type"] as? String ?? "") else { return nil }
                        return part["text"] as? String
                    }.joined()
                    if !text.isEmpty { latest = text }
                }
            } else {
                guard row["isSidechain"] as? Bool != true,
                      (row["sessionId"] as? String ?? row["session_id"] as? String) == sessionID else { return }
                if matchingDirectory(row["cwd"] as? String) { identityVerified = true }
                guard identityVerified, row["type"] as? String == "assistant",
                      let message = row["message"] as? [String: Any], message["role"] as? String == "assistant",
                      let id = message["id"] as? String else { return }
                if id != messageID { messageID = id; textBlocks = [:] }
                let content = message["content"] as? [[String: Any]] ?? []
                if row["apiBlockIndex"] == nil { textBlocks = [:] }
                let base = row["apiBlockIndex"] as? Int ?? 0
                for (index, part) in content.enumerated() where part["type"] as? String == "text" {
                    if let text = part["text"] as? String { textBlocks[base + index] = text }
                }
                if message["stop_reason"] as? String == "end_turn" {
                    let text = textBlocks.keys.sorted().compactMap { textBlocks[$0] }.joined()
                    if !text.isEmpty { latest = text }
                }
            }
        }
        // Stop at the original file size; a CLI may be appending a new turn concurrently.
        while remaining > 0 {
            let chunk = try file.read(upToCount: Int(min(remaining, 65_536))) ?? Data()
            guard !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count); pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                try consume(Data(pending[..<newline]))
                pending.removeSubrange(...newline)
            }
        }
        // Accept a complete final JSON record without a newline, but ignore an in-flight partial write.
        if !pending.isEmpty, (try? JSONSerialization.jsonObject(with: pending)) != nil { try consume(pending) }
        guard identityVerified else { throw RouterError.message("No matching session identity was found in the transcript.") }
        guard let latest else { throw RouterError.message("No completed reply is recorded for this session yet. Terminal screen view remains available.") }
        return latest
    }
}
