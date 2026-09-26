# Fake ACP agent (like `opencode acp`) for tests. A prompt containing "wait" runs
# until session/cancel; "approve" asks permission for a command first. Title and commit
# prompts ask to run a tool, then answer JSON naming the permission outcome.
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

# With FAKE_ACP_LOG set, the argv and every message read are appended to it as JSON lines.
LOG = os.environ.get("FAKE_ACP_LOG")
def log(entry):
    if LOG:
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")

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

log({"argv": sys.argv[1:]})
for line in sys.stdin:
    msg = json.loads(line)
    log({"in": msg})
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    if method is None and mid == "perm-text":
        # Text generation's answer says what became of the tool it asked for.
        pid, sid = pending
        outcome = msg["result"]["outcome"]["outcome"] if "result" in msg else "error"
        answer = json.dumps({"title": "ACP title, tool " + outcome, "needsRefinement": False,
                             "subject": "ACP subject, tool " + outcome, "body": "ACP body"})
        update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "msg-1", "content": {"type": "text", "text": answer}})
        send({"id": pid, "result": {"stopReason": "end_turn"}})
        continue
    if method is None and mid == "perm-1":
        outcome = msg["result"]["outcome"]
        pid, sid = pending
        finish_turn(pid, sid, outcome.get("optionId") in ("allow", "allow-always"))
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
        sid = params.get("sessionId") or "acp-%d" % sessions
        # FAKE_ACP_MODELS: a JSON list of model names to offer instead of the fake's own.
        names = json.loads(os.environ.get("FAKE_ACP_MODELS", "null")) or ["Fake/One", "Fake/Two"]
        options = [{"value": n.lower().replace(" ", "-"), "name": n} for n in names]
        result = {"configOptions": [{"id": "model", "currentValue": options[0]["value"], "options": options}]}
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
        elif "Return JSON with keys title and needsRefinement" in text or "Return a JSON object with keys: subject" in text:
            # A title or commit message: asks to run a tool first, then answers.
            pending = (mid, sid)
            send({"id": "perm-text", "method": "session/request_permission", "params": {"sessionId": sid,
                  "toolCall": {"toolCallId": "call-1", "title": "ls", "kind": "execute", "rawInput": {"command": "ls"}},
                  "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"}]}})
        elif "wait" in text:
            waiting = (mid, sid)
        elif "approve" in text:
            pending = (mid, sid)
            send({"id": "perm-1", "method": "session/request_permission", "params": {"sessionId": sid,
                  "toolCall": {"toolCallId": "call-1", "title": "ls", "kind": "execute", "rawInput": {"command": "ls"}},
                  "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                              {"optionId": "allow-always", "name": "Always allow", "kind": "allow_always"},
                              {"optionId": "deny", "name": "Deny", "kind": "reject_once"}]}})
        else:
            finish_turn(mid, sid)
    elif method == "session/list":
        send({"id": mid, "result": {"nextCursor": None, "sessions": [
            {"sessionId": "old-1", "cwd": params["cwd"], "title": "Earlier work", "updatedAt": "2026-09-01T10:00:00Z"},
            {"sessionId": "old/2", "cwd": params["cwd"]}]}})
    elif method == "session/delete":
        send({"id": mid, "result": {}})
    elif method == "providers/list":
        send({"id": mid, "result": {"providers": [{"providerId": "openai", "supported": ["openai"], "required": False,
              "current": {"apiType": "openai", "baseUrl": "https://api.example.com"}}]}})
    elif method in ("providers/set", "providers/disable", "logout"):
        send({"id": mid, "result": {}})
    elif method == "session/cancel" and waiting:
        send({"id": waiting[0], "result": {"stopReason": "cancelled"}})
        waiting = None
    elif mid is not None:
        send({"id": mid, "error": {"code": -32601, "message": method}})
