#!/usr/bin/env python3
# Fake `gh` for tests. Answers from the rules in $FAKE_GH_RULES, a JSON list of
# {"args": [substrings], "stdin": [substrings], "stdout": text | json, "stderr", "exit",
#  "sleep": seconds to wait before answering}:
# the first rule whose substrings all appear in the joined argv (and stdin) wins.
# A rule with "cmd" only answers when the fake runs under that name (it can be
# symlinked as glab, tea, az, ... so one rules file serves every host CLI).
# A rule with "run" (a /bin/sh script) runs it in the call's cwd first, for commands
# such as `gh pr checkout` whose effect is on the checkout.
# A rule with "since" answering a GraphQL issue listing keeps only the issues whose
# "updatedAt" is at or after the listing's `filter.since`, as GitHub's `filterBy` does.
# A rule with "summaries" ({"owner/name#number": pullRequest node}, and "viewer", a
# login) answers a batched GraphQL summary read alias by alias, whichever pull requests
# it asks for and in whatever order; one it does not know is null.
# A rule with "record" (a path) appends the call's stdin to it once answered with exit 0,
# so a post a caller called off before it was answered is not recorded.
# A rule with "reviews" ({"path", "match", "login"}) answers `gh pr view --json` with its
# "stdout" whose "reviews" are the bodies recorded at "path" by calls whose argv had
# "match", each under "login": what GitHub has of the reviews posted to a pull request.
# Every call is appended to $FAKE_GH_LOG as a JSON line {"cmd", "args", "stdin", "cwd"}.
import json, os, re, subprocess, sys, time
from datetime import datetime


def since(out, stdin):
    after = json.loads(stdin).get("variables", {}).get("filter", {}).get("since")
    if not after:
        return out
    issues = out["data"]["repository"]["issues"]
    nodes = [n for n in issues["nodes"] if datetime.fromisoformat(n["updatedAt"]) >= datetime.fromisoformat(after)]
    return {"data": {"repository": {"issues": {**issues, "nodes": nodes}}}}

def summaries(rule, stdin):
    query = json.loads(stdin).get("query", "")
    data = {"viewer": {"login": rule.get("viewer", "monalisa")}}
    for alias, owner, name, number in re.findall(
        r'(s\d+): repository\(owner: "([^"]+)", name: "([^"]+)"\) \{ pullRequest\(number: (\d+)\)', query
    ):
        data[alias] = {"pullRequest": rule["summaries"].get(f"{owner}/{name}#{number}")}
    return {"data": data}

def reviews(out, spec):
    try:
        with open(spec["path"]) as f:
            lines = [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        lines = []
    posted = [
        {"id": "PRR_%d" % i, "author": {"login": spec["login"]}, "state": "COMMENTED",
         "body": json.loads(line["stdin"]).get("body", ""), "submittedAt": "2026-09-04T00:00:00Z"}
        for i, line in enumerate(lines) if spec["match"] in line["args"]
    ]
    return {**out, "reviews": out.get("reviews", []) + posted}

cmd = os.path.basename(sys.argv[0])
args = sys.argv[1:]
stdin = sys.stdin.read() if "-" in args else ""
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps({"cmd": cmd, "args": args, "stdin": stdin, "cwd": os.getcwd()}) + "\n")

joined = " ".join(args)
with open(os.environ["FAKE_GH_RULES"]) as f:
    rules = json.load(f)

for rule in rules:
    if rule.get("cmd", cmd) == cmd and all(s in joined for s in rule.get("args", [])) and all(s in stdin for s in rule.get("stdin", [])):
        if "run" in rule:
            subprocess.run(["/bin/sh", "-c", rule["run"]], check=True, stdout=sys.stderr)
        time.sleep(rule.get("sleep", 0))
        out = rule.get("stdout", "")
        if rule.get("since"):
            out = since(out, stdin)
        if "summaries" in rule:
            out = summaries(rule, stdin)
        if "reviews" in rule:
            out = reviews(out, rule["reviews"])
        try:
            sys.stdout.write(out if isinstance(out, str) else json.dumps(out))
            sys.stderr.write(rule.get("stderr", ""))
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(1)  # the caller stopped waiting (a sleeping rule)
        if "record" in rule and rule.get("exit", 0) == 0:
            with open(rule["record"], "a") as f:
                f.write(json.dumps({"args": joined, "stdin": stdin}) + "\n")
        sys.exit(rule.get("exit", 0))

sys.stderr.write("fake " + cmd + ": no rule for " + joined + "\n")
sys.exit(1)
