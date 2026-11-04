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
# A rule with "pulls" (pull requests as `gh pr list --json` gives them) answers the
# MC's GraphQL pull request listing, a search or a repository's own list, a page of
# `first` after `after` at a time, with each pull request's checks summed up the way
# GitHub's `statusCheckRollup.state` does.
# A rule with "repository" ("owner/name") only answers a pull request listing of it.
# A rule with "record" (a path) appends the call's stdin to it once answered with exit 0,
# so a post a caller called off before it was answered is not recorded.
# A rule with "reviews" ({"path", "match", "login"}) answers `gh pr view --json` with its
# "stdout" whose "reviews" are the bodies recorded at "path" by calls whose argv had
# "match", each under "login": what GitHub has of the reviews posted to a pull request.
# A rule with "head" ({"status": "HTTP/2.0 403 Forbidden", "headers": {name: value}})
# answers nothing: the first one whose substrings match puts its status line and
# headers ahead of the answer of a call made with --include, as `gh api --include`
# does. A gh call with --include that no head rule matches gets "HTTP/2.0 200 OK" or,
# when it fails, "HTTP/2.0 500 Internal Server Error", with no headers. (tea prints
# its head to stderr, which its rules give themselves.)
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

FAILED = {"FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED"}

def rollup(contexts):
    if not contexts:
        return None
    if any((c.get("conclusion") or c.get("state") or "").upper() in FAILED for c in contexts):
        return {"state": "FAILURE"}
    if any((c.get("status") or "COMPLETED").upper() != "COMPLETED"
           or (c.get("state") or "").upper() in ("PENDING", "EXPECTED") for c in contexts):
        return {"state": "PENDING"}
    return {"state": "SUCCESS"}

def pull_node(pr):
    node = {k: v for k, v in pr.items() if k not in ("reviewRequests", "latestReviews", "labels", "statusCheckRollup")}
    node["reviewRequests"] = {"nodes": [{"requestedReviewer": r} for r in pr.get("reviewRequests") or []]}
    node["latestReviews"] = {"nodes": pr.get("latestReviews") or []}
    node["labels"] = {"nodes": pr.get("labels") or []}
    node["commits"] = {"nodes": [{"commit": {"statusCheckRollup": rollup(pr.get("statusCheckRollup"))}}]}
    return node

def pulls(prs, stdin):
    request = json.loads(stdin)
    variables = request.get("variables", {})
    start = int(variables.get("after") or 0)
    end = start + variables.get("first", 1)
    connection = {
        "pageInfo": {"hasNextPage": end < len(prs), "endCursor": str(end)},
        "nodes": [pull_node(pr) for pr in prs[start:end]],
    }
    if "search(" in request["query"]:
        return {"data": {"search": {**connection, "issueCount": len(prs)}}}
    return {"data": {"repository": {"pullRequests": connection}}}

def lists(repository, stdin):
    if "PullRequestList" not in stdin:
        return False
    variables = json.loads(stdin).get("variables", {})
    owner, name = repository.split("/", 1)
    return ("repo:" + repository + " ") in variables.get("q", "") or (
        variables.get("owner") == owner and variables.get("name") == name)

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

def matches(rule):
    return rule.get("cmd", cmd) == cmd and all(s in joined for s in rule.get("args", [])) and all(s in stdin for s in rule.get("stdin", [])) and ("repository" not in rule or lists(rule["repository"], stdin))

head = next((r["head"] for r in rules if "head" in r and matches(r)), None)

def write_head(exit_code):
    if "--include" not in args or (head is None and cmd != "gh"):
        return
    h = head or {"status": "HTTP/2.0 200 OK" if exit_code == 0 else "HTTP/2.0 500 Internal Server Error"}
    sys.stdout.write(h["status"] + "\r\n" + "".join("%s: %s\r\n" % kv for kv in h.get("headers", {}).items()) + "\r\n")

for rule in rules:
    if "head" not in rule and matches(rule):
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
        if "pulls" in rule:
            out = pulls(rule["pulls"], stdin)
        try:
            write_head(rule.get("exit", 0))
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
