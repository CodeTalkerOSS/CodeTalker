import SwiftUI
import Combine

/// Status panel surfaced via the gear icon in the overlay. Reflects what is
/// actually configured: API token, which agent hooks are wired up, and how
/// much activity is flowing through the event log.
struct SettingsView: View {
    @StateObject private var status = SettingsStatus()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                SettingsCard(title: "OpenAI") {
                    KeyRow(
                        title: status.apiKeyState.title,
                        detail: status.apiKeyState.detail,
                        ok: status.apiKeyState.ok
                    )
                    Divider().opacity(0.15)
                    HStack {
                        Text("Realtime model")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("gpt-realtime-2").monospaced()
                    }
                    .font(.callout)
                }

                SettingsCard(title: "Coding agents") {
                    ForEach(status.agents) { agent in
                        AgentRow(agent: agent)
                        if agent.id != status.agents.last?.id {
                            Divider().opacity(0.15)
                        }
                    }
                }

                SettingsCard(title: "Storage") {
                    StorageRow(label: "Event log", file: status.eventLog)
                    Divider().opacity(0.15)
                    StorageRow(label: "MCP event log", file: status.mcpLog)
                    Divider().opacity(0.15)
                    HStack {
                        Button("Reveal in Finder") { status.revealStorageFolder() }
                        Button("Refresh") { status.refresh() }
                        Spacer()
                        Text("Updates every 3 s")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(22)
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear { status.start() }
        .onDisappear { status.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Code Talker")
                .font(.title2).bold()
            Text("Voice companion for Codex, Claude Code, and Cursor.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cards & rows

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption).bold()
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.thinMaterial)
            )
        }
    }
}

private struct KeyRow: View {
    let title: String
    let detail: String
    let ok: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .imageScale(.medium)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct AgentRow: View {
    let agent: AgentStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: agent.symbol)
                .imageScale(.medium)
                .frame(width: 22)
                .foregroundStyle(agent.tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.callout).bold()
                    if agent.recentEventCount > 0 {
                        Text("\(agent.recentEventCount) recent")
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.green.opacity(0.18))
                            )
                            .foregroundStyle(.green)
                    }
                }
                Text(agent.hookStatus)
                    .font(.caption)
                    .foregroundStyle(agent.hookInstalled
                        ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                        : AnyShapeStyle(Color.orange))
                Text("Config: \(agent.configPathDisplay)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let last = agent.lastEventDescription {
                    Text(last)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        let installed = agent.hookInstalled
        let active = agent.recentEventCount > 0
        let (text, color): (String, Color) = {
            if active { return ("Live", .green) }
            if installed { return ("Idle", .gray) }
            return ("Not set up", .orange)
        }()
        return Text(text)
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

private struct StorageRow: View {
    let label: String
    let file: FileStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: file.exists ? "doc.fill" : "doc")
                .foregroundStyle(file.exists ? Color.accentColor : Color.gray)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout)
                Text(file.path).font(.caption).monospaced().foregroundStyle(.secondary)
                Text(file.detail).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}

// MARK: - Status model

@MainActor
final class SettingsStatus: ObservableObject {
    @Published private(set) var apiKeyState: APIKeyState = .init(title: "Checking…", detail: "", ok: false)
    @Published private(set) var agents: [AgentStatus] = []
    @Published private(set) var eventLog: FileStatus = .init(path: "", detail: "", exists: false)
    @Published private(set) var mcpLog: FileStatus = .init(path: "", detail: "", exists: false)

    private var refreshTask: Task<Void, Never>?

    func start() {
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() {
        apiKeyState = Self.detectAPIKey()
        eventLog = Self.fileStatus(at: Self.eventLogPath(), label: "Event log")
        mcpLog = Self.fileStatus(at: Self.mcpLogPath(), label: "MCP event log")

        let activity = Self.scanEventLog(at: Self.eventLogPath())
        agents = Self.agentTemplates().map { template in
            template.merging(activity: activity[template.agentKey])
        }
    }

    func revealStorageFolder() {
        let url = URL(fileURLWithPath: Self.eventLogPath()).deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Detection helpers

    private static func detectAPIKey() -> APIKeyState {
        let env = ProcessInfo.processInfo.environment
        for name in ["OPENAI_API_KEY", "CODETALKER_REALTIME_EPHEMERAL_KEY", "OPENAI_REALTIME_EPHEMERAL_KEY"] {
            if let value = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                let masked = mask(value)
                return APIKeyState(title: "\(name) is set", detail: masked, ok: true)
            }
        }
        return APIKeyState(
            title: "No OpenAI key found in this app's environment",
            detail: "Set OPENAI_API_KEY in Xcode → Edit Scheme → Run → Environment Variables, then relaunch.",
            ok: false
        )
    }

    private static func mask(_ value: String) -> String {
        guard value.count > 10 else { return String(repeating: "•", count: value.count) }
        let head = value.prefix(7)
        let tail = value.suffix(4)
        return "\(head)…\(tail)"
    }

    private static func fileStatus(at path: String, label: String) -> FileStatus {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path) else {
            return FileStatus(path: path, detail: "Will be created on first event.", exists: false)
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let modified = attrs[.modificationDate] as? Date
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        let sizeText = formatter.string(fromByteCount: Int64(size))
        let modText = modified.map { "Updated \(Self.relative(date: $0))" } ?? "Never updated"
        _ = url
        return FileStatus(path: path, detail: "\(sizeText) · \(modText)", exists: true)
    }

    private static func relative(date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func eventLogPath() -> String {
        let env = ProcessInfo.processInfo.environment
        let path = env["CODETALKER_EVENT_LOG"] ?? "\(NSHomeDirectory())/.codetalker/codex-events.jsonl"
        return NSString(string: path).expandingTildeInPath
    }

    private static func mcpLogPath() -> String {
        let env = ProcessInfo.processInfo.environment
        let path = env["CODETALKER_DIR"].map { "\($0)/mcp-events.jsonl" }
            ?? "\(NSHomeDirectory())/.codetalker/mcp-events.jsonl"
        return NSString(string: path).expandingTildeInPath
    }

    /// Tail the event log and produce per-agent activity stats. Counts events
    /// received in the last 10 minutes.
    private static func scanEventLog(at path: String) -> [String: AgentActivity] {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return [:]
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        let offset = size > window ? size - window : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [:] }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var result: [String: AgentActivity] = [:]
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFractional = ISO8601DateFormatter()
        isoNoFractional.formatOptions = [.withInternetDateTime]
        let recencyThreshold = Date().addingTimeInterval(-600) // 10 min

        for line in lines {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            let agent = (object["agent"] as? String) ?? inferAgent(from: object)
            let createdAtString = object["created_at"] as? String
            let createdAt = createdAtString.flatMap { isoFormatter.date(from: $0) ?? isoNoFractional.date(from: $0) }
            var entry = result[agent] ?? AgentActivity()
            entry.totalCount += 1
            if let createdAt {
                if createdAt > recencyThreshold {
                    entry.recentCount += 1
                }
                if entry.lastEventAt == nil || createdAt > entry.lastEventAt! {
                    entry.lastEventAt = createdAt
                    entry.lastEventName = object["event"] as? String
                }
            }
            result[agent] = entry
        }
        return result
    }

    /// Pre-modern events may not carry an `agent` field — guess from the hook name.
    private static func inferAgent(from object: [String: Any]) -> String {
        let hookName = (object["hook_event_name"] as? String) ?? ""
        switch hookName {
        case "Notification", "PreToolUse", "PostToolUse": return "claude_code"
        case "sessionStart", "beforeSubmitPrompt", "stop", "beforeShellExecution": return "cursor"
        case "PermissionRequest": return "codex"
        default: return "codex"
        }
    }

    // MARK: - Agent templates

    private static func agentTemplates() -> [AgentStatus] {
        let home = NSHomeDirectory()
        let repoCodex = repoFile(".codex/hooks.json")
        let repoClaude = repoFile(".claude/settings.json")
        let repoCursor = repoFile(".cursor/hooks.json")
        let userClaude = "\(home)/.claude/settings.json"
        let userCursor = "\(home)/.cursor/hooks.json"

        return [
            AgentStatus(
                agentKey: "codex",
                name: "Codex",
                symbol: "chevron.left.forwardslash.chevron.right",
                tint: .orange,
                configPath: repoCodex,
                fallbackConfigPath: nil,
                hookInstalledHint: "Project hook at .codex/hooks.json"
            ),
            AgentStatus(
                agentKey: "claude_code",
                name: "Claude Code",
                symbol: "sparkles",
                tint: .purple,
                configPath: repoClaude,
                fallbackConfigPath: userClaude,
                hookInstalledHint: "Project hook at .claude/settings.json"
            ),
            AgentStatus(
                agentKey: "cursor",
                name: "Cursor",
                symbol: "cursorarrow.rays",
                tint: .blue,
                configPath: repoCursor,
                fallbackConfigPath: userCursor,
                hookInstalledHint: "Project hook at .cursor/hooks.json"
            )
        ]
    }

    /// Resolve a repo-relative path. The bundled app lives inside DerivedData,
    /// so we don't know the repo at runtime — show the path display only and
    /// detect installation by checking project-local OR user-home variants.
    private static func repoFile(_ relative: String) -> String {
        // Best-effort: many users run from within the repo via Xcode, where
        // the current working directory is the project root.
        return FileManager.default.currentDirectoryPath + "/" + relative
    }
}

// MARK: - Value types

struct APIKeyState: Equatable {
    var title: String
    var detail: String
    var ok: Bool
}

struct FileStatus: Equatable {
    var path: String
    var detail: String
    var exists: Bool
}

struct AgentActivity {
    var totalCount: Int = 0
    var recentCount: Int = 0
    var lastEventAt: Date?
    var lastEventName: String?
}

struct AgentStatus: Identifiable, Equatable {
    let agentKey: String
    let name: String
    let symbol: String
    let tint: Color
    let configPath: String
    let fallbackConfigPath: String?
    let hookInstalledHint: String

    // Filled in by merging(activity:)
    var recentEventCount: Int = 0
    var totalEventCount: Int = 0
    var lastEventAt: Date?
    var lastEventName: String?

    var id: String { agentKey }

    var hookInstalled: Bool {
        // From a sandboxed app we can't reliably stat repo-local config paths,
        // so treat any recent event from this agent as proof the hook is wired.
        if totalEventCount > 0 { return true }
        let fm = FileManager.default
        if fm.fileExists(atPath: configPath) { return true }
        if let fallback = fallbackConfigPath, fm.fileExists(atPath: fallback) { return true }
        return false
    }

    var hookStatus: String {
        if totalEventCount > 0 {
            return "Hook firing · \(totalEventCount) total event\(totalEventCount == 1 ? "" : "s") seen"
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: configPath) || (fallbackConfigPath.map(fm.fileExists(atPath:)) ?? false) {
            return "Hook installed · \(hookInstalledHint)"
        }
        return "Hook not detected — see docs/agent-hooks.md"
    }

    var configPathDisplay: String {
        let path = configPath
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var lastEventDescription: String? {
        guard let lastEventAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: lastEventAt, relativeTo: Date())
        return "Last \(lastEventName ?? "event") \(when)"
    }

    func merging(activity: AgentActivity?) -> AgentStatus {
        var copy = self
        copy.totalEventCount = activity?.totalCount ?? 0
        copy.recentEventCount = activity?.recentCount ?? 0
        copy.lastEventAt = activity?.lastEventAt
        copy.lastEventName = activity?.lastEventName
        return copy
    }
}
