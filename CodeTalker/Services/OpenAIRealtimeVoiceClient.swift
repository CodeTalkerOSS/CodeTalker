import Foundation

#if canImport(RealtimeAPI)
import RealtimeAPI
#endif

#if canImport(RealtimeAPI)
public actor OpenAIRealtimeVoiceClient: RealtimeVoiceClient {
    private let credentialProvider: any RealtimeEphemeralKeyProvider
    private let configuration: OpenAIRealtimeVoiceConfiguration

    @MainActor private var playbackConversations: [CodingSession.ID: Conversation] = [:]
    @MainActor private var listeningConversations: [CodingSession.ID: Conversation] = [:]

    public init(
        credentialProvider: any RealtimeEphemeralKeyProvider,
        configuration: OpenAIRealtimeVoiceConfiguration = OpenAIRealtimeVoiceConfiguration()
    ) {
        self.credentialProvider = credentialProvider
        self.configuration = configuration
    }

    public func playSummary(for request: RealtimeSpeechRequest) async throws -> RealtimeSpeechResult {
        let conversation = try await makeConversation(mode: .speechSummary)
        await MainActor.run {
            playbackConversations[request.session.id] = conversation
        }

        defer {
            Task { @MainActor in
                playbackConversations.removeValue(forKey: request.session.id)
            }
        }

        let prompt = """
        \(request.summaryInstruction)

        Codex response:
        \(request.assistantMessage)
        """

        try await MainActor.run {
            try conversation.send(
                from: .user,
                text: prompt
            )
        }

        let summary = try await waitForAssistantTranscript(
            in: conversation,
            timeout: .seconds(45)
        )

        return RealtimeSpeechResult(spokenSummary: summary)
    }

    public func pausePlayback(sessionId: CodingSession.ID) async throws {
        guard let conversation = await MainActor.run(body: { playbackConversations[sessionId] }) else {
            return
        }

        try await MainActor.run {
            try conversation.send(event: .cancelResponse())
            try conversation.send(event: .outputAudioBufferClear())
            playbackConversations.removeValue(forKey: sessionId)
        }
    }

    public func startListening(for request: RealtimeListenRequest) async throws -> RealtimeListeningSession {
        let conversation = try await makeConversation(mode: .codexDictation)
        await MainActor.run {
            listeningConversations[request.session.id] = conversation
        }

        let stream = AsyncStream<RealtimeListenEvent> { continuation in
            let task = Task {
                do {
                    try await streamUserTranscript(
                        from: conversation,
                        request: request,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    continuation.yield(.ended)
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(String(describing: error)))
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task { @MainActor in
                    self.listeningConversations.removeValue(forKey: request.session.id)
                }
            }
        }

        return RealtimeListeningSession(events: stream) {
            await MainActor.run {
                if let conversation = self.listeningConversations.removeValue(forKey: request.session.id) {
                    try? conversation.send(event: .clearInputAudioBuffer())
                    conversation.muted = true
                }
            }
        }
    }
}

private extension OpenAIRealtimeVoiceClient {
    enum Mode {
        case speechSummary
        case codexDictation
    }

    func makeConversation(mode: Mode) async throws -> Conversation {
        let ephemeralKey = try await credentialProvider.ephemeralKey()
        let configuration = configuration
        let model = Model(rawValue: configuration.model) ?? .custom(configuration.model)
        let conversation = await MainActor.run {
            Conversation(debug: configuration.debug) { session in
                Self.configure(&session, mode: mode, configuration: configuration)
            }
        }

        try await conversation.connect(ephemeralKey: ephemeralKey, model: model)
        await conversation.waitForConnection()

        return conversation
    }

    nonisolated static func configure(
        _ session: inout Session,
        mode: Mode,
        configuration: OpenAIRealtimeVoiceConfiguration
    ) {
        session.model = Model(rawValue: configuration.model) ?? .custom(configuration.model)
        session.modalities = [.text, .audio]
        session.temperature = configuration.temperature
        session.maxResponseOutputTokens = .limited(configuration.maxResponseOutputTokens)
        session.audio.output.voice = Self.voice(from: configuration.voice)
        session.audio.output.speed = configuration.speechSpeed
        session.audio.input.noiseReduction = .nearField
        session.audio.input.transcription = Session.Audio.Input.Transcription(
            model: .gpt4oMini,
            language: configuration.transcriptionLanguage,
            prompt: configuration.transcriptionPrompt
        )

        switch mode {
        case .speechSummary:
            session.instructions = """
            You are Code Talker's voice layer for a coding agent. Summarize the provided Codex response in one or two natural spoken sentences. Do not mention that you are summarizing unless it is useful. Preserve important filenames, commands, errors, and next actions.
            """
            session.audio.input.turnDetection = nil
        case .codexDictation:
            session.instructions = """
            You are Code Talker's dictation layer. Listen to the user's spoken instruction for a coding agent and produce a clean Codex prompt. Preserve code symbols, paths, command names, and technical terms. Do not answer the request yourself.
            """
            session.audio.input.turnDetection = Self.turnDetection(createResponse: false, configuration: configuration)
            session.modalities = [.text]
        }
    }

    nonisolated static func turnDetection(
        createResponse: Bool,
        configuration: OpenAIRealtimeVoiceConfiguration
    ) -> Session.Audio.Input.TurnDetection {
        if configuration.useSemanticTurnDetection {
            return .semanticVad(
                createResponse: createResponse,
                eagerness: .medium,
                idleTimeout: 12_000,
                interruptResponse: true
            )
        }

        return .serverVad(
            createResponse: createResponse,
            idleTimeout: 12_000,
            interruptResponse: true,
            prefixPaddingMs: 300,
            silenceDurationMs: 650,
            threshold: 0.5
        )
    }

    func waitForAssistantTranscript(
        in conversation: Conversation,
        timeout: Duration
    ) async throws -> String {
        let started = ContinuousClock.now
        var observedModelSpeaking = false
        var lastTranscript = ""
        var lastTranscriptChange = started

        while ContinuousClock.now - started < timeout {
            let snapshot = await MainActor.run {
                assistantTranscript(in: conversation)
            }

            if !snapshot.isEmpty, snapshot != lastTranscript {
                lastTranscript = snapshot
                lastTranscriptChange = ContinuousClock.now
            }

            let isModelSpeaking = await MainActor.run {
                conversation.isModelSpeaking
            }

            if isModelSpeaking {
                observedModelSpeaking = true
            }

            if !lastTranscript.isEmpty {
                if observedModelSpeaking, !isModelSpeaking {
                    return lastTranscript
                }

                if ContinuousClock.now - lastTranscriptChange > Duration.seconds(2) {
                    return lastTranscript
                }
            }

            try await Task.sleep(for: .milliseconds(150))
        }

        if !lastTranscript.isEmpty {
            return lastTranscript
        }

        throw OpenAIRealtimeVoiceClientError.transcriptUnavailable
    }

    func streamUserTranscript(
        from conversation: Conversation,
        request: RealtimeListenRequest,
        continuation: AsyncStream<RealtimeListenEvent>.Continuation
    ) async throws {
        var previousTranscript = ""
        var completedMessageIds = Set<String>()

        while !Task.isCancelled {
            let snapshot = await MainActor.run {
                userInputTranscripts(in: conversation)
            }

            for transcript in snapshot where !completedMessageIds.contains(transcript.id) {
                if transcript.text.count > previousTranscript.count,
                   transcript.text.hasPrefix(previousTranscript) {
                    let delta = String(transcript.text.dropFirst(previousTranscript.count))
                    if !delta.isEmpty {
                        continuation.yield(.transcriptDelta(delta))
                    }
                }

                if !transcript.text.isEmpty {
                    continuation.yield(.finalTranscript(transcript.text))
                    completedMessageIds.insert(transcript.id)
                    continuation.yield(.ended)
                    continuation.finish()
                    await MainActor.run {
                        _ = listeningConversations.removeValue(forKey: request.session.id)
                    }
                    return
                }

                previousTranscript = transcript.text
            }

            try await Task.sleep(for: .milliseconds(150))
        }
    }

    @MainActor
    func assistantTranscript(in conversation: Conversation) -> String {
        conversation.messages
            .filter { $0.role == .assistant }
            .flatMap(\.content)
            .compactMap(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    func userInputTranscripts(in conversation: Conversation) -> [(id: String, text: String)] {
        conversation.messages
            .filter { $0.role == .user }
            .compactMap { message in
                let text = message.content
                    .compactMap(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                return text.isEmpty ? nil : (message.id, text)
            }
    }

    nonisolated static func voice(from rawValue: String) -> Session.Voice {
        Session.Voice(rawValue: rawValue) ?? .marin
    }
}
#else
public actor OpenAIRealtimeVoiceClient: RealtimeVoiceClient {
    public init(
        credentialProvider: any RealtimeEphemeralKeyProvider,
        configuration: OpenAIRealtimeVoiceConfiguration = OpenAIRealtimeVoiceConfiguration()
    ) {}

    public func playSummary(for request: RealtimeSpeechRequest) async throws -> RealtimeSpeechResult {
        throw OpenAIRealtimeVoiceClientError.realtimePackageUnavailable
    }

    public func pausePlayback(sessionId: CodingSession.ID) async throws {
        throw OpenAIRealtimeVoiceClientError.realtimePackageUnavailable
    }

    public func startListening(for request: RealtimeListenRequest) async throws -> RealtimeListeningSession {
        throw OpenAIRealtimeVoiceClientError.realtimePackageUnavailable
    }
}
#endif
