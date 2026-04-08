import Foundation

public enum AgentStatus {
    case idle
    case processing
    case running
    case waitingApproval
    case waitingQuestion
}

public struct HookEvent {
    public let eventName: String
    public let sessionId: String?
    public let toolName: String?
    public let agentId: String?
    public let toolInput: [String: Any]?
    public let rawJSON: [String: Any]  // Full payload for event-specific fields

    public init?(from data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        self.init(json: json)
    }

    public init?(json: [String: Any]) {
        guard let eventName = HookEvent.readEventName(from: json) else {
            return nil
        }
        self.eventName = eventName
        self.sessionId = HookEvent.readString(from: json, keys: ["session_id", "sessionId", "conversation_id", "conversationId"])
        self.toolName = HookEvent.readString(from: json, keys: ["tool_name", "toolName"])
        self.toolInput = HookEvent.readObject(from: json, keys: ["tool_input", "toolInput", "toolArgs"])
        self.agentId = HookEvent.readString(from: json, keys: ["agent_id", "agentId"])
        self.rawJSON = json
    }

    public var toolDescription: String? {
        // Try tool_input fields first
        if let input = toolInput {
            if let command = input["command"] as? String { return command }
            if let filePath = input["file_path"] as? String { return (filePath as NSString).lastPathComponent }
            if let pattern = input["pattern"] as? String { return pattern }
            if let prompt = input["prompt"] as? String { return String(prompt.prefix(40)) }
        }
        // Fall back to top-level fields
        if let msg = HookEvent.readString(from: rawJSON, keys: ["message"]) { return msg }
        if let agentType = HookEvent.readString(from: rawJSON, keys: ["agent_type", "agentType"]) { return agentType }
        if let prompt = HookEvent.readString(from: rawJSON, keys: ["prompt", "user_prompt", "userPrompt"]) { return String(prompt.prefix(40)) }
        return nil
    }

    public var originId: String {
        if let origin = rawJSON["_origin_id"] as? String,
           !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return origin
        }
        if let profile = rawJSON["_remote_profile"] as? String,
           !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "remote:\(profile)"
        }
        return SessionKey.localOriginId
    }

    public var originDisplayName: String? {
        if let display = rawJSON["_origin_display_name"] as? String,
           !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return display
        }
        if let alias = rawJSON["_remote_host_alias"] as? String,
           !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return alias
        }
        return nil
    }

    public var sessionKey: SessionKey {
        SessionKey(originId: originId, sessionId: sessionId ?? "default")
    }

    public var routingSessionId: String {
        sessionKey.rawValue
    }

    private static func readEventName(from json: [String: Any]) -> String? {
        readString(from: json, keys: ["hook_event_name", "hookEventName", "event", "eventName"])
    }

    private static func readString(from json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func readObject(from json: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let object = json[key] as? [String: Any] {
                return object
            }
            if let text = json[key] as? String,
               let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        return nil
    }
}

public struct SubagentState {
    public let agentId: String
    public let agentType: String
    public var status: AgentStatus = .running
    public var currentTool: String?
    public var toolDescription: String?
    public var startTime: Date = Date()
    public var lastActivity: Date = Date()

    public init(agentId: String, agentType: String) {
        self.agentId = agentId
        self.agentType = agentType
    }
}

public struct ToolHistoryEntry: Identifiable {
    public let id = UUID()
    public let tool: String
    public let description: String?
    public let timestamp: Date
    public let success: Bool
    public let agentType: String?  // nil = main thread

    public init(tool: String, description: String?, timestamp: Date, success: Bool, agentType: String?) {
        self.tool = tool
        self.description = description
        self.timestamp = timestamp
        self.success = success
        self.agentType = agentType
    }
}

public struct ChatMessage: Identifiable {
    public let id = UUID()
    public let isUser: Bool
    public let text: String

    public init(isUser: Bool, text: String) {
        self.isUser = isUser
        self.text = text
    }
}

public struct QuestionPayload {
    public let question: String
    public let options: [String]?
    public let descriptions: [String]?
    public let header: String?

    public init(question: String, options: [String]?, descriptions: [String]? = nil, header: String? = nil) {
        self.question = question
        self.options = options
        self.descriptions = descriptions
        self.header = header
    }

    /// Try to extract question from a Notification hook event
    public static func from(event: HookEvent) -> QuestionPayload? {
        if let question = event.rawJSON["question"] as? String {
            let options = event.rawJSON["options"] as? [String]
            return QuestionPayload(question: question, options: options)
        }
        // Don't use "?" heuristic — normal status text like "Should I update tests?"
        // would be misclassified as a blocking question, stalling the hook.
        return nil
    }
}
