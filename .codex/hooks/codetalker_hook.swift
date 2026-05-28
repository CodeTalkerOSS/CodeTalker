#!/usr/bin/env swift

import Foundation

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

struct CodeTalkerHook {
    static func main() {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let payload = try decodePayload(from: input)
            let event = normalize(payload: payload, rawPayload: String(data: input, encoding: .utf8))

            deliver("append") {
                try append(event: event)
            }

            deliver("post") {
                try post(event: event)
            }
        } catch {
            debug("Code Talker hook ignored error: \(error)")
        }
    }

    private static func decodePayload(from data: Data) throws -> [String: Any] {
        guard !data.isEmpty else {
            return [:]
        }

        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private static func normalize(payload: [String: Any], rawPayload: String?) -> HookEvent {
        let hookName = stringValue(payload, keys: ["hook_event_name", "hookEventName"]) ?? "Unknown"
        let assistantMessage = stringValue(payload, keys: ["last_assistant_message", "lastAssistantMessage"]) ?? ""
        let eventName = eventName(for: hookName)

        var voiceAction = "none"
        var data = HookEventData(rawPayload: rawPayload)

        switch hookName {
        case "SessionStart":
            data.source = stringValue(payload, keys: ["source"])
        case "UserPromptSubmit":
            data.prompt = stringValue(payload, keys: ["prompt"])
        case "Stop":
            voiceAction = assistantMessage.isEmpty ? "none" : "speak_summary"
            data.assistantMessage = assistantMessage
            data.summaryInstruction = "Summarize this coding-agent response into one or two spoken sentences."
            data.stopHookActive = boolValue(payload, keys: ["stop_hook_active", "stopHookActive"]) ?? false
        case "PermissionRequest":
            voiceAction = "announce_permission"
            data.toolName = stringValue(payload, keys: ["tool_name", "toolName", "tool"])
            data.command = stringValue(payload, keys: ["command", "input"])
            data.permissionReason = stringValue(payload, keys: ["reason", "message", "permission_reason", "permissionReason"])
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
            turnId: stringValue(payload, keys: ["turn_id", "turnId"]),
            cwd: stringValue(payload, keys: ["cwd"]),
            transcriptPath: stringValue(payload, keys: ["transcript_path", "transcriptPath"]),
            model: stringValue(payload, keys: ["model"]),
            permissionMode: stringValue(payload, keys: ["permission_mode", "permissionMode"]),
            voiceAction: voiceAction,
            data: data
        )
    }

    private static func eventName(for hookName: String) -> String {
        switch hookName {
        case "SessionStart":
            return "session.started"
        case "UserPromptSubmit":
            return "user.prompt_submitted"
        case "Stop":
            return "assistant.response_ready"
        case "PermissionRequest":
            return "permission.requested"
        default:
            return "codex.hook"
        }
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
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        handle.write(data)
    }

    private static func post(event: HookEvent) throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let endpoint = environment["CODETALKER_HOOK_ENDPOINT"] ?? environment["CODETALKER_HOOK_URL"],
            let url = URL(string: endpoint)
        else {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let body = try encoder.encode(event)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = hookTimeout()
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodeTalker-CodexHook/1", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + hookTimeout()) == .timedOut {
            task.cancel()
        }
    }

    private static func deliver(_ name: String, action: () throws -> Void) {
        do {
            try action()
        } catch {
            debug("Code Talker hook \(name) delivery failed: \(error)")
        }
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
            if let value = payload[key] as? String {
                return value
            }

            if let value = payload[key] {
                return String(describing: value)
            }
        }

        return nil
    }

    private static func boolValue(_ payload: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = payload[key] as? Bool {
                return value
            }
        }

        return nil
    }

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["CODETALKER_HOOK_DEBUG"] == "1" else {
            return
        }

        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

CodeTalkerHook.main()
