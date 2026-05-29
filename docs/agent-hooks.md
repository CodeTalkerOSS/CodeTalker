# Code Talker hook & MCP layout

Code Talker connects coding agents (Codex, Claude Code, Cursor) to voice via
two surfaces. Hooks are reactive lifecycle notifiers; MCP is the live
voice channel.

## MCP — the live voice channel

`mcp/codetalker_mcp.swift` is a JSON-RPC-over-stdio MCP server registered with
each agent that supports MCP. It exposes two tools:

| Tool | Behavior |
| --- | --- |
| `speak(message)` | Append a `speak` event to `~/.codetalker/mcp-events.jsonl`; return immediately. The app picks it up and speaks the message via the realtime API. Use for status / summary lines. |
| `ask(question, timeout_seconds?)` | Append an `ask` event, then **block** polling `~/.codetalker/mcp-replies/<id>.txt` for the user's spoken reply. The app speaks the question, captures the user's voice with Whisper, writes the transcript to the reply file. The server reads the file, removes it, returns the transcript as the tool result. |

Registration:

| Agent | Config | Notes |
| --- | --- | --- |
| Claude Code | `.mcp.json` | Auto-loaded by Claude Code when run in this repo. |
| Cursor | `.cursor/mcp.json` (user-side) | Point at the same script. |
| Codex CLI | `~/.codex/config.toml` | Add an `[mcp_servers.codetalker]` entry pointing at the script. |

The Claude Code `SessionStart` hook also emits an `additionalContext` block
telling the agent these tools exist and when to prefer each — without that
nudge, the tools are available but unused.

## Hooks — event recorders

Per-agent lifecycle hooks normalize each agent's events into the shared
`codetalker.codex-hook.v1` JSON schema and append to
`~/.codetalker/codex-events.jsonl`. The Settings panel reads that file to
show per-agent activity counters.

| Agent | Config | Script | Events handled |
| --- | --- | --- | --- |
| Codex | `.codex/hooks.json` | `.codex/hooks/codetalker_hook.swift` | `SessionStart`, `UserPromptSubmit`, `Stop`, `PermissionRequest` |
| Claude Code | `.claude/settings.json` | `.claude/hooks/codetalker_hook.swift` | `SessionStart` (also emits MCP-context), `UserPromptSubmit`, `Stop`, `Notification` |
| Cursor | `.cursor/hooks.json` | `.cursor/hooks/codetalker_hook.swift` | `sessionStart`, `beforeSubmitPrompt`, `stop`, `beforeShellExecution` |

The hooks **no longer attempt to inject voice replies** via `decision:block`
(Claude) or `followup_message` (Cursor). That experimental path was
superseded by MCP `ask` and removed. Hooks are now purely observational.

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

Smoke-test MCP `ask` (server-side; needs no agent):

```sh
TEST=$(mktemp -d); mkdir -p "$TEST/mcp-replies"
(
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"speak","arguments":{"message":"hello"}}}'
) | CODETALKER_DIR="$TEST" /usr/bin/swift mcp/codetalker_mcp.swift
cat "$TEST/mcp-events.jsonl"
```
