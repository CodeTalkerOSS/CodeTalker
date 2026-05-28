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

    public func pauseSessionResponse(_ sessionId: CodingSession.ID) async throws {
        try await realtimeVoiceClient.pausePlayback(sessionId: sessionId)
        await repository.setRuntimeState(.paused, for: sessionId)
    }

    @discardableResult
    public func listenForSession(_ sessionId: CodingSession.ID) async throws -> CodeTalkerListeningSession {
        let session = try await repository.session(id: sessionId)
        let realtimeSession = try await realtimeVoiceClient.startListening(
            for: RealtimeListenRequest(session: session)
        )

        await repository.setRuntimeState(.listening, for: sessionId)

        let eventTask = Task {
            for await event in realtimeSession.events {
                switch event {
                case .transcriptDelta:
                    continue
                case .finalTranscript(let prompt):
                    await handleFinalTranscript(prompt, session: session)
                case .failed:
                    await repository.setRuntimeState(.error, for: sessionId)
                    return
                case .ended:
                    await repository.clearRuntimeState(for: sessionId)
                    return
                }
            }

            await repository.clearRuntimeState(for: sessionId)
        }

        return CodeTalkerListeningSession(sessionId: sessionId) {
            eventTask.cancel()
            await realtimeSession.stop()
            await self.repository.clearRuntimeState(for: sessionId)
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
