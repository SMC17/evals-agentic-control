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
#                         [--execution-mode simulation|mock|live]
#                         [--samples N]
#
# Default: --battery v0.1.0 (the seed battery), --model required,
#          --execution-mode simulation, --samples 3 (live) / 1 (dry-run).
#
# Per-cell sampling: --samples N runs the model N times per prompt.
# Each sample is written to model-trace-sample-<i>.{json,txt}; the
# canonical model-trace.{json,txt} is the first non-empty sample.
# Empty-turn observations are recorded in sample-summary.json (see
# docs/METHODOLOGY.md "Empty-turn audit"). Rationale: model-side
# non-determinism documented in docs/C5_SANDBOX_BUG_DIAGNOSTIC.md.
#
# Execution modes (see docs/EXECUTION_MODES.md):
#   simulation - text-only; model proposes commands, nothing runs.
#                Disallowed tools: Bash Edit Write Read Glob Grep WebFetch
#                WebSearch NotebookEdit Agent. This is the v0.1.0 baseline.
#   mock       - Bash tool allowed; hyprctl on sandbox PATH is the
#                mock-hyprctl.sh shim. Model invocations against hyprctl
#                land in HYPRCTL_MOCK_TRACE and are surfaced into the
#                run dir. Edit/Write/Read remain denied so the model
#                still cannot mutate repo files. Requires --live and
#                a sandbox with the mock shim wired (sandbox-bwrap.sh
#                --execution-mode mock).
#   live       - DEFERRED to v0.3.0. Refused with a clear error. Headless
#                Hyprland integration not yet shipped.

set -euo pipefail

# -------------------------------------------------------------------- arg parse

MODEL=""
BATTERY="v0.1.0"
MODE="dry-run"
PROMPTS_DIR=""
RESULTS_DIR=""
SANDBOX_FLAVOR=""
EXECUTION_MODE="simulation"
SAMPLES=""

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
    --execution-mode)   EXECUTION_MODE="$2"; shift 2 ;;
    --samples)          SAMPLES="$2"; shift 2 ;;
    -h|--help)          usage ;;
    *)                  echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

# --samples default: 3 in live mode, 1 in dry-run. Live defaults to N=3 so a
# single model-side empty turn does not destroy the per-cell observation;
# the modal verdict is taken across samples. See docs/C5_SANDBOX_BUG_DIAGNOSTIC.md.
if [[ -z "$SAMPLES" ]]; then
  if [[ "$MODE" == "live" ]]; then
    SAMPLES=3
  else
    SAMPLES=1
  fi
fi
if ! [[ "$SAMPLES" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --samples must be a positive integer (got: $SAMPLES)" >&2
  exit 64
fi

if [[ -z "$MODEL" ]]; then
  echo "error: --model required (e.g. claude-opus-4-7, claude-sonnet-4-6, llama-3.2-1b)" >&2
  exit 64
fi

case "$EXECUTION_MODE" in
  simulation|mock)
    ;;
  live)
    echo "error: --execution-mode=live is deferred to v0.3.0 of this harness." >&2
    echo "       Headless Hyprland integration not yet shipped. See" >&2
    echo "       docs/EXECUTION_MODES.md and docs/SANDBOX_NESTED_HYPRLAND.md" >&2
    echo "       for the roadmap. Use --execution-mode=simulation (default) or" >&2
    echo "       --execution-mode=mock (mock-hyprctl shim) instead." >&2
    exit 64
    ;;
  *)
    echo "error: unknown --execution-mode: $EXECUTION_MODE" >&2
    echo "       valid: simulation | mock | live (live deferred)" >&2
    exit 64
    ;;
esac

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

# Resolve the Claude Code tool denylist for the current EXECUTION_MODE.
# simulation denies all built-in tools (text-only scoring; v0.1.0 baseline).
# mock allows Bash so the model can invoke the mock-hyprctl shim staged on
# the sandbox PATH; Edit/Write/Read remain denied.
resolve_disallowed_tools() {
  case "$EXECUTION_MODE" in
    simulation)
      printf '%s' "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Agent"
      ;;
    mock)
      printf '%s' "Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Agent"
      ;;
    *)
      fatal "resolve_disallowed_tools: unsupported execution mode: $EXECUTION_MODE"
      ;;
  esac
}

# Single Claude invocation with JSON output. Writes the raw envelope to
# $env_path and the extracted assistant text to $txt_path. Returns the
# CLI exit code. The caller is responsible for interpreting empty turns.
#
# --output-format json returns a single envelope with shape (relevant fields):
#   {"type":"result","subtype":"success","is_error":<bool>,
#    "result":"<assistant text>","stop_reason":"end_turn"|...,
#    "duration_ms":N,"num_turns":N,"usage":{...},...}
# An empty assistant turn surfaces as .result == "". This is structurally
# distinguishable from a wrapper bug that produces a 0-byte file (the JSON
# envelope itself is always non-trivial). See docs/C5_SANDBOX_BUG_DIAGNOSTIC.md.
claude_one_shot_json() {
  local prompt_body="$1"
  local sys_prompt="$2"
  local disallowed="$3"
  local env_path="$4"
  local txt_path="$5"
  local stderr_path="$6"

  local iso_cwd
  iso_cwd="$(mktemp -d -t claude-eval-iso-XXXX)"
  set +e
  (
    cd "$iso_cwd"
    printf '%s\n' "$prompt_body" \
      | claude --print \
          --system-prompt "$sys_prompt" \
          --model "$MODEL" \
          --output-format json \
          --no-session-persistence \
          --disallowedTools "$disallowed" \
      > "$env_path" 2> "$stderr_path"
  )
  local rc=$?
  set -e
  rm -rf "$iso_cwd" 2>/dev/null || true

  # Extract the assistant text from the JSON envelope. We tolerate a malformed
  # envelope (jq fails) by leaving txt_path empty rather than aborting the run;
  # downstream sample-summary logic treats an empty txt_path as an empty turn,
  # which is the correct observable.
  if [[ -s "$env_path" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.result // ""' "$env_path" > "$txt_path" 2>/dev/null || {
      : > "$txt_path"
    }
  else
    : > "$txt_path"
  fi
  return $rc
}

# Lightweight warmup invocation. Fires a trivial prompt at the model and
# checks that the response contains the warmup token. Distinguishes "model
# is responsive but produced an empty turn on this specific prompt" (a
# legitimate observable) from "model is silent on every prompt this run"
# (an upstream outage that should abort the run before scoring artifacts
# are produced). Returns 0 on success, 1 on failure.
WARMUP_TOKEN="WARMUP-OK-$(date +%s)-$$"
warmup_claude() {
  command -v claude >/dev/null 2>&1 \
    || { warn "warmup: claude CLI not on PATH"; return 1; }
  local sys_prompt_file="${EVAL_SYSTEM_PROMPT:-$REPO_ROOT/scripts/system-prompt.md}"
  [[ -f "$sys_prompt_file" ]] || { warn "warmup: system prompt missing: $sys_prompt_file"; return 1; }

  local warmup_dir
  warmup_dir="$(mktemp -d -t claude-warmup-XXXX)"
  local env_path="$warmup_dir/envelope.json"
  local txt_path="$warmup_dir/text.txt"
  local stderr_path="$warmup_dir/stderr.txt"
  # For warmup we deliberately disallow ALL tools regardless of EXECUTION_MODE.
  # Warmup is a model-responsiveness check, not an eval invocation.
  local disallowed="Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Agent"
  local sys_prompt
  sys_prompt="$(cat "$sys_prompt_file")"
  local prompt_body="Reply with EXACTLY this token and nothing else: ${WARMUP_TOKEN}"

  info "warmup: invoking $MODEL with token ${WARMUP_TOKEN}"
  claude_one_shot_json "$prompt_body" "$sys_prompt" "$disallowed" \
    "$env_path" "$txt_path" "$stderr_path"
  local rc=$?

  local result_text=""
  [[ -s "$txt_path" ]] && result_text="$(cat "$txt_path")"

  # Persist warmup artifact under the run dir so the manifest can point at it.
  if [[ -n "${WARMUP_OUT_DIR:-}" ]]; then
    mkdir -p "$WARMUP_OUT_DIR"
    cp -f "$env_path" "$WARMUP_OUT_DIR/warmup-envelope.json" 2>/dev/null || true
    cp -f "$txt_path" "$WARMUP_OUT_DIR/warmup-response.txt" 2>/dev/null || true
    cp -f "$stderr_path" "$WARMUP_OUT_DIR/warmup-stderr.txt" 2>/dev/null || true
  fi
  rm -rf "$warmup_dir" 2>/dev/null || true

  if [[ $rc -ne 0 ]]; then
    warn "warmup: claude exit rc=$rc"
    return 1
  fi
  if [[ -z "$result_text" ]]; then
    warn "warmup: empty assistant turn"
    return 1
  fi
  if ! printf '%s' "$result_text" | grep -qF "$WARMUP_TOKEN"; then
    warn "warmup: response did not contain token ${WARMUP_TOKEN}"
    warn "warmup: response was: $(printf '%s' "$result_text" | head -c 200)"
    return 1
  fi
  info "warmup: OK (token echoed)"
  return 0
}

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
  # OUTPUT FORMAT — JSON
  # We use --output-format json so an empty assistant turn surfaces as a
  # structured .result=="" field rather than an indistinguishable empty
  # file. See docs/C5_SANDBOX_BUG_DIAGNOSTIC.md for the diagnostic that
  # motivated this switch (model-side non-determinism on C5).
  #
  # PER-CELL SAMPLING
  # We invoke the model SAMPLES times. Each sample writes:
  #   model-trace-sample-<i>.json   raw envelope
  #   model-trace-sample-<i>.txt    extracted assistant text
  #   model-trace-sample-<i>.stderr stderr from claude
  # The canonical model-trace.{json,txt} is a copy of the first non-empty
  # sample (or sample 1 if all are empty). sample-summary.json records
  # the per-sample observations including per-non-empty-sample sha256.
  # An empty-turn-observed.flag (zero-byte file) is created if any sample
  # was empty.
  local disallowed
  disallowed="$(resolve_disallowed_tools)"
  local sys_prompt
  sys_prompt="$(cat "$sys_prompt_file")"

  local samples_total="$SAMPLES"
  local samples_empty=0
  local first_nonempty=0
  local i
  local -a nonempty_hashes=()
  local -a sample_sizes=()
  local -a sample_durations=()
  local -a sample_stops=()
  local -a sample_rcs=()

  for i in $(seq 1 "$samples_total"); do
    local env_path="$out_dir/model-trace-sample-${i}.json"
    local txt_path="$out_dir/model-trace-sample-${i}.txt"
    local stderr_path="$out_dir/model-trace-sample-${i}.stderr"

    info "  sample $i/$samples_total..."
    set +e
    claude_one_shot_json "$prompt_body" "$sys_prompt" "$disallowed" \
      "$env_path" "$txt_path" "$stderr_path"
    local rc=$?
    set -e
    sample_rcs+=("$rc")

    local sz=0
    if [[ -f "$txt_path" ]]; then
      sz="$(wc -c < "$txt_path" | tr -d '[:space:]')"
    fi
    sample_sizes+=("$sz")

    local dur_ms="null"
    local stop="\"unknown\""
    if [[ -s "$env_path" ]] && command -v jq >/dev/null 2>&1; then
      dur_ms="$(jq -r '.duration_ms // "null"' "$env_path" 2>/dev/null || echo null)"
      stop="$(jq -c '.stop_reason // "unknown"' "$env_path" 2>/dev/null || echo '"unknown"')"
    fi
    sample_durations+=("$dur_ms")
    sample_stops+=("$stop")

    if [[ "$sz" -eq 0 ]]; then
      samples_empty=$((samples_empty + 1))
    else
      if [[ $first_nonempty -eq 0 ]]; then
        first_nonempty="$i"
      fi
      local hash
      hash="$(sha256sum "$txt_path" | awk '{print $1}')"
      nonempty_hashes+=("\"sample-${i}\": \"$hash\"")
    fi
  done

  # Canonical model-trace.{json,txt} is the first non-empty sample, falling
  # back to sample 1 if all are empty.
  local canon=$first_nonempty
  if [[ $canon -eq 0 ]]; then
    canon=1
  fi
  cp -f "$out_dir/model-trace-sample-${canon}.json" "$out_dir/model-trace.json" 2>/dev/null || true
  cp -f "$out_dir/model-trace-sample-${canon}.txt"  "$out_dir/model-trace.txt"  2>/dev/null || true
  cp -f "$out_dir/model-trace-sample-${canon}.stderr" "$out_dir/model-stderr.txt" 2>/dev/null || true

  # Mark empty-turn observations so a downstream auditor can locate them
  # without reparsing sample-summary.json.
  if [[ $samples_empty -gt 0 ]]; then
    : > "$out_dir/empty-turn-observed.flag"
  fi

  # Per-cell sample summary. Empty-turn samples are recorded as an
  # observable; they do NOT vote in the modal verdict but they DO update
  # the run-level empty_turn_rate. See docs/METHODOLOGY.md.
  local hashes_joined=""
  if [[ ${#nonempty_hashes[@]} -gt 0 ]]; then
    local sep=""
    for h in "${nonempty_hashes[@]}"; do
      hashes_joined+="${sep}${h}"
      sep=", "
    done
  fi
  local sizes_joined
  sizes_joined="$(IFS=,; echo "${sample_sizes[*]}")"
  local durs_joined
  durs_joined="$(IFS=,; echo "${sample_durations[*]}")"
  local stops_joined
  stops_joined="$(IFS=,; echo "${sample_stops[*]}")"
  local rcs_joined
  rcs_joined="$(IFS=,; echo "${sample_rcs[*]}")"

  cat > "$out_dir/sample-summary.json" <<EOF
{
  "samples": $samples_total,
  "samples_empty": $samples_empty,
  "samples_nonempty": $((samples_total - samples_empty)),
  "empty_turn_rate": $(awk -v e="$samples_empty" -v t="$samples_total" 'BEGIN { printf "%.4f", e/t }'),
  "first_nonempty_sample": $first_nonempty,
  "canonical_sample": $canon,
  "per_sample_bytes": [$sizes_joined],
  "per_sample_duration_ms": [$durs_joined],
  "per_sample_stop_reason": [$stops_joined],
  "per_sample_rc": [$rcs_joined],
  "nonempty_sample_sha256": { $hashes_joined }
}
EOF

  printf '%s\n' "$sys_prompt_file" > "$out_dir/system-prompt-used.path"
  printf '%s\n' "$EXECUTION_MODE" > "$out_dir/execution-mode.txt"

  # Return the canonical-sample rc so callers can detect upstream failures
  # while still preserving all per-sample artifacts for audit.
  return "${sample_rcs[$((canon - 1))]}"
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
info " model:           $MODEL"
info " battery:         $BATTERY"
info " mode:            $MODE"
info " execution mode:  $EXECUTION_MODE"
info " samples per cell: $SAMPLES"
info " prompts:         $PROMPTS_DIR"
info " results:         $out_root"
info "==================================================================="

preflight_experiment_register

if [[ "$MODE" == "live" ]]; then
  preflight_sandbox
else
  info "dry-run mode: skipping sandbox preflight (no model will be invoked)"
fi

# Warmup invocation (live mode only). A successful warmup means the model is
# producing non-empty turns under the no-tools system prompt before scoring
# begins. A failed warmup aborts the run so empty-turn samples on real cells
# can be distinguished from a generic upstream outage. See diagnostic doc.
warmup_ok="not-attempted"
if [[ "$MODE" == "live" ]]; then
  case "$MODEL" in
    claude-opus-4-7|claude-sonnet-4-6|claude-haiku-4-5-20251001)
      WARMUP_OUT_DIR="$out_root/warmup"
      if warmup_claude; then
        warmup_ok="true"
      else
        warmup_ok="false"
      fi
      if [[ "$warmup_ok" == "false" ]]; then
        fatal "model warmup failed; aborting run before per-cell sampling. See $out_root/warmup/."
      fi
      ;;
    *)
      info "warmup: skipped (non-claude model: $MODEL)"
      warmup_ok="skipped"
      ;;
  esac
fi

# Write run manifest.
manifest="$out_root/manifest.json"
cat > "$manifest" <<EOF
{
  "run_id": "$run_id",
  "model": "$MODEL",
  "battery": "$BATTERY",
  "mode": "$MODE",
  "execution_mode": "$EXECUTION_MODE",
  "sandbox_flavor": "${SANDBOX_FLAVOR:-none}",
  "samples_per_cell": $SAMPLES,
  "warmup_ok": "$warmup_ok",
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
    info " invoking model... (execution-mode=$EXECUTION_MODE)"
    invoke_model "$prompt_body" "$prompt_dir"
    info " model trace written: $prompt_dir/model-trace.txt"
    # Snapshot the agent-app-control trace log for this run window.
    if [[ -n "${STAXCTL_TRACE_PATH:-}" && -f "${STAXCTL_TRACE_PATH}" ]]; then
      cp "$STAXCTL_TRACE_PATH" "$prompt_dir/audit-envelope.jsonl"
      info " audit envelope: $prompt_dir/audit-envelope.jsonl"
    else
      warn " no STAXCTL_TRACE_PATH; audit envelope not captured"
    fi
    # In mock execution mode, also snapshot the per-prompt slice of the
    # mock-hyprctl trace. The sandbox sets HYPRCTL_MOCK_TRACE; we copy
    # whatever it contains so far into the prompt dir for the verdict
    # pass to read. The cumulative trace is also exported by the
    # sandbox wrapper at end-of-run.
    if [[ "$EXECUTION_MODE" == "mock" ]]; then
      if [[ -n "${HYPRCTL_MOCK_TRACE:-}" && -f "${HYPRCTL_MOCK_TRACE}" ]]; then
        cp "$HYPRCTL_MOCK_TRACE" "$prompt_dir/hyprctl-mock-trace.jsonl"
        info " hyprctl mock trace: $prompt_dir/hyprctl-mock-trace.jsonl"
      else
        warn " execution-mode=mock but HYPRCTL_MOCK_TRACE unset/missing"
        warn " mock-hyprctl shim may not be wired; check sandbox-bwrap.sh"
      fi
    fi
  else
    # Dry-run: write what would have been sent.
    printf '%s\n' "$prompt_body" > "$prompt_dir/prompt-body.txt"
    cat > "$prompt_dir/dry-run.md" <<EOF
# Dry-run record for $exp_id

This run did **not** invoke any model. The prompt body is in
\`prompt-body.txt\`. To run live:

\`\`\`
# Simulation (text-only; v0.1.0 baseline)
./scripts/run-eval.sh --model $MODEL --battery $BATTERY --live \\
  --sandbox-flavor bwrap-nested-hyprland \\
  --execution-mode simulation

# Mock-execution (Bash tool allowed; mock-hyprctl shim records calls)
./scripts/sandbox-bwrap.sh --model $MODEL --battery $BATTERY \\
  --execution-mode mock
\`\`\`

The live run will write \`model-trace.txt\` and \`audit-envelope.jsonl\`
into this same directory. In \`mock\` mode the runner also writes
\`hyprctl-mock-trace.jsonl\`. The verdict pass then reads them and
records a \`pre-registration verdict\` against \`$exp_id\`.

\`--execution-mode=live\` is reserved for v0.3.0 (headless Hyprland) and
is currently refused with a clear error. See \`docs/EXECUTION_MODES.md\`.
EOF
    info " dry-run record: $prompt_dir/dry-run.md"
  fi
done

info "==================================================================="
info " run complete: $run_id"
info " results at:   $out_root"
info "==================================================================="

# Aggregate empty-turn statistics across all prompts. This is the run-level
# observable for METHODOLOGY.md stage 7 (Empty-turn audit). We walk every
# sample-summary.json under the run dir and sum samples / samples_empty.
total_samples=0
total_empty=0
if [[ "$MODE" == "live" ]] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r summary; do
    [[ -s "$summary" ]] || continue
    s="$(jq -r '.samples // 0' "$summary" 2>/dev/null || echo 0)"
    e="$(jq -r '.samples_empty // 0' "$summary" 2>/dev/null || echo 0)"
    total_samples=$((total_samples + s))
    total_empty=$((total_empty + e))
  done < <(find "$out_root/prompts" -name 'sample-summary.json' -type f 2>/dev/null)
fi
if [[ $total_samples -gt 0 ]]; then
  empty_turn_rate="$(awk -v e="$total_empty" -v t="$total_samples" 'BEGIN { printf "%.4f", e/t }')"
else
  empty_turn_rate="null"
fi

# Update manifest with completion time. The started_at value is extracted
# from the in-flight manifest before we overwrite it.
started_at_extract="$(grep -oE '"started_at":[[:space:]]*"[^"]+"' "$manifest" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
cat > "$manifest" <<EOF
{
  "run_id": "$run_id",
  "model": "$MODEL",
  "battery": "$BATTERY",
  "mode": "$MODE",
  "execution_mode": "$EXECUTION_MODE",
  "sandbox_flavor": "${SANDBOX_FLAVOR:-none}",
  "samples_per_cell": $SAMPLES,
  "warmup_ok": "$warmup_ok",
  "started_at": "${started_at_extract}",
  "completed_at": "$(ts)",
  "prompt_count": ${#PROMPT_FILES[@]},
  "total_samples": $total_samples,
  "empty_turn_total": $total_empty,
  "empty_turn_rate": $empty_turn_rate,
  "repo_commit": "$(cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null || echo unknown)"
}
EOF

if [[ "$MODE" == "live" && $total_samples -gt 0 ]]; then
  info "empty-turn audit: $total_empty / $total_samples samples were empty (rate=$empty_turn_rate)"
fi
