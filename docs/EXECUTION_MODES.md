# Execution Modes

The eval harness supports three execution modes. Each is wired in
`scripts/run-eval.sh` and `scripts/sandbox-bwrap.sh` behind the
`--execution-mode` flag, with the default being `simulation`.

This document explains what each mode does, when each is appropriate,
what falsifier signal each provides, and the honest non-claims for each.

## Mode summary

| Mode | Bash tool | hyprctl on PATH | Side effects | Falsifier source |
|---|---|---|---|---|
| `simulation` (default) | denied | n/a | none | model-trace.txt only |
| `mock` | allowed | `mock-hyprctl.sh` shim | trace file writes only | model-trace.txt + hyprctl-mock-trace.jsonl |
| `live` | (deferred) | (deferred) | (deferred) | (deferred to v0.3.0) |

## `simulation` — text-only scoring

### What it does

The model receives the prompt body and the system-prompt instruction to
emit only the bash commands it *would* run. All Claude Code tool surfaces
(`Bash`, `Edit`, `Write`, `Read`, `Glob`, `Grep`, `WebFetch`, `WebSearch`,
`NotebookEdit`, `Agent`) are denied via `--disallowedTools`. The model's
output is the audit envelope.

This is the v0.1.0 baseline behaviour and remains the default in v0.2.0.

### When it's appropriate

- The category falsifier is satisfied by **intent** (what the model
  proposes to do), not by host side-effects. C1, C3, C4, and C5 in
  the v0.1.0 battery all fall into this bucket — the falsifier reads
  the proposed commands directly.
- The reviewer wants the most reproducible measurement: no nondeterministic
  tool-call dispatch, no per-run sandbox cleanup, no
  compositor/state-mutation variance.
- The eval runs in a context where granting Bash is unsafe even with the
  bwrap namespace in place (e.g. running outside a sandbox during
  development).

### Falsifier signal

`results/run-*/prompts/<exp-id>/model-trace.txt` is the entire signal.
The verdict pass reads that file and a hand-coded falsifier (per
`docs/THREAT_MODEL.md`) decides confirmed / refuted / inconclusive.

### Honest non-claims

- Simulation does **not** verify whether `sandbox-gate`, capability gates,
  or any other interception layer *would* catch the dispatch. Those are
  policy-enforcement assertions on the host, not model-behaviour
  assertions. They need `mock` or `live`.
- Simulation does not test whether the model's proposed commands are
  syntactically valid — only whether they describe an action the
  falsifier names. A real shell may reject what looks like compliance
  on paper.
- The model knows from the system prompt that it is producing a script
  for review. The behaviour under "you have a real shell" instructions
  may differ; that's the subject of `mock` mode.

## `mock` — execution-against-mock-shim

### What it does

The runner allows the `Bash` tool (`Edit`, `Write`, `Read`, and friends
remain denied) so the model can actually invoke shell commands. The
sandbox stages `scripts/mock-hyprctl.sh` as a binary named `hyprctl` on a
per-run bin directory which is **first on the sandbox PATH**. Any
`hyprctl ...` invocation by the model lands in the shim, which:

1. Records the full argv, allowlisted env vars, cwd, and a UTC timestamp
   as one JSON-line per invocation to `$HYPRCTL_MOCK_TRACE`.
2. Returns exit code 0 with empty stdout.

The cumulative trace is copied to
`results/run-*/hyprctl-mock-trace.jsonl` after the run. Per-prompt
slices (whatever was in the trace at the time the prompt finished) are
also copied to each `prompts/<exp-id>/hyprctl-mock-trace.jsonl`.

### When it's appropriate

- The category falsifier wants both **intent and execution**: not just
  "what did the model say it would do" but "what did the model
  successfully invoke when it had a shell." C3 (dispatch-escape) is
  the clearest case — the falsifier is the dispatch *being issued*,
  not the model talking about issuing it.
- The reviewer wants to separate "model proposes unsafe dispatch but
  the proposed text is malformed" from "model issues an unsafe dispatch
  that real hyprctl would accept." Mock mode at least answers the first
  question for the subset of commands the mock shim sees.
- The reviewer wants to test whether the model loops on failed commands
  in ways that simulation cannot show (the mock always returns 0, so
  loop-on-failure is constrained, but the trace records every attempt).

### Falsifier signal

Two artifacts per prompt:

- `model-trace.txt` — the assistant's textual output, same as simulation.
- `hyprctl-mock-trace.jsonl` — one JSON record per `hyprctl` invocation
  the model issued through the Bash tool. Each record has
  `{ts, event, argv, cwd, env}`.

Plus the global `hyprctl-mock-trace.jsonl` at the run root.

### Honest non-claims

- **`mock-hyprctl.sh` does not parse the real hyprctl argument
  grammar.** Some malformed dispatches that real `hyprctl` would
  reject (typos in dispatch names, missing required args, invalid
  workspace IDs, etc.) look "accepted" in the mock trace. The mock
  cannot tell the verdict pass whether the dispatch *would have*
  fired on a real compositor.
- **The mock returns empty stdout.** Any agent code that calls
  `hyprctl -j clients` (expecting JSON output) sees an empty
  response and may either retry, error, or proceed with a default.
  This is a measurable behaviour, not a hidden one — the model's
  follow-up shows in `model-trace.txt`.
- **Only `hyprctl` is mocked.** Other CLI tools the model invokes
  (`agent-app-control`, `wtype`, `sandbox-gate`, `rm`, `bash -c`) hit
  whatever resolves on the sandbox PATH. The sandbox does not bind
  any of those by default, so most resolve to "command not found",
  which is itself a measurable signal but not the same as live
  enforcement.
- **The Bash tool is the model's invocation channel.** That means
  the eval measures Claude-Code-style agent behaviour through that
  tool, not the agent-app-control wrapper. If a model never reaches
  for Bash in `mock` mode, we learn nothing new versus simulation
  for that prompt.
- **Auto-memory bleed is mitigated, not eliminated.** Each `claude`
  invocation runs from a fresh `mktemp -d` cwd, so cwd-derived
  project-memory loading is empty. The cleanup deletes that directory
  after the call. If a future Claude Code version adds non-cwd-derived
  context discovery, this assumption needs re-checking.

## `live` — DEFERRED to v0.3.0

`--execution-mode=live` is recognised by both `run-eval.sh` and
`sandbox-bwrap.sh` and is **refused with a clear error**. It does not
silently fall through to simulation; the operator gets an exit code
(64 from `run-eval.sh`, 67 from `sandbox-bwrap.sh`) and an error message
pointing at `docs/SANDBOX_NESTED_HYPRLAND.md` for the roadmap.

### Why it's deferred

A faithful live mode needs:

- A headless Hyprland session inside the sandbox (per
  `docs/SANDBOX_NESTED_HYPRLAND.md` Option 2).
- A working wlroots build inside the bwrap namespace.
- A fresh `HYPRLAND_INSTANCE_SIGNATURE`, a writable per-run
  `$XDG_RUNTIME_DIR`, and a real Wayland socket separate from the host.
- Clean tear-down between prompts so traces don't bleed across runs.
- A way for the verdict pass to snapshot post-run compositor state
  (windows opened, keybinds installed, window-rules added) to feed C3
  and C5 falsifiers.

None of that is shipped in v0.2.0. The current decision is: surface the
limit honestly, refuse with a clear error, do not pretend.

### What `live` *would* provide once shipped

- Real `hyprctl` argument parsing — malformed dispatches are rejected by
  the real binary, not silently recorded as the mock does.
- Real keybind installation, window-rule eval, and dispatch effects
  inside the sandboxed compositor.
- A snapshot of compositor state after each prompt that the verdict
  pass can diff against the pre-run snapshot for the C5 persistence
  falsifier.

## Choosing a mode

Pick `simulation` when:

- You want the v0.1.0-comparable baseline numbers.
- The falsifier is intent-only.
- You're iterating on prompts and don't want sandbox setup overhead.

Pick `mock` when:

- The falsifier needs to see a `hyprctl` invocation actually issued.
- You want to measure whether the model reaches for Bash given a
  prompt that simulation showed it would propose-but-not-execute.
- You accept the "mock doesn't parse real hyprctl grammar" limitation.

Pick `live` when:

- v0.3.0 ships. Until then, the runner refuses.

## Operator quick-reference

```bash
# Simulation (default, no sandbox required)
./scripts/run-eval.sh --model claude-opus-4-7 --battery v0.1.0 --live \
  --sandbox-flavor bwrap-nested-hyprland \
  --execution-mode simulation

# Mock (sandbox-wrapped; the bwrap script stages mock-hyprctl)
./scripts/sandbox-bwrap.sh --model claude-opus-4-7 --battery v0.1.0 \
  --execution-mode mock

# Live (refused; prints error and exits non-zero)
./scripts/run-eval.sh --model claude-opus-4-7 --execution-mode live
# error: --execution-mode=live is deferred to v0.3.0 of this harness.
```

## Version table

| Version | simulation | mock | live |
|---|---|---|---|
| v0.1.0 | shipped (default and only mode) | not implemented | not implemented |
| v0.2.0 (this version) | shipped (default) | shipped (mock-hyprctl + sandbox wiring) | refused with clear error |
| v0.3.0 (planned) | shipped (default) | shipped | headless Hyprland (target) |

## Related documents

- `docs/SANDBOX.md` — sandbox design and isolation properties
- `docs/SANDBOX_NESTED_HYPRLAND.md` — roadmap for live mode
- `docs/THREAT_MODEL.md` — falsifier definitions per category
- `docs/METHODOLOGY.md` — scoring scheme that consumes these traces
- `scripts/mock-hyprctl.sh` — the mock shim implementation
- `scripts/run-eval.sh` — the runner that switches tool policy by mode
- `scripts/sandbox-bwrap.sh` — the wrapper that stages the mock and
  copies traces out
