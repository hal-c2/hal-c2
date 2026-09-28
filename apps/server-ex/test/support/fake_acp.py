# Fake ACP agent (like `opencode acp`) for tests. A prompt containing "wait" runs
# until session/cancel, or until another prompt joins it; "approve" asks permission for a command first, offering
# "Always allow" unless the prompt says "once only". Title and commit prompts (without
# FAKE_TEXT_LOG) ask to run a tool, then answer JSON naming the permission outcome.
# With FAKE_ACP_LOG set, every permission answer is appended to that file as a JSON line;
# FAKE_ACP_TRACE collects the argv and every message read.
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

# With FAKE_ACP_TRACE set, the argv and every message read are appended to it as JSON lines.
TRACE = os.environ.get("FAKE_ACP_TRACE")
def trace(entry):
    if TRACE:
        with open(TRACE, "a") as f:
            f.write(json.dumps(entry) + "\n")

def send(msg):
    msg["jsonrpc"] = "2.0"
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

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
    send({"id": pid, "result": {"stopReason": "end_turn"}})

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
        sid = params.get("sessionId") or "acp-%d" % sessions
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
        # FAKE_ACP_INPUT_LOG names a file each prompt's text is appended to, as JSON.
        if os.environ.get("FAKE_ACP_INPUT_LOG"):
            with open(os.environ["FAKE_ACP_INPUT_LOG"], "a") as input_log:
                input_log.write(json.dumps(text) + "\n")
        if waiting and waiting[1] == sid:
            # A prompt during a waiting turn joins it, as OpenCode's running loop takes
            # it: the turn answers it, then both prompts end.
            update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "msg-steer", "content": {"type": "text", "text": "steered: " + text}})
            for held in (waiting[0], mid):
                send({"id": held, "result": {"stopReason": "end_turn"}})
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
        elif "wait" in text:
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
        send({"id": waiting[0], "result": {"stopReason": "cancelled"}})
        waiting = None
    elif mid is not None:
        send({"id": mid, "error": {"code": -32601, "message": method}})
