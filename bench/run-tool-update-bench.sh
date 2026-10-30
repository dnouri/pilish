#!/usr/bin/env bash
# run-tool-update-bench.sh - Run Pilish tool-update storm benchmarks
#
# Usage:
#   ./bench/run-tool-update-bench.sh                         # GUI via xvfb (primary lane)
#   ./bench/run-tool-update-bench.sh --batch                 # batch mode (secondary lane)
#   ./bench/run-tool-update-bench.sh -c 3                    # 3 repetitions per scenario
#   ./bench/run-tool-update-bench.sh --scenario smoke -c 1   # cheap correctness smoke
#   ./bench/run-tool-update-bench.sh --scenario agent-end-cooling -c 1
#   ./bench/run-tool-update-bench.sh --scenarios storm,smoke # comma-separated scenarios
#   ./bench/run-tool-update-bench.sh --out-dir tmp/tu-bench  # write artifacts elsewhere
#
# Default out-dir: tmp/tool-update-bench, or tmp/agent-end-cooling-bench/<lane>
# (gui|batch) when every selected scenario starts with agent-end-cooling;
# relative --out-dir paths anchor at the project root.
#
# The primary lane uses xvfb-run for GUI Emacs: the measured cost is buffer
# mutation plus redisplay/fontification, which batch mode cannot reproduce.
# Batch numbers are a faster secondary lane and CI artifact generator.
# The script fails on correctness failures, not on timing thresholds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EMACS_BIN="${EMACS:-emacs}"
if [ -z "${PACKAGE_USER_DIR:-}" ]; then
    EMACS_MAJOR_VERSION=$("$EMACS_BIN" --batch -Q \
        --eval '(princ emacs-major-version)')
    export PACKAGE_USER_DIR="$PROJECT_DIR/.cache/elpa/$EMACS_MAJOR_VERSION"
fi

BATCH=0
REPS=3
OUT_DIR=""
SCENARIOS=()

usage() {
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

require_arg() {
    local opt="$1"
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "ERROR: $opt requires an argument" >&2
        usage >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --batch) BATCH=1; shift ;;
        -c|--count)
            require_arg "$1" "${2:-}"
            REPS="$2"
            shift 2
            ;;
        --out-dir)
            require_arg "$1" "${2:-}"
            OUT_DIR="$2"
            shift 2
            ;;
        --scenario)
            require_arg "$1" "${2:-}"
            SCENARIOS+=("$2")
            shift 2
            ;;
        --scenarios)
            require_arg "$1" "${2:-}"
            IFS=',' read -r -a SCENARIOS <<< "$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if ! [[ "$REPS" =~ ^[0-9]+$ ]] || [[ "$REPS" -lt 1 ]]; then
    echo "ERROR: repetition count must be a positive integer: $REPS" >&2
    exit 1
fi

if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
    SCENARIOS=(storm)
fi

if [[ -z "$OUT_DIR" ]]; then
    all_cooling=1
    for scenario in "${SCENARIOS[@]}"; do
        if [[ "$scenario" != agent-end-cooling* ]]; then
            all_cooling=0
            break
        fi
    done
    if [[ "$all_cooling" = 1 ]]; then
        if [[ "$BATCH" = "1" ]]; then lane="batch"; else lane="gui"; fi
        OUT_DIR="$PROJECT_DIR/tmp/agent-end-cooling-bench/$lane"
    else
        OUT_DIR="$PROJECT_DIR/tmp/tool-update-bench"
    fi
fi

case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$PROJECT_DIR/$OUT_DIR" ;;
esac
while [[ "$OUT_DIR" != "/" && "$OUT_DIR" == */ ]]; do
    OUT_DIR="${OUT_DIR%/}"
done
if [[ -z "$OUT_DIR" || "$OUT_DIR" == "/" ]]; then
    echo "ERROR: refusing unsafe output directory: $OUT_DIR" >&2
    exit 1
fi

BENCH_MARKER="$OUT_DIR/.pilish-tool-update-bench"
if [[ -L "$OUT_DIR" ]]; then
    echo "ERROR: refusing symlink output directory: $OUT_DIR" >&2
    exit 1
fi
if [[ -e "$OUT_DIR" && ! -d "$OUT_DIR" ]]; then
    echo "ERROR: refusing to replace non-directory output path: $OUT_DIR" >&2
    exit 1
fi
if [[ -d "$OUT_DIR" && ! -f "$BENCH_MARKER" ]] && find "$OUT_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "ERROR: refusing to remove non-empty output directory without benchmark marker: $OUT_DIR" >&2
    exit 1
fi

scenario_env() {
    case "$1" in
        smoke)
            cat <<'EOF'
PI_TU_BENCH_FILL_BASH=6
PI_TU_BENCH_FILL_READ=2
PI_TU_BENCH_FILL_WRITE=1
PI_TU_BENCH_FILL_EDIT=1
PI_TU_BENCH_FILL_OUTPUT_LINES=8
PI_TU_BENCH_UPDATES=30
PI_TU_BENCH_PARALLEL_TOOLS=2
PI_TU_BENCH_GAP_SCALE=0.2
PI_TU_BENCH_SEED=20240817
PI_TU_BENCH_TIMEOUT_SECONDS=60
EOF
            ;;
        storm)
            cat <<'EOF'
PI_TU_BENCH_FILL_BASH=58
PI_TU_BENCH_FILL_READ=5
PI_TU_BENCH_FILL_WRITE=2
PI_TU_BENCH_FILL_EDIT=1
PI_TU_BENCH_FILL_OUTPUT_LINES=20
PI_TU_BENCH_UPDATES=400
PI_TU_BENCH_PARALLEL_TOOLS=3
PI_TU_BENCH_GAP_SCALE=1.0
PI_TU_BENCH_SEED=20240817
PI_TU_BENCH_TIMEOUT_SECONDS=240
EOF
            ;;
        agent-end-cooling-smoke)
            cat <<'EOF'
PI_TU_BENCH_FILL_BASH=6
PI_TU_BENCH_FILL_READ=2
PI_TU_BENCH_FILL_WRITE=1
PI_TU_BENCH_FILL_EDIT=1
PI_TU_BENCH_FILL_OUTPUT_LINES=12
PI_TU_BENCH_UPDATES=0
PI_TU_BENCH_PARALLEL_TOOLS=0
PI_TU_BENCH_GAP_SCALE=0.0
PI_TU_BENCH_SEED=20240817
PI_TU_BENCH_HOT_TAIL_TURNS=1
PI_TU_BENCH_COMMAND_INTERVAL_MS=100
PI_TU_BENCH_TIMEOUT_SECONDS=30
EOF
            ;;
        agent-end-cooling)
            cat <<'EOF'
PI_TU_BENCH_FILL_BASH=72
PI_TU_BENCH_FILL_READ=10
PI_TU_BENCH_FILL_WRITE=4
PI_TU_BENCH_FILL_EDIT=4
PI_TU_BENCH_FILL_OUTPUT_LINES=18
PI_TU_BENCH_UPDATES=0
PI_TU_BENCH_PARALLEL_TOOLS=0
PI_TU_BENCH_GAP_SCALE=0.0
PI_TU_BENCH_SEED=20240817
PI_TU_BENCH_HOT_TAIL_TURNS=1
PI_TU_BENCH_COMMAND_INTERVAL_MS=100
PI_TU_BENCH_TIMEOUT_SECONDS=90
EOF
            ;;
        *) echo "Unknown scenario: $1" >&2; exit 1 ;;
    esac
}

for scenario in "${SCENARIOS[@]}"; do
    scenario_env "$scenario" >/dev/null
done

export PI_TU_BENCH_PROJECT_DIR="$PROJECT_DIR"
EMACS_INIT=(
    -Q -L "$PROJECT_DIR"
    --eval '(setq inhibit-startup-screen t)'
    --eval '(require (quote package))'
    --eval '(let ((dir (getenv "PACKAGE_USER_DIR"))) (when dir (setq package-user-dir (directory-file-name (expand-file-name dir)))))'
    --eval '(package-initialize)'
    --eval '(let ((project (getenv "PI_TU_BENCH_PROJECT_DIR"))) (unless project (error "PI_TU_BENCH_PROJECT_DIR is unset")) (setq load-path (cons (expand-file-name project) load-path)))'
    -l "$SCRIPT_DIR/pilish-tool-update-bench.el"
)

printf '=== Pilish Tool-Update Benchmarks ===\n'
printf 'Project: %s\n' "$PROJECT_DIR"
if [[ "$BATCH" = "1" ]]; then
    MODE="batch"
    printf 'Mode: batch (secondary lane), %s reps\n' "$REPS"
else
    MODE="gui-xvfb"
    printf 'Mode: GUI via xvfb (primary lane), %s reps\n' "$REPS"
    if ! command -v xvfb-run >/dev/null 2>&1; then
        echo "ERROR: xvfb-run not found. Install xvfb or use --batch." >&2
        exit 1
    fi
fi
printf 'Scenarios: %s\n\n' "${SCENARIOS[*]}"

rm -rf -- "$OUT_DIR"
mkdir -p -- "$OUT_DIR"
touch -- "$BENCH_MARKER"

for scenario in "${SCENARIOS[@]}"; do
    for ((iter = 1; iter <= REPS; iter++)); do
        run_dir="$OUT_DIR/$scenario/iter-$(printf '%02d' "$iter")"
        mkdir -p "$run_dir"
        env_file="$run_dir/env"
        scenario_env "$scenario" > "$env_file"
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
        export PI_TU_BENCH_SCENARIO="$scenario"
        export PI_TU_BENCH_ITERATION="$iter"
        export PI_TU_BENCH_OUT_DIR="$run_dir"
        export PI_TU_BENCH_RUNNER_OUT_DIR="$OUT_DIR"
        export PI_TU_BENCH_DISPLAY=$([[ "$BATCH" = "1" ]] && echo 0 || echo 1)

        printf '[%s/%s] running\n' "$scenario" "$iter"
        if [[ "$BATCH" = "1" ]]; then
            if ! "$EMACS_BIN" --batch "${EMACS_INIT[@]}" \
                -f pilish-tu-bench-run-batch \
                > "$run_dir/stdout.log" 2> "$run_dir/stderr.log"; then
                cat "$run_dir/stdout.log"
                cat "$run_dir/stderr.log" >&2
                exit 1
            fi
        else
            if ! xvfb-run -a env GDK_BACKEND=x11 PATH="$PATH" \
                "$EMACS_BIN" --geometry 120x40 "${EMACS_INIT[@]}" \
                --eval '(let ((standard-output (function external-debugging-output))) (kill-emacs (pilish-tu-bench--exit-status (pilish-tu-bench-run))))' \
                </dev/null > "$run_dir/stdout.log" 2> "$run_dir/stderr.log"; then
                cat "$run_dir/stdout.log"
                cat "$run_dir/stderr.log" >&2
                exit 1
            fi
        fi
    done
done

python3 - "$OUT_DIR" "$MODE" "$REPS" "${SCENARIOS[*]}" <<'PY'
from __future__ import annotations

import csv
import json
import statistics
import sys
from pathlib import Path
from typing import Any

out = Path(sys.argv[1])
mode = sys.argv[2]
reps = sys.argv[3]
scenarios_arg = sys.argv[4]
rows: list[dict[str, Any]] = []


def as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


for result_path in sorted(out.glob("*/iter-*/result.json")):
    with result_path.open(encoding="utf-8") as handle:
        result = json.load(handle)
    probe = as_dict(result.get("probe"))
    renders = as_dict(result.get("renders"))
    cooling = as_dict(result.get("cooling"))
    drain = as_dict(cooling.get("drain"))
    final = as_dict(cooling.get("final"))
    command_stats = as_dict(as_dict(cooling.get("commands")).get("stats"))
    slices_value = cooling.get("slices")
    slices = slices_value if isinstance(slices_value, list) else []
    agent_end = as_dict(result.get("agentEnd"))
    agent_end_filter = as_dict(
        as_dict(result.get("processFilters")).get("agentEnd")
    )
    update_stats = next(
        (row for row in result.get("eventStats", [])
         if row.get("type") == "tool_execution_update"),
        {},
    )
    failed_checks: list[str] = []
    not_applicable_checks: list[str] = []
    checks = result.get("checks")
    if not isinstance(checks, list) or not checks:
        failed_checks.append("missing-or-empty-checks")
        checks = []
    for check in checks:
        if not isinstance(check, dict):
            failed_checks.append("malformed-check")
            continue
        name = check.get("name")
        category = check.get("category")
        status = check.get("status")
        valid_name = isinstance(name, str) and bool(name)
        valid_category = category in (
            "behavior", "cooling-policy", "scheduler-contract", "viewport"
        )
        allowed_na = mode == "batch" and category == "viewport"
        if (not valid_name or not valid_category
                or status not in ("pass", "fail", "not-applicable")
                or status == "fail"
                or (status == "not-applicable" and not allowed_na)):
            failed_checks.append(name if valid_name else "malformed-check")
        elif status == "not-applicable":
            not_applicable_checks.append(name)
    derived_ok = result.get("settled") is True and not failed_checks
    if result.get("ok") is not derived_ok:
        failed_checks.append("result-ok-verdict-mismatch")
    rows.append({
        "scenario": result.get("scenario"),
        "iteration": result.get("iteration"),
        "ok": result.get("ok") is True and derived_ok and not failed_checks,
        "settled": result.get("settled") is True,
        "coolingScenario": str(result.get("scenario", "")).startswith("agent-end-cooling"),
        "wallMs": result.get("wallMs") or 0,
        "agentEndMs": agent_end.get("wallMs") or 0,
        "agentEndFilterMs": agent_end_filter.get("wallMs") or 0,
        "drainWallMs": drain.get("wallMs") or 0,
        "drainActiveMs": drain.get("activeMs") or 0,
        "drainCallbacks": drain.get("callbacks") or 0,
        "sliceMaxMs": max((float(row.get("wallMs") or 0) for row in slices), default=0),
        "drainGcs": drain.get("gcs") or 0,
        "updateMeanMs": update_stats.get("meanMs") or 0,
        "updateMaxMs": update_stats.get("maxMs") or 0,
        "replaceBodyCalls": renders.get("replaceBody", {}).get("total") or 0,
        "displayToolEndCalls": renders.get("displayToolEnd", {}).get("total") or 0,
        "probeP95Ms": probe.get("p95Ms") or 0,
        "probeMaxMs": probe.get("maxMs") or 0,
        "probeOver100Ms": probe.get("over100Ms") or 0,
        "probeOver250Ms": probe.get("over250Ms") or 0,
        "commandLatenessP95Ms": command_stats.get("latenessP95Ms") or 0,
        "commandLatenessMaxMs": command_stats.get("latenessMaxMs") or 0,
        "commandDurationMaxMs": command_stats.get("durationMaxMs") or 0,
        "coldTools": final.get("coldTools") or 0,
        "hotToolOverlays": final.get("toolOverlays") or 0,
        "bufferBytes": result.get("bufferBytes"),
        "overlays": result.get("overlays"),
        "seconds": result.get("seconds"),
        "failedChecks": ";".join(failed_checks),
        "notApplicableChecks": ";".join(not_applicable_checks),
        "error": result.get("error") or "",
        "resultPath": str(result_path),
    })

csv_path = out / "summary.csv"
if rows:
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

summary_lines: list[str] = []
summary_lines.append("# Pilish tool-update benchmark summary")
summary_lines.append("")
summary_lines.append("Synthetic deterministic workload only; no private session content is used.")
summary_lines.append("")
summary_lines.append(f"- Mode: `{mode}`")
summary_lines.append(f"- Repetitions per scenario: `{reps}`")
summary_lines.append(f"- Scenarios: `{scenarios_arg}`")
summary_lines.append(
    "- Timing policy: diagnostics only (`<100 ms` target, `>250 ms` concern, "
    "`>1 s` severe); correctness failures alone fail the run"
)

print("\nsummary")
failed = [row for row in rows if not row["ok"]]
storm_rows = [row for row in rows if not row["coolingScenario"]]
cooling_rows = [row for row in rows if row["coolingScenario"]]

if storm_rows:
    summary_lines.append("")
    summary_lines.append("## Tool-update storm")
    summary_lines.append("")
    summary_lines.append("| scenario | wall ms (median) | update mean ms | update max ms | replace-body calls | tool-end renders | probe p95 ms | probe max ms | >100 ms late | >250 ms late | successful runs |")
    summary_lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    print("\ntool-update storm")
    print("scenario    wall-med  upd-mean  upd-max  replace-body  tool-end  probe-p95  probe-max  >100ms  >250ms  ok")
    print("--------    --------  --------  -------  ------------  --------  ---------  ---------  ------  ------  --")
    for scenario in sorted({str(row["scenario"]) for row in storm_rows}):
        subset_all = [row for row in storm_rows if str(row["scenario"]) == scenario]
        subset = [row for row in subset_all if row["ok"]]
        if not subset:
            print(f"{scenario:<11} no successful runs")
            summary_lines.append(f"| {scenario} | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | 0/{len(subset_all)} |")
            continue
        walls = [float(row["wallMs"]) for row in subset]
        upd_mean = statistics.median(float(row["updateMeanMs"]) for row in subset)
        upd_max = max(float(row["updateMaxMs"]) for row in subset)
        replace_body = max(int(row["replaceBodyCalls"]) for row in subset)
        tool_end = max(int(row["displayToolEndCalls"]) for row in subset)
        p95 = statistics.median(float(row["probeP95Ms"]) for row in subset)
        pmax = max(float(row["probeMaxMs"]) for row in subset)
        over100 = max(int(row["probeOver100Ms"]) for row in subset)
        over250 = max(int(row["probeOver250Ms"]) for row in subset)
        ok_count = f"{len(subset)}/{len(subset_all)}"
        print(
            f"{scenario:<11} {statistics.median(walls):8.0f}  {upd_mean:8.2f}  {upd_max:7.1f}  "
            f"{replace_body:12d}  {tool_end:8d}  {p95:9.1f}  {pmax:9.1f}  {over100:6d}  {over250:6d}  {ok_count}"
        )
        summary_lines.append(
            f"| {scenario} | {statistics.median(walls):.0f} | {upd_mean:.2f} | {upd_max:.1f} | "
            f"{replace_body} | {tool_end} | {p95:.1f} | {pmax:.1f} | {over100} | {over250} | {ok_count} |"
        )

if cooling_rows:
    summary_lines.append("")
    summary_lines.append("## Deferred agent_end cooling")
    summary_lines.append("")
    summary_lines.append("| scenario | agent_end ms | enclosing filter ms | drain wall ms | drain active ms | callbacks | max slice ms | probe p95/max ms | command late p95/max ms | command max ms | GC | cold/hot | successful runs |")
    summary_lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    print("\ndeferred agent_end cooling")
    print("scenario                  end-ms  filter-ms  drain-ms  active-ms  callbacks  slice-max  probe-p95/max  cmd-late-p95/max  cmd-max  GC  cold/hot  ok")
    print("------------------------  ------  ---------  --------  ---------  ---------  ---------  -------------  ----------------  -------  --  --------  --")
    for scenario in sorted({str(row["scenario"]) for row in cooling_rows}):
        subset_all = [row for row in cooling_rows if str(row["scenario"]) == scenario]
        subset = [row for row in subset_all if row["ok"]]
        if not subset:
            print(f"{scenario:<24} no successful runs")
            summary_lines.append(f"| {scenario} | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | 0/{len(subset_all)} |")
            continue
        def median(key: str) -> float:
            return statistics.median(float(row[key]) for row in subset)

        def maximum(key: str) -> float:
            return max(float(row[key]) for row in subset)
        callbacks = int(maximum("drainCallbacks"))
        gcs = int(maximum("drainGcs"))
        cold = int(maximum("coldTools"))
        hot = int(maximum("hotToolOverlays"))
        ok_count = f"{len(subset)}/{len(subset_all)}"
        print(
            f"{scenario:<24} {median('agentEndMs'):7.2f}  {median('agentEndFilterMs'):9.2f}  "
            f"{median('drainWallMs'):8.1f}  {median('drainActiveMs'):9.1f}  {callbacks:9d}  "
            f"{maximum('sliceMaxMs'):9.2f}  {median('probeP95Ms'):5.1f}/{maximum('probeMaxMs'):5.1f}  "
            f"{median('commandLatenessP95Ms'):7.2f}/{maximum('commandLatenessMaxMs'):7.2f}  "
            f"{maximum('commandDurationMaxMs'):7.2f}  {gcs:2d}  {cold}/{hot}  {ok_count}"
        )
        summary_lines.append(
            f"| {scenario} | {median('agentEndMs'):.2f} | {median('agentEndFilterMs'):.2f} | "
            f"{median('drainWallMs'):.1f} | {median('drainActiveMs'):.1f} | {callbacks} | "
            f"{maximum('sliceMaxMs'):.2f} | {median('probeP95Ms'):.1f}/{maximum('probeMaxMs'):.1f} | "
            f"{median('commandLatenessP95Ms'):.2f}/{maximum('commandLatenessMaxMs'):.2f} | "
            f"{maximum('commandDurationMaxMs'):.2f} | {gcs} | {cold}/{hot} | {ok_count} |"
        )

summary_lines.append("")
summary_lines.append("## Artifacts")
summary_lines.append("")
summary_lines.append(f"- CSV: `{csv_path}`")
summary_lines.append("- Per-run reports: `SCENARIO/iter-NN/report.md`")
summary_lines.append("- Per-run JSON: `SCENARIO/iter-NN/result.json`")
summary_lines.append("- Per-run timing TSV: `SCENARIO/iter-NN/times.tsv`")
if cooling_rows:
    summary_lines.append("- Per-callback cooling TSV: `SCENARIO/iter-NN/cooling-slices.tsv`")
    summary_lines.append("- Per-command heartbeat TSV: `SCENARIO/iter-NN/commands.tsv`")

not_applicable = [row for row in rows if row["notApplicableChecks"]]
if not_applicable:
    summary_lines.extend(["", "## Not applicable checks", ""])
    for row in not_applicable:
        summary_lines.append(
            f"- {row['scenario']} iter {row['iteration']}: {row['notApplicableChecks']}"
        )

if failed:
    summary_lines.append("")
    summary_lines.append("## Correctness failures")
    summary_lines.append("")
    for row in failed:
        detail = row["error"] or f"failed checks: {row['failedChecks']}"
        summary_lines.append(
            f"- {row['scenario']} iter {row['iteration']}: {detail} ({row['resultPath']})"
        )

summary_path = out / "summary.md"
summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")

print(f"\nWrote {csv_path}")
print(f"Wrote {summary_path}")

if not rows:
    print("ERROR: no benchmark result rows found", file=sys.stderr)
    raise SystemExit(1)
if failed:
    print("ERROR: one or more tool-update correctness checks failed", file=sys.stderr)
    raise SystemExit(1)
PY
