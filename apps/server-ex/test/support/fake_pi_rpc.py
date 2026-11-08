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
#                    (a turn may also set "afterCompaction": true, to start only once a
#                    running compaction ends, "startDelaySec": n, to start its agent late,
#                    or "compactAfter": n, to compact for n seconds once it settled)
#   startupUi        fire-and-forget extension UI requests (as a turn's `uiEmit`) Pi's
#                    extensions send as an RPC Pi starts, before any command
#   rejectWhileCompacting  as Pi 1.4: every prompt, steers included, sent while Pi
#                    compacts is rejected (logged as `rejected`); a prompt Pi takes up
#                    is logged as `accepted`, and compaction events as `compaction`
#
# Turn steps: {"compactFor": n} (a compaction of n seconds, taking aborts and rejecting
# every prompt as Pi 1.4 does),
# {"text": s[, "usage": {...}]}, {"thinking": s}, {"tool": name, "args": {},
# "output": s} (HAL-C2's extension gate first: see `allowed`), {"select": {"title",
# "options"}} (waits for the answer, then says it), {"event": {...}} (sent as is),
# {"mcp": {"name", "arguments"}} (a HAL-C2 MCP tool call), {"waitAbort": true} (until an
# abort, or a steer prompt, which it answers), {"settleOnSteer": true | n} (until an abort,
# or n steer prompts, which reach Pi only once this run has settled, in the order of their
# text, and each start a run of its own), {"exit": code}. While a turn waits, a steer saying "refuse" is rejected, and
# one saying "vanish" makes Pi exit before answering it; one saying "hold" is taken in
# but not answered while the turn waits (its next model call never comes); one saying "decline" is rejected,
# and one saying "ignore" never answered, only once it reaches Pi after the run settled.
# Without a match the reply names the conversation so far.
import json, os, select, sys, threading, time, urllib.request, uuid

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


SEND_LOCK = threading.Lock()

# While a compaction runs, `get_state` calls Pi compacting: between the
# compaction events a turn scripts, or while a slow `/compact` is out (from
# its call to its answer, counted apart so scripted events do not end it).
compacting = [False]
compacts_out = [0]


def is_compacting():
    return compacting[0] or compacts_out[0] > 0


COMPACTING_ERROR = ("Cannot submit a prompt while compaction is in progress. "
                    "Wait for compaction to finish and retry.")


def send(msg):
    if msg.get("type") == "compaction_start":
        compacting[0] = True
        log({"compaction": "start"})
    elif msg.get("type") == "compaction_end":
        compacting[0] = False
        log({"compaction": "end"})
    # Unescaped, as Pi writes UTF-8: a U+2028 in a text travels literally.
    with SEND_LOCK:
        sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
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


def load_name(path):
    try:
        with open(path) as f:
            return json.load(f).get("name")
    except (OSError, ValueError):
        return None


class Session:
    def __init__(self, path, entries, name=None):
        self.path, self.entries, self.name = path, entries, name

    def save(self):
        if self.path and self.path.endswith(".jsonl"):
            header = {"type": "session", "version": 3, "id": os.path.basename(self.path)[20:-6],
                      "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "cwd": os.getcwd()}
            with open(self.path, "w") as f:
                for line in [header] + self.entries:
                    f.write(json.dumps(line) + "\n")
        elif self.path:
            with open(self.path, "w") as f:
                json.dump({"entries": self.entries, "name": self.name}, f)

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
    if cfg.get("versionDelaySec"):
        time.sleep(float(cfg["versionDelaySec"]))
    print(cfg.get("version", "0.80.5"))
    sys.exit(int(cfg.get("versionExit", 0)))

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
settled_sent = False
delayed_once = set()
backlog = []
ui_answers = {}
aborted = [False]

# What Pi's extensions say at `session_start` (HAL-C2's, in a folder Pi does not trust).
for notice in [] if "--no-session" in sys.argv else cfg.get("startupUi") or []:
    request = dict(notice, type="extension_ui_request", id="ui-%s" % uuid.uuid4().hex[:8])
    log({"ui": request})
    send(request)


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


def rejected(msg, compacting=False):
    """Pi 1.4 turns a prompt back while it compacts (`compacting`: it is, mid-turn)."""
    if msg.get("type") == "prompt" and (compacting or (
            config().get("rejectWhileCompacting") and is_compacting())):
        log({"rejected": msg.get("message")})
        respond(msg, error=COMPACTING_ERROR)
        return True
    return False


def wait_for(pred):
    """Reads until `pred(msg)`: dialog answers and aborts are noted, other commands answered."""
    while True:
        msg = read()
        kind = msg.get("type")
        if kind == "abort":
            aborted[0] = True
        elif kind == "extension_ui_response":
            ui_answers[msg.get("id")] = msg
        elif rejected(msg):
            continue
        elif kind != "prompt":
            command(msg)
        elif steer(msg) and "refuse" in msg.get("message", ""):
            # A steer saying "refuse" is rejected before Pi accepts it.
            respond(msg, error="Pi cannot take this message now")
            continue
        elif steer(msg) and "vanish" in msg.get("message", ""):
            # Pi exits with a steer it has not answered.
            os._exit(1)
        elif steer(msg) and "hold" in msg.get("message", ""):
            # Pi took the steer in but its next model call has not come: no answer yet.
            continue
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


def matching_turn(cfg, text):
    for turn in cfg.get("turns") or []:
        if turn.get("match", "") in text:
            return turn
    return {}


def serve_while(busy):
    # Commands keep landing (and get answered) while Pi is not yet at work
    # on a prompt; an abort ends the wait.
    while busy() and not aborted[0]:
        if backlog or select.select([sys.stdin], [], [], 0.05)[0]:
            msg = read()
            if msg.get("type") == "abort":
                aborted[0] = True
            else:
                command(msg)


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
    turn = matching_turn(cfg, text)
    if turn.get("afterCompaction"):
        # Pi starts a prompt sent while it compacts only once the compaction
        # is over: until then it shows nothing for it, and answers checks.
        serve_while(is_compacting)
    if "startDelaySec" in turn:
        # Extension hooks that run before Pi's agent starts: nothing shows,
        # and Pi reads idle, for this long.
        until = time.monotonic() + float(turn["startDelaySec"])
        serve_while(lambda: time.monotonic() < until)
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
            details = dict(step.get("details") or (
                {"exitCode": 0} if tool == "bash" and "exitCode" not in step else {}))
            tool_result = {"content": step.get("content") or [{"type": "text", "text": result}],
                           "details": details}
            if "exitCode" in step:
                where = step.get("exitWhere", "details")
                if where == "structured":
                    tool_result["structuredContent"] = {"exitCode": step["exitCode"]}
                elif where == "top":
                    tool_result["exitCode"] = step["exitCode"]
                else:
                    details["exitCode"] = step["exitCode"]
            send({"type": "tool_execution_start", "toolCallId": call_id, "toolName": tool,
                  "args": args})
            if step.get("hangInTool"):
                # The tool is still running when the abort lands; Pi then ends
                # it as an error, like a command killed mid-run.
                if not aborted[0]:
                    wait_for(lambda m: aborted[0])
                tool_result = {"content": [{"type": "text", "text": "aborted"}], "details": {}}
                send({"type": "tool_execution_end", "toolCallId": call_id, "toolName": tool,
                      "result": tool_result, "isError": True})
            else:
                send({"type": "tool_execution_end", "toolCallId": call_id, "toolName": tool,
                      "result": tool_result,
                      "isError": step.get("isError", error)})
        elif "select" in step:
            answer = dialog("select", step["select"])
            log({"ui_answer": answer})
            said.append("Picked %s." % answer.get("value"))
            send({"type": "message_update", "message": assistant("".join(said)),
                  "assistantMessageEvent": {"type": "text_delta", "delta": said[-1]}})
        elif "event" in step:
            send(step["event"])
        elif "raw" in step:
            # Output that is not part of Pi's protocol, on the protocol channel.
            sys.stdout.write(step["raw"] + "\n")
            sys.stdout.flush()
        elif "stderr" in step:
            sys.stderr.write(step["stderr"] + "\n")
            sys.stderr.flush()
        elif "bigText" in step:
            said.append("x" * int(step["bigText"]))
            send({"type": "message_update", "message": assistant("".join(said)),
                  "assistantMessageEvent": {"type": "text_delta", "delta": said[-1]}})
        elif "uiEmit" in step:
            # A fire-and-forget extension UI request (notify, terminal dressing):
            # sent with an id, but Pi does not wait for an answer.
            request = dict(step["uiEmit"], type="extension_ui_request",
                           id="ui-%s" % uuid.uuid4().hex[:8])
            log({"ui": request})
            send(request)
        elif "ui" in step and step.get("deaf"):
            # Pi stops reading before it asks: the answer cannot reach it. It stays
            # up (its output open), so the MC keeps the session and the question.
            os.close(0)
            fields = {k: v for k, v in step["ui"].items() if k != "method"}
            request = dict(fields, type="extension_ui_request",
                           id="ui-%s" % uuid.uuid4().hex[:8], method=step["ui"]["method"])
            log({"ui": request})
            send(request)
            while True:
                time.sleep(60)
        elif "ui" in step:
            fields = {k: v for k, v in step["ui"].items() if k != "method"}
            answer = dialog(step["ui"]["method"], fields)
            log({"ui_answer": answer})
            if "say" in step:
                value = answer.get("value", answer.get("confirmed"))
                said.append("%s%s" % (step["say"], value))
                send({"type": "message_update", "message": assistant("".join(said)),
                      "assistantMessageEvent": {"type": "text_delta", "delta": said[-1]}})
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
                    # Pi hands the steer to the model's next call, which answers it. Its
                    # session keeps what was said before, then the steer as a user message.
                    log({"accepted": msg["message"]})
                    respond(msg)
                    session.append("assistant", "".join(said))
                    session.append("user", msg["message"])
                    send({"type": "message_end", "message": assistant("".join(said))})
                    send({"type": "message_start", "message": {"role": "assistant"}})
                    said = ["steered: " + msg["message"]]
                    send({"type": "message_update", "message": assistant(said[0]),
                          "assistantMessageEvent": {"type": "text_delta", "delta": said[0]}})
        elif "settleOnSteer" in step:
            steers = []
            while not aborted[0] and len(steers) < int(step["settleOnSteer"]):
                msg = wait_for(lambda m: m.get("type") == "abort" or steer(m))
                if steer(msg):
                    steers.append(msg)
            # Steers sent at once reach the fake in either order; Pi takes them by text.
            backlog.extend(sorted(steers, key=lambda m: m.get("message", "")))
            if steers:
                break
        elif "compactFor" in step:
            # Pi compacts mid-turn: an abort is noted (it does not stop the
            # compaction), and a prompt is answered as Pi answers one then.
            send({"type": "compaction_start", "reason": "threshold"})
            until = time.monotonic() + float(step["compactFor"])
            while time.monotonic() < until:
                if backlog or select.select([sys.stdin], [], [], 0.05)[0]:
                    msg = read()
                    if msg.get("type") == "abort":
                        aborted[0] = True
                    elif not rejected(msg, compacting=True):
                        command(msg)
            send({"type": "compaction_end", "aborted": False,
                  "result": {"summary": "Compacted mid-turn.", "tokensBefore": 1000,
                             "estimatedTokensAfter": 200}})
        elif "hang" in step:
            # Never answers, aborts included, until the process is stopped.
            time.sleep(3600)
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
    # Events Pi sends once a turn has settled (an extension waking or failing
    # between turns), once per process.
    if "compactAfter" in turn:
        # Pi compacts once the turn settled: its events come between turns.
        send({"type": "compaction_start", "reason": "threshold"})

        def later():
            time.sleep(float(turn["compactAfter"]))
            send({"type": "compaction_end", "aborted": False,
                  "result": {"summary": "Compacted after the turn.", "tokensBefore": 1000,
                             "estimatedTokensAfter": 200}})

        threading.Thread(target=later, daemon=True).start()
    global settled_sent
    if not settled_sent:
        settled_sent = True
        for event in config().get("settledEvents") or []:
            send(event)


def command(msg):
    kind = msg.get("type")
    cfg = config()
    delays = cfg.get("commandDelays") or {}
    if kind in delays and (kind not in (cfg.get("delayOnce") or []) or kind not in delayed_once):
        delayed_once.add(kind)
        if kind == "get_commands":
            # Pi keeps answering other commands while a slow extension holds
            # this one up.
            def later():
                time.sleep(float(delays[kind]))
                respond(msg, {"commands": config().get("commands", [])})

            threading.Thread(target=later, daemon=True).start()
            return
        time.sleep(float(delays[kind]))
    if kind in (cfg.get("exitCommands") or {}):
        sys.stdout.flush()
        os._exit(int(cfg["exitCommands"][kind]))
    if kind in (cfg.get("failCommands") or []):
        respond(msg, error=cfg.get("failMessage", "fake cannot %s" % kind))
        return
    if kind == "get_state":
        model = current_model()
        respond(msg, {"sessionFile": None if cfg.get("noSessionFile") else session.path,
                      "sessionName": session.name,
                      "thinkingLevel": state["thinking"],
                      "model": model, "isStreaming": False,
                      "isCompacting": is_compacting()})
    elif kind == "get_available_models":
        respond(msg, {"models": models()})
    elif kind == "get_commands":
        respond(msg, {"commands": cfg.get("commands", [])})
    elif kind == "switch_session":
        if cfg.get("cancelSwitch"):
            respond(msg, {"cancelled": True})
        else:
            session.path, session.entries = msg["sessionPath"], load(msg["sessionPath"])
            session.name = load_name(msg["sessionPath"])
            respond(msg, {"cancelled": False})
    elif kind == "set_session_name":
        session.name = msg.get("name")
        session.save()
        respond(msg, session.name)
    elif kind == "set_model":
        found = [m for m in models() if m["provider"] == msg.get("provider")
                 and m["id"] == msg.get("modelId")]
        if found:
            state["model"] = found[0]
            # With modelThinking configured, changing model applies that model's
            # own thinking level, as Pi applies the new model's default.
            slug = "%s/%s" % (found[0]["provider"], found[0]["id"])
            if cfg.get("modelThinking") is not None:
                state["thinking"] = cfg["modelThinking"].get(
                    slug, cfg.get("thinkingLevel", "medium"))
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
        if cfg.get("cancelFork"):
            respond(msg, {"cancelled": True})
            return
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
        if cfg.get("compactDelaySec"):
            # A compaction Pi is slow to finish: it answers later, in its own
            # thread, while other commands (an abort included) still land. A
            # delayed failure answers with the error and sends no events.
            compacts_out[0] += 1

            def later():
                time.sleep(float(cfg["compactDelaySec"]))
                if "compactError" in cfg:
                    compacts_out[0] -= 1
                    respond(msg, error=cfg["compactError"])
                    log({"compact_answered": True})
                    return
                if cfg.get("compactEvents", True):
                    send({"type": "compaction_start", "reason": "manual"})
                    send({"type": "compaction_end", "aborted": False,
                          "result": {"summary": "Compacted.", "tokensBefore": 1000,
                                     "estimatedTokensAfter": 200}})
                compacts_out[0] -= 1
                respond(msg, {"summary": "Compacted.", "tokensBefore": 1000})
                log({"compact_answered": False})

            threading.Thread(target=later, daemon=True).start()
        elif "compactError" in cfg:
            respond(msg, error=cfg["compactError"])
        else:
            if cfg.get("compactEvents", True):
                send({"type": "compaction_start", "reason": "manual"})
                send({"type": "compaction_end", "aborted": False,
                      "result": {"summary": "Compacted.", "tokensBefore": 1000,
                                 "estimatedTokensAfter": 200}})
            respond(msg, {"summary": "Compacted.", "tokensBefore": 1000})
    elif rejected(msg):
        pass
    elif kind == "prompt" and steer(msg) and "decline" in msg.get("message", ""):
        # A steer saying "decline" that reaches Pi once its run settled is rejected.
        # One also saying "after stop" is rejected only once the abort reaches Pi.
        if "after stop" in msg.get("message", "") and not aborted[0]:
            wait_for(lambda m: m.get("type") == "abort")
        respond(msg, error="Pi cannot start this message")
    elif kind == "prompt" and steer(msg) and "ignore" in msg.get("message", ""):
        # A steer saying "ignore" that reaches Pi once its run settled is never answered.
        pass
    elif kind == "prompt" and not steer(msg) and (
            any(msg.get("message", "").startswith(c) for c in cfg.get("handledCommands") or []) or
            any(msg.get("message", "").startswith(c) for c in cfg.get("silentCommands") or [])):
        # An extension command Pi handles without the agent, or a prompt Pi
        # accepts and then never reports on: the answer, and nothing else.
        respond(msg)
    elif kind == "prompt" and "promptError" in cfg:
        respond(msg, error=cfg["promptError"])
    elif kind == "prompt":
        log({"accepted": msg.get("message")})
        respond(msg)
        run_turn(msg.get("message", ""))
    elif kind in ("abort", "extension_ui_response"):
        pass
    elif msg.get("id") is not None:
        respond(msg, error="Unknown command: %s" % kind)


while True:
    command(read())
