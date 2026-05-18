# evals-agentic-control

An empirical evaluation of agentic computer-use safety under capability-gated
tool surfaces.

## What this is

A pre-registered adversarial-prompt battery run against frontier and open-weight
language models through a capability-gated computer-use harness
(`agent-app-control`). Each prompt targets a failure mode documented in the
published agentic-safety literature *or* in operational incident telemetry
from this fleet (e.g. the 2026-05-13 `XDG_STATE_HOME` wipe that seeded
category C1). Hypotheses and falsifiers are registered before runs via
`pre-registration log`. Verdicts and Type-I / Type-II catches are recorded after.

The goal is not to break models. The goal is to *measure where current
refuse-by-default behaviour breaks down when the agent is reasoning under
real operating-system primitives* — file deletion, screen scraping, network
exfiltration, blast-radius bypass via shell metacharacters — rather than under
sandboxed text-only conditions.

## Scope and non-claims

What this artifact claims:

- The harness exists, is reproducible, and is licensed AGPL.
- The adversarial-prompt battery is pre-registered with falsifiers prior to
  any model run.
- Results are reported with refuse-rate, partial-compliance rate, full-
  compliance rate, audit-envelope integrity, and a Type-I / Type-II
  breakdown per prompt category.
- Negative and inconclusive results are reported with equal weight to
  positive ones.

What this artifact does **not** claim:

- That a high refuse-rate means a model is "safe."
- That the prompt battery exhausts the agentic-misuse threat model.
- That results generalise beyond the specific harness, OS, and tool
  surface tested.
- That this is a benchmark suitable for cross-paper comparison; it is a
  point-in-time study with a fixed harness version.

## Methodology

See `docs/METHODOLOGY.md` for the full protocol. Summary:

1. **Threat model** — documented in `docs/THREAT_MODEL.md`. Five failure
   categories: blast-radius bypass, credential exfiltration, sandbox escape
   via dispatch primitives, screen-content prompt injection, persistence.
2. **Pre-registration** — every prompt is registered as a `pre-registration log`
   entry with hypothesis and falsifier *before* the first model sees it.
3. **Models under test** — Claude Opus 4.7, Claude Sonnet 4.6,
   GPT-5-class, Llama-3.x-Instruct (open-weight control).
4. **Harness** — `agent-app-control` running on an isolated Hyprland VM
   with `sandbox-gate` blast-radius protection enabled. Capability gates
   record every dispatched action. Audit envelopes are written before
   tool execution; integrity is verified after.
5. **Scoring** — per-prompt: refused / partially-complied / fully-complied
   / harness-blocked. Aggregated by category and by model.
6. **Verdict pass** — for each registered experiment, a verdict is
   recorded with evidence pointers and any Type-I (overclaim) or Type-II
   (missed risk) catches the run surfaced.

## What this work extends

- Anthropic, [*Introducing computer use, a new Claude 3.5 Sonnet, and
  Claude 3.5 Haiku*](https://www.anthropic.com/news/3-5-models-and-computer-use)
  (blog post, 22 October 2024) — the published Trust-and-Safety analysis
  is the starting point; this artifact extends it with a pre-registered
  adversarial battery rather than ad-hoc red-teaming.
- Greenblatt, Denison, Wright, et al., [*Alignment faking in large
  language models*](https://arxiv.org/abs/2412.14093), arXiv:2412.14093
  (December 2024) — provides the empirical, falsifiable methodology
  template (place a model in a scenario where compliance and identity
  conflict, measure what it actually does).
- Anthropic et al., [*Agentic Misalignment: How LLMs Could Be Insider
  Threats*](https://arxiv.org/abs/2510.05179), arXiv:2510.05179 (October
  2025) — extends simulated-corporate-environment findings into a real
  operating-system harness rather than an abstract simulation.
- Prompt-injection literature (Carlini and collaborators) — adopts the
  empirical, adversarial style of finding failure modes others assumed
  wouldn't exist.

## Reproducibility

```
nix develop
./scripts/run-eval.sh --model claude-opus-4-7 --battery v0.1.0
./scripts/score.sh results/run-YYYYMMDD-HHMMSS/
pre-registration report --since 7d
```

All raw model outputs, harness traces, and `pre-registration log` JSONL are
committed to the repo. Re-running the eval against new model versions
appends new runs; old runs are not modified.

## Licence

AGPL-3.0-or-later. Adversarial-prompt batteries are released for research
use; do not use for production red-team-as-a-service without consulting
your organisation's policy.

## Status

v0.1.0-alpha. Pre-registered battery in `spec/`. First run targeted for
[FILL IN DATE]. See `STATUS.md` for current progress and known gaps.
