# A configurable fake ACP agent for the provider features (`HalC2.Test.AcpFixtures`).
#
#   fake_acme_agent.py --control DIR --name NAME [--argv0 PATH] [agent args...]
#
# DIR/control.json holds each agent's behaviour under its NAME; every launch and
# request is appended to DIR/NAME.log as JSON lines, written before the answer, so
# a test reads it once the call it made has returned. A prompt's text picks what
# the turn does (see `prompt` below).
import subprocess
import base64, json, os, re, signal, sys, time

argv = sys.argv[1:]
def opt(flag, default=None):
    if flag in argv:
        i = argv.index(flag)
        value = argv[i + 1]
        del argv[i:i + 2]
        return value
    return default

DIR = opt("--control")
NAME = opt("--name")
ARGV0 = opt("--argv0", sys.argv[0])
ARGS = list(argv)
try:
    CONTROL = json.load(open(os.path.join(DIR, "control.json"))).get(NAME, {})
except FileNotFoundError:
    CONTROL = {}
AUTH_FILE = os.path.join(DIR, NAME + ".auth")
PROVIDERS_FILE = os.path.join(DIR, NAME + ".providers.json")
LOG_ENV = ["XAI_API_KEY", "ACME_MODE", "ACME_API_KEY", "OPENCODE_TOKEN"] + CONTROL.get("logEnv", [])

def log(entry):
    with open(os.path.join(DIR, NAME + ".log"), "a") as f:
        f.write(json.dumps(entry) + "\n")

log({"event": "launch", "pid": os.getpid(), "argv0": ARGV0, "args": ARGS, "cwd": os.getcwd(),
     "env": {k: os.environ[k] for k in LOG_ENV if k in os.environ}})

def signed_in():
    auth = CONTROL.get("auth")
    if auth is None:
        return True
    if auth.startswith("env:"):
        return os.environ.get(auth[4:], "") != ""
    return os.path.exists(AUTH_FILE)

# The terminal sign-in: `<agent> login` asks for a code and reports resizes.
if "login" in ARGS:
    signal.signal(signal.SIGWINCH, lambda *_: (sys.stdout.write("size %dx%d\n" % os.get_terminal_size()), sys.stdout.flush()))
    sys.stdout.write("Paste code: ")
    sys.stdout.flush()
    while True:
        try:
            code = sys.stdin.readline().strip()
            break
        except InterruptedError:
            continue
    if code == "ok":
        open(AUTH_FILE, "w").write("signed in")
        print("Signed in.")
        sys.exit(0)
    sys.exit(1)

# SIGUSR1: writes DIR/NAME.stderr to the error output and exits with code 3, mid-turn.
def crash(*_):
    try:
        sys.stderr.write(open(os.path.join(DIR, NAME + ".stderr")).read())
        sys.stderr.flush()
    finally:
        os._exit(3)
signal.signal(signal.SIGUSR1, crash)

# SIGUSR2: the background agent of a held prompt finishes, and so does the prompt.
def background_done(*_):
    global held
    if held:
        pid, sid = held
        held = None
        log({"event": "background done"})
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "bg-1", "status": "completed"})
        finish(pid, sid, "background done")
signal.signal(signal.SIGUSR2, background_done)

def send(msg):
    msg["jsonrpc"] = "2.0"
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

def update(sid, u):
    send({"method": "session/update", "params": {"sessionId": sid, "update": u}})

def say(sid, text, mid="msg-1"):
    update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": mid, "content": {"type": "text", "text": text}})

DEFAULT_MODELS = [["acme/fast", "Fast"], ["acme/smart", "Smart"]]
models = CONTROL.get("models", DEFAULT_MODELS)
model = models[0][0] if models else None

# "modes": the agent's own session modes, the first being the one it starts in.
# "keepMode": the mode stays with the session, so a restarted agent resumes in it.
modes = CONTROL.get("modes", [])
mode = modes[0] if modes else None
MODE_FILE = os.path.join(DIR, NAME + ".mode")
if CONTROL.get("keepMode") and os.path.exists(MODE_FILE):
    mode = open(MODE_FILE).read()

# "legacyModes": older ACP session modes (`modes`, set by session/set_mode).
legacy_modes = CONTROL.get("legacyModes", [])
legacy_mode = legacy_modes[0] if legacy_modes else None

# "sessionOptions": more configOptions, as given; a set one keeps its new value.
extra_options = [dict(o) for o in CONTROL.get("sessionOptions", [])]

def config_options():
    options = []
    if models and not CONTROL.get("legacyModels"):
        options.append({"id": "model", "name": "Model", "type": "select", "currentValue": model,
                        "options": [{"value": v, "name": n} for v, n in models]})
    if modes:
        options.append({"id": "mode", "name": "Mode", "category": "mode", "type": "select",
                        "currentValue": mode, "options": [{"value": v, "name": v} for v in modes]})
    return options + extra_options

def providers():
    try:
        return json.load(open(PROVIDERS_FILE))
    except FileNotFoundError:
        return CONTROL.get("providers", [
            {"providerId": "openai", "supported": ["openai"], "required": True,
             "current": {"apiType": "openai", "baseUrl": "https://api.openai.com/v1"}},
            {"providerId": "openrouter", "supported": ["openai"], "required": False,
             "current": {"apiType": "openai", "baseUrl": "https://openrouter.ai/api/v1"}}])

def save_providers(value):
    json.dump(value, open(PROVIDERS_FILE, "w"))

sessions = 0
# With `loseSessions`, a launch that finds DIR/NAME.lost (which it removes) cannot
# resume or load a session an earlier launch made.
LOST_FILE = os.path.join(DIR, NAME + ".lost")
lost = bool(CONTROL.get("loseSessions")) and os.path.exists(LOST_FILE)
if lost:
    os.remove(LOST_FILE)
mine = set()
held = None          # a prompt held until session/cancel: (id, session)
asked = {}           # our request id -> (kind, prompt id, session)
answers = {}         # replies collected for a "read file" turn
authenticating = None

def mode_entry(m):
    # `modeDescriptions` may hold null, as some agents send.
    entry = {"id": m, "name": m.capitalize()}
    if m in CONTROL.get("modeDescriptions", {}):
        entry["description"] = CONTROL["modeDescriptions"][m]
    return entry

def finish(pid, sid, text, reason="end_turn"):
    if text:
        say(sid, text, "msg-%d-%s" % (os.getpid(), pid))
    send({"id": pid, "result": {"stopReason": reason}})

def title_json(text):
    keys = re.search(r"Return a JSON object with keys?: ([A-Za-z, ]+)\.", text)
    keys = [k.strip() for k in keys.group(1).split(",")] if keys else ["title", "needsRefinement"]
    return json.dumps({k: (False if k == "needsRefinement" else "%s %s" % (NAME, k)) for k in keys})

def prompt(pid, sid, text):
    global held
    # Closes its output and keeps running, deaf to its input (upstream #21323).
    if "close output" in text and "<conversation_history>" not in text:
        log({"event": "closed", "at": time.time()})
        sys.stdout.close()
        os.close(1)
        signal.signal(signal.SIGTERM, lambda *_: (log({"event": "signalled", "signal": "TERM"}), sys.exit(143)))
        time.sleep(60)
        sys.exit(0)
    # "fail without a code": answers the prompt with an error that has no JSON-RPC code.
    if "fail without a code" in text:
        return send({"id": pid, "error": {"message": "Prompt refused"}})
    # "crash": writes control's "stderr" to its error output and exits with "exitCode".
    if "crash" in text:
        sys.stderr.write(CONTROL.get("stderr", ""))
        sys.stderr.flush()
        os._exit(CONTROL.get("exitCode", 1))
    if "Return a JSON object" in text or "Return JSON with keys" in text:
        return finish(pid, sid, "Here it is: " + title_json(text))
    # "start a helper": runs a helper that exits at once, so its pid is free for reuse.
    if "start a helper" in text and "<conversation_history>" not in text:
        helper = subprocess.Popen(["true"])
        helper.wait()
        log({"event": "helper", "pid": helper.pid, "pgid": os.getpgrp()})
        finish(pid, sid, "helper done")
        return
    # "start a background agent": one works on, holding the prompt until SIGUSR2.
    if "start a background agent" in text and "<conversation_history>" not in text:
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "bg-1", "title": "Background agent",
                     "kind": "other", "status": "in_progress"})
        held = (pid, sid)
        return
    if "wait" in text:
        held = (pid, sid)
        return
    if "approve" in text or "edit file" in text:
        edit = "edit file" in text
        asked["perm-%s" % pid] = ("permission", pid, sid)
        call = {"toolCallId": "call-%s" % pid, "title": "edit a.txt" if edit else "ls",
                "kind": "edit" if edit else "execute",
                "rawInput": {"path": "a.txt"} if edit else {"command": "ls"}}
        update(sid, dict(call, sessionUpdate="tool_call", status="pending"))
        send({"id": "perm-%s" % pid, "method": "session/request_permission", "params": {"sessionId": sid,
              "toolCall": call,
              "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                          {"optionId": "deny", "name": "Deny", "kind": "reject_once"}]}})
        return
    if "open bad url" in text:
        send({"id": "url-bad", "method": "elicitation/create", "params": {"mode": "url",
              "url": "file:///etc/passwd", "elicitationId": "bad", "message": "Sign in to Acme"}})
        return finish(pid, sid, "asked for bad")
    if "open anonymous url" in text:
        send({"id": "url-anon", "method": "elicitation/create", "params": {"mode": "url",
              "url": "https://acme.test/anon", "elicitationId": "", "message": "Sign in to Acme"}})
        return finish(pid, sid, "asked for anon")
    if "open long url" in text:
        send({"id": "url-long", "method": "elicitation/create", "params": {"mode": "url",
              "url": "https://acme.test/long", "elicitationId": "x" * 300, "message": "m" * 2000}})
        return finish(pid, sid, "asked for long")
    m = re.search(r"open url (\S+)", text)
    if m:
        send({"id": "url-" + m.group(1), "method": "elicitation/create", "params": {"mode": "url",
              "url": "https://acme.test/" + m.group(1), "elicitationId": m.group(1), "message": "Sign in to Acme"}})
        return finish(pid, sid, "asked for " + m.group(1))
    # "say N characters": one text update that long.
    m = re.search(r"say (\d+) characters", text)
    if m and "<conversation_history>" not in text:
        say(sid, "x" * int(m.group(1)), "long-%s" % pid)
        return finish(pid, sid, "")
    # "updates [...]": sends each session update as given, then ends the turn.
    m = re.search(r"updates (\[.*\])", text)
    if m and "<conversation_history>" not in text:
        for u in json.loads(m.group(1)):
            update(sid, u)
        return finish(pid, sid, "")
    m = re.search(r"ask (\S+) (\{.*\})", text)
    if m:
        # One client request; the turn ends with its answer.
        asked["ask-%s" % pid] = ("ask", pid, sid)
        send({"id": "ask-%s" % pid, "method": m.group(1),
              "params": dict(json.loads(m.group(2)), sessionId=sid)})
        return
    if "read file" in text:
        # A file outside the workspace, and a terminal.
        answers[pid] = {}
        asked["fs-%s" % pid] = ("fs", pid, sid)
        asked["term-%s" % pid] = ("terminal", pid, sid)
        send({"id": "fs-%s" % pid, "method": "fs/read_text_file", "params": {"sessionId": sid, "path": "/etc/hosts"}})
        send({"id": "term-%s" % pid, "method": "terminal/create", "params": {"sessionId": sid, "command": "ls"}})
        return
    m = re.search(r"change and read (\S+)", text)
    if m:
        # Asks to edit a file, and while that waits reads a workspace file.
        asked["perm-%s" % pid] = ("permission", pid, sid)
        asked["read-%s" % pid] = ("read", pid, sid)
        call = {"toolCallId": "call-%s" % pid, "title": "edit a.txt", "kind": "edit", "rawInput": {"path": "a.txt"}}
        update(sid, dict(call, sessionUpdate="tool_call", status="pending"))
        send({"id": "perm-%s" % pid, "method": "session/request_permission", "params": {"sessionId": sid,
              "toolCall": call,
              "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                          {"optionId": "deny", "name": "Deny", "kind": "reject_once"}]}})
        send({"id": "read-%s" % pid, "method": "fs/read_text_file",
              "params": {"sessionId": sid, "path": os.path.join(os.getcwd(), m.group(1))}})
        return
    if "own terminal" in text:
        # ACP v2: a command in a terminal the agent owns, its output in two chunks.
        b64 = lambda s: base64.b64encode(s.encode()).decode()
        update(sid, {"sessionUpdate": "terminal_update", "terminalId": "term-1", "command": "npm test",
                     "cwd": os.getcwd()})
        update(sid, {"sessionUpdate": "terminal_output_chunk", "terminalId": "term-1", "data": b64("running 2 tests\n")})
        update(sid, {"sessionUpdate": "terminal_output_chunk", "terminalId": "term-1", "data": b64("1 failed\n")})
        update(sid, {"sessionUpdate": "terminal_update", "terminalId": "term-1", "exitStatus": {"exitCode": 1}})
        return finish(pid, sid, "ran it")
    if "withdraw commands" in text and "<conversation_history>" not in text:
        update(sid, {"sessionUpdate": "available_commands_update", "availableCommands": []})
        return finish(pid, sid, "no commands")
    if "offer commands" in text:
        update(sid, {"sessionUpdate": "available_commands_update", "availableCommands": CONTROL.get("commands", [])})
        held = (pid, sid)
        return
    m = re.search(r"write (\S+)", text)
    if m:
        with open(os.path.join(os.getcwd(), m.group(1)), "w") as f:
            f.write(text + "\n")
        return finish(pid, sid, "wrote " + m.group(1))
    if "which model" in text:
        # A session handed the thread so far says how many turns it was given.
        handed = text.count("User: which model") if "<conversation_history>" in text else 0
        return finish(pid, sid, "model: %s" % model + (" with %d earlier turns" % handed if handed else ""))
    if "report" in text:
        return finish(pid, sid, json.dumps({"argv0": ARGV0, "args": ARGS, "session": sid, "model": model,
                      "env": {k: os.environ[k] for k in LOG_ENV if k in os.environ}}))
    if "plan" in text:
        update(sid, {"sessionUpdate": "plan", "entries": [
            {"content": "Read the code", "priority": "high", "status": "completed"},
            {"content": "Fix the bug", "priority": "high", "status": "in_progress"}]})
        update(sid, {"sessionUpdate": "usage_update", "used": 1200, "size": 200000})
        return finish(pid, sid, "planned")
    if "new model" in text:
        models.append(["acme/huge", "Huge"])
        update(sid, {"sessionUpdate": "config_option_update", "configOptions": config_options()})
        return finish(pid, sid, "added a model")
    if "image" in text:
        update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "msg-1",
                     "content": {"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="}})
        return finish(pid, sid, "")
    finish(pid, sid, "Hello from %s" % NAME)

def initialize_result():
    caps = {"loadSession": True, "sessionCapabilities": {"resume": {}, "list": {}, "delete": {}}}
    if CONTROL.get("providerConfig", True):
        caps["providers"] = {}
    if CONTROL.get("logout", True):
        caps["auth"] = {"logout": {}}
    return {"protocolVersion": CONTROL.get("protocolVersion", 1), "agentInfo": {"name": NAME, "version": CONTROL.get("version", "1.2.3")},
            "authMethods": CONTROL.get("methods", []), "agentCapabilities": caps}

for line in sys.stdin:
    msg = json.loads(line)
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    log({"event": "request" if method else "response", "method": method, "id": mid,
         "params": params, "result": msg.get("result"), "error": msg.get("error")})

    # Requests left unanswered, or answered with an error.
    if method in CONTROL.get("silent", []):
        continue
    if method in CONTROL.get("fail", []):
        send({"id": mid, "error": {"code": -32603, "message": "acme could not do " + method}})
        continue

    if method is None:
        kind, pid, sid = asked.pop(mid, (None, None, None))
        if mid == "auth-url":
            if (msg.get("result") or {}).get("action") == "accept":
                open(AUTH_FILE, "w").write("signed in")
                send({"id": authenticating, "result": {}})
            else:
                send({"id": authenticating, "error": {"code": -32000, "message": "declined"}})
        elif kind == "permission":
            allowed = msg["result"]["outcome"].get("optionId") == "allow"
            finish(pid, sid, "allowed" if allowed else "denied")
        elif kind == "ask":
            finish(pid, sid, "answer: %s" % json.dumps(msg.get("result") or msg.get("error")))
        elif kind == "read":
            say(sid, "read: %s\n\n" % json.dumps(msg.get("result") or msg.get("error")), "read-%s" % pid)
        elif kind in ("fs", "terminal"):
            err = msg.get("error") or {}
            answers[pid][kind] = "%s %s" % (err.get("code"), err.get("message"))
            if len(answers[pid]) == 2:
                got = answers.pop(pid)
                finish(pid, sid, "fs: %s; terminal: %s" % (got["fs"], got["terminal"]))
        continue

    if method == "initialize":
        send({"id": mid, "result": initialize_result()})
    elif method == "authenticate":
        failure = CONTROL.get("authenticateError")
        if failure:
            send({"id": mid, "error": {"code": -32000, "message": failure}})
        else:
            authenticating = mid
            send({"id": "auth-url", "method": "elicitation/create", "params": {"mode": "url",
                  "url": "https://acme.test/login", "elicitationId": "login-1", "message": "Sign in to Acme"}})
    elif method in ("session/new", "session/resume", "session/load") and not signed_in():
        send({"id": mid, "error": {"code": -32000, "message": "Authentication required"}})
    elif method == "session/new" and CONTROL.get("sessionError"):
        send({"id": mid, "error": {"code": -32000, "message": CONTROL["sessionError"]}})
    elif method in ("session/resume", "session/load") and lost and params.get("sessionId") not in mine:
        send({"id": mid, "error": {"code": -32002, "message": "Session not found"}})
    elif method in ("session/new", "session/resume", "session/load"):
        sessions += 1
        sid = params.get("sessionId") or "%s-%d-%d" % (NAME, os.getpid(), sessions)
        mine.add(sid)
        result = {"configOptions": config_options()}
        if CONTROL.get("legacyModels") and not (method != "session/new" and CONTROL.get("resumeWithoutModels")):
            result["models"] = {"currentModelId": model,
                                "availableModels": [{"modelId": v, "name": n} for v, n in models]}
        if legacy_modes:
            result["modes"] = {"currentModeId": legacy_mode,
                               "availableModes": [mode_entry(m) for m in legacy_modes]}
        if method == "session/new":
            result["sessionId"] = sid
        send({"id": mid, "result": result})
    elif method == "session/set_mode" and legacy_modes:
        legacy_mode = params["modeId"]
        send({"id": mid, "result": {}})
    elif method == "session/set_config_option":
        if CONTROL.get("legacyModels") and params.get("configId") == "model":
            send({"id": mid, "error": {"code": -32601, "message": "Use session/set_model"}})
            continue
        if params.get("configId") == "model":
            model = params["value"]
        if params.get("configId") == "mode":
            mode = params["value"]
            if CONTROL.get("keepMode"):
                open(MODE_FILE, "w").write(mode)
        for option in extra_options:
            if option.get("id") == params.get("configId"):
                option["currentValue"] = params["value"]
        send({"id": mid, "result": {"configOptions": config_options()}})
    elif method == "session/set_model" and CONTROL.get("legacyModels"):
        model = params["modelId"]
        send({"id": mid, "result": {}})
    elif method == "session/prompt":
        prompt(mid, params["sessionId"], "\n".join(b.get("text", "") for b in params["prompt"]))
    elif method == "session/cancel":
        if held:
            send({"id": held[0], "result": {"stopReason": "cancelled"}})
            held = None
    elif method == "session/list":
        # `sessions`, `pageSize` at a time; the cursor is where the next page starts.
        listed = CONTROL.get("sessions", [])
        start = int(params.get("cursor") or 0)
        size = CONTROL.get("pageSize", len(listed) or 1)
        more = start + size < len(listed)
        send({"id": mid, "result": {"nextCursor": str(start + size) if more else None,
                                    "sessions": listed[start:start + size]}})
    elif method == "session/delete":
        send({"id": mid, "result": {}})
    elif method == "providers/list":
        send({"id": mid, "result": {"providers": providers()}})
    elif method == "providers/set":
        current = providers()
        for p in current:
            if p["providerId"] == params.get("providerId"):
                p["current"] = {"apiType": params.get("apiType"), "baseUrl": params.get("baseUrl"),
                                "headers": params.get("headers") or {}}
        save_providers(current)
        send({"id": mid, "result": {}})
    elif method == "providers/disable":
        save_providers([dict(p, current=None) if p["providerId"] == params.get("providerId") else p
                        for p in providers()])
        send({"id": mid, "result": {}})
    elif method == "logout":
        if os.path.exists(AUTH_FILE):
            os.remove(AUTH_FILE)
        send({"id": mid, "result": {}})
    elif mid is not None:
        send({"id": mid, "error": {"code": -32601, "message": method}})
