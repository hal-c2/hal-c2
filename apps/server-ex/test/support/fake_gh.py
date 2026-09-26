#!/usr/bin/env python3
# Fake `gh` for tests. Answers from the rules in $FAKE_GH_RULES, a JSON list of
# {"args": [substrings], "stdin": [substrings], "stdout": text | json, "stderr", "exit",
#  "sleep": seconds to wait before answering}:
# the first rule whose substrings all appear in the joined argv (and stdin) wins.
# A rule with "cmd" only answers when the fake runs under that name (it can be
# symlinked as glab, tea, az, ... so one rules file serves every host CLI).
# A rule with "run" (a /bin/sh script) runs it in the call's cwd first, for commands
# such as `gh pr checkout` whose effect is on the checkout.
# Every call is appended to $FAKE_GH_LOG as a JSON line {"cmd", "args", "stdin", "cwd"}.
import json, os, subprocess, sys, time

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
        try:
            sys.stdout.write(out if isinstance(out, str) else json.dumps(out))
            sys.stderr.write(rule.get("stderr", ""))
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(1)  # the caller stopped waiting (a sleeping rule)
        sys.exit(rule.get("exit", 0))

sys.stderr.write("fake " + cmd + ": no rule for " + joined + "\n")
sys.exit(1)
