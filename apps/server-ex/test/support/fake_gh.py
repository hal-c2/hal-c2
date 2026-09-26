#!/usr/bin/env python3
# Fake `gh` for tests. Answers from the rules in $FAKE_GH_RULES, a JSON list of
# {"args": [substrings], "stdin": [substrings], "stdout": text | json, "stderr", "exit",
#  "sleep": seconds to wait before answering}:
# the first rule whose substrings all appear in the joined argv (and stdin) wins.
# Every call is appended to $FAKE_GH_LOG as a JSON line {"args", "stdin"}.
import json, os, sys, time

args = sys.argv[1:]
stdin = sys.stdin.read() if "-" in args else ""
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps({"args": args, "stdin": stdin}) + "\n")

joined = " ".join(args)
with open(os.environ["FAKE_GH_RULES"]) as f:
    rules = json.load(f)

for rule in rules:
    if all(s in joined for s in rule.get("args", [])) and all(s in stdin for s in rule.get("stdin", [])):
        time.sleep(rule.get("sleep", 0))
        out = rule.get("stdout", "")
        try:
            sys.stdout.write(out if isinstance(out, str) else json.dumps(out))
            sys.stderr.write(rule.get("stderr", ""))
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(1)  # the caller stopped waiting (a sleeping rule)
        sys.exit(rule.get("exit", 0))

sys.stderr.write("fake gh: no rule for " + joined + "\n")
sys.exit(1)
