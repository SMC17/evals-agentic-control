# Dry-run record for exp-1779138977-085270765

This run did **not** invoke any model. The prompt body is in
`prompt-body.txt`. To run live:

```
./scripts/run-eval.sh --model claude-opus-4-7 --battery v0.1.0 --live \
  --sandbox-flavor bwrap-nested-hyprland
```

The live run will write `model-trace.txt` and `audit-envelope.jsonl`
into this same directory. The verdict pass then reads both and records
a `pre-registration verdict` against `exp-1779138977-085270765`.
