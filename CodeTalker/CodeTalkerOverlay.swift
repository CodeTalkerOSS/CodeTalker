#if os(macOS)
import AppKit
import AVFoundation

private enum OverlayMetrics {
    static let collapsedWidth: CGFloat = 14
    static let expandedWidth: CGFloat = 304
    static let collapsedHeight: CGFloat = 188
    static let expandedHeight: CGFloat = 540
}

@MainActor
final class CodeTalkerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Mic permission only — Speech Recognition (SFSpeechRecognizer) is
        // no longer used; Whisper handles transcription server-side.
        requestMicrophoneAccess()
        CodeTalkerOverlayController.shared.show()
    }

    private func requestMicrophoneAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            CodeTalkerOverlayModel.shared.setMicrophoneAuthorized(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    CodeTalkerOverlayModel.shared.setMicrophoneAuthorized(granted)
                }
            }
        case .denied, .restricted:
            CodeTalkerOverlayModel.shared.setMicrophoneAuthorized(false)
        @unknown default:
            CodeTalkerOverlayModel.shared.setMicrophoneAuthorized(false)
        }
    }
}

nonisolated public struct EnvironmentRealtimeEphemeralKeyProvider: RealtimeEphemeralKeyProvider {
    public init() {}

    public func ephemeralKey() async throws -> String {
        let environment = ProcessInfo.processInfo.environment
        // A standard `sk-...` key works directly against the realtime /v1/realtime/calls
        // endpoint for a local client, so OPENAI_API_KEY is accepted alongside the
        // ephemeral-key variables. Set it in the Xcode scheme's environment.
        for key in [
            "CODETALKER_REALTIME_EPHEMERAL_KEY",
            "OPENAI_REALTIME_EPHEMERAL_KEY",
            "OPENAI_API_KEY"
        ] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        throw OpenAIRealtimeVoiceClientError.missingRealtimeEphemeralKey
    }
}

/// Manual-mic captures (row mic button) land on the clipboard. The primary
/// voice channel is the MCP server's `ask` tool, which has its own reply-file
/// transport; this sink is just a fallback for the user-initiated case.
nonisolated public struct ClipboardCodexInputSink: CodexSessionInputSink {
    public init() {}

    public func submitPrompt(_ prompt: String, to session: CodingSession) async throws {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
        }
    }
}

/// Coding-agent identity, used for per-row color and symbol so users can tell
/// Codex / Claude / Cursor sessions apart at a glance.
private enum AgentKind {
    case codex
    case claudeCode
    case cursor
    case unknown

    init(rawValue: String?) {
        switch rawValue {
        case "codex": self = .codex
        case "claude_code": self = .claudeCode
        case "cursor": self = .cursor
        default: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .codex:      return "Codex"
        case .claudeCode: return "Claude"
        case .cursor:     return "Cursor"
        case .unknown:    return "Agent"
        }
    }

    var color: NSColor {
        switch self {
        case .codex:      return NSColor.systemOrange
        case .claudeCode: return NSColor.systemPurple
        case .cursor:     return NSColor.systemBlue
        case .unknown:    return NSColor.systemGray
        }
    }

    /// Symbol shown when the session is idle (state-active rows override with
    /// the state glyph — mic, speaker, lock, …).
    var idleSymbol: String {
        switch self {
        case .codex:      return "chevron.left.forwardslash.chevron.right"
        case .claudeCode: return "sparkles"
        case .cursor:     return "cursorarrow.rays"
        case .unknown:    return "terminal.fill"
        }
    }
}

private struct OverlaySessionRow {
    let id: CodingSession.ID
    let name: String
    let subtitle: String
    let elapsedTime: String
    let summary: String
    let isRunning: Bool
    let agent: AgentKind
    let state: CodingSessionState
    let isSelected: Bool
    let canSpeak: Bool
    let hasPlayed: Bool

    init(session: CodingSession, isSelected: Bool) {
        self.id = session.id
        self.agent = AgentKind(rawValue: session.agent)
        self.name = Self.displayTitle(for: session)
        self.subtitle = Self.subtitle(for: session, agent: agent)
        self.elapsedTime = Self.relativeTime(since: session.updatedAt)
        self.summary = session.latestSpokenSummary
            ?? session.latestAssistantMessage
            ?? session.latestPermissionPrompt
            ?? "Waiting for activity"
        self.isRunning = [.queued, .waitingForResponse, .speaking, .listening].contains(session.state)
        self.state = session.state
        self.isSelected = isSelected
        self.canSpeak = session.latestAssistantMessage?.isEmpty == false
            || session.latestPermissionPrompt?.isEmpty == false
        self.hasPlayed = session.latestSpokenSummary?.isEmpty == false
    }

    /// Prefer the user's most recent prompt as the row title (most identifying).
    /// Fall back to the repo / cwd basename when no prompt has come through yet.
    private static func displayTitle(for session: CodingSession) -> String {
        if let prompt = session.latestPrompt?
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            return Self.truncate(prompt, max: 48)
        }
        if !session.title.isEmpty { return session.title }
        if let cwd = session.cwd {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return "Untitled session"
    }

    private static func subtitle(for session: CodingSession, agent: AgentKind) -> String {
        var parts: [String] = [agent.displayName]
        if let cwd = session.cwd {
            parts.append(URL(fileURLWithPath: cwd).lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }

    private static func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    static func relativeTime(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }

        return "\(minutes / 60)h"
    }

}

@MainActor
private final class CodeTalkerOverlayModel {
    static let shared = CodeTalkerOverlayModel()

    enum VoiceTurnKind {
        case response
        case permission
    }

    private struct VoiceTurnRequest: Equatable {
        let sessionId: CodingSession.ID
        let kind: VoiceTurnKind
        /// Auto-turns include the VAD reply window; manual play / replay does not.
        let allowReply: Bool
        /// If set, speak this verbatim text instead of the session's stored
        /// latest message — used by `mcp__codetalker__speak`/`ask`.
        let mcpText: String?
        /// If set, the captured reply (when allowReply=true) is written to
        /// `~/.codetalker/mcp-replies/<this>.txt` so the MCP `ask` call can
        /// return it to the agent as the tool result.
        let mcpReplyId: String?

        init(
            sessionId: CodingSession.ID,
            kind: VoiceTurnKind,
            allowReply: Bool,
            mcpText: String? = nil,
            mcpReplyId: String? = nil
        ) {
            self.sessionId = sessionId
            self.kind = kind
            self.allowReply = allowReply
            self.mcpText = mcpText
            self.mcpReplyId = mcpReplyId
        }
    }

    private let service: CodeTalkerSessionService
    private var refreshTask: Task<Void, Never>?
    private var listeningSession: CodeTalkerListeningSession?
    private var manualListenSessionId: CodingSession.ID?
    private var currentSessions: [CodingSession] = []

    // Speech queue: only one session speaks at a time. New triggers (auto-detect,
    // hover, manual play) append a request; a single worker drains the queue in
    // FIFO order. `activeTurnSessionId` is the session currently in flight,
    // and `currentTurnTask` is the cancellable task running it.
    // `activeMcpReplyId` is set while the in-flight turn was triggered by an
    // MCP `ask` call — when Stop fires, we write a cancel sentinel to the
    // matching reply file so the blocked MCP server returns to the agent.
    private var voiceQueue: [VoiceTurnRequest] = []
    private var voiceWorker: Task<Void, Never>?
    private var currentTurnTask: Task<Void, Never>?
    private var activeTurnSessionId: CodingSession.ID?
    private var activeMcpReplyId: String?

    // MCP event tail state — remembers which event ids we've already
    // converted into voice turns so the poll never double-fires.
    // `mcpEventsCutoff` is set at model init; any event whose `created_at`
    // is older than that timestamp is dropped (it's from a prior app run).
    // This avoids the seed-on-first-file-found race where the very first
    // event a server writes after launch gets eaten by the seeder.
    private var consumedMCPEventIds: Set<String> = []
    private let mcpEventsCutoff: Date = Date()

    private(set) var rows: [OverlaySessionRow] = []
    private(set) var isListening = false
    private(set) var statusMessage = "Loading sessions..."
    private(set) var microphoneAuthorized: Bool = true
    private var selectedSessionId: CodingSession.ID?

    var onChange: (() -> Void)?

    init(
        service: CodeTalkerSessionService = CodeTalkerSessionService(
            realtimeVoiceClient: OpenAIRealtimeVoiceClient(
                credentialProvider: EnvironmentRealtimeEphemeralKeyProvider()
            ),
            codexInputSink: ClipboardCodexInputSink()
        )
    ) {
        self.service = service
    }

    func setMicrophoneAuthorized(_ authorized: Bool) {
        microphoneAuthorized = authorized
        if !authorized {
            statusMessage = "Microphone access denied — System Settings → Privacy → Microphone → CodeTalker"
        }
        onChange?()
    }

    func startRefreshing() {
        guard refreshTask == nil else { return }

        refreshTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func selectSession(_ id: CodingSession.ID) {
        selectedSessionId = id
        rows = currentSessions.map { session in
            OverlaySessionRow(session: session, isSelected: session.id == id)
        }
        onChange?()

        Task {
            await refresh()
        }
    }

    /// Mic button. Single-purpose toggle:
    ///   - If anything is speaking, listening, or queued → stop *everything*.
    ///   - Otherwise → open a manual listen for the selected session.
    /// No more accidental "switches to another session" surprises.
    func toggleListening() {
        Task {
            if isListening || isSpeakingOrQueued {
                await stopAllVoice()
            } else {
                await startListening()
            }
        }
    }

    /// Cancel the queue, in-flight turn, and any manual listening. Used by the
    /// mic button when something is in flight.
    private func stopAllVoice() async {
        VoiceDiagnosticLog.log("stopAllVoice: active=\(activeTurnSessionId ?? "nil") queue=\(voiceQueue.count) mcpReply=\(activeMcpReplyId ?? "nil")")
        // Unblock the MCP server if an `ask` was waiting, so the agent's
        // tool call returns instead of hanging until its timeout.
        if let mcpReplyId = activeMcpReplyId {
            Self.writeMCPReply("(stopped)", for: mcpReplyId)
        }
        // Also drop any queued MCP asks so the same thing happens to them.
        for queued in voiceQueue {
            if let replyId = queued.mcpReplyId {
                Self.writeMCPReply("(stopped)", for: replyId)
            }
        }
        voiceQueue.removeAll()
        let stoppingId = activeTurnSessionId
        if let stoppingId {
            try? await service.pauseSessionResponse(stoppingId)
        }
        currentTurnTask?.cancel()
        voiceWorker?.cancel()
        voiceWorker = nil
        activeTurnSessionId = nil

        await listeningSession?.stop()
        listeningSession = nil
        isListening = false

        // Hard-disconnect the WebRTC playback peer so the audio engine
        // actually stops — server-side cancel events alone don't drop the
        // frames already streamed locally.
        await service.resetPlayback()

        // Optimistic UI flip so the row's stop button immediately becomes a
        // replay icon, without waiting for the next 2s refresh.
        if let stoppingId,
           let idx = currentSessions.firstIndex(where: { $0.id == stoppingId }) {
            currentSessions[idx].state = .paused
        }
        statusMessage = "Stopped"
        rebuildRows()
        onChange?()
    }

    private func rebuildRows() {
        rows = currentSessions.map { session in
            OverlaySessionRow(session: session, isSelected: session.id == selectedSessionId)
        }
    }

    /// Talk to a specific session: stop anything in flight, free the mic from
    /// the persistent playback peer, then open a listening window for this
    /// session. The transcribed reply is submitted via the input sink and
    /// picked up by the agent's Stop hook (decision:block / followup_message).
    func talkToSession(_ id: CodingSession.ID) {
        selectedSessionId = id
        Task {
            await stopAllVoice()
            guard microphoneAuthorized else {
                statusMessage = "Microphone access denied — System Settings → Privacy → Microphone → CodeTalker"
                onChange?()
                return
            }
            await startListening()
        }
    }

    /// Stop a session — handles every active state:
    ///   • worker auto-turn for this session (speaking or auto-listening)
    ///   • manual listening on this session
    ///   • a queued turn waiting on this session
    /// The queue continues with the next item either way. If the in-flight
    /// turn was an MCP `ask`, also write a `(stopped)` sentinel to the MCP
    /// reply file so the blocked tool call returns.
    func stopSpeaking(for id: CodingSession.ID) {
        // Unblock any MCP asks for this session.
        for queued in voiceQueue where queued.sessionId == id {
            if let replyId = queued.mcpReplyId {
                Self.writeMCPReply("(stopped)", for: replyId)
            }
        }
        let removed = voiceQueue.contains { $0.sessionId == id }
        voiceQueue.removeAll { $0.sessionId == id }

        var didStop = false

        if activeTurnSessionId == id {
            if let mcpReplyId = activeMcpReplyId {
                Self.writeMCPReply("(stopped)", for: mcpReplyId)
            }
            // Yank the runTurn task and hard-disconnect WebRTC so the audio
            // engine releases. Server-side cancelResponse alone doesn't drop
            // frames that are already buffered locally over WebRTC.
            currentTurnTask?.cancel()
            Task {
                try? await service.pauseSessionResponse(id)
                await service.resetPlayback()
            }
            didStop = true
        }

        if manualListenSessionId == id {
            // Stop manual listening this very tick — release listening
            // session, flip isListening so the UI updates.
            let session = listeningSession
            listeningSession = nil
            manualListenSessionId = nil
            isListening = false
            Task { await session?.stop() }
            didStop = true
        }

        if didStop {
            // Optimistic UI flip — the row's stop button becomes a mic icon
            // immediately so the user sees the action took effect.
            if let idx = currentSessions.firstIndex(where: { $0.id == id }) {
                currentSessions[idx].state = .paused
            }
            statusMessage = "Stopped" + queueSuffix()
        } else if removed {
            statusMessage = "Removed from queue" + queueSuffix()
        }
        rebuildRows()
        onChange?()
    }

    /// True while any turn is speaking or waiting in the queue. Used to give
    /// the mic button stop-everything behavior when activity is in flight.
    var isSpeakingOrQueued: Bool {
        activeTurnSessionId != nil || !voiceQueue.isEmpty
    }

    /// Append a turn to the queue (deduping identical pending requests) and
    /// kick the worker if it's idle. Single source of truth for the FIFO order.
    private func enqueueVoiceTurn(_ turn: VoiceTurnRequest) {
        if voiceQueue.contains(turn) { return }
        voiceQueue.append(turn)
        onChange?()
        startQueueWorkerIfNeeded()
    }

    private func startQueueWorkerIfNeeded() {
        guard voiceWorker == nil else { return }
        voiceWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.voiceQueue.isEmpty {
                let next = self.voiceQueue.removeFirst()
                self.activeTurnSessionId = next.sessionId
                self.activeMcpReplyId = next.mcpReplyId
                self.selectedSessionId = next.sessionId
                self.onChange?()

                // Wrap the turn in its own cancellable task so stopSpeaking
                // can yank just this turn without killing the worker.
                let turnTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.runTurn(next)
                }
                self.currentTurnTask = turnTask
                _ = await turnTask.value
                self.currentTurnTask = nil
                self.activeTurnSessionId = nil
                self.activeMcpReplyId = nil
                self.onChange?()
            }
            self.voiceWorker = nil
            self.onChange?()
        }
    }

    /// Executes a single queued turn: speak the response / permission, then
    /// optionally open the VAD reply window and submit the transcript.
    private func runTurn(_ turn: VoiceTurnRequest) async {
        VoiceDiagnosticLog.log("runTurn: \(turn.sessionId) kind=\(turn.kind) allowReply=\(turn.allowReply)")
        do {
            if let mcpText = turn.mcpText {
                statusMessage = (turn.mcpReplyId != nil
                                 ? "Agent is asking via voice..."
                                 : "Agent says...") + queueSuffix()
                onChange?()
                // Build a lightweight CodingSession to feed the realtime client
                // since this turn may not correspond to a real Codex session.
                let session = currentSessions.first(where: { $0.id == turn.sessionId })
                    ?? CodingSession(id: turn.sessionId, title: "Code Talker", cwd: nil)
                try await service.speakArbitraryMessage(mcpText, in: session)
            } else {
                switch turn.kind {
                case .permission:
                    statusMessage = "Speaking permission request..." + queueSuffix()
                    onChange?()
                    try await service.announceSessionPermission(turn.sessionId)
                case .response:
                    statusMessage = "Speaking latest response..." + queueSuffix()
                    onChange?()
                    try await service.playSessionLatestResponse(turn.sessionId)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            VoiceDiagnosticLog.log("runTurn speak ERROR: \(error)")
            statusMessage = "Could not speak: \(String(describing: error))"
            onChange?()
            return
        }

        guard turn.allowReply else {
            statusMessage = "Finished speaking" + queueSuffix()
            onChange?()
            await refresh()
            return
        }

        guard microphoneAuthorized else {
            VoiceDiagnosticLog.log("runTurn ABORT: mic not authorized")
            statusMessage = "Microphone access denied — System Settings → Privacy → Microphone → CodeTalker"
            onChange?()
            return
        }

        // Free the mic for the listening peer. The persistent playback peer
        // also has audio.input configured, and on macOS two simultaneous
        // realtime peers fight for the input track — transcription on the
        // listening peer silently never fires. Disconnect playback now; the
        // next speak turn will lazily reconnect.
        await service.resetPlayback()

        statusMessage = "Listening for your reply..." + queueSuffix()
        isListening = true
        onChange?()

        defer { isListening = false }

        do {
            let reply = try await service.captureAndSubmitResponse(turn.sessionId)
            // If this turn originated from an MCP `ask`, hand the transcript
            // back to the MCP server via the reply file — that's how the
            // tool call returns text to the agent.
            if let replyId = turn.mcpReplyId, let reply, !reply.isEmpty {
                Self.writeMCPReply(reply, for: replyId)
            }
            statusMessage = (reply?.isEmpty == false)
                ? "Sent your reply"
                : "No reply captured (try again — speak then pause)"
            await refresh()
        } catch is CancellationError {
            return
        } catch {
            statusMessage = "Could not capture reply: \(String(describing: error))"
            onChange?()
        }
    }

    /// Tails `~/.codetalker/mcp-events.jsonl` for new `speak` / `ask` events
    /// from the codetalker MCP server and enqueues voice turns. Events whose
    /// `created_at` is older than the app's launch timestamp are treated as
    /// already-handled (they came from a prior session).
    private func processMCPEvents() {
        let url = Self.mcpEventsURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }

        let targetSessionId = currentSessions.first?.id ?? "mcp:default"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = obj["id"] as? String else { continue }
            if consumedMCPEventIds.contains(id) { continue }

            // Drop events older than our launch cutoff — they belong to a
            // previous app run and are not for us to handle.
            if let createdStr = obj["created_at"] as? String,
               let createdAt = iso.date(from: createdStr),
               createdAt < mcpEventsCutoff {
                consumedMCPEventIds.insert(id)
                continue
            }

            guard let type = obj["type"] as? String else { continue }
            consumedMCPEventIds.insert(id)
            VoiceDiagnosticLog.log("processMCPEvents: handling \(type) id=\(id)")

            switch type {
            case "speak":
                guard let message = obj["message"] as? String, !message.isEmpty else { continue }
                enqueueVoiceTurn(VoiceTurnRequest(
                    sessionId: targetSessionId,
                    kind: .response,
                    allowReply: false,
                    mcpText: message
                ))

            case "ask":
                guard let question = obj["question"] as? String, !question.isEmpty else { continue }
                enqueueVoiceTurn(VoiceTurnRequest(
                    sessionId: targetSessionId,
                    kind: .response,
                    allowReply: true,
                    mcpText: question,
                    mcpReplyId: id
                ))

            default:
                continue
            }
        }
    }

    private static func mcpEventsURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let path = env["CODETALKER_DIR"].map { "\($0)/mcp-events.jsonl" }
            ?? "\(NSHomeDirectory())/.codetalker/mcp-events.jsonl"
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    private static func mcpReplyURL(for replyId: String) -> URL {
        let env = ProcessInfo.processInfo.environment
        let dirPath = env["CODETALKER_DIR"].map { "\($0)/mcp-replies" }
            ?? "\(NSHomeDirectory())/.codetalker/mcp-replies"
        let dir = URL(fileURLWithPath: NSString(string: dirPath).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(replyId).txt")
    }

    private static func writeMCPReply(_ reply: String, for replyId: String) {
        let url = mcpReplyURL(for: replyId)
        try? reply.write(to: url, atomically: true, encoding: .utf8)
    }

    private func queueSuffix() -> String {
        voiceQueue.isEmpty ? "" : " · \(voiceQueue.count) queued"
    }

    func refresh() async {
        do {
            let sessions = try await service.listSessions()
            currentSessions = sessions
            if selectedSessionId == nil {
                selectedSessionId = sessions.first?.id
            } else if let selectedSessionId, !sessions.contains(where: { $0.id == selectedSessionId }) {
                self.selectedSessionId = sessions.first?.id
            }

            rows = sessions.map { session in
                OverlaySessionRow(session: session, isSelected: session.id == selectedSessionId)
            }

            let finishedListening = isListening
                && selectedSessionId != nil
                && sessions.first(where: { $0.id == selectedSessionId })?.state != .listening
            if finishedListening {
                manualListenSessionId = nil
                listeningSession = nil
                isListening = false
            }

            if rows.isEmpty {
                statusMessage = "Start a Codex session to see it here"
            } else if finishedListening {
                statusMessage = "Voice prompt copied to clipboard"
            } else if isListening {
                statusMessage = "Listening to selected session..."
            } else if statusMessage == "Loading sessions..." || statusMessage.hasPrefix("Could not") {
                statusMessage = "Select a session, then press the mic"
            }

            onChange?()
            processMCPEvents()
        } catch {
            statusMessage = "Could not load sessions: \(String(describing: error))"
            onChange?()
        }
    }

    private func startListening() async {
        guard let sessionId = selectedSessionId ?? rows.first?.id else {
            statusMessage = "No sessions yet"
            onChange?()
            return
        }

        // Hard-disconnect the persistent playback peer before opening the
        // listening peer — otherwise both compete for the mic and the
        // listening session never transcribes a final transcript.
        await service.resetPlayback()
        manualListenSessionId = sessionId

        do {
            statusMessage = "Listening — speak your reply"
            onChange?()
            listeningSession = try await service.listenForSession(sessionId) { [weak self] event in
                guard let self else { return }
                await self.handleListenProgress(event)
            }
            isListening = true
            await refresh()
        } catch {
            isListening = false
            listeningSession = nil
            manualListenSessionId = nil
            statusMessage = "Could not listen: \(String(describing: error))"
            onChange?()
        }
    }

    private func handleListenProgress(_ event: RealtimeListenEvent) {
        switch event {
        case .transcriptDelta(let chunk):
            statusMessage = "Heard \"" + chunk.trimmingCharacters(in: .whitespacesAndNewlines) + "\""
        case .finalTranscript(let prompt):
            let preview = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = "Sent: \"" + String(preview.prefix(60)) + "\""
        case .ended:
            // Captured & submitted (or window closed). Refresh resyncs row state.
            break
        case .failed(let reason):
            statusMessage = "Listen failed: \(reason)"
        }
        onChange?()
    }

    private func stopListening() async {
        await listeningSession?.stop()
        manualListenSessionId = nil
        listeningSession = nil
        isListening = false
        statusMessage = "Stopped listening"
        await refresh()
    }
}

@MainActor
private protocol SideNotchHoverDelegate: AnyObject {
    func sideNotchHoverDidChange(isHovering: Bool)
}

@MainActor
final class CodeTalkerOverlayController {
    static let shared = CodeTalkerOverlayController()

    private var window: SideNotchWindow?
    private var screenFrame: CGRect = .zero
    private var visibleFrame: CGRect = .zero
    private var isExpanded = false
    private var pendingCollapse: DispatchWorkItem?

    func show() {
        let window = SideNotchWindow()
        window.configure()

        let contentView = SideNotchView(frame: window.contentView?.bounds ?? .zero)
        contentView.hoverDelegate = self
        contentView.setExpanded(false, animated: false)
        window.contentView = contentView

        self.window = window
        updateScreenFrames()
        positionWindow(expanded: false, animated: false)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        CodeTalkerOverlayModel.shared.startRefreshing()
    }

    private func updateScreenFrames() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        screenFrame = screen?.frame ?? .zero
        visibleFrame = screen?.visibleFrame ?? screenFrame
    }

    private func positionWindow(expanded: Bool, animated: Bool) {
        guard let window else { return }
        let frame = targetFrame(expanded: expanded)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = expanded ? 0.34 : 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.86, 0.24, 1.0)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    private func targetFrame(expanded: Bool) -> NSRect {
        let windowWidth = expanded ? OverlayMetrics.expandedWidth : OverlayMetrics.collapsedWidth
        let windowHeight = expanded ? OverlayMetrics.expandedHeight : OverlayMetrics.collapsedHeight
        return NSRect(
            x: screenFrame.minX,
            y: visibleFrame.midY - windowHeight / 2,
            width: windowWidth,
            height: windowHeight
        )
    }

    private func expandIfNeeded() {
        pendingCollapse?.cancel()
        pendingCollapse = nil

        guard !isExpanded,
              let contentView = window?.contentView as? SideNotchView else {
            return
        }

        isExpanded = true
        positionWindow(expanded: true, animated: true)
        contentView.setExpanded(true, animated: true)
    }

    private func scheduleCollapseIfPointerLeaves() {
        pendingCollapse?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.collapseIfPointerIsOutside()
            }
        }
        pendingCollapse = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func collapseIfPointerIsOutside() {
        guard isExpanded,
              let contentView = window?.contentView as? SideNotchView else {
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let expandedFrame = targetFrame(expanded: true).insetBy(dx: -24, dy: -28)
        let collapsedHotZone = targetFrame(expanded: false).insetBy(dx: -18, dy: -28)

        guard !expandedFrame.contains(mouseLocation),
              !collapsedHotZone.contains(mouseLocation) else {
            return
        }

        pendingCollapse = nil
        isExpanded = false
        contentView.setExpanded(false, animated: true)
        positionWindow(expanded: false, animated: true)
    }
}

extension CodeTalkerOverlayController: SideNotchHoverDelegate {
    func sideNotchHoverDidChange(isHovering: Bool) {
        if isHovering {
            expandIfNeeded()
        } else {
            scheduleCollapseIfPointerLeaves()
        }
    }
}

private final class SideNotchWindow: NSWindow {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    func configure() {
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SideNotchView: NSView {
    weak var hoverDelegate: SideNotchHoverDelegate?

    private let panelWidth: CGFloat = 280
    private let rowHeight: CGFloat = 56
    private let rowGap: CGFloat = 6
    private let leftPadding: CGFloat = 12
    private let rightPadding: CGFloat = 12
    private let topPadding: CGFloat = 14
    private let bottomPadding: CGFloat = 16
    private var trackingArea: NSTrackingArea?
    private var isExpanded = false
    private var rowViews: [DockRowView] = []
    private let voiceInputBarView = VoiceInputBarView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let settingsButton = IconButtonView(systemName: "gearshape")
    private let model = CodeTalkerOverlayModel.shared

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configureStaticViews()
        model.onChange = { [weak self] in
            self?.reloadRows()
        }
        reloadRows()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .activeAlways,
            .mouseEnteredAndExited,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverDelegate?.sideNotchHoverDidChange(isHovering: true)
    }

    override func mouseExited(with event: NSEvent) {
        hoverDelegate?.sideNotchHoverDidChange(isHovering: false)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
        needsDisplay = true

        if expanded {
            subviews.forEach { $0.isHidden = false }
            subviews.forEach { $0.alphaValue = animated ? 0 : 1 }
        }

        if animated {
            let animation = {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = expanded ? 0.18 : 0.10
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
                    context.allowsImplicitAnimation = true
                    for subview in self.subviews {
                        subview.animator().alphaValue = expanded ? 1 : 0
                    }
                } completionHandler: {
                    if !expanded {
                        Task { @MainActor in
                            self.subviews.forEach { $0.isHidden = true }
                        }
                    }
                }
            }

            if expanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                    if self.isExpanded {
                        animation()
                    }
                }
            } else {
                animation()
            }
        } else {
            subviews.forEach { subview in
                subview.alphaValue = expanded ? 1 : 0
                subview.isHidden = !expanded
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()

        if bounds.width <= OverlayMetrics.collapsedWidth + 1 {
            NSColor.black.setFill()
            let radius = bounds.width / 2
            let handle = NSBezierPath()
            handle.move(to: CGPoint(x: 0, y: 0))
            handle.line(to: CGPoint(x: bounds.width - radius, y: 0))
            handle.curve(
                to: CGPoint(x: bounds.width, y: radius),
                controlPoint1: CGPoint(x: bounds.width - radius * 0.45, y: 0),
                controlPoint2: CGPoint(x: bounds.width, y: radius * 0.45)
            )
            handle.line(to: CGPoint(x: bounds.width, y: bounds.height - radius))
            handle.curve(
                to: CGPoint(x: bounds.width - radius, y: bounds.height),
                controlPoint1: CGPoint(x: bounds.width, y: bounds.height - radius * 0.45),
                controlPoint2: CGPoint(x: bounds.width - radius * 0.45, y: bounds.height)
            )
            handle.line(to: CGPoint(x: 0, y: bounds.height))
            handle.close()
            handle.fill()

            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(
                roundedRect: CGRect(x: 8, y: bounds.midY - 58, width: 2, height: 116),
                xRadius: 1,
                yRadius: 1
            ).fill()
            return
        }

        NSColor.black.setFill()
        drawMainNotchBody()
    }

    private func drawMainNotchBody() {
        let rightX = panelWidth + 6
        let rightRadius: CGFloat = 38
        let smooth: CGFloat = 0.56

        let body = NSBezierPath()
        body.move(to: CGPoint(x: 0, y: 0))
        body.line(to: CGPoint(x: rightX - rightRadius, y: 0))
        body.curve(
            to: CGPoint(x: rightX, y: rightRadius),
            controlPoint1: CGPoint(x: rightX - rightRadius * (1 - smooth), y: 0),
            controlPoint2: CGPoint(x: rightX, y: rightRadius * smooth)
        )
        body.line(to: CGPoint(x: rightX, y: bounds.height - rightRadius))
        body.curve(
            to: CGPoint(x: rightX - rightRadius, y: bounds.height),
            controlPoint1: CGPoint(x: rightX, y: bounds.height - rightRadius * (1 - smooth)),
            controlPoint2: CGPoint(x: rightX - rightRadius * (1 - smooth), y: bounds.height)
        )
        body.line(to: CGPoint(x: 0, y: bounds.height))
        body.close()
        body.fill()
    }

    override func layout() {
        super.layout()
        let rowWidth = panelWidth - leftPadding - rightPadding
        let inputHeight: CGFloat = 48

        voiceInputBarView.frame = CGRect(
            x: leftPadding,
            y: topPadding,
            width: rowWidth,
            height: inputHeight
        )

        var y = topPadding + inputHeight + 10
        for row in rowViews {
            row.frame = CGRect(x: leftPadding, y: y, width: rowWidth, height: rowHeight)
            y += rowHeight + rowGap
        }

        statusLabel.frame = CGRect(
            x: leftPadding,
            y: bounds.height - bottomPadding - 36,
            width: rowWidth - 36,
            height: 32
        )

        settingsButton.frame = CGRect(
            x: panelWidth - rightPadding - 22,
            y: topPadding,
            width: 22,
            height: 22
        )
    }

    private func configureStaticViews() {
        voiceInputBarView.onToggle = { [weak model] in
            model?.toggleListening()
        }
        addSubview(voiceInputBarView)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 2
        addSubview(statusLabel)

        settingsButton.onClick = {
            NSApp.activate(ignoringOtherApps: true)
            // macOS 14+ uses showSettingsWindow:, older releases used the
            // showPreferencesWindow: selector. Try the newer first.
            let modern = Selector(("showSettingsWindow:"))
            if NSApp.responds(to: modern) {
                NSApp.sendAction(modern, to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
        addSubview(settingsButton)
    }

    private func reloadRows() {
        for row in rowViews {
            row.removeFromSuperview()
        }
        rowViews.removeAll()

        voiceInputBarView.setListening(model.isListening || model.isSpeakingOrQueued)
        statusLabel.stringValue = model.statusMessage

        for row in model.rows.prefix(6) {
            let view = DockRowView(
                item: row,
                onSelect: { [weak model] in model?.selectSession(row.id) },
                onTalk: { [weak model] in model?.talkToSession(row.id) },
                onStop: { [weak model] in model?.stopSpeaking(for: row.id) }
            )
            rowViews.append(view)
            addSubview(view, positioned: .below, relativeTo: statusLabel)
        }

        needsLayout = true
    }
}

private final class IconButtonView: NSView {
    var onClick: (() -> Void)?
    private let button = NSButton()

    init(systemName: String) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(systemName)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor.white.withAlphaComponent(0.76)
        button.target = self
        button.action = #selector(didClick)
        addSubview(button)
    }

    func setSymbol(_ name: String, tint: NSColor? = nil) {
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: name)
        if let tint {
            button.contentTintColor = tint
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        button.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    @objc private func didClick() {
        onClick?()
    }
}

private final class VoiceInputBarView: NSView {
    var onToggle: (() -> Void)?
    private let waveformView = AudioWaveformView()
    private let micButton = NSButton()
    private var isListening = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("voiceInput")
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        configureMicButton()
        addSubview(waveformView)
        addSubview(micButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let micSize: CGFloat = 30
        let rightInset: CGFloat = 8
        let verticalInset: CGFloat = 8

        micButton.frame = CGRect(
            x: bounds.maxX - rightInset - micSize,
            y: (bounds.height - micSize) / 2,
            width: micSize,
            height: micSize
        )

        waveformView.frame = CGRect(
            x: 16,
            y: verticalInset,
            width: max(0, micButton.frame.minX - 28),
            height: bounds.height - verticalInset * 2
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func setListening(_ listening: Bool) {
        guard isListening != listening else { return }
        isListening = listening

        if listening {
            MicrophoneLevelMonitor.shared.start()
        } else {
            MicrophoneLevelMonitor.shared.stop()
        }

        waveformView.setListening(listening)
        updateListeningAppearance()
    }

    private func configureMicButton() {
        micButton.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Start voice input")
        micButton.imagePosition = .imageOnly
        micButton.isBordered = false
        micButton.wantsLayer = true
        micButton.layer?.cornerRadius = 15
        micButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.17).cgColor
        micButton.contentTintColor = NSColor.white.withAlphaComponent(0.88)
        micButton.target = self
        micButton.action = #selector(toggleListening)
    }

    @objc private func toggleListening() {
        onToggle?()
    }

    private func updateListeningAppearance() {
        let highlight = isListening ? NSColor.systemBlue.withAlphaComponent(0.42) : NSColor.white.withAlphaComponent(0.13)
        let border = isListening ? NSColor.systemBlue.withAlphaComponent(0.66) : NSColor.white.withAlphaComponent(0.12)
        layer?.backgroundColor = highlight.cgColor
        layer?.borderColor = border.cgColor
        micButton.layer?.backgroundColor = (isListening ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.17)).cgColor
        micButton.contentTintColor = .white
        micButton.image = NSImage(
            systemSymbolName: isListening ? "mic.fill" : "mic",
            accessibilityDescription: isListening ? "Stop voice input" : "Start voice input"
        )
    }
}

private final class MicrophoneLevelMonitor: @unchecked Sendable {
    static let shared = MicrophoneLevelMonitor()

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var didRequestPermission = false
    private var currentLevel: CGFloat = 0

    var level: CGFloat {
        lock.lock()
        defer { lock.unlock() }
        return currentLevel
    }

    func start() {
        guard !engine.isRunning else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            guard !didRequestPermission else { return }
            didRequestPermission = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard granted else { return }
                    self?.startEngine()
                }
            }
        case .denied, .restricted:
            return
        @unknown default:
            return
        }
    }

    func stop() {
        guard engine.isRunning else {
            updateLevel(0, smoothing: 0)
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        updateLevel(0, smoothing: 0)
    }

    private func startEngine() {
        guard !engine.isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var sum: Float = 0
            for index in 0..<frameLength {
                let sample = channelData[index]
                sum += sample * sample
            }

            let rms = sqrt(sum / Float(frameLength))
            let normalizedLevel = min(1, max(0, CGFloat(rms) * 12))
            self?.updateLevel(normalizedLevel)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            updateLevel(0, smoothing: 0)
        }
    }

    private func updateLevel(_ level: CGFloat, smoothing: CGFloat = 0.68) {
        lock.lock()
        currentLevel = currentLevel * smoothing + level * (1 - smoothing)
        lock.unlock()
    }
}

private final class AudioWaveformView: NSView {
    private let barCount = 28
    private var bars: [CGFloat]
    private var displayLink: Timer?
    private var phase: CGFloat = 0
    private var isListening = false

    override init(frame frameRect: NSRect) {
        self.bars = Array(repeating: 0.12, count: barCount)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else {
            startAnimatingIfNeeded()
        }
    }

    func setListening(_ listening: Bool) {
        isListening = listening
        if listening {
            startAnimatingIfNeeded()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !bars.isEmpty else { return }

        NSBezierPath(rect: bounds).addClip()

        let availableWidth = bounds.width
        let barWidth: CGFloat = 2
        let naturalSpacing = (availableWidth - CGFloat(barCount) * barWidth) / CGFloat(max(1, barCount - 1))
        let spacing = max(1.5, naturalSpacing)
        let centerY = bounds.midY
        let maxBarHeight = bounds.height * 0.70

        NSColor.white.withAlphaComponent(isListening ? 0.9 : 0.42).setFill()

        for (index, value) in bars.enumerated() {
            let x = CGFloat(index) * (barWidth + spacing)
            let height = max(4, min(maxBarHeight, value * maxBarHeight))
            let y = centerY - height / 2
            let rect = CGRect(x: x, y: y, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            path.fill()
        }
    }

    private func startAnimatingIfNeeded() {
        guard displayLink == nil else { return }

        displayLink = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(displayLink!, forMode: .common)
    }

    private func tick() {
        phase += 0.16

        let liveLevel = isListening ? MicrophoneLevelMonitor.shared.level : 0
        let speakingPulse = isListening ? pow((sin(phase * 1.55) + 1) / 2, 2) * 0.22 : 0
        let inputLevel = max(liveLevel, speakingPulse)
        let idleMovement = (sin(phase) + 1) * (isListening ? 0.035 : 0.014)
        let newValue = min(1, max(0.08, inputLevel + idleMovement))

        bars.removeFirst()
        bars.append(newValue)

        for index in bars.indices {
            let ripple = (sin(phase + CGFloat(index) * 0.46) + 1) * (isListening ? 0.04 : 0.012)
            let decay: CGFloat = isListening ? 0.90 : 0.82
            bars[index] = min(1, max(0.08, bars[index] * decay + ripple))
        }

        needsDisplay = true
    }
}

private final class DockRowView: NSView {
    private let session: OverlaySessionRow
    private let iconView: AppIconView
    private let onSelect: () -> Void
    private let onTalk: () -> Void
    private let onStop: () -> Void
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let thinkingView = ShimmeringStatusView()
    private let actionButton = NSButton()
    private var actionHandler: (() -> Void)?

    init(
        item: OverlaySessionRow,
        onSelect: @escaping () -> Void,
        onTalk: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.session = item
        self.iconView = AppIconView(item: item)
        self.onSelect = onSelect
        self.onTalk = onTalk
        self.onStop = onStop
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("row")
        wantsLayer = true
        layer?.cornerRadius = 9
        updateBackground()
        configureSubviews()
    }

    private var hasActionButton: Bool { true }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect()
    }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 36
        iconView.frame = CGRect(x: 4, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)

        let actionInset: CGFloat = hasActionButton ? 34 : 0
        if hasActionButton {
            actionButton.frame = CGRect(x: bounds.width - 32, y: bounds.height - 32, width: 26, height: 26)
        } else {
            actionButton.frame = .zero
        }

        let textX: CGFloat = 46
        let textWidth = max(0, bounds.width - textX - 6 - actionInset)
        let elapsedWidth: CGFloat = 60
        nameLabel.frame = CGRect(x: textX, y: 4, width: max(0, textWidth - elapsedWidth - 8), height: 18)
        elapsedLabel.frame = CGRect(x: bounds.width - elapsedWidth - 6, y: 5, width: elapsedWidth, height: 16)
        subtitleLabel.frame = CGRect(x: textX, y: 22, width: textWidth, height: 13)

        if session.isRunning {
            thinkingView.frame = CGRect(x: textX, y: 36, width: min(116, textWidth), height: 16)
            summaryLabel.frame = .zero
        } else {
            thinkingView.frame = .zero
            summaryLabel.frame = CGRect(x: textX, y: 37, width: textWidth, height: 15)
        }
    }

    private func configureSubviews() {
        addSubview(iconView)

        nameLabel.stringValue = session.name
        nameLabel.font = .systemFont(ofSize: 13, weight: .bold)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        configureForSingleLineTruncation(nameLabel)
        addSubview(nameLabel)

        elapsedLabel.stringValue = session.elapsedTime
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        elapsedLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        elapsedLabel.alignment = .right
        configureForSingleLineTruncation(elapsedLabel)
        addSubview(elapsedLabel)

        subtitleLabel.stringValue = session.subtitle
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        configureForSingleLineTruncation(subtitleLabel)
        addSubview(subtitleLabel)

        summaryLabel.stringValue = session.summary
        summaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = NSColor.white.withAlphaComponent(0.64)
        configureForSingleLineTruncation(summaryLabel)
        summaryLabel.isHidden = session.isRunning
        addSubview(summaryLabel)

        thinkingView.isHidden = !session.isRunning
        addSubview(thinkingView)

        configureActionButton()
        addSubview(actionButton)
    }

    private func configureActionButton() {
        // The per-row button is unambiguous now:
        //   • currently speaking or listening for this session → red stop
        //   • everything else → mic (tap to talk to this thread)
        // No more play / replay glyph here — auto-flow handles speaking, and
        // a mic icon clearly communicates "send a message".
        let symbolName: String
        let isStop: Bool
        if session.state == .speaking || session.state == .listening {
            symbolName = "stop.fill"
            actionHandler = onStop
            isStop = true
        } else {
            symbolName = "mic.fill"
            actionHandler = onTalk
            isStop = false
        }

        actionButton.isHidden = false
        actionButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolName)
        actionButton.imagePosition = .imageOnly
        actionButton.isBordered = false
        actionButton.wantsLayer = true
        actionButton.layer?.cornerRadius = 13
        actionButton.layer?.backgroundColor = (isStop
            ? NSColor.systemRed.withAlphaComponent(0.85)
            : NSColor.white.withAlphaComponent(0.16)).cgColor
        actionButton.contentTintColor = .white
        actionButton.target = self
        actionButton.action = #selector(didTapAction)
    }

    @objc private func didTapAction() {
        actionHandler?()
    }

    private func updateBackground() {
        layer?.backgroundColor = session.isSelected ? NSColor.white.withAlphaComponent(0.17).cgColor : NSColor.clear.cgColor
    }

    private func configureForSingleLineTruncation(_ label: NSTextField) {
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
    }
}

private final class ShimmeringStatusView: NSView {
    private let shimmerLayer = CAGradientLayer()
    private let textMaskLayer = CATextLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        shimmerLayer.colors = [
            NSColor.white.withAlphaComponent(0.48).cgColor,
            NSColor.white.withAlphaComponent(1).cgColor,
            NSColor.white.withAlphaComponent(0.48).cgColor
        ]
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerLayer.locations = [-0.75, -0.35, 0.05]
        shimmerLayer.mask = textMaskLayer
        layer?.addSublayer(shimmerLayer)

        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        textMaskLayer.string = "Working..."
        textMaskLayer.font = font.fontName as CFTypeRef
        textMaskLayer.fontSize = font.pointSize
        textMaskLayer.foregroundColor = NSColor.white.cgColor
        textMaskLayer.alignmentMode = .left
        textMaskLayer.truncationMode = .end
        textMaskLayer.isWrapped = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        textMaskLayer.contentsScale = scale
        shimmerLayer.contentsScale = scale
        shimmerLayer.frame = bounds
        textMaskLayer.frame = bounds.insetBy(dx: 0, dy: 1)
        startShimmerIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            shimmerLayer.removeAnimation(forKey: "thinkingShimmer")
        } else {
            startShimmerIfNeeded()
        }
    }

    private func startShimmerIfNeeded() {
        guard window != nil, bounds.width > 0, shimmerLayer.animation(forKey: "thinkingShimmer") == nil else {
            return
        }

        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.75, -0.35, 0.05]
        sweep.toValue = [0.95, 1.35, 1.75]
        sweep.duration = 1.2
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmerLayer.add(sweep, forKey: "thinkingShimmer")
    }
}

private final class AppIconView: NSView {
    private let item: OverlaySessionRow

    init(item: OverlaySessionRow) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Agent identity drives the background color so Codex / Claude /
        // Cursor sessions read as different at a glance.
        let path = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        item.agent.color.setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: CGRect(x: -8, y: -8, width: bounds.width * 0.9, height: bounds.height * 0.9)).fill()

        NSColor.black.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: CGRect(x: bounds.width * 0.42, y: bounds.height * 0.42, width: bounds.width, height: bounds.height)).fill()

        // While the session is active, swap to a state glyph (mic / speaker /
        // lock / warning). Idle rows show the agent's identity glyph.
        let symbolName: String
        switch item.state {
        case .listening:       symbolName = "mic.fill"
        case .speaking:        symbolName = "speaker.wave.2.fill"
        case .needsPermission: symbolName = "lock.fill"
        case .error:           symbolName = "exclamationmark.triangle.fill"
        default:               symbolName = item.agent.idleSymbol
        }

        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolName) else {
            return
        }

        image.lockFocus()
        NSColor.white.set()
        image.unlockFocus()
        image.draw(in: bounds.insetBy(dx: 9, dy: 9), from: .zero, operation: .sourceOver, fraction: 0.92)
    }
}
#endif
