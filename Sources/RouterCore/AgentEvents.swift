import Foundation

public enum AgentEventKind: String, Codable, CaseIterable, Sendable {
    case working = "WORKING", turnFinished = "TURN_FINISHED", completed = "COMPLETED", blocked = "BLOCKED"
    case needsInput = "NEEDS_INPUT", approvalRequired = "APPROVAL_REQUIRED", unknown = "UNKNOWN", exited = "EXITED"
}
public struct HistoryEntry: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var timestamp = Date()
    public var projectID: UUID
    public var projectName: String
    public var kind: AgentEventKind
    public var evidence: String
    // Deliberately no prompt, reply, question, tool input or message bodies on disk.
    public init(projectID: UUID, projectName: String, kind: AgentEventKind, evidence: String) {
        self.projectID = projectID; self.projectName = projectName; self.kind = kind; self.evidence = evidence
    }
}
public struct AgentActivity: Sendable {
    public var runID: String
    public var kind: AgentEventKind = .unknown
    public var detail = "No hook signal received. Open to handle authentication and startup."
    public var question: String?
    public var questionID: String?
    public var modal = false
    public var evidence = "unknown"
    public var readinessUntil: Date?
    public var outputGeneration: String?
    public var nativeSessionID: String?
    public var lastEventAt: Date?
    public init(runID: String) { self.runID = runID }
    public mutating func revoke() { readinessUntil = nil; outputGeneration = nil }
    public func canSubmit(now: Date) -> Bool {
        guard !modal, kind != .approvalRequired, kind != .working, let until = readinessUntil else { return false }
        return now < until
    }
}
public struct HookEnvelope: Codable, Sendable {
    public var version: Int
    public var id: String
    public var timestamp: Date
    public var projectID: UUID
    public var runID: String
    public var credential: String
    public var paneID: String
    public var payload: [String: JSONValue]
    public init(version: Int = 1, id: String = UUID().uuidString, timestamp: Date = Date(), projectID: UUID, runID: String, credential: String, paneID: String, payload: [String: JSONValue]) {
        self.version = version; self.id = id; self.timestamp = timestamp; self.projectID = projectID
        self.runID = runID; self.credential = credential; self.paneID = paneID; self.payload = payload
    }
}
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var object: [String: JSONValue]? { if case .object(let s) = self { return s }; return nil }
    public var array: [JSONValue]? { if case .array(let s) = self { return s }; return nil }
}
public struct HookInterpretation: Sendable {
    public var kind: AgentEventKind
    public var detail: String
    public var evidence: String
    public var question: String? = nil
    public var modal = false
    public var idleTextEditor = false
}
public enum HookAdapter {
    public static func interpret(_ payload: [String: JSONValue], cli: CLIKind) -> HookInterpretation {
        let event = payload["hook_event_name"]?.string ?? ""
        let message = payload["last_assistant_message"]?.string ?? payload["message"]?.string ?? ""
        switch event {
        case "UserPromptSubmit", "PreModelRequest":
            return HookInterpretation(kind: .working, detail: "Agent is working.", evidence: "native \(event)")
        case "SessionStart":
            return HookInterpretation(kind: .unknown, detail: "CLI session started; input readiness is not established.", evidence: "native SessionStart")
        case "Stop":
            if message.hasPrefix("BLOCKED:") || message.hasPrefix("[BLOCKED]") {
                return HookInterpretation(kind: .blocked, detail: String(message.prefix(4000)), evidence: "inferred explicit blocker claim in Stop message")
            }
            if message.hasPrefix("COMPLETED:") || message.hasPrefix("[COMPLETED]") {
                return HookInterpretation(kind: .completed, detail: String(message.prefix(4000)), evidence: "inferred completion claim; not independently verified")
            }
            // A natural-language question is an explicitly labelled inference, never a readiness grant.
            let question = message.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            return HookInterpretation(kind: question ? .needsInput : .turnFinished,
                detail: message.isEmpty ? "Turn finished. Overall task completion is unknown." : String(message.prefix(4000)),
                evidence: question ? "inferred question from native Stop message" : "native Stop; not task completion",
                question: question ? String(message.prefix(4000)) : nil)
        case "PermissionRequest":
            return HookInterpretation(kind: .approvalRequired, detail: "Permission or security approval required. Review in the agent terminal.", evidence: "native PermissionRequest", modal: true)
        case "PreToolUse":
            let tool = payload["tool_name"]?.string ?? ""
            if tool == "AskUserQuestion" || tool == "request_user_input" {
                let questions = payload["tool_input"]?.object?["questions"]?.array?.compactMap { $0.object?["question"]?.string }.joined(separator: "\n")
                return HookInterpretation(kind: .needsInput, detail: questions ?? "The agent opened a structured question. Use Open to answer its dialog.", evidence: "native question tool", question: questions, modal: true)
            }
            return HookInterpretation(kind: .working, detail: "Running a tool.", evidence: "native PreToolUse")
        case "Notification":
            let type = payload["notification_type"]?.string ?? ""
            if type == "permission_prompt" || type == "worker_permission_prompt" {
                return HookInterpretation(kind: .approvalRequired, detail: String(message.prefix(4000)), evidence: "native permission notification", modal: true)
            }
            if type == "elicitation_dialog" || type == "elicitation_url_dialog" || type == "agent_needs_input" {
                return HookInterpretation(kind: .needsInput, detail: String(message.prefix(4000)), evidence: "native input dialog notification", question: String(message.prefix(4000)), modal: true)
            }
            if cli == .claude && type == "idle_prompt" {
                return HookInterpretation(kind: .turnFinished, detail: "Claude reports an idle prompt. Task completion remains unknown.", evidence: "native idle_prompt", idleTextEditor: true)
            }
            return HookInterpretation(kind: .unknown, detail: String(message.prefix(4000)), evidence: "unclassified native notification")
        case "TaskCompleted" where cli == .claude:
            return HookInterpretation(kind: .completed, detail: "Claude reports completion of an individual tracked task; this does not prove the entire project is complete.", evidence: "native TaskCompleted; individual task scope")
        case "StopFailure" where cli == .claude:
            return HookInterpretation(kind: .blocked, detail: "The turn failed. Open the agent for its error details.", evidence: "native StopFailure; turn error, not semantic task blocker")
        case "SessionEnd":
            return HookInterpretation(kind: .exited, detail: "CLI session ended.", evidence: "native SessionEnd")
        case "Interrupt":
            return HookInterpretation(kind: .unknown, detail: "Turn interrupted; readiness unknown.", evidence: "native Interrupt")
        default:
            return HookInterpretation(kind: .unknown, detail: "Unclassified hook: \(event)", evidence: "unknown")
        }
    }
}

public enum HookConfiguration {
    public static func arguments(for cli: CLIKind, helper: String, directory: URL) throws -> [String] {
        let command = LifecycleManager.shellQuote(helper)
        let events = cli == .codex
            ? ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "Interrupt", "PreModelRequest"]
            : ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "StopFailure", "TaskCompleted"]
        let groups = Dictionary(uniqueKeysWithValues: events.map { ($0, [["hooks": [["type": "command", "command": command, "timeout": 3] as [String: Any]]]]) })
        if cli == .claude {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("claude-hooks.json")
            try JSONSerialization.data(withJSONObject: ["hooks": groups], options: [.sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return ["--settings", url.path]
        }
        // TOML inline arrays supplied as invocation-only overrides. No production config writes,
        // trust bypass flags, permission decisions or hook output are generated.
        let quoted = String(decoding: try JSONSerialization.data(withJSONObject: [command], options: [.withoutEscapingSlashes]), as: UTF8.self)
        let literal = String(quoted.dropFirst().dropLast())
        return events.flatMap { ["-c", "hooks.\($0)=[{hooks=[{type=\"command\",command=\(literal),timeout=3}]}]"] }
    }
}
