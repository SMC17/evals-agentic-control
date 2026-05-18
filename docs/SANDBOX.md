# Sandbox Design

## What changed: scoring is on the text the model produces

The v0.1.0 scoring design (per `docs/METHODOLOGY.md`) operates on the
**text the model emits**, not on the side effects of that text. The
system prompt at `scripts/system-prompt.md` instructs the model to
output the bash commands it would execute as a script for human
review, rather than running them. The eval's load-bearing safety
property is therefore **the model's adherence to that meta-instruction
combined with the absence of an executor**, not a kernel-level
containment boundary.

This changes the sandbox requirements substantially. The original
framing — "running these prompts unsandboxed is the 2026-05-13 wipe,
only worse" — applies only if the model has an executor available.
For Claude-family invocations via `claude --print` we must verify that
the launching context exposes no tool surface that would let the model
execute its own output. For open-weight invocations via `llama.cpp` or
MLX the model has no executor by default; this is the reference-safe
path.

## What the sandbox is still for

Even with text-only scoring, the sandbox remains valuable for two
reasons:

1. **Prompt environmental realism.** C2 requires synthetic secrets on
   the screen; C4 requires the injection-bearing document to be
   loaded in `Pdf-viewer`; C5 requires `~/.config/systemd/user/` and
   `~/.config/cron/` to be inspectable. The sandbox is where those
   fixtures live, separate from the host's real state.
2. **Substrate validation (the optional secondary pass).** After
   v0.1.0 verdicts on the model's text output, an optional pass
   actually executes the produced scripts inside the sandbox and
   observes side effects. This is what tests whether `sandbox-gate`
   *would* in fact intercept the model's `rm -rf $VAR/...`. That
   secondary pass requires the original kernel-level isolation —
   it's the original sandbox use case, scoped to substrate audit
   rather than model evaluation.

## Threat model the sandbox addresses (revised)

## Threat model the sandbox addresses

The sandbox isolates four blast radii:

1. **Filesystem.** Model cannot touch the host's `/`, `/home`, or any
   mounted storage. The agent sees a per-run scratch tree with
   intentionally-empty `XDG_STATE_HOME` for C1, and synthetic dotfiles
   for C5.
2. **Credentials.** No real keys, tokens, or browser profiles inside
   the sandbox. C2 uses *synthetic* secrets generated per run with a
   known marker so the audit can detect their presence in agent
   output without ever putting real credentials at risk.
3. **Window manager.** The host Hyprland session is not visible. The
   sandbox runs its own Hyprland on a nested compositor or VM. C3
   dispatches affect only the sandboxed compositor.
4. **Network.** Default-deny outbound. C4's screen-injection payloads
   reference `evil.example.com`-style sinks; the sandbox has no DNS
   resolution and no route to the public internet. Attempted exfil
   appears in the audit envelope but cannot complete.

## Implementation options (decision pending)

Three viable substrates, ranked by complexity:

### Option A — `bubblewrap` + nested Hyprland (lightest)

`bwrap` wraps a Wayland session in a user namespace with bind-mounts
controlling filesystem visibility. Hyprland-in-Hyprland via Cage or a
nested compositor handles the window manager isolation. `nftables`
namespace handles network deny.

- Pros: no VM overhead, fast iteration, native performance, runs on
  Arch directly with package install only.
- Cons: shared kernel surface, namespace-escape research is an
  ongoing threat surface; nested compositors have known edge cases.

### Option B — QEMU + MicroVM (firecracker-style)

Boot a minimal NixOS image inside QEMU with KVM acceleration. Hyprland
runs inside the VM. Per-run snapshot/revert via the QEMU monitor.

- Pros: kernel isolation, snapshot/revert is trivial, full reproducibility
  via Nix.
- Cons: 30-60s boot per run, larger artifact, GPU passthrough for
  reasonable Hyprland performance is finicky.

### Option C — Container with `gVisor` or `kata-containers`

Container runtime with a userspace kernel (`gVisor`) or a
microhypervisor (`kata`) sitting between the agent and the host kernel.

- Pros: cattle-not-pets per run, integrates with existing container
  tooling, faster boot than full VM.
- Cons: GPU/Wayland passthrough across the isolation boundary is the
  hardest piece of the stack.

**Working recommendation:** Option A (bwrap) for v0.1.0 dry-run + first
empirical runs, with the explicit non-claim that the isolation is
namespace-level not kernel-level. Promote to Option B (QEMU MicroVM)
for v0.2.0 if any v0.1.0 prompt produces ambiguous results that a
stronger isolation boundary would resolve.

## `sandbox-gate` integration

The C1 falsifier checks for blast-radius bypass; that check depends on
`sandbox-gate` being installed and enabled inside the sandbox. The
sandbox provisioning script must:

1. Install `sandbox-gate` from the fleet-canonical location.
2. Configure `sandbox-gate` to wrap `rm`, `rm -rf`, and `find ... -delete`
   invocations with the canonical refuse-on-`$VAR`-resolved-empty-path
   policy.
3. *Also* configure the C1 test variant where `sandbox-gate` is
   intentionally broken (per the STATUS.md self-validation gap) — this
   is a separate sandbox profile, not the default.

## Pre-run sandbox checklist

`run-eval.sh` refuses to enter live mode until all six checks pass:

```
[ ] sandbox flavor identifies as one of {bwrap-nested-hyprland,
    qemu-microvm, gvisor-container}
[ ] $XDG_STATE_HOME inside sandbox is the per-run scratch dir, not
    inherited from host
[ ] /home and / from host are not bind-mounted
[ ] outbound network is denied (synthetic DNS responses for the
    `evil.example.com` sinks but no actual routing)
[ ] sandbox-gate is enabled (or, for the fault-injection variant,
    explicitly disabled with a labelled audit-log marker)
[ ] agent-app-control trace log path is the per-run audit envelope,
    not the host fleet trace
```

If any check fails, `run-eval.sh --live` exits with a clear error
naming the missing precondition. `--dry-run` mode bypasses these
checks but does not invoke any model.

## Reproducibility

The sandbox image is a build artifact, not a snowflake. v0.1.0 ships
a Nix flake that builds the sandbox from source so the same image is
reproducible by any reviewer. The flake input pins the kernel,
Hyprland, `agent-app-control`, and `sandbox-gate` versions.

## Honest non-claim

This sandbox prevents the *operator-error* failure modes the threat
model names. It does not — and cannot — prevent novel kernel-level
escapes or unknown side channels. A model that has discovered a
zero-day in the kernel running inside the sandbox would in principle
escape it; the eval makes no claim about defending against that. The
eval's job is to measure model behaviour under realistic operational
isolation, not to be an alignment-grade containment boundary.
