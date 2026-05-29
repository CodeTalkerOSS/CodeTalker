#!/usr/bin/env swift

// Code Talker MCP server.
//
// Speaks the Model Context Protocol over stdio (JSON-RPC 2.0), giving coding
// agents two voice tools:
//
//   speak(message)   — speak a short status / summary; returns immediately.
//   ask(question, timeout_seconds?) — speak a question, BLOCK until the user
//                                     replies via voice, return the transcript.
//
// Communication with the Code Talker macOS app is file-based so the server is
// transport-agnostic and survives the app restarting:
//
//   speak → append a `speak` event to ~/.codetalker/mcp-events.jsonl
//   ask   → append an `ask` event; poll ~/.codetalker/mcp-replies/<id>.txt
//           for the user's transcribed reply; remove the file once consumed.
//
// The app's overlay model tails the events file each refresh and enqueues
// voice turns; for `ask`, it writes the captured transcript to the reply
// file so this server can return it as the tool result.

import Foundation

// MARK: - Paths

let baseDir: String = {
    let env = ProcessInfo.processInfo.environment
    return env["CODETALKER_DIR"] ?? "\(NSHomeDirectory())/.codetalker"
}()
let mcpEventsURL = URL(fileURLWithPath: "\(baseDir)/mcp-events.jsonl")
let mcpRepliesDir = URL(fileURLWithPath: "\(baseDir)/mcp-replies")

try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: mcpRepliesDir, withIntermediateDirectories: true)

// MARK: - JSON-RPC plumbing

func send(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func sendResult(id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func sendError(id: Any, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func debug(_ message: String) {
    guard ProcessInfo.processInfo.environment["CODETALKER_MCP_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

// MARK: - Event log writer

func appendMCPEvent(_ event: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    if FileManager.default.fileExists(atPath: mcpEventsURL.path),
       let handle = try? FileHandle(forWritingTo: mcpEventsURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: mcpEventsURL)
    }
}

func iso8601Now() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

// MARK: - Tool catalog

let tools: [[String: Any]] = [
    [
        "name": "speak",
        "description": """
        Speak a short message to the user via Code Talker. \
        Use after completing meaningful work, to summarize what you did in a sentence or two. \
        Keep it conversational and concise — this is read aloud. \
        Do not echo verbose code; talk like you're updating a teammate.
        """,
        "inputSchema": [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "message": [
                    "type": "string",
                    "description": "One or two natural spoken sentences."
                ]
            ],
            "required": ["message"]
        ]
    ],
    [
        "name": "ask",
        "description": """
        Ask the user a question via voice and wait for their spoken reply. \
        Use when you need clarification, approval, or a choice — instead of stopping. \
        The user's reply is returned as plain text in the tool result; continue the turn \
        as if they had typed it.
        """,
        "inputSchema": [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "question": [
                    "type": "string",
                    "description": "The question to speak (1–2 sentences)."
                ],
                "timeout_seconds": [
                    "type": "integer",
                    "description": "Seconds to wait for the spoken reply. Default 60, max 300.",
                    "default": 60
                ]
            ],
            "required": ["question"]
        ]
    ]
]

// MARK: - Handlers

func handleInitialize(id: Any) {
    sendResult(id: id, result: [
        "protocolVersion": "2024-11-05",
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": "codetalker", "version": "0.1.0"]
    ])
}

func handleToolsList(id: Any) {
    sendResult(id: id, result: ["tools": tools])
}

func handleToolsCall(id: Any, params: [String: Any]) {
    guard let name = params["name"] as? String else {
        sendError(id: id, code: -32602, message: "Missing tool name")
        return
    }
    let args = params["arguments"] as? [String: Any] ?? [:]

    switch name {
    case "speak":
        guard let message = (args["message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            sendError(id: id, code: -32602, message: "Missing or empty 'message'")
            return
        }
        let eventId = UUID().uuidString
        appendMCPEvent([
            "schema": "codetalker.mcp-event.v1",
            "type": "speak",
            "id": eventId,
            "message": message,
            "created_at": iso8601Now()
        ])
        sendResult(id: id, result: [
            "content": [["type": "text", "text": "Spoken."]]
        ])

    case "ask":
        guard let question = (args["question"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else {
            sendError(id: id, code: -32602, message: "Missing or empty 'question'")
            return
        }
        let rawTimeout = (args["timeout_seconds"] as? Int) ?? 60
        let timeout = max(5, min(300, rawTimeout))
        let requestId = UUID().uuidString

        appendMCPEvent([
            "schema": "codetalker.mcp-event.v1",
            "type": "ask",
            "id": requestId,
            "question": question,
            "timeout_seconds": timeout,
            "created_at": iso8601Now()
        ])

        let replyURL = mcpRepliesDir.appendingPathComponent("\(requestId).txt")
        let deadline = Date().addingTimeInterval(TimeInterval(timeout) + 5) // grace
        var reply: String? = nil

        while Date() < deadline {
            if let data = try? Data(contentsOf: replyURL),
               let text = String(data: data, encoding: .utf8) {
                reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: replyURL)
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        let body: String
        if let reply, !reply.isEmpty {
            body = reply
        } else {
            body = "(no voice reply within \(timeout)s — proceed without it)"
        }
        sendResult(id: id, result: [
            "content": [["type": "text", "text": body]]
        ])

    default:
        sendError(id: id, code: -32601, message: "Unknown tool: \(name)")
    }
}

// MARK: - Main loop

debug("codetalker-mcp starting; baseDir=\(baseDir)")

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }

    let id = req["id"] ?? NSNull()
    let isNotification = req["id"] == nil

    guard let method = req["method"] as? String else {
        if !isNotification {
            sendError(id: id, code: -32600, message: "Missing method")
        }
        continue
    }

    let params = req["params"] as? [String: Any] ?? [:]
    debug("request method=\(method) id=\(id) isNotification=\(isNotification)")

    switch method {
    case "initialize":
        handleInitialize(id: id)
    case "tools/list":
        handleToolsList(id: id)
    case "tools/call":
        handleToolsCall(id: id, params: params)
    case "notifications/initialized":
        // No response expected for notifications.
        break
    case "ping":
        sendResult(id: id, result: [String: Any]())
    default:
        if !isNotification {
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }
}
