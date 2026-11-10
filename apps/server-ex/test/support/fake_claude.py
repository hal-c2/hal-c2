# Fake `claude -p --input-format stream-json --output-format stream-json` for tests.
# Plays one turn per user message: thinking, a Bash tool call, and a streamed answer.
# A message containing "wait" stays open until an interrupt control request; "approve"
# asks permission for a command ("approve run: CMD" names it), "ask" asks a question
# (AskUserQuestion), "long session" asks whether to compact first when the session was
# resumed (the resume_return dialog, only for a host that said it can show it, answered
# with "resume RESULT"), and "where are we" says which message the session resumed at
# (--resume-session-at); "usage limit until EPOCH" stops on a usage limit; "in the
# background" starts a background subagent (task task-agent-N) and a background command
# (task task-bash-N) and ends the turn while both run, their task_notification left to
# the test; "background commands: A, B" starts one background command per name and
# ends the turn while they run; "subagent leaves work running" runs a subagent that starts a background
# command and returns "Dev server started" while the command runs on; "subagent approve
# run: CMD" runs a subagent that asks permission for CMD and returns "ran CMD" when
# allowed, "was not allowed to run CMD" otherwise. Rules a
# permission answer adds for the session (updatedPermissions) let later matching
# commands run without asking; "call a skill" calls the demo skill twice, with
# and without arguments; "edit a file" writes edited.txt through a Write call. "mcp
# confirm" is an MCP tool eliciting a yes or no (twice over when it says so), answered
# "elicitation ACTION"; "mcp sign in", "mcp form" and "mcp undescribed" elicit a web
# sign-in, form values, and input no schema describes. "which tools" names the MCP
# servers the host handed over (mcp_set_servers), and "run env" runs `env` as a child
# process, the way Claude runs a shell command, a hook or a local MCP server, and
# answers with what it printed.
# Each turn's message text is appended to
# $FAKE_CLAUDE_LOG when it is set.
import json, os, re, subprocess, sys, threading, time, uuid

# With FAKE_CLAUDE_TRACE set, the argv and every message read are appended to it as JSON lines.
TRACE = os.environ.get("FAKE_CLAUDE_TRACE")
def trace(entry):
    if TRACE:
        with open(TRACE, "a") as f:
            f.write(json.dumps(entry) + "\n")

# A held MCP answer is sent from its own thread (answer_mcp_servers).
sending = threading.Lock()
# With FAKE_CLAUDE_USAGE set, every result reports token usage, as Claude's do, a
# stopped or failed turn's too.
USAGE = os.environ.get("FAKE_CLAUDE_USAGE")

def send(msg):
    if USAGE and msg.get("type") == "result" and "usage" not in msg:
        msg = {**msg, "usage": {"input_tokens": 1000, "output_tokens": 50}}
    with sending:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()

session = "fake-session-1"
# With FAKE_SESSIONS set, the fake keeps transcripts the way Claude Code does:
# $CLAUDE_CONFIG_DIR/projects/<working directory, each other character a dash>/<session
# id>.jsonl, one entry per message recording its cwd, sessionId and the version that
# wrote it. --resume takes a session id (looked up for the working directory) or a
# transcript's path, and --fork-session continues it as a new session; a missing
# transcript, one with no message, or one written by a newer version than FAKE_CLAUDE_VERSION, ends the
# process as Claude Code does.
SESSIONS = (os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")) if os.environ.get("FAKE_SESSIONS") else None
VERSION = os.environ.get("FAKE_CLAUDE_VERSION", "2.1.0")
if sys.argv[1:] and sys.argv[-1] == "--version":
    print(f"{VERSION} (Claude Code)")
    sys.exit(0)
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
        # A transcript with only metadata (the prompt Claude had not saved yet) holds no
        # conversation to resume.
        if not any(e.get("type") in ("user", "assistant") for e in entries):
            sys.stderr.write(f"No conversation found with session ID: {resume}\n")
            sys.exit(1)
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
asked_before_plan = False  # a "question first" turn waiting on its answer
asking_subagent = None  # (Agent tool id, command) of a subagent waiting on its permission answer
pending_tool = None  # the Bash call a "leave a tool pending" turn has not answered yet
goal = None  # the objective "/goal OBJECTIVE" set, until "/goal clear"
pending_elicit = None  # (request id, asks again after an accept) of an MCP elicitation waiting on its answer
dialogs = []  # the dialog kinds the host said it can show (initialize)
mcp_servers = {}  # the MCP servers the host handed over stdin (mcp_set_servers)

def prompt_blocked(text):
    try:
        with open(os.path.join(os.getcwd(), ".claude", "settings.json")) as f:
            groups = json.load(f).get("hooks", {}).get("UserPromptSubmit", [])
    except (OSError, ValueError):
        return None
    for hook in (h for group in groups for h in group.get("hooks", [])):
        run = subprocess.run(hook["command"], shell=True, input=json.dumps({"hook_event_name": "UserPromptSubmit", "prompt": text}),
                             capture_output=True, text=True)
        if run.returncode == 2:
            return f"Prompt dropped by a hook: {run.stderr.strip()}"
    return None

def answer_mcp_servers(msg):
    global mcp_servers
    scrub = os.environ.get("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB")
    expand = lambda v: re.sub(r"\$\{(\w+)\}", lambda m: "" if scrub else os.environ.get(m.group(1), ""), v)
    servers = {name: {**spec, "headers": {k: expand(v) for k, v in spec.get("headers", {}).items()}}
               for name, spec in msg["request"].get("servers", {}).items()}
    if os.environ.get("FAKE_CLAUDE_MCP_LOG"):
        with open(os.environ["FAKE_CLAUDE_MCP_LOG"], "a") as f:
            f.write(json.dumps(servers) + "\n")
    if os.environ.get("FAKE_CLAUDE_MCP_REFUSE"):
        # The error's text can echo what it was sent, the credential too.
        result = {"added": [], "removed": [], "errors": {name: f"Connection failed with {json.dumps(spec)}" for name, spec in servers.items()}}
    else:
        mcp_servers = servers
        result = {"added": list(servers), "removed": [], "errors": {}}
    send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": result}})
# FAKE_CLAUDE_ORPHANED names a background task the previous process left running. A
# resumed process queues its first message behind a turn of its own that reports the
# task stopped: its result has origin task-notification and echoes no message's uuid.
orphaned = os.environ.get("FAKE_CLAUDE_ORPHANED") if "--resume" in sys.argv else None
resume_at = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--resume-session-at=")), None)
# A subagent's messages are in a transcript of their own: Claude Code cannot resume the
# conversation at one and ends the process.
if resume_at and resume_at.startswith("sub-uuid-"):
    sys.stderr.write(f"No message found with message.uuid of: {resume_at}\n")
    sys.exit(1)
# The permission mode, from argv and then set_permission_mode; in auto Claude's own
# classifier approves the command "approve" would otherwise ask about.
mode = sys.argv[sys.argv.index("--permission-mode") + 1] if "--permission-mode" in sys.argv else "default"
# FAKE_CLAUDE_NO_AUTO: a model without auto mode. Claude Code runs it in its default
# mode instead, says so in its init message, and refuses a later switch to auto.
NO_AUTO = bool(os.environ.get("FAKE_CLAUDE_NO_AUTO"))
if NO_AUTO and mode == "auto":
    mode = "default"
# The login is the config directory's, as Claude Code keeps it (`.claude.json`'s
# oauthAccount); without one the fake is signed in as me@example.com.
ACCOUNT_EMAIL = "me@example.com"
try:
    with open(os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", ""), ".claude.json")) as f:
        ACCOUNT_EMAIL = json.load(f)["oauthAccount"]["emailAddress"]
except (OSError, ValueError, KeyError):
    pass
# `claude auth status` prints its sign-in as JSON and exits, before any session.
# FAKE_CLAUDE_AUTH_STATUS is that JSON, or "unknown" for a CLI too old to have the
# command (as FAKE_CLAUDE_NO_ACCOUNT's is: it reports no sign-in anywhere).
if sys.argv[1:] == ["auth", "status"]:
    spec = os.environ.get("FAKE_CLAUDE_AUTH_STATUS")
    if spec == "unknown" or (not spec and os.environ.get("FAKE_CLAUDE_NO_ACCOUNT")):
        sys.stderr.write("error: unknown command 'auth'\n")
        sys.exit(1)
    if spec:
        print(spec)
        sys.exit(0 if json.loads(spec).get("loggedIn") else 1)
    if os.environ.get("FAKE_CLAUDE_SIGNED_OUT"):
        print(json.dumps({"loggedIn": False, "authMethod": "none"}))
        sys.exit(1)
    print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty",
                      "email": ACCOUNT_EMAIL}))
    sys.exit(0)
# The start also traces where it was pointed: its config directory, its account and any router.
trace({"argv": sys.argv[1:], "pid": os.getpid(), "account": ACCOUNT_EMAIL, "env": {k: v for k, v in os.environ.items() if k.startswith("ANTHROPIC_") or k in ("CLAUDE_CONFIG_DIR", "HOME", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_TOOL_USE_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SHELL", "CLAUDE_CODE_ENABLE_TODO_TOOLS")}})
# Claude's safety check asks to run a command and forbids an always-allow rule
# (`suppressAlwaysAllowRule`), though its suggestions would allow every Bash command.
def ask_once():
    send({"type": "control_request", "request_id": "perm-once", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "rm -rf build"},
          "decision_reason": "rm -rf on a path Claude could not verify always asks", "decision_reason_type": "safetyCheck", "suppressAlwaysAllowRule": True,
          "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash"}], "behavior": "allow", "destination": "session"}]}})


for line in sys.stdin:
    msg = json.loads(line)
    trace({"in": msg})
    if msg.get("type") == "control_response":
        reply = msg["response"]["response"]
        # A cancelled approval interrupts the turn (the reply's interrupt flag).
        if reply.get("interrupt"):
            send({"type": "result", "subtype": "error_during_execution", "is_error": True, "terminal_reason": "aborted_tools", "session_id": session})
            continue
        if pending_elicit and "action" in reply:
            elicit_id, again = pending_elicit
            if again and reply["action"] == "accept":
                pending_elicit = ("elicit-2", False)
                send({"type": "control_request", "request_id": "elicit-2", "request": {"subtype": "elicitation", "mcp_server_name": "demo", "message": "Delete the file for sure?", "mode": "form", "requested_schema": {"type": "object", "properties": {}}}})
                continue
            pending_elicit = None
            send({"type": "assistant", "session_id": session, "message": {"id": "m-elicit", "role": "assistant", "content": [{"type": "text", "text": "elicitation " + reply["action"]}]}})
            send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
            continue
        if reply["behavior"] in ("completed", "cancelled"):
            send({"type": "assistant", "session_id": session, "message": {"id": "m-dialog", "role": "assistant", "content": [{"type": "text", "text": "resume " + reply.get("result", "cancelled")}]}})
            send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
            continue
        allowed = reply["behavior"] == "allow"
        if asking_subagent:
            agent, cmd = asking_subagent
            asking_subagent = None
            report = f"ran {cmd}" if allowed else f"was not allowed to run {cmd}"
            send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": agent,
                  "content": [{"type": "text", "text": report}]}]}})
            send({"type": "assistant", "session_id": session, "message": {"id": "m-sub-perm", "role": "assistant", "content": [{"type": "text", "text": f"The subagent {report}"}]}})
            send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
            continue
        for update in reply.get("updatedPermissions") or []:
            if update.get("destination") == "session" and update.get("behavior") == "allow":
                session_rules += [r.get("ruleContent") for r in update.get("rules", []) if r.get("toolName") == "Bash"]
        answers = reply.get("updatedInput", {}).get("answers")
        if asked_before_plan and answers is not None:
            asked_before_plan = False
            send({"type": "control_request", "request_id": "perm-2", "request": {"subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": {"plan": "# Plan\n- paint it " + " ".join(answers.values())}}})
            continue
        text = ("answered " + json.dumps(answers, sort_keys=True)) if answers is not None else ("allowed" if allowed else "denied")
        send({"type": "assistant", "session_id": session, "message": {"id": "m-perm", "role": "assistant", "content": [{"type": "text", "text": text}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if msg.get("type") == "control_request":
        sub = msg["request"]["subtype"]
        # Plan usage; FAKE_CLAUDE_USAGE=unsupported is an account without plan limits.
        if sub == "get_usage":
            # FAKE_CLAUDE_USAGE=error: the read fails, as it does for a Claude signed out.
            if os.environ.get("FAKE_CLAUDE_USAGE") == "error":
                send({"type": "control_response", "response": {"subtype": "error", "request_id": msg["request_id"], "error": "Not logged in · Please run /login"}})
                continue
            # FAKE_CLAUDE_USAGE=empty has limits but returns none, until the file it names is gone.
            empty = os.environ.get("FAKE_CLAUDE_USAGE_EMPTY")
            usage = {"rate_limits_available": False, "rate_limits": None} if os.environ.get("FAKE_CLAUDE_USAGE") == "unsupported" else {"rate_limits_available": True, "rate_limits": {}} if empty and os.path.exists(empty) else {
                "rate_limits_available": True,
                "rate_limits": {
                    "five_hour": {"utilization": 30, "resets_at": "2026-09-24T15:00:00.123456+00:00"},
                    "seven_day": {"utilization": 55.5, "resets_at": None},
                    "model_scoped": [{"display_name": "Fable 1", "utilization": 12, "resets_at": "2026-09-30T00:00:00Z"}]}}
            # FAKE_CLAUDE_MONTHLY=<percent>: the account's monthly spending limit, that used.
            if os.environ.get("FAKE_CLAUDE_MONTHLY") and isinstance(usage.get("rate_limits"), dict) and usage["rate_limits"]:
                usage["rate_limits"]["extra_usage"] = {"is_enabled": True, "utilization": float(os.environ["FAKE_CLAUDE_MONTHLY"]), "resets_at": "2026-10-01T00:00:00Z"}
            send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": usage}})
            continue
        # The account a signed-in Claude Code reports when it starts.
        if sub == "set_permission_mode" and NO_AUTO and msg["request"]["mode"] == "auto":
            send({"type": "control_response", "response": {"subtype": "error", "request_id": msg["request_id"], "error": "Cannot set permission mode to auto: auto mode unavailable for this model"}})
            continue
        # The MCP servers the host hands over stdin. Claude expands ${VAR} in their
        # headers from its environment, which CLAUDE_CODE_SUBPROCESS_ENV_SCRUB empties.
        # FAKE_CLAUDE_MCP_LOG gets each set's servers, expanded, as one JSON line;
        # FAKE_CLAUDE_MCP_REFUSE fails every one, as Claude reports a server it cannot add.
        # FAKE_CLAUDE_MCP_HOLD=1: a set Claude never answers; naming a file instead, one
        # it answers once that file exists, reading its input meanwhile.
        hold = os.environ.get("FAKE_CLAUDE_MCP_HOLD")
        if sub == "mcp_set_servers" and hold == "1":
            continue
        if sub == "mcp_set_servers" and hold:
            def answer_later(msg=msg):
                while not os.path.exists(hold):
                    time.sleep(0.02)
                answer_mcp_servers(msg)
            threading.Thread(target=answer_later, daemon=True).start()
            continue
        if sub == "mcp_set_servers":
            answer_mcp_servers(msg)
            continue
        if sub == "set_permission_mode":
            mode = msg["request"]["mode"]
        if sub == "initialize":
            dialogs = msg["request"].get("supportedDialogKinds", [])
        # FAKE_CLAUDE_COMMANDS is a JSON list of the slash command names it reports.
        reply = {"account": {"email": ACCOUNT_EMAIL, "subscriptionType": os.environ.get("FAKE_CLAUDE_SUBSCRIPTION", "max"), "tokenSource": os.environ.get("FAKE_CLAUDE_TOKEN_SOURCE", "claude.ai")},
                 "commands": [{"name": n, "description": "", "argumentHint": ""} for n in json.loads(os.environ.get("FAKE_CLAUDE_COMMANDS", "[]"))]} if sub == "initialize" else {}
        # FAKE_CLAUDE_MODELS is the JSON list of models it reports (ModelInfo: value,
        # resolvedModel, displayName, description, supportedEffortLevels, ...). Unset, the
        # reply has no models, as a Claude Code too old to list them answers.
        if sub == "initialize" and os.environ.get("FAKE_CLAUDE_MODELS"):
            reply["models"] = json.loads(os.environ["FAKE_CLAUDE_MODELS"])
        # FAKE_CLAUDE_NO_ACCOUNT: an initialize that reports no sign-in.
        if sub == "initialize" and os.environ.get("FAKE_CLAUDE_NO_ACCOUNT"):
            reply.pop("account", None)
        send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": reply}})
        # FAKE_CLAUDE_HOLD_INTERRUPT: an interrupt the CLI never answers, so the
        # host has to settle the turn itself.
        # FAKE_CLAUDE_STOP_LIMIT_FILE names a file holding an epoch: once it exists, the limit
        # resetting then lands as an interrupt ends the run. A terminal reason after the epoch
        # ("EPOCH aborted_streaming") is the one the interrupt's result carries.
        limit_file = os.environ.get("FAKE_CLAUDE_STOP_LIMIT_FILE")
        stop_spec = open(limit_file).read().split() if limit_file and os.path.exists(limit_file) else []
        stop_limit = int(stop_spec[0]) if stop_spec else None
        if sub == "interrupt" and stop_limit and not os.environ.get("FAKE_CLAUDE_HOLD_INTERRUPT"):
            send({"type": "rate_limit_event", "session_id": session, "rate_limit_info": {"status": "rejected", "rateLimitType": "five_hour", "resetsAt": stop_limit}})
            stopped = {"type": "result", "subtype": "error_during_execution", "is_error": True, "session_id": session}
            if len(stop_spec) > 1:
                stopped["terminal_reason"] = stop_spec[1]
            send(stopped)
        elif sub == "interrupt" and not os.environ.get("FAKE_CLAUDE_HOLD_INTERRUPT"):
            send({"type": "result", "subtype": "error_during_execution", "is_error": True, "session_id": session})
        # A stopped turn's elicitation is no longer waiting on its answer, nor its tool.
        if sub == "interrupt":
            pending_elicit = None
            pending_tool = None
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
        # Content blocks read as their text, then how many images came with it.
        content = msg["message"]["content"]
        if isinstance(content, str):
            steer_text = content
        else:
            images = sum(1 for b in content if b.get("type") == "image")
            steer_text = "".join(b.get("text", "") for b in content) + f" (+{images} image)"
        # A steer "ask once": the running turn's next tool call trips Claude's safety
        # check, which asks and forbids remembering the answer (Upstream #22546).
        if steer_text.startswith("ask once"):
            ask_once()
            continue
        # A steer saying "fold" is folded into the running turn instead: no result
        # cuts that turn short, and the one result answers both.
        # Claude does not run the tool call a steer cuts off, and marks it so.
        if pending_tool:
            send({"type": "user", "session_id": session, "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": pending_tool, "is_error": True,
                 "content": "The user doesn't want to proceed with this tool use."}]},
                  "tool_result_meta": [{"id": pending_tool, "non_execution_kind": "cancelled"}]})
            pending_tool = None
        if "fold" not in steer_text:
            send({"type": "result", "subtype": "error_during_execution", "is_error": True, "terminal_reason": "aborted_streaming", "session_id": session})
        send({"type": "assistant", "session_id": session, "message": {"id": "m-steer", "role": "assistant", "content": [{"type": "text", "text": "steered: " + steer_text}]}})
        # The answer names only the steer's prompt, not the one the turn started with.
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session,
              **({"user_message_uuids": [msg["uuid"]]} if msg.get("uuid") else {})})
        continue
    turn += 1
    # A message in blocks reads as its text blocks joined: the handoff sends the history
    # and the user's message as two (`HalC2.Claude.ThreadRuntime`).
    content = msg["message"]["content"]
    text = content if isinstance(content, str) else "".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    if os.environ.get("FAKE_CLAUDE_LOG"):
        with open(os.environ["FAKE_CLAUDE_LOG"], "a") as f:
            f.write(json.dumps({"text": text}) + "\n")
    # FAKE_CLAUDE_INPUT_LOG names a file each user message's text is appended to, as JSON.
    if os.environ.get("FAKE_CLAUDE_INPUT_LOG"):
        with open(os.environ["FAKE_CLAUDE_INPUT_LOG"], "a") as f:
            f.write(json.dumps(text) + "\n")
    # Claude Code says when it starts and finishes a prompt it was given a uuid for.
    lifecycle = lambda state: msg.get("uuid") and send({"type": "command_lifecycle", "session_id": session, "command_uuid": msg["uuid"], "state": state})
    if orphaned:
        lifecycle("queued")
        send({"type": "system", "subtype": "task_notification", "session_id": session, "task_id": orphaned, "status": "stopped",
              "summary": "Orphaned by a previous Claude Code process exit"})
        send({"type": "system", "subtype": "init", "session_id": session, "model": "claude-haiku", "permissionMode": mode})
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}o", "role": "assistant", "content": [{"type": "text", "text": "The survey stopped"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 1, "result": "The survey stopped",
              "origin": {"kind": "task-notification"}, "session_id": session})
        # Then Claude starts the prompt it queued, unless it never runs one for it.
        if "never start a turn" not in text:
            lifecycle("started")
        orphaned = None
    send({"type": "system", "subtype": "init", "session_id": session, "model": "claude-haiku", "permissionMode": mode})
    # The project's UserPromptSubmit hooks (.claude/settings.json) run on the prompt; one
    # that exits 2 drops it, and Claude reports the hook's reason as a warning, then
    # again as the result of a turn that ran nothing (Claude Code 2.1.302).
    blocked = prompt_blocked(text)
    if blocked:
        send({"type": "system", "subtype": "informational", "level": "info", "content": "Running UserPromptSubmit hooks",
              "session_id": session, "uuid": str(uuid.uuid4())})
        send({"type": "system", "subtype": "informational", "level": "warning", "prevent_continuation": True,
              "content": blocked, "session_id": session, "uuid": str(uuid.uuid4())})
        send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 0, "result": blocked, "session_id": session,
              **({"user_message_uuids": [msg["uuid"]]} if msg.get("uuid") else {})})
        continue
    record("user", text)
    # What the fake does is the user's message, not the history handed over before it.
    full, text = text, text.rsplit("</conversation_history>\n\n", 1)[-1]
    # Claude runs a command only from the last block of a message in blocks: a command
    # in an earlier block, or ahead of an image, is words. The fake's other triggers
    # read the whole message.
    command = text
    if isinstance(content, list) and content:
        last = content[-1]
        command = last.get("text", "") if isinstance(last, dict) and last.get("type") == "text" else ""
    # FAKE_CLAUDE_REJECT_RESUME_FILE: once that file exists the provider refuses the server's
    # automatic resume with a 429 naming no reset.
    if os.path.exists(os.environ.get("FAKE_CLAUDE_REJECT_RESUME_FILE", "")) and text == "Continue where you left off.":
        send({"type": "result", "subtype": "success", "is_error": True, "api_error_status": 429, "result": "Rate limited", "session_id": session})
        continue
    # "/compact": Claude summarises the conversation (compact_boundary) and answers with
    # a result that echoes the message's uuid, as Claude Code 2.1.285 does.
    if command == "/compact":
        lifecycle("started")
        send({"type": "system", "subtype": "compact_boundary", "session_id": session, "uuid": f"compact-{turn}",
              "compact_metadata": {"trigger": "manual", "pre_tokens": 27445, "post_tokens": 1192}})
        send({"type": "user", "session_id": session, "message": {"role": "user", "content": "<local-command-stdout>Compacted </local-command-stdout>"}})
        send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 0, "result": "", "session_id": session,
              **({"user_message_uuids": [msg["uuid"]]} if msg.get("uuid") else {})})
        lifecycle("completed")
        continue
    # "/goal OBJECTIVE": Claude Code's own goal command. It says "Goal set" in a synthetic
    # message, works on it, and its Stop hook finds it unmet once ("Stop hook feedback")
    # before the turn goes on; the turn stays open for the test to end. With "in the
    # background" in the objective Claude starts a background subagent (agent-N, task
    # task-agent-N) and ends the turn while it runs, deferring the check. "/goal" alone
    # says the goal's state, "/goal clear" clears it. Like Claude Code, it reads "/goal
    # pause" as a goal named "pause".
    if command == "/goal" or command.startswith("/goal "):
        synthetic = lambda said: send({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "uuid": f"goal-uuid-{turn}",
                                       "message": {"id": f"m{turn}goal", "model": "<synthetic>", "role": "assistant", "content": [{"type": "text", "text": said}]}})
        objective = command[len("/goal"):].strip()
        if objective in ("", "clear"):
            said = ("No goal set" if goal is None else (f"Goal cleared: {goal}" if objective else f"Goal active: {goal} (not yet evaluated)"))
            if objective:
                goal = None
            synthetic(said)
            send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 0, "result": said, "session_id": session})
            continue
        goal = objective
        synthetic(f"Goal set: {goal}")
        if "in the background" in goal:
            agent = f"agent-{turn}"
            send({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "message": {"id": f"m{turn}g", "role": "assistant", "content": [{"type": "tool_use", "id": agent, "name": "Agent", "input": {
                "description": "Survey the repo", "prompt": "List what is in the repo", "subagent_type": "general-purpose", "run_in_background": True}}]}})
            send({"type": "system", "subtype": "task_started", "session_id": session, "task_id": f"task-{agent}", "tool_use_id": agent,
                  "description": "Survey the repo", "task_type": "local_agent", "prompt": "List what is in the repo", "is_backgrounded": True})
            send({"type": "user", "session_id": session, "parent_tool_use_id": None, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": agent,
                  "content": [{"type": "text", "text": f"Async agent launched successfully.\nagentId: task-{agent}"}]}]}})
            send({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}i", "role": "assistant", "content": [{"type": "text", "text": "A helper is surveying the repo"}]}})
            send({"type": "result", "subtype": "success", "is_error": False, "result": "A helper is surveying the repo", "session_id": session})
            continue
        send({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "uuid": f"uuid-{turn}a", "message": {"id": f"m{turn}a", "role": "assistant", "content": [{"type": "text", "text": "Working on it"}]}})
        send({"type": "user", "session_id": session, "parent_tool_use_id": None, "isSynthetic": True, "message": {"role": "user", "content": [
            {"type": "text", "text": f"Stop hook feedback:\n[{goal}]: the tests still fail"}]}})
        send({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}b", "role": "assistant", "content": [{"type": "text", "text": "Fixing the last test"}]}})
        continue
    # "usage limit until EPOCH": the plan's five-hour window rejects the turn until then.
    if text.startswith("usage limit until "):
        resets = int(text.rsplit(" ", 1)[1])
        send({"type": "rate_limit_event", "session_id": session, "rate_limit_info": {"status": "rejected", "rateLimitType": "five_hour", "resetsAt": resets}})
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}l", "role": "assistant", "content": [{"type": "text", "text": "You've hit your limit"}]}})
        send({"type": "result", "subtype": "success", "is_error": True, "result": "You've hit your limit", "session_id": session})
        continue
    if "long session" in text and "--resume" in sys.argv and "resume_return" in dialogs:
        send({"type": "control_request", "request_id": f"dialog-{turn}", "request": {"subtype": "request_user_dialog", "dialog_kind": "resume_return",
              "payload": {"sessionAgeMinutes": 135, "estimatedTokens": 182400}}})
        continue
    # "loop N": Claude is stuck, N times over editing a.py and running the same failing
    # test, then ends the turn; "loop N and wait" stays open after them until a steer or
    # an interrupt, as a turn that goes on.
    looping = re.search(r"\bloop (\d+)", text.split("</conversation_history>")[-1])
    if looping:
        for i in range(int(looping.group(1))):
            edit, test = f"edit-{turn}-{i}", f"test-{turn}-{i}"
            send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}e{i}", "role": "assistant", "content": [{"type": "tool_use", "id": edit, "name": "Edit", "input": {
                "file_path": "a.py", "old_string": "x", "new_string": "y"}}]}})
            send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": edit, "content": "The file a.py has been updated.", "is_error": False}]}})
            send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}t{i}", "role": "assistant", "content": [{"type": "tool_use", "id": test, "name": "Bash", "input": {"command": "pytest -q test_a.py"}}]}})
            send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": test,
                  "content": "FAILED test_a.py::test_a - AssertionError: assert 1 == 2\n1 failed in 0.02s", "is_error": True}]}})
        if "and wait" in text:
            continue
        send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}l", "role": "assistant", "content": [{"type": "text", "text": "Still failing"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "Still failing", "session_id": session})
        continue
    # "repair the test command": Claude edits a.py, finds the bare `pytest`
    # missing, and runs the tests through `python -m pytest` instead: what a
    # plugin's micro-skills learn an environment fact from.
    if "repair the test command" in text.split("</conversation_history>")[-1]:
        for call, name, given, said, failed in (
                ("edit", "Edit", {"file_path": "a.py", "old_string": "x", "new_string": "y"},
                 "The file a.py has been updated.", False),
                ("bare", "Bash", {"command": "pytest -q"},
                 "bash: pytest: command not found", True),
                ("fixed", "Bash", {"command": "python -m pytest -q"}, "4 passed in 0.01s", False)):
            tool_id = f"repair-{turn}-{call}"
            send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}r{call}", "role": "assistant", "content": [{"type": "tool_use", "id": tool_id, "name": name, "input": given}]}})
            send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool_id,
                  "content": said, "is_error": failed}]}})
        send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}rd", "role": "assistant", "content": [{"type": "text", "text": "The tests pass"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "The tests pass", "session_id": session})
        continue
    # "run the tests the working way": Claude runs the tests through
    # `python -m pytest` only, as one told the bare `pytest` is missing would.
    if "run the tests the working way" in text.split("</conversation_history>")[-1]:
        tool_id = f"working-{turn}"
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}w", "role": "assistant", "content": [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {"command": "python -m pytest -q"}}]}})
        send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool_id,
              "content": "4 passed in 0.01s", "is_error": False}]}})
        send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}wd", "role": "assistant", "content": [{"type": "text", "text": "The tests pass"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "The tests pass", "session_id": session})
        continue
    # "answer halfway": Claude writes part of its answer (message half-uuid-N) and stays open,
    # as a turn the user stops mid-answer. Claude says it started the prompt first.
    if "answer halfway" in text.split("</conversation_history>")[-1]:
        lifecycle("started")
        send({"type": "assistant", "session_id": session, "uuid": f"half-uuid-{turn}", "message": {"id": f"m{turn}h", "role": "assistant", "content": [{"type": "text", "text": "Half an answer"}]}})
        continue
    # "leave a tool pending": Claude calls Bash (tool-pending-N) and the call runs on, so
    # the turn stays open with a tool call pending.
    if "leave a tool pending" in text:
        pending_tool = f"tool-pending-{turn}"
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}p", "role": "assistant", "content": [
            {"type": "tool_use", "id": pending_tool, "name": "Bash", "input": {"command": "npm test"}}]}})
        continue
    # A handoff's earlier conversation is history, not a directive, and so is a
    # delegated task's worker preamble (it asks the worker to finish its own waiting).
    if "wait" in text.split("</conversation_history>")[-1].split("\nTask:\n")[-1]:
        # "start and wait": Claude says it started the prompt, and says nothing more.
        if "start and wait" in text and msg.get("uuid"):
            send({"type": "command_lifecycle", "session_id": session, "command_uuid": msg["uuid"], "state": "started"})
        continue
    # "never start a turn": Claude finishes the prompt without running a turn for it, as
    # it does one whose uuid its transcript already holds; "never start a turn (STATE)"
    # ends it in another lifecycle state (discarded, refused).
    if "never start a turn" in text:
        ended = re.search(r"never start a turn \((\w+)\)", text)
        send({"type": "command_lifecycle", "session_id": session, "command_uuid": msg.get("uuid"), "state": ended.group(1) if ended else "completed"})
        continue
    # "grow the conversation": with an autoCompactWindow in --settings the conversation
    # outgrows it and Claude compacts (compact_boundary) before it answers.
    if "grow the conversation" in text:
        window = json.loads(sys.argv[sys.argv.index("--settings") + 1]).get("autoCompactWindow") if "--settings" in sys.argv else None
        if window:
            send({"type": "system", "subtype": "compact_boundary", "session_id": session, "uuid": f"compact-{turn}",
                  "compact_metadata": {"trigger": "auto", "pre_tokens": window + 5000, "post_tokens": 42000}})
        send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}k", "role": "assistant", "content": [{"type": "text", "text": "It grew"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "It grew", "session_id": session})
        continue
    # "start a monitor": the Monitor tool watches a command (task task-mon-N) and the
    # turn ends while it runs. "start a monitor and hold the turn" holds the turn's
    # answer until the test has marked the monitor as awaited (the gate file
    # "monitor-awaited" in FAKE_CLAUDE_GATE), as `hal_c2_background_wait` does in a turn.
    if "start a monitor" in text:
        mon = f"mon-{turn}"
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}g", "role": "assistant", "content": [{"type": "tool_use", "id": mon, "name": "Monitor", "input": {
            "command": "tail -f log/dev.log", "description": "Watch the dev log", "persistent": False}}]}})
        send({"type": "system", "subtype": "task_started", "session_id": session, "task_id": f"task-{mon}", "tool_use_id": mon,
              "description": "Watch the dev log", "task_type": "monitor"})
        send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": mon,
              "content": f"Monitor started (task task-{mon})", "is_error": False}]}})
        if "and hold the turn" in text:
            gate = os.path.join(os.environ["FAKE_CLAUDE_GATE"], "monitor-awaited")
            for _ in range(3000):  # bounded: 30 s at most
                if os.path.exists(gate):
                    break
                time.sleep(0.01)
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}i", "role": "assistant", "content": [{"type": "text", "text": "Watching the log"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "Watching the log", "session_id": session})
        continue
    # "subagent has the last word": Claude starts a background subagent (agent-N) and
    # answers, and the subagent's message (sub-uuid-N) comes after Claude's (uuid-N)
    # before the turn ends.
    if text == "subagent has the last word":
        agent = f"agent-{turn}"
        send({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "uuid": f"uuid-{turn}s", "message": {"id": f"m{turn}s", "role": "assistant", "content": [{"type": "tool_use", "id": agent, "name": "Agent", "input": {
            "description": "Helper", "prompt": "look around", "subagent_type": "general-purpose", "run_in_background": True}}]}})
        send({"type": "system", "subtype": "task_started", "session_id": session, "task_id": f"task-{agent}", "tool_use_id": agent,
              "description": "Helper", "task_type": "local_agent", "prompt": "look around", "is_backgrounded": True})
        send({"type": "user", "session_id": session, "parent_tool_use_id": None, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": agent,
              "content": [{"type": "text", "text": "Async agent launched"}]}]}})
        send({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}u", "role": "assistant", "content": [{"type": "text", "text": "A helper is looking around"}]}})
        send({"type": "assistant", "session_id": session, "parent_tool_use_id": agent, "uuid": f"sub-uuid-{turn}", "message": {"id": f"s{turn}", "role": "assistant", "content": [{"type": "text", "text": "Looking around"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    # "subagent works on: TASK": a subagent (tool use agent-N) runs TASK in the turn,
    # its own messages under its tool call: partial text, then text, a Bash call and a
    # task list, their results, and its answer "The tests pass".
    if text.startswith("subagent works on: "):
        agent, task = f"agent-{turn}", text[len("subagent works on: "):]
        side = lambda msg: send({**msg, "session_id": session, "parent_tool_use_id": agent})
        send({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "message": {"id": f"m{turn}s", "role": "assistant", "content": [{"type": "tool_use", "id": agent, "name": "Agent", "input": {
            "description": "Helper", "prompt": task, "subagent_type": "general-purpose"}}]}})
        send({"type": "system", "subtype": "task_started", "session_id": session, "task_id": f"task-{agent}", "tool_use_id": agent,
              "description": "Helper", "task_type": "local_agent", "prompt": task, "is_backgrounded": False})
        side({"type": "user", "message": {"role": "user", "content": task}})
        side({"type": "stream_event", "event": {"type": "message_start", "message": {"id": f"s{turn}a"}}})
        side({"type": "stream_event", "event": {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}})
        side({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Running the"}}})
        side({"type": "assistant", "uuid": f"sub-uuid-{turn}a", "message": {"id": f"s{turn}a", "role": "assistant", "content": [
            {"type": "text", "text": "Running the tests"},
            {"type": "tool_use", "id": f"sub-bash-{turn}", "name": "Bash", "input": {"command": "mix test"}},
            {"type": "tool_use", "id": f"sub-todo-{turn}", "name": "TodoWrite", "input": {"todos": [{"content": "Run the tests", "status": "in_progress", "activeForm": "Running"}]}}]}})
        side({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": f"sub-bash-{turn}", "content": "12 tests, 0 failures", "is_error": False},
            {"type": "tool_result", "tool_use_id": f"sub-todo-{turn}", "content": "Todos updated", "is_error": False}]}})
        side({"type": "assistant", "uuid": f"sub-uuid-{turn}b", "message": {"id": f"s{turn}b", "role": "assistant", "content": [{"type": "text", "text": "The tests pass"}]}})
        send({"type": "user", "session_id": session, "parent_tool_use_id": None, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": agent,
              "content": [{"type": "text", "text": "The tests pass"}]}]}})
        send({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}u", "role": "assistant", "content": [{"type": "text", "text": "The subagent says the tests pass"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if text.startswith("subagent "):
        agent, bash = f"agent-{turn}", f"bash-{turn}"
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}s", "role": "assistant", "content": [{"type": "tool_use", "id": agent, "name": "Agent", "input": {
            "description": "Helper", "prompt": text[len("subagent "):], "subagent_type": "general-purpose"}}]}})
        send({"type": "system", "subtype": "task_started", "session_id": session, "task_id": f"task-{agent}", "tool_use_id": agent,
              "description": "Helper", "task_type": "local_agent", "prompt": text[len("subagent "):], "is_backgrounded": False})
        if "approve run: " in text:
            cmd = text.split("run: ", 1)[1]
            asking_subagent = (agent, cmd)
            send({"type": "control_request", "request_id": f"perm-{agent}", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": cmd},
                  "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": cmd}], "behavior": "allow", "destination": "localSettings"}]}})
            continue
        send({"type": "assistant", "session_id": session, "parent_tool_use_id": agent, "message": {"id": f"m{turn}t", "role": "assistant", "content": [{"type": "tool_use", "id": bash, "name": "Bash", "input": {
            "command": "npm run dev", "description": "Dev server", "run_in_background": True}}]}})
        send({"type": "system", "subtype": "task_started", "session_id": session, "task_id": f"task-{bash}", "tool_use_id": bash,
              "description": "Dev server", "task_type": "local_bash"})
        send({"type": "user", "session_id": session, "parent_tool_use_id": agent, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": bash,
              "content": f"Command running in background with ID: task-{bash}", "is_error": False}]}})
        send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": agent,
              "content": [{"type": "text", "text": "Dev server started"}]}]}})
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}u", "role": "assistant", "content": [{"type": "text", "text": "The subagent started the dev server"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    # "background commands: A, B": one background Bash per name (tool use NAME-N, task
    # task-NAME-N, spaces as dashes, described by its name), the turn ending while they run.
    if text.startswith("background commands: "):
        names = [n.strip() for n in text[len("background commands: "):].split(",") if n.strip()]
        for name in names:
            tool = f"{name.replace(' ', '-')}-{turn}"
            send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}{tool}", "role": "assistant", "content": [{"type": "tool_use", "id": tool, "name": "Bash", "input": {
                "command": f"run {name}", "description": name, "run_in_background": True}}]}})
            send({"type": "system", "subtype": "task_started", "session_id": session, "task_id": f"task-{tool}", "tool_use_id": tool,
                  "description": name, "task_type": "local_bash"})
            send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool,
                  "content": f"Command running in background with ID: task-{tool}", "is_error": False}]}})
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}i", "role": "assistant", "content": [{"type": "text", "text": "They are running"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "They are running", "session_id": session})
        continue
    # "in the background": a background subagent (agent-N) and command (bash-N); "only
    # the subagent" or "only the command" leaves the other out.
    if "in the background" in text:
        agent, bash = f"agent-{turn}", f"bash-{turn}"
        if "only the command" not in text:
            send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}g", "role": "assistant", "content": [{"type": "tool_use", "id": agent, "name": "Agent", "input": {
                "description": "Survey the repo", "prompt": "List what is in the repo", "subagent_type": "general-purpose", "run_in_background": True}}]}})
            send({"type": "system", "subtype": "task_started", "session_id": session, "task_id": f"task-{agent}", "tool_use_id": agent,
                  "description": "Survey the repo", "task_type": "local_agent", "prompt": "List what is in the repo", "is_backgrounded": True})
            send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": agent,
                  "content": [{"type": "text", "text": f"Async agent launched successfully.\nagentId: task-{agent}"}]}]}})
        if "only the subagent" not in text:
            send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}h", "role": "assistant", "content": [{"type": "tool_use", "id": bash, "name": "Bash", "input": {
                "command": "npm run build", "description": "Build", "run_in_background": True}}]}})
            send({"type": "system", "subtype": "task_started", "session_id": session, "task_id": f"task-{bash}", "tool_use_id": bash,
                  "description": "Build", "task_type": "local_bash"})
            send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": bash,
                  "content": f"Command running in background with ID: task-{bash}", "is_error": False}]}})
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}i", "role": "assistant", "content": [{"type": "text", "text": "Both are running"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "Both are running", "session_id": session})
        continue
    # FAKE_CLAUDE_SIGNED_OUT: a CLI with no login answers every message with an auth error.
    if os.environ.get("FAKE_CLAUDE_SIGNED_OUT"):
        send({"type": "assistant", "session_id": session, "parent_tool_use_id": None, "error": "authentication_failed", "message": {"id": f"m{turn}x", "role": "assistant", "content": [{"type": "text", "text": "Invalid API key · Please run /login"}]}})
        send({"type": "result", "subtype": "success", "is_error": True, "result": "Invalid API key · Please run /login", "session_id": session})
        continue
    # MCP elicitations: a tool asking the user mid-turn. The answer's action is
    # what the tool is told ("elicitation ACTION"), and the turn ends on it.
    if text.startswith("mcp "):
        ask = text[len("mcp "):]
        base = {"type": "control_request", "request_id": "elicit-1", "request": {"subtype": "elicitation", "mcp_server_name": "demo"}}
        if ask.startswith("confirm"):
            pending_elicit = ("elicit-1", "twice" in ask)
            base["request"].update({"message": "Delete the file?", "mode": "form", "requested_schema": {"type": "object", "properties": {}}})
        elif ask == "sign in":
            pending_elicit = ("elicit-1", False)
            base["request"].update({"message": "Sign in to continue", "mode": "url", "url": "https://example.com/login", "elicitation_id": "login-1"})
        elif ask == "form":
            pending_elicit = ("elicit-1", False)
            base["request"].update({"message": "Name the file", "mode": "form", "requested_schema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}})
        elif ask == "undescribed":
            pending_elicit = ("elicit-1", False)
            base["request"].update({"message": "The tool needs input", "mode": "form"})
        if pending_elicit:
            send(base)
            continue
    if text in ("which tools", "run env"):
        if text == "which tools":
            answer = "tools: " + (", ".join(sorted(mcp_servers)) or "none")
        else:
            import subprocess
            answer = subprocess.run(["env"], capture_output=True, text=True).stdout
        send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}t", "role": "assistant", "content": [{"type": "text", "text": answer}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if "where are we" in text:
        send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}w", "role": "assistant", "content": [{"type": "text", "text": f"resumed at {resume_at} fork {'--fork-session' in sys.argv} history {'<conversation_history>' in full}" + (f" earlier [{' | '.join(earlier)}]" if SESSIONS else "")}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    # "edit a file": a Write tool call, and the file really is written.
    if text == "edit a file":
        send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}w", "role": "assistant", "content": [{"type": "tool_use", "id": f"write-{turn}", "name": "Write", "input": {"file_path": "edited.txt", "content": "edited by the turn\n"}}]}})
        with open("edited.txt", "w") as f:
            f.write("edited by the turn\n")
        send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"write-{turn}", "content": "File created", "is_error": False}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    # "call a skill": two Skill calls, one with arguments and one without.
    if text == "call a skill":
        for tool, extra in [(f"skill-args-{turn}", {"args": "with care"}), (f"skill-bare-{turn}", {})]:
            send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}{tool}", "role": "assistant", "content": [{"type": "tool_use", "id": tool, "name": "Skill", "input": {"skill": "demo", **extra}}]}})
            send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool, "content": "skill ran", "is_error": False}]}})
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}u", "role": "assistant", "content": [{"type": "text", "text": "Ran the demo skill"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if "approve" in text and mode == "auto":
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}u", "role": "assistant", "content": [{"type": "tool_use", "id": f"tool-{turn}", "name": "Bash", "input": {"command": "touch x"}}]}})
        send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"tool-{turn}", "content": "", "is_error": False}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    # "approve once": the safety check's ask, which a session rule does not skip.
    if text.startswith("approve once"):
        ask_once()
        continue
    if "approve" in text:
        cmd = text.split("run: ", 1)[1] if "run: " in text else "touch x"
        if cmd in session_rules or None in session_rules:
            send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}r", "role": "assistant", "content": [{"type": "text", "text": f"ran {cmd} without asking"}]}})
            send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
            continue
        # Claude Code's request ids are unique; a resumed process must not reuse the first's.
        perm = f"perm-{uuid.uuid4().hex[:8]}" if "--resume" in sys.argv else "perm-1"
        send({"type": "control_request", "request_id": perm, "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": cmd},
              "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": cmd}], "behavior": "allow", "destination": "localSettings"}]}})
        continue
    # "question first" asks before it plans; the answer brings the plan.
    if "question first" in text:
        asked_before_plan = True
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": {"questions": [
            {"question": "Which color?", "header": "Color", "multiSelect": False,
             "options": [{"label": "Red", "description": "Warm"}, {"label": "Blue", "description": ""}]}]}}})
        continue
    # "enter plan mode yourself": Claude calls EnterPlanMode, which puts its session in
    # plan mode; "which mode" says the mode the session runs in.
    if "enter plan mode yourself" in text:
        mode = "plan"
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}p", "role": "assistant", "content": [{"type": "tool_use", "id": f"enter-plan-{turn}", "name": "EnterPlanMode", "input": {}}]}})
        send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"enter-plan-{turn}", "content": "Entered plan mode."}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "planning", "session_id": session})
        continue
    if "which mode" in text:
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}m", "role": "assistant", "content": [{"type": "text", "text": f"mode {mode}"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": f"mode {mode}", "session_id": session})
        continue
    if "plan" in text:
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": {"plan": "# Plan\n- do it"}}})
        continue
    if "todo twice" in text:
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}ta", "role": "assistant", "content": [{"type": "tool_use", "id": f"todo-a-{turn}", "name": "TodoWrite", "input": {"todos": [
            {"content": "Read the code", "status": "in_progress", "activeForm": "Reading"}, {"content": "Fix it", "status": "pending", "activeForm": "Fixing"}, {"content": "Ship it", "status": "pending", "activeForm": "Shipping"}]}}]}})
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}tb", "role": "assistant", "content": [{"type": "tool_use", "id": f"todo-b-{turn}", "name": "TodoWrite", "input": {"todos": [
            {"content": "Read the code", "status": "completed", "activeForm": "Reading"}, {"content": "Fix it", "status": "completed", "activeForm": "Fixing"}, {"content": "Ship it", "status": "in_progress", "activeForm": "Shipping"}]}}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if "todo three" in text:
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}t", "role": "assistant", "content": [{"type": "tool_use", "id": f"todo-{turn}", "name": "TodoWrite", "input": {"todos": [
            {"content": "Read the code", "status": "completed", "activeForm": "Reading"}, {"content": "Fix it", "status": "in_progress", "activeForm": "Fixing"}, {"content": "Ship it", "status": "pending", "activeForm": "Shipping"}]}}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if "todo done" in text:
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}t", "role": "assistant", "content": [{"type": "tool_use", "id": f"todo-{turn}", "name": "TodoWrite", "input": {"todos": [
            {"content": "Read the code", "status": "completed", "activeForm": "Reading"}, {"content": "Fix it", "status": "completed", "activeForm": "Fixing"}]}}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if "todo" in text:
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}t", "role": "assistant", "content": [{"type": "tool_use", "id": f"todo-{turn}", "name": "TodoWrite", "input": {"todos": [
            {"content": "Read the code", "status": "completed", "activeForm": "Reading"}, {"content": "Fix it", "status": "in_progress", "activeForm": "Fixing"}]}}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    # "ask two": two questions, the second without a heading of its own.
    if text.startswith("ask two"):
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": {"questions": [
            {"question": "Which color?", "header": "Color", "multiSelect": False,
             "options": [{"label": "Red", "description": "Warm"}, {"label": "Blue", "description": ""}]},
            {"question": "How big?", "multiSelect": False,
             "options": [{"label": "Small", "description": ""}, {"label": "Large", "description": ""}]}]}}})
        continue
    # "ask skip": a choice whose description is blank (Upstream #21762).
    if text.startswith("ask skip"):
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": {"questions": [
            {"question": "What should we add?", "header": "Scope", "multiSelect": False,
             "options": [{"label": "Docs", "description": "Write the docs"}, {"label": "Skip", "description": "   "}]}]}}})
        continue
    # "ask preview": an option with a preview (Upstream #21932).
    if text.startswith("ask preview"):
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": {"questions": [
            {"question": "Which database?", "header": "Store", "multiSelect": False,
             "options": [{"label": "Postgres", "description": "Relational", "preview": "```sql\nCREATE TABLE orders (id serial);\n```"},
                         {"label": "SQLite", "description": "Embedded"}]}]}}})
        continue
    # "ask multi": one question that takes several answers.
    if text.startswith("ask multi"):
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": {"questions": [
            {"question": "What should we add?", "header": "Scope", "multiSelect": True,
             "options": [{"label": "Unit tests", "description": ""}, {"label": "Docs", "description": ""}, {"label": "Benchmarks", "description": ""}]}]}}})
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
    # FAKE_CLAUDE_GATEWAY_USAGE: a gateway reports zero tokens as a message starts and its
    # counts only as it ends (message_delta). "compact" compacts between the two, so the
    # ending counts are from before the compaction.
    if os.environ.get("FAKE_CLAUDE_GATEWAY_USAGE"):
        zero = {"input_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 0}
        send({"type": "stream_event", "session_id": session, "event": {"type": "message_start", "message": {"id": f"m{turn}g", "usage": zero}}})
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}g", "role": "assistant", "usage": zero, "content": [{"type": "text", "text": "Hello from claude"}]}})
        if "compact" in text:
            send({"type": "system", "subtype": "compact_boundary", "session_id": session, "uuid": f"compact-{turn}",
                  "compact_metadata": {"trigger": "auto", "pre_tokens": 150000, "post_tokens": 5000}})
        send({"type": "stream_event", "session_id": session, "event": {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
              "usage": {"input_tokens": 1200, "cache_creation_input_tokens": 300, "cache_read_input_tokens": 40000, "output_tokens": 80}}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "Hello from claude", "session_id": session,
              "usage": {"input_tokens": 9999, "output_tokens": 999}})
        continue
    if "rate limit" in text:
        send({"type": "rate_limit_event", "session_id": session, "rate_limit_info": {"status": "allowed_warning", "rateLimitType": "five_hour", "utilization": 0.91, "resetsAt": 1790000000}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    ev = lambda e: send({"type": "stream_event", "session_id": session, "event": e})
    lifecycle("started")
    send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}a", "role": "assistant", "content": [{"type": "thinking", "thinking": "Let me look."}]}})
    send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}b", "role": "assistant", "content": [{"type": "tool_use", "id": f"tool-{turn}", "name": "Bash", "input": {"command": "ls"}}]}})
    send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"tool-{turn}", "content": "a.txt\n", "is_error": False}]}})
    ev({"type": "message_start", "message": {"id": f"m{turn}c"}})
    ev({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
    for d in ["Hel", "lo from ", "claude"]:
        ev({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": d}})
    ev({"type": "content_block_stop", "index": 0})
    send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}c", "role": "assistant", "content": [{"type": "text", "text": "Hello from claude"}]}})
    # "report your usage": the result carries the turn's token usage.
    usage = {"usage": {"input_tokens": 1000, "output_tokens": 50}} if "report your usage" in text else {}
    # FAKE_CLAUDE_CONTEXT_WINDOW: the result's modelUsage reports that window for the model.
    if os.environ.get("FAKE_CLAUDE_CONTEXT_WINDOW") and "--model" in sys.argv:
        usage["modelUsage"] = {sys.argv[sys.argv.index("--model") + 1]: {"inputTokens": 1000, "outputTokens": 50, "contextWindow": int(os.environ["FAKE_CLAUDE_CONTEXT_WINDOW"])}}
    send({"type": "result", "subtype": "success", "is_error": False, "result": "Hello from claude", "session_id": session, **usage})
    lifecycle("completed")
# Its stdin closed, the process says so in its trace and, with FAKE_CLAUDE_EXIT_DELAY
# (seconds), lingers that long before it exits, as one finishing its work does.
trace({"eof": os.getpid()})
if os.environ.get("FAKE_CLAUDE_EXIT_DELAY"):
    time.sleep(float(os.environ["FAKE_CLAUDE_EXIT_DELAY"]))
