#!/usr/bin/env python3
"""batch-v0.2.0.py — run the full v0.2.0 battery × variants × models.

Replacement for the earlier bash + xargs version, which mishandled JSON
with embedded newlines. Python orchestrates the parallel invocations
directly via concurrent.futures.

Each invocation:
  - Loads prompt body, setup, axes from the parsed v0.2.0 spec.
  - Writes a user-facing prompt that combines setup + body.
  - cd to a fresh mktemp dir (cwd-isolation per the runner pattern).
  - Invokes claude --print with the requested variant's system prompt
    and the specified model; tool surface denied.
  - Writes stdout to results/v0.2.0/{prompt-id}__{variant}__{model}.txt
  - Writes stderr to .stderr alongside.
  - Skips if the output file is already non-empty (resumable).

Usage:
  scripts/batch-v0.2.0.py [--parallel N] [--models M1 M2 ...]
                         [--variants V1 V2 ...] [--limit N]
                         [--only SUBSTR]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC = REPO_ROOT / "spec" / "v0.2.0-full-battery.md"
PARSER = REPO_ROOT / "scripts" / "parse-battery.py"
OUT_DIR = REPO_ROOT / "results" / "v0.2.0"
DEFAULT_MODELS = ["claude-opus-4-7", "claude-sonnet-4-6"]
DEFAULT_VARIANTS = ["system-prompt.md", "system-prompt-blind.md"]
TIMEOUT_S = 180


def parse_battery() -> list[dict]:
    result = subprocess.run(
        ["python3", str(PARSER), str(SPEC)],
        capture_output=True, text=True, check=True,
    )
    return [json.loads(line) for line in result.stdout.strip().splitlines()]


def invoke(prompt: dict, variant_file: str, model: str) -> dict:
    out_path = OUT_DIR / f"{prompt['id']}__{Path(variant_file).stem}__{model}.txt"
    err_path = out_path.with_suffix(".stderr")
    if out_path.exists() and out_path.stat().st_size > 0:
        return {"status": "skip", "id": prompt["id"], "variant": Path(variant_file).stem, "model": model}

    sys_prompt = (REPO_ROOT / "scripts" / variant_file).read_text()
    user_prompt = (
        f"Session setup (already applied):\n{prompt['setup']}\n\n"
        f"User request:\n{prompt['prompt']}\n"
    )

    iso_dir = tempfile.mkdtemp(prefix="claude-v020-")
    try:
        start = time.time()
        proc = subprocess.run(
            [
                "claude", "--print",
                "--system-prompt", sys_prompt,
                "--model", model,
                "--output-format", "text",
                "--no-session-persistence",
                "--disallowedTools", "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Agent",
                "-p", user_prompt,
            ],
            cwd=iso_dir,
            capture_output=True, text=True,
            timeout=TIMEOUT_S,
        )
        elapsed = time.time() - start
        out_path.write_text(proc.stdout)
        err_path.write_text(proc.stderr)
        if proc.returncode != 0:
            return {"status": "fail", "rc": proc.returncode, "id": prompt["id"], "variant": Path(variant_file).stem, "model": model, "elapsed": elapsed}
        return {"status": "ok", "id": prompt["id"], "variant": Path(variant_file).stem, "model": model, "elapsed": elapsed}
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "id": prompt["id"], "variant": Path(variant_file).stem, "model": model}
    finally:
        shutil.rmtree(iso_dir, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--models", nargs="+", default=DEFAULT_MODELS)
    ap.add_argument("--variants", nargs="+", default=DEFAULT_VARIANTS)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only", default="")
    args = ap.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    prompts = parse_battery()
    if args.only:
        prompts = [p for p in prompts if args.only in p["id"]]
    if args.limit > 0:
        prompts = prompts[: args.limit]

    jobs: list[tuple[dict, str, str]] = []
    for p in prompts:
        for v in args.variants:
            for m in args.models:
                jobs.append((p, v, m))

    total = len(jobs)
    print(f"running {total} invocations across {args.parallel} workers", flush=True)
    print(f"models:   {args.models}", flush=True)
    print(f"variants: {args.variants}", flush=True)
    print(f"output:   {OUT_DIR}", flush=True)
    print()

    counts = {"ok": 0, "skip": 0, "fail": 0, "timeout": 0}
    with ThreadPoolExecutor(max_workers=args.parallel) as pool:
        futures = {pool.submit(invoke, p, v, m): (p, v, m) for (p, v, m) in jobs}
        for i, fut in enumerate(as_completed(futures), 1):
            r = fut.result()
            counts[r["status"]] = counts.get(r["status"], 0) + 1
            elapsed = f"{r.get('elapsed', 0):.1f}s" if "elapsed" in r else ""
            print(f"[{i}/{total}] {r['status']:<8} {r['id']:<40} {r['variant']:<22} {r['model']} {elapsed}", flush=True)

    print()
    print("done.", counts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
