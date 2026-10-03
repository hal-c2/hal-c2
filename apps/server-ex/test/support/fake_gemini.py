# Fake Gemini CLI over ACP, for the scenarios that carry its sessions between machines.
#
# It keeps one chat file per session the way Gemini CLI does, under FAKE_GEMINI_HOME
# (the folder holding `.gemini`): `.gemini/tmp/<sha256 of the cwd>/chats/
# session-<time>-<first 8 of the id>.json`, holding `sessionId`, `projectHash` and the
# messages. `session/load` finds a session by its id among the chats of the cwd's
# project, and fails when it is not there. It cannot branch a session.
#
# Each prompt's text is appended to FAKE_ACP_INPUT_LOG and every message read to
# FAKE_ACP_TRACE, as `fake_acp.py` does. A prompt is answered with what the user said
# in the session so far, and whether the prompt carried a transcript:
# "said: a | b history False".
import glob, hashlib, json, os, sys, time, uuid

HOME = os.path.join(os.environ["FAKE_GEMINI_HOME"], ".gemini")
TRACE = os.environ.get("FAKE_ACP_TRACE")
INPUTS = os.environ.get("FAKE_ACP_INPUT_LOG")


def trace(entry):
    if TRACE:
        with open(TRACE, "a") as f:
            f.write(json.dumps(entry) + "\n")


def send(msg):
    msg["jsonrpc"] = "2.0"
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def project(cwd):
    return hashlib.sha256(cwd.encode()).hexdigest()


def chats(cwd):
    return os.path.join(HOME, "tmp", project(cwd), "chats")


def find(sid, cwd):
    for path in glob.glob(os.path.join(chats(cwd), "session-*-%s.json" % sid[:8])):
        chat = json.load(open(path))
        if chat.get("sessionId") == sid and chat.get("projectHash") == project(cwd):
            return path
    return None


def save(path, chat):
    with open(path + ".tmp", "w") as f:
        json.dump(chat, f)
    os.replace(path + ".tmp", path)


OPTIONS = {"configOptions": [{"id": "model", "currentValue": "fake/one",
                              "options": [{"value": "fake/one", "name": "Fake/One"}]}]}
files = {}  # session id -> its chat file

trace({"argv": sys.argv[1:]})
for line in sys.stdin:
    msg = json.loads(line)
    trace({"in": msg})
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    if method == "initialize":
        send({"id": mid, "result": {"protocolVersion": 1, "agentInfo": {"name": "gemini", "version": "1.0.0"},
              "authMethods": [], "agentCapabilities": {"loadSession": True}}})
    elif method == "session/new":
        cwd = params.get("cwd") or os.getcwd()
        sid = str(uuid.uuid4())
        os.makedirs(chats(cwd), exist_ok=True)
        path = os.path.join(chats(cwd), "session-%s-%s.json" % (time.strftime("%Y-%m-%dT%H-%M"), sid[:8]))
        save(path, {"sessionId": sid, "projectHash": project(cwd), "messages": []})
        files[sid] = path
        send({"id": mid, "result": dict(OPTIONS, sessionId=sid)})
    elif method == "session/load":
        path = find(params["sessionId"], params.get("cwd") or os.getcwd())
        if path:
            files[params["sessionId"]] = path
            send({"id": mid, "result": OPTIONS})
        else:
            send({"id": mid, "error": {"code": -32603, "message": "Session not found"}})
    elif method == "session/set_config_option":
        send({"id": mid, "result": {"configOptions": []}})
    elif method == "session/prompt":
        sid = params["sessionId"]
        text = "\n".join(block.get("text", "") for block in params["prompt"])
        if INPUTS:
            with open(INPUTS, "a") as f:
                f.write(json.dumps(text) + "\n")
        chat = json.load(open(files[sid]))
        chat["messages"].append({"type": "user", "content": text})
        said = " | ".join(m["content"] for m in chat["messages"] if m["type"] == "user")
        answer = "said: %s history %s" % (said, "<conversation_history>" in text)
        chat["messages"].append({"type": "gemini", "content": answer})
        save(files[sid], chat)
        send({"method": "session/update", "params": {"sessionId": sid, "update": {
            "sessionUpdate": "agent_message_chunk", "messageId": "msg-%d" % len(chat["messages"]),
            "content": {"type": "text", "text": answer}}}})
        send({"id": mid, "result": {"stopReason": "end_turn"}})
    elif mid is not None and method:
        send({"id": mid, "error": {"code": -32601, "message": method}})
