# A scriptable fake `pi` for the Pi feature: `--version`, the RPC mode
# (`--mode rpc`, JSON lines of `{type, id?, ...}`), and the print mode Pi's own
# terminal app uses to continue a session (`--session <file> -p <text>`). FAKE_DIR
# holds `config.json` (read on every command, so a step can change it between turns)
# and gets `log.jsonl`: one `start` line (argv, cwd, pid, selected environment), then
# every command received (`recv`), every dialog sent (`ui`) and every tool run (`tool`).
# Sessions are JSON files under FAKE_DIR/sessions: `{"entries": [...]}`, each entry
# `{"id", "type": "message", "message": {"role", "content"}}`.
#
# config.json:
#   version          `pi --version` (default "0.80.5")
#   discoveryError   a `--no-session` process exits at once, as a Pi stuck at a prompt
#   models           get_available_models (default one model, fake/one)
#   thinkingLevel    get_state's level (default "medium")
#   commands         get_commands
#   turns            [{"match": substring, "steps": [...]}], first match wins
#
# Turn steps: {"text": s[, "usage": {...}]}, {"thinking": s}, {"tool": name, "args": {},
# "output": s} (HAL-C2's extension gate first: see `allowed`), {"select": {"title",
# "options"}} (waits for the answer, then says it), {"event": {...}} (sent as is),
# {"mcp": {"name", "arguments"}} (a HAL-C2 MCP tool call), {"waitAbort": true} (until an
# abort, or a steer prompt, which it answers), {"exit": code}.
# Without a match the reply names the conversation so far.
import json, os, sys, time, urllib.request, uuid

DIR = os.environ["FAKE_DIR"]
LOG = os.path.join(DIR, "log.jsonl")
CONFIG = os.path.join(DIR, "config.json")
SESSIONS = os.path.join(DIR, "sessions")
ENV_PREFIXES = ("PI_", "HAL_C2_", "FAKE_")
READ_ONLY = ("read", "grep", "find", "ls")
FILE_CHANGES = ("edit", "write")


def log(entry):
    with open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")


def config():
    try:
        with open(CONFIG) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def arg(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None


# With FAKE_SESSIONS set, sessions are kept the way Pi keeps them: JSONL files under
# $PI_CODING_AGENT_SESSION_DIR (else $PI_CODING_AGENT_DIR/sessions), in a folder named by
# the working directory ("--home-me-shop--"), each starting with a header that records
# the cwd. A session whose recorded cwd does not exist is refused, as Pi refuses it.
PI_SESSIONS = None
if os.environ.get("FAKE_SESSIONS"):
    PI_SESSIONS = os.environ.get("PI_CODING_AGENT_SESSION_DIR") or (
        os.environ.get("PI_CODING_AGENT_DIR") and os.path.join(os.environ["PI_CODING_AGENT_DIR"], "sessions"))


def load(path):
    if path.endswith(".jsonl"):
        with open(path) as f:
            lines = [json.loads(line) for line in f if line.strip()]
        header = lines[0] if lines and lines[0].get("type") == "session" else {}
        if not os.path.isdir(header.get("cwd") or ""):
            sys.stderr.write("Session %s was recorded in %s, which does not exist\n" % (path, header.get("cwd")))
            sys.exit(1)
        return [line for line in lines if line.get("type") != "session"]
    with open(path) as f:
        return json.load(f)["entries"]


def new_path():
    if PI_SESSIONS:
        folder = os.path.join(PI_SESSIONS, "--%s--" % os.getcwd().lstrip("/").replace("/", "-"))
        os.makedirs(folder, exist_ok=True)
        return os.path.join(folder, "%s_%s.jsonl" % (time.strftime("%Y-%m-%dT%H-%M-%S"), uuid.uuid4()))
    os.makedirs(SESSIONS, exist_ok=True)
    return os.path.join(SESSIONS, "%s.json" % uuid.uuid4().hex[:12])


class Session:
    def __init__(self, path, entries):
        self.path, self.entries = path, entries

    def save(self):
        if self.path and self.path.endswith(".jsonl"):
            header = {"type": "session", "version": 3, "id": os.path.basename(self.path)[20:-6],
                      "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "cwd": os.getcwd()}
            with open(self.path, "w") as f:
                for line in [header] + self.entries:
                    f.write(json.dumps(line) + "\n")
        elif self.path:
            with open(self.path, "w") as f:
                json.dump({"entries": self.entries}, f)

    def append(self, role, content):
        entry = {"id": uuid.uuid4().hex[:8], "type": "message",
                 "message": {"role": role, "content": content}}
        self.entries.append(entry)
        self.save()
        return entry

    def leaf(self):
        return self.entries[-1]["id"] if self.entries else None

    def history(self):
        return [e["message"]["content"] for e in self.entries if e["message"]["role"] == "user"]


def reply_to(session, text):
    before = session.history()[:-1]
    return "Reply to %s after [%s]" % (text, " | ".join(before))


log({"start": {"argv": sys.argv, "cwd": os.getcwd(), "pid": os.getpid(),
               "env": {k: v for k, v in os.environ.items() if k.startswith(ENV_PREFIXES)}}})
cfg = config()

if "--version" in sys.argv:
    print(cfg.get("version", "0.80.5"))
    sys.exit(0)

# Pi's own terminal app continuing a session file.
if "-p" in sys.argv:
    path = arg("--session")
    session = Session(path, load(path))
    text = arg("-p")
    session.append("user", text)
    answer = reply_to(session, text)
    session.append("assistant", answer)
    print(answer)
    sys.exit(0)

if "--no-session" in sys.argv:
    if cfg.get("discoveryError"):
        sys.exit(1)
    session = Session(None, [])
elif arg("--fork"):
    session = Session(new_path(), list(load(arg("--fork"))))
    session.save()
else:
    session = Session(new_path(), [])

state = {"thinking": cfg.get("thinkingLevel", "medium"), "model": None, "usage": None}
backlog = []
ui_answers = {}
aborted = [False]


def models():
    return config().get("models", [{"provider": "fake", "id": "one", "name": "Fake One",
                                    "reasoning": False, "contextWindow": 200000}])


def current_model():
    if state["model"] is None and models():
        state["model"] = models()[0]
    return state["model"]


def read():
    if backlog:
        return backlog.pop(0)
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    msg = json.loads(line)
    log({"recv": msg})
    return msg


def wait_for(pred):
    """Reads until `pred(msg)`: dialog answers and aborts are noted, other commands answered."""
    while True:
        msg = read()
        kind = msg.get("type")
        if kind == "abort":
            aborted[0] = True
        elif kind == "extension_ui_response":
            ui_answers[msg.get("id")] = msg
        elif kind != "prompt":
            command(msg)
        if pred(msg):
            return msg


def steer(msg):
    return msg.get("type") == "prompt" and msg.get("streamingBehavior") == "steer"


def respond(msg, data=None, error=None):
    out = {"type": "response", "command": msg.get("type"), "success": error is None}
    if msg.get("id") is not None:
        out["id"] = msg["id"]
    if error is None:
        out["data"] = data
    else:
        out["error"] = error
    send(out)


def dialog(method, fields):
    ui_id = "ui-%s" % uuid.uuid4().hex[:8]
    request = dict(fields, type="extension_ui_request", id=ui_id, method=method)
    log({"ui": request})
    send(request)
    if ui_id not in ui_answers:
        wait_for(lambda m: m.get("type") == "extension_ui_response" and m.get("id") == ui_id
                 or aborted[0])
    return ui_answers.get(ui_id, {"cancelled": True})


# HAL-C2's extension (`priv/pi/hal-c2-mcp-extension.ts`) asks before tools the mode does not allow.
def allowed(tool, args):
    mode = os.environ.get("HAL_C2_PI_RUNTIME_MODE", "full-access")
    if mode == "full-access" or tool in READ_ONLY:
        return True
    if mode == "auto-accept-edits" and tool in FILE_CHANGES:
        return True
    return dialog("confirm", {"title": "Allow %s?" % tool, "message": json.dumps(args)}).get(
        "confirmed") is True


def assistant(text, usage=None):
    msg = {"role": "assistant", "content": [{"type": "text", "text": text}]}
    if usage:
        msg["usage"] = usage
    return msg


def run_turn(text):
    aborted[0] = False
    cfg = config()
    steps = None
    for turn in cfg.get("turns") or []:
        if turn.get("match", "") in text:
            steps = turn.get("steps") or []
            break
    session.append("user", text)
    if steps is None:
        steps = [{"text": reply_to(session, text)}]
    send({"type": "agent_start"})
    send({"type": "message_start", "message": {"role": "assistant"}})
    said = []
    stop = "stop"
    for step in steps:
        if aborted[0]:
            break
        if "text" in step:
            said.append(step["text"])
            usage = step.get("usage")
            if usage:
                state["usage"] = usage
            send({"type": "message_update", "message": assistant("".join(said), usage),
                  "assistantMessageEvent": {"type": "text_delta", "delta": step["text"]}})
        elif "thinking" in step:
            send({"type": "message_update", "message": assistant("".join(said)),
                  "assistantMessageEvent": {"type": "thinking_delta", "delta": step["thinking"]}})
        elif "tool" in step:
            tool, args = step["tool"], step.get("args") or {}
            call_id = "call-%s" % uuid.uuid4().hex[:6]
            if allowed(tool, args):
                log({"tool": {"name": tool, "args": args}})
                result, error = step.get("output", "ok"), False
            else:
                result, error = "%s was declined in HAL-C2." % tool, True
            send({"type": "tool_execution_start", "toolCallId": call_id, "toolName": tool,
                  "args": args})
            send({"type": "tool_execution_end", "toolCallId": call_id, "toolName": tool,
                  "result": {"content": [{"type": "text", "text": result}],
                             "details": {"exitCode": 0} if tool == "bash" else {}},
                  "isError": error})
        elif "select" in step:
            answer = dialog("select", step["select"])
            log({"ui_answer": answer})
            said.append("Picked %s." % answer.get("value"))
            send({"type": "message_update", "message": assistant("".join(said)),
                  "assistantMessageEvent": {"type": "text_delta", "delta": said[-1]}})
        elif "event" in step:
            send(step["event"])
        elif "mcp" in step:
            body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                               "params": step["mcp"]}).encode()
            req = urllib.request.Request(os.environ["HAL_C2_MCP_URL"], data=body, headers={
                "Content-Type": "application/json", "Accept": "application/json",
                "Authorization": "Bearer " + os.environ["HAL_C2_MCP_BEARER_TOKEN"]})
            with urllib.request.urlopen(req, timeout=60) as res:
                log({"mcp": json.loads(res.read())})
        elif "waitAbort" in step:
            if not aborted[0]:
                msg = wait_for(lambda m: m.get("type") == "abort" or steer(m))
                if steer(msg):
                    # Pi hands the steer to the model's next call, which answers it.
                    respond(msg)
                    session.append("user", msg["message"])
                    send({"type": "message_end", "message": assistant("".join(said))})
                    send({"type": "message_start", "message": {"role": "assistant"}})
                    said = ["steered: " + msg["message"]]
                    send({"type": "message_update", "message": assistant(said[0]),
                          "assistantMessageEvent": {"type": "text_delta", "delta": said[0]}})
        elif "exit" in step:
            os._exit(step["exit"])
    if aborted[0]:
        stop = "aborted"
    final = assistant("".join(said))
    final["stopReason"] = stop
    send({"type": "message_end", "message": final})
    session.append("assistant", "".join(said))
    send({"type": "agent_end"})
    send({"type": "agent_settled"})


def command(msg):
    kind = msg.get("type")
    cfg = config()
    if kind == "get_state":
        model = current_model()
        respond(msg, {"sessionFile": session.path, "thinkingLevel": state["thinking"],
                      "model": model, "isStreaming": False})
    elif kind == "get_available_models":
        respond(msg, {"models": models()})
    elif kind == "get_commands":
        respond(msg, {"commands": cfg.get("commands", [])})
    elif kind == "switch_session":
        session.path, session.entries = msg["sessionPath"], load(msg["sessionPath"])
        respond(msg, {"cancelled": False})
    elif kind == "set_model":
        found = [m for m in models() if m["provider"] == msg.get("provider")
                 and m["id"] == msg.get("modelId")]
        if found:
            state["model"] = found[0]
            respond(msg, found[0])
        else:
            respond(msg, error="Model not found: %s/%s" % (msg.get("provider"), msg.get("modelId")))
    elif kind == "set_thinking_level":
        state["thinking"] = msg.get("level")
        respond(msg)
    elif kind == "get_entries":
        since = msg.get("since")
        ids = [e["id"] for e in session.entries]
        start = ids.index(since) + 1 if since in ids else 0
        respond(msg, {"entries": session.entries[start:], "leafId": session.leaf()})
    elif kind == "get_session_stats":
        usage = state["usage"] or {}
        window = (current_model() or {}).get("contextWindow")
        respond(msg, {"contextUsage": {"tokens": usage.get("totalTokens"), "contextWindow": window},
                      "tokens": {"input": usage.get("input"), "output": usage.get("output"),
                                 "cacheRead": usage.get("cacheRead")}})
    elif kind == "fork":
        ids = [e["id"] for e in session.entries]
        entry = msg.get("entryId")
        if entry not in ids:
            respond(msg, error="Entry %s not found" % entry)
            return
        index = ids.index(entry)
        text = session.entries[index]["message"]["content"]
        session.path, session.entries = new_path(), session.entries[:index]
        session.save()
        respond(msg, {"text": text, "cancelled": False})
    elif kind == "get_last_assistant_text":
        said = [e["message"]["content"] for e in session.entries if e["message"]["role"] == "assistant"]
        respond(msg, {"text": said[-1] if said else None})
    elif kind == "compact":
        respond(msg, {"summary": "Compacted.", "tokensBefore": 1000})
    elif kind == "prompt":
        respond(msg)
        run_turn(msg.get("message", ""))
    elif kind in ("abort", "extension_ui_response"):
        pass
    elif msg.get("id") is not None:
        respond(msg, error="Unknown command: %s" % kind)


while True:
    command(read())
