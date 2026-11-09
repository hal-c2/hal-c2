# A scriptable fake ACP agent (Grok, OpenCode, Pi's adapter, ...) for the provider
# features. FAKE_DIR holds `config.json` (optional, read on every message so a step can
# change it between turns) and gets `log.jsonl`: one line for the start (argv, cwd,
# selected environment), then every message received.
#
# config.json:
#   agentName          agentInfo.name (default "Fake")
#   version            agentInfo.version (default "1.0.0")
#   initMeta           initialize result `_meta`
#   capabilities       merged into agentCapabilities
#   authRequired       session/new and session/resume fail with -32000
#   sessionError       session/new fails with this error object
#   sessionErrorOnce   the same, for the next session/new only (then removed)
#   configOptions      session/new's configOptions (default: one model "fake/one")
#   modes              session/new's modes
#   rejectUnknownModels  session/set_config_option refuses a model configOptions lacks
#   turns              [{"match": substring, "steps": [...]}], first match wins
#   googleAuth         Antigravity's Google sign-in (see fake_google_auth.py)
#
# Turn steps: {"text": s}, {"thought": s}, {"update": sessionUpdate[, "sessionId": child's
# session, else the prompt's]}, {"request": {method,
# params}} (waits for the answer), {"permission": toolCall} (session/request_permission
# with allow_once/allow_always/reject_once), {"waitCancel": true}, {"exit": code},
# {"error": {code, message}} (ends the prompt with it), {"stop": reason}.
#
# With `--port P` (`opencode acp --port`) it also serves OpenCode's HTTP API on
# 127.0.0.1:P for the `opencode` user and OPENCODE_SERVER_PASSWORD, over sessions kept
# in FAKE_DIR/sessions (a prompt adds a user and an assistant message):
# GET /session/:id/message[?limit=n], POST /session/:id/prompt_async (a user message)
# and POST /session/:id/fork ({messageID}: the messages before it, with new ids). Each
# request is logged as {"http": {method, path, body}}.
import base64, json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.environ["FAKE_DIR"]
LOG = os.path.join(DIR, "log.jsonl")
CONFIG = os.path.join(DIR, "config.json")
ENV_PREFIXES = ("PI_", "XAI_", "GROK_", "OPENCODE_", "FAKE_", "GEMINI_", "GOOGLE_",
                "ANTIGRAVITY_", "AGY_")


LOCK = threading.RLock()


def log(entry):
    with LOCK:
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
    with LOCK:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()


# --- OpenCode's sessions and HTTP API (`--port`) ---------------------------------

SESSIONS = os.path.join(DIR, "sessions")
counter = [0]


def new_id(prefix):
    with LOCK:
        counter[0] += 1
        return "%s_%020d%04d" % (prefix, time.time_ns(), counter[0])


def messages(sid):
    try:
        with open(os.path.join(SESSIONS, "%s.json" % sid)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def save(sid, msgs):
    os.makedirs(SESSIONS, exist_ok=True)
    with open(os.path.join(SESSIONS, "%s.json" % sid), "w") as f:
        json.dump(msgs, f)


def add_message(sid, role, text):
    with LOCK:
        msgs = messages(sid)
        msgs.append({"info": {"id": new_id("msg"), "role": role, "sessionID": sid},
                     "parts": [{"type": "text", "text": text}]})
        save(sid, msgs)


class Api(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        length = int(self.headers.get("content-length") or 0)
        body = json.loads(self.rfile.read(length) or b"null") if length else None
        log({"http": {"method": method, "path": self.path, "body": body}})
        password = os.environ.get("OPENCODE_SERVER_PASSWORD", "")
        wanted = "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()
        if self.headers.get("authorization") != wanted:
            return self.reply(401, {"message": "Unauthorized"})
        path, _, query = self.path.partition("?")
        parts = path.strip("/").split("/")
        if len(parts) != 3 or parts[0] != "session":
            return self.reply(404, {"message": "not found"})
        sid, action = parts[1], parts[2]
        if action == "message" and method == "GET":
            limit = dict(q.split("=", 1) for q in query.split("&") if "=" in q).get("limit")
            with LOCK:
                msgs = messages(sid)
            return self.reply(200, msgs[-int(limit):] if limit else msgs)
        if action == "prompt_async" and method == "POST":
            text = "\n".join(p.get("text", "") for p in (body or {}).get("parts") or [])
            add_message(sid, "user", text)
            return self.reply(204)
        if action == "fork" and method == "POST":
            before = (body or {}).get("messageID")
            with LOCK:
                kept = []
                for msg in messages(sid):
                    if msg["info"]["id"] == before:
                        break
                    kept.append(msg)
                fork = new_id("ses")
                for msg in kept:
                    msg["info"] = dict(msg["info"], id=new_id("msg"), sessionID=fork)
                save(fork, kept)
            return self.reply(200, {"id": fork})
        return self.reply(404, {"message": "not found"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


if "--port" in sys.argv:
    server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--port") + 1])), Api)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def update(sid, u):
    send({"method": "session/update", "params": {"sessionId": sid, "update": u}})


log({"start": {"argv": sys.argv, "cwd": os.getcwd(), "pid": os.getpid(),
               "env": {k: v for k, v in os.environ.items() if k.startswith(ENV_PREFIXES)}}})

cancelled = False
backlog = []  # messages read while a turn waited on something else
next_id = [0]


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
    """Reads until `pred(msg)`; session/cancel sets the flag, other messages wait."""
    global cancelled
    held = []
    while True:
        msg = read()
        if msg.get("method") == "session/cancel":
            cancelled = True
            if pred(msg):
                backlog[:0] = held
                return msg
            continue
        if pred(msg):
            backlog[:0] = held
            return msg
        held.append(msg)


def request(method, params):
    next_id[0] += 1
    rid = "fake-%d" % next_id[0]
    send({"id": rid, "method": method, "params": params})
    return wait_for(lambda m: m.get("id") == rid and m.get("method") is None)


def default_options():
    return [{"id": "model", "name": "Model", "type": "select", "currentValue": "fake/one",
             "options": [{"value": "fake/one", "name": "Fake/One"}]}]


def finish(sid, msg):
    """Ends the prompt, once the turn's answer is in the session."""
    add_message(sid, "assistant", "")
    send(msg)


def run_turn(mid, sid, text):
    global cancelled
    cancelled = False
    add_message(sid, "user", text)
    cfg = config()
    steps = None
    for turn in cfg.get("turns") or []:
        if turn.get("match", "") in text:
            steps = turn.get("steps") or []
            break
    if steps is None:
        if "User message:" in text or "Return a JSON" in text:
            # Text generation: a tool it asks for is refused, then the JSON answer.
            steps = [{"permission": {"toolCallId": "tg-1", "title": "read", "kind": "read",
                                      "rawInput": {"path": "README.md"}}},
                     {"text": '{"title": "Fake title", "needsRefinement": false, '
                              '"subject": "Fake subject", "body": "", "branch": "fake-branch"}'}]
        else:
            steps = [{"text": "Hello from the fake agent"}]
    for step in steps:
        if "text" in step:
            update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "msg-%s" % mid,
                         "content": {"type": "text", "text": step["text"]}})
        elif "thought" in step:
            update(sid, {"sessionUpdate": "agent_thought_chunk", "messageId": "th-%s" % mid,
                         "content": {"type": "text", "text": step["thought"]}})
        elif "update" in step:
            update(step.get("sessionId", sid), step["update"])
        elif "request" in step:
            request(step["request"]["method"], dict(step["request"].get("params") or {}, sessionId=sid))
        elif "permission" in step:
            request("session/request_permission", {
                "sessionId": sid, "toolCall": step["permission"],
                "options": [{"optionId": "once", "name": "Allow once", "kind": "allow_once"},
                            {"optionId": "always", "name": "Always allow", "kind": "allow_always"},
                            {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]})
        elif "waitCancel" in step:
            if not cancelled:
                wait_for(lambda m: m.get("method") == "session/cancel")
            finish(sid, {"id": mid, "result": {"stopReason": "cancelled"}})
            return
        elif "exit" in step:
            sys.stdout.flush()
            os._exit(step["exit"])
        elif "error" in step:
            finish(sid, {"id": mid, "error": step["error"]})
            return
        elif "stop" in step:
            finish(sid, {"id": mid, "result": {"stopReason": step["stop"]}})
            return
    finish(sid, {"id": mid, "result": {"stopReason": "cancelled" if cancelled else "end_turn"}})


sessions = 0
while True:
    msg = read()
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    cfg = config()
    if cfg.get("googleAuth"):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        sys.dont_write_bytecode = True  # no __pycache__ in the source tree
        import fake_google_auth
        if fake_google_auth.handle(msg, cfg, send):
            continue
    if method == "initialize":
        caps = {"loadSession": True, "sessionCapabilities": {"resume": {}},
                "promptCapabilities": {"image": False}}
        caps.update(cfg.get("capabilities") or {})
        result = {"protocolVersion": 1,
                  "agentInfo": {"name": cfg.get("agentName", "Fake"),
                                "version": cfg.get("version", "1.0.0")},
                  "authMethods": cfg.get("authMethods", []), "agentCapabilities": caps}
        if cfg.get("initMeta") is not None:
            result["_meta"] = cfg["initMeta"]
        send({"id": mid, "result": result})
    elif method in ("session/new", "session/resume", "session/load") and cfg.get("authRequired"):
        send({"id": mid, "error": {"code": -32000, "message": "Authentication required"}})
    elif method == "session/new" and cfg.get("sessionError"):
        send({"id": mid, "error": cfg["sessionError"]})
    elif method == "session/new" and cfg.get("sessionErrorOnce"):
        error = cfg.pop("sessionErrorOnce")
        with open(CONFIG, "w") as f:
            json.dump(cfg, f)
        send({"id": mid, "error": error})
    elif method in ("session/new", "session/resume", "session/load"):
        sessions += 1
        result = {"configOptions": cfg.get("configOptions", default_options())}
        if cfg.get("modes") is not None:
            result["modes"] = cfg["modes"]
        if method == "session/new":
            result["sessionId"] = "fake-session-%d-%d" % (os.getpid(), sessions)
        send({"id": mid, "result": result})
    elif (method == "session/set_config_option" and cfg.get("rejectUnknownModels")
          and params.get("configId") == "model"
          and params.get("value") not in [o["value"] for o in next(
              (c for c in cfg.get("configOptions", default_options()) if c["id"] == "model"),
              {"options": []})["options"]]):
        send({"id": mid, "error": {"code": -32602, "message": "Model not found: %s" % params.get("value")}})
    elif method in ("session/set_config_option", "session/set_mode", "session/set_model"):
        send({"id": mid, "result": {"configOptions": cfg.get("configOptions", default_options())}})
    elif method == "session/prompt":
        text = "\n".join(b.get("text", "") for b in params.get("prompt") or [])
        run_turn(mid, params.get("sessionId"), text)
    elif mid is not None and method is not None:
        send({"id": mid, "error": {"code": -32601, "message": method}})
