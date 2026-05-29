#!/usr/bin/env swift

import Foundation

// Code Talker hook for Claude Code.
//
// Claude Code's hook stdin payload is documented at
// https://docs.claude.com/en/docs/claude-code/hooks-reference — all hooks
// share `session_id`, `transcript_path`, `cwd`, `hook_event_name`, and
// `permission_mode`. Event-specific fields:
//   • SessionStart:      source ("startup" | "resume" | "clear" | "compact")
//   • UserPromptSubmit:  prompt
//   • Notification:      message       (permission asks surface here)
//   • Stop / SubagentStop: stop_hook_active
//
// Unlike Codex's Stop hook, Claude's Stop payload does NOT include the
// assistant message text. We tail `transcript_path` (JSONL) and pull the
// most recent assistant text out of it.

private let schema = "codetalker.codex-hook.v1"
private let defaultTimeoutSeconds = 0.6

struct HookEvent: Encodable {
    var schema: String
    var eventId: String
    var event: String
    var hookEventName: String
    var createdAt: String
    var receivedUnixMilliseconds: Int64
    var sessionId: String?
    var turnId: String?
    var cwd: String?
    var transcriptPath: String?
    var model: String?
    var permissionMode: String?
    var voiceAction: String
    var agent: String
    var data: HookEventData

    enum CodingKeys: String, CodingKey {
        case schema
        case eventId = "event_id"
        case event
        case hookEventName = "hook_event_name"
        case createdAt = "created_at"
        case receivedUnixMilliseconds = "received_unix_ms"
        case sessionId = "session_id"
        case turnId = "turn_id"
        case cwd
        case transcriptPath = "transcript_path"
        case model
        case permissionMode = "permission_mode"
        case voiceAction = "voice_action"
        case agent
        case data
    }
}

struct HookEventData: Encodable {
    var source: String?
    var prompt: String?
    var assistantMessage: String?
    var summaryInstruction: String?
    var stopHookActive: Bool?
    var toolName: String?
    var command: String?
    var permissionReason: String?
    var rawPayload: String?

    enum CodingKeys: String, CodingKey {
        case source
        case prompt
        case assistantMessage = "assistant_message"
        case summaryInstruction = "summary_instruction"
        case stopHookActive = "stop_hook_active"
        case toolName = "tool_name"
        case command
        case permissionReason = "permission_reason"
        case rawPayload = "raw_payload"
    }
}

struct CodeTalkerClaudeHook {
    static func main() {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let payload = try decodePayload(from: input)
            let event = normalize(payload: payload, rawPayload: String(data: input, encoding: .utf8))

            deliver("append") { try append(event: event) }
            deliver("post") { try post(event: event) }

            // On SessionStart, tell Claude about the codetalker MCP tools so
            // it actually uses them. Without this hint the agent has the
            // tools available but doesn't know they're the preferred channel.
            if event.hookEventName == "SessionStart" {
                emitSessionStartContext()
            }
        } catch {
            debug("Code Talker Claude hook ignored error: \(error)")
        }
    }

    /// Tell Claude about the voice channel via the SessionStart
    /// `additionalContext` mechanism. Brief — agents follow short, concrete
    /// instructions better than long ones.
    private static func emitSessionStartContext() {
        let context = """
        Voice channel available via the `codetalker` MCP server. Two tools:

        - mcp__codetalker__speak(message): one or two natural spoken sentences \
        summarizing what you just finished. Use after meaningful work; skip \
        for trivial replies. Don't read code aloud.
        - mcp__codetalker__ask(question, timeout_seconds?): ask the user a \
        question and BLOCK until their spoken reply returns as the tool \
        result. Prefer this over stopping when you need clarification, \
        approval, or a choice — the user is wearing a headset, not at the \
        keyboard.
        """
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "SessionStart",
                "additionalContext": context
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func decodePayload(from data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private static func normalize(payload: [String: Any], rawPayload: String?) -> HookEvent {
        let hookName = stringValue(payload, keys: ["hook_event_name", "hookEventName"]) ?? "Unknown"
        let transcriptPath = stringValue(payload, keys: ["transcript_path", "transcriptPath"])
        let eventName = eventName(for: hookName)

        var voiceAction = "none"
        var data = HookEventData(rawPayload: rawPayload)

        switch hookName {
        case "SessionStart":
            data.source = stringValue(payload, keys: ["source"])
        case "UserPromptSubmit":
            data.prompt = stringValue(payload, keys: ["prompt"])
        case "Stop", "SubagentStop":
            let assistantMessage = transcriptPath.flatMap(lastAssistantMessage(transcriptPath:)) ?? ""
            voiceAction = assistantMessage.isEmpty ? "none" : "speak_summary"
            data.assistantMessage = assistantMessage
            data.summaryInstruction = "Summarize this coding-agent response into one or two spoken sentences."
            data.stopHookActive = boolValue(payload, keys: ["stop_hook_active", "stopHookActive"]) ?? false
        case "Notification":
            // Claude surfaces permission prompts / idle nudges via Notification.
            voiceAction = "announce_permission"
            data.permissionReason = stringValue(payload, keys: ["message"])
        case "PreToolUse":
            data.toolName = stringValue(payload, keys: ["tool_name"])
            if let toolInput = payload["tool_input"] as? [String: Any] {
                data.command = stringValue(toolInput, keys: ["command", "file_path", "path", "url"])
            }
        default:
            break
        }

        return HookEvent(
            schema: schema,
            eventId: UUID().uuidString,
            event: eventName,
            hookEventName: hookName,
            createdAt: iso8601Now(),
            receivedUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            sessionId: stringValue(payload, keys: ["session_id", "sessionId"]),
            turnId: nil,
            cwd: stringValue(payload, keys: ["cwd"]),
            transcriptPath: transcriptPath,
            model: stringValue(payload, keys: ["model"]),
            permissionMode: stringValue(payload, keys: ["permission_mode", "permissionMode"]),
            voiceAction: voiceAction,
            agent: "claude_code",
            data: data
        )
    }

    private static func eventName(for hookName: String) -> String {
        switch hookName {
        case "SessionStart":     return "session.started"
        case "SessionEnd":       return "session.ended"
        case "UserPromptSubmit": return "user.prompt_submitted"
        case "Stop", "SubagentStop": return "assistant.response_ready"
        case "Notification":     return "permission.requested"
        case "PreToolUse":       return "tool.invoked"
        case "PostToolUse":      return "tool.completed"
        default:                 return "claude.hook"
        }
    }

    /// Reads the tail of a Claude Code transcript JSONL and returns the most
    /// recent assistant text block. Returns nil if no assistant content found.
    private static func lastAssistantMessage(transcriptPath: String) -> String? {
        let url = URL(fileURLWithPath: NSString(string: transcriptPath).expandingTildeInPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Tail the last ~512 KB.
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 512 * 1024
        let offset = size > window ? size - window : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Common shape: {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"…"}]}}
            let type = stringValue(object, keys: ["type"])
            if type == "assistant",
               let message = object["message"] as? [String: Any],
               let extracted = extractText(fromMessage: message),
               !extracted.isEmpty {
                return extracted
            }

            // Alternate shapes seen in plugin transcripts.
            if let role = stringValue(object, keys: ["role"]), role == "assistant" {
                if let extracted = extractText(fromMessage: object), !extracted.isEmpty {
                    return extracted
                }
            }
        }
        return nil
    }

    private static func extractText(fromMessage message: [String: Any]) -> String? {
        if let text = stringValue(message, keys: ["text"]), !text.isEmpty {
            return text
        }
        if let content = message["content"] as? [[String: Any]] {
            let parts = content.compactMap { block -> String? in
                let blockType = stringValue(block, keys: ["type"]) ?? ""
                guard blockType == "text" || blockType.isEmpty else { return nil }
                return stringValue(block, keys: ["text"])
            }
            let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        if let content = message["content"] as? String {
            return content
        }
        return nil
    }

    private static func append(event: HookEvent) throws {
        let logURL = eventLogURL()
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(event)
        data.append(0x0A)

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(data)
    }

    private static func post(event: HookEvent) throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let endpoint = environment["CODETALKER_HOOK_ENDPOINT"] ?? environment["CODETALKER_HOOK_URL"],
            let url = URL(string: endpoint)
        else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let body = try encoder.encode(event)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = hookTimeout()
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodeTalker-ClaudeHook/1", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }
        task.resume()
        if semaphore.wait(timeout: .now() + hookTimeout()) == .timedOut {
            task.cancel()
        }
    }

    private static func deliver(_ name: String, action: () throws -> Void) {
        do { try action() } catch { debug("Code Talker Claude hook \(name) delivery failed: \(error)") }
    }

    private static func eventLogURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["CODETALKER_EVENT_LOG"] ?? "\(NSHomeDirectory())/.codetalker/codex-events.jsonl"
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    private static func hookTimeout() -> TimeInterval {
        let value = ProcessInfo.processInfo.environment["CODETALKER_HOOK_TIMEOUT_SECONDS"]
        let parsed = value.flatMap(TimeInterval.init) ?? defaultTimeoutSeconds
        return min(max(parsed, 0.05), 5.0)
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func stringValue(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String { return value }
            if let value = payload[key] { return String(describing: value) }
        }
        return nil
    }

    private static func boolValue(_ payload: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = payload[key] as? Bool { return value }
        }
        return nil
    }

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["CODETALKER_HOOK_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

CodeTalkerClaudeHook.main()
