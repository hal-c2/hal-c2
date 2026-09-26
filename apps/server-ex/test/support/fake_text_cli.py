#!/usr/bin/env python3
# Fake `claude -p` and `codex exec` for text generation tests. Appends each call
# (argv, cwd, prompt, pid) to $FAKE_TEXT_LOG and answers every key its JSON schema asks
# for with "<cli> <key>" (false for booleans). $FAKE_TEXT_ANSWER (a JSON object)
# replaces answers by key, $FAKE_TEXT_FAIL makes the call fail with that message and
# $FAKE_TEXT_HANG makes it never answer.
#
# With $FAKE_TEXT_ANSWERS set, a title comes from that file instead, one line per
# call, used up in order: "fail" fails the call, and an empty or missing file titles
# the thread with the first words of the message its prompt carries.
import json, os, re, sys, time

args = sys.argv[1:]
prompt = sys.stdin.read()
codex = args[:1] == ["exec"]

log = os.environ.get("FAKE_TEXT_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps({"argv": args, "cwd": os.getcwd(), "prompt": prompt, "pid": os.getpid()}) + "\n")

if codex:
    schema = json.load(open(args[args.index("--output-schema") + 1]))
else:
    schema = json.loads(args[args.index("--json-schema") + 1])

if os.environ.get("FAKE_TEXT_HANG"):
    while True:
        time.sleep(60)

if os.environ.get("FAKE_TEXT_FAIL"):
    sys.stderr.write(os.environ["FAKE_TEXT_FAIL"] + "\n")
    sys.exit(1)

name = "codex" if codex else "claude"
out = {key: (False if spec["type"] == "boolean" else "%s %s" % (name, key))
       for key, spec in schema["properties"].items()}
out.update(json.loads(os.environ.get("FAKE_TEXT_ANSWER") or "{}"))

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
