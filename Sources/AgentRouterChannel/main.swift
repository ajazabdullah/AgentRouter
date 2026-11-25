import Foundation
import RouterCore
import Darwin

/// Minimal MCP stdio server. Stdout contains JSON-RPC only; no network ports.
final class Bridge: @unchecked Sendable {
    let credential: String
    let lock = NSLock()
    var initialized = false
    var messages: [String: Bool] = [:]
    init(credential: String) { self.credential = credential }
    func emit(_ object: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: object) + Data([10])
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
    func receive(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard initialized, let value = try? JSONDecoder().decode([String: String].self, from: data),
              value["credential"] == credential, let id = value["id"], UUID(uuidString: id) != nil else { return false }
        if value["operation"] == "ready" { return true }
        if value["operation"] == "status" { return messages[id] == true }
        guard value["operation"] == "submit", let text = value["text"], (try? Tmux.validateText(text)) != nil else { return false }
        if messages[id] != nil { return true } // Idempotent transport retries, no second notification.
        guard messages.count < 10000 else { return false }
        messages[id] = false // Reserve before write: an uncertain write must never be retried.
        do {
            try emit(["jsonrpc": "2.0", "method": "notifications/claude/channel", "params": ["content": text, "meta": ["message_id": id]]])
            return true
        } catch { return false }
    }
    func inputError(code: Int, message: String) throws {
        lock.lock(); defer { lock.unlock() }
        try emit(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": code, "message": message]])
    }
    func rpc(_ request: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard let method = request["method"] as? String else { return }
        if method == "notifications/initialized" { initialized = true; return }
        guard let id = request["id"] else { return }
        let params = request["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05", "serverInfo": ["name": "agentrouter", "version": "0.1.0"],
                      "capabilities": ["experimental": ["claude/channel": [:]], "tools": [:]],
                      "instructions": "Messages are user-submitted AgentRouter prompts. First call acknowledge with meta.message_id, then respond in Terminal. Never approve permission requests through this channel."]
        case "ping": result = [:]
        case "tools/list":
            result = ["tools": [["name": "acknowledge", "description": "Confirm receipt of a user-submitted channel message. Does not approve any operation or indicate completion.",
                                 "inputSchema": ["type": "object", "properties": ["message_id": ["type": "string"]], "required": ["message_id"], "additionalProperties": false],
                                 "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]]]
        case "tools/call":
            let args = params["arguments"] as? [String: String] ?? [:]
            let known = params["name"] as? String == "acknowledge" && args["message_id"].map { messages[$0] != nil } == true
            if known, let message = args["message_id"] { messages[message] = true }
            result = ["content": [["type": "text", "text": known ? "Receipt acknowledged. Continue with the user's prompt in Terminal." : "Unknown message ID."]], "isError": !known]
        default:
            try emit(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]); return
        }
        try emit(["jsonrpc": "2.0", "id": id, "result": result])
    }
}

do {
    guard CommandLine.arguments.count == 3, UUID(uuidString: CommandLine.arguments[1]) != nil else { exit(1) }
    let run = CommandLine.arguments[1], bridge = Bridge(credential: CommandLine.arguments[2])
    let server = try HookServer(path: ClaudeChannel.socket(run: run)) { data, _ in bridge.receive(data) }
    defer { server.stop() }
    // Read bounded JSON lines without unbounded readLine allocation.
    var pending = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if count == 0 { break }
        if count < 0 { if errno == EINTR { continue }; throw RouterError.message("MCP stdin failed.") }
        pending.append(contentsOf: bytes.prefix(count))
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]; pending.removeSubrange(...newline)
            guard line.count <= 1024 * 1024 else { exit(1) }
            let value: Any
            do { value = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) }
            catch { try bridge.inputError(code: -32700, message: "Parse error"); continue }
            guard let object = value as? [String: Any] else {
                try bridge.inputError(code: -32600, message: "Invalid Request"); continue
            }
            try bridge.rpc(object)
        }
        guard pending.count <= 1024 * 1024 else { exit(1) }
    }
} catch { exit(1) }
