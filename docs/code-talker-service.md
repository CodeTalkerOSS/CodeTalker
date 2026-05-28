# Code Talker Swift Service

The SwiftUI client should talk to `CodeTalkerSessionService`. The service is UI-free: it exposes the app-facing operations and delegates GPT-realtime-2 work to `RealtimeVoiceClient`. The concrete OpenAI implementation is `OpenAIRealtimeVoiceClient`.

## Public Operations

```swift
public actor CodeTalkerSessionService {
    public func listSessions() async throws -> [CodingSession]
    public func playSessionLatestResponse(_ sessionId: CodingSession.ID) async throws
    public func pauseSessionResponse(_ sessionId: CodingSession.ID) async throws

    @discardableResult
    public func listenForSession(_ sessionId: CodingSession.ID) async throws -> CodeTalkerListeningSession
}
```

`listSessions` derives sessions from the Codex hook JSONL log. `playSessionLatestResponse` asks the realtime client to summarize and speak the latest assistant response. `pauseSessionResponse` forwards pause to the realtime client and marks the session paused. `listenForSession` starts realtime listening, then submits final transcript text back to Codex through `CodexSessionInputSink`.

## Realtime Boundary

The GPT-realtime-2 implementation conforms to:

```swift
public protocol RealtimeVoiceClient: Sendable {
    func playSummary(for request: RealtimeSpeechRequest) async throws -> RealtimeSpeechResult
    func pausePlayback(sessionId: CodingSession.ID) async throws
    func startListening(for request: RealtimeListenRequest) async throws -> RealtimeListeningSession
}
```

`OpenAIRealtimeVoiceClient` uses `m1guelpf/swift-realtime-openai` when the `RealtimeAPI` module is available. It uses the package's high-level `Conversation` API for WebRTC, microphone streaming, output playback, session updates, and cancellation.

The Xcode target depends on the package product `RealtimeAPI`, pinned through `Package.resolved`.

```swift
let realtimeClient = OpenAIRealtimeVoiceClient(
    credentialProvider: ClosureRealtimeEphemeralKeyProvider {
        try await fetchRealtimeEphemeralKey()
    },
    configuration: OpenAIRealtimeVoiceConfiguration(
        model: "gpt-realtime-2",
        voice: "marin"
    )
)

let service = CodeTalkerSessionService(
    realtimeVoiceClient: realtimeClient,
    codexInputSink: codexInputSink
)
```

For speech replay, the client opens a realtime session, sends the latest Codex response as text with summary instructions, and lets `Conversation` stream the spoken audio response. For hover dictation, it opens a realtime session with input transcription and VAD configured with `createResponse: false`; the final transcript is forwarded to `CodexSessionInputSink`.

The package currently exposes `Session.AudioFormat` as a public type without a usable public memberwise initializer, so this service does not override input/output audio format. It uses the session's negotiated/default audio formats and configures the exposed controls: model, voice, speed, transcription, VAD, temperature, max tokens, and instructions.

## Codex Input Boundary

Voice-to-Codex submission is injected:

```swift
public protocol CodexSessionInputSink: Sendable {
    func submitPrompt(_ prompt: String, to session: CodingSession) async throws
}
```

The UI/app integration can implement this with whatever mechanism it uses to send a message to the active Codex session. If no sink is provided, `listenForSession` can still start realtime listening, but final transcript submission marks the session as `error`.

## Hook State

Hook events are read by `CodexSessionRepository` from:

```text
~/.codetalker/codex-events.jsonl
```

Override that path with `CODETALKER_EVENT_LOG` when running multiple demos or tests. The same JSONL file is written by `.codex/hooks/codetalker_hook.swift`.
