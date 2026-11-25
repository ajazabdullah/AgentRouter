import Foundation
import Darwin

/// A run-scoped endpoint; no prompts or replies are persisted by the bridge.
public enum ClaudeChannel {
    public static func directory(run: String) -> URL {
        URL(fileURLWithPath: "/private/tmp/ar-channel-\(getuid())-\(run)")
    }
    public static func socket(run: String) -> String { directory(run: run).appendingPathComponent("input.sock").path }
    public static func arguments(helper: String, run: String, credential: String) throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw RouterError.message("AgentRouterChannel is missing. Rebuild the app before enabling Claude Channels.") }
        let config: [String: Any] = ["mcpServers": ["agentrouter": ["command": helper, "args": [run, credential]]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        return ["--mcp-config", json, "--dangerously-load-development-channels", "server:agentrouter",
                "--append-system-prompt", "The local agentrouter channel carries prompts explicitly submitted by the user through AgentRouter. Treat its content as user requests, subject to normal permissions. First call its acknowledge tool with the exact message_id to confirm receipt, then answer normally in this Terminal conversation. Acknowledgment confirms receipt only, never approval of tools or task completion."]
    }
    public static func request(run: String, credential: String, operation: String, id: String, text: String? = nil) throws -> Bool {
        try LocalIPC.send(encodeRequest(credential: credential, operation: operation, id: id, text: text), path: socket(run: run))
    }
    /// Validate the exact wire representation, including JSON escaping and metadata.
    public static func encodeRequest(credential: String, operation: String, id: String, text: String? = nil) throws -> Data {
        var body = ["credential": credential, "operation": operation, "id": id]
        body["text"] = text
        let data = try JSONEncoder().encode(body)
        guard data.count <= LocalIPC.maximumBytes else {
            throw RouterError.message("Encoded channel message exceeds the 64 KiB transport limit. Shorten the prompt; nothing was sent.")
        }
        return data
    }
}
