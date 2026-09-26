# A scriptable fake ACP agent (Grok, OpenCode, Pi's adapter, ...) for the provider
# features. FAKE_DIR holds `config.json` (optional, read on every message so a step can
# change it between turns) and gets `log.jsonl`: one line for the start (argv, cwd,
# selected environment), then every message received.
#
# config.json:
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
#
# Turn steps: {"text": s}, {"thought": s}, {"update": sessionUpdate[, "sessionId": child's
# session, else the prompt's]}, {"request": {method,
# params}} (waits for the answer), {"permission": toolCall} (session/request_permission
# with allow_once/allow_always/reject_once), {"waitCancel": true}, {"exit": code},
# {"error": {code, message}} (ends the prompt with it), {"stop": reason}.
import json, os, sys

DIR = os.environ["FAKE_DIR"]
LOG = os.path.join(DIR, "log.jsonl")
CONFIG = os.path.join(DIR, "config.json")
ENV_PREFIXES = ("PI_", "XAI_", "GROK_", "OPENCODE_", "FAKE_", "GEMINI_", "GOOGLE_")


def log(entry):
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
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


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


def run_turn(mid, sid, text):
    global cancelled
    cancelled = False
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
            send({"id": mid, "result": {"stopReason": "cancelled"}})
            return
        elif "exit" in step:
            sys.stdout.flush()
            os._exit(step["exit"])
        elif "error" in step:
            send({"id": mid, "error": step["error"]})
            return
        elif "stop" in step:
            send({"id": mid, "result": {"stopReason": step["stop"]}})
            return
    send({"id": mid, "result": {"stopReason": "cancelled" if cancelled else "end_turn"}})


sessions = 0
while True:
    msg = read()
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    cfg = config()
    if method == "initialize":
        caps = {"loadSession": True, "sessionCapabilities": {"resume": {}},
                "promptCapabilities": {"image": False}}
        caps.update(cfg.get("capabilities") or {})
        result = {"protocolVersion": 1,
                  "agentInfo": {"name": "Fake", "version": cfg.get("version", "1.0.0")},
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
