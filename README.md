# Code Talker

A macOS companion app that lets coding agents (Claude Code, Codex, Cursor)
**talk** — speak short summaries aloud, ask the user questions by voice, and
receive spoken replies as text in real time. The agent decides what's worth
saying out loud; you don't read screens, you have a conversation.

The voice channel is implemented as an **MCP server** the agent connects to.
Two tools:

| Tool | What it does |
| --- | --- |
| `mcp__codetalker__speak(message)` | Speak a one- or two-sentence status / summary. Non-blocking. |
| `mcp__codetalker__ask(question)` | Speak a question, **block** until the user replies by voice, return their transcript as the tool result. |

Speak goes through OpenAI's **gpt-realtime-2**. Listen goes through
**Whisper** via local mic capture. The overlay UI lets you see what's
queued, stop a turn, or open the Settings panel.

## Quick start

1. **Clone and open**

   ```sh
   git clone https://github.com/CodeTalkerOSS/CodeTalker.git
   cd CodeTalker
   open CodeTalker.xcodeproj
   ```

2. **Set your OpenAI API key** in the Xcode scheme:
   Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables →
   add `OPENAI_API_KEY` = `sk-…` (a service-account key is fine).
   The same key drives both gpt-realtime-2 (speak) and Whisper (listen).
   Realtime API access on your project is required.

3. **Run** (⌘R). Allow the microphone permission prompt.

4. **Pair with an agent.** This repo registers the MCP server with Claude Code
   automatically via `.mcp.json`. To use Cursor or Codex CLI, add the server
   to that agent's MCP config (see "MCP registration" below).

5. **Start talking.** Run a Claude Code session inside this repo; the
   SessionStart hook tells Claude about the voice tools. Type a request,
   Claude calls `ask`, you reply by voice.

## Architecture

```
┌────────────────────┐                ┌─────────────────┐
│  Coding agent      │                │  Code Talker    │
│  (Claude/Codex/    │                │   macOS app     │
│   Cursor)          │                │                 │
└──────────┬─────────┘                └────┬────────────┘
           │                               │
           │  MCP tool calls               │ gpt-realtime-2  ─→ speakers
           │  ───────────────►             │  (speak)
           │                               │
           │  ▲ tool result (text)         │ AVAudioEngine + Whisper
           │  └───────────────              │  (listen)         ←─ mic
           │                               │
        ~/.codetalker/mcp-events.jsonl  ◄──┤
        ~/.codetalker/mcp-replies/<id>.txt ─┘
```

Lifecycle hooks (Codex / Claude / Cursor) still run alongside the MCP path,
but they're **purely observational** now — they normalize events into
`~/.codetalker/codex-events.jsonl` so the Settings panel can show per-agent
activity. They no longer drive voice output or inject replies.

## Supported agents

| Agent | MCP | Lifecycle hooks |
| --- | --- | --- |
| Claude Code | ✅ via `.mcp.json` | `.claude/settings.json` |
| Cursor | ✅ (add to `.cursor/mcp.json`) | `.cursor/hooks.json` |
| Codex CLI | ✅ (add to `~/.codex/config.toml`) | `.codex/hooks.json` |

## MCP registration

`mcp/codetalker_mcp.swift` is a JSON-RPC-over-stdio MCP server. The two
tools (`speak`, `ask`) are described at the top of this README.

| Agent | Config | Notes |
| --- | --- | --- |
| Claude Code | `.mcp.json` | Auto-loaded when run in this repo. The Claude SessionStart hook also injects `additionalContext` telling the agent the tools exist and when to use each. |
| Cursor | `~/.cursor/mcp.json` | Point at the same script. |
| Codex CLI | `~/.codex/config.toml` | Add an `[mcp_servers.codetalker]` entry pointing at the script. |

## Hook registration

Per-agent lifecycle hooks normalize each agent's events into the shared
`codetalker.codex-hook.v1` JSON schema and append to
`~/.codetalker/codex-events.jsonl`. The Settings panel reads that file to
show per-agent activity counters.

| Agent | Config | Script | Events handled |
| --- | --- | --- | --- |
| Codex | `.codex/hooks.json` | `.codex/hooks/codetalker_hook.swift` | `SessionStart`, `UserPromptSubmit`, `Stop`, `PermissionRequest` |
| Claude Code | `.claude/settings.json` | `.claude/hooks/codetalker_hook.swift` | `SessionStart` (also emits MCP-context), `UserPromptSubmit`, `Stop`, `Notification` |
| Cursor | `.cursor/hooks.json` | `.cursor/hooks/codetalker_hook.swift` | `sessionStart`, `beforeSubmitPrompt`, `stop`, `beforeShellExecution` |

The hooks **do not attempt to inject voice replies** via `decision:block`
(Claude) or `followup_message` (Cursor). That experimental path was
superseded by MCP `ask`. Hooks are now purely observational.

## Storage layout

| Path | Written by | Read by | Purpose |
| --- | --- | --- | --- |
| `~/.codetalker/codex-events.jsonl` | Per-agent hooks | Settings panel; session repository | Lifecycle events for per-agent activity feed |
| `~/.codetalker/mcp-events.jsonl` | MCP server (this repo) | App (`processMCPEvents`) | Outbound speak/ask requests from the agent |
| `~/.codetalker/mcp-replies/<id>.txt` | App (after Whisper transcription) | MCP server | Inbound voice reply consumed by the agent's `ask` tool call |
| `~/.codetalker/listening-debug.log` | App | You, during debugging | Voice-path breadcrumbs |

## Validation

Smoke-test a Claude `Stop` hook event:

```sh
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Ok."}]}}' > /tmp/tr.jsonl
printf '%s' '{"session_id":"demo","transcript_path":"/tmp/tr.jsonl","cwd":"/tmp","hook_event_name":"Stop"}' \
  | CODETALKER_EVENT_LOG=/tmp/ct-events.jsonl \
    /usr/bin/swift -module-cache-path /private/tmp/codetalker-swift-module-cache \
      .claude/hooks/codetalker_hook.swift
tail -n 1 /tmp/ct-events.jsonl
```

Smoke-test MCP `speak` (server-side; needs no agent):

```sh
TEST=$(mktemp -d); mkdir -p "$TEST/mcp-replies"
(
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"speak","arguments":{"message":"hello"}}}'
) | CODETALKER_DIR="$TEST" /usr/bin/swift mcp/codetalker_mcp.swift
cat "$TEST/mcp-events.jsonl"
```

## Swift service API

`CodeTalkerSessionService` is the UI-free service the overlay model
(`CodeTalkerOverlayModel`) talks to. It owns the coding-session repository,
the realtime voice client, and the local input sink.

```swift
public actor CodeTalkerSessionService {
    public func listSessions() async throws -> [CodingSession]
    public func playSessionLatestResponse(_ sessionId: CodingSession.ID) async throws
    public func announceSessionPermission(_ sessionId: CodingSession.ID) async throws
    public func pauseSessionResponse(_ sessionId: CodingSession.ID) async throws
    public func resetPlayback() async
    public func speakArbitraryMessage(_ text: String, in session: CodingSession) async throws

    @discardableResult
    public func captureAndSubmitResponse(
        _ sessionId: CodingSession.ID,
        timeout: Duration = .seconds(30)
    ) async throws -> String?

    @discardableResult
    public func listenForSession(
        _ sessionId: CodingSession.ID,
        onProgress: @Sendable @escaping (RealtimeListenEvent) async -> Void = { _ in }
    ) async throws -> CodeTalkerListeningSession
}
```

`listSessions` derives sessions from `~/.codetalker/codex-events.jsonl`.
`speakArbitraryMessage` is the live voice path — the overlay's queue worker
calls it with the agent's MCP-supplied text.
`captureAndSubmitResponse` opens a `WhisperDictation` capture (mic → WAV →
`/v1/audio/transcriptions`) and submits the transcript through the input
sink (clipboard). The overlay model writes the same text to
`~/.codetalker/mcp-replies/<id>.txt` when the turn was originated by an MCP
`ask`. `resetPlayback` drops the persistent playback peer so its `deinit`
fires and the WebRTC audio engine releases — used by Stop.

```swift
public protocol RealtimeVoiceClient: Sendable {
    func playSummary(for request: RealtimeSpeechRequest) async throws -> RealtimeSpeechResult
    func pausePlayback(sessionId: CodingSession.ID) async throws
    func startListening(for request: RealtimeListenRequest) async throws -> RealtimeListeningSession
    func resetPlayback() async
}
```

`OpenAIRealtimeVoiceClient` wraps `m1guelpf/swift-realtime-openai`'s
`Conversation` for the speak half. It keeps a single persistent playback
peer (muted) so successive `speak` turns can't overlap audio and the
server-side response stream can't echo the user's mic input back.
`startListening` is retained for protocol conformance but is no longer
called by the app — listening goes through `WhisperDictation`.

## Limitations

This is a hackathon-era demo. Things that work and things that don't:

- **macOS only.** Uses `AVAudioEngine`, AppKit overlay, and the
  `swift-realtime-openai` package's WebRTC transport.
- **Sandbox disabled.** `ENABLE_APP_SANDBOX = NO` so the app can read /
  write `~/.codetalker/` directly; the MCP server (run by the agent,
  unsandboxed) writes there too. Re-enabling sandbox would require
  entitlements for `~/.codetalker/` access.
- **No app-bundle distribution.** Run from Xcode against a fresh build.
  Each rebuild re-prompts macOS for Microphone permission unless you set
  up stable code signing in Signing & Capabilities.
- **Realtime audio path** uses `swift-realtime-openai`'s WebRTC transport;
  the playback peer is muted so it can't capture mic input and parrot you
  back.
- **Voice replies require an active `ask` call.** Pressing the row mic
  outside of an `ask` opens a listen window and copies the transcript to
  the clipboard for manual paste, but does not push it to a running agent
  — that channel was removed when the MCP path superseded it.

## Security notes

The repo's `.githooks/pre-commit` (run automatically when
`core.hooksPath = .githooks` is set) scrubs:

- `OPENAI_API_KEY` / `SECRET` / `TOKEN` / `PASSWORD` / `PASSWD` values in
  staged `.xcscheme` files.
- `DEVELOPMENT_TEAM`, `PROVISIONING_PROFILE*`, `CODE_SIGN_IDENTITY`, and
  `PRODUCT_BUNDLE_IDENTIFIER` in staged `project.pbxproj`.
- Blocks `.p12` and `.mobileprovision` commits outright.

Working-tree files are not modified — only the staged blob is rewritten.
Set `git config core.hooksPath .githooks` after cloning to opt in.

## License

See `LICENSE`.
