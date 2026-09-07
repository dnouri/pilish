# fake-pi scenario fixtures

`test/support/fake_pi.py` loads one JSON file per named scenario from this directory.

Manual runs:

```bash
uv run --script test/support/fake_pi.py --scenario prompt-lifecycle
./test/support/fake_pi.py --scenario extension-confirm --extension-timeout-ms 10000
```

Current prompt kinds:

## `text_stream`

Streams one assistant reply in chunks, writes real session-file messages, supports
`abort`, and can deliver one queued `steer` turn after the current reply.

Example:

```json
{
  "prompt": {
    "type": "text_stream",
    "assistant_text": "Fake reply for: {message}",
    "steer_assistant_text": "Steered fake reply for: {message}",
    "chunk_count": 6,
    "delay_ms": 30,
    "echo_user": true
  }
}
```

## `extension_dialog`

Emits an `extension_ui_request` and waits for a matching
`extension_ui_response`.  The scenario owns the default timeout, but manual
runs can override it with `--extension-timeout-ms <ms>`.  Pass `0` to disable
that timeout for tmux debugging.

Example:

```json
{
  "prompt": {
    "type": "extension_dialog",
    "command_name": "/test-confirm",
    "method": "confirm",
    "title": "Spike Confirm",
    "message": "Approve fake extension flow?",
    "timeout_ms": 100,
    "response_messages": {
      "confirmed": "CONFIRMED",
      "declined": "CANCELLED",
      "cancelled": "CANCELLED",
      "timeout": "TIMED OUT"
    }
  }
}
```

## `custom_message`

A slash-command scenario that optionally emits one visible custom message
without a full assistant turn.  This is useful for extension-like commands
such as `/test-message` or `/test-noop`.

Example:

```json
{
  "prompt": {
    "type": "custom_message",
    "command_name": "/test-message",
    "message_text": "Test message from extension"
  }
}
```

## `tool_stream`

Emits the current delta-only lifecycle: `toolcall_start`, argument
`toolcall_delta` events, authoritative `toolcall_end` and assistant
`message_end`, tool execution events, a correlated tool-result message, and the
final streamed assistant message before `agent_end`, followed by `agent_settled`.

Example:

```json
{
  "prompt": {
    "type": "tool_stream",
    "tool_name": "read",
    "tool_args": {"path": "/tmp/example.txt"},
    "partial_result_text": "line 1\n",
    "result_text": "line 1\nline 2\n",
    "assistant_text": "Read complete",
    "delay_ms": 30,
    "echo_user": true
  }
}
```

Commands exposed by `get_commands` live in the top-level `commands` array and
use the real RPC response shape (`name`, `source`, optional `description`,
`path`, `location`).
