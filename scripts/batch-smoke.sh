#!/usr/bin/env bash
# batch-smoke.sh — run all 5 v0.1.0 prompts × 2 system-prompt variants
# × all listed models in parallel. Captures outputs to results/smoke/.
#
# Each invocation runs the same clean-context path as the runner's
# invoke_claude (cwd-isolated, custom system prompt, tool surface denied).
# Sandbox is NOT used here — this is a smoke batch, not a production
# run. Live-in-sandbox runs come through scripts/sandbox-bwrap.sh later.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE_DIR="$REPO_ROOT/results/smoke"
mkdir -p "$SMOKE_DIR"

PROMPT_FILES=(
    "$REPO_ROOT/prompts/c1-blast-radius.md"
    "$REPO_ROOT/prompts/c2-credential-exfil.md"
    "$REPO_ROOT/prompts/c3-dispatch-escape.md"
    "$REPO_ROOT/prompts/c4-screen-injection.md"
    "$REPO_ROOT/prompts/c5-persistence.md"
)
VARIANTS=("system-prompt.md" "system-prompt-blind.md")
MODELS=("claude-opus-4-7" "claude-sonnet-4-6")

extract_prompt_body() {
    awk '
        /^## Prompt as delivered to the model/ {flag=1; next}
        flag && /^```/ { if (!opened) {opened=1; next} else exit }
        flag && opened { print }
    ' "$1"
}

invoke_one() {
    local prompt_file="$1"
    local variant_file="$2"
    local model="$3"

    local prompt_id
    prompt_id="$(basename "$prompt_file" .md)"
    local variant
    variant="$(basename "$variant_file" .md)"
    local out_path="$SMOKE_DIR/${prompt_id}__${variant}__${model}.txt"

    if [ -s "$out_path" ]; then
        echo "SKIP (already exists): $out_path"
        return 0
    fi

    local body
    body="$(extract_prompt_body "$prompt_file")"
    local sys
    sys="$(cat "$REPO_ROOT/scripts/$variant_file")"

    local iso
    iso="$(mktemp -d -t claude-batch-XXXX)"
    (
        cd "$iso"
        timeout 180 claude --print \
            --system-prompt "$sys" \
            --model "$model" \
            --output-format text \
            --no-session-persistence \
            --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Agent" \
            -p "$body" \
            > "$out_path" 2> "${out_path%.txt}.stderr"
    )
    local rc=$?
    rm -rf "$iso"
    if [ $rc -ne 0 ]; then
        echo "FAIL ($rc): $out_path"
        return 1
    fi
    echo "OK: $out_path"
}

export -f invoke_one extract_prompt_body
export REPO_ROOT SMOKE_DIR

# Build the job list (prompt × variant × model) and run in parallel.
JOBS_FILE="$(mktemp)"
for p in "${PROMPT_FILES[@]}"; do
    for v in "${VARIANTS[@]}"; do
        for m in "${MODELS[@]}"; do
            printf '%s\t%s\t%s\n' "$p" "$v" "$m"
        done
    done
done > "$JOBS_FILE"

TOTAL="$(wc -l < "$JOBS_FILE")"
echo "running $TOTAL invocations in parallel batches of 4..."

# Parallel execution. Each invocation is one tab-separated line.
cat "$JOBS_FILE" \
  | xargs -P 4 -I {} bash -c '
        IFS=$'\''\t'\'' read -r p v m <<< "{}"
        invoke_one "$p" "$v" "$m"
    '

rm -f "$JOBS_FILE"
echo "batch complete. results in $SMOKE_DIR"
