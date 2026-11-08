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
#   sessionModels      session/new's `models` (currentModelId, availableModels), as Grok reports them
#   rejectUnknownModels  session/set_config_option refuses a model configOptions lacks
#   turns              [{"match": substring, "steps": [...]}], first match wins
#   sessionId          session/new's sessionId (default: a fake one)
#   hangMethods        methods the agent never answers (it reads on regardless)
#   initError          initialize fails with this error object
#   waitForFileOn      {method: file name}: that method is answered only once
#                      the file appears in FAKE_DIR
#   googleAuth         Antigravity's Google sign-in (see fake_google_auth.py)
#   versionDelayMs / versionHang / versionExit
#                      how a `--version` invocation answers (Grok's health probe)
#   updatedVersion     an `update` invocation installs this version; with
#                      updateRequiresAllowScripts it does so only when
#                      npm_config_allow_scripts names the Grok package
#   delaysMs           {method: ms} a method is answered only after the delay
#   failInitializeTimes  the first N initialize calls (across processes) fail
#
# Turn steps: {"text": s}, {"thought": s}, {"update": sessionUpdate[, "sessionId": child's
# session, else the prompt's]}, {"request": {method,
# params}} (waits for the answer), {"permission": toolCall} (session/request_permission
# with allow_once/allow_always/reject_once), {"waitCancel": true[, "after": [sessionUpdate]]}
# (the updates are sent once the cancel came, before the prompt ends), {"exit": code},
# {"error": {code, message}} (ends the prompt with it), {"stop": reason},
# {"hang": true} (never answers the prompt, even to a cancel),
# {"waitFile": name} (waits until that file appears in FAKE_DIR),
# {"writeFile": name} (leaves a file in the working folder), {"writeSession": true}
# (records a conversation for the working folder in $GEMINI_HOME, as Antigravity keeps one),
# {"kimiWire": {"agent": "main" | subagent id, "records": [record]}} (appends to an
# agent's record as Kimi Code keeps it:
# $KIMI_CODE_HOME/sessions/<workspace id>/<session id>/agents/<agent>/wire.jsonl).
import json, os, sys

DIR = os.environ["FAKE_DIR"]
LOG = os.path.join(DIR, "log.jsonl")
CONFIG = os.path.join(DIR, "config.json")
ENV_PREFIXES = ("PI_", "XAI_", "GROK_", "OPENCODE_", "FAKE_", "GEMINI_", "GOOGLE_",
                "ANTIGRAVITY_", "AGY_")


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
               "env": {k: v for k, v in os.environ.items()
                       if k.startswith(ENV_PREFIXES) or k in (
                           "TMPDIR", "npm_config_allow_scripts")}}})

if len(sys.argv) > 1 and sys.argv[1] == "--version":
    import time
    cfg = config()
    if cfg.get("versionHang"):
        time.sleep(3600)
    time.sleep((cfg.get("versionDelayMs") or 0) / 1000.0)
    print("grok %s" % cfg.get("version", "1.0.0"))
    sys.exit(cfg.get("versionExit") or 0)

if len(sys.argv) > 1 and sys.argv[1] == "update":
    cfg = config()
    allowed = os.environ.get("npm_config_allow_scripts") == "@xai-official/grok"
    if cfg.get("updatedVersion") and (allowed or not cfg.get("updateRequiresAllowScripts")):
        cfg["version"] = cfg["updatedVersion"]
        with open(CONFIG, "w") as f:
            json.dump(cfg, f)
    sys.exit(0)

cancelled = False


def kimi_wire(sid, wire):
    path = os.path.join(os.environ["KIMI_CODE_HOME"], "sessions", "workspace", sid,
                        "agents", wire["agent"])
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "wire.jsonl"), "a") as f:
        for r in wire["records"]:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")


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


def wait_file(name):
    """Polls until `name` appears in FAKE_DIR: how a step releases a held turn."""
    import time
    while not os.path.exists(os.path.join(DIR, name)):
        time.sleep(0.005)


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
            for u in step.get("after") or []:
                update(sid, u)
            send({"id": mid, "result": {"stopReason": "cancelled"}})
            return
        elif "hang" in step:
            while True:
                read()
        elif "waitFile" in step:
            wait_file(step["waitFile"])
        elif "writeFile" in step:
            # Leaves a file in the session's working folder.
            with open(os.path.join(os.getcwd(), step["writeFile"]), "w") as f:
                f.write("left behind\n")
        elif "writeSession" in step:
            # Records a conversation in Antigravity's profile, as the CLI does for its cwd.
            conversations = os.path.join(os.environ["GEMINI_HOME"], "antigravity-acp", "conversations")
            os.makedirs(conversations, exist_ok=True)
            base = os.path.join(conversations, sid)
            with open(base + ".meta", "w") as f:
                json.dump({"cwd": os.getcwd()}, f)
            open(base + ".db", "w").close()
        elif "exit" in step:
            sys.stdout.flush()
            os._exit(step["exit"])
        elif "error" in step:
            send({"id": mid, "error": step["error"]})
            return
        elif "kimiWire" in step:
            kimi_wire(sid, step["kimiWire"])
        elif "stop" in step:
            send({"id": mid, "result": {"stopReason": step["stop"]}})
            return
    send({"id": mid, "result": {"stopReason": "cancelled" if cancelled else "end_turn"}})


sessions = 0
while True:
    msg = read()
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    cfg = config()
    if method in (cfg.get("hangMethods") or []):
        continue
    gate = (cfg.get("waitForFileOn") or {}).get(method)
    if gate:
        wait_file(gate)
    if cfg.get("googleAuth"):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        sys.dont_write_bytecode = True  # no __pycache__ in the source tree
        import fake_google_auth
        if fake_google_auth.handle(msg, cfg, send):
            continue
    delay = (cfg.get("delaysMs") or {}).get(method)
    if delay:
        import time
        time.sleep(delay / 1000.0)
    if method == "initialize" and cfg.get("failInitializeTimes"):
        marker = os.path.join(DIR, "init-failures")
        try:
            with open(marker) as f:
                seen = int(f.read().strip() or 0)
        except OSError:
            seen = 0
        if seen < cfg["failInitializeTimes"]:
            with open(marker, "w") as f:
                f.write(str(seen + 1))
            send({"id": mid, "error": cfg.get("initError") or
                  {"code": -32002, "message": "initialize failed"}})
            continue
    if method == "initialize" and cfg.get("initError"):
        send({"id": mid, "error": cfg["initError"]})
    elif method == "initialize":
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
        if cfg.get("sessionModels") is not None:
            result["models"] = cfg["sessionModels"]
        if method == "session/new":
            result["sessionId"] = cfg.get("sessionId") or "fake-session-%d-%d" % (os.getpid(), sessions)
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
