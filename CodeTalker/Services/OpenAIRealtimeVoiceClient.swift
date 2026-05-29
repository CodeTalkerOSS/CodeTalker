import Foundation

#if canImport(RealtimeAPI)
import RealtimeAPI
#endif

/// File-based diagnostic log for the voice path. Tail `~/.codetalker/listening-debug.log`
/// while testing to see exactly where the listen flow stalls (connection,
/// audio start, transcription, sink write).
nonisolated public enum VoiceDiagnosticLog {
    nonisolated public static func log(_ message: String) {
        let env = ProcessInfo.processInfo.environment
        let path = env["CODETALKER_DEBUG_LOG"]
            ?? "\(NSHomeDirectory())/.codetalker/listening-debug.log"
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)

        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

#if canImport(RealtimeAPI)
public actor OpenAIRealtimeVoiceClient: RealtimeVoiceClient {
    private let credentialProvider: any RealtimeEphemeralKeyProvider
    private let configuration: OpenAIRealtimeVoiceConfiguration

    // Single persistent playback conversation. Reusing one realtime session is
    // the only reliable way to prevent overlapping audio: the OpenAI server
    // serializes responses within a session, so successive playSummary() calls
    // can never speak at the same time. (outputAudioBufferClear only stops
    // server-side generation — WebRTC frames already streamed to the speaker
    // keep playing until the peer disconnects, which is what caused overlap.)
    @MainActor private var sharedPlaybackConversation: Conversation?
    @MainActor private var listeningConversations: [CodingSession.ID: Conversation] = [:]

    public init(
        credentialProvider: any RealtimeEphemeralKeyProvider,
        configuration: OpenAIRealtimeVoiceConfiguration = OpenAIRealtimeVoiceConfiguration()
    ) {
        self.credentialProvider = credentialProvider
        self.configuration = configuration
    }

    public func playSummary(for request: RealtimeSpeechRequest) async throws -> RealtimeSpeechResult {
        VoiceDiagnosticLog.log("playSummary: session=\(request.session.id) chars=\(request.assistantMessage.count)")
        let conversation = try await getOrCreatePlaybackConversation()

        // Baseline the assistant message count so we only collect transcript
        // from the new response, not from earlier turns in the same session.
        let baseline = await MainActor.run {
            conversation.messages.filter { $0.role == .assistant }.count
        }

        let prompt = """
        \(request.summaryInstruction)

        Codex response:
        \(request.assistantMessage)
        """

        try await MainActor.run {
            try conversation.send(from: .user, text: prompt)
        }

        let summary = try await waitForAssistantTranscript(
            in: conversation,
            afterAssistantCount: baseline,
            timeout: .seconds(45)
        )
        return RealtimeSpeechResult(spokenSummary: summary)
    }

    /// Lazily build (or reconnect) the single playback conversation.
    private func getOrCreatePlaybackConversation() async throws -> Conversation {
        if let existing = await MainActor.run(body: { sharedPlaybackConversation }) {
            let status = await MainActor.run { existing.status }
            if status == .connected {
                return existing
            }
            // Drop the stale one so a fresh peer is created.
            await MainActor.run { sharedPlaybackConversation = nil }
        }

        let conversation = try await makeConversation(mode: .speechSummary)
        // Mute the mic on the playback peer immediately. This peer only
        // SPEAKS — it should never receive audio. Without this, anything
        // the user says while the model is speaking gets captured by the
        // peer's WebRTC audio track, the server VAD commits it, and the
        // model generates a spoken response — i.e., echoes the user back.
        await MainActor.run {
            sharedPlaybackConversation = conversation
            conversation.muted = true
        }

        // Forward any server-side errors into the diagnostic log. Without
        // this, a rejected session.update field (or any per-event error)
        // silently disables audio output and we get a hung speak with no
        // explanation.
        let errorsStream = await MainActor.run { conversation.errors }
        Task {
            for await err in errorsStream {
                VoiceDiagnosticLog.log("playback realtime ERROR: \(err)")
            }
        }

        // Forward isModelSpeaking transitions so we can prove whether the
        // server even started generating audio.
        Task {
            var wasSpeaking = false
            while !Task.isCancelled {
                let speaking = await MainActor.run { conversation.isModelSpeaking }
                if speaking != wasSpeaking {
                    VoiceDiagnosticLog.log("playback isModelSpeaking → \(speaking)")
                    wasSpeaking = speaking
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        return conversation
    }

    public func pausePlayback(sessionId: CodingSession.ID) async throws {
        // Server-side cancel + buffer clear. Keep the conversation alive — the
        // queue's next turn will re-use it.
        guard let conversation = await MainActor.run(body: { sharedPlaybackConversation }) else {
            return
        }

        try await MainActor.run {
            try conversation.send(event: .cancelResponse())
            try conversation.send(event: .outputAudioBufferClear())
        }
    }

    /// Hard-disconnect: drop the strong reference so Conversation's deinit
    /// calls client.disconnect() and the WebRTC audio engine releases. Used
    /// by Stop to actually silence audio that's already buffered locally
    /// (outputAudioBufferClear is a WebSocket-only event — over WebRTC it
    /// asks the server to halt generation but doesn't drop frames in flight).
    public func resetPlayback() async {
        VoiceDiagnosticLog.log("resetPlayback: disconnecting persistent playback peer")
        await MainActor.run {
            sharedPlaybackConversation = nil
        }
    }

    public func startListening(for request: RealtimeListenRequest) async throws -> RealtimeListeningSession {
        // NOTE: this realtime-API listen path is no longer used by the app;
        // `WhisperDictation` handles capture. Kept for protocol conformance.
        let conversation = try await makeConversation(mode: .codexDictation)
        await MainActor.run {
            listeningConversations[request.session.id] = conversation
        }
        let errorsStream = await MainActor.run { conversation.errors }
        let errorTask = Task {
            for await err in errorsStream {
                VoiceDiagnosticLog.log("listen ERROR: \(err)")
            }
        }
        _ = errorTask
        let speechTask = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) } }
        _ = speechTask

        // Use makeStream so the stop closure can finish the event stream and
        // cancel the polling task synchronously — previously `stop()` only
        // cleared the audio buffer, leaving `for await event in events` blocked
        // forever and the worker stuck in `captureAndSubmitResponse`.
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeListenEvent.self)

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

        continuation.onTermination = { [weak self] _ in
            task.cancel()
            speechTask.cancel()
            errorTask.cancel()
            guard let self else { return }
            Task { @MainActor in
                self.listeningConversations.removeValue(forKey: request.session.id)
            }
        }

        return RealtimeListeningSession(events: stream) { [weak self] in
            // Cancel polling, finish the stream so the consumer's for-await
            // exits, and tear down the listening conversation.
            task.cancel()
            speechTask.cancel()
            errorTask.cancel()
            continuation.yield(.ended)
            continuation.finish()
            guard let self else { return }
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
        // gpt-realtime-2 rejects `modalities`, `max_response_output_tokens`,
        // and `temperature` on session.update — each rejection drops the
        // ENTIRE update so transcription / turn-detection overrides never
        // applied, leaving the model in default conversational mode. We're
        // moving listening to SFSpeechRecognizer anyway; for now just keep
        // session.update minimal so this build at least attempts to be
        // usable on the speak side.
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
            // Leave modalities at the base [.text, .audio]. Restricting to
            // [.text] previously appeared to disable audio handling on the
            // session — input transcription would never run. createResponse:
            // false on the VAD already stops the model from speaking, so we
            // get dictation without a spoken reply either way.
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

        // Short silence threshold so dictation feels responsive: ~800 ms after
        // the user stops talking, the server commits the buffer and runs
        // transcription. `createResponse: false` keeps the model from
        // generating a reply audibly — we only want the transcript.
        return .serverVad(
            createResponse: createResponse,
            idleTimeout: 5_000,
            interruptResponse: true,
            prefixPaddingMs: 300,
            silenceDurationMs: 800,
            threshold: 0.5
        )
    }

    func waitForAssistantTranscript(
        in conversation: Conversation,
        afterAssistantCount baseline: Int = 0,
        timeout: Duration
    ) async throws -> String {
        let started = ContinuousClock.now
        var observedModelSpeaking = false
        var lastTranscript = ""
        var lastTranscriptChange = started

        while ContinuousClock.now - started < timeout {
            try Task.checkCancellation()

            let snapshot = await MainActor.run {
                assistantTranscript(in: conversation, afterAssistantCount: baseline)
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

            // Primary exit: we saw the model start speaking and stop. That's
            // the signal that the audio phase is complete; the transcript
            // text is *not* required (gpt-realtime-2 with default session
            // config doesn't always emit `response.audio_transcript.*` deltas,
            // which made `playSummary` hang indefinitely after audio ended).
            if observedModelSpeaking, !isModelSpeaking {
                return lastTranscript  // may be empty; caller doesn't need it
            }
            // Edge: model never registered as speaking but transcript stable
            // (server emitted text-only response).
            if !lastTranscript.isEmpty, !isModelSpeaking,
               ContinuousClock.now - lastTranscriptChange > Duration.seconds(6) {
                return lastTranscript
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
    func assistantTranscript(in conversation: Conversation, afterAssistantCount baseline: Int = 0) -> String {
        let assistants = conversation.messages.filter { $0.role == .assistant }
        return assistants
            .dropFirst(baseline)
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

    public func resetPlayback() async {}
}
#endif
