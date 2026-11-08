# MCP Apps for the fake `codex app-server` (fake_codex.py). A turn whose text has
# "mcp app" calls the "weather" server's get_forecast tool, which returns the app
# ui://weather/forecast.html ("cookies": ui://weather/cookies.html, a page that reads
# document.cookie); "failed" marks the result an error, as a tool that reports a
# failure does, and "broken" fails the call before it returns a result. The server's
# tools: get_forecast (read only), save_city (not read only) and admin_reset (for
# the model only). mcpServer/tool/call answers "called TOOL with ARGS".
import json

SERVER = "weather"

TOOLS = {
    "get_forecast": {
        "name": "get_forecast",
        "inputSchema": {"type": "object"},
        "annotations": {"title": "Get forecast", "readOnlyHint": True},
        "_meta": {"ui": {"resourceUri": "ui://weather/forecast.html", "visibility": ["model", "app"]}},
    },
    "save_city": {"name": "save_city", "inputSchema": {"type": "object"}},
    "admin_reset": {
        "name": "admin_reset",
        "inputSchema": {"type": "object"},
        "_meta": {"ui": {"visibility": ["model"]}},
    },
}

PAGES = {
    "ui://weather/forecast.html": "<!doctype html><html><body><h1>Forecast</h1><script>window.app = true</script></body></html>",
    "ui://weather/cookies.html": "<html><body><script>document.title = document.cookie || 'no cookies'</script></body></html>",
}

UI_META = {
    "csp": {
        "connectDomains": ["https://api.weather.example", "javascript:alert(1)"],
        "resourceDomains": ["https://cdn.weather.example"],
    },
    "permissions": {"geolocation": {}, "telepathy": {}},
    "prefersBorder": True,
}


def answer(method, params, mid, send):
    """Answers the MCP requests an app makes through Codex; True when it did."""
    if method == "mcpServer/resource/read":
        uri = params.get("uri")
        if params.get("server") != SERVER or uri not in PAGES:
            send({"id": mid, "error": {"code": -32002, "message": f"no resource {uri}"}})
        else:
            content = {"uri": uri, "mimeType": "text/html;profile=mcp-app", "text": PAGES[uri], "_meta": {"ui": UI_META}}
            send({"id": mid, "result": {"contents": [content]}})
        return True
    if method == "mcpServerStatus/list":
        tools = TOOLS if params.get("serverName") in (None, SERVER) else {}
        send({"id": mid, "result": {"data": [{"name": SERVER, "tools": tools, "authStatus": "unsupported"}], "nextCursor": None}})
        return True
    if method == "mcpServer/tool/call":
        text = f"called {params.get('tool')} with {json.dumps(params.get('arguments'), sort_keys=True)}"
        send({"id": mid, "result": {"content": [{"type": "text", "text": text}], "structuredContent": {"ok": True}}})
        return True
    return False


def play(text, ctx, turn_id, send):
    """Plays a turn that returns an MCP app; True when the text asked for one."""
    if "mcp app" not in text:
        return False
    uri = "ui://weather/cookies.html" if "cookies" in text else "ui://weather/forecast.html"
    item = {
        "type": "mcpToolCall",
        "id": f"mcp-app-{turn_id}",
        "server": SERVER,
        "tool": "get_forecast",
        "arguments": {"city": "Reykjavik"},
        "status": "inProgress",
        "result": None,
        "error": None,
        "mcpAppResourceUri": uri,
    }
    send({"method": "item/started", "params": {**ctx, "item": item}})
    if "broken" in text:
        done = {**item, "status": "failed", "error": {"message": "server went away"}}
    elif "failed" in text:
        result = {"content": [{"type": "text", "text": "No forecast for Reykjavik"}], "isError": True}
        done = {**item, "status": "failed", "result": result}
    else:
        result = {"content": [{"type": "text", "text": "Sunny"}], "structuredContent": {"forecast": "sunny"}}
        done = {**item, "status": "completed", "result": result}
    send({"method": "item/completed", "params": {**ctx, "item": done}})
    message = {"type": "agentMessage", "id": f"msg-{turn_id}", "text": ""}
    send({"method": "item/started", "params": {**ctx, "item": message}})
    send({"method": "item/completed", "params": {**ctx, "item": {**message, "text": "Here is the forecast."}}})
    send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
    return True
