# Code Talker Codex Hooks

Code Talker uses project-local Codex hooks as the boundary between a coding-agent session and the app/realtime voice stack. The hooks do not call OpenAI, capture audio, or render UI. They normalize Codex events and deliver them to whatever local process is responsible for GPT-realtime-2 and speech.

## Current Hook Flow

| Codex hook | Code Talker event | Consumer behavior |
| --- | --- | --- |
| `SessionStart` | `session.started` | Create or refresh the active coding session row. |
| `UserPromptSubmit` | `user.prompt_submitted` | Mark the session as queued or pending after voice/text input is sent to Codex. |
| `Stop` | `assistant.response_ready` | Summarize `data.assistant_message` into one or two spoken sentences and play it. |

Codex does not currently expose a hook literally named `response received`. For the demo scope, `Stop` is the turn-complete trigger because its payload includes `last_assistant_message`.

## Delivery

The hook command is configured in `.codex/hooks.json` and runs `.codex/hooks/codetalker_hook.swift`.

Delivery is intentionally fail-open:

- The hook appends every normalized event as JSON Lines.
- The hook optionally POSTs the same event to the app.
- Hook failures are ignored so Codex turns are not blocked if Code Talker is closed.
- The hook writes nothing to stdout, so it does not alter Codex context or stop behavior.

Environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CODETALKER_EVENT_LOG` | `~/.codetalker/codex-events.jsonl` | JSONL file consumed by local tooling or a file watcher. |
| `CODETALKER_HOOK_ENDPOINT` | unset | Optional local HTTP endpoint, for example `http://127.0.0.1:52733/hooks/codex`. |
| `CODETALKER_HOOK_URL` | unset | Alias for `CODETALKER_HOOK_ENDPOINT`. |
| `CODETALKER_HOOK_TIMEOUT_SECONDS` | `0.6` | POST timeout, clamped from `0.05` to `5.0` seconds. |
| `CODETALKER_HOOK_DEBUG` | unset | Set to `1` to print hook errors to stderr during development. |

## Event Shape

All events share this envelope:

```json
{
  "schema": "codetalker.codex-hook.v1",
  "event_id": "uuid",
  "event": "assistant.response_ready",
  "hook_event_name": "Stop",
  "created_at": "2026-05-27T00:00:00.000000Z",
  "received_unix_ms": 1780000000000,
  "session_id": "codex-session-id",
  "turn_id": "codex-turn-id",
  "cwd": "/path/to/repo",
  "transcript_path": "/path/to/transcript.jsonl",
  "model": "gpt-5-codex",
  "permission_mode": "default",
  "voice_action": "speak_summary",
  "data": {}
}
```

For `assistant.response_ready`, `data` contains:

```json
{
  "assistant_message": "Raw Codex assistant response text.",
  "summary_instruction": "Summarize this coding-agent response into one or two spoken sentences.",
  "stop_hook_active": false
}
```

The realtime service owns the actual summarization and speech. The hook only provides the source message and an explicit `voice_action`.

For `permission.requested`, `voice_action` is `announce_permission`, and `data` may contain `tool_name`, `command`, and `permission_reason`.

## Local Validation

Validate the hook config:

```sh
/usr/bin/swift -module-cache-path /private/tmp/codetalker-swift-module-cache -e 'import Foundation; _ = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: ".codex/hooks.json")))'
```

Simulate a Codex `Stop` event without touching the default user log:

```sh
printf '%s\n' '{"hook_event_name":"Stop","session_id":"demo","turn_id":"turn-1","cwd":"/tmp/demo","last_assistant_message":"Implemented the hook bridge and validated it."}' \
  | CODETALKER_EVENT_LOG=/tmp/codetalker-events.jsonl \
    /usr/bin/swift -module-cache-path /private/tmp/codetalker-swift-module-cache .codex/hooks/codetalker_hook.swift
```

Inspect the emitted event:

```sh
tail -n 1 /tmp/codetalker-events.jsonl
```
