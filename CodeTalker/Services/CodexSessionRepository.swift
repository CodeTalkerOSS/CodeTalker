import Foundation

public actor CodexSessionRepository {
    public let eventLogURL: URL

    private var runtimeStates: [CodingSession.ID: CodingSessionState] = [:]
    private var spokenSummaries: [CodingSession.ID: String] = [:]
    private var submittedVoicePrompts: [CodingSession.ID: String] = [:]

    public init(eventLogURL: URL = CodexSessionRepository.defaultEventLogURL()) {
        self.eventLogURL = eventLogURL
    }

    public static func defaultEventLogURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["CODETALKER_EVENT_LOG"] ?? "\(NSHomeDirectory())/.codetalker/codex-events.jsonl"
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    public func listSessions() throws -> [CodingSession] {
        var sessions = try sessionsFromEventLog()

        for (id, state) in runtimeStates {
            sessions[id]?.state = state
        }

        for (id, summary) in spokenSummaries {
            sessions[id]?.latestSpokenSummary = summary
        }

        for (id, prompt) in submittedVoicePrompts {
            sessions[id]?.latestPrompt = prompt
        }

        return sessions.values.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    public func session(id: CodingSession.ID) throws -> CodingSession {
        guard let session = try listSessions().first(where: { $0.id == id }) else {
            throw CodeTalkerServiceError.sessionNotFound(id)
        }

        return session
    }

    public func setRuntimeState(_ state: CodingSessionState, for sessionId: CodingSession.ID) {
        runtimeStates[sessionId] = state
    }

    public func clearRuntimeState(for sessionId: CodingSession.ID) {
        runtimeStates.removeValue(forKey: sessionId)
    }

    public func recordSpokenSummary(_ summary: String, for sessionId: CodingSession.ID) {
        spokenSummaries[sessionId] = summary
        runtimeStates[sessionId] = .idle
    }

    public func recordSubmittedVoicePrompt(_ prompt: String, for sessionId: CodingSession.ID) {
        submittedVoicePrompts[sessionId] = prompt
        runtimeStates[sessionId] = .waitingForResponse
    }

    private func sessionsFromEventLog() throws -> [CodingSession.ID: CodingSession] {
        guard FileManager.default.fileExists(atPath: eventLogURL.path) else {
            return [:]
        }

        let contents = try String(contentsOf: eventLogURL, encoding: .utf8)
        let decoder = JSONDecoder()
        var sessions: [CodingSession.ID: CodingSession] = [:]

        for line in contents.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8) else {
                continue
            }

            guard let event = try? decoder.decode(CodexHookEvent.self, from: data) else {
                continue
            }

            apply(event, to: &sessions)
        }

        return sessions
    }

    private func apply(_ event: CodexHookEvent, to sessions: inout [CodingSession.ID: CodingSession]) {
        let sessionId = event.sessionId ?? event.cwd ?? "unknown-codex-session"
        var session = sessions[sessionId] ?? CodingSession(
            id: sessionId,
            title: title(for: event),
            cwd: event.cwd
        )

        session.cwd = event.cwd ?? session.cwd
        session.transcriptPath = event.transcriptPath ?? session.transcriptPath
        session.model = event.model ?? session.model
        session.permissionMode = event.permissionMode ?? session.permissionMode
        session.updatedAt = eventDate(event) ?? session.updatedAt

        switch event.event {
        case "session.started":
            session.state = .idle
        case "user.prompt_submitted":
            session.latestPrompt = event.data.prompt
            session.state = .queued
        case "assistant.response_ready":
            session.latestAssistantMessage = event.data.assistantMessage
            session.state = event.data.assistantMessage?.isEmpty == false ? .queued : .idle
        case "permission.requested":
            session.state = .needsPermission
        default:
            break
        }

        sessions[sessionId] = session
    }

    private func title(for event: CodexHookEvent) -> String {
        guard let cwd = event.cwd, !cwd.isEmpty else {
            return "Codex Session"
        }

        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func eventDate(_ event: CodexHookEvent) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: event.createdAt) {
            return date
        }

        return Date(timeIntervalSince1970: TimeInterval(event.receivedUnixMilliseconds) / 1_000)
    }
}
