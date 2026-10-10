#!/usr/bin/env python3
"""ledger.py <features dir> [path filter]: the desktop's scenarios, one per line, as
claimed (no status tag: the ledger says it passes today), backlog or dropped, with file:line."""

import re
import sys
from pathlib import Path


def emit(tags, rel, no, name):
    if "@desktop" in tags or "@shared" in tags:
        status = "dropped" if "@dropped" in tags else "backlog" if tags & {"@backlog", "@backlog-desktop"} else "claimed"
        print(f"{status:8} {rel}:{no}  {name}")


root, flt = Path(sys.argv[1]), (sys.argv[2] if len(sys.argv) > 2 else "")
for path in sorted(root.rglob("*.feature")):
    rel = str(path.relative_to(root))
    if flt not in rel:
        continue
    # An outline is reported once per Examples block, which can carry its own status tag.
    feature, rule, pending, outline = set(), set(), set(), None
    for no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        s = line.strip()
        if s.startswith("@"):
            pending |= set(re.findall(r"@[\w-]+", s))
            continue
        m = re.match(r"(Feature|Rule|Scenario Outline|Scenario Template|Scenario|Example|Examples):\s*(.*)", s)
        if not m:
            continue
        kind, name = m.groups()
        if kind == "Examples":
            if outline:
                emit(outline[0] | pending, rel, no, f"{outline[1]} [examples{': ' + name if name else ''}]")
                outline[2] = True
            pending = set()
            continue
        if outline and not outline[2]:
            emit(outline[0], rel, outline[3], outline[1])
        outline = None
        if kind == "Feature":
            feature, rule = pending, set()
        elif kind == "Rule":
            rule = pending
        elif kind in ("Scenario Outline", "Scenario Template"):
            outline = [feature | rule | pending, name, False, no]
        else:
            emit(feature | rule | pending, rel, no, name)
        pending = set()
    if outline and not outline[2]:
        emit(outline[0], rel, outline[3], outline[1])
