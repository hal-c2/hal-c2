# Codex's own goal for the fake app-server (`thread/goal/get|set|clear`), imported by
# fake_codex.py. One goal per process. FAKE_CODEX_GOAL seeds it (JSON
# {"objective", "status"}). While the goal is active Codex works toward it in turns of
# its own: one starts when the goal becomes active with no turn running, and another
# each time a turn completes, FAKE_CODEX_GOAL_TURNS (default 2) of them in all, the
# last marking the goal complete. FAKE_CODEX_GOAL_STALL: Codex never starts one.
# FAKE_CODEX_GOAL_FINISH_FIRST: setting the goal active reports it complete before the
# answer, which still shows it active, as a Codex that finished the goal first would.
# FAKE_CODEX_GOAL_DONE_BEFORE_STOP: clearing or pausing the goal reports it complete
# before the answer, as a Codex that finished it just before the user's command would
# (a clear's own report then comes ahead of the answer too).
import json, os, time

MAX_OBJECTIVE = 4000

_send = None
goal = None
running = False
goal_turns = 0

def setup(send):
    global _send, goal
    _send = send
    seed = os.environ.get("FAKE_CODEX_GOAL")
    if seed:
        goal = _goal(**json.loads(seed))

def _goal(objective, status="active"):
    now = int(time.time())
    return {"threadId": None, "objective": objective, "status": status, "tokensUsed": 0,
            "tokenBudget": None, "timeUsedSeconds": 0, "createdAt": now, "updatedAt": now}

def _updated(thread, turn=None):
    _send({"method": "thread/goal/updated",
           "params": {"threadId": thread, "turnId": turn, "goal": {**goal, "threadId": thread}}})

def _done(thread):
    global goal
    goal = {**goal, "status": "complete", "updatedAt": int(time.time())}
    _updated(thread)

def request(mid, method, params):
    global goal
    thread = params.get("threadId")
    if method == "thread/goal/get":
        _send({"id": mid, "result": {"goal": goal and {**goal, "threadId": thread}}})
    elif method == "thread/goal/clear":
        cleared = goal is not None
        early = cleared and os.environ.get("FAKE_CODEX_GOAL_DONE_BEFORE_STOP")
        if early:
            _done(thread)
        goal = None
        if early:
            _send({"method": "thread/goal/cleared", "params": {"threadId": thread}})
        _send({"id": mid, "result": {"cleared": cleared}})
        if cleared and not early:
            _send({"method": "thread/goal/cleared", "params": {"threadId": thread}})
    elif method == "thread/goal/set":
        objective = params.get("objective")
        if objective is not None and len(objective) > MAX_OBJECTIVE:
            _send({"id": mid, "error": {"code": -32600, "message": f"goal objective must be at most {MAX_OBJECTIVE} characters"}})
            return
        if objective is not None:
            goal = _goal(objective, params.get("status") or "active")
        elif goal is None:
            _send({"id": mid, "error": {"code": -32600, "message": "thread has no goal"}})
            return
        elif params.get("status"):
            if params["status"] == "paused" and os.environ.get("FAKE_CODEX_GOAL_DONE_BEFORE_STOP"):
                _done(thread)
            goal = {**goal, "status": params["status"], "updatedAt": int(time.time())}
        if os.environ.get("FAKE_CODEX_GOAL_FINISH_FIRST") and goal["status"] == "active":
            answer = {**goal, "threadId": thread}
            goal = {**goal, "status": "complete", "updatedAt": int(time.time())}
            _updated(thread)
            _send({"id": mid, "result": {"goal": answer}})
            return
        _send({"id": mid, "result": {"goal": {**goal, "threadId": thread}}})
        _updated(thread)
        if goal["status"] == "active" and not running:
            _goal_turn(thread)
    else:
        _send({"id": mid, "error": {"code": -32601, "message": method}})

# Called with every message the fake sends, after it is written.
def sent(msg):
    global running
    method = msg.get("method")
    if method == "turn/started":
        running = True
    elif method == "turn/completed":
        running = False
        params = msg["params"]
        if params["turn"].get("status") == "completed" and goal and goal["status"] == "active":
            _goal_turn(params["threadId"])

def _goal_turn(thread):
    global goal, goal_turns
    if os.environ.get("FAKE_CODEX_GOAL_STALL") or goal_turns >= int(os.environ.get("FAKE_CODEX_GOAL_TURNS", "2")):
        return
    goal_turns += 1
    turn = f"goal-turn-{goal_turns}"
    ctx = {"threadId": thread, "turnId": turn}
    _send({"method": "turn/started", "params": {**ctx, "turn": {"id": turn, "status": "inProgress"}}})
    item = f"msg-{turn}"
    text = f"Working toward the goal ({goal_turns})"
    _send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": item, "text": ""}}})
    _send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": item, "text": text}}})
    if goal_turns >= int(os.environ.get("FAKE_CODEX_GOAL_TURNS", "2")):
        goal = {**goal, "status": "complete", "updatedAt": int(time.time())}
        _updated(thread, turn)
    _send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn, "status": "completed"}}})
