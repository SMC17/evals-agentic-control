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
#
# Egress policy (v0.2.0):
#   - simulation: --unshare-net + no proxy. Loopback only. Total egress denied.
#   - mock:       --unshare-net + a host-side CONNECT proxy bound into the
#                 sandbox via a UNIX socket, exposed as 127.0.0.1:18118 by an
#                 in-sandbox socat TCP↔UNIX bridge. HTTPS_PROXY points at it.
#                 Only api.anthropic.com:443 is allowed; all other CONNECTs
#                 are 403'd by the proxy. Direct TCP to any external IP fails
#                 because the netns has no default route. See
#                 docs/EGRESS_FILTER_DESIGN.md for the survey and decision.
#   - live:       deferred to v0.3.0.
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
SANDBOX_PROXY_SOCK="$SANDBOX_DIR/egress-proxy.sock"
SANDBOX_PROXY_LOG="$SANDBOX_DIR/egress-proxy.log"
SANDBOX_PROXY_PID_FILE="$SANDBOX_DIR/egress-proxy.pid"
SANDBOX_EGRESS_ALLOW="${EVAL_EGRESS_ALLOW:-api.anthropic.com:443}"
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

PROXY_PID=""
cleanup() {
    if [ -n "$PROXY_PID" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
        # Give it a moment to clean up its socket and write the final log line.
        for _ in 1 2 3 4 5; do
            kill -0 "$PROXY_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$PROXY_PID" 2>/dev/null || true
    fi
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

# -------------------------------------------------------------------- egress proxy (mock only)

# In execution-mode=mock we need claude to actually reach api.anthropic.com:443
# while still denying outbound to everywhere else. Approach A from
# docs/EGRESS_FILTER_DESIGN.md: a CONNECT-filtering proxy on a UNIX socket,
# bind-mounted into the sandbox, fronted by an in-sandbox socat TCP↔UNIX
# bridge on 127.0.0.1:18118.
SANDBOX_INNER_PROXY_PORT=18118
if [ "$EXECUTION_MODE" = "mock" ]; then
    if ! command -v python3 >/dev/null 2>&1; then
        echo "error: python3 not on PATH; required for egress proxy" >&2
        exit 65
    fi
    if [ ! -x "$REPO_ROOT/scripts/egress-connect-proxy.py" ]; then
        echo "error: scripts/egress-connect-proxy.py missing or not executable" >&2
        exit 65
    fi
    # Find a socat we can run inside the sandbox. We need an absolute path the
    # bwrap-internal shell can exec; the nix store version is the safest pick.
    SOCAT_BIN="$(command -v socat || true)"
    if [ -z "$SOCAT_BIN" ]; then
        echo "error: socat not on PATH; required for in-sandbox TCP↔UNIX bridge" >&2
        exit 65
    fi
    SOCAT_REAL="$(readlink -f "$SOCAT_BIN")"

    echo "egress allow:   $SANDBOX_EGRESS_ALLOW"
    echo "egress socket:  $SANDBOX_PROXY_SOCK"
    echo "egress log:     $SANDBOX_PROXY_LOG"

    # Build --allow args from comma-separated list (defaults to a single entry).
    ALLOW_ARGS=()
    IFS=',' read -r -a _allow_arr <<< "$SANDBOX_EGRESS_ALLOW"
    for a in "${_allow_arr[@]}"; do
        a="$(printf '%s' "$a" | tr -d '[:space:]')"
        [ -n "$a" ] && ALLOW_ARGS+=(--allow "$a")
    done

    # Launch proxy. We deliberately exec via python3 with the explicit script
    # path so the runtime is the host's, not whatever lives inside the sandbox.
    python3 "$REPO_ROOT/scripts/egress-connect-proxy.py" \
        --socket "$SANDBOX_PROXY_SOCK" \
        --log "$SANDBOX_PROXY_LOG" \
        --pidfile "$SANDBOX_PROXY_PID_FILE" \
        "${ALLOW_ARGS[@]}" \
        >/dev/null 2>&1 &
    PROXY_PID=$!

    # Wait for the socket to appear, up to ~2s.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -S "$SANDBOX_PROXY_SOCK" ] && break
        sleep 0.1
    done
    if [ ! -S "$SANDBOX_PROXY_SOCK" ]; then
        echo "error: egress proxy failed to bind $SANDBOX_PROXY_SOCK" >&2
        if [ -s "$SANDBOX_PROXY_LOG" ]; then
            echo "--- proxy log ---" >&2
            cat "$SANDBOX_PROXY_LOG" >&2
        fi
        exit 65
    fi
    echo "egress proxy:   pid=$PROXY_PID, socket ready"
fi

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
# Prepend ~/.local/bin so pre-registration / sandbox-gate preflight resolves.
# The dir itself is bound read-only below.
if [ -d "$HOME/.local/bin" ]; then
    SANDBOX_PATH="$HOME/.local/bin:$SANDBOX_PATH"
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
    # /usr and /bin are bound read-only so basic coreutils (sleep, cat, ls,
    # getent, curl) are present inside the sandbox. The host system is
    # write-protected here; the sandbox can only read. /bin on Arch is a
    # symlink to usr/bin so we bind both shapes.
    --ro-bind /usr /usr
    --ro-bind-try /bin /bin
    --ro-bind-try /lib /lib
    --ro-bind-try /lib64 /lib64
    --ro-bind /etc/resolv.conf /etc/resolv.conf
    --ro-bind /etc/ssl /etc/ssl
    --ro-bind-try /etc/ca-certificates /etc/ca-certificates
    --ro-bind-try /etc/static/ssl /etc/static/ssl
    --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
    # SANDBOX_HOME must bind BEFORE REPO_ROOT, otherwise the home-dir bind
    # shadows the repo path (repo lives under $HOME). bwrap honors source
    # bind order, not target depth.
    --bind "$SANDBOX_HOME" "$HOME"
    --bind "$REPO_ROOT" "$REPO_ROOT"
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
    # Egress proxy plumbing:
    #   1. Bind the host-side UNIX socket into the sandbox at the same path.
    #   2. Set HTTPS_PROXY/HTTP_PROXY so claude (undici-backed) connects via
    #      the in-sandbox loopback bridge. NO_PROXY="" forces ALL hosts to
    #      transit the proxy.
    BWRAP_ARGS+=(
        --bind "$SANDBOX_PROXY_SOCK" "$SANDBOX_PROXY_SOCK"
        --setenv HTTPS_PROXY "http://127.0.0.1:${SANDBOX_INNER_PROXY_PORT}"
        --setenv HTTP_PROXY  "http://127.0.0.1:${SANDBOX_INNER_PROXY_PORT}"
        --setenv https_proxy "http://127.0.0.1:${SANDBOX_INNER_PROXY_PORT}"
        --setenv http_proxy  "http://127.0.0.1:${SANDBOX_INNER_PROXY_PORT}"
        --setenv NO_PROXY ""
        --setenv no_proxy ""
        --setenv EVAL_EGRESS_PROXY_SOCKET "$SANDBOX_PROXY_SOCK"
        --setenv EVAL_EGRESS_PROXY_PORT "$SANDBOX_INNER_PROXY_PORT"
        --setenv EVAL_EGRESS_ALLOW "$SANDBOX_EGRESS_ALLOW"
    )
fi

# Auth: claude needs to read the user's OAuth credentials and settings.
# We bind-mount specific files/dirs read-only — NOT the whole ~/.claude
# tree, because that includes the auto-memory directory which would leak
# host context into the model.
#
# Required for auth (verified on claude-code 2.1.x):
#   - ~/.claude/.credentials.json  (OAuth token bundle)
#   - ~/.claude/settings.json      (auth/account settings)
#
# Optional but harmless:
#   - ~/.config/claude/            (config dir; may not exist)
#
# We deliberately do NOT bind ~/.claude/projects/, ~/.claude/sessions/,
# ~/.claude/history.jsonl, ~/.claude/file-history/, ~/.claude/paste-cache/,
# ~/.claude/shell-snapshots/, ~/.claude/plugins/, etc.
if [ -d "$HOME/.config/claude" ]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.config/claude" "$HOME/.config/claude")
fi
if [ -f "$HOME/.claude/.credentials.json" ]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.claude/.credentials.json" "$HOME/.claude/.credentials.json")
fi
if [ -f "$HOME/.claude/settings.json" ]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.claude/settings.json" "$HOME/.claude/settings.json")
fi
# Legacy path (older versions stored credentials under a directory).
if [ -d "$HOME/.claude/credentials" ]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.claude/credentials" "$HOME/.claude/credentials")
fi

# pre-registration and sandbox-gate live under $HOME/.local/bin. The
# preflight in run-eval.sh requires both on PATH. We already prepended
# the dir to SANDBOX_PATH; bind it read-only and also bind the real
# pre-registration binary location (symlink target) so symlink resolution
# works inside the namespace.
if [ -d "$HOME/.local/bin" ]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.local/bin" "$HOME/.local/bin")
fi
STAX_EXP_REAL="$(readlink -f "$HOME/.local/bin/pre-registration" 2>/dev/null || true)"
if [ -n "$STAX_EXP_REAL" ] && [ -x "$STAX_EXP_REAL" ]; then
    STAX_EXP_DIR="$(dirname "$STAX_EXP_REAL")"
    [ -d "$STAX_EXP_DIR" ] && BWRAP_ARGS+=(--ro-bind "$STAX_EXP_DIR" "$STAX_EXP_DIR")
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    BWRAP_ARGS+=(--setenv ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY")
fi

# We do NOT pass --setenv ANTHROPIC_API_KEY by default; per the
# no-paid-API-keys fleet policy, this eval uses subscription-auth claude.

echo
echo "host-side preflight passed; entering sandbox..."
echo

# Inner entrypoint. In mock mode we need to start the socat TCP↔UNIX bridge
# BEFORE run-eval.sh fires the model call. The bridge is a background process
# inside the sandbox; we hand-roll a tiny wrapper that starts it, sets a trap
# to kill it on exit, and execs the real runner. In simulation mode there is
# no bridge, so we invoke run-eval.sh directly.
#
# bwrap resolves the inner command path INSIDE its mount namespace but uses
# its own argv lookup, not the sandbox PATH at process start. Use absolute
# bash from /usr/bin (Arch) or /bin (most distros) — both exist post-mount.
# Pick a bash that EXISTS INSIDE THE SANDBOX. The sandbox binds /nix (the
# nix store) but does NOT bind /usr or /bin. So /usr/bin/bash on the host
# is invisible to the sandbox process — only /nix/store/...-bash/bin/bash
# is reachable. Resolve the host's bash (typically a symlink into nix-profile)
# to its real /nix/store path.
BASH_BIN="$(readlink -f "$(command -v bash)")"
[ -x "$BASH_BIN" ] || BASH_BIN="$(command -v bash)"
[ -x "$BASH_BIN" ] || { echo "error: no usable bash" >&2; exit 65; }
if [ "$EXECUTION_MODE" = "mock" ]; then
    INNER_CMD=(
        "$BASH_BIN" -c "
            set -e
            '$SOCAT_REAL' \
                TCP-LISTEN:${SANDBOX_INNER_PROXY_PORT},bind=127.0.0.1,fork,reuseaddr \
                UNIX-CONNECT:'$SANDBOX_PROXY_SOCK' \
                >/tmp/socat-bridge.log 2>&1 &
            BRIDGE_PID=\$!
            trap 'kill \$BRIDGE_PID 2>/dev/null || true' EXIT
            # Wait briefly for the bridge to start listening.
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                if (echo > /dev/tcp/127.0.0.1/${SANDBOX_INNER_PROXY_PORT}) 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done
            exec '$BASH_BIN' '$REPO_ROOT/scripts/run-eval.sh' \
                $INNER_MODE \
                --model '$MODEL' \
                --battery '$BATTERY' \
                --sandbox-flavor bwrap-nested-hyprland \
                --execution-mode '$EXECUTION_MODE'
        "
    )
else
    INNER_CMD=(
        "$BASH_BIN" "$REPO_ROOT/scripts/run-eval.sh"
        $INNER_MODE
        --model "$MODEL"
        --battery "$BATTERY"
        --sandbox-flavor bwrap-nested-hyprland
        --execution-mode "$EXECUTION_MODE"
    )
fi

set +e
bwrap "${BWRAP_ARGS[@]}" "${INNER_CMD[@]}"
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
    # The egress-proxy log is the network-layer audit envelope.
    if [ -s "$SANDBOX_PROXY_LOG" ]; then
        cp "$SANDBOX_PROXY_LOG" "$LATEST_RUN/egress-proxy.log"
        echo "egress-proxy log saved: $LATEST_RUN/egress-proxy.log"
    fi
fi

echo
echo "sandbox eval complete."
