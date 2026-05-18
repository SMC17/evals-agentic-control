#!/usr/bin/env python3
"""
Parse a battery markdown file (e.g. spec/v0.2.0-full-battery.md) and emit
one JSON object per prompt to stdout (JSONL).

The parser is structural, not lexical: it finds H3 headings matching the
prompt-id pattern (e.g. `### C1-blast-unset-state-neutral`) and extracts
the following bullet fields:

  - Axes
  - Prompt
  - Setup
  - Hypothesis
  - Falsifier
  - Difficulty

Multi-line bullet values are joined. Lines outside these fields are
ignored. The first paragraph after a prompt-id heading must start with
`- **Axes:**` for the entry to be considered a prompt block; sections
that look like prompts but don't fit the schema are skipped with a
warning to stderr.

Usage:
  parse-battery.py path/to/battery.md > battery.jsonl

Output format:
  {"id": "...", "axes": "...", "prompt": "...", "setup": "...",
   "hypothesis": "...", "falsifier": "...", "difficulty": "..."}
"""

import json
import re
import sys
from pathlib import Path

HEADING_RE = re.compile(r"^### ([A-Z]\d+-[a-z0-9-]+)\s*$")
FIELD_RE = re.compile(r"^- \*\*(Axes|Prompt|Setup|Hypothesis|Falsifier|Difficulty):\*\*\s*(.*)$")
CONTINUATION_RE = re.compile(r"^\s{2,}(.*)$")


def parse(path: Path):
    lines = path.read_text().splitlines()
    i = 0
    n = len(lines)
    while i < n:
        m = HEADING_RE.match(lines[i])
        if not m:
            i += 1
            continue
        prompt_id = m.group(1)
        i += 1
        entry = {"id": prompt_id}
        current_field = None
        while i < n and not HEADING_RE.match(lines[i]):
            line = lines[i]
            fm = FIELD_RE.match(line)
            if fm:
                current_field = fm.group(1).lower()
                entry[current_field] = fm.group(2).strip()
            elif current_field is not None:
                cm = CONTINUATION_RE.match(line)
                if cm:
                    entry[current_field] = (entry[current_field] + " " + cm.group(1).strip()).strip()
                elif line.strip() == "":
                    current_field = None
                else:
                    pass
            i += 1
        required = {"axes", "prompt", "setup", "hypothesis", "falsifier", "difficulty"}
        if required.issubset(entry.keys()):
            yield entry
        else:
            missing = required - set(entry.keys())
            print(f"WARN: prompt {prompt_id} missing fields: {missing}", file=sys.stderr)


def main():
    if len(sys.argv) != 2:
        print("usage: parse-battery.py path/to/battery.md", file=sys.stderr)
        sys.exit(2)
    path = Path(sys.argv[1])
    for entry in parse(path):
        print(json.dumps(entry, ensure_ascii=False))


if __name__ == "__main__":
    main()
