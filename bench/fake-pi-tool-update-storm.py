#!/usr/bin/env python3
"""Fake pi JSON-over-stdio server emitting a tool_execution_update storm.

Drives the Pilish tool-update benchmark.  On ``prompt`` the server
replays one deterministic synthetic agent turn in two phases:

Fill phase
    Completed bash/read/write/edit tool executions (default 58/5/2/1), each
    with ~20 lines of synthetic output and a preceding small thinking block
    (thinking_start/delta/end).  This builds a realistic long-session chat
    buffer before the storm starts.  All content is synthetic (for example
    "line 0042 of bash block 003"); no real paths or session text are used.

Storm phase
    ``--parallel-tools`` parallel ``subagent`` calls in one completed
    assistant tool-use message, then ``--updates`` ``tool_execution_update``
    events distributed round-robin across their executions.  Correlated tool
    results and a final assistant message complete the run before
    ``agent_end``.  Update payloads mimic pi-submarine progress text (150-300
    characters, changing every update) and carry a small ``details.run``
    object.

Storm gap pattern (deterministic, seeded PRNG; stable for a fixed Python
version):

* updates arrive in bursts of 5-10 events;
* inside a burst, gaps are uniform in 1-5 ms and are NEVER scaled -- these
  reproduce the machine-gun micro-bursts observed in real subagent sessions
  (median inter-update gap ~1 ms, peaks above 40 updates/s);
* between bursts, pauses are uniform in 200-400 ms;
* every 8th burst boundary adds a turn pause, uniform in 1500-2500 ms
  (mimics a subagent completing a turn before the next activity flush);
* ``--gap-scale`` multiplies only the inter-burst and turn pauses.

With defaults (400 updates, scale 1.0) the storm phase takes ~30 s of wall
time, so a full run finishes in roughly 30-45 s.  Use ``--gap-scale`` below
1.0 to compress wall time (for example the smoke scenario) or above 1.0 to
dilate toward a real session's average cadence (~3.5 updates/s across the
busiest 120 s of an observed session, which this pattern runs hotter than
by default to keep benchmark wall time practical).

Configuration comes from ``PI_TU_BENCH_*`` environment variables, with CLI
flags taking precedence; ``--size smoke`` selects a tiny fast preset before
other overrides apply.  The ``agent-end-cooling`` scenarios reuse the fill
controls to build a completed-tool cohort, then emit a boundary user message,
a hot-tail table, one still-live tool, and ``agent_end``.  The Emacs harness
reads the same environment to derive expected event counts, so a runner must
export matching values.

The optional ``--log-file`` records command names, event counts, and
configuration only; it never records message content.

Handshake shapes mirror test/support/fake_pi.py: get_state, get_commands,
get_session_stats, get_fork_messages, get_last_assistant_text, prompt,
abort, steer, new_session, plus ``--version`` argv handling.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import threading
import time
from pathlib import Path
from typing import Any

JsonDict = dict[str, Any]

MODEL = {
    "id": "fake-model",
    "name": "Fake Model",
    "provider": "fake",
    "api": "fake-api",
    "contextWindow": 200000,
    "maxTokens": 4096,
}

# Synthetic activity labels cycled by the storm phase.  Generic on purpose.
ACTIVITIES = (
    "subagent: thinking",
    "subagent: responding",
    "subagent: running bash tool",
    "subagent: reading files",
    "subagent: applying edit",
    "subagent: compacting context",
)

# Millisecond timestamp base shared with the reload/resume bench fixtures
# (2024-01-01T00:00:00Z); keeps synthetic timestamps boring and sortable.
TIMESTAMP_BASE_MS = 1704067200000

_WRITE_LOCK = threading.Lock()

FULL_DEFAULTS: JsonDict = {
    "fill_bash": 58,
    "fill_read": 5,
    "fill_write": 2,
    "fill_edit": 1,
    "fill_output_lines": 20,
    "updates": 400,
    "parallel_tools": 3,
    "gap_scale": 1.0,
    "seed": 20240817,
}

SMOKE_DEFAULTS: JsonDict = {
    "fill_bash": 6,
    "fill_read": 2,
    "fill_write": 1,
    "fill_edit": 1,
    "fill_output_lines": 8,
    "updates": 30,
    "parallel_tools": 2,
    "gap_scale": 0.2,
    "seed": 20240817,
}


def os_environ_get(name: str) -> str | None:
    value = os.environ.get(name)
    return value if value else None


def env_int(name: str, default: int) -> int:
    raw = os_environ_get(name)
    return int(raw) if raw else default


def env_float(name: str, default: float) -> float:
    raw = os_environ_get(name)
    return float(raw) if raw else default


def log_line(log_file: Path | None, payload: JsonDict) -> None:
    if log_file is None:
        return
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n")


def write_json(payload: JsonDict) -> None:
    with _WRITE_LOCK:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def zero_usage() -> JsonDict:
    """Return deterministic cumulative usage for a streaming update."""
    return {
        "input": 0,
        "output": 0,
        "cacheRead": 0,
        "cacheWrite": 0,
        "totalTokens": 0,
        "cost": {
            "input": 0,
            "output": 0,
            "cacheRead": 0,
            "cacheWrite": 0,
            "total": 0,
        },
    }


def write_message_update(event: JsonDict) -> None:
    """Emit one delta-only Pi 0.84 assistant message update."""
    write_json(
        {
            "type": "message_update",
            "usage": zero_usage(),
            "assistantMessageEvent": event,
        }
    )


def respond(command: JsonDict, data: JsonDict | None = None) -> None:
    response: JsonDict = {
        "type": "response",
        "command": command.get("type"),
        "success": True,
    }
    if "id" in command:
        response["id"] = command["id"]
    if data is not None:
        response["data"] = data
    write_json(response)


def state_rpc() -> JsonDict:
    return {
        "model": MODEL,
        "thinkingLevel": "medium",
        "isStreaming": False,
        "isCompacting": False,
        "steeringMode": "one-at-a-time",
        "followUpMode": "one-at-a-time",
        "sessionFile": "",
        "sessionId": "fake-tool-update-session",
        "autoCompactionEnabled": False,
        "messageCount": 0,
        "pendingMessageCount": 0,
    }


def stats_rpc() -> JsonDict:
    return {
        "totalCost": 0.42,
        "totalTokens": 123456,
        "inputTokens": 1000,
        "outputTokens": 2000,
        "cacheReadTokens": 100000,
        "cacheWriteTokens": 20000,
        "contextTokens": 50000,
        "contextWindow": 200000,
        "messageCount": 42,
    }


def tool_result(text: str, details: JsonDict | None = None) -> JsonDict:
    result: JsonDict = {"content": [{"type": "text", "text": text}]}
    if details is not None:
        result["details"] = details
    return result


def emit_tool_result_message(
    tool_call: JsonDict, result: JsonDict, timestamp_offset_ms: int
) -> JsonDict:
    """Emit and return one authoritative tool-result message."""
    message: JsonDict = {
        "role": "toolResult",
        "toolCallId": tool_call["id"],
        "toolName": tool_call["name"],
        **result,
        "isError": False,
        "timestamp": TIMESTAMP_BASE_MS + timestamp_offset_ms,
    }
    write_json({"type": "message_start", "message": message})
    write_json({"type": "message_end", "message": message})
    return message


def iso_timestamp(offset_ms: int) -> str:
    seconds, millis = divmod(TIMESTAMP_BASE_MS + offset_ms, 1000)
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(seconds)) + f".{millis:03d}Z"


def fill_output(tool: str, block_index: int, lines: int) -> str:
    return "\n".join(
        f"line {n:04d} of {tool} block {block_index:03d}: "
        f"synthetic benchmark output row with deterministic width"
        for n in range(lines)
    )


def fill_thinking(block_index: int) -> str:
    return (
        f"Synthetic thinking for fill block {block_index:03d}. "
        + "Considering the next deterministic step. " * 3
    )


def fill_tool_call(block_index: int, tool: str, output_lines: int) -> tuple[JsonDict, str]:
    """Return (arguments, result_text) for one synthetic fill tool call."""
    if tool == "bash":
        return (
            {"command": f"synthetic-scan --block {block_index:03d} --verbose"},
            fill_output("bash", block_index, output_lines),
        )
    if tool == "read":
        return (
            {"path": f"synthetic/fill/file-{block_index:03d}.txt"},
            fill_output("read", block_index, output_lines),
        )
    if tool == "write":
        content = fill_output("write", block_index, output_lines)
        return (
            {"path": f"synthetic/fill/out-{block_index:03d}.txt", "content": content},
            f"Wrote synthetic/fill/out-{block_index:03d}.txt ({len(content)} bytes)",
        )
    return (
        {
            "path": f"synthetic/fill/file-{block_index:03d}.txt",
            "oldText": f"old synthetic text {block_index:03d}",
            "newText": f"new synthetic text {block_index:03d}",
        },
        f"Edited synthetic/fill/file-{block_index:03d}.txt",
    )


def cooling_fill_tool_call(
    block_index: int, tool: str, output_lines: int
) -> tuple[JsonDict, str]:
    """Return a realistic long-or-short cooling fixture tool result."""
    tool_call_id = f"call-cooling-{block_index:04d}"
    sentinel = f"COOLING-SEMANTIC {tool_call_id}"
    # Keep a deterministic minority short while the rest exercise collapsed
    # previews.  Edit results are short by construction; every ninth other
    # result is short as well.
    lines = 2 if tool == "edit" or block_index % 9 == 0 else output_lines
    body = "\n".join(
        [sentinel]
        + [
            f"cooling fixture {tool} block {block_index:04d} line {line:02d}: "
            "deterministic representative output"
            for line in range(1, max(1, lines))
        ]
    )
    if tool == "bash":
        return (
            {"command": f"benchmark-scan --cohort {block_index:04d}"},
            body,
        )
    if tool == "read":
        return (
            {
                "path": f"synthetic/cooling/src/file-{block_index:04d}.py",
                "offset": block_index + 1,
            },
            body,
        )
    if tool == "write":
        return (
            {
                "path": f"synthetic/cooling/out/file-{block_index:04d}.txt",
                "content": body,
            },
            f"Wrote cooling fixture {block_index:04d}",
        )
    return (
        {
            "path": f"synthetic/cooling/src/file-{block_index:04d}.py",
            "oldText": f"old cooling text {block_index:04d}",
            "newText": f"new cooling text {block_index:04d}",
        },
        body,
    )


def fill_plan(config: JsonDict) -> list[str]:
    """Return fill tool names interleaved round-robin for realism."""
    remaining = {
        "bash": int(config["fill_bash"]),
        "read": int(config["fill_read"]),
        "write": int(config["fill_write"]),
        "edit": int(config["fill_edit"]),
    }
    plan: list[str] = []
    while any(remaining.values()):
        for tool in ("bash", "read", "write", "edit"):
            if remaining[tool] > 0:
                plan.append(tool)
                remaining[tool] -= 1
    return plan


def emit_fill_block(
    block_index: int, tool: str, output_lines: int, *, cooling: bool = False
) -> list[JsonDict]:
    """Emit one completed fill tool exchange and return its messages."""
    tool_call_id = (
        f"call-cooling-{block_index:04d}"
        if cooling
        else f"call-fill-{block_index:04d}"
    )
    if cooling:
        arguments, result_text = cooling_fill_tool_call(
            block_index, tool, output_lines
        )
    else:
        arguments, result_text = fill_tool_call(block_index, tool, output_lines)
    thinking = fill_thinking(block_index)
    thinking_block = {"type": "thinking", "thinking": thinking}
    tool_call = {
        "type": "toolCall",
        "id": tool_call_id,
        "name": tool,
        "arguments": arguments,
    }
    message: JsonDict = {
        "role": "assistant",
        "content": [thinking_block, tool_call],
        "timestamp": TIMESTAMP_BASE_MS + block_index * 10,
        "stopReason": "toolUse",
    }
    message_start = {**message, "content": [], "stopReason": "pending"}
    write_json({"type": "message_start", "message": message_start})
    write_message_update({"type": "thinking_start", "contentIndex": 0})
    write_message_update(
        {"type": "thinking_delta", "contentIndex": 0, "delta": thinking}
    )
    write_message_update(
        {
            "type": "thinking_end",
            "contentIndex": 0,
            "content": thinking,
        }
    )
    write_message_update({"type": "toolcall_start", "contentIndex": 1})
    write_message_update(
        {
            "type": "toolcall_delta",
            "contentIndex": 1,
            "delta": json.dumps(arguments, separators=(",", ":")),
        }
    )
    write_message_update(
        {"type": "toolcall_end", "contentIndex": 1, "toolCall": tool_call}
    )
    write_json({"type": "message_end", "message": message})

    write_json(
        {
            "type": "tool_execution_start",
            "toolCallId": tool_call_id,
            "toolName": tool,
            "args": arguments,
        }
    )
    result = tool_result(result_text)
    write_json(
        {
            "type": "tool_execution_end",
            "toolCallId": tool_call_id,
            "toolName": tool,
            "result": result,
            "isError": False,
        }
    )
    result_message = emit_tool_result_message(
        tool_call, result, block_index * 10 + 1
    )
    return [message, result_message]


def gap_schedule(updates: int, gap_scale: float, rng: random.Random) -> list[float]:
    """Return per-update delays in seconds; delay i sleeps before update i.

    See the module docstring for the documented burst/pause pattern.  Only
    inter-burst and turn pauses are multiplied by ``gap_scale``; intra-burst
    1-5 ms gaps are never scaled.
    """
    if updates <= 0:
        return []
    bursts: list[int] = []
    left = updates
    while left > 0:
        burst = min(rng.randint(5, 10), left)
        bursts.append(burst)
        left -= burst
    delays = [0.0]
    for burst_index, burst in enumerate(bursts):
        for _ in range(burst - 1):
            delays.append(rng.uniform(1.0, 5.0) / 1000.0)
        if burst_index < len(bursts) - 1:
            pause_ms = rng.uniform(200.0, 400.0)
            if (burst_index + 1) % 8 == 0:
                pause_ms += rng.uniform(1500.0, 2500.0)
            delays.append(pause_ms * gap_scale / 1000.0)
    return delays


def storm_tool_ids(parallel_tools: int) -> list[str]:
    return [f"call-storm-{index:02d}" for index in range(parallel_tools)]


def progress_text(seq: int, tool_id: str, turn: int, activity: str) -> str:
    """Return deterministic 150-300 character progress text for update SEQ."""
    base = (
        f"[u{seq:04d}] {tool_id} (turn {turn:02d}, ctx {30 + seq % 41}%): "
        f"{activity}; scanned {seq * 7 % 500} synthetic files, "
        f"{seq * 13 % 97} candidate matches. "
    )
    target = 150 + (seq * 37) % 151
    text = base
    filler = f"progress-{seq % 10}-"
    while len(text) < target:
        text += filler
    return text[:target]


def run_details(tool_id: str, tool_index: int, turn: int, seq: int, status: str) -> JsonDict:
    return {
        "run": {
            "episodeId": f"episode-{tool_index:02d}-{turn:03d}",
            "sessionId": tool_id,
            "agent": "default",
            "status": status,
            "turnCount": turn,
            "lastActivityAt": iso_timestamp(seq * 1000),
            "activity": ACTIVITIES[seq % len(ACTIVITIES)],
            "activityLog": f"logs/{tool_id}.subagents.md",
            "children": [],
        }
    }


def final_result_text(tool_id: str, tool_index: int, turns: int) -> str:
    return (
        f"STORM-FINAL-RESULT {tool_id}\n"
        f"Subagent finished after {turns} synthetic turns.\n"
        f"Summary: investigated synthetic area {tool_index}; all checks passed."
    )


def run_agent_end_cooling_scenario(
    config: JsonDict, log_file: Path | None
) -> None:
    """Emit a completed cohort and cross its hot-tail boundary at agent_end."""
    emitted = {
        "tool_execution_start": 0,
        "tool_execution_update": 0,
        "tool_execution_end": 0,
    }
    messages: list[JsonDict] = []

    write_json({"type": "agent_start"})
    for block_index, tool in enumerate(fill_plan(config)):
        messages.extend(
            emit_fill_block(
                block_index,
                tool,
                int(config["fill_output_lines"]),
                cooling=True,
            )
        )
        emitted["tool_execution_start"] += 1
        emitted["tool_execution_end"] += 1

    # This real user-message event resets the Assistant heading.  The final
    # Assistant heading is therefore the one-turn hot tail when agent_end
    # advances the production boundary.
    boundary_text = (
        "COOLING-WINDOW-SENTINEL keep this logical scroll anchor stable "
        "while older tool bodies cool."
    )
    boundary_message: JsonDict = {
        "role": "user",
        "content": [{"type": "text", "text": boundary_text}],
        "timestamp": TIMESTAMP_BASE_MS + 200_000,
    }
    write_json({"type": "message_start", "message": boundary_message})
    write_json({"type": "message_end", "message": boundary_message})
    messages.append(boundary_message)

    hot_text = (
        "The current tool and this adjacent table belong to the hot tail.\n\n"
        "| marker | state | deterministic note |\n"
        "|---|---|---|\n"
        "| COOLING-SEMANTIC-HOT-TABLE | hot | remains decorated and outside "
        "the completed cooling cohort |\n"
    )
    live_call: JsonDict = {
        "type": "toolCall",
        "id": "call-cooling-live",
        "name": "bash",
        "arguments": {
            "command": "cooling-live --sentinel COOLING-SEMANTIC-LIVE"
        },
    }
    assistant_message: JsonDict = {
        "role": "assistant",
        "content": [{"type": "text", "text": hot_text}, live_call],
        "timestamp": TIMESTAMP_BASE_MS + 200_001,
        "stopReason": "toolUse",
    }
    assistant_start = {
        **assistant_message,
        "content": [],
        "stopReason": "pending",
    }
    write_json({"type": "message_start", "message": assistant_start})
    write_message_update(
        {"type": "text_delta", "contentIndex": 0, "delta": hot_text}
    )
    write_message_update({"type": "text_end", "contentIndex": 0})
    write_message_update({"type": "toolcall_start", "contentIndex": 1})
    write_message_update(
        {
            "type": "toolcall_delta",
            "contentIndex": 1,
            "delta": json.dumps(
                live_call["arguments"], separators=(",", ":")
            ),
        }
    )
    write_message_update(
        {"type": "toolcall_end", "contentIndex": 1, "toolCall": live_call}
    )
    write_json({"type": "message_end", "message": assistant_message})
    messages.append(assistant_message)

    write_json(
        {
            "type": "tool_execution_start",
            "toolCallId": live_call["id"],
            "toolName": live_call["name"],
            "args": live_call["arguments"],
        }
    )
    emitted["tool_execution_start"] += 1

    # Deliberately omit tool_execution_end.  Production agent_end finalization
    # makes this block completed, but its position remains inside the new hot
    # tail and must not enter the cooling queue.
    write_json(
        {"type": "agent_end", "messages": messages, "willRetry": False}
    )
    write_json({"type": "agent_settled"})
    log_line(
        log_file,
        {"event": "agent-end-cooling-complete", "emitted": emitted},
    )


def run_scenario(config: JsonDict, log_file: Path | None) -> None:
    """Emit the fill phase, then the storm phase, then end the run."""
    updates = int(config["updates"])
    tools = storm_tool_ids(int(config["parallel_tools"]))
    rng = random.Random(int(config["seed"]))
    delays = gap_schedule(updates, float(config["gap_scale"]), rng)
    emitted = {
        "tool_execution_start": 0,
        "tool_execution_update": 0,
        "tool_execution_end": 0,
    }
    messages: list[JsonDict] = []

    write_json({"type": "agent_start"})

    for block_index, tool in enumerate(fill_plan(config)):
        messages.extend(
            emit_fill_block(block_index, tool, int(config["fill_output_lines"]))
        )
        emitted["tool_execution_start"] += 1
        emitted["tool_execution_end"] += 1
        time.sleep(0.002)

    # Storm: generate all parallel subagent calls in one assistant message.
    tool_calls = [
        {
            "type": "toolCall",
            "id": tool_id,
            "name": "subagent",
            "arguments": {
                "task": f"Investigate synthetic area {index} and report a summary."
            },
        }
        for index, tool_id in enumerate(tools)
    ]
    message: JsonDict = {
        "role": "assistant",
        "content": tool_calls,
        "timestamp": TIMESTAMP_BASE_MS + 100_000,
        "stopReason": "toolUse",
    }
    message_start = {**message, "content": [], "stopReason": "pending"}
    write_json({"type": "message_start", "message": message_start})
    for index, call in enumerate(tool_calls):
        write_message_update({"type": "toolcall_start", "contentIndex": index})
        write_message_update(
            {
                "type": "toolcall_delta",
                "contentIndex": index,
                "delta": json.dumps(call["arguments"], separators=(",", ":")),
            }
        )
        write_message_update(
            {
                "type": "toolcall_end",
                "contentIndex": index,
                "toolCall": call,
            }
        )
    write_json({"type": "message_end", "message": message})
    messages.append(message)

    for call in tool_calls:
        write_json(
            {
                "type": "tool_execution_start",
                "toolCallId": call["id"],
                "toolName": "subagent",
                "args": call["arguments"],
            }
        )
        emitted["tool_execution_start"] += 1

    per_tool_updates = {tool_id: 0 for tool_id in tools}
    for seq, delay in enumerate(delays):
        time.sleep(delay)
        tool_index = seq % len(tools)
        tool_id = tools[tool_index]
        per_tool_updates[tool_id] += 1
        turn = per_tool_updates[tool_id] // 8 + 1
        activity = ACTIVITIES[seq % len(ACTIVITIES)]
        write_json(
            {
                "type": "tool_execution_update",
                "toolCallId": tool_id,
                "toolName": "subagent",
                "args": {
                    "task": f"Investigate synthetic area {tool_index} and report a summary."
                },
                "partialResult": {
                    "content": [
                        {
                            "type": "text",
                            "text": progress_text(seq, tool_id, turn, activity),
                        }
                    ],
                    "details": run_details(
                        tool_id, tool_index, turn, seq, "running"
                    ),
                },
            }
        )
        emitted["tool_execution_update"] += 1

    completed: list[tuple[JsonDict, JsonDict]] = []
    for index, call in enumerate(tool_calls):
        tool_id = call["id"]
        turns = per_tool_updates[tool_id] // 8 + 1
        result = tool_result(
            final_result_text(tool_id, index, turns),
            details=run_details(tool_id, index, turns, updates, "done"),
        )
        write_json(
            {
                "type": "tool_execution_end",
                "toolCallId": tool_id,
                "toolName": "subagent",
                "result": result,
                "isError": False,
            }
        )
        completed.append((call, result))
        emitted["tool_execution_end"] += 1

    for index, (call, result) in enumerate(completed):
        messages.append(
            emit_tool_result_message(call, result, 101_000 + index)
        )

    final_text = "Synthetic tool-update storm complete."
    final_message: JsonDict = {
        "role": "assistant",
        "content": [{"type": "text", "text": final_text}],
        "timestamp": TIMESTAMP_BASE_MS + 102_000,
        "stopReason": "stop",
    }
    final_start = {**final_message, "content": [], "stopReason": "pending"}
    write_json({"type": "message_start", "message": final_start})
    write_message_update(
        {"type": "text_delta", "contentIndex": 0, "delta": final_text}
    )
    write_json({"type": "message_end", "message": final_message})
    messages.append(final_message)

    write_json(
        {"type": "agent_end", "messages": messages, "willRetry": False}
    )
    write_json({"type": "agent_settled"})
    log_line(log_file, {"event": "storm-complete", "emitted": emitted})


def parse_args(argv: list[str]) -> tuple[argparse.Namespace, Path | None]:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", default="rpc")
    parser.add_argument("--approve", action="store_true")
    parser.add_argument("--no-approve", action="store_true")
    parser.add_argument("--size", choices=("full", "smoke"), default=None)
    parser.add_argument("--log-file")
    parser.add_argument("--fill-bash", type=int)
    parser.add_argument("--fill-read", type=int)
    parser.add_argument("--fill-write", type=int)
    parser.add_argument("--fill-edit", type=int)
    parser.add_argument("--fill-output-lines", type=int)
    parser.add_argument("--updates", type=int)
    parser.add_argument("--parallel-tools", type=int)
    parser.add_argument("--gap-scale", type=float)
    parser.add_argument("--seed", type=int)
    args = parser.parse_args(argv)
    log_file = Path(args.log_file) if args.log_file else None
    return args, log_file


def resolve_config(args: argparse.Namespace) -> JsonDict:
    size = args.size or os_environ_get("PI_TU_BENCH_SIZE") or "full"
    defaults = dict(SMOKE_DEFAULTS if size == "smoke" else FULL_DEFAULTS)
    config: JsonDict = {
        "scenario": os_environ_get("PI_TU_BENCH_SCENARIO") or "storm",
        "fill_bash": env_int("PI_TU_BENCH_FILL_BASH", int(defaults["fill_bash"])),
        "fill_read": env_int("PI_TU_BENCH_FILL_READ", int(defaults["fill_read"])),
        "fill_write": env_int("PI_TU_BENCH_FILL_WRITE", int(defaults["fill_write"])),
        "fill_edit": env_int("PI_TU_BENCH_FILL_EDIT", int(defaults["fill_edit"])),
        "fill_output_lines": env_int(
            "PI_TU_BENCH_FILL_OUTPUT_LINES", int(defaults["fill_output_lines"])
        ),
        "updates": env_int("PI_TU_BENCH_UPDATES", int(defaults["updates"])),
        "parallel_tools": env_int(
            "PI_TU_BENCH_PARALLEL_TOOLS", int(defaults["parallel_tools"])
        ),
        "gap_scale": env_float("PI_TU_BENCH_GAP_SCALE", float(defaults["gap_scale"])),
        "seed": env_int("PI_TU_BENCH_SEED", int(defaults["seed"])),
    }
    overrides = {
        "fill_bash": args.fill_bash,
        "fill_read": args.fill_read,
        "fill_write": args.fill_write,
        "fill_edit": args.fill_edit,
        "fill_output_lines": args.fill_output_lines,
        "updates": args.updates,
        "parallel_tools": args.parallel_tools,
        "gap_scale": args.gap_scale,
        "seed": args.seed,
    }
    for key, value in overrides.items():
        if value is not None:
            config[key] = value
    return config


def main(argv: list[str] | None = None) -> int:
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    if raw_argv == ["--version"]:
        print("0.85.0")
        return 0

    args, log_file = parse_args([a for a in raw_argv if a != "--version"])
    config = resolve_config(args)
    log_line(log_file, {"event": "fake-pi-start", "config": {k: v for k, v in config.items()}})

    storm_thread: threading.Thread | None = None
    for raw in sys.stdin.buffer:
        line = raw.decode("utf-8", "replace").strip()
        if not line:
            continue
        try:
            command = json.loads(line)
        except json.JSONDecodeError:
            continue
        command_type = command.get("type")
        log_line(log_file, {"direction": "in", "command": command_type, "id": command.get("id")})
        if command_type == "get_state":
            respond(command, data=state_rpc())
        elif command_type == "get_commands":
            respond(command, data={"commands": []})
        elif command_type == "get_session_stats":
            respond(command, data=stats_rpc())
        elif command_type == "get_fork_messages":
            respond(command, data={"messages": []})
        elif command_type == "get_last_assistant_text":
            respond(command, data={"text": ""})
        elif command_type == "prompt":
            respond(command)
            target = (
                run_agent_end_cooling_scenario
                if str(config["scenario"]).startswith("agent-end-cooling")
                else run_scenario
            )
            storm_thread = threading.Thread(
                target=target, args=(config, log_file), daemon=True
            )
            storm_thread.start()
        elif command_type == "clear_queue":
            respond(command, data={"steering": [], "followUp": []})
        elif command_type in ("abort", "steer", "set_thinking_level"):
            respond(command)
        elif command_type == "new_session":
            respond(command, data={"cancelled": False})
        else:
            response: JsonDict = {
                "type": "response",
                "command": command_type,
                "success": False,
                "error": f"unsupported: {command_type}",
            }
            if "id" in command:
                response["id"] = command["id"]
            write_json(response)
    # stdin closed (session teardown): let an in-flight storm finish writing
    # before the interpreter exits and flushes stdout.
    if storm_thread is not None:
        storm_thread.join()
    return 0


if __name__ == "__main__":
    sys.exit(main())
