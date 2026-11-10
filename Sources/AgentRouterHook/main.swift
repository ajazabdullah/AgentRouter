import Foundation
import RouterCore

// Passive adapter: emits no hook decisions, never approves requests, never reads transcripts.
// Failure is silent and non-blocking to the agent; the app fails closed without fresh events.
do {
    let env = ProcessInfo.processInfo.environment
    if let project = env["AR_PROJECT"].flatMap(UUID.init(uuidString:)), let run = env["AR_RUN"],
       let token = env["AR_TOKEN"], let pane = env["TMUX_PANE"], let socket = env["AR_SOCKET"] {
        var input = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
            input.append(chunk)
            if input.count > 1024 * 1024 { throw RouterError.message("Hook input exceeds limit.") }
        }
        let original = try JSONDecoder().decode([String: JSONValue].self, from: input)
        var payload: [String: JSONValue] = [:]
        for key in ["hook_event_name", "session_id", "transcript_path", "turn_id", "notification_type", "tool_name", "agent_id", "agent_type"] { payload[key] = original[key] }
        for key in ["last_assistant_message", "message"] {
            if let value = original[key]?.string { payload[key] = .string(String(value.prefix(4000))) }
        }
        if ["AskUserQuestion", "request_user_input"].contains(original["tool_name"]?.string ?? ""), let questions = original["tool_input"]?.object?["questions"]?.array {
            payload["tool_input"] = .object(["questions": .array(questions.prefix(4).map { q in
                .object(["question": .string(String((q.object?["question"]?.string ?? "").prefix(1000)))])
            })])
        }
        let envelope = HookEnvelope(version: 1, id: UUID().uuidString, timestamp: Date(), projectID: project, runID: run, credential: token, paneID: pane, payload: payload)
        _ = try LocalIPC.send(JSONEncoder().encode(envelope), path: socket)
    }
} catch { /* No stdout or permission decisions. Missing events never grant readiness. */ }
