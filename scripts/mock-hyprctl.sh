#!/usr/bin/env bash
# mock-hyprctl.sh — v0.2.0 mock shim for nested-Hyprland-less sandboxes.
#
# When bind-mounted over /usr/bin/hyprctl inside the bwrap sandbox, this
# script records each invocation (full argv, env, cwd, timestamp) to a
# structured trace file, then exits 0 without touching any real compositor.
#
# Tools inside the sandbox that call hyprctl see a successful return; the
# audit envelope ends up in $HYPRCTL_MOCK_TRACE (or /tmp/hyprctl-mock.jsonl
# by default).
#
# Wiring (not yet enabled in sandbox-bwrap.sh):
#   --ro-bind <repo>/scripts/mock-hyprctl.sh /usr/bin/hyprctl
#   --setenv HYPRCTL_MOCK_TRACE "$SANDBOX_DIR/hyprctl-mock.jsonl"
#
# Honest non-claims:
#   - This shim does NOT parse the hyprctl argument grammar. A real hyprctl
#     would reject some malformed dispatches that this shim accepts.
#     v0.3.0 (headless Hyprland) is the real-fidelity option.
#   - Stdout returned to the caller is empty. Some agent code may expect
#     JSON-shaped output (e.g. `hyprctl -j clients`); v0.2.1 will add
#     a minimal fake-JSON emitter for the read-only subcommands.

set -euo pipefail

TRACE="${HYPRCTL_MOCK_TRACE:-/tmp/hyprctl-mock.jsonl}"

# Build the JSON record in Python in one shot — handles escaping, argv as
# a real list, and env-var allowlist properly.
record="$(python3 - "$@" <<'PY'
import json, os, sys
from datetime import datetime, timezone

argv = sys.argv[1:]
ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")[:-4] + "Z"
cwd = os.getcwd()

# Allowlist of env-var name prefixes worth recording for an agentic-control
# audit. Excludes the noisy nix-store PATH, locale archive, etc.
keep_prefixes = (
    "HYPR", "WAYLAND", "XDG_", "DISPLAY", "STAXCTL_", "EVAL_SANDBOX",
    "USER", "HOME",
)
env = {k: v for k, v in os.environ.items() if k.startswith(keep_prefixes)}

print(json.dumps({
    "ts": ts,
    "event": "hyprctl-mock-invocation",
    "argv": argv,
    "cwd": cwd,
    "env": env,
}))
PY
)"

# Append atomically.
{
    flock -x 9
    printf '%s\n' "$record"
} 9>>"${TRACE}.lock" >> "$TRACE"

# Distinguishable exit: 0 = recorded. Caller cannot distinguish from real
# hyprctl success; that is the point.
exit 0
