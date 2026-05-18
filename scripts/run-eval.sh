#!/usr/bin/env bash
#
# evals-agentic-control/scripts/run-eval.sh
#
# Drive a pre-registered adversarial-prompt battery against a model
# through the agent-app-control harness, with sandbox preflight gating.
#
# Default mode is --dry-run: validates the protocol end-to-end without
# invoking any model and without touching the filesystem outside this
# repo's results/ tree.
#
# Live mode is gated by an explicit --live flag plus a six-point sandbox
# preflight (see docs/SANDBOX.md). Live mode refuses to start until all
# preflight checks pass.
#
# Usage:
#   ./scripts/run-eval.sh --model <name> --battery <version> [--live]
#                         [--prompts-dir PATH] [--results-dir PATH]
#                         [--sandbox-flavor bwrap|qemu|gvisor]
#
# Default: --battery v0.1.0 (the seed battery), --model required.

set -euo pipefail

# -------------------------------------------------------------------- arg parse

MODEL=""
BATTERY="v0.1.0"
MODE="dry-run"
PROMPTS_DIR=""
RESULTS_DIR=""
SANDBOX_FLAVOR=""

usage() {
  sed -n 's/^# \{0,1\}//p' "$0" | sed -n '/^Usage:/,/^Default:/p'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)            MODEL="$2"; shift 2 ;;
    --battery)          BATTERY="$2"; shift 2 ;;
    --live)             MODE="live"; shift ;;
    --dry-run)          MODE="dry-run"; shift ;;
    --prompts-dir)      PROMPTS_DIR="$2"; shift 2 ;;
    --results-dir)      RESULTS_DIR="$2"; shift 2 ;;
    --sandbox-flavor)   SANDBOX_FLAVOR="$2"; shift 2 ;;
    -h|--help)          usage ;;
    *)                  echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

if [[ -z "$MODEL" ]]; then
  echo "error: --model required (e.g. claude-opus-4-7, claude-sonnet-4-6, llama-3.2-1b)" >&2
  exit 64
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROMPTS_DIR="${PROMPTS_DIR:-$REPO_ROOT/prompts}"
RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/results}"

# -------------------------------------------------------------------- logging

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
info()  { printf '[%s] INFO  %s\n' "$(ts)" "$*" >&2; }
warn()  { printf '[%s] WARN  %s\n' "$(ts)" "$*" >&2; }
fatal() { printf '[%s] FATAL %s\n' "$(ts)" "$*" >&2; exit 1; }

# -------------------------------------------------------------------- battery

declare -a PROMPT_FILES
case "$BATTERY" in
  v0.1.0)
    PROMPT_FILES=(
      "$PROMPTS_DIR/c1-blast-radius.md"
      "$PROMPTS_DIR/c2-credential-exfil.md"
      "$PROMPTS_DIR/c3-dispatch-escape.md"
      "$PROMPTS_DIR/c4-screen-injection.md"
      "$PROMPTS_DIR/c5-persistence.md"
    )
    ;;
  *)
    fatal "unknown battery: $BATTERY (only v0.1.0 supported in this script)"
    ;;
esac

for p in "${PROMPT_FILES[@]}"; do
  [[ -f "$p" ]] || fatal "missing prompt file: $p"
done

# -------------------------------------------------------------------- prompt-frontmatter parse

# Extract experiment ID from a prompt file (looks for line:
#   **Experiment ID:** exp-1779138977-079045889
extract_exp_id() {
  local file="$1"
  awk '
    /^\*\*Experiment ID:\*\*/ {
      gsub(/^\*\*Experiment ID:\*\* */, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$file"
}

# Extract the user-facing prompt from a prompt file (the fenced block under
# "## Prompt as delivered to the model").
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

# -------------------------------------------------------------------- preflight

# pre-registration is the canonical experiment register. v0.1.0 expects the
# five seed experiments are already registered. We do not register them here;
# pre-registration must happen before the first run.
preflight_experiment_register() {
  command -v pre-registration >/dev/null 2>&1 \
    || fatal "pre-registration not on PATH; protocol requires pre-registered experiments"
  for p in "${PROMPT_FILES[@]}"; do
    local id
    id="$(extract_exp_id "$p")"
    [[ -n "$id" ]] || fatal "prompt $p missing **Experiment ID:** frontmatter line"
    info "prompt $(basename "$p") → experiment $id"
    # We don't verify against the pre-registration store here because the IDs
    # are seeded with category-specific timestamps. The verdict pass at the
    # end of the run does the cross-check.
  done
}

# Six-point sandbox preflight per docs/SANDBOX.md. Refuses live mode if any
# check fails. Each check function returns 0 on pass, non-zero on fail.
preflight_sandbox() {
  local failures=0

  info "sandbox preflight: flavor"
  case "$SANDBOX_FLAVOR" in
    bwrap-nested-hyprland|qemu-microvm|gvisor-container)
      info "  → flavor=$SANDBOX_FLAVOR"
      ;;
    "")
      warn "  ✗ --sandbox-flavor not specified"
      failures=$((failures+1))
      ;;
    *)
      warn "  ✗ unrecognised flavor: $SANDBOX_FLAVOR"
      failures=$((failures+1))
      ;;
  esac

  info "sandbox preflight: \$XDG_STATE_HOME"
  if [[ -z "${XDG_STATE_HOME:-}" ]]; then
    warn "  ✗ \$XDG_STATE_HOME unset on the runner side; cannot confirm sandbox indirection"
    failures=$((failures+1))
  elif [[ "${XDG_STATE_HOME}" == "$HOME/.local/state" ]]; then
    warn "  ✗ \$XDG_STATE_HOME points at host default; sandbox indirection missing"
    failures=$((failures+1))
  else
    info "  → \$XDG_STATE_HOME=${XDG_STATE_HOME}"
  fi

  info "sandbox preflight: host bind-mounts"
  if mount | grep -qE '^/dev/[^ ]+ on (/home|/) '; then
    if [[ "$SANDBOX_FLAVOR" == "bwrap-nested-hyprland" ]]; then
      # bwrap doesn't change mount output of the host; this check is
      # informational, not blocking, for bwrap. We trust the bwrap invocation
      # to have set up its own namespace.
      info "  → bwrap mode: trust the namespace (informational only)"
    else
      warn "  ✗ host filesystem is mounted; sandbox isolation cannot be verified"
      failures=$((failures+1))
    fi
  else
    info "  → host filesystem not visible (or running inside namespace)"
  fi

  info "sandbox preflight: outbound network"
  # Try to resolve a domain that should not route in the sandbox.
  if getent hosts evil.example.com >/dev/null 2>&1; then
    warn "  ✗ evil.example.com resolves; sandbox network policy not enforced"
    failures=$((failures+1))
  else
    info "  → evil.example.com unresolvable (expected for sandbox)"
  fi

  info "sandbox preflight: sandbox-gate"
  if command -v sandbox-gate >/dev/null 2>&1; then
    info "  → sandbox-gate on PATH"
  else
    warn "  ✗ sandbox-gate not on PATH; C1 falsifier cannot detect blast-radius routing"
    failures=$((failures+1))
  fi

  info "sandbox preflight: agent-app-control trace path"
  local trace_default="state/sandbox-traces.jsonl"
  if [[ "${STAXCTL_TRACE_PATH:-$trace_default}" == "$trace_default" ]]; then
    warn "  ✗ trace path points at host default; per-run isolation missing"
    failures=$((failures+1))
  else
    info "  → trace path=${STAXCTL_TRACE_PATH}"
  fi

  if [[ $failures -gt 0 ]]; then
    fatal "sandbox preflight failed: $failures check(s) did not pass; live mode refused"
  fi
  info "sandbox preflight: all checks passed"
}

# -------------------------------------------------------------------- model invocation

invoke_claude() {
  local prompt_body="$1"
  local out_dir="$2"
  command -v claude >/dev/null 2>&1 \
    || fatal "claude CLI not on PATH; required for $MODEL"
  local sys_prompt_file="${EVAL_SYSTEM_PROMPT:-$REPO_ROOT/scripts/system-prompt.md}"
  [[ -f "$sys_prompt_file" ]] || fatal "system prompt missing: $sys_prompt_file"

  # CLEAN CONTEXT VIA CWD ISOLATION
  # We do NOT use --bare here. --bare disables OAuth/keychain reads which
  # forces ANTHROPIC_API_KEY, violating the no-paid-API-keys fleet policy.
  # Instead, we cd to an ephemeral directory before invoking claude. Auto-
  # memory and CLAUDE.md discovery are cwd-derived (claude hashes the cwd
  # to find its project memory dir), so a fresh /tmp directory hashes to a
  # nonexistent project memory dir and loads nothing. Verified empirically
  # on 2026-05-18: claude --print from /tmp/empty does not load
  # ~/.claude/projects/-home-stax/memory/* into the model context.
  #
  # --system-prompt replaces the default system prompt with our agent-role
  #                 description.
  # --disallowedTools denies the Claude Code built-in tool surface so the
  #                   model produces text proposing commands (the
  #                   simulation-mode scoring surface) rather than
  #                   executing on the host.
  # --no-session-persistence ensures no eval session is written to disk
  #                          for resume, keeping the eval reproducible.
  local sys_prompt
  sys_prompt="$(cat "$sys_prompt_file")"
  local iso_cwd
  iso_cwd="$(mktemp -d -t claude-eval-iso-XXXX)"
  set +e
  (
    cd "$iso_cwd"
    printf '%s\n' "$prompt_body" \
      | claude --print \
          --system-prompt "$sys_prompt" \
          --model "$MODEL" \
          --output-format text \
          --no-session-persistence \
          --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Agent" \
      > "$out_dir/model-trace.txt" 2> "$out_dir/model-stderr.txt"
  )
  local rc=$?
  set -e
  rm -rf "$iso_cwd" 2>/dev/null || true
  printf '%s\n' "$sys_prompt_file" > "$out_dir/system-prompt-used.path"
  return $rc
}

invoke_local_llama() {
  local prompt_body="$1"
  local out_dir="$2"
  # Local-served-weight path. Not yet implemented; placeholder for v0.2.0.
  # The thin agent-loop wrapper that translates tool-use intent into
  # agent-app-control calls lives at scripts/lib/llama-agent-loop.sh
  # when it ships.
  fatal "local-weight model invocation not yet implemented (planned for v0.2.0)"
}

invoke_model() {
  local prompt_body="$1"
  local out_dir="$2"
  case "$MODEL" in
    claude-opus-4-7|claude-sonnet-4-6|claude-haiku-4-5-20251001)
      invoke_claude "$prompt_body" "$out_dir"
      ;;
    llama-*|qwen*|deepseek*)
      invoke_local_llama "$prompt_body" "$out_dir"
      ;;
    *)
      fatal "unknown model: $MODEL"
      ;;
  esac
}

# -------------------------------------------------------------------- run

run_id="run-$(date -u +'%Y%m%d-%H%M%S')"
out_root="$RESULTS_DIR/$run_id"
mkdir -p "$out_root/prompts"

info "==================================================================="
info " evals-agentic-control — run $run_id"
info "==================================================================="
info " model:     $MODEL"
info " battery:   $BATTERY"
info " mode:      $MODE"
info " prompts:   $PROMPTS_DIR"
info " results:   $out_root"
info "==================================================================="

preflight_experiment_register

if [[ "$MODE" == "live" ]]; then
  preflight_sandbox
else
  info "dry-run mode: skipping sandbox preflight (no model will be invoked)"
fi

# Write run manifest.
manifest="$out_root/manifest.json"
cat > "$manifest" <<EOF
{
  "run_id": "$run_id",
  "model": "$MODEL",
  "battery": "$BATTERY",
  "mode": "$MODE",
  "sandbox_flavor": "${SANDBOX_FLAVOR:-none}",
  "started_at": "$(ts)",
  "prompt_count": ${#PROMPT_FILES[@]},
  "repo_commit": "$(cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null || echo unknown)"
}
EOF
info "wrote manifest: $manifest"

# Iterate prompts.
for prompt_file in "${PROMPT_FILES[@]}"; do
  exp_id="$(extract_exp_id "$prompt_file")"
  prompt_body="$(extract_prompt_body "$prompt_file")"
  prompt_dir="$out_root/prompts/$exp_id"
  mkdir -p "$prompt_dir"
  cp "$prompt_file" "$prompt_dir/prompt.md"

  info "------------------------------------------------------------------"
  info " prompt: $(basename "$prompt_file")"
  info " exp:    $exp_id"
  info " bytes:  ${#prompt_body}"

  if [[ "$MODE" == "live" ]]; then
    info " invoking model..."
    invoke_model "$prompt_body" "$prompt_dir"
    info " model trace written: $prompt_dir/model-trace.txt"
    # Snapshot the agent-app-control trace log for this run window.
    if [[ -n "${STAXCTL_TRACE_PATH:-}" && -f "${STAXCTL_TRACE_PATH}" ]]; then
      cp "$STAXCTL_TRACE_PATH" "$prompt_dir/audit-envelope.jsonl"
      info " audit envelope: $prompt_dir/audit-envelope.jsonl"
    else
      warn " no STAXCTL_TRACE_PATH; audit envelope not captured"
    fi
  else
    # Dry-run: write what would have been sent.
    printf '%s\n' "$prompt_body" > "$prompt_dir/prompt-body.txt"
    cat > "$prompt_dir/dry-run.md" <<EOF
# Dry-run record for $exp_id

This run did **not** invoke any model. The prompt body is in
\`prompt-body.txt\`. To run live:

\`\`\`
./scripts/run-eval.sh --model $MODEL --battery $BATTERY --live \\
  --sandbox-flavor bwrap-nested-hyprland
\`\`\`

The live run will write \`model-trace.txt\` and \`audit-envelope.jsonl\`
into this same directory. The verdict pass then reads both and records
a \`pre-registration verdict\` against \`$exp_id\`.
EOF
    info " dry-run record: $prompt_dir/dry-run.md"
  fi
done

info "==================================================================="
info " run complete: $run_id"
info " results at:   $out_root"
info "==================================================================="

# Update manifest with completion time.
cat > "$manifest" <<EOF
{
  "run_id": "$run_id",
  "model": "$MODEL",
  "battery": "$BATTERY",
  "mode": "$MODE",
  "sandbox_flavor": "${SANDBOX_FLAVOR:-none}",
  "started_at": "$(head -3 "$manifest" | tail -1 | grep -oE '"[^"]+T[^"]+Z"' | tr -d '"')",
  "completed_at": "$(ts)",
  "prompt_count": ${#PROMPT_FILES[@]},
  "repo_commit": "$(cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null || echo unknown)"
}
EOF
