import Foundation

nonisolated public struct CodingSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var cwd: String?
    public var transcriptPath: String?
    public var model: String?
    public var permissionMode: String?
    public var state: CodingSessionState
    public var latestPrompt: String?
    public var latestAssistantMessage: String?
    public var latestSpokenSummary: String?
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        model: String? = nil,
        permissionMode: String? = nil,
        state: CodingSessionState = .idle,
        latestPrompt: String? = nil,
        latestAssistantMessage: String? = nil,
        latestSpokenSummary: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.model = model
        self.permissionMode = permissionMode
        self.state = state
        self.latestPrompt = latestPrompt
        self.latestAssistantMessage = latestAssistantMessage
        self.latestSpokenSummary = latestSpokenSummary
        self.updatedAt = updatedAt
    }
}

nonisolated public enum CodingSessionState: String, Codable, Equatable, Sendable {
    case idle
    case queued
    case waitingForResponse
    case speaking
    case paused
    case listening
    case needsPermission
    case error
}

nonisolated public struct CodexHookEvent: Codable, Equatable, Sendable {
    public var schema: String
    public var eventId: String
    public var event: String
    public var hookEventName: String
    public var createdAt: String
    public var receivedUnixMilliseconds: Int64
    public var sessionId: String?
    public var turnId: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var model: String?
    public var permissionMode: String?
    public var voiceAction: String
    public var data: CodexHookEventData

    enum CodingKeys: String, CodingKey {
        case schema
        case eventId = "event_id"
        case event
        case hookEventName = "hook_event_name"
        case createdAt = "created_at"
        case receivedUnixMilliseconds = "received_unix_ms"
        case sessionId = "session_id"
        case turnId = "turn_id"
        case cwd
        case transcriptPath = "transcript_path"
        case model
        case permissionMode = "permission_mode"
        case voiceAction = "voice_action"
        case data
    }
}

nonisolated public struct CodexHookEventData: Codable, Equatable, Sendable {
    public var source: String?
    public var prompt: String?
    public var assistantMessage: String?
    public var summaryInstruction: String?
    public var stopHookActive: Bool?
    public var toolName: String?
    public var command: String?
    public var permissionReason: String?
    public var rawPayload: String?

    enum CodingKeys: String, CodingKey {
        case source
        case prompt
        case assistantMessage = "assistant_message"
        case summaryInstruction = "summary_instruction"
        case stopHookActive = "stop_hook_active"
        case toolName = "tool_name"
        case command
        case permissionReason = "permission_reason"
        case rawPayload = "raw_payload"
    }
}

nonisolated public enum CodeTalkerServiceError: Error, Equatable, Sendable {
    case sessionNotFound(String)
    case noAssistantResponse(String)
    case codexInputUnavailable
}

nonisolated public enum OpenAIRealtimeVoiceClientError: Error, Equatable, Sendable {
    case realtimePackageUnavailable
    case transcriptUnavailable
    case missingRealtimeEphemeralKey
    case cancelled
}
