#!/usr/bin/env bash
# sandbox-bwrap.sh — launch a live eval run inside a bubblewrap namespace
# that satisfies the six preflight checks in run-eval.sh.
#
# Scope (v0.1.0):
#   - Redirects $XDG_STATE_HOME to a per-run tmpfs path so the eval cannot
#     mutate the host's real state directory.
#   - Redirects $STAXCTL_TRACE_PATH similarly.
#   - Unshares the network so adversarial network calls fail closed.
#   - Bind-mounts the repo read-write so the run writes results into
#     the eval repo's results/ tree (the only intended write target).
#   - All other host paths are mounted read-only or hidden entirely.
#
# Out of scope (v0.1.0):
#   - Nested Hyprland session inside the sandbox. Until that lands, prompts
#     whose falsifier requires an actual hyprctl dispatch (C3) will record
#     "model proposed dispatch X" in the trace but won't observe whether the
#     guard would have caught it. v0.3.0 plan: launch hyprland-headless
#     inside the bwrap namespace and patch agent-app-control's HYPRLAND_
#     env vars to point at it.
#   - Outbound network controls finer than "deny all." A "deny all but
#     api.anthropic.com:443" allowlist via a netns + nftables egress
#     filter is v0.2.0 work.
#
# Usage:
#   scripts/sandbox-bwrap.sh --model claude-opus-4-7 [--battery v0.1.0]
#                            [--keep-state] [--dry-run]
#                            [--execution-mode simulation|mock|live]
#
# Execution modes:
#   simulation - (default) v0.1.0 behaviour. Model invoked with all
#                Claude Code tools disallowed; produces text only.
#   mock       - v0.2.0. mock-hyprctl.sh is staged at the front of the
#                sandbox PATH as `hyprctl`; HYPRCTL_MOCK_TRACE points to
#                a per-run trace file. The model may invoke Bash and call
#                hyprctl; calls are recorded but no real compositor is
#                touched. After the inner run, the trace is copied into
#                results/run-*/.
#   live       - DEFERRED to v0.3.0. Refused with a clear error here and
#                inside the inner runner. Headless Hyprland integration
#                not yet shipped (see docs/SANDBOX_NESTED_HYPRLAND.md).
#
# Exit codes:
#   0  success
#   64 usage error
#   65 preflight failed (bwrap not available, repo not writable, etc.)
#   66 eval reported a non-zero exit inside the sandbox
#   67 execution-mode=live refused (deferred to v0.3.0)

set -euo pipefail

MODEL=""
BATTERY="v0.1.0"
KEEP_STATE=0
INNER_MODE="--live"
EXECUTION_MODE="simulation"

usage() {
    sed -n 's/^# \?//p' "$0" | sed -n '/^Usage:/,/^Exit codes:/p'
    exit 64
}

while [ $# -gt 0 ]; do
    case "$1" in
        --model)           MODEL="$2"; shift 2 ;;
        --battery)         BATTERY="$2"; shift 2 ;;
        --keep-state)      KEEP_STATE=1; shift ;;
        --dry-run)         INNER_MODE="--dry-run"; shift ;;
        --execution-mode)  EXECUTION_MODE="$2"; shift 2 ;;
        -h|--help)         usage ;;
        *)                 echo "unknown arg: $1" >&2; usage ;;
    esac
done

[ -n "$MODEL" ] || { echo "error: --model required" >&2; exit 64; }

case "$EXECUTION_MODE" in
    simulation|mock)
        ;;
    live)
        echo "error: --execution-mode=live is deferred to v0.3.0." >&2
        echo "       Headless Hyprland integration not yet shipped." >&2
        echo "       Use --execution-mode=simulation (default) or" >&2
        echo "       --execution-mode=mock. See docs/EXECUTION_MODES.md." >&2
        exit 67
        ;;
    *)
        echo "error: unknown --execution-mode: $EXECUTION_MODE" >&2
        echo "       valid: simulation | mock | live (live deferred)" >&2
        exit 64
        ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# -------------------------------------------------------------------- preflight (host-side)

if ! command -v bwrap >/dev/null 2>&1; then
    echo "error: bwrap not on PATH" >&2
    exit 65
fi

if [ ! -w "$REPO_ROOT/results" ]; then
    mkdir -p "$REPO_ROOT/results"
fi

# Per-run sandbox state directory. Lives under /tmp so it is destroyed
# at next reboot; we also clean it up at end unless --keep-state.
TS="$(date -u +%Y%m%d-%H%M%SZ)"
SANDBOX_DIR="$(mktemp -d -t "eval-sandbox-${TS}-XXXX")"
SANDBOX_STATE="$SANDBOX_DIR/state"
SANDBOX_TRACE="$SANDBOX_DIR/sandbox-traces.jsonl"
SANDBOX_HOME="$SANDBOX_DIR/home"
SANDBOX_BIN="$SANDBOX_DIR/bin"
SANDBOX_HYPRCTL_TRACE="$SANDBOX_DIR/hyprctl-mock.jsonl"
mkdir -p "$SANDBOX_STATE" "$SANDBOX_HOME" "$SANDBOX_BIN"
touch "$SANDBOX_TRACE"

# Stage mock-hyprctl as `hyprctl` on a sandbox-only bin directory if and
# only if the operator asked for execution-mode=mock. We copy rather than
# symlink so the sandbox doesn't need read access to the repo just to
# resolve a symlink target (the repo is bind-mounted, but the copy keeps
# the mock shim runnable even if the repo path layout changes later).
if [ "$EXECUTION_MODE" = "mock" ]; then
    if [ ! -x "$REPO_ROOT/scripts/mock-hyprctl.sh" ]; then
        echo "error: scripts/mock-hyprctl.sh missing or not executable" >&2
        exit 65
    fi
    cp "$REPO_ROOT/scripts/mock-hyprctl.sh" "$SANDBOX_BIN/hyprctl"
    chmod +x "$SANDBOX_BIN/hyprctl"
    touch "$SANDBOX_HYPRCTL_TRACE"
fi

cleanup() {
    if [ "$KEEP_STATE" -eq 0 ]; then
        rm -rf "$SANDBOX_DIR"
    else
        echo "sandbox state retained at: $SANDBOX_DIR" >&2
    fi
}
trap cleanup EXIT

echo "sandbox dir:    $SANDBOX_DIR"
echo "model:          $MODEL"
echo "battery:        $BATTERY"
echo "mode:           $INNER_MODE"
echo "execution mode: $EXECUTION_MODE"

# -------------------------------------------------------------------- claude location

CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || { echo "error: claude not on PATH" >&2; exit 65; }
CLAUDE_REAL="$(readlink -f "$CLAUDE_BIN")"
CLAUDE_DIR="$(dirname "$CLAUDE_REAL")"

# Discover the nix store paths claude needs. claude is a node script;
# we need node + the claude install dir on PATH inside the sandbox.
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || { echo "error: node not on PATH" >&2; exit 65; }
NODE_REAL="$(readlink -f "$NODE_BIN")"
NODE_DIR="$(dirname "$NODE_REAL")"

# Identify a writable XDG_RUNTIME_DIR-equivalent inside sandbox.
SANDBOX_XDG_RUNTIME="$SANDBOX_DIR/runtime"
mkdir -p "$SANDBOX_XDG_RUNTIME"
chmod 700 "$SANDBOX_XDG_RUNTIME"

# -------------------------------------------------------------------- bwrap invocation

# Build bwrap arg list. Read-only host mounts give us node, claude, and
# their nix-store dependencies; tmpfs at sandbox state/trace paths
# satisfies the preflight; --unshare-net denies outbound (preflight
# resolves evil.example.com to fail).
#
# In execution-mode=mock, $SANDBOX_BIN is mounted and prepended to PATH
# so any `hyprctl` invocation inside the sandbox resolves to the mock
# shim instead of /usr/bin/hyprctl (if one were present in the nix
# closure). The shim records argv+env to $SANDBOX_HYPRCTL_TRACE.
SANDBOX_PATH="$CLAUDE_DIR:$NODE_DIR:/usr/bin:/bin"
if [ "$EXECUTION_MODE" = "mock" ]; then
    SANDBOX_PATH="$SANDBOX_BIN:$SANDBOX_PATH"
fi

BWRAP_ARGS=(
    --unshare-pid
    --unshare-net
    --unshare-uts
    --unshare-ipc
    --die-with-parent
    --new-session
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --ro-bind /nix /nix
    --ro-bind /etc/resolv.conf /etc/resolv.conf
    --ro-bind /etc/ssl /etc/ssl
    --ro-bind /etc/static/ssl /etc/static/ssl
    --bind "$REPO_ROOT" "$REPO_ROOT"
    --bind "$SANDBOX_HOME" "$HOME"
    --bind "$SANDBOX_STATE" "$SANDBOX_STATE"
    --bind "$SANDBOX_TRACE" "$SANDBOX_TRACE"
    --bind "$SANDBOX_XDG_RUNTIME" "$SANDBOX_XDG_RUNTIME"
    --setenv HOME "$HOME"
    --setenv USER "$USER"
    --setenv PATH "$SANDBOX_PATH"
    --setenv XDG_STATE_HOME "$SANDBOX_STATE"
    --setenv XDG_RUNTIME_DIR "$SANDBOX_XDG_RUNTIME"
    --setenv STAXCTL_TRACE_PATH "$SANDBOX_TRACE"
    --setenv EVAL_SANDBOX "bwrap-v0.2.0"
    --setenv EVAL_EXECUTION_MODE "$EXECUTION_MODE"
    --chdir "$REPO_ROOT"
)

if [ "$EXECUTION_MODE" = "mock" ]; then
    # The mock-hyprctl shim and its trace file both need to be visible
    # and writable inside the sandbox at the same path as on the host.
    BWRAP_ARGS+=(
        --ro-bind "$SANDBOX_BIN" "$SANDBOX_BIN"
        --bind "$SANDBOX_HYPRCTL_TRACE" "$SANDBOX_HYPRCTL_TRACE"
        --setenv HYPRCTL_MOCK_TRACE "$SANDBOX_HYPRCTL_TRACE"
    )
fi

# Auth: claude needs to read the user's credentials. We bind-mount the
# claude config and auth dirs read-only. If the user's claude is API-keyed,
# ANTHROPIC_API_KEY must already be set in the environment; we propagate.
if [ -d "$HOME/.config/claude" ]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.config/claude" "$HOME/.config/claude")
fi
if [ -d "$HOME/.claude" ]; then
    # Only bind specific subdirs that claude needs; do NOT expose the
    # auto-memory directory (the whole point of this eval is to NOT
    # leak the host's memory into the model context).
    if [ -d "$HOME/.claude/credentials" ]; then
        BWRAP_ARGS+=(--ro-bind "$HOME/.claude/credentials" "$HOME/.claude/credentials")
    fi
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    BWRAP_ARGS+=(--setenv ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY")
fi

# We do NOT pass --setenv ANTHROPIC_API_KEY by default; per the
# no-paid-API-keys fleet policy, this eval uses subscription-auth claude.

echo
echo "host-side preflight passed; entering sandbox..."
echo

set +e
bwrap "${BWRAP_ARGS[@]}" \
    bash "$REPO_ROOT/scripts/run-eval.sh" \
        $INNER_MODE \
        --model "$MODEL" \
        --battery "$BATTERY" \
        --sandbox-flavor bwrap-nested-hyprland \
        --execution-mode "$EXECUTION_MODE"
INNER_EXIT="$?"
set -e

if [ "$INNER_EXIT" -ne 0 ]; then
    echo "eval reported exit $INNER_EXIT" >&2
    exit 66
fi

# Copy the captured trace out if the inner run wrote it.
LATEST_RUN="$(ls -td "$REPO_ROOT/results"/run-* 2>/dev/null | head -1 || true)"
if [ -s "$SANDBOX_TRACE" ] && [ -n "$LATEST_RUN" ]; then
    cp "$SANDBOX_TRACE" "$LATEST_RUN/sandbox-trace.jsonl"
    echo "sandbox trace saved: $LATEST_RUN/sandbox-trace.jsonl"
fi

# In mock execution mode, the cumulative hyprctl-mock trace is the
# canonical record of what the model attempted. Copy it out alongside
# the sandbox trace.
if [ "$EXECUTION_MODE" = "mock" ] && [ -n "$LATEST_RUN" ]; then
    if [ -s "$SANDBOX_HYPRCTL_TRACE" ]; then
        cp "$SANDBOX_HYPRCTL_TRACE" "$LATEST_RUN/hyprctl-mock-trace.jsonl"
        echo "hyprctl-mock trace saved: $LATEST_RUN/hyprctl-mock-trace.jsonl"
    else
        echo "execution-mode=mock: hyprctl-mock trace is empty"
        echo "  (model may not have invoked hyprctl; check model-trace.txt"
        echo "   under each prompt dir for what the model produced)"
    fi
fi

echo
echo "sandbox eval complete."
