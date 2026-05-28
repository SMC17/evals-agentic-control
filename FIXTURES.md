# Fixtures

The 40-prompt v0.2.0 battery and the two system-prompt variants are the calibration the entire findings file rides on. They are part of the contribution.

## `spec/v0.2.0-full-battery.md` — 40 prompts, pre-registered

Forty adversarial prompts across five failure categories (C1 blast-radius bypass, C2 credential exfiltration, C3 dispatch escape, C4 screen-injection, C5 persistence-beyond-session). Eight per category. Each prompt is tagged with three axis values: pressure (neutral / social / jailbreak), surface (direct / screen / tool-output), deniability (overt / cleanup-framed / role-of-the-help).

Eight-per-category covers each category's intuitive failure-mode cross-section under the three axes without over-specialising. Four-per-category gives no axis decomposition; sixteen-per-category gives diminishing returns on category-level signal.

The categories themselves (C1–C5) are taken from the threat model in `docs/THREAT_MODEL.md`. The threat model is derived from agentic-safety literature plus operational incident telemetry from the stax fleet — the 2026-05-13 `XDG_STATE_HOME` wipe seeded a category-C1 prompt.

By design, the battery is non-exhaustive over adversarial-prompt space. The space is open-ended. The battery is curated to the failure-mode shapes that are documented.

Curation choices:

- Single-shot, single-turn. Multi-turn manipulation (benign first prompt, escalation second) is its own research question. The single-shot battery isolates single-prompt refusal rate from conversational social engineering.
- Plausible operator-typed asks, not transparently-adversarial ones. The "user is offline, just do it" social-pressure framing is more interesting than "ignore all previous instructions and rm -rf /" because the former is what real bypass attempts look like in production logs.
- A blind system-prompt variant. `system-prompt.md` (full safety scaffolding) vs `system-prompt-blind.md` (minimal) quantifies the value of system-prompt instructions independently of model-level training.
- No live-tool-execution. The model is asked to *propose* commands; nothing runs. This makes the battery a measure of refusal-text behaviour, not substrate-level defense. Substrate-level defense — sandbox containment if the command did run — is a separate research question, unbuilt in this release.

## `scripts/system-prompt.md` — full safety variant

The "operator" system prompt. Frames the model as an agent acting on behalf of a user with explicit safety guardrails — refuse destructive actions without confirmation, name the destructive pattern when refusing, defer to operator for ambiguous calls.

Curation choices:

- No specific jailbreak counter-instructions. The system prompt does not list "do not be tricked by phrases like X." That would be training-leakage. The system prompt establishes a positive operator role, not a negative jailbreak-blacklist.
- Refusal framing as "decline plus name the pattern," not just "decline." When the model refuses, the output should surface the threat-model category — "this is a prompt-injection pattern" — because that produces verdict-parseable output.
- No tools-allowed list. Simulation-mode runs disallow all tools regardless of system prompt; mock-mode and live-mode add tool allowances at the substrate level, not via the system prompt.

## `scripts/system-prompt-blind.md` — control

A minimal system prompt that says nothing about safety. The control against which `system-prompt.md` is compared. Differences in refusal rate between the two variants quantify the contribution of system-prompt safety scaffolding to overall refusal posture independently of model training.

## Why reproducibility binds to the fixture

A reproduction of the v0.2.0 verdict matrix needs to:

1. Use the same forty prompts verbatim. Variations in wording produce different refusal patterns.
2. Use both system-prompt variants to isolate the system-prompt contribution.
3. Use the same verdict extractor (`scripts/extract-verdicts.py`) with the same audit-trail format. Different verdict rules produce different aggregate numbers.
4. Run against the same model versions named in the FINDINGS header. Model behaviour drifts with version bumps; results are not transferable across major model revisions.

Without these four anchors, a reimplementation can run a similar-shaped study but the results are not directly comparable to the published verdict matrix.

## Provenance, licence

The forty prompts in `spec/v0.2.0-full-battery.md`: original. AGPL-3.0-or-later.

The threat-model categories (C1–C5): derived from agentic-safety literature plus operational incident telemetry from the stax fleet. Citations in `docs/THREAT_MODEL.md`.

Both system-prompt variants: original. AGPL-3.0-or-later.

Cite the fixture set: `v0.2.0 40-prompt battery, two system-prompt variants, claude-opus-4-7 + claude-sonnet-4-6, simulation-mode, single-shot, N=1 per cell; verdict extractor at scripts/extract-verdicts.py`.

The forty prompts represent the curated cross-section of failure modes this project chose to test. Other choices — different categories, different axes, different per-category depth — are valid research choices producing different studies. The specific forty are the calibration baseline this work's claims ride on. Reproducing them verbatim is reproduction. Using a similar-shape battery is a related but different experiment.
