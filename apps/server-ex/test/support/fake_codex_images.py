# Images and partial answers for the fake `codex app-server` (fake_codex.py), which
# hands every turn here first (`turn`) and passes every message through (`incoming`,
# `outgoing`):
#
# - "draw a fox" generates three images: two Codex saves (the first twice, and the
#   reply already shows it) and one that fails. Saved files go under
#   $CODEX_HOME/generated_images (the working directory without a home).
# - "draw slowly" answers while its image is still generating, ends the turn, and
#   saves the image once the test creates the gate file "image".
# - "use a tool with an image" calls a dynamic tool and an MCP tool that each return
#   an image as base64 data.
# - "answer in parts" sends a partial answer and then a final answer with the same
#   text; with FAKE_SESSIONS both go into the rollout, phase and all.
#
# A thread/fork answer (which carries the thread's turns unless excludeTurns asks
# otherwise) lists the turns its rollout holds, partial answers included, as Codex does.
import base64, json, os, threading

PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
PNG_DATA = base64.b64encode(PNG).decode()

hooks = {}
# Requests whose answers carry the thread's turns: request id -> params.
listing = {}


def setup(**functions):
    hooks.update(functions)


def incoming(msg):
    if msg.get("method") == "thread/fork" and msg.get("id") is not None:
        listing[msg["id"]] = msg.get("params") or {}


def outgoing(msg):
    params = listing.pop(msg.get("id"), None) if "result" in msg or "error" in msg else None
    if params is None or params.get("excludeTurns") or "result" not in msg:
        return msg
    thread = msg["result"].get("thread") or {}
    turns = history(thread.get("id"))
    if turns is None:
        return msg
    return {**msg, "result": {**msg["result"], "thread": {**thread, "turns": turns}}}


# The turns a thread's rollout holds, as thread/fork lists them.
def history(thread_id):
    find = hooks.get("rollout_find")
    path = thread_id and find and find(thread_id)
    if not path:
        return None
    turns = []
    with open(path) as f:
        records = [json.loads(line) for line in f if line.strip()]
    for record in records:
        payload = record.get("payload") or {}
        if record.get("type") == "turn_context":
            turns.append({"id": f"history-turn-{len(turns) + 1}", "status": "completed", "items": []})
        elif record.get("type") == "response_item" and payload.get("type") == "message" and turns:
            items = turns[-1]["items"]
            text = "".join(part.get("text", "") for part in payload.get("content", []))
            if payload.get("role") == "user":
                items.append({"type": "userMessage", "id": f"user-{len(items)}", "content": [{"type": "text", "text": text}]})
            else:
                items.append({"type": "agentMessage", "id": f"agent-{len(items)}", "text": text, "phase": payload.get("phase")})
    return turns


def image_dir(thread_id):
    folder = os.path.join(os.environ.get("CODEX_HOME") or os.getcwd(), "generated_images", thread_id)
    os.makedirs(folder, exist_ok=True)
    return folder


def save(thread_id, name):
    path = os.path.join(image_dir(thread_id), name)
    with open(path, "wb") as f:
        f.write(PNG)
    return path


def event(send, ctx, method, item):
    send({"method": method, "params": {**ctx, "item": item}})


def message(send, ctx, native, text, phase=None):
    item = {"type": "agentMessage", "id": native, "text": "", "phase": phase}
    event(send, ctx, "item/started", item)
    event(send, ctx, "item/completed", {**item, "text": text})
    hooks["rollout_append"]({"type": "response_item", "payload": {
        "type": "message", "role": "assistant", "phase": phase,
        "content": [{"type": "output_text", "text": text}]}})


def generating(native):
    return {"type": "imageGeneration", "id": native, "status": "inProgress", "revisedPrompt": "a fox", "result": ""}


def saved(native, path):
    return {"type": "imageGeneration", "id": native, "status": "completed", "revisedPrompt": "a fox",
            "result": PNG_DATA, "savedPath": path}


def end(send, ctx):
    send({"method": "turn/completed", "params": {**ctx, "turn": {"id": ctx["turnId"], "status": "completed"}}})


# Plays the turn when its text is one of the above; True when it did.
def turn(ctx, text, send):
    turn_id = ctx["turnId"]
    if "draw a fox" in text:
        first, second, failed = (f"image-{turn_id}-{n}" for n in (1, 2, 3))
        for native in (first, second, failed):
            event(send, ctx, "item/started", generating(native))
        shown = save(ctx["threadId"], f"{first}.png")
        event(send, ctx, "item/completed", saved(first, shown))
        event(send, ctx, "item/completed", saved(first, shown))
        event(send, ctx, "item/completed", saved(second, save(ctx["threadId"], f"{second}.png")))
        event(send, ctx, "item/completed", {**generating(failed), "status": "failed", "failure": "content policy"})
        message(send, ctx, f"msg-draw-{turn_id}", f"Here is the fox.\n\n![fox]({shown})", "final_answer")
        end(send, ctx)
        return True
    if "draw slowly" in text:
        native = f"image-{turn_id}-late"
        event(send, ctx, "item/started", generating(native))
        message(send, ctx, f"msg-slow-{turn_id}", "The fox is on its way.", "final_answer")
        end(send, ctx)

        def finish():
            hooks["gate"]("image")
            event(send, ctx, "item/completed", saved(native, save(ctx["threadId"], f"{native}.png")))

        threading.Thread(target=finish, daemon=True).start()
        return True
    if "use a tool with an image" in text:
        dynamic = {"type": "dynamicToolCall", "id": f"tool-{turn_id}", "tool": "screenshot",
                   "arguments": {"window": "main"}, "status": "inProgress"}
        event(send, ctx, "item/started", dynamic)
        event(send, ctx, "item/completed", {**dynamic, "status": "completed", "success": True, "contentItems": [
            {"type": "inputText", "text": "The main window."},
            {"type": "inputImage", "imageUrl": f"data:image/png;base64,{PNG_DATA}"}]})
        mcp = {"type": "mcpToolCall", "id": f"mcp-{turn_id}", "server": "browser", "tool": "capture",
               "arguments": {}, "status": "inProgress"}
        event(send, ctx, "item/started", mcp)
        event(send, ctx, "item/completed", {**mcp, "status": "completed", "result": {"content": [
            {"type": "text", "text": "The page."},
            {"type": "image", "data": PNG_DATA, "mimeType": "image/png"}]}})
        message(send, ctx, f"msg-tool-{turn_id}", "Took two screenshots.")
        end(send, ctx)
        return True
    if "answer in parts" in text:
        message(send, ctx, f"msg-partial-answer-{turn_id}", "The answer is 42.", "partial_answer")
        message(send, ctx, f"msg-final-answer-{turn_id}", "The answer is 42.", "final_answer")
        end(send, ctx)
        return True
    return False
