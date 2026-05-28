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
        CodeTalkerOverlayController.shared.show()
    }
}

nonisolated public struct EnvironmentRealtimeEphemeralKeyProvider: RealtimeEphemeralKeyProvider {
    public init() {}

    public func ephemeralKey() async throws -> String {
        let environment = ProcessInfo.processInfo.environment
        for key in ["CODETALKER_REALTIME_EPHEMERAL_KEY", "OPENAI_REALTIME_EPHEMERAL_KEY"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        throw OpenAIRealtimeVoiceClientError.missingRealtimeEphemeralKey
    }
}

nonisolated public struct ClipboardCodexInputSink: CodexSessionInputSink {
    public init() {}

    public func submitPrompt(_ prompt: String, to session: CodingSession) async throws {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
        }
    }
}

private struct OverlaySessionRow {
    let id: CodingSession.ID
    let name: String
    let elapsedTime: String
    let summary: String
    let isRunning: Bool
    let fallbackColor: NSColor
    let state: CodingSessionState
    let isSelected: Bool

    init(session: CodingSession, isSelected: Bool) {
        self.id = session.id
        self.name = session.title
        self.elapsedTime = Self.relativeTime(since: session.updatedAt)
        self.summary = session.latestSpokenSummary
            ?? session.latestAssistantMessage
            ?? session.latestPrompt
            ?? session.cwd
            ?? "Waiting for Codex activity"
        self.isRunning = [.queued, .waitingForResponse, .speaking, .listening].contains(session.state)
        self.fallbackColor = Self.color(for: session.id)
        self.state = session.state
        self.isSelected = isSelected
    }

    private static func relativeTime(since date: Date) -> String {
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

    private static func color(for value: String) -> NSColor {
        let colors: [NSColor] = [.systemBlue, .systemOrange, .systemPurple, .systemGreen, .systemPink]
        return colors[abs(value.hashValue) % colors.count]
    }
}

@MainActor
private final class CodeTalkerOverlayModel {
    static let shared = CodeTalkerOverlayModel()

    private let service: CodeTalkerSessionService
    private var refreshTask: Task<Void, Never>?
    private var listeningSession: CodeTalkerListeningSession?
    private var currentSessions: [CodingSession] = []

    private(set) var rows: [OverlaySessionRow] = []
    private(set) var isListening = false
    private(set) var statusMessage = "Loading sessions..."
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

    func toggleListening() {
        Task {
            if isListening {
                await stopListening()
            } else {
                await startListening()
            }
        }
    }

    func playSelectedResponse() {
        guard let sessionId = selectedSessionId ?? rows.first?.id else {
            statusMessage = "No Codex sessions yet"
            onChange?()
            return
        }

        Task {
            statusMessage = "Speaking latest response..."
            onChange?()

            do {
                try await service.playSessionLatestResponse(sessionId)
                statusMessage = "Finished speaking"
                await refresh()
            } catch {
                statusMessage = "Could not speak: \(String(describing: error))"
                onChange?()
            }
        }
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
        } catch {
            statusMessage = "Could not load sessions: \(String(describing: error))"
            onChange?()
        }
    }

    private func startListening() async {
        guard let sessionId = selectedSessionId ?? rows.first?.id else {
            statusMessage = "No Codex sessions yet"
            onChange?()
            return
        }

        do {
            statusMessage = "Starting realtime microphone..."
            onChange?()
            listeningSession = try await service.listenForSession(sessionId)
            isListening = true
            statusMessage = "Listening to selected session..."
            await refresh()
        } catch {
            isListening = false
            listeningSession = nil
            statusMessage = "Could not listen: \(String(describing: error))"
            onChange?()
        }
    }

    private func stopListening() async {
        await listeningSession?.stop()
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
    private let speakerButton = IconButtonView(systemName: "speaker.wave.2.fill")
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

        speakerButton.frame = CGRect(
            x: panelWidth - rightPadding - 28,
            y: bounds.height - bottomPadding - 30,
            width: 28,
            height: 28
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

        speakerButton.onClick = { [weak model] in
            model?.playSelectedResponse()
        }
        addSubview(speakerButton)
    }

    private func reloadRows() {
        for row in rowViews {
            row.removeFromSuperview()
        }
        rowViews.removeAll()

        voiceInputBarView.setListening(model.isListening)
        statusLabel.stringValue = model.statusMessage

        for row in model.rows.prefix(6) {
            let view = DockRowView(item: row) { [weak model] in
                model?.selectSession(row.id)
            }
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
    private let nameLabel = NSTextField(labelWithString: "")
    private let sessionIDLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let thinkingView = ShimmeringStatusView()

    init(item: OverlaySessionRow, onSelect: @escaping () -> Void) {
        self.session = item
        self.iconView = AppIconView(item: item)
        self.onSelect = onSelect
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("row")
        wantsLayer = true
        layer?.cornerRadius = 9
        updateBackground()
        configureSubviews()
    }

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

        let textX: CGFloat = 46
        let textWidth = max(0, bounds.width - textX - 6)
        let elapsedWidth: CGFloat = 60
        nameLabel.frame = CGRect(x: textX, y: 4, width: max(0, textWidth - elapsedWidth - 8), height: 18)
        elapsedLabel.frame = CGRect(x: bounds.width - elapsedWidth - 6, y: 5, width: elapsedWidth, height: 16)
        sessionIDLabel.frame = CGRect(x: textX, y: 22, width: textWidth, height: 13)

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

        sessionIDLabel.stringValue = session.id
        sessionIDLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        sessionIDLabel.textColor = NSColor.white.withAlphaComponent(0.48)
        configureForSingleLineTruncation(sessionIDLabel)
        addSubview(sessionIDLabel)

        summaryLabel.stringValue = session.summary
        summaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = NSColor.white.withAlphaComponent(0.64)
        configureForSingleLineTruncation(summaryLabel)
        summaryLabel.isHidden = session.isRunning
        addSubview(summaryLabel)

        thinkingView.isHidden = !session.isRunning
        addSubview(thinkingView)
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

        let path = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        item.fallbackColor.setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: CGRect(x: -8, y: -8, width: bounds.width * 0.9, height: bounds.height * 0.9)).fill()

        NSColor.black.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: CGRect(x: bounds.width * 0.42, y: bounds.height * 0.42, width: bounds.width, height: bounds.height)).fill()

        let symbolName: String
        switch item.state {
        case .listening:
            symbolName = "mic.fill"
        case .speaking:
            symbolName = "speaker.wave.2.fill"
        case .needsPermission:
            symbolName = "lock.fill"
        case .error:
            symbolName = "exclamationmark.triangle.fill"
        default:
            symbolName = "terminal.fill"
        }

        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return
        }

        image.lockFocus()
        NSColor.white.set()
        image.unlockFocus()
        image.draw(in: bounds.insetBy(dx: 9, dy: 9), from: .zero, operation: .sourceOver, fraction: 0.92)
    }
}
#endif
