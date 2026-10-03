# Fake ACP agent (like `opencode acp`) for tests. A prompt containing "wait" runs
# until session/cancel, or until another prompt joins it; "approve" asks permission for a command first, offering
# "Always allow" unless the prompt says "once only". Title and commit prompts (without
# FAKE_TEXT_LOG) ask to run a tool, then answer JSON naming the permission outcome.
# With FAKE_ACP_LOG set, every permission answer is appended to that file as a JSON line;
# FAKE_ACP_TRACE collects the argv and every message read.
#
# With `--port P` (`opencode acp --port`) it also serves OpenCode's HTTP API on
# 127.0.0.1:P for the `opencode` user and OPENCODE_SERVER_PASSWORD, over sessions kept
# as JSON files in FAKE_ACP_SESSIONS (shared by every fake; a private directory without
# it): each prompt adds a user message, and each turn's end an assistant message.
# GET /session/:id/message[?limit=n] and POST /session/:id/fork ({messageID}: the
# messages before it, with new ids) are served; each request is traced as
# {"http": {method, path, body}}.
import base64, json, os, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# With FAKE_AUTH_FILE set, sessions need a sign-in, which creates that file: the
# "browser" method asks the client to open a URL; "cli" runs `fake_acp.py login`.
AUTH_FILE = os.environ.get("FAKE_AUTH_FILE")
if len(sys.argv) > 1 and sys.argv[1] == "login":
    sys.stdout.write("Paste code: ")
    sys.stdout.flush()
    code = sys.stdin.readline().strip()
    if code == "ok":
        open(AUTH_FILE, "w").write("signed in")
        print("Signed in.")
        sys.exit(0)
    sys.exit(1)

# With FAKE_ACP_STATE set (a JSON file), the agent remembers across runs what it was
# asked: every method ("calls"), deleted sessions, and its configured model provider
# ("provider", none until set; "headers" as last set).
STATE = os.environ.get("FAKE_ACP_STATE")

def load_state():
    try:
        return json.load(open(STATE))
    except (OSError, ValueError):
        return {"calls": [], "deleted": [], "provider": None}

def save_state(state):
    json.dump(state, open(STATE + ".tmp", "w"))
    os.replace(STATE + ".tmp", STATE)

# With FAKE_ACP_TRACE set, the argv and every message read are appended to it as JSON lines.
TRACE = os.environ.get("FAKE_ACP_TRACE")
LOCK = threading.RLock()
def trace(entry):
    if TRACE:
        with LOCK, open(TRACE, "a") as f:
            f.write(json.dumps(entry) + "\n")

def send(msg):
    msg["jsonrpc"] = "2.0"
    with LOCK:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()

# --- OpenCode's sessions and HTTP API (`--port`) ---------------------------------

# The session of the subagent an "in the background" prompt spawns.
CHILD = "0f8e2a4c-5b6d-4e7f-8a9b-1c2d3e4f5a6b"
PORT = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else None
SESSIONS = os.environ.get("FAKE_ACP_SESSIONS") or (PORT and tempfile.mkdtemp())
ids = [0]

def new_id(prefix):
    with LOCK:
        ids[0] += 1
        return "%s_%020d%06d" % (prefix, time.time_ns(), ids[0])

def messages(sid):
    try:
        with open(os.path.join(SESSIONS, "%s.json" % sid)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return []

def save(sid, msgs):
    os.makedirs(SESSIONS, exist_ok=True)
    path = os.path.join(SESSIONS, "%s.json" % sid)
    with open(path + ".tmp", "w") as f:
        json.dump(msgs, f)
    os.replace(path + ".tmp", path)

def add_message(sid, role, text):
    if PORT:
        with LOCK:
            save(sid, messages(sid) + [{"info": {"id": new_id("msg"), "role": role, "sessionID": sid},
                                        "parts": [{"type": "text", "text": text}]}])

def end_prompt(pid, sid, reason="end_turn"):
    """Ends a prompt once the turn's answer is in the session."""
    add_message(sid, "assistant", "")
    send({"id": pid, "result": {"stopReason": reason}})

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
        body = json.loads(self.rfile.read(length)) if length else None
        trace({"http": {"method": method, "path": self.path, "body": body}})
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

if PORT:
    api = ThreadingHTTPServer(("127.0.0.1", PORT), Api)
    threading.Thread(target=api.serve_forever, daemon=True).start()

def update(sid, u):
    send({"method": "session/update", "params": {"sessionId": sid, "update": u}})

# `--instance <id>` names the provider instance this fake stands in for, in the
# $FAKE_TEXT_LOG entries it writes for text generation title prompts.
INSTANCE = sys.argv[sys.argv.index("--instance") + 1] if "--instance" in sys.argv else "opencode"

sessions = 0
cwds = {}           # session id -> the cwd it was opened in
titling = None      # a title prompt waiting on its tool requests: {pid, sid, text, answers}
model = "fake/one"  # the session's model, as set_config_option leaves it
waiting = None      # prompt request id held until cancel
pending = None      # (prompt id, session id) waiting on a permission answer
asked = 0           # permission requests so far, numbering their ids

def finish_turn(pid, sid, allowed=True):
    update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "completed",
                 "rawInput": {"command": "ls"},
                 "content": [{"type": "content", "content": {"type": "text", "text": "a.txt\n"}}]})
    text = "Hello from acp" if allowed else "not allowed"
    for part in [text[:5], text[5:]]:
        update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "msg-1", "content": {"type": "text", "text": part}})
    end_prompt(pid, sid)

def answer_title():
    # Text generation: log what the agent was allowed, then answer the schema's keys.
    global titling
    pid, sid, text, answers = titling["pid"], titling["sid"], titling["text"], titling["answers"]
    titling = None
    cwd = cwds.get(sid, os.getcwd())
    with open(os.environ["FAKE_TEXT_LOG"], "a") as f:
        f.write(json.dumps({"acp": INSTANCE, "argv": sys.argv[1:], "cwd": cwd, "listing": os.listdir(cwd),
                            "prompt": text, "model": model, "refused": answers}) + "\n")
    out = {"title": "%s title" % INSTANCE, "needsRefinement": False}
    out.update(json.loads(os.environ.get("FAKE_TEXT_ANSWER") or "{}"))
    update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "msg-1",
                 "content": {"type": "text", "text": json.dumps(out)}})
    send({"id": pid, "result": {"stopReason": "end_turn"}})

trace({"argv": sys.argv[1:]})
for line in sys.stdin:
    msg = json.loads(line)
    trace({"in": msg})
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    state = load_state() if STATE else None
    if state is not None and method:
        state["calls"].append(method)
        save_state(state)
    if method is None and titling and mid in ("tg-perm", "tg-read"):
        titling["answers"][mid] = msg.get("result") or {"error": msg.get("error")}
        if len(titling["answers"]) == 2:
            answer_title()
        continue
    if method is None and mid == "perm-text":
        # Text generation's answer says what became of the tool it asked for.
        pid, sid = pending
        outcome = msg["result"]["outcome"]["outcome"] if "result" in msg else "error"
        answer = json.dumps({"title": "ACP title, tool " + outcome, "needsRefinement": False,
                             "subject": "ACP subject, tool " + outcome, "body": "ACP body"})
        update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "msg-1", "content": {"type": "text", "text": answer}})
        send({"id": pid, "result": {"stopReason": "end_turn"}})
        continue
    if method is None and str(mid).startswith("perm-"):
        outcome = msg["result"]["outcome"]
        if os.environ.get("FAKE_ACP_LOG"):
            with open(os.environ["FAKE_ACP_LOG"], "a") as f:
                f.write(json.dumps({"method": "response", "params": {"id": mid, "result": msg["result"]}}) + "\n")
        pid, sid = pending
        finish_turn(pid, sid, outcome.get("optionId") in ("allow", "always"))
        continue
    if method is None and mid == "elic-1":
        if msg["result"]["action"] == "accept":
            open(AUTH_FILE, "w").write("signed in")
            send({"id": authenticating, "result": {}})
        else:
            send({"id": authenticating, "error": {"code": -32000, "message": "declined"}})
        continue
    if method == "authenticate":
        authenticating = mid
        send({"id": "elic-1", "method": "elicitation/create", "params": {"mode": "url",
              "url": "https://example.com/login", "elicitationId": "e1", "message": "Sign in"}})
        continue
    if method in ("session/new", "session/resume", "session/list") and AUTH_FILE and not os.path.exists(AUTH_FILE):
        send({"id": mid, "error": {"code": -32000, "message": "Authentication required"}})
        continue
    if method == "initialize":
        send({"id": mid, "result": {"protocolVersion": 1, "agentInfo": {"name": "Fake", "version": "9.9"},
              "authMethods": [{"id": "browser", "name": "Browser login"},
                              {"id": "cli", "name": "CLI login", "type": "terminal", "args": ["login"]}],
              # FAKE_ACP_CAPS: a JSON object of agentCapabilities to report instead.
              "agentCapabilities": json.loads(os.environ.get("FAKE_ACP_CAPS", "null")) or {"loadSession": True,
                  "sessionCapabilities": {"resume": {}, "list": {}, "delete": {}},
                  "providers": {}, "auth": {"logout": {}}}}})
    elif method in ("session/new", "session/resume"):
        sessions += 1
        # Sessions every fake keeps in one place need ids no other fake gives.
        new = "acp-%d-%d" % (os.getpid(), sessions) if os.environ.get("FAKE_ACP_SESSIONS") else "acp-%d" % sessions
        sid = params.get("sessionId") or new
        # FAKE_ACP_MODELS: a JSON list of model names to offer instead of the fake's own.
        names = json.loads(os.environ.get("FAKE_ACP_MODELS", "null")) or ["Fake/One", "Fake/Two"]
        options = [{"value": n.lower().replace(" ", "-"), "name": n} for n in names]
        result = {"configOptions": [{"id": "model", "currentValue": options[0]["value"], "options": options}]}
        if method == "session/new": result["sessionId"] = sid
        cwds[sid] = params.get("cwd") or os.getcwd()
        send({"id": mid, "result": result})
    elif method == "session/set_config_option":
        if params.get("configId") == "model": model = params["value"]
        send({"id": mid, "result": {"configOptions": []}})
    elif method == "session/prompt":
        sid = params["sessionId"]
        text = params["prompt"][0]["text"]
        add_message(sid, "user", text)
        # FAKE_ACP_INPUT_LOG names a file each prompt's text is appended to, as JSON.
        if os.environ.get("FAKE_ACP_INPUT_LOG"):
            with open(os.environ["FAKE_ACP_INPUT_LOG"], "a") as input_log:
                input_log.write(json.dumps(text) + "\n")
        if waiting and waiting[1] == sid:
            # A prompt during a waiting turn joins it, as OpenCode's running loop takes
            # it: the turn answers it, then both prompts end.
            update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "msg-steer", "content": {"type": "text", "text": "steered: " + text}})
            end_prompt(waiting[0], sid)
            send({"id": mid, "result": {"stopReason": "end_turn"}})
            waiting = None
            continue
        update(sid, {"sessionUpdate": "agent_thought_chunk", "messageId": "th-1", "content": {"type": "text", "text": "Let me look."}})
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "call-1", "title": "bash", "kind": "execute", "status": "pending", "rawInput": {}})
        if "Return JSON with keys title and needsRefinement." in text and os.environ.get("FAKE_TEXT_LOG"):
            # A title writer that tries a command and a file read first.
            titling = {"pid": mid, "sid": sid, "text": text, "answers": {}}
            send({"id": "tg-perm", "method": "session/request_permission", "params": {"sessionId": sid,
                  "toolCall": {"toolCallId": "call-1", "title": "ls", "kind": "execute", "rawInput": {"command": "ls"}},
                  "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                              {"optionId": "deny", "name": "Deny", "kind": "reject_once"}]}})
            send({"id": "tg-read", "method": "fs/read_text_file", "params": {"sessionId": sid, "path": "/etc/hostname"}})
        elif "Return a JSON object with key: branch." in text:
            # Text generation: the JSON comes wrapped in prose, in pieces.
            answer = 'Sure: {"branch": "ACP branch %s in %s"} done' % (model, os.path.basename(os.getcwd()))
            for part in [answer[:12], answer[12:]]:
                update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "msg-1", "content": {"type": "text", "text": part}})
            send({"id": mid, "result": {"stopReason": "end_turn"}})
        elif "Return JSON with keys title and needsRefinement" in text or "Return a JSON object with keys: subject" in text:
            # A title or commit message: asks to run a tool first, then answers.
            pending = (mid, sid)
            send({"id": "perm-text", "method": "session/request_permission", "params": {"sessionId": sid,
                  "toolCall": {"toolCallId": "call-1", "title": "ls", "kind": "execute", "rawInput": {"command": "ls"}},
                  "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"}]}})
        elif "write the plan down" in text:
            # Cursor's createPlan tool, as cursor-acp passes it on: named after the SDK's
            # tool, with its input repeated when it ends.
            call = {"toolCallId": "plan-1", "title": "createPlan", "kind": "other",
                    "rawInput": {"plan": "# Plan\n\n1. Add the form"}}
            update(sid, dict(call, sessionUpdate="tool_call", status="pending"))
            update(sid, dict(call, sessionUpdate="tool_call_update", status="completed"))
            finish_turn(mid, sid)
        elif "hand it to a subagent" in text:
            # The agent's task tool: a subagent it runs to the end inside the turn.
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": "task-1", "title": "task", "kind": "other",
                         "status": "in_progress", "rawInput": {"description": "Survey the modules",
                             "prompt": "List the modules in lib", "subagent_type": "general-purpose"}})
            update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "task-1", "status": "completed",
                         "content": [{"type": "content", "content": {"type": "text", "text": "lib has three modules"}}]})
            finish_turn(mid, sid)
        elif "in the background" in text:
            # Grok's background work: a shell started as a task (task-sh), and a subagent
            # spawned in the background (spawn-1, session CHILD). With "wait" the turn
            # stays open.
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": "sh-1", "title": "npm run dev", "kind": "execute",
                         "status": "in_progress", "rawInput": {"command": "npm run dev"}})
            update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "sh-1", "status": "completed",
                         "content": [{"type": "content", "content": {"type": "text", "text": "Started in the background."}}],
                         "rawOutput": {"type": "BackgroundTaskStarted", "task_id": "task-sh", "command": "npm run dev"}})
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": "spawn-1", "title": "task", "kind": "other",
                         "status": "in_progress", "rawInput": {"description": "Survey the repo", "prompt": "List the repo"}})
            update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "spawn-1", "status": "completed",
                         "content": [{"type": "content", "content": {"type": "text", "text":
                             "Subagent started in background.\nsubagent_id: %s\nUse get_command_or_subagent_output." % CHILD}}]})
            if "wait" in text:
                waiting = (mid, sid)
            else:
                finish_turn(mid, sid)
        elif "wait" in text:
            # OpenCode names the command once it runs, with its output so far.
            update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "in_progress",
                         "kind": "execute", "title": "ls", "rawInput": {"command": "ls"},
                         "content": [{"type": "content", "content": {"type": "text", "text": "a.txt\n"}}]})
            waiting = (mid, sid)
        elif "approve" in text:
            pending = (mid, sid)
            asked += 1
            # "approve run: npm test" asks about that command; anything else asks about ls.
            command = text.split("approve run:", 1)[1].split(",")[0].strip() if "approve run:" in text else "ls"
            send({"id": "perm-%d" % asked, "method": "session/request_permission", "params": {"sessionId": sid,
                  "toolCall": {"toolCallId": "call-1", "title": command, "kind": "execute", "rawInput": {"command": command}},
                  "options": ([{"optionId": "always", "name": "Always allow", "kind": "allow_always"}] if "once only" not in text else [])
                             + [{"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                                {"optionId": "deny", "name": "Deny", "kind": "reject_once"}]}})
        else:
            finish_turn(mid, sid)
    elif method == "session/list":
        deleted = state["deleted"] if state else []
        send({"id": mid, "result": {"nextCursor": None, "sessions": [s for s in [
            {"sessionId": "old-1", "cwd": params["cwd"], "title": "Earlier work", "updatedAt": "2026-09-01T10:00:00Z"},
            {"sessionId": "old/2", "cwd": params["cwd"]}] if s["sessionId"] not in deleted]}})
    elif method == "session/delete":
        if state is not None:
            state["deleted"].append(params["sessionId"])
            save_state(state)
        send({"id": mid, "result": {}})
    elif method == "providers/list":
        current = state["provider"] if state else {"apiType": "openai", "baseUrl": "https://api.example.com"}
        send({"id": mid, "result": {"providers": [{"providerId": "openai", "supported": ["openai"], "required": False,
              "current": current}]}})
    elif method in ("providers/set", "providers/disable", "logout"):
        if state is not None and method == "providers/set":
            state["provider"] = {"apiType": params["apiType"], "baseUrl": params["baseUrl"]}
            state["headers"] = params.get("headers")
        if state is not None and method == "providers/disable":
            state["provider"] = None
        if state is not None:
            save_state(state)
        if method == "logout" and AUTH_FILE and os.path.exists(AUTH_FILE):
            os.remove(AUTH_FILE)
        send({"id": mid, "result": {}})
    elif method == "session/cancel" and waiting:
        end_prompt(waiting[0], waiting[1], "cancelled")
        waiting = None
    elif mid is not None:
        send({"id": mid, "error": {"code": -32601, "message": method}})
