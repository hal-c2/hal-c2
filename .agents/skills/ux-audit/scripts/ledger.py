#!/usr/bin/env python3
"""ledger.py <features dir> [path filter]: the desktop's scenarios, one per line, as
claimed (no status tag: the ledger says it passes today), backlog or dropped, with file:line."""

import re
import sys
from pathlib import Path

root, flt = Path(sys.argv[1]), (sys.argv[2] if len(sys.argv) > 2 else "")
for path in sorted(root.rglob("*.feature")):
    rel = str(path.relative_to(root))
    if flt not in rel:
        continue
    feature, rule, pending = set(), set(), set()
    for no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        s = line.strip()
        if s.startswith("@"):
            pending |= set(re.findall(r"@[\w-]+", s))
            continue
        m = re.match(r"(Feature|Rule|Scenario Outline|Scenario|Example|Examples):\s*(.*)", s)
        if not m:
            continue
        kind, name = m.groups()
        if kind == "Feature":
            feature, rule = pending, set()
        elif kind == "Rule":
            rule = pending
        elif kind != "Examples":
            tags = feature | rule | pending
            if "@desktop" in tags or "@shared" in tags:
                status = "dropped" if "@dropped" in tags else "backlog" if tags & {"@backlog", "@backlog-desktop"} else "claimed"
                print(f"{status:8} {rel}:{no}  {name}")
        pending = set()
