#!/usr/bin/env python3
# Fake `claude -p` and `codex exec` for text generation tests. Appends each call
# (argv, cwd, prompt) to $FAKE_TEXT_LOG and answers every key its JSON schema asks
# for with "<cli> <key>" (false for booleans).
#
# With $FAKE_TEXT_ANSWERS set, a title comes from that file instead, one line per
# call, used up in order: "fail" fails the call, and an empty or missing file titles
# the thread with the first words of the message its prompt carries.
import json, os, re, sys

args = sys.argv[1:]
prompt = sys.stdin.read()
codex = args[:1] == ["exec"]

log = os.environ.get("FAKE_TEXT_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps({"argv": args, "cwd": os.getcwd(), "prompt": prompt}) + "\n")

if codex:
    schema = json.load(open(args[args.index("--output-schema") + 1]))
else:
    schema = json.loads(args[args.index("--json-schema") + 1])

name = "codex" if codex else "claude"
out = {key: (False if spec["type"] == "boolean" else "%s %s" % (name, key))
       for key, spec in schema["properties"].items()}

answers = os.environ.get("FAKE_TEXT_ANSWERS")
if answers and "title" in out:
    lines = open(answers).read().splitlines() if os.path.exists(answers) else []
    with open(answers, "w") as f:
        f.write("\n".join(lines[1:]))
    answer = lines[0] if lines else None
    if answer == "fail":
        sys.stderr.write("scripted failure\n")
        sys.exit(1)
    if answer is None:
        found = re.search(r"User message:\n(.+)", prompt) or re.search(r"USER:\n(.+)", prompt)
        answer = " ".join(found.group(1).split()[:6]) if found else "Untitled"
    out["title"] = answer

if codex:
    with open(args[args.index("--output-last-message") + 1], "w") as f:
        f.write(json.dumps(out))
else:
    print(json.dumps([{"type": "system"}, {"type": "result", "structured_output": out}]))
