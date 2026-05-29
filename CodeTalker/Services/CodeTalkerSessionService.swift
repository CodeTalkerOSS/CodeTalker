import Foundation

public actor CodeTalkerSessionService {
    private let repository: CodexSessionRepository
    private let realtimeVoiceClient: any RealtimeVoiceClient
    private let codexInputSink: (any CodexSessionInputSink)?

    public init(
        repository: CodexSessionRepository = CodexSessionRepository(),
        realtimeVoiceClient: any RealtimeVoiceClient,
        codexInputSink: (any CodexSessionInputSink)? = nil
    ) {
        self.repository = repository
        self.realtimeVoiceClient = realtimeVoiceClient
        self.codexInputSink = codexInputSink
    }

    public func listSessions() async throws -> [CodingSession] {
        try await repository.listSessions()
    }

    public func playSessionLatestResponse(_ sessionId: CodingSession.ID) async throws {
        let session = try await repository.session(id: sessionId)

        guard let assistantMessage = session.latestAssistantMessage, !assistantMessage.isEmpty else {
            throw CodeTalkerServiceError.noAssistantResponse(sessionId)
        }

        await repository.setRuntimeState(.speaking, for: sessionId)

        do {
            let result = try await realtimeVoiceClient.playSummary(
                for: RealtimeSpeechRequest(session: session, assistantMessage: assistantMessage)
            )
            await repository.recordSpokenSummary(result.spokenSummary, for: sessionId)
        } catch {
            await repository.setRuntimeState(.error, for: sessionId)
            throw error
        }
    }

    /// Speak text the agent supplied via `mcp__codetalker__speak` /
    /// `mcp__codetalker__ask`. Goes through the OpenAI realtime API
    /// (`gpt-realtime-2`) — natural voice, the same path the user heard
    /// working before.
    public func speakArbitraryMessage(
        _ text: String,
        in session: CodingSession
    ) async throws {
        VoiceDiagnosticLog.log("speak: session=\(session.id) chars=\(text.count)")
        await repository.setRuntimeState(.speaking, for: session.id)
        do {
            let result = try await realtimeVoiceClient.playSummary(
                for: RealtimeSpeechRequest(
                    session: session,
                    assistantMessage: text,
                    summaryInstruction: "Read the following short message aloud verbatim, in a natural conversational tone. Do not summarize, expand, or comment — just speak it."
                )
            )
            await repository.recordSpokenSummary(result.spokenSummary, for: session.id)
        } catch is CancellationError {
            await repository.setRuntimeState(.error, for: session.id)
            throw CancellationError()
        } catch {
            VoiceDiagnosticLog.log("speak ERROR: \(error)")
            await repository.setRuntimeState(.error, for: session.id)
            throw error
        }
    }

    public func announceSessionPermission(_ sessionId: CodingSession.ID) async throws {
        let session = try await repository.session(id: sessionId)
        let permissionText = session.latestPermissionPrompt ?? "Codex is requesting permission to continue."

        await repository.setRuntimeState(.speaking, for: sessionId)

        do {
            let result = try await realtimeVoiceClient.playSummary(
                for: RealtimeSpeechRequest(
                    session: session,
                    assistantMessage: permissionText,
                    summaryInstruction: "Read this Codex permission request aloud in one short, natural sentence, then ask the user whether to approve it."
                )
            )
            await repository.recordSpokenSummary(result.spokenSummary, for: sessionId)
        } catch {
            await repository.setRuntimeState(.error, for: sessionId)
            throw error
        }
    }

    public func pauseSessionResponse(_ sessionId: CodingSession.ID) async throws {
        try await realtimeVoiceClient.pausePlayback(sessionId: sessionId)
        await repository.setRuntimeState(.paused, for: sessionId)
    }

    /// Hard-stop: disconnect any persistent playback connection so the audio
    /// engine actually releases. Pair with `pauseSessionResponse` when the
    /// user presses Stop.
    public func resetPlayback() async {
        await realtimeVoiceClient.resetPlayback()
    }

    /// Opens a mic capture window via Apple's local speech recognition, waits
    /// for the user to finish speaking (silence detection, or `timeout`),
    /// submits the transcript back via the input sink, and returns it.
    /// Switched off the realtime API for listening — the OpenAI realtime
    /// session.update kept getting rejected (max_response_output_tokens,
    /// modalities, temperature, …) which silently disabled transcription on
    /// the server and left the model in default conversational mode (audio
    /// echoes, empty input log). SFSpeechRecognizer is purpose-built for
    /// "mic in → text out" and has no API schema for the server to reject.
    @discardableResult
    public func captureAndSubmitResponse(
        _ sessionId: CodingSession.ID,
        timeout: Duration = .seconds(30)
    ) async throws -> String? {
        let session = try await repository.session(id: sessionId)
        await repository.setRuntimeState(.listening, for: sessionId)

        let dictation = WhisperDictation()
        do {
            let total = TimeInterval(timeout.components.seconds)
            let transcript = try await dictation.transcribeOnce(
                silenceTimeout: 1.2,
                totalTimeout: total > 0 ? total : 30
            )
            if let transcript, !transcript.isEmpty {
                await handleFinalTranscript(transcript, session: session)
                return transcript
            }
            await repository.clearRuntimeState(for: sessionId)
            return nil
        } catch {
            await repository.setRuntimeState(.error, for: sessionId)
            throw error
        }
    }

    /// Manual mic flow — drives Apple speech recognition the same way the
    /// auto-flow does, so both paths share one transcription pipeline.
    @discardableResult
    public func listenForSession(
        _ sessionId: CodingSession.ID,
        onProgress: @Sendable @escaping (RealtimeListenEvent) async -> Void = { _ in }
    ) async throws -> CodeTalkerListeningSession {
        let session = try await repository.session(id: sessionId)
        await repository.setRuntimeState(.listening, for: sessionId)

        let dictation = WhisperDictation()
        let task = Task { [repository] in
            do {
                let transcript = try await dictation.transcribeOnce(
                    silenceTimeout: 1.2,
                    totalTimeout: 30
                )
                if let transcript, !transcript.isEmpty {
                    await onProgress(.finalTranscript(transcript))
                    await handleFinalTranscript(transcript, session: session)
                }
                await onProgress(.ended)
                await repository.clearRuntimeState(for: sessionId)
            } catch is CancellationError {
                await onProgress(.ended)
                await repository.clearRuntimeState(for: sessionId)
            } catch {
                await onProgress(.failed(String(describing: error)))
                await repository.setRuntimeState(.error, for: sessionId)
            }
        }

        return CodeTalkerListeningSession(sessionId: sessionId) { [repository] in
            task.cancel()
            await repository.clearRuntimeState(for: sessionId)
        }
    }

    private func handleFinalTranscript(_ prompt: String, session: CodingSession) async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return
        }

        guard let codexInputSink else {
            await repository.setRuntimeState(.error, for: session.id)
            return
        }

        do {
            try await codexInputSink.submitPrompt(trimmedPrompt, to: session)
            await repository.recordSubmittedVoicePrompt(trimmedPrompt, for: session.id)
        } catch {
            await repository.setRuntimeState(.error, for: session.id)
        }
    }
}
