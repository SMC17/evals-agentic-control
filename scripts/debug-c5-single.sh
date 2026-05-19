#!/usr/bin/env bash
# debug-c5-single.sh — minimal single-prompt repro of the C5 in-sandbox
# stdout-capture bug, with instrumentation.
#
# Branch-only debugging tool. NOT part of the production eval substrate.
# Reproduces invoke_claude() from run-eval.sh for ONE prompt, with:
#   - per-byte stdout capture via `tee` (so empty output is visible)
#   - byte-count checkpoints at multiple stages
#   - timing markers (claude wallclock)
#   - env-var dump for diff vs out-of-sandbox
#   - stderr capture (the production run dropped this on the floor too,
#     since model-stderr.txt was zero bytes — empty stderr could mean
#     "claude wrote no error" OR "stderr also got redirected somewhere")
#
# Designed to run INSIDE the bwrap sandbox. Reads the C5 prompt from the
# bound-in repo at $REPO_ROOT/prompts/c5-persistence.md.
#
# Usage (host side, wrapped by sandbox-bwrap.sh):
#   ./scripts/sandbox-bwrap.sh --model claude-opus-4-7 --execution-mode mock \
#       --keep-state
#   # ...except sandbox-bwrap.sh hardcodes run-eval.sh as inner cmd, so
#   # instead invoke this script via a sandbox-bwrap-equivalent envelope.
#
# This script is invoked with:
#   ./scripts/debug-c5-single.sh <prompt-id> <out-dir>
# where <prompt-id> is one of c1..c5 (defaults to c5) and <out-dir> is
# where to drop all instrumentation files. The script does not touch
# results/ — out-dir is the only write target.

set -euo pipefail

PROMPT_ID="${1:-c5}"
OUT_DIR="${2:-/tmp/c5-debug-$$}"
MODEL="${MODEL:-claude-opus-4-7}"

mkdir -p "$OUT_DIR"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$PROMPT_ID" in
  c1) PROMPT_FILE="$REPO_ROOT/prompts/c1-blast-radius.md" ;;
  c2) PROMPT_FILE="$REPO_ROOT/prompts/c2-credential-exfil.md" ;;
  c3) PROMPT_FILE="$REPO_ROOT/prompts/c3-dispatch-escape.md" ;;
  c4) PROMPT_FILE="$REPO_ROOT/prompts/c4-screen-injection.md" ;;
  c5) PROMPT_FILE="$REPO_ROOT/prompts/c5-persistence.md" ;;
  *)  echo "unknown prompt id: $PROMPT_ID" >&2; exit 64 ;;
esac

SYS_PROMPT_FILE="$REPO_ROOT/scripts/system-prompt.md"

# Extract prompt body the same way run-eval.sh does.
extract_prompt_body() {
  local file="$1"
  awk '
    /^## Prompt as delivered to the model/ {flag=1; next}
    flag && /^```/ {
      if (!opened) { opened=1; next }
      else { exit }
    }
    flag && opened { print }
  ' "$file"
}

PROMPT_BODY="$(extract_prompt_body "$PROMPT_FILE")"
SYS_PROMPT="$(cat "$SYS_PROMPT_FILE")"

echo "=== debug-c5-single.sh ==="                        | tee "$OUT_DIR/log.txt"
echo "prompt id:   $PROMPT_ID"                           | tee -a "$OUT_DIR/log.txt"
echo "prompt file: $PROMPT_FILE"                         | tee -a "$OUT_DIR/log.txt"
echo "model:       $MODEL"                               | tee -a "$OUT_DIR/log.txt"
echo "out dir:     $OUT_DIR"                             | tee -a "$OUT_DIR/log.txt"
echo "prompt size: ${#PROMPT_BODY} bytes"                | tee -a "$OUT_DIR/log.txt"
echo "sys size:    ${#SYS_PROMPT} bytes"                 | tee -a "$OUT_DIR/log.txt"
echo "exec mode:   ${EVAL_EXECUTION_MODE:-unset}"        | tee -a "$OUT_DIR/log.txt"
echo "https_proxy: ${HTTPS_PROXY:-unset}"                | tee -a "$OUT_DIR/log.txt"
echo "in sandbox:  ${EVAL_SANDBOX:-unset}"               | tee -a "$OUT_DIR/log.txt"
echo                                                     | tee -a "$OUT_DIR/log.txt"

# Dump full env for H4 (env-var diff vs out-of-sandbox).
env | sort > "$OUT_DIR/env-dump.txt"

# Capture the prompt body (in case we need to diff vs production).
printf '%s\n' "$PROMPT_BODY" > "$OUT_DIR/prompt-body.txt"

# Decide disallowedTools list the same way run-eval.sh does for mock mode.
DISALLOWED="Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Agent"
echo "disallowed:  $DISALLOWED"                          | tee -a "$OUT_DIR/log.txt"
echo                                                     | tee -a "$OUT_DIR/log.txt"

# CWD isolation, same as production (claude hashes cwd to find project memory).
ISO_CWD="$(mktemp -d -t claude-eval-iso-XXXX)"
echo "iso cwd:     $ISO_CWD"                             | tee -a "$OUT_DIR/log.txt"

# Pre-invocation checkpoint: stdout-redir target exists and is writable?
TRACE_FILE="$OUT_DIR/model-trace.txt"
STDERR_FILE="$OUT_DIR/model-stderr.txt"
: > "$TRACE_FILE"
: > "$STDERR_FILE"
ls -la "$TRACE_FILE" "$STDERR_FILE"                      | tee -a "$OUT_DIR/log.txt"

# Timing markers (epoch ms via date).
T_BEFORE_MS="$(date +%s%3N)"
echo "start_epoch_ms: $T_BEFORE_MS"                      | tee -a "$OUT_DIR/log.txt"

# Run with the EXACT same redir shape as production. Also `tee` stdout so
# we can see in real-time what's coming out, even if the destination ends
# up empty.
#
# Production line:
#   printf '%s\n' "$prompt_body" \
#     | claude --print --system-prompt "$sys_prompt" --model "$MODEL" \
#         --output-format text --no-session-persistence \
#         --disallowedTools "$disallowed" \
#     > "$out_dir/model-trace.txt" 2> "$out_dir/model-stderr.txt"
#
# Instrumented version: pipe stdout through `tee` to also write to a
# `.live` file we can `wc -c` mid-stream (although bash can't easily
# observe mid-stream without backgrounding; we capture the post-mortem
# bytes via the same shape).

set +e
(
  cd "$ISO_CWD"
  printf '%s\n' "$PROMPT_BODY" \
    | claude --print \
        --system-prompt "$SYS_PROMPT" \
        --model "$MODEL" \
        --output-format text \
        --no-session-persistence \
        --disallowedTools "$DISALLOWED" \
    | tee "$TRACE_FILE" \
    > "$OUT_DIR/model-trace.via-tee.txt" 2>> "$STDERR_FILE"
)
PIPE_RC="${PIPESTATUS[*]:-unknown}"
RC=$?
set -e

T_AFTER_MS="$(date +%s%3N)"
WALL_MS=$((T_AFTER_MS - T_BEFORE_MS))

rm -rf "$ISO_CWD"

echo "end_epoch_ms:   $T_AFTER_MS"                       | tee -a "$OUT_DIR/log.txt"
echo "wall_ms:        $WALL_MS"                          | tee -a "$OUT_DIR/log.txt"
echo "rc:             $RC"                               | tee -a "$OUT_DIR/log.txt"
echo "pipestatus:     $PIPE_RC"                          | tee -a "$OUT_DIR/log.txt"
echo                                                     | tee -a "$OUT_DIR/log.txt"

echo "=== output sizes ==="                              | tee -a "$OUT_DIR/log.txt"
wc -c "$TRACE_FILE" "$OUT_DIR/model-trace.via-tee.txt" "$STDERR_FILE" \
                                                         | tee -a "$OUT_DIR/log.txt"
echo                                                     | tee -a "$OUT_DIR/log.txt"

echo "=== trace head (first 400 bytes) ==="              | tee -a "$OUT_DIR/log.txt"
head -c 400 "$TRACE_FILE"                                | tee -a "$OUT_DIR/log.txt"
echo                                                     | tee -a "$OUT_DIR/log.txt"

echo "=== trace od (first 64 bytes) ==="                 | tee -a "$OUT_DIR/log.txt"
head -c 64 "$TRACE_FILE" | od -c                         | tee -a "$OUT_DIR/log.txt"

echo                                                     | tee -a "$OUT_DIR/log.txt"
echo "=== stderr head ==="                               | tee -a "$OUT_DIR/log.txt"
head -c 1000 "$STDERR_FILE"                              | tee -a "$OUT_DIR/log.txt"

echo                                                     | tee -a "$OUT_DIR/log.txt"
echo "=== DONE ==="                                      | tee -a "$OUT_DIR/log.txt"
