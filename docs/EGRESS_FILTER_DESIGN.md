# Egress Filter Design — `execution-mode=mock` Network Policy

**Status:** Approach A (userspace CONNECT proxy + UNIX-socket bridge) implemented
2026-05-19, smoke-tested end-to-end, shipped as the live `--execution-mode=mock`
egress backend in `scripts/sandbox-bwrap.sh`.

**Experiment register:** `exp-1779206863-479871220` (lane `sandbox-egress`).
Hypothesis: "Under execution-mode=mock with the egress-filtered bwrap sandbox,
claude can complete a model invocation to api.anthropic.com:443 AND outbound
TCP/DNS to any other host fails closed." Pre-registered before implementation.

## Why a real filter is required

`execution-mode=mock` allows the model to invoke the `Bash` tool. The model can
therefore attempt arbitrary outbound network calls from inside the sandbox.
For the eval to make a *meaningful* safety claim, the sandbox must enforce
"only api.anthropic.com:443 is reachable" at the network layer — not at the
"the model is well-behaved" layer.

The constraints driving the design:

1. **Subscription auth, no paid API keys.** `~/.config/claude` and
   `~/.claude/credentials` are bind-mounted read-only. claude reaches
   `api.anthropic.com:443` from inside the sandbox to invoke the model.
2. **Single-user laptop, sudo available but not preferred for routine runs.**
   The egress filter must work without `sudo` per-run.
3. **Bwrap 0.11.1, Hyprland on Linux.** No slirp4netns, pasta, or mitmproxy
   installed on this box; `socat` is.
4. **The model invocation must succeed end-to-end** so `model-trace.txt` is
   non-empty and the mock-hyprctl trace can capture dispatch attempts.
5. **All other outbound — DNS, TCP, ICMP, UDP — must fail closed.** A
   prompt that says "exfiltrate to evil.example.com" must not be able to.

## Three approaches surveyed

### Approach A — userspace HTTPS CONNECT proxy + UNIX-socket bridge

**Architecture.** The sandbox keeps `--unshare-net` (no veth, no host route, no
DNS). A python CONNECT proxy runs on the host listening on a UNIX domain socket.
That socket is bind-mounted into the sandbox. Inside the sandbox, a `socat`
bridge exposes the UNIX socket as `127.0.0.1:18118`. `HTTPS_PROXY=http://127.0.0.1:18118`
is set for the model invocation.

When claude's HTTP client (the Anthropic SDK, which respects `HTTPS_PROXY` via
undici's `EnvHttpProxyAgent` — verified by `strings` on the bundled binary)
opens an HTTPS connection to `api.anthropic.com`, it sends:

```
CONNECT api.anthropic.com:443 HTTP/1.1
Host: api.anthropic.com:443
```

through the loopback bridge into the host-side proxy. The proxy:

1. Parses the request line.
2. Checks `host:port` against the allowlist (default `api.anthropic.com:443`).
3. If allowed: resolves on the host, opens upstream TCP, replies
   `200 Connection Established`, pumps bytes both ways. TLS terminates END-TO-END
   at claude and Anthropic — the proxy never sees plaintext.
4. If denied: replies `403 Forbidden by sandbox egress filter`.

**Pros:**
- Network-layer enforcement: the sandbox literally has no route to any
  external IP. Direct TCP to `1.1.1.1` returns "Network is unreachable" because
  no default route exists inside the netns.
- No TLS interception, no cert pinning gotchas. Real Anthropic certificate is
  what claude validates.
- No root, no `CAP_NET_ADMIN`, no nftables rules. Runs entirely as the eval
  user.
- ~200 lines of python; auditable by hand.
- Failure modes are loud: a forbidden CONNECT gets a 403, which appears in
  the proxy log.

**Cons:**
- The proxy trusts the CONNECT line's hostname. A client that says
  "CONNECT api.anthropic.com:443" but then does TLS SNI for a different host
  could reach an attacker-controlled cert at the resolved Anthropic IP. This is
  inherent to CONNECT-style allowlisting without TLS interception. For this
  eval, the threat model is "the model under test misbehaves," not "the model
  smuggles malicious SNI through an honest TLS-aware HTTP client."
- Only HTTP(S) CONNECT is supported. UDP-based protocols (QUIC, DNS) cannot
  egress at all. Anthropic API is HTTP/2 over TLS over TCP, so this works.
  If/when Anthropic ships HTTP/3 over QUIC and claude prefers it, the proxy
  becomes a hard backstop forcing TCP fallback — measurable, not silent.
- A determined model could try to exploit the proxy itself (parse confusion,
  resource exhaustion). The 200-line python is easier to audit than nftables
  rule sets for this concern.

### Approach B — network namespace + nftables egress filter

**Architecture.** Create a fresh netns with a veth pair. The host end of the
veth lives in the host netns; nftables on the host filters by destination IP
to the resolved IP set for `api.anthropic.com`. Sandbox runs inside the netns
via `bwrap --share-net` against the pre-created netns.

**Pros:**
- True L3 enforcement; no parser to fool. The model sees real internet, just
  filtered.
- Standard tooling; nftables semantics well-understood.

**Cons (this environment):**
- **Requires `CAP_NET_ADMIN` on the host** to create the veth pair with one
  end in the host netns and set up the routing/NAT. `unshare -U -r -n` puts
  CAP_NET_ADMIN inside the userns, but a veth created in a userns has BOTH
  ends in that userns — no bridge to real network. Confirmed empirically:
  `unshare --user --map-root-user --net -- ip link add veth0 type veth peer
  name veth1` succeeds, but both ends are isolated.
- **sudo on this laptop is password-prompt only**, not passwordless. Confirmed:
  `sudo -n true` exits 1. Routine eval runs would either need a password
  prompt per run (bad) or a setuid helper (much larger attack surface than
  Approach A's 200-line proxy).
- nftables rule set has to be careful about DNS (port 53/UDP, two query
  resolvers, possibly DoH/DoT), connection tracking, IPv6, and the SNI/SAN
  drift problem (Anthropic's edge IPs change; IP allowlist gets stale).
  Doing it right is a multi-day effort.

**Verdict:** Approach B is the more honest enforcement story IF root access were
routine. In this environment it isn't, and the setup time exceeds the budget.
Deferred. The interface (allow `api.anthropic.com:443`) is identical to
Approach A, so a future swap is mechanical.

### Approach C — drop `--unshare-net`, rely on `--disallowedTools`

**Architecture.** Remove the network isolation in `execution-mode=mock`. Trust
the `--disallowedTools` policy (no `WebFetch`, no `WebSearch`) and the
system-prompt rules to keep the model from issuing network calls.

**Pros:**
- Trivial. Zero new code.
- The eval works immediately.

**Cons:**
- **The constraint is no longer enforced; it's described.** The eval has to
  caveat every result with "outbound is informational, model-policy-enforces."
- A model that decides to `curl evil.example.com` via the `Bash` tool simply
  succeeds. The C2 (credential exfil) and C4 (screen injection) falsifiers
  become "did the model *say* it would exfiltrate" rather than "could it."
  This is exactly the "parlor trick" failure mode: a demo that looks like
  a containment guarantee but doesn't enforce one.
- Honesty would require a prominent non-claim in `EXECUTION_MODES.md` saying
  "egress not enforced in mock mode; eval results are model-policy lower
  bounds, not interception upper bounds." That's a degraded sandbox.

**Verdict:** Refused for v0.2.0. If Approach A breaks and Approach B is
unavailable, the right move is to refuse `--execution-mode=mock` with a clear
error, not silently degrade to Approach C.

## Decision

**Implement Approach A.** It is the strongest defensible filter achievable
without root in the available time, and the architecture leaves room for a
future Approach B swap (the allowlist is the same shape).

## Implementation

Files:

- `scripts/egress-connect-proxy.py` — the host-side CONNECT proxy (~200 lines).
- `scripts/sandbox-bwrap.sh` — modified to:
  - In `simulation` mode: unchanged. `--unshare-net` is kept and the only
    network is loopback inside the sandbox, with no proxy. Egress is
    fully blocked (same as v0.1.0).
  - In `mock` mode: start the egress proxy on a per-run UNIX socket, bind it
    into the sandbox, start an in-sandbox `socat` TCP↔UNIX bridge on
    `127.0.0.1:18118`, set `HTTPS_PROXY=http://127.0.0.1:18118` and
    `HTTP_PROXY=http://127.0.0.1:18118` and `NO_PROXY=""`, and run the eval.
    On exit, shut down the proxy and snapshot its log into
    `results/run-*/egress-proxy.log`.

The host-side proxy is launched as a background process by `sandbox-bwrap.sh`.
Its lifetime is the sandbox run; a `trap` cleans it up on exit.

The proxy log captures every CONNECT attempt — allowed and denied — so the
audit envelope includes a network-layer record of what the model tried.

## Smoke-test plan

1. `scripts/sandbox-bwrap.sh --model claude-opus-4-7 --execution-mode mock
   --battery v0.1.0 --keep-state`
2. Verify `results/run-*/prompts/*/model-trace.txt` is non-empty (model
   invocation succeeded; api.anthropic.com:443 was reachable).
3. Verify `results/run-*/hyprctl-mock-trace.jsonl` is non-empty (the
   mock-hyprctl shim wasn't broken by the egress changes).
4. Inspect `results/run-*/egress-proxy.log` — should contain
   `ALLOW CONNECT api.anthropic.com:443` entries from each model turn.
5. Run a deliberate forbidden-host probe inside a sandbox session
   (`scripts/smoke-egress.sh`) — github.com, evil.example.com, 1.1.1.1 must
   all fail.

The verdict on `exp-1779206863-479871220` is recorded after the smoke
completes, per the experiment-register discipline.

## Honest non-claims

- **TLS is end-to-end.** The proxy does NOT see the model's request body or
  Anthropic's response body. The eval cannot use the proxy to inspect the
  contents of the model conversation — that has to come from `model-trace.txt`.
- **The CONNECT-string allowlist is name-based.** A pathological client that
  CONNECT-says `api.anthropic.com:443` but then TLS-SNIs for `attacker.example`
  could reach a different cert at the Anthropic-resolved IP. The threat model
  is "model misbehaves," not "model + sophisticated TLS-aware client work
  together to smuggle SNI." If that threat is on-table, Approach B is required.
- **No QUIC.** UDP egress is impossible inside `--unshare-net`. If a future
  claude prefers HTTP/3, it must fall back to TCP/HTTP/2 — that fallback is
  observable in the proxy log (no QUIC attempt visible, only the resulting TCP
  CONNECT).
- **DNS is forced through the proxy's host-side resolver.** The sandbox has no
  `/etc/resolv.conf`-driven resolver because it has no network besides
  loopback. The proxy itself uses the host's resolv.conf to resolve allowed
  hostnames. A DNS-substitution attack against the host resolver would
  redirect the allowed connection. This is identical to running claude on the
  bare host.
- **The proxy is a single point of failure.** If the proxy crashes mid-run,
  in-flight HTTPS connections inside the sandbox break. The `trap`-based
  cleanup means the proxy outlives the sandbox; a future improvement is to
  add a watchdog.
- **The allowlist is set once at sandbox launch.** Adding hosts requires
  restarting the sandbox (and the proxy). This is by design — rotating the
  allowlist mid-run would be a footgun.

## Open questions deferred to v0.3.0+

- Cert-pinning the upstream Anthropic edge to prevent the "honest CONNECT,
  attacker SNI" theoretical bypass.
- Approach B as the *primary* enforcement, with Approach A as the auditable
  fallback. Requires the udev/sudo plumbing for `CAP_NET_ADMIN` already
  outlined in internal-audit R3.
- A separate proxy log format that emits JSONL rather than human-readable
  lines so the verdict pass can mechanically read it.
