#!/usr/bin/env python3
# Fake `claude -p` and `codex exec` for text generation tests. Appends each call
# (argv, cwd, prompt, pid) to $FAKE_TEXT_LOG and answers every key its JSON schema asks
# for with "<cli> <key>" (false for booleans). $FAKE_TEXT_ANSWER (a JSON object)
# replaces answers by key, $FAKE_TEXT_FAIL makes the call fail with that message and
# $FAKE_TEXT_HANG makes it never answer. $FAKE_TEXT_EXIT makes it exit with that code
# (printing $FAKE_TEXT_FAIL, if any, on stderr), and $FAKE_TEXT_STDOUT replaces what
# Claude prints on stdout (before it exits).
#
# With $FAKE_TEXT_ANSWERS set, a title comes from that file instead, one line per
# call, used up in order: "fail" fails the call, and an empty or missing file titles
# the thread with the first words of the message its prompt carries.
import errno, hashlib, json, os, re, sys, time

args = sys.argv[1:]

# `codex ... mcp list --json`: the servers $FAKE_CODEX_MCP lists (a JSON array), or a
# failure with $FAKE_CODEX_MCP_FAIL. Logged apart from the writing calls.
if args[-3:] == ["mcp", "list", "--json"]:
    if os.environ.get("FAKE_TEXT_LOG"):
        with open(os.environ["FAKE_TEXT_LOG"] + ".mcp", "a") as f:
            f.write(json.dumps(args) + "\n")
    if os.environ.get("FAKE_CODEX_MCP_FAIL"):
        sys.stderr.write("cannot list\n")
        sys.exit(1)
    print(os.environ.get("FAKE_CODEX_MCP") or "[]")
    sys.exit(0)

prompt = sys.stdin.read()
codex = args[:1] == ["exec"]



def codex_files():
    # config.toml is logged as is; auth.json only as its sha256, so a call that reaches the
    # login fallback without a seeded home never writes a real token into a log.
    home = os.environ.get("CODEX_HOME")
    files = {}
    modes = {}
    if home:
        path = os.path.join(home, "config.toml")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                files["config.toml"] = f.read()
        path = os.path.join(home, "auth.json")
        if os.path.exists(path):
            with open(path, "rb") as f:
                files["auth.json"] = hashlib.sha256(f.read()).hexdigest()
            modes["auth.json"] = oct(os.stat(path).st_mode & 0o777)
        modes["."] = oct(os.stat(home).st_mode & 0o777)
    return files, modes

log = os.environ.get("FAKE_TEXT_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps({"argv": args, "cwd": os.getcwd(), "prompt": prompt, "pid": os.getpid(),
                            "codexHome": os.environ.get("CODEX_HOME"),
                            "codexFiles": codex_files()[0], "codexModes": codex_files()[1],
                            "claudeConfigDir": os.environ.get("CLAUDE_CONFIG_DIR"),
                            "codexHome": os.environ.get("CODEX_HOME"),
                            "entrypoint": os.environ.get("CLAUDE_CODE_ENTRYPOINT"),
                            "claudecode": os.environ.get("CLAUDECODE")}) + "\n")

# $FAKE_TEXT_STARTED names a fifo the call writes to once logged: a receipt for a test
# that stops the caller while this call runs.
if os.environ.get("FAKE_TEXT_STARTED"):
    # Non-blocking, retried briefly: a test that attached no reader fails on its own
    # assertion instead of hanging this process in open().
    for _ in range(50):
        try:
            fd = os.open(os.environ["FAKE_TEXT_STARTED"], os.O_WRONLY | os.O_NONBLOCK)
            os.write(fd, b"started")
            os.close(fd)
            break
        except OSError as e:
            if e.errno != errno.ENXIO:
                break
            time.sleep(0.1)

if codex:
    schema = json.load(open(args[args.index("--output-schema") + 1]))
else:
    schema = json.loads(args[args.index("--json-schema") + 1])

if os.environ.get("FAKE_TEXT_HANG"):
    while True:
        time.sleep(60)

if os.environ.get("FAKE_TEXT_STDOUT") is not None and not codex:
    print(os.environ["FAKE_TEXT_STDOUT"])

if os.environ.get("FAKE_TEXT_FAIL") or os.environ.get("FAKE_TEXT_EXIT"):
    if os.environ.get("FAKE_TEXT_FAIL"):
        sys.stderr.write(os.environ["FAKE_TEXT_FAIL"] + "\n")
    sys.exit(int(os.environ.get("FAKE_TEXT_EXIT") or 1))

if os.environ.get("FAKE_TEXT_STDOUT") is not None and not codex:
    sys.exit(0)

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
