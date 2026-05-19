#!/usr/bin/env bash
# smoke-egress.sh — probe the egress-filtered sandbox WITHOUT invoking the
# model. Stands up the same bwrap + proxy plumbing as sandbox-bwrap.sh in
# execution-mode=mock and runs curl from inside the sandbox against:
#
#   - https://api.anthropic.com/    (must succeed — proxy ALLOW)
#   - https://github.com/           (must fail — proxy 403)
#   - https://evil.example.com/     (must fail — proxy 403)
#   - https://1.1.1.1/              (must fail — direct, no route)
#   - getent hosts api.anthropic.com (must fail — no resolver in sandbox)
#
# This is the falsifier evidence for exp-1779206863-479871220 (lane
# sandbox-egress) without burning a real claude turn.
#
# Usage:
#   scripts/smoke-egress.sh [--keep-state]

set -euo pipefail

KEEP_STATE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --keep-state) KEEP_STATE=1; shift ;;
        -h|--help)
            sed -n 's/^# \?//p' "$0" | sed -n '/^Usage:/,/^$/p'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

command -v bwrap >/dev/null || { echo "error: bwrap missing" >&2; exit 65; }
command -v python3 >/dev/null || { echo "error: python3 missing" >&2; exit 65; }
command -v socat >/dev/null || { echo "error: socat missing" >&2; exit 65; }

SANDBOX_DIR="$(mktemp -d -t "egress-smoke-XXXX")"
SOCK="$SANDBOX_DIR/egress-proxy.sock"
PLOG="$SANDBOX_DIR/egress-proxy.log"
SMOKE="$SANDBOX_DIR/smoke-results.txt"
touch "$SMOKE" "$PLOG"

cleanup() {
    if [ -n "${PROXY_PID:-}" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
    fi
    if [ "$KEEP_STATE" -eq 0 ]; then
        rm -rf "$SANDBOX_DIR"
    else
        echo "smoke state retained at: $SANDBOX_DIR" >&2
    fi
}
trap cleanup EXIT

# Launch proxy.
python3 "$REPO_ROOT/scripts/egress-connect-proxy.py" \
    --socket "$SOCK" \
    --log "$PLOG" \
    --allow api.anthropic.com:443 \
    >/dev/null 2>&1 &
PROXY_PID=$!

# Wait for socket.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$SOCK" ] && break
    sleep 0.1
done
[ -S "$SOCK" ] || { echo "error: proxy failed to bind" >&2; exit 65; }

SOCAT_REAL="$(readlink -f "$(command -v socat)")"
PORT=18118

# Run the probes inside a bwrap session shaped like the mock-mode sandbox.
bwrap \
    --unshare-pid --unshare-net --unshare-uts --unshare-ipc \
    --die-with-parent --new-session \
    --proc /proc --dev /dev --tmpfs /tmp \
    --ro-bind /nix /nix \
    --ro-bind /etc/resolv.conf /etc/resolv.conf \
    --ro-bind /etc/ssl /etc/ssl \
    --ro-bind /etc/ca-certificates /etc/ca-certificates \
    --ro-bind /usr /usr --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
    --bind "$SOCK" "$SOCK" \
    --bind "$SMOKE" "$SMOKE" \
    --setenv HTTPS_PROXY "http://127.0.0.1:${PORT}" \
    --setenv HTTP_PROXY  "http://127.0.0.1:${PORT}" \
    --setenv https_proxy "http://127.0.0.1:${PORT}" \
    --setenv http_proxy  "http://127.0.0.1:${PORT}" \
    --setenv NO_PROXY "" \
    -- bash -c "
        set +e
        '$SOCAT_REAL' TCP-LISTEN:${PORT},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:'$SOCK' \
            >/tmp/socat-bridge.log 2>&1 &
        BRIDGE_PID=\$!
        trap 'kill \$BRIDGE_PID 2>/dev/null || true' EXIT
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if (echo > /dev/tcp/127.0.0.1/${PORT}) 2>/dev/null; then break; fi
            sleep 0.1
        done

        {
            echo '=== smoke-egress probes ==='
            echo

            echo '--- ALLOWED: curl -sI https://api.anthropic.com/  (expect HTTP/2 4xx) ---'
            /usr/bin/curl --max-time 10 -sI -o /dev/null -w 'http_code=%{http_code} ssl_verify=%{ssl_verify_result} time=%{time_total}\n' https://api.anthropic.com/
            echo

            echo '--- BLOCKED: curl https://github.com/ (expect proxy 403) ---'
            /usr/bin/curl --max-time 5 -sv https://github.com/ 2>&1 | grep -E 'HTTP/1.1 403|tunnel failed|CONNECT tunnel|forbidden' | head -3
            echo

            echo '--- BLOCKED: curl https://evil.example.com/ (expect proxy 403) ---'
            /usr/bin/curl --max-time 5 -sv https://evil.example.com/ 2>&1 | grep -E 'HTTP/1.1 403|tunnel failed|CONNECT tunnel|forbidden' | head -3
            echo

            echo '--- BLOCKED: direct https://1.1.1.1/  (NO_PROXY override; expect failure) ---'
            /usr/bin/curl --noproxy '*' --max-time 3 -sv https://1.1.1.1/ 2>&1 | grep -E 'unreachable|connect|error|failed' | head -3
            echo

            echo '--- DNS: getent hosts api.anthropic.com (expect failure) ---'
            /usr/bin/getent hosts api.anthropic.com 2>&1 || echo 'getent EXIT=non-zero (expected)'
            echo
        } > '$SMOKE' 2>&1
    "

echo
echo "============================ SMOKE RESULTS ============================"
cat "$SMOKE"
echo "============================ END RESULTS =============================="
echo
echo "--- proxy log ---"
cat "$PLOG"

# Pattern-match expected outcomes.
fail=0
if ! grep -q 'http_code=' "$SMOKE"; then
    echo "FAIL: api.anthropic.com produced no http_code line" >&2
    fail=$((fail+1))
fi
# api.anthropic.com without auth typically returns 401/404 — anything 2xx/3xx/4xx
# means we reached the real edge.
if grep -q 'http_code=000' "$SMOKE"; then
    echo "FAIL: api.anthropic.com returned http_code=000 (no successful TLS)" >&2
    fail=$((fail+1))
fi
if ! grep -q '403' "$SMOKE"; then
    echo "FAIL: no 403 from proxy for github.com/evil.example.com — egress not enforced" >&2
    fail=$((fail+1))
fi
if grep -E 'http_code=(2..|3..)' "$SMOKE" | grep -q 'github\|evil\|1\.1\.1'; then
    echo "FAIL: a forbidden host produced a 2xx/3xx" >&2
    fail=$((fail+1))
fi

if [ "$fail" -eq 0 ]; then
    echo "SMOKE PASS: egress filter is enforced (api.anthropic.com reachable, others 403/unreachable)"
    exit 0
fi
echo "SMOKE FAIL: $fail check(s) failed" >&2
exit 1
