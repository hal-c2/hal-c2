# A scriptable fake `muse` for the Muse Code feature: `--version` and `serve`, which
# speaks the Muse Session Protocol (JSON-RPC 2.0 lines on stdio). FAKE_DIR holds
# `config.json` (read on every command, so a step can change it between turns) and
# gets `log.jsonl`: one `start` line (argv, cwd, pid, selected environment), then
# every message received (`recv`). Sessions are JSON files under FAKE_DIR/sessions:
# `{"history": [user texts], "approvalMode", "modelId"}`.
#
# config.json:
#   version   `muse --version` (default "1.4.7")
#   versionExit  `muse --version`'s exit status (default 0)
#   models    model/list's models (default one Meta model, fake/one)
#   turns     [{"match": substring, "steps": [...]}], first match wins
#   mismatch  "session/start", "session/resume" or "turn/start": answered under another id
#
# Turn steps: {"text": s}, {"shell": command} and {"edit": path} (asked first unless
# the session allows all; a decline skips the tool; "requirements": n on a shell step
# asks n times, each approval answered by approval/updated naming the next one), {"question": {"header",
# "question", "options"}} (waits for the answer, then says it), {"usage": {...}}
# (session/tokenUsage), {"contextAfter": {"usedTokens", "windowTokens"}} (session/contextUsage
# once the turn has completed), {"childShell": command} (a workflow child asks, offering
# no way to approve), {"waitInterrupt": true} (until turn/interrupt, or a
# turn/steer, which it answers with "steered: <text>"). Without a match the reply names the conversation so
# far.
import json, os, queue, sys, threading, uuid

DIR = os.environ["FAKE_DIR"]
LOG = os.path.join(DIR, "log.jsonl")
CONFIG = os.path.join(DIR, "config.json")
SESSIONS = os.path.join(DIR, "sessions")
ENV_PREFIXES = ("MUSE_", "META_", "HAL_C2_", "FAKE_")
WRITE = threading.Lock()


def log(entry):
    with WRITE:
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")


def config():
    try:
        with open(CONFIG) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def send(msg):
    msg["jsonrpc"] = "2.0"
    with WRITE:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()


def notify(method, params):
    send({"method": method, "params": params})


def session_path(sid):
    return os.path.join(SESSIONS, sid + ".json")


def load_session(sid):
    try:
        with open(session_path(sid)) as f:
            return json.load(f)
    except OSError:
        return None


def save_session(sid, session):
    os.makedirs(SESSIONS, exist_ok=True)
    with open(session_path(sid), "w") as f:
        json.dump(session, f)


if "--version" in sys.argv:
    print("muse " + config().get("version", "1.4.7"))
    sys.exit(config().get("versionExit", 0))

log({"start": {
    "argv": sys.argv[1:],
    "cwd": os.getcwd(),
    "pid": os.getpid(),
    "env": {k: v for k, v in os.environ.items() if k.startswith(ENV_PREFIXES)},
}})

state = {"session": None, "turn": None}
# What the running turn waits on: decisions, answers, interrupts and steers.
events = queue.Queue()
# Approvals with requirements still to come: approvalId -> [request, how many].
requirements = {}


def item(turn, kind, status, revision, **fields):
    return dict(fields, itemId=fields.get("itemId") or "item-" + uuid.uuid4().hex[:8],
                turnId=turn, kind=kind, status=status, revision=revision)


def emit_item(sid, method, it):
    notify(method, {"sessionId": sid, "item": it})


def say(sid, turn, text):
    it = item(turn, "agentMessage", "inProgress", 1, text="")
    emit_item(sid, "item/started", it)
    notify("item/delta", {"sessionId": sid, "itemId": it["itemId"], "field": "text", "delta": text})
    emit_item(sid, "item/completed", dict(it, status="completed", revision=2, text=text))


def wait(kinds):
    while True:
        event = events.get()
        if event[0] in kinds:
            return event


def ask(sid, turn, subject, choices, origin=None, count=1):
    approval = "approval-" + uuid.uuid4().hex[:8]
    request = {
        "sessionId": sid, "turnId": turn, "approvalId": approval,
        "currentRequirementId": "req-1", "subject": subject, "availableChoices": choices,
    }
    if origin:
        request["subagentOrigin"] = origin
    requirements[approval] = [request, count]
    notify("approval/requested", request)
    event = wait(("decide", "interrupt"))
    if event[0] == "interrupt":
        return None
    choice = next(c for c in choices if c["choiceId"] == event[1]["choiceId"])
    notify("approval/resolved", {"sessionId": sid, "approvalId": approval, "decision": choice["decision"]})
    return choice["decision"].startswith("approved")


def tool(sid, turn, name, args, output, approved):
    status = "completed" if approved else "declined"
    it = item(turn, "toolCall", "inProgress", 1, tool=name, args=json.dumps(args))
    emit_item(sid, "item/started", it)
    emit_item(sid, "item/completed", dict(it, status=status, revision=2,
                                          visibleOutput=output if approved else None))


def run_turn(sid, turn, text, params):
    session = load_session(sid)
    history = session["history"]
    session["history"] = history + [text]
    save_session(sid, session)
    allow = session.get("approvalMode") == "allowAll"
    notify("turn/started", {"sessionId": sid, "turnId": turn})
    steps = next((t["steps"] for t in config().get("turns", []) if t["match"] in text), None)
    if steps is None:
        steps = [{"text": "Reply to %s after [%s]" % (text, " | ".join(history))}]
    terminal = "completed"
    after = []
    for step in steps:
        if "text" in step:
            say(sid, turn, step["text"])
        elif "shell" in step:
            approved = allow or ask(sid, turn, {"kind": "shell", "command": step["shell"]}, [
                {"choiceId": "once", "decision": "approved", "scope": "once"},
                {"choiceId": "session", "decision": "approvedForSession", "scope": "session"},
                {"choiceId": "reject", "decision": "abort", "scope": "once"},
            ], count=step.get("requirements", 1))
            if approved is None:
                terminal = "cancelled"
                break
            log({"tool": {"name": "shell", "approved": approved, "asked": not allow}})
            tool(sid, turn, "shell", {"command": step["shell"]}, "ok", approved)
        elif "edit" in step:
            approved = allow or ask(sid, turn, {"kind": "fileAccess", "access": "write", "path": step["edit"]}, [
                {"choiceId": "allow", "decision": "approved", "scope": "once"},
                {"choiceId": "deny", "decision": "denied", "scope": "once"},
            ])
            if approved is None:
                terminal = "cancelled"
                break
            log({"tool": {"name": "edit", "approved": approved, "asked": not allow}})
            tool(sid, turn, "edit", {"file_path": step["edit"], "content": "edited"}, "edited", approved)
        elif "question" in step:
            q = step["question"]
            notify("userInput/requested", {
                "sessionId": sid, "turnId": turn, "userInputId": "input-1",
                "questions": [{"id": "q1", "header": q.get("header"), "question": q["question"],
                               "options": [{"label": o} for o in q["options"]],
                               "selection": {"mode": "single"}}],
            })
            event = wait(("answer", "interrupt"))
            if event[0] == "interrupt":
                terminal = "cancelled"
                break
            answer = event[1]["answers"][0]
            notify("userInput/settled", {"sessionId": sid, "userInputId": "input-1"})
            say(sid, turn, "Picked %s." % (answer.get("selectedLabel") or answer.get("freeText")))
        elif "childShell" in step:
            approved = ask(sid, turn, {"kind": "shell", "command": step["childShell"]},
                           [{"choiceId": "reject", "decision": "abort", "scope": "once"}],
                           {"agentId": "child-1"})
            if approved is None:
                terminal = "cancelled"
                break
            log({"tool": {"name": "shell", "approved": approved, "asked": True}})
        elif "contextAfter" in step:
            after.append(step["contextAfter"])
        elif "usage" in step:
            notify("session/tokenUsage", {"sessionId": sid, "turnId": turn, "usage": step["usage"]})
        elif "waitInterrupt" in step:
            event = wait(("interrupt", "steer"))
            if event[0] == "interrupt":
                terminal = "cancelled"
                break
            say(sid, turn, "steered: " + event[1])
    notify("turn/completed", {"sessionId": sid, "turnId": turn, "terminal": terminal})
    for usage in after:
        notify("session/contextUsage", dict(usage, sessionId=sid))
    state["turn"] = None


def compact(sid, command):
    it = item(command, "compaction", "inProgress", 1)
    emit_item(sid, "item/started", it)
    emit_item(sid, "item/completed", dict(it, status="completed", revision=2, outcome="compacted"))


def handle(msg):
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")

    def reply(result):
        send({"id": mid, "result": result})

    def error(code, message, data=None):
        send({"id": mid, "error": {"code": code, "message": message, "data": data}})

    if mid is None:
        return
    sid = state["session"]

    def answered(id):
        return "other-" + id if config().get("mismatch") == method else id

    if method == "initialize":
        requested = params.get("capabilities", {}).get("requestedCapabilities", [])
        reply({"schema": {"version": 1}, "grantedCapabilities": requested})
    elif method == "model/list":
        models = config().get("models", [{"modelId": "fake/one", "providerId": "meta",
                                          "displayLabel": "Fake One", "isDefault": True}])
        reply({"models": models, "providerId": "meta", "source": "fake"})
    elif method == "session/start":
        sid = params["sessionId"]
        state["session"] = sid
        save_session(sid, {"history": [], "approvalMode": params.get("approvalMode"),
                           "modelId": params.get("modelId") or "fake/one"})
        reply({"session": {"sessionId": answered(sid), "modelId": params.get("modelId") or "fake/one"}})
    elif method == "session/resume":
        session = load_session(params["sessionId"])
        if session is None:
            return error(-32004, "session not found", {"kind": "sessionNotFound"})
        state["session"] = params["sessionId"]
        reply({"session": {"sessionId": answered(params["sessionId"]), "modelId": session.get("modelId")}})
    elif method == "session/setApprovalMode":
        session = load_session(sid)
        session["approvalMode"] = params["mode"]
        save_session(sid, session)
        reply({})
    elif method == "session/setModel":
        session = load_session(sid)
        session["modelId"] = params["model"]["modelId"]
        save_session(sid, session)
        reply({})
    elif method == "turn/start":
        turn = params["commandId"]
        state["turn"] = turn
        while not events.empty():
            events.get()
        text = "".join(p.get("text", "") for p in params["input"] if p["type"] == "text")
        reply({"commandId": turn, "turnId": answered(turn), "status": "accepted", "disposition": "started"})
        threading.Thread(target=run_turn, args=(sid, turn, text, params), daemon=True).start()
    elif method == "turn/steer":
        if state["turn"] != params.get("expectedTurnId"):
            return error(-32010, "no such turn")
        text = "".join(p.get("text", "") for p in params["input"] if p["type"] == "text")
        reply({"turnId": state["turn"]})
        events.put(("steer", text))
    elif method == "turn/interrupt":
        reply({})
        if state["turn"] == params.get("turnId"):
            events.put(("interrupt",))
    elif method == "approval/decide":
        request, count = requirements.get(params.get("approvalId"), (None, 1))
        if request and params.get("requirementId") != request["currentRequirementId"]:
            return error(-32011, "not the current requirement")
        choice = request and next(c for c in request["availableChoices"]
                                  if c["choiceId"] == params["choiceId"])
        if count > 1 and choice["decision"].startswith("approved"):
            # The next requirement goes out before the decision is acknowledged.
            request = dict(request, currentRequirementId="req-%d" % (int(request["currentRequirementId"][4:]) + 1))
            requirements[params["approvalId"]] = [request, count - 1]
            notify("approval/updated", request)
            return reply({})
        requirements.pop(params.get("approvalId"), None)
        reply({})
        events.put(("decide", params))
    elif method == "userInput/answer":
        reply({})
        events.put(("answer", params))
    elif method == "session/compact":
        reply({"status": "accepted"})
        compact(sid, params["commandId"])
    else:
        error(-32601, "method not found: %s" % method)


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    log({"recv": msg})
    handle(msg)
