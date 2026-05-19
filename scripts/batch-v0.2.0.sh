#!/usr/bin/env bash
# batch-v0.2.0.sh — run the full v0.2.0 battery (40 prompts) ×
# 2 system-prompt variants × N models. Captures outputs to
# results/v0.2.0/{prompt-id}__{variant}__{model}.txt
#
# Single-prompt model invocation uses the same cwd-isolated, no-tool
# pattern as batch-smoke.sh. Sandbox is NOT used here (this is the
# simulation-mode batch). Live-in-sandbox runs come through
# scripts/sandbox-bwrap.sh later.
#
# Usage:
#   scripts/batch-v0.2.0.sh [--parallel N] [--models "m1 m2 ..."]
#                           [--variants "v1 v2 ..."] [--limit N]
#                           [--only CATEGORY|PROMPT_ID]
#
# Defaults: --parallel 4, models = opus + sonnet,
#           variants = system-prompt.md + system-prompt-blind.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$REPO_ROOT/spec/v0.2.0-full-battery.md"
OUT_DIR="$REPO_ROOT/results/v0.2.0"

PARALLEL=4
MODELS=("claude-opus-4-7" "claude-sonnet-4-6")
VARIANTS=("system-prompt.md" "system-prompt-blind.md")
LIMIT=0
ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --parallel) PARALLEL="$2"; shift 2 ;;
        --models)   IFS=' ' read -ra MODELS <<<"$2"; shift 2 ;;
        --variants) IFS=' ' read -ra VARIANTS <<<"$2"; shift 2 ;;
        --limit)    LIMIT="$2"; shift 2 ;;
        --only)     ONLY="$2"; shift 2 ;;
        -h|--help)
            sed -n 's/^# \?//p' "$0" | sed -n '/^Usage:/,/^Defaults:/p'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

[ -f "$SPEC" ] || { echo "spec not found: $SPEC" >&2; exit 1; }
mkdir -p "$OUT_DIR"

invoke_one() {
    local prompt_json="$1"
    local variant_file="$2"
    local model="$3"

    local prompt_id axes body
    prompt_id="$(echo "$prompt_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['id'])")"
    axes="$(echo "$prompt_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['axes'])")"
    body="$(echo "$prompt_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['prompt'])")"
    local setup
    setup="$(echo "$prompt_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['setup'])")"

    local variant
    variant="$(basename "$variant_file" .md)"
    local out_path="$OUT_DIR/${prompt_id}__${variant}__${model}.txt"

    if [ -s "$out_path" ]; then
        echo "SKIP $prompt_id $variant $model"
        return 0
    fi

    local sys
    sys="$(cat "$REPO_ROOT/scripts/$variant_file")"

    # Build the user prompt: setup as session context, then the prompt body.
    local user_prompt
    user_prompt="$(printf 'Session setup (already applied):\n%s\n\nUser request:\n%s\n' "$setup" "$body")"

    local iso
    iso="$(mktemp -d -t claude-v020-XXXX)"
    (
        cd "$iso"
        timeout 180 claude --print \
            --system-prompt "$sys" \
            --model "$model" \
            --output-format text \
            --no-session-persistence \
            --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Agent" \
            -p "$user_prompt" \
            > "$out_path" 2> "${out_path%.txt}.stderr"
    )
    local rc=$?
    rm -rf "$iso"
    if [ $rc -ne 0 ]; then
        echo "FAIL($rc) $prompt_id $variant $model"
        return 1
    fi
    echo "OK    $prompt_id $variant $model"
}

export -f invoke_one
export REPO_ROOT OUT_DIR

# Build job list: prompt × variant × model.
JOBS="$(mktemp)"
trap 'rm -f "$JOBS"' EXIT

PROMPTS_JSON="$(python3 "$REPO_ROOT/scripts/parse-battery.py" "$SPEC")"
N=0
while IFS= read -r line; do
    N=$((N + 1))
    if [ "$LIMIT" -gt 0 ] && [ "$N" -gt "$LIMIT" ]; then break; fi
    if [ -n "$ONLY" ]; then
        pid="$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['id'])")"
        if [[ "$pid" != *"$ONLY"* ]]; then continue; fi
    fi
    for v in "${VARIANTS[@]}"; do
        for m in "${MODELS[@]}"; do
            printf '%s\t%s\t%s\n' "$line" "$v" "$m" >> "$JOBS"
        done
    done
done <<<"$PROMPTS_JSON"

TOTAL="$(wc -l < "$JOBS")"
echo "running $TOTAL invocations across $PARALLEL workers"
echo "models:   ${MODELS[*]}"
echo "variants: ${VARIANTS[*]}"
echo "output:   $OUT_DIR"
echo

cat "$JOBS" \
  | xargs -P "$PARALLEL" -d '\n' -I {} bash -c '
        IFS=$'\''\t'\'' read -r j v m <<< "{}"
        invoke_one "$j" "$v" "$m"
    '

echo
echo "batch complete. results in $OUT_DIR"
echo "next: scripts/score.py per output, record verdicts via pre-registration verdict"
