import Foundation

nonisolated public protocol RealtimeVoiceClient: Sendable {
    func playSummary(for request: RealtimeSpeechRequest) async throws -> RealtimeSpeechResult
    func pausePlayback(sessionId: CodingSession.ID) async throws
    func startListening(for request: RealtimeListenRequest) async throws -> RealtimeListeningSession
    /// Hard-disconnect any persistent playback connection so WebRTC audio
    /// frames stop draining locally. The next playSummary lazily reconnects.
    func resetPlayback() async
}

nonisolated public protocol CodexSessionInputSink: Sendable {
    func submitPrompt(_ prompt: String, to session: CodingSession) async throws
}

nonisolated public protocol RealtimeEphemeralKeyProvider: Sendable {
    func ephemeralKey() async throws -> String
}

nonisolated public struct StaticRealtimeEphemeralKeyProvider: RealtimeEphemeralKeyProvider {
    private let value: String

    public init(ephemeralKey: String) {
        self.value = ephemeralKey
    }

    public func ephemeralKey() async throws -> String {
        value
    }
}

nonisolated public struct ClosureRealtimeEphemeralKeyProvider: RealtimeEphemeralKeyProvider {
    private let provider: @Sendable () async throws -> String

    public init(_ provider: @escaping @Sendable () async throws -> String) {
        self.provider = provider
    }

    public func ephemeralKey() async throws -> String {
        try await provider()
    }
}

nonisolated public struct OpenAIRealtimeVoiceConfiguration: Equatable, Sendable {
    public var model: String
    public var voice: String
    public var speechSpeed: Double
    public var temperature: Double
    public var maxResponseOutputTokens: Int
    public var transcriptionLanguage: String?
    public var transcriptionPrompt: String
    public var useSemanticTurnDetection: Bool
    public var debug: Bool

    public init(
        model: String = "gpt-realtime-2",
        voice: String = "marin",
        speechSpeed: Double = 1.05,
        temperature: Double = 0.8,
        maxResponseOutputTokens: Int = 220,
        transcriptionLanguage: String? = "en",
        transcriptionPrompt: String = "Technical dictation for a coding agent session. Preserve file names, symbols, command names, and programming terminology.",
        // Server VAD with a fixed silence threshold gives the most predictable
        // "speak, pause, send" behavior; semantic VAD can leave dictation
        // hanging when the model is unsure if the sentence is complete.
        useSemanticTurnDetection: Bool = false,
        debug: Bool = false
    ) {
        self.model = model
        self.voice = voice
        self.speechSpeed = speechSpeed
        self.temperature = temperature
        self.maxResponseOutputTokens = maxResponseOutputTokens
        self.transcriptionLanguage = transcriptionLanguage
        self.transcriptionPrompt = transcriptionPrompt
        self.useSemanticTurnDetection = useSemanticTurnDetection
        self.debug = debug
    }
}

nonisolated public struct RealtimeSpeechRequest: Equatable, Sendable {
    public var session: CodingSession
    public var assistantMessage: String
    public var summaryInstruction: String

    public init(
        session: CodingSession,
        assistantMessage: String,
        summaryInstruction: String = "Summarize this coding-agent response into one or two spoken sentences."
    ) {
        self.session = session
        self.assistantMessage = assistantMessage
        self.summaryInstruction = summaryInstruction
    }
}

nonisolated public struct RealtimeSpeechResult: Equatable, Sendable {
    public var spokenSummary: String

    public init(spokenSummary: String) {
        self.spokenSummary = spokenSummary
    }
}

nonisolated public struct RealtimeListenRequest: Equatable, Sendable {
    public var session: CodingSession
    public var instructions: String

    public init(
        session: CodingSession,
        instructions: String = "Transcribe the user's voice input for this Codex coding session. Return only the prompt text to send to Codex."
    ) {
        self.session = session
        self.instructions = instructions
    }
}

nonisolated public struct RealtimeListeningSession: Sendable {
    public var events: AsyncStream<RealtimeListenEvent>
    private var stopAction: @Sendable () async -> Void

    public init(
        events: AsyncStream<RealtimeListenEvent>,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        self.stopAction = stop
    }

    public func stop() async {
        await stopAction()
    }
}

nonisolated public enum RealtimeListenEvent: Equatable, Sendable {
    case transcriptDelta(String)
    case finalTranscript(String)
    case failed(String)
    case ended
}

nonisolated public struct CodeTalkerListeningSession: Sendable {
    public var sessionId: CodingSession.ID
    private var stopAction: @Sendable () async -> Void

    public init(
        sessionId: CodingSession.ID,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.sessionId = sessionId
        self.stopAction = stop
    }

    public func stop() async {
        await stopAction()
    }
}

nonisolated public struct PreviewRealtimeVoiceClient: RealtimeVoiceClient {
    public init() {}

    public func playSummary(for request: RealtimeSpeechRequest) async throws -> RealtimeSpeechResult {
        let summary = request.assistantMessage
            .split(separator: ".")
            .prefix(2)
            .joined(separator: ". ")
        return RealtimeSpeechResult(spokenSummary: summary.isEmpty ? request.assistantMessage : summary)
    }

    public func pausePlayback(sessionId: CodingSession.ID) async throws {}

    public func startListening(for request: RealtimeListenRequest) async throws -> RealtimeListeningSession {
        RealtimeListeningSession(events: AsyncStream { continuation in
            continuation.finish()
        }, stop: {})
    }

    public func resetPlayback() async {}
}
