# A configurable fake ACP agent for the provider features (`HalC2.Test.AcpFixtures`).
#
#   fake_acme_agent.py --control DIR --name NAME [--argv0 PATH] [agent args...]
#
# DIR/control.json holds each agent's behaviour under its NAME; every launch and
# request is appended to DIR/NAME.log as JSON lines, written before the answer, so
# a test reads it once the call it made has returned. A prompt's text picks what
# the turn does (see `prompt` below).
import json, os, re, signal, sys

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

log({"event": "launch", "argv0": ARGV0, "args": ARGS, "cwd": os.getcwd(),
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

def config_options():
    if not models:
        return []
    return [{"id": "model", "name": "Model", "type": "select", "currentValue": model,
             "options": [{"value": v, "name": n} for v, n in models]}]

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
held = None          # a prompt held until session/cancel: (id, session)
asked = {}           # our request id -> (kind, prompt id, session)
answers = {}         # replies collected for a "read file" turn
authenticating = None

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
    if "Return a JSON object" in text or "Return JSON with keys" in text:
        return finish(pid, sid, "Here it is: " + title_json(text))
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
    m = re.search(r"open url (\S+)", text)
    if m:
        send({"id": "url-" + m.group(1), "method": "elicitation/create", "params": {"mode": "url",
              "url": "https://acme.test/" + m.group(1), "elicitationId": m.group(1), "message": "Sign in to Acme"}})
        return finish(pid, sid, "asked for " + m.group(1))
    if "read file" in text:
        answers[pid] = {}
        asked["fs-%s" % pid] = ("fs", pid, sid)
        asked["term-%s" % pid] = ("terminal", pid, sid)
        send({"id": "fs-%s" % pid, "method": "fs/read_text_file", "params": {"sessionId": sid, "path": "README.md"}})
        send({"id": "term-%s" % pid, "method": "terminal/create", "params": {"sessionId": sid, "command": "ls"}})
        return
    m = re.search(r"write (\S+)", text)
    if m:
        with open(os.path.join(os.getcwd(), m.group(1)), "w") as f:
            f.write(text + "\n")
        return finish(pid, sid, "wrote " + m.group(1))
    if "which model" in text:
        return finish(pid, sid, "model: %s" % model)
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
    caps = {"loadSession": True, "sessionCapabilities": {"resume": {}, "list": {}, "delete": {}},
            "providers": {}}
    if CONTROL.get("logout", True):
        caps["auth"] = {"logout": {}}
    return {"protocolVersion": 1, "agentInfo": {"name": NAME, "version": CONTROL.get("version", "1.2.3")},
            "authMethods": CONTROL.get("methods", []), "agentCapabilities": caps}

for line in sys.stdin:
    msg = json.loads(line)
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    log({"event": "request" if method else "response", "method": method, "id": mid,
         "params": params, "result": msg.get("result"), "error": msg.get("error")})

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
    elif method in ("session/new", "session/resume", "session/load"):
        sessions += 1
        sid = params.get("sessionId") or "%s-%d-%d" % (NAME, os.getpid(), sessions)
        result = {"configOptions": config_options()}
        if method == "session/new":
            result["sessionId"] = sid
        send({"id": mid, "result": result})
    elif method == "session/set_config_option":
        if params.get("configId") == "model":
            model = params["value"]
        send({"id": mid, "result": {"configOptions": config_options()}})
    elif method == "session/prompt":
        prompt(mid, params["sessionId"], "\n".join(b.get("text", "") for b in params["prompt"]))
    elif method == "session/cancel":
        if held:
            send({"id": held[0], "result": {"stopReason": "cancelled"}})
            held = None
    elif method == "session/list":
        send({"id": mid, "result": {"nextCursor": None, "sessions": []}})
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
