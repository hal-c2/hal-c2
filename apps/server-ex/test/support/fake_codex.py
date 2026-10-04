# Fake `codex app-server` for tests: answers the handshake and plays a scripted turn.
# A turn whose text contains "wait" stays running until turn/interrupt; "approve" asks
# to run a command, "ask" asks a question (item/tool/requestUserInput; "ask: Q" asks Q), and "write NAME"
# creates the file NAME ("edit NAME" reports a change to it; "indent", "fill", "fail" and "say" are below;
# steering with "say ..." ends a waiting turn with that answer). "where are we" says which native thread
# the turn ran on and whether handed-off history or merged work came with the message; "exit before
# starting" makes the process exit on turn/start. With FAKE_CODEX_LOG set, every request the MC sends
# is appended to that file as one JSON line, and every answer to our own requests as
# {"method": "response", "params": {"id": ..., "result": ...}}; while the file FAKE_CODEX_REJECT_STEER
# names exists, turn/steer is refused. "stream ..." turns pace themselves by gate files
# in FAKE_CODEX_GATE (see stream_reply); "answer from gate" waits for the gate file
# "answer" and replies with its contents, or with no message when it is empty.
import glob, json, os, re, sys, time, uuid

# With FAKE_CODEX_TRACE set, every message read is appended to it as a JSON line.
# FAKE_CODEX_MODELS is the JSON `data` model/list answers with.
TRACE = os.environ.get("FAKE_CODEX_TRACE")
def trace(entry):
    if TRACE:
        with open(TRACE, "a") as f:
            f.write(json.dumps(entry) + "\n")

# The arguments the app-server was started with, first in the trace.
trace({"argv": sys.argv[1:], "home": os.environ.get("CODEX_HOME")})

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

# Waits until the test creates the file NAME in FAKE_CODEX_GATE: the test's cue that it
# saw what the reply so far wrote.
def gate(name):
    path = os.path.join(os.environ["FAKE_CODEX_GATE"], name)
    while not os.path.exists(path):
        time.sleep(0.01)

# "stream paragraphs" writes three paragraphs and a code block in pieces; "stream a reply"
# writes text while a command runs and the plan changes. Each waits at gates in between.
def stream_reply(ctx, text):
    if "stream paragraphs" in text:
        parts = ["One.\n\nTw", "o.\n\n```\ncode", "\n```\n\nThree."]
    else:
        parts = ["Working on it.\n\nStill ", "going.\n\nDone."]
    msg = {**ctx, "item": {"type": "agentMessage", "id": "msg-stream", "text": ""}}
    send({"method": "item/started", "params": msg})
    for i, part in enumerate(parts):
        if i:
            gate(f"go-{i}")
        send({"method": "item/agentMessage/delta", "params": {**ctx, "itemId": "msg-stream", "delta": part}})
        if i == 0 and "stream a reply" in text:
            send({"method": "item/started", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-s", "command": "ls", "status": "inProgress"}}})
            send({"method": "item/commandExecution/outputDelta", "params": {**ctx, "itemId": "cmd-s", "delta": "a.txt\n"}})
            send({"method": "turn/plan/updated", "params": {**ctx, "plan": [{"step": "List files", "status": "inProgress"}]}})
    if "stream a reply" in text:
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-s", "command": "ls", "status": "completed", "aggregatedOutput": "a.txt\n", "exitCode": 0}}})
    send({"method": "item/completed", "params": {**ctx, "item": {**msg["item"], "text": "".join(parts)}}})
    send({"method": "turn/completed", "params": {**ctx, "turn": {"id": ctx["turnId"], "status": "completed"}}})

# "say A | B" answers with one assistant message per part and ends the turn.
def say(ctx, text):
    for i, part in enumerate(text[4:].split(" | ")):
        send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": f"msg-say-{ctx['turnId']}-{i}", "text": ""}}})
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": f"msg-say-{ctx['turnId']}-{i}", "text": part}}})
    send({"method": "turn/completed", "params": {**ctx, "turn": {"id": ctx["turnId"], "status": "completed"}}})


# With FAKE_SESSIONS set, the fake keeps rollout files the way Codex does, under
# $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl: a session_meta line
# naming the thread's cwd, then per turn a turn_context with its cwd and the user's
# message. thread/resume and thread/fork (by threadId, or by the rollout's `path`) read
# them back, and a rollout written by a newer Codex than FAKE_CODEX_VERSION is refused.
SESSIONS = os.environ.get("CODEX_HOME") if os.environ.get("FAKE_SESSIONS") else None
VERSION = os.environ.get("FAKE_CODEX_VERSION", "0.130.0")
rollout = None

def version(text):
    return tuple(int(part) for part in text.split(".") if part.isdigit())

def rollout_find(tid):
    found = glob.glob(os.path.join(SESSIONS, "sessions", "*", "*", "*", f"rollout-*-{tid}.jsonl"))
    return found[0] if found else None

def rollout_read(path):
    with open(path) as f:
        records = [json.loads(line) for line in f if line.strip()]
    meta = records[0]["payload"] if records and records[0].get("type") == "session_meta" else {}
    if version(meta.get("cli_version", "0")) > version(VERSION):
        raise ValueError(f"rollout {path} was written by a newer Codex ({meta.get('cli_version')})")
    return records

def rollout_append(record):
    if rollout:
        with open(rollout, "a") as f:
            f.write(json.dumps({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()), **record}) + "\n")

def rollout_new(tid, cwd, records=(), forked_from=None):
    global rollout
    now = time.gmtime()
    folder = os.path.join(SESSIONS, "sessions", time.strftime("%Y", now), time.strftime("%m", now), time.strftime("%d", now))
    os.makedirs(folder, exist_ok=True)
    rollout = os.path.join(folder, f"rollout-{time.strftime('%Y-%m-%dT%H-%M-%S', now)}-{tid}.jsonl")
    meta = {"id": tid, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", now), "cwd": cwd, "originator": "fake", "cli_version": VERSION}
    if forked_from:
        meta["forked_from_id"] = forked_from
    rollout_append({"type": "session_meta", "payload": meta})
    for record in records:
        if record.get("type") != "session_meta":
            with open(rollout, "a") as f:
                f.write(json.dumps(record) + "\n")

def rollout_history():
    if not rollout:
        return []
    with open(rollout) as f:
        records = [json.loads(line) for line in f if line.strip()]
    return [r["payload"]["content"][0]["text"] for r in records
            if r.get("type") == "response_item" and r["payload"].get("role") == "user"]

thread_id = "native-thread-1"
# Current Codex keeps paginated history, which only rewinds with thread/revert.
paginated = os.environ.get("FAKE_CODEX_LEGACY") != "1"
# FAKE_CODEX_PAGE_SIZE=N keeps N turns per history page; thread/revert only reaches the latest page.
page_size = int(os.environ.get("FAKE_CODEX_PAGE_SIZE", "0"))
turns = 0
finishing = False  # "finishing": the turn ends as a steer for it arrives
for line in sys.stdin:
    msg = json.loads(line)
    trace({"in": msg})
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    if os.environ.get("FAKE_CODEX_LOG") and method:
        with open(os.environ["FAKE_CODEX_LOG"], "a") as f:
            f.write(json.dumps({"method": method, "params": params}) + "\n")
    elif os.environ.get("FAKE_CODEX_LOG") and "result" in msg:
        with open(os.environ["FAKE_CODEX_LOG"], "a") as f:
            f.write(json.dumps({"method": "response", "params": {"id": mid, "result": msg["result"]}}) + "\n")
    if mid is None:
        continue
    # FAKE_CODEX_REQUEST_LOG collects the method of every request, one per line.
    if method and os.environ.get("FAKE_CODEX_REQUEST_LOG"):
        with open(os.environ["FAKE_CODEX_REQUEST_LOG"], "a") as f:
            f.write(method + "\n")
    # A reply to our question: say what was answered.
    if "result" in msg and mid == "input-1":
        ctx = pending_ctx
        text = "answered " + json.dumps(msg["result"]["answers"], sort_keys=True)
        send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-ask", "text": ""}}})
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-ask", "text": text}}})
        send({"method": "turn/completed", "params": {**ctx, "turn": {"id": ctx["turnId"], "status": "completed"}}})
        continue
    # A reply to our approval request: finish the command according to the decision.
    if "result" in msg and mid == "approval-1":
        decision = msg["result"]["decision"]
        ctx = pending_ctx
        status = "completed" if decision in ("accept", "acceptForSession") else "declined"
        if decision == "cancel":
            send({"method": "item/completed", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "touch x", "status": "declined", "aggregatedOutput": "", "exitCode": None}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": ctx["turnId"], "status": "interrupted"}}})
            continue
        if status == "completed":
            open("x", "w").write("approved\n")
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "touch x", "status": status, "aggregatedOutput": "", "exitCode": 0}}})
        send({"method": "turn/completed", "params": {**ctx, "turn": {"id": ctx["turnId"], "status": "completed"}}})
        continue
    # An answer to a request a test delivered to the MC as if from Codex: while a turn
    # waits, say what was received (item "msg-received-<id>", text "received <json>").
    if not method:
        ctx = globals().get("waiting_ctx")
        if ctx:
            item = {"type": "agentMessage", "id": f"msg-received-{mid}", "text": ""}
            send({"method": "item/started", "params": {**ctx, "item": item}})
            text = "received " + json.dumps(msg.get("result"), sort_keys=True)
            send({"method": "item/completed", "params": {**ctx, "item": {**item, "text": text}}})
        continue
    if method == "initialize":
        send({"id": mid, "result": {"userAgent": "fake", "platformOs": "test"}})
    elif method == "model/list":
        # FAKE_CODEX_MODELS replaces the default catalogue.
        send({"id": mid, "result": {"data": json.loads(os.environ.get("FAKE_CODEX_MODELS") or "null") or [
            {"id": "gpt-6-luna", "model": "gpt-6-luna", "displayName": "GPT-6 Luna", "isDefault": True},
            {"id": "gpt-5.5", "model": "gpt-5.5", "displayName": "GPT-5.5", "isDefault": False}]}})
    elif method == "feedback/upload":
        send({"id": mid, "result": {"threadId": f"feedback-for-{params['threadId']}"}})
    elif method in ("thread/start", "thread/resume"):
        # FAKE_CODEX_SESSION_LOG collects each thread/start and thread/resume's params.
        if os.environ.get("FAKE_CODEX_SESSION_LOG"):
            with open(os.environ["FAKE_CODEX_SESSION_LOG"], "a") as f:
                f.write(json.dumps({"method": method, "params": params}) + "\n")
        if SESSIONS and method == "thread/start":
            thread_id = str(uuid.uuid4())
            rollout_new(thread_id, params.get("cwd"))
        elif SESSIONS:
            path = rollout_find(params["threadId"])
            try:
                if not path:
                    raise ValueError(f"no rollout found for thread id {params['threadId']}")
                rollout_read(path)
            except ValueError as error:
                send({"id": mid, "error": {"code": -32600, "message": str(error)}})
                continue
            thread_id, rollout = params["threadId"], path
        send({"id": mid, "result": {"thread": {"id": thread_id}}})
    elif method == "turn/start":
        # FAKE_CODEX_INPUT_LOG collects every turn's input, one JSON line each.
        if os.environ.get("FAKE_CODEX_INPUT_LOG"):
            with open(os.environ["FAKE_CODEX_INPUT_LOG"], "a") as f:
                f.write(json.dumps(params["input"]) + "\n")
        turns += 1
        turn_id = f"native-turn-{turns}"
        prompt = params["input"][0]["text"]
        # The script plays from the user's message, not from the context the MC hands
        # off ahead of it (`<conversation_history>`, `<imported_history>`, ...).
        text = re.sub(r"\A(?:<(\w+)>\n.*?\n</\1>\n\n)+", "", prompt, flags=re.S)
        rollout_append({"type": "turn_context", "payload": {"cwd": params.get("cwd"), "model": params.get("model")}})
        rollout_append({"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": prompt}]}})
        if "exit before starting" in text:
            sys.exit(1)
        send({"id": mid, "result": {"turn": {"id": turn_id, "status": "inProgress"}}})
        ctx = {"threadId": thread_id, "turnId": turn_id}
        send({"method": "turn/started", "params": {**ctx, "turn": {"id": turn_id, "status": "inProgress"}}})
        if "stream paragraphs" in text or "stream a reply" in text:
            stream_reply(ctx, text)
            continue
        if "answer from gate" in text:
            gate("answer")
            answer = open(os.path.join(os.environ["FAKE_CODEX_GATE"], "answer")).read()
            if answer:
                send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-gate", "text": ""}}})
                send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-gate", "text": answer}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        # "in the background" starts a dev server in a unified exec terminal and ends the
        # turn with it running (or, with "wait", keeps the turn open); Codex reports it
        # later, when it exits. thread/backgroundTerminals/terminate stops it.
        if "in the background" in text:
            send({"method": "item/started", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-bg", "command": "npm run dev", "processId": "4275", "source": "unifiedExecStartup", "status": "inProgress"}}})
            send({"method": "item/commandExecution/outputDelta", "params": {**ctx, "itemId": "cmd-bg", "delta": "listening on 5173\n"}})
            if "wait" not in text:
                send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-bg", "text": ""}}})
                send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-bg", "text": "The dev server is running."}}})
                send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
                continue
        if "wait" in text or "finishing" in text:
            waiting_ctx = ctx
            finishing = "finishing" in text
            continue
        if text.startswith("say "):
            say(ctx, text)
            continue
        if "where are we" in text:
            where = f"on {thread_id} history {'<conversation_history>' in prompt} merged {'<merged_work>' in prompt}"
            if SESSIONS:
                where += " earlier [" + " | ".join(rollout_history()[:-1]) + "]"
            send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-where", "text": ""}}})
            send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-where", "text": where}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        if text.startswith("repeat"):
            # Unique per turn, as Codex's item ids are.
            send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": f"msg-repeat-{turns}", "text": ""}}})
            send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": f"msg-repeat-{turns}", "text": text}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        if text.startswith("write "):
            name = text.split()[1]
            os.makedirs(os.path.dirname(name) or ".", exist_ok=True)
            open(name, "w").write(text + "\n")
        # "edit NAME" reports a change to NAME (a fileChange item) before the usual answer.
        if text.startswith("edit "):
            name = text.split()[1]
            change = {"path": name, "kind": {"type": "update"}, "diff": "@@ -1 +1 @@\n-old\n+new\n"}
            send({"method": "item/completed", "params": {**ctx, "item": {"type": "fileChange", "id": "file-1", "status": "completed", "changes": [change]}}})
        # "indent NAME" re-indents every line of NAME; "fill NAME" writes 11 MB to it.
        if text.startswith("indent "):
            name = text.split()[1]
            lines = open(name).read().splitlines(True)
            open(name, "w").write("".join("  " + line for line in lines))
        if text.startswith("fill "):
            open(text.split()[1], "w").write(("x" * 99 + "\n") * 110_000)
        # "fail" ends the turn as failed.
        if text.startswith("fail"):
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "failed", "error": {"message": "the turn failed"}}}})
            continue
        if "look" in text:
            kinds = [item["type"] for item in params["input"]]
            saved = "is saved at" in text
            send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-look", "text": ""}}})
            send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-look", "text": f"input {','.join(kinds)} saved {saved}"}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        # "spawn a subagent": the spawnAgent tool starts a thread of its own, which
        # answers under its thread id and ends its turn before the tool call completes.
        if "spawn a subagent" in text:
            child = {"threadId": "native-child-1", "turnId": "native-child-turn-1"}
            call = {"type": "collabAgentToolCall", "id": "collab-1", "tool": "spawnAgent", "prompt": "List the modules in lib",
                    "senderThreadId": thread_id, "receiverThreadIds": [child["threadId"]]}
            send({"method": "item/started", "params": {**ctx, "item": {**call, "status": "inProgress", "agentsStates": {}}}})
            send({"method": "item/started", "params": {**child, "item": {"type": "agentMessage", "id": "child-msg", "text": ""}}})
            send({"method": "item/agentMessage/delta", "params": {**child, "itemId": "child-msg", "delta": "lib has three modules"}})
            send({"method": "item/completed", "params": {**child, "item": {"type": "agentMessage", "id": "child-msg", "text": "lib has three modules"}}})
            send({"method": "turn/completed", "params": {**child, "turn": {"id": child["turnId"], "status": "completed"}}})
            send({"method": "item/completed", "params": {**ctx, "item": {**call, "status": "completed",
                  "agentsStates": {child["threadId"]: {"status": "completed", "message": "lib has three modules"}}}}})
            send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-sub", "text": ""}}})
            send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-sub", "text": "The subagent found three modules."}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        if "plan" in text:
            mode = (params.get("collaborationMode") or {}).get("mode")
            if mode == "plan":
                send({"method": "turn/plan/updated", "params": {**ctx, "explanation": "Two steps", "plan": [
                    {"step": "Read the code", "status": "completed"}, {"step": "Write the plan", "status": "inProgress"}]}})
                send({"method": "item/started", "params": {**ctx, "item": {"type": "plan", "id": "plan-1", "text": ""}}})
                for delta in ["# Plan\n", "- do it"]:
                    send({"method": "item/plan/delta", "params": {**ctx, "itemId": "plan-1", "delta": delta}})
                send({"method": "item/completed", "params": {**ctx, "item": {"type": "plan", "id": "plan-1", "text": "# Plan\n- do it"}}})
            else:
                send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-mode", "text": ""}}})
                send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-mode", "text": f"mode {mode}"}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        # "ask and approve" asks a question and for an approval in one turn.
        if "ask and approve" in text:
            pending_ctx = ctx
            send({"id": "input-1", "method": "item/tool/requestUserInput", "params": {**ctx, "itemId": "ask-1", "questions": [
                {"id": "color", "header": "Color", "question": "Which color?", "options": [{"label": "Red", "description": "Warm"}]}]}})
            send({"method": "item/started", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "touch x", "status": "inProgress"}}})
            send({"id": "approval-1", "method": "item/commandExecution/requestApproval", "params": {**ctx, "itemId": "cmd-1", "command": "touch x"}})
            continue
        if "ask" in text:
            pending_ctx = ctx
            send({"id": "input-1", "method": "item/tool/requestUserInput", "params": {**ctx, "itemId": "ask-1", "questions": [
                {"id": "color", "header": "Color", "question": text.split("ask: ", 1)[1] if "ask: " in text else "Which color?", "options": [{"label": "Red", "description": "Warm"}]}]}})
            continue
        if "rate limit" in text:
            send({"method": "account/rateLimits/updated", "params": {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 77, "windowDurationMins": 300}}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        # "usage limit" stops the turn on a used-up weekly window resetting in 5d 5h;
        # FAKE_CODEX_REACHED is the snapshot's rateLimitReachedType.
        if "usage limit" in text:
            import time
            snapshot = {"limitId": "codex", "planType": "pro", "primary": {"usedPercent": 40, "windowDurationMins": 300, "resetsAt": int(time.time()) + 3600},
                        "secondary": {"usedPercent": 100, "windowDurationMins": 10080, "resetsAt": int(time.time()) + 5 * 86400 + 5 * 3600 - 30}}
            if os.environ.get("FAKE_CODEX_REACHED"):
                snapshot["rateLimitReachedType"] = os.environ["FAKE_CODEX_REACHED"]
            send({"method": "account/rateLimits/updated", "params": {"rateLimits": snapshot}})
            send({"method": "error", "params": {**ctx, "willRetry": False, "error": {"message": "You've hit your usage limit.", "codexErrorInfo": "usageLimitExceeded"}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "failed", "error": {"message": "You've hit your usage limit."}}}})
            continue
        # "approve file" asks to change a file, "approve permissions" to widen the sandbox.
        if "approve file" in text:
            pending_ctx = ctx
            send({"method": "item/started", "params": {**ctx, "item": {"type": "fileChange", "id": "cmd-1", "changes": [{"path": "x", "kind": {"type": "add"}, "diff": "approved"}], "status": "inProgress"}}})
            send({"id": "approval-1", "method": "item/fileChange/requestApproval", "params": {**ctx, "itemId": "cmd-1", "reason": "write x"}})
            continue
        if "approve permissions" in text:
            pending_ctx = ctx
            send({"id": "approval-1", "method": "item/permissions/requestApproval", "params": {**ctx, "itemId": "perm-1", "reason": "network access", "permissions": {"network": True}}})
            continue
        # In auto, Codex's own reviewer approves the command instead of asking the client.
        if "approve" in text and params.get("approvalsReviewer") == "auto_review":
            review = {**ctx, "reviewId": "review-1", "targetItemId": "cmd-1", "action": {"type": "command", "command": "touch x"}, "startedAtMs": 0}
            send({"method": "item/started", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "touch x", "status": "inProgress"}}})
            send({"method": "item/autoApprovalReview/started", "params": {**review, "review": {"status": "inProgress"}}})
            send({"method": "item/autoApprovalReview/completed", "params": {**review, "review": {"status": "approved"}, "decisionSource": "agent", "completedAtMs": 0}})
            open("x", "w").write("approved\n")
            send({"method": "item/completed", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "touch x", "status": "completed", "aggregatedOutput": "", "exitCode": 0}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        if "approve" in text:
            pending_ctx = ctx
            send({"method": "item/started", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "touch x", "status": "inProgress"}}})
            send({"id": "approval-1", "method": "item/commandExecution/requestApproval", "params": {**ctx, "itemId": "cmd-1", "command": "touch x"}})
            continue
        send({"method": "item/started", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "ls", "status": "inProgress"}}})
        send({"method": "item/commandExecution/outputDelta", "params": {**ctx, "itemId": "cmd-1", "delta": "a.txt\n"}})
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "ls", "status": "completed", "aggregatedOutput": "a.txt\n", "exitCode": 0}}})
        send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-1", "text": ""}}})
        for delta in ["Hel", "lo ", "from ", "codex"]:
            send({"method": "item/agentMessage/delta", "params": {**ctx, "itemId": "msg-1", "delta": delta}})
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-1", "text": "Hello from codex"}}})
        send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
    elif method == "turn/steer":
        ctx = waiting_ctx
        if finishing:
            # The turn ended before the steer got there.
            finishing = False
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": ctx["turnId"], "status": "completed"}}})
            send({"id": mid, "error": {"code": -32600, "message": "no active turn to steer"}})
            continue
        if params["expectedTurnId"] != ctx["turnId"] or os.path.exists(os.environ.get("FAKE_CODEX_REJECT_STEER", "/nonexistent")):
            send({"id": mid, "error": {"code": -32600, "message": "turn moved on"}})
            continue
        send({"id": mid, "result": {"turnId": ctx["turnId"]}})
        if params["input"][0]["text"].startswith("say "):
            say(ctx, params["input"][0]["text"])
            continue
        text = "steered: " + params["input"][0]["text"]
        images = sum(1 for i in params["input"] if i["type"] == "image")
        if images:
            text += f" (+{images} image)"
        # A running turn passes on a new quota reading, as Codex does alongside token usage.
        if "rate limit" in text:
            send({"method": "account/rateLimits/updated", "params": {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 77, "windowDurationMins": 300}}}})
        send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-steer", "text": ""}}})
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-steer", "text": text}}})
        send({"method": "turn/completed", "params": {**ctx, "turn": {"id": ctx["turnId"], "status": "completed"}}})
    elif method == "thread/fork" and SESSIONS:
        # A fork by `path` reads that rollout; the new thread works in the given cwd.
        path = params.get("path") or rollout_find(params["threadId"])
        try:
            if not path or not os.path.exists(path):
                raise ValueError(f"no rollout found for thread id {params.get('threadId')}")
            records = rollout_read(path)
        except ValueError as error:
            send({"id": mid, "error": {"code": -32600, "message": str(error)}})
            continue
        source = records[0]["payload"]["id"]
        thread_id = str(uuid.uuid4())
        rollout_new(thread_id, params.get("cwd") or records[0]["payload"].get("cwd"), records, source)
        send({"id": mid, "result": {"thread": {"id": thread_id}}})
    elif method == "thread/fork":
        thread_id = f"forked-{params['threadId']}-at-{params.get('lastTurnId')}"
        send({"id": mid, "result": {"thread": {"id": thread_id}}})
    elif method == "thread/revert" and paginated and page_size and int(params["beforeTurnId"].rsplit("-", 1)[1]) <= turns - page_size:
        send({"id": mid, "error": {"code": -32600, "message": f"{params['beforeTurnId']} is not on the latest history page"}})
    elif method == "thread/revert" and paginated:
        thread_id = f"native-thread-1-before-{params['beforeTurnId']}"
        send({"id": mid, "result": {"thread": {"id": thread_id, "turns": []}}})
    elif method == "thread/rollback" and paginated:
        send({"id": mid, "error": {"code": -32600, "message": "paginated threads do not support thread/rollback"}})
    elif method == "thread/rollback":
        # The returned id says how many turns were dropped.
        thread_id = f"native-thread-1-dropped-{params['numTurns']}"
        send({"id": mid, "result": {"thread": {"id": thread_id}}})
    # Account and quota: FAKE_CODEX_ACCOUNT picks the account type ("none" signs out).
    # A reset credit redemption logs its idempotency key to FAKE_CODEX_CONSUME_LOG and
    # fails once while the FAKE_CODEX_CONSUME_FAIL file exists.
    elif method == "account/read":
        kind = os.environ.get("FAKE_CODEX_ACCOUNT", "chatgpt")
        account = None if kind == "none" else {"type": kind, "email": "me@example.com", "planType": "pro"}
        send({"id": mid, "result": {"account": account, "requiresOpenaiAuth": True}})
    # FAKE_CODEX_RESET_CREDITS sets how many reset credits are banked (default two);
    # FAKE_CODEX_CONSUME_OUTCOME is what a redemption answers (default "reset").
    elif method == "account/rateLimits/read":
        # After a successful redemption the session window starts over and one credit is gone.
        consumed = os.environ.get("FAKE_CODEX_CONSUME_LOG")
        reset = bool(consumed) and os.path.exists(consumed + ".reset")
        count = os.environ.get("FAKE_CODEX_RESET_CREDITS")
        if count is None:
            credits = {"availableCount": 1 if reset else 2, "credits": [
                {"status": "available", "expiresAt": 1800000000},
                {"status": "redeemed" if reset else "available", "expiresAt": 1795000000},
                {"status": "redeemed", "expiresAt": 1700000000}]}
        else:
            credits = {"availableCount": int(count), "credits": [
                {"status": "available", "expiresAt": 1800000000 + i} for i in range(int(count))]}
        main = {"limitId": "codex", "planType": "pro",
                "primary": {"usedPercent": 0 if reset else 42, "windowDurationMins": 300, "resetsAt": 1790000000},
                "secondary": {"usedPercent": 10.5, "resetsAt": 1790500000}}
        send({"id": mid, "result": {
            "rateLimits": {"limitId": "codex_spark", "primary": {"usedPercent": 99}},
            "rateLimitsByLimitId": {"codex": main, "codex_spark": {"limitId": "codex_spark", "primary": {"usedPercent": 99}}},
            "rateLimitResetCredits": credits}})
    elif method == "account/rateLimitResetCredit/consume":
        with open(os.environ["FAKE_CODEX_CONSUME_LOG"], "a") as f:
            f.write(params["idempotencyKey"] + "\n")
        flag = os.environ.get("FAKE_CODEX_CONSUME_FAIL", "")
        if flag and os.path.exists(flag):
            os.remove(flag)
            send({"id": mid, "error": {"code": -32000, "message": "upstream unavailable"}})
        else:
            outcome = os.environ.get("FAKE_CODEX_CONSUME_OUTCOME", "reset")
            if outcome == "reset":
                open(os.environ["FAKE_CODEX_CONSUME_LOG"] + ".reset", "w").close()
            send({"id": mid, "result": {"outcome": outcome}})
    elif method == "thread/backgroundTerminals/terminate":
        send({"id": mid, "result": {"terminated": True}})
    elif method == "turn/interrupt":
        send({"id": mid, "result": {}})
        send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": params["turnId"], "status": "interrupted"}}})
    else:
        send({"id": mid, "error": {"code": -32601, "message": method}})
