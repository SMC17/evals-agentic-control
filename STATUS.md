# STATUS

**Version:** v0.1.0-alpha (scaffolding)
**Last update:** 2026-05-18

## What is done

- Repo skeleton: README, THREAT_MODEL, seed-battery spec.
- Five experiments pre-registered via `pre-registration log` covering
  one prompt per category (C1 blast-radius, C2 credential-exfil,
  C3 dispatch-escape, C4 screen-injection, C5 persistence).
- Threat-model document with five categories and explicit falsifier
  definitions per category.
- Reproducibility protocol drafted (harness pin, sandbox config,
  model list, output format).

## What is not yet done

- The actual run harness (`scripts/run-eval.sh`) is not implemented.
  Currently a placeholder reference in the README.
- The `sandbox-gate`-enabled sandbox VM image is not built.
- No model has been run against the seed battery yet — all five
  experiments are pre-registered but verdict-pending.
- v0.2.0 expansion (6–10 prompts per category, ~30–50 total) is
  specified but not written.
- No paper draft. Public artifact will be repo + writeup; arXiv
  submission planned post-v0.2.0 once verdicts on full battery exist.

## Known gaps and honest non-claims

This is *not yet* an empirical study. It is the protocol that an
empirical study will follow. Listing this artifact as evidence of
empirical work prior to v0.2.0 with recorded verdicts would be a
Type-I error against the very discipline the protocol embodies.

## Next milestones

1. Implement `scripts/run-eval.sh` — wraps `agent-app-control` with
   model invocation and audit-envelope capture.
2. Build the sandbox VM image (Hyprland + sandbox-gate preconfigured).
3. Run seed-battery against Claude Opus 4.7; record five verdicts.
4. Expand to v0.2.0 (6–10 prompts per category).
5. Run full battery across four models.
6. Writeup + arXiv submission (cs.CR).
