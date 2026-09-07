#!/usr/bin/env python3
"""Fake pi JSON-over-stdio server for reload/resume benchmarks.

The server reads deterministic synthetic JSONL session fixtures and returns only
RPC responses.  Its optional log records command names, byte counts, durations,
and fixture paths; it never records message content.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

Json = dict[str, Any]


def log_line(log_file: Path | None, payload: Json) -> None:
    if log_file is None:
        return
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n")


def write_response(
    command: Json,
    *,
    data: Json | None = None,
    success: bool = True,
    error: str | None = None,
    log_file: Path | None = None,
) -> None:
    response: Json = {
        "type": "response",
        "command": command.get("type"),
        "success": success,
    }
    if "id" in command:
        response["id"] = command["id"]
    if data is not None:
        response["data"] = data
    if error is not None:
        response["error"] = error
    line = json.dumps(response, separators=(",", ":"), ensure_ascii=False) + "\n"
    log_line(
        log_file,
        {
            "direction": "out",
            "command": command.get("type"),
            "bytes": len(line.encode("utf-8")),
            "success": success,
        },
    )
    sys.stdout.write(line)
    sys.stdout.flush()


def read_session_messages(path: Path) -> list[Json]:
    messages: list[Json] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            obj = json.loads(line)
            if obj.get("type") == "message" and isinstance(obj.get("message"), dict):
                messages.append(obj["message"])
    return messages


def latest_session_name(path: Path) -> str | None:
    name: str | None = None
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                obj = json.loads(line)
                if obj.get("type") == "session_info" and isinstance(obj.get("name"), str):
                    name = obj["name"]
    except OSError:
        return None
    return name


def message_count(path: Path) -> int:
    count = 0
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if '"type":"message"' in line or '"type": "message"' in line:
                    count += 1
    except OSError:
        pass
    return count


def session_state(session_file: Path) -> Json:
    data: Json = {
        "model": {
            "id": "fake-model",
            "name": "Fake Model",
            "provider": "fake",
            "api": "fake-api",
            "contextWindow": 200000,
            "maxTokens": 4096,
        },
        "thinkingLevel": "medium",
        "isStreaming": False,
        "isCompacting": False,
        "steeringMode": "one-at-a-time",
        "followUpMode": "one-at-a-time",
        "sessionFile": str(session_file),
        "sessionId": session_file.stem,
        "autoCompactionEnabled": False,
        "messageCount": message_count(session_file),
        "pendingMessageCount": 0,
    }
    name = latest_session_name(session_file)
    if name:
        data["sessionName"] = name
    return data


def main(argv: list[str] | None = None) -> int:
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    if raw_argv == ["--version"]:
        print("0.85.0")
        return 0

    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", default="rpc")
    parser.add_argument("--approve", action="store_true")
    parser.add_argument("--no-approve", action="store_true")
    parser.add_argument("--initial-session", required=True)
    parser.add_argument("--log-file")
    parser.add_argument("--delay-ms", type=int, default=0)
    args = parser.parse_args(raw_argv)

    current_session = Path(args.initial_session).resolve()
    log_file = Path(args.log_file) if args.log_file else None
    log_line(log_file, {"event": "fake-pi-start", "session": str(current_session)})

    for line in sys.stdin:
        if not line.strip():
            continue
        command = json.loads(line)
        started = time.perf_counter()
        command_type = command.get("type")
        log_line(log_file, {"direction": "in", "command": command_type, "id": command.get("id")})
        try:
            if args.delay_ms > 0:
                time.sleep(args.delay_ms / 1000)
            if command_type == "get_state":
                write_response(command, data=session_state(current_session), log_file=log_file)
            elif command_type == "switch_session":
                selected = command.get("sessionPath")
                if not isinstance(selected, str):
                    write_response(command, success=False, error="missing sessionPath", log_file=log_file)
                else:
                    current_session = Path(selected).resolve()
                    write_response(command, data={"cancelled": False}, log_file=log_file)
            elif command_type == "get_messages":
                messages = read_session_messages(current_session)
                write_response(command, data={"messages": messages}, log_file=log_file)
            elif command_type == "get_commands":
                write_response(command, data={"commands": []}, log_file=log_file)
            elif command_type == "get_session_stats":
                write_response(command, data={"totalCost": 0, "contextPercentage": 0}, log_file=log_file)
            elif command_type == "new_session":
                write_response(command, data={"cancelled": False}, log_file=log_file)
            else:
                write_response(command, success=False, error=f"unsupported command: {command_type}", log_file=log_file)
        finally:
            log_line(
                log_file,
                {
                    "event": "handled",
                    "command": command_type,
                    "seconds": round(time.perf_counter() - started, 6),
                    "session": str(current_session),
                },
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
