# Fake ACP agent (like `opencode acp`) for tests. A prompt containing "wait" runs
# until session/cancel; "approve" asks permission for a command first.
import json, os, sys

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

def send(msg):
    msg["jsonrpc"] = "2.0"
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

def update(sid, u):
    send({"method": "session/update", "params": {"sessionId": sid, "update": u}})

sessions = 0
model = "fake/one"  # the session's model, as set_config_option leaves it
waiting = None      # prompt request id held until cancel
pending = None      # (prompt id, session id) waiting on a permission answer

def finish_turn(pid, sid, allowed=True):
    update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "completed",
                 "rawInput": {"command": "ls"},
                 "content": [{"type": "content", "content": {"type": "text", "text": "a.txt\n"}}]})
    text = "Hello from acp" if allowed else "not allowed"
    for part in [text[:5], text[5:]]:
        update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "msg-1", "content": {"type": "text", "text": part}})
    send({"id": pid, "result": {"stopReason": "end_turn"}})

for line in sys.stdin:
    msg = json.loads(line)
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    state = load_state() if STATE else None
    if state is not None and method:
        state["calls"].append(method)
        save_state(state)
    if method is None and mid == "perm-1":
        outcome = msg["result"]["outcome"]
        pid, sid = pending
        finish_turn(pid, sid, outcome.get("optionId") == "allow")
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
    if method in ("session/new", "session/resume") and AUTH_FILE and not os.path.exists(AUTH_FILE):
        send({"id": mid, "error": {"code": -32000, "message": "Authentication required"}})
        continue
    if method == "initialize":
        send({"id": mid, "result": {"protocolVersion": 1, "agentInfo": {"name": "Fake", "version": "9.9"},
              "authMethods": [{"id": "browser", "name": "Browser login"},
                              {"id": "cli", "name": "CLI login", "type": "terminal", "args": ["login"]}],
              "agentCapabilities": {"loadSession": True,
                  "sessionCapabilities": {"resume": {}, "list": {}, "delete": {}},
                  "providers": {}, "auth": {"logout": {}}}}})
    elif method in ("session/new", "session/resume"):
        sessions += 1
        sid = params.get("sessionId") or "acp-%d" % sessions
        result = {"configOptions": [{"id": "model", "currentValue": "fake/one",
                  "options": [{"value": "fake/one", "name": "Fake/One"}, {"value": "fake/two", "name": "Fake/Two"}]}]}
        if method == "session/new": result["sessionId"] = sid
        send({"id": mid, "result": result})
    elif method == "session/set_config_option":
        if params.get("configId") == "model": model = params["value"]
        send({"id": mid, "result": {"configOptions": []}})
    elif method == "session/prompt":
        sid = params["sessionId"]
        text = params["prompt"][0]["text"]
        update(sid, {"sessionUpdate": "agent_thought_chunk", "messageId": "th-1", "content": {"type": "text", "text": "Let me look."}})
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "call-1", "title": "bash", "kind": "execute", "status": "pending", "rawInput": {}})
        if "Return a JSON object with key: branch." in text:
            # Text generation: the JSON comes wrapped in prose, in pieces.
            answer = 'Sure: {"branch": "ACP branch %s in %s"} done' % (model, os.path.basename(os.getcwd()))
            for part in [answer[:12], answer[12:]]:
                update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "msg-1", "content": {"type": "text", "text": part}})
            send({"id": mid, "result": {"stopReason": "end_turn"}})
        elif "wait" in text:
            waiting = (mid, sid)
        elif "approve" in text:
            pending = (mid, sid)
            send({"id": "perm-1", "method": "session/request_permission", "params": {"sessionId": sid,
                  "toolCall": {"toolCallId": "call-1", "title": "ls", "kind": "execute", "rawInput": {"command": "ls"}},
                  "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"},
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
        send({"id": waiting[0], "result": {"stopReason": "cancelled"}})
        waiting = None
    elif mid is not None:
        send({"id": mid, "error": {"code": -32601, "message": method}})
