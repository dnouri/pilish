#!/usr/bin/env bash
# run-tool-md-ts-bench.sh - Wall-time benchmark for the tool rewrites that
# suspend md-ts's expensive stale-side-effect change hook.
#
# Usage:
#   ./bench/run-tool-md-ts-bench.sh              # GUI via xvfb (primary lane)
#   ./bench/run-tool-md-ts-bench.sh --batch      # batch mode (secondary lane)
#   ./bench/run-tool-md-ts-bench.sh --smoke      # cheap correctness smoke
#   PILISH_TMD_BENCH_SECTIONS=3200 ./bench/run-tool-md-ts-bench.sh --batch
#
# Environment:
#   PILISH_TMD_BENCH_SECTIONS   transcript size (default 1600, ~650 KB)
#   PILISH_TMD_BENCH_ITERATIONS timed iterations per repetition (default 30)
#   PILISH_TMD_BENCH_REPS       repetitions per scenario (default 3)
#   PILISH_TMD_BENCH_OUT_DIR    artifact directory (default per lane)
#
# The primary lane uses xvfb-run for GUI Emacs, because the measured cost is
# dominated by buffer mutation plus redisplay/fontification, which batch mode
# cannot reproduce.  Batch numbers are useful for CI trend artifacts.  The run
# fails on correctness violations, not on timing thresholds.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EMACS_BIN="${EMACS:-emacs}"
if [ -z "${PACKAGE_USER_DIR:-}" ]; then
    EMACS_MAJOR_VERSION=$("$EMACS_BIN" --batch -Q \
        --eval '(princ emacs-major-version)')
    export PACKAGE_USER_DIR="$PROJECT_DIR/.cache/elpa/$EMACS_MAJOR_VERSION"
fi

BATCH=0
SMOKE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --batch) BATCH=1; shift ;;
        --smoke) SMOKE=1; BATCH=1; shift ;;
        *) shift ;;
    esac
done

if [ "$SMOKE" = "1" ]; then
    LANE="smoke"
    export PILISH_TMD_BENCH_SECTIONS="${PILISH_TMD_BENCH_SECTIONS:-400}"
    export PILISH_TMD_BENCH_ITERATIONS="${PILISH_TMD_BENCH_ITERATIONS:-5}"
    export PILISH_TMD_BENCH_REPS="${PILISH_TMD_BENCH_REPS:-1}"
elif [ "$BATCH" = "1" ]; then
    LANE="batch"
else
    LANE="gui"
fi
export PILISH_TMD_BENCH_LANE="$LANE"
export PILISH_TMD_BENCH_OUT_DIR="${PILISH_TMD_BENCH_OUT_DIR:-$PROJECT_DIR/tmp/tool-md-ts-bench/$LANE}"

EMACS_INIT=(
    -Q -L "$PROJECT_DIR"
    --eval "(progn (require 'package)
                   (let ((dir (getenv \"PACKAGE_USER_DIR\")))
                     (when dir (setq package-user-dir (directory-file-name (expand-file-name dir)))))
                   (package-initialize)
                   (add-to-list 'treesit-extra-load-path (expand-file-name \"~/.emacs.d/tree-sitter\"))
                   (setq load-prefer-newer t))"
    -l "$SCRIPT_DIR/pilish-tool-md-ts-bench.el"
)

echo "=== Pilish Tool md-ts Wall-Time Benchmarks ==="
echo "Project: $PROJECT_DIR"

if [ "$BATCH" = "1" ]; then
    echo "Mode: batch (secondary lane), lane=$LANE"
    echo ""
    "$EMACS_BIN" "${EMACS_INIT[@]}" --batch -f pilish-tmd-bench-run-batch 2>&1
else
    echo "Mode: GUI via xvfb (primary lane), lane=$LANE"
    echo ""
    if ! command -v xvfb-run &>/dev/null; then
        echo "ERROR: xvfb-run not found. Install xvfb or use --batch."
        exit 1
    fi
    xvfb-run -a env GDK_BACKEND=x11 PATH="$PATH" \
        "$EMACS_BIN" "${EMACS_INIT[@]}" \
        --eval "(progn (pilish-tmd-bench-run) (kill-emacs 0))" </dev/null 2>&1
fi
