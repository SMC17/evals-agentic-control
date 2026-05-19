#!/usr/bin/env bash
# debug-c5-sandbox-wrap.sh — thin bwrap wrapper that invokes
# debug-c5-single.sh inside the SAME sandbox shape used by
# sandbox-bwrap.sh, for a single prompt.
#
# Branch-only debugging tool. Not part of the production substrate.
#
# Why this file exists: sandbox-bwrap.sh hardcodes run-eval.sh as the
# inner command and iterates the full battery. We want to drive ONE
# prompt with instrumentation; the cleanest way is a sibling wrapper
# that copies the relevant bwrap arg-list and execs debug-c5-single.sh.
#
# This is intentionally a less-rigorous wrapper (no egress proxy by
# default; no mock-hyprctl). H4 (env-var diff) is the primary lens.
#
# Usage:
#   ./scripts/debug-c5-sandbox-wrap.sh <prompt-id> <out-dir>
#
# All token-spending invocations of `claude` happen inside; budget
# accordingly.

set -euo pipefail

PROMPT_ID="${1:-c5}"
OUT_DIR="${2:-/tmp/c5-debug-$$}"
WITH_PROXY="${3:-no}"   # "yes" to match production shape (--unshare-net + proxy)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT_DIR"

if ! command -v bwrap >/dev/null 2>&1; then
    echo "error: bwrap not on PATH" >&2
    exit 65
fi

TS="$(date -u +%Y%m%d-%H%M%SZ)"
SANDBOX_DIR="$(mktemp -d -t "c5-debug-sandbox-${TS}-XXXX")"
SANDBOX_STATE="$SANDBOX_DIR/state"
SANDBOX_TRACE="$SANDBOX_DIR/sandbox-traces.jsonl"
SANDBOX_HOME="$SANDBOX_DIR/home"
SANDBOX_XDG_RUNTIME="$SANDBOX_DIR/runtime"
SANDBOX_PROXY_SOCK="$SANDBOX_DIR/egress-proxy.sock"
SANDBOX_PROXY_LOG="$SANDBOX_DIR/egress-proxy.log"
mkdir -p "$SANDBOX_STATE" "$SANDBOX_HOME" "$SANDBOX_XDG_RUNTIME"
chmod 700 "$SANDBOX_XDG_RUNTIME"
touch "$SANDBOX_TRACE"

PROXY_PID=""
cleanup() {
    if [ -n "$PROXY_PID" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$PROXY_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$PROXY_PID" 2>/dev/null || true
    fi
    # Preserve proxy log into OUT_DIR before cleanup.
    if [ -f "$SANDBOX_PROXY_LOG" ]; then
        cp "$SANDBOX_PROXY_LOG" "$OUT_DIR/egress-proxy.log" 2>/dev/null || true
    fi
    rm -rf "$SANDBOX_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Optionally launch the egress proxy (production shape: --unshare-net + proxy).
if [ "$WITH_PROXY" = "yes" ]; then
    SOCAT_BIN="$(command -v socat || true)"
    [ -n "$SOCAT_BIN" ] || { echo "error: socat required for --with-proxy" >&2; exit 65; }
    SOCAT_REAL="$(readlink -f "$SOCAT_BIN")"

    python3 "$REPO_ROOT/scripts/egress-connect-proxy.py" \
        --socket "$SANDBOX_PROXY_SOCK" \
        --log "$SANDBOX_PROXY_LOG" \
        --allow api.anthropic.com:443 \
        >/dev/null 2>&1 &
    PROXY_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -S "$SANDBOX_PROXY_SOCK" ] && break
        sleep 0.1
    done
    [ -S "$SANDBOX_PROXY_SOCK" ] || { echo "error: proxy failed to bind" >&2; exit 65; }
    echo "proxy pid:   $PROXY_PID"
fi

CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || { echo "error: claude not on PATH" >&2; exit 65; }
CLAUDE_REAL="$(readlink -f "$CLAUDE_BIN")"
CLAUDE_DIR="$(dirname "$CLAUDE_REAL")"

NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || { echo "error: node not on PATH" >&2; exit 65; }
NODE_REAL="$(readlink -f "$NODE_BIN")"
NODE_DIR="$(dirname "$NODE_REAL")"

SANDBOX_PATH="$CLAUDE_DIR:$NODE_DIR:/usr/bin:/bin"
if [ -d "$HOME/.local/bin" ]; then
    SANDBOX_PATH="$HOME/.local/bin:$SANDBOX_PATH"
fi

# Default: no --unshare-net (so we can isolate H1/H2/H3/H4 from egress-
# proxy interactions). Pass WITH_PROXY=yes (3rd arg) to add --unshare-net
# + proxy bind + HTTPS_PROXY env, matching the production sandbox shape.
BWRAP_ARGS=(
    --unshare-pid
    --unshare-uts
    --unshare-ipc
    --die-with-parent
    --new-session
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --ro-bind /nix /nix
    --ro-bind /usr /usr
    --ro-bind-try /bin /bin
    --ro-bind-try /lib /lib
    --ro-bind-try /lib64 /lib64
    --ro-bind /etc/resolv.conf /etc/resolv.conf
    --ro-bind /etc/ssl /etc/ssl
    --ro-bind-try /etc/ca-certificates /etc/ca-certificates
    --ro-bind-try /etc/static/ssl /etc/static/ssl
    --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
    --bind "$SANDBOX_HOME" "$HOME"
    --bind "$REPO_ROOT" "$REPO_ROOT"
    --bind "$SANDBOX_STATE" "$SANDBOX_STATE"
    --bind "$SANDBOX_TRACE" "$SANDBOX_TRACE"
    --bind "$SANDBOX_XDG_RUNTIME" "$SANDBOX_XDG_RUNTIME"
    --bind "$OUT_DIR" "$OUT_DIR"
    --setenv HOME "$HOME"
    --setenv USER "$USER"
    --setenv PATH "$SANDBOX_PATH"
    --setenv XDG_STATE_HOME "$SANDBOX_STATE"
    --setenv XDG_RUNTIME_DIR "$SANDBOX_XDG_RUNTIME"
    --setenv STAXCTL_TRACE_PATH "$SANDBOX_TRACE"
    --setenv EVAL_SANDBOX "bwrap-debug-c5"
    --setenv EVAL_EXECUTION_MODE "simulation"
    --chdir "$REPO_ROOT"
)

# Auth credentials (read-only bind, same as production).
if [ -d "$HOME/.config/claude" ]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.config/claude" "$HOME/.config/claude")
fi
if [ -f "$HOME/.claude/.credentials.json" ]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.claude/.credentials.json" "$HOME/.claude/.credentials.json")
fi
if [ -f "$HOME/.claude/settings.json" ]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.claude/settings.json" "$HOME/.claude/settings.json")
fi
if [ -d "$HOME/.local/bin" ]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.local/bin" "$HOME/.local/bin")
fi

# Add --unshare-net + proxy plumbing when requested (production shape).
if [ "$WITH_PROXY" = "yes" ]; then
    SANDBOX_INNER_PROXY_PORT=18118
    BWRAP_ARGS+=(
        --unshare-net
        --bind "$SANDBOX_PROXY_SOCK" "$SANDBOX_PROXY_SOCK"
        --setenv HTTPS_PROXY "http://127.0.0.1:${SANDBOX_INNER_PROXY_PORT}"
        --setenv HTTP_PROXY  "http://127.0.0.1:${SANDBOX_INNER_PROXY_PORT}"
        --setenv https_proxy "http://127.0.0.1:${SANDBOX_INNER_PROXY_PORT}"
        --setenv http_proxy  "http://127.0.0.1:${SANDBOX_INNER_PROXY_PORT}"
        --setenv NO_PROXY ""
        --setenv no_proxy ""
        --setenv EVAL_EGRESS_PROXY_SOCKET "$SANDBOX_PROXY_SOCK"
        --setenv EVAL_EGRESS_PROXY_PORT "$SANDBOX_INNER_PROXY_PORT"
        --setenv EVAL_EGRESS_ALLOW "api.anthropic.com:443"
    )
fi

BASH_BIN="$(readlink -f "$(command -v bash)")"
[ -x "$BASH_BIN" ] || BASH_BIN="$(command -v bash)"

echo "=== debug-c5-sandbox-wrap.sh ==="
echo "out dir:     $OUT_DIR"
echo "sandbox dir: $SANDBOX_DIR"
echo "prompt id:   $PROMPT_ID"
echo "with proxy:  $WITH_PROXY"
echo

if [ "$WITH_PROXY" = "yes" ]; then
    # With --unshare-net, the sandbox needs a socat TCP↔UNIX bridge to
    # forward HTTPS_PROXY traffic to the host-side proxy socket.
    SANDBOX_INNER_PROXY_PORT=18118
    INNER_CMD=("$BASH_BIN" -c "
        set -e
        '$SOCAT_REAL' \
            TCP-LISTEN:${SANDBOX_INNER_PROXY_PORT},bind=127.0.0.1,fork,reuseaddr \
            UNIX-CONNECT:'$SANDBOX_PROXY_SOCK' \
            >/tmp/socat-bridge.log 2>&1 &
        BRIDGE_PID=\$!
        trap 'kill \$BRIDGE_PID 2>/dev/null || true' EXIT
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if (echo > /dev/tcp/127.0.0.1/${SANDBOX_INNER_PROXY_PORT}) 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        exec '$BASH_BIN' '$REPO_ROOT/scripts/debug-c5-single.sh' '$PROMPT_ID' '$OUT_DIR'
    ")
else
    INNER_CMD=("$BASH_BIN" "$REPO_ROOT/scripts/debug-c5-single.sh" "$PROMPT_ID" "$OUT_DIR")
fi

bwrap "${BWRAP_ARGS[@]}" "${INNER_CMD[@]}"

echo
echo "=== post-run inventory ==="
ls -la "$OUT_DIR"
