#!/usr/bin/env python3
"""File a parent issue plus one sub-issue per non-ok finding from an audit dir.

Usage:
  github_issues.py --dir AUDIT_DIR --repo hal-c2/hal-c2 [--title "..."] [--env "..."]
                   [--upload-shots] [--dry-run]
Requires `gh` authenticated. Findings with `fixed` set are left out.
--upload-shots pushes the shots the issues use to one secret gist and embeds
them; GitHub has no API for issue attachments. Without it each sub-issue
names its shots. Resumable: the state file AUDIT_DIR/issues.state.json
records what exists and is tied to the repo and audit dir, so a re-run never
duplicates and never reuses another audit's parent or gist.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_report import SEV_LABEL, SEV_ORDER, load_findings

LABELS = [
    ("ux-audit", "5319e7", "Findings from a desktop UX/UI audit"),
    ("severity:high", "b60205", "Blocks or misleads a task, shows internals, or loses work"),
    ("severity:medium", "d93f0b", "Clear usability cost, workaround exists"),
    ("severity:low", "fbca04", "Polish / consistency"),
    ("severity:info", "0e8a16", "Observation"),
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--title", default="Desktop UX/UI audit")
    ap.add_argument("--env", default="", help="environment caveats for the parent issue")
    ap.add_argument("--upload-shots", action="store_true", help="embed the shots through a secret gist")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    root = Path(a.dir).resolve()
    env = {**os.environ, "GH_REPO": a.repo}

    def gh(*args, inp=None):
        r = subprocess.run(["gh", *args], input=inp, capture_output=True, text=True, env=env, check=False)
        if r.returncode:
            sys.exit(f"gh {' '.join(args[:3])} failed: {r.stderr[:600]}")
        return r.stdout

    def api(method, path, payload):
        return json.loads(gh("api", "-X", method, path, "--input", "-", inp=json.dumps(payload)))

    findings = load_findings(root / "findings.jsonl")
    issues = sorted((f for f in findings if f["sev"] != "ok" and not f["fixed"]), key=lambda f: (SEV_ORDER.index(f["sev"]), f["id"]))
    oks = [f for f in findings if f["sev"] == "ok"]
    fingerprint = {"repo": a.repo, "dir": str(root)}
    state_path = root / "issues.state.json"
    state = {"fingerprint": fingerprint, "subs": {}, "linked": []}
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8"))
        if state.get("fingerprint") != fingerprint:
            sys.exit(f"{state_path} belongs to a different audit ({state.get('fingerprint')})")

    def save():
        state_path.write_text(json.dumps(state, indent=1), encoding="utf-8")

    def upload_shots():
        names = sorted({s for f in issues for s in f["shots"] if (root / "shots" / s).exists()})
        if "gist" not in state:
            readme = root / "gist-README.md"
            readme.write_text(f"Screenshots for the {a.title} in {a.repo}.\n", encoding="utf-8")
            state["gist"] = gh("gist", "create", "-d", f"{a.title} screenshots", str(readme)).strip().rsplit("/", 1)[-1]
            save()
        clone = root / "gist"
        git = ["git", "-C", str(clone), "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"]
        if not clone.exists():
            subprocess.run([*git[:1], *git[3:], "clone", "-q", f"https://gist.github.com/{state['gist']}.git", str(clone)], check=True)
        for n in names:
            shutil.copyfile(root / "shots" / n, clone / n)
        subprocess.run([*git, "add", "--", *names], check=True)
        if subprocess.run([*git, "diff", "--cached", "--quiet"], check=False).returncode:
            subprocess.run([*git, "commit", "-q", "-m", "shots"], check=True)
            subprocess.run([*git, "push", "-q"], check=True)
        # The revision-less raw URL 404s; the API's per-file raw_url serves image/png.
        files = json.loads(gh("api", f"gists/{state['gist']}"))["files"]
        return {n: files[n]["raw_url"] for n in names if n in files}

    shot_urls = {}

    def shots_md(f):
        if not f["shots"]:
            return ""
        if not shot_urls:
            return "\n**Screenshots (in the local audit report):** " + ", ".join(f"`{s}`" for s in f["shots"])
        return "\n## Screenshots\n\n" + "\n\n".join(f"`{s}`\n\n![{s}]({shot_urls[s]})" if s in shot_urls else f"`{s}` (not uploaded)" for s in f["shots"])

    def sub_body(f):
        b = [f"Part of the {a.title}, parent #{state['parent']}.", ""]
        b.append(f"**Severity:** {SEV_LABEL[f['sev']]}  \n**Area:** {f['area']}")
        if f["related"]:
            b.append("\n**Related:** " + ", ".join(f["related"]))
        b.append("\n## Problem\n\n" + (f["desc"] or f["title"]))
        if f["evidence"]:
            ev = f["evidence"] if isinstance(f["evidence"], str) else json.dumps(f["evidence"], indent=1, ensure_ascii=False)
            b.append("\n<details><summary>Evidence</summary>\n\n```json\n" + ev + "\n```\n</details>")
        if f["shots"]:
            b.append(shots_md(f))
        if f["where"]:
            b.append("\n## Where\n\n" + "\n".join(f"- `{w}`" for w in f["where"]))
        if f["ledger"]:
            b.append("\n## Ledger\n\n" + "\n".join(f"- `{s}`" for s in f["ledger"]))
        if f["solutions"]:
            b.append("\n## Possible solutions\n\n" + "\n".join(f"{i}. {s}" for i, s in enumerate(f["solutions"], 1)))
        return "\n".join(b)

    def parent_body():
        counts = {s: sum(1 for f in findings if f["sev"] == s) for s in SEV_ORDER}
        b = ["UX/UI audit of the Qt desktop, run in the `mise run desktop:cua` sandbox against real data with the `ux-audit` skill.\n"]
        b.append("| Severity | Count |\n|---|---|\n" + "\n".join(f"| {SEV_LABEL[s]} | {counts[s]} |" for s in SEV_ORDER))
        b.append(
            "\n**High** = blocks or misleads a task, shows internals, or loses work; **Medium** = clear usability cost, workaround exists; "
            "**Low** = polish / consistency; **Info** = observation.\n\n## Sub-issues"
        )
        for sev in SEV_ORDER[:-1]:
            fs = [f for f in issues if f["sev"] == sev]
            if fs:
                b.append(f"\n### {SEV_LABEL[sev]}\n")
                b += [f"- [ ] #{state['subs'][f['id']]['number']} {f['id']} {f['title']}" for f in fs]
        if a.env:
            b.append("\n## Environment and caveats\n\n" + a.env)
        fixed = [f for f in findings if f["fixed"]]
        if fixed:
            b.append("\n## Fixed on main before filing\n")
            b += [f"- **{f['id']} {f['title']}**: {f['fixed']}" for f in fixed]
        if oks:
            b.append("\n## Reviewed and judged fine as-is\n")
            b += [f"- **{f['id']} {f['title']}**: {f['why_ok']}" for f in oks]
        return "\n".join(b)

    if a.dry_run:
        state.setdefault("parent", 0)
        for f in issues:
            state["subs"].setdefault(f["id"], {"number": 0})
        print("=== PARENT ===\n" + parent_body())
        # Every body, since each one is published and has to be read for private text first.
        for f in issues:
            print(f"\n=== SUB {f['id']} ===\n" + sub_body(f))
        print(f"\n(dry run) would create 1 parent + {len(issues)} sub-issues in {a.repo}")
        return

    if a.upload_shots:
        shot_urls.update(upload_shots())
        print(f"{len(shot_urls)} shots in gist {state['gist']}")
    have = {lbl["name"] for lbl in json.loads(gh("label", "list", "--limit", "300", "--json", "name"))}
    for name, color, desc in LABELS:
        if name not in have:
            gh("label", "create", name, "--color", color, "--description", desc)
    if "parent" not in state:
        r = api("POST", f"repos/{a.repo}/issues", {"title": f"{a.title}: {len(issues)} findings", "body": "(populating…)", "labels": ["ux-audit"]})
        state["parent"], state["parent_node"] = r["number"], r["node_id"]
        save()
        print("parent", r["number"])
    for f in issues:
        if f["id"] in state["subs"]:
            continue
        r = api(
            "POST",
            f"repos/{a.repo}/issues",
            {"title": f"[UX {f['id']}][{SEV_LABEL[f['sev']]}] {f['title']}"[:250], "body": sub_body(f), "labels": ["ux-audit", f"severity:{f['sev']}"]},
        )
        state["subs"][f["id"]] = {"number": r["number"], "node": r["node_id"]}
        save()
        print(f["id"], r["number"])
        time.sleep(1.2)
    q = "mutation($p:ID!,$c:ID!){ addSubIssue(input:{issueId:$p, subIssueId:$c}){ subIssue { number } } }"
    for f in issues:
        if f["id"] in state["linked"]:
            continue
        r = subprocess.run(
            ["gh", "api", "graphql", "-f", f"query={q}", "-F", f"p={state['parent_node']}", "-F", f"c={state['subs'][f['id']]['node']}"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        if r.returncode and "already" not in r.stderr:
            sys.exit(f"link {f['id']} failed: {r.stderr[:300]}")
        state["linked"].append(f["id"])
        save()
        time.sleep(0.5)
    api("PATCH", f"repos/{a.repo}/issues/{state['parent']}", {"body": parent_body()})
    print(f"done: parent #{state['parent']} with {len(state['subs'])} sub-issues")


if __name__ == "__main__":
    main()
