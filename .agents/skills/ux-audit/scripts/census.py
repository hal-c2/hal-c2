#!/usr/bin/env python3
"""census.py <db>: list the seeded threads worth auditing, grouped by what makes them unusual.

Opens the database read-only; point it at the sandbox MC's copy, not a live one.
The defects live in unusual data, so the audit visits a few threads from every group,
not just the first threads in the sidebar.
"""

from __future__ import annotations

import json
import re
import sqlite3
import sys
from collections import Counter

MARKUP = re.compile(r"^\s*<[A-Za-z_][\w-]*[\s>]")
PER_GROUP = 5


def is_payload(text: str) -> bool:
    """Markup, or a JSON object or array: what tools and agents inject, not what people type."""
    if MARKUP.match(text):
        return True
    try:
        return isinstance(json.loads(text), (dict, list))
    except ValueError:
        return False


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: census.py <hal-c2.sqlite>   (ux census passes the sandbox's copy)")
    db = sys.argv[1]
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = {k: json.loads(r) for k, r in con.execute("select kind || ':' || stream, row from shell")}
    projects = {p["id"]: p for k, p in rows.items() if k.startswith("project:")}
    threads = [t for k, t in rows.items() if k.startswith("thread:") and not t.get("deletedAt")]
    stream_of = dict(con.execute("select id, key from streams where kind = 'thread'"))
    markup = Counter()
    for stream, text in con.execute("select stream, text from messages where role = 'user'"):
        if is_payload(text):
            markup[stream] += 1
    subagents = Counter(dict(con.execute("select stream, count(*) from events where kind = 'subagent' group by stream")))
    # A scheduled run's message id names its task; the thread keeps the creator of the task.
    scheduled = Counter(dict(con.execute(
        "select stream, count(*) from messages where id like 'scheduled-task-message:%' group by stream")))

    def project(t):
        return projects.get(t.get("projectId"), {})

    def outside_root(t):
        wt, ws = t.get("worktreePath"), project(t).get("workspaceRoot")
        return bool(wt and ws and not wt.startswith(ws.rstrip("/") + "/") and wt != ws)

    def n(counter, t):
        return counter[stream_of.get(t["id"])]

    groups = [
        ("Longest", lambda t: t.get("visibleItemCount") or 0),
        ("User messages that are markup or JSON (injected by tools or agents)", lambda t: n(markup, t)),
        ("Most subagent activity", lambda t: n(subagents, t)),
        ("Worktree outside the project's root", lambda t: outside_root(t)),
        ("On a worktree", lambda t: bool(t.get("worktreePath"))),
        ("Errors", lambda t: bool(t.get("lastError") or t.get("lastErrorClass"))),
        ("Usage limit or limit recovery", lambda t: bool(t.get("usageLimitResetAt") or t.get("limitRecovery"))),
        ("Pending request or actionable plan", lambda t: bool(t.get("pendingRuntimeRequest") or t.get("hasActionableProposedPlan"))),
        ("Background tasks pending", lambda t: len(t.get("pendingBackgroundTasks") or [])),
        ("Pull requests", lambda t: len(t.get("pullRequests") or [])),
        ("Pinned", lambda t: bool(t.get("pinnedAt"))),
        ("Snoozed", lambda t: bool(t.get("snoozedUntil"))),
        ("Archived", lambda t: bool(t.get("archivedAt"))),
        ("Forked", lambda t: bool(t.get("forkedFrom"))),
        ("Longest titles", lambda t: len(t.get("title") or "")),
        ("Created by an agent", lambda t: t.get("createdBy") not in (None, "user") and t.get("visibleItemCount", 0)),
        ("Runs of a scheduled task", lambda t: n(scheduled, t)),
    ]
    print(f"{len(threads)} threads in {len(projects)} projects ({db})")
    by_provider = Counter(t.get("providerInstanceId") for t in threads)
    print("providers: " + ", ".join(f"{p} {c}" for p, c in by_provider.most_common()))
    for title, key in groups:
        hits = sorted((t for t in threads if key(t)), key=key, reverse=True)
        if not hits:
            continue
        print(f"\n## {title} ({len(hits)})")
        for t in hits[:PER_GROUP]:
            print(f"  {str(key(t)):>6}  {(project(t).get('title') or '?')[:18]:18}  {' '.join((t.get('title') or '').split())[:60]:60}  {t['id']}")


if __name__ == "__main__":
    main()
