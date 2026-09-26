# Fake `claude -p --input-format stream-json --output-format stream-json` for tests.
# Plays one turn per user message: thinking, a Bash tool call, and a streamed answer.
# A message containing "wait" stays open until an interrupt control request; "approve"
# asks permission for a command ("approve run: CMD" names it), "ask" asks a question
# (AskUserQuestion), and "where are we" says which message the session resumed at
# (--resume-session-at); "usage limit until EPOCH" stops on a usage limit. Rules a
# permission answer adds for the session (updatedPermissions) let later matching
# commands run without asking. Each turn's message text is appended to
# $FAKE_CLAUDE_LOG when it is set.
import json, os, re, sys, uuid

# With FAKE_CLAUDE_TRACE set, the argv and every message read are appended to it as JSON lines.
TRACE = os.environ.get("FAKE_CLAUDE_TRACE")
def trace(entry):
    if TRACE:
        with open(TRACE, "a") as f:
            f.write(json.dumps(entry) + "\n")

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

session = "fake-session-1"
# With FAKE_SESSIONS set, the fake keeps transcripts the way Claude Code does:
# $CLAUDE_CONFIG_DIR/projects/<working directory, each other character a dash>/<session
# id>.jsonl, one entry per message recording its cwd, sessionId and the version that
# wrote it. --resume takes a session id (looked up for the working directory) or a
# transcript's path, and --fork-session continues it as a new session; a missing
# transcript, or one written by a newer version than FAKE_CLAUDE_VERSION, ends the
# process as Claude Code does.
SESSIONS = os.environ.get("CLAUDE_CONFIG_DIR") if os.environ.get("FAKE_SESSIONS") else None
VERSION = os.environ.get("FAKE_CLAUDE_VERSION", "2.1.0")
transcript, earlier = None, []

def version(text):
    return tuple(int(part) for part in text.split(".") if part.isdigit())

def record(role, text):
    if transcript:
        with open(transcript, "a") as f:
            f.write(json.dumps({"type": role, "sessionId": session, "cwd": os.getcwd(), "version": VERSION,
                                "uuid": str(uuid.uuid4()), "message": {"role": role, "content": text}}) + "\n")

if SESSIONS:
    folder = os.path.join(SESSIONS, "projects", re.sub(r"[^A-Za-z0-9]", "-", os.getcwd()))
    resume = sys.argv[sys.argv.index("--resume") + 1] if "--resume" in sys.argv else None
    entries = []
    if resume:
        source = resume if resume.endswith(".jsonl") else os.path.join(folder, resume + ".jsonl")
        if not os.path.exists(source):
            sys.stderr.write(f"No conversation found with session ID: {resume}\n")
            sys.exit(1)
        with open(source) as f:
            entries = [json.loads(line) for line in f if line.strip()]
        newest = max((e.get("version", "0") for e in entries), key=version, default="0")
        if version(newest) > version(VERSION):
            sys.stderr.write(f"This session was written by Claude Code {newest}; update to open it.\n")
            sys.exit(1)
        earlier = [e["message"]["content"] for e in entries if e.get("type") == "user"]
    if resume and "--fork-session" not in sys.argv:
        session, transcript = os.path.basename(source)[:-6], source
    else:
        session = str(uuid.uuid4())
        os.makedirs(folder, exist_ok=True)
        transcript = os.path.join(folder, session + ".jsonl")
        with open(transcript, "w") as f:
            for e in entries:
                f.write(json.dumps({**e, "sessionId": session}) + "\n")
# FAKE_CLAUDE_ARGV_LOG names a file each start appends its arguments to, as one JSON list.
if os.environ.get("FAKE_CLAUDE_ARGV_LOG"):
    with open(os.environ["FAKE_CLAUDE_ARGV_LOG"], "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\n")
turn = 0
session_rules = []  # Bash commands the session allows without asking
resume_at = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--resume-session-at=")), None)
# The permission mode, from argv and then set_permission_mode; in auto Claude's own
# classifier approves the command "approve" would otherwise ask about.
mode = sys.argv[sys.argv.index("--permission-mode") + 1] if "--permission-mode" in sys.argv else "default"
trace({"argv": sys.argv[1:]})
for line in sys.stdin:
    msg = json.loads(line)
    trace({"in": msg})
    if msg.get("type") == "control_response":
        reply = msg["response"]["response"]
        allowed = reply["behavior"] == "allow"
        for update in reply.get("updatedPermissions") or []:
            if update.get("destination") == "session" and update.get("behavior") == "allow":
                session_rules += [r.get("ruleContent") for r in update.get("rules", []) if r.get("toolName") == "Bash"]
        answers = reply.get("updatedInput", {}).get("answers")
        text = ("answered " + json.dumps(answers, sort_keys=True)) if answers is not None else ("allowed" if allowed else "denied")
        send({"type": "assistant", "session_id": session, "message": {"id": "m-perm", "role": "assistant", "content": [{"type": "text", "text": text}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if msg.get("type") == "control_request":
        sub = msg["request"]["subtype"]
        # Plan usage; FAKE_CLAUDE_USAGE=unsupported is an account without plan limits.
        if sub == "get_usage":
            usage = {"rate_limits_available": False, "rate_limits": None} if os.environ.get("FAKE_CLAUDE_USAGE") == "unsupported" else {
                "rate_limits_available": True,
                "rate_limits": {
                    "five_hour": {"utilization": 30, "resets_at": "2026-09-24T15:00:00.123456+00:00"},
                    "seven_day": {"utilization": 55.5, "resets_at": None},
                    "model_scoped": [{"display_name": "Fable 1", "utilization": 12, "resets_at": "2026-09-30T00:00:00Z"}]}}
            send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": usage}})
            continue
        # The account a signed-in Claude Code reports when it starts.
        if sub == "set_permission_mode":
            mode = msg["request"]["mode"]
        # FAKE_CLAUDE_COMMANDS is a JSON list of the slash command names it reports.
        reply = {"account": {"email": "me@example.com", "subscriptionType": "max", "tokenSource": "claude.ai"},
                 "commands": [{"name": n, "description": "", "argumentHint": ""} for n in json.loads(os.environ.get("FAKE_CLAUDE_COMMANDS", "[]"))]} if sub == "initialize" else {}
        send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": reply}})
        if sub == "interrupt":
            send({"type": "result", "subtype": "error_during_execution", "is_error": True, "session_id": session})
        continue
    if msg.get("type") != "user":
        continue
    # $FAKE_CLAUDE_PROMPT_LOG records every user message's text, one JSON string per line.
    if os.environ.get("FAKE_CLAUDE_PROMPT_LOG"):
        with open(os.environ["FAKE_CLAUDE_PROMPT_LOG"], "a") as prompt_log:
            content = msg["message"]["content"]
            prompt_log.write(json.dumps(content if isinstance(content, str) else "".join(b.get("text", "") for b in content if isinstance(b, dict))) + "\n")
    # A steer cuts the running turn short and answers the new message in the same turn.
    if msg.get("priority") == "now":
        steer_text = msg["message"]["content"] if isinstance(msg["message"]["content"], str) else ""
        send({"type": "result", "subtype": "error_during_execution", "is_error": True, "terminal_reason": "aborted_streaming", "session_id": session})
        send({"type": "assistant", "session_id": session, "message": {"id": "m-steer", "role": "assistant", "content": [{"type": "text", "text": "steered: " + steer_text}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    turn += 1
    text = msg["message"]["content"] if isinstance(msg["message"]["content"], str) else ""
    if os.environ.get("FAKE_CLAUDE_LOG"):
        with open(os.environ["FAKE_CLAUDE_LOG"], "a") as f:
            f.write(json.dumps({"text": text}) + "\n")
    # FAKE_CLAUDE_INPUT_LOG names a file each user message's text is appended to, as JSON.
    if os.environ.get("FAKE_CLAUDE_INPUT_LOG"):
        with open(os.environ["FAKE_CLAUDE_INPUT_LOG"], "a") as f:
            f.write(json.dumps(text) + "\n")
    send({"type": "system", "subtype": "init", "session_id": session, "model": "claude-haiku"})
    record("user", text)
    # "usage limit until EPOCH": the plan's five-hour window rejects the turn until then.
    if text.startswith("usage limit until "):
        resets = int(text.rsplit(" ", 1)[1])
        send({"type": "rate_limit_event", "session_id": session, "rate_limit_info": {"status": "rejected", "rateLimitType": "five_hour", "resetsAt": resets}})
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}l", "role": "assistant", "content": [{"type": "text", "text": "You've hit your limit"}]}})
        send({"type": "result", "subtype": "success", "is_error": True, "result": "You've hit your limit", "session_id": session})
        continue
    if "wait" in text:
        continue
    # FAKE_CLAUDE_SIGNED_OUT: a CLI with no login answers every message with an auth error.
    if os.environ.get("FAKE_CLAUDE_SIGNED_OUT"):
        send({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "error": "authentication_failed", "message": {"id": f"m{turn}x", "role": "assistant", "content": [{"type": "text", "text": "Invalid API key · Please run /login"}]}})
        send({"type": "result", "subtype": "success", "is_error": True, "result": "Invalid API key · Please run /login", "session_id": session})
        continue
    if "where are we" in text:
        send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}w", "role": "assistant", "content": [{"type": "text", "text": f"resumed at {resume_at} fork {'--fork-session' in sys.argv} history {'<conversation_history>' in text}" + (f" earlier [{' | '.join(earlier)}]" if SESSIONS else "")}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if "approve" in text and mode == "auto":
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}u", "role": "assistant", "content": [{"type": "tool_use", "id": f"tool-{turn}", "name": "Bash", "input": {"command": "touch x"}}]}})
        send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"tool-{turn}", "content": "", "is_error": False}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if "approve" in text:
        cmd = text.split("run: ", 1)[1] if "run: " in text else "touch x"
        if cmd in session_rules or None in session_rules:
            send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}r", "role": "assistant", "content": [{"type": "text", "text": f"ran {cmd} without asking"}]}})
            send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
            continue
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": cmd},
              "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": cmd}], "behavior": "allow", "destination": "localSettings"}]}})
        continue
    if "plan" in text:
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": {"plan": "# Plan\n- do it"}}})
        continue
    if "todo" in text:
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}t", "role": "assistant", "content": [{"type": "tool_use", "id": f"todo-{turn}", "name": "TodoWrite", "input": {"todos": [
            {"content": "Read the code", "status": "completed", "activeForm": "Reading"}, {"content": "Fix it", "status": "in_progress", "activeForm": "Fixing"}]}}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if "ask" in text:
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": {"questions": [
            {"question": "Which color?", "header": "Color", "multiSelect": False,
             "options": [{"label": "Red", "description": "Warm"}, {"label": "Blue", "description": ""}]}]}}})
        continue
    # "use TOOL" calls that tool; "rate limit" reports a nearly used-up session window.
    if text.startswith("use "):
        tool = text.split()[1]
        tool_input = {"command": "ls"} if tool == "Bash" else {"query": "elixir", "url": "https://example.com"} if tool.startswith("Web") else {"file_path": "a.txt", "content": "a"}
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}u", "role": "assistant", "content": [{"type": "tool_use", "id": f"tool-{turn}", "name": tool, "input": tool_input}]}})
        send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"tool-{turn}", "content": "done", "is_error": False}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if "rate limit" in text:
        send({"type": "rate_limit_event", "session_id": session, "rate_limit_info": {"status": "allowed_warning", "rateLimitType": "five_hour", "utilization": 0.91, "resetsAt": 1790000000}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    ev = lambda e: send({"type": "stream_event", "session_id": session, "event": e})
    send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}a", "role": "assistant", "content": [{"type": "thinking", "thinking": "Let me look."}]}})
    send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}b", "role": "assistant", "content": [{"type": "tool_use", "id": f"tool-{turn}", "name": "Bash", "input": {"command": "ls"}}]}})
    send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"tool-{turn}", "content": "a.txt\n", "is_error": False}]}})
    ev({"type": "message_start", "message": {"id": f"m{turn}c"}})
    ev({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
    for d in ["Hel", "lo from ", "claude"]:
        ev({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": d}})
    ev({"type": "content_block_stop", "index": 0})
    send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}c", "role": "assistant", "content": [{"type": "text", "text": "Hello from claude"}]}})
    send({"type": "result", "subtype": "success", "is_error": False, "result": "Hello from claude", "session_id": session})
