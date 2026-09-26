# Google sign-in for the fake ACP agent, standing in for Antigravity's
# (`agy_acp_server`): used when config.json has "googleAuth": true.
#
# The instance's profile is $GEMINI_HOME/antigravity-acp: `settings.json` names the
# sign-in method (auth.type), `acp_token.json` is the saved Google login.
#   oauth-personal / oauth-business  authenticate without a login prints Google's
#       sign-in link and serves its loopback redirect until a response with the
#       link's state arrives: a code saves the login, an error fails.
#   gemini-api-key   needs GEMINI_API_KEY; agent-platform needs GOOGLE_API_KEY, or a
#       GCP project and location in settings.json.
# Sessions need the method's credentials (else -32000); `logout` removes the login.
#
# config.json keys: account (the login's account), authError (authenticate fails
# with this error object).
import json, os, secrets, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

PREFIX = "Open the following link to authenticate the ACP server: "


def profile():
    return os.path.join(os.environ.get("GEMINI_HOME", "."), "antigravity-acp")


def token_path():
    return os.path.join(profile(), "acp_token.json")


def settings():
    try:
        with open(os.path.join(profile(), "settings.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def method():
    return (settings().get("auth") or {}).get("type", "oauth-personal")


def credentials():
    m = method()
    if m.startswith("oauth"):
        return os.path.exists(token_path())
    if m == "gemini-api-key":
        return bool(os.environ.get("GEMINI_API_KEY"))
    gcp = settings().get("gcp") or {}
    return bool(os.environ.get("GOOGLE_API_KEY")) or bool(gcp.get("project") and gcp.get("location"))


def browser_sign_in(cfg, send, mid):
    state = secrets.token_hex(8)
    outcome = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(url.query)
            if url.path != "/oauth2callback" or query.get("state") != [state]:
                self.send_response(400)
                self.end_headers()
                return
            if query.get("code"):
                os.makedirs(profile(), exist_ok=True)
                with open(token_path(), "w") as f:
                    json.dump({"account": cfg.get("account", "user@example.com")}, f)
                outcome["ok"] = True
            else:
                outcome["error"] = (query.get("error") or ["unknown"])[0]
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Sign-in succeeded. You can close this page.")

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    params = urllib.parse.urlencode({
        "client_id": "fake", "response_type": "code", "scope": "openid",
        "redirect_uri": "http://127.0.0.1:%d/oauth2callback" % port, "state": state})
    print(PREFIX + "https://accounts.google.com/o/oauth2/v2/auth?" + params, flush=True)
    while not outcome:
        server.handle_request()
    server.server_close()
    if outcome.get("ok"):
        send({"id": mid, "result": {}})
    else:
        send({"id": mid, "error": {"code": -32603, "message": outcome["error"]}})


def handle(msg, cfg, send):
    """Answers `msg` when it is Google's to answer; returns whether it did."""
    m, mid = msg.get("method"), msg.get("id")
    if m == "authenticate":
        if cfg.get("authError"):
            send({"id": mid, "error": cfg["authError"]})
        elif credentials():
            send({"id": mid, "result": {}})
        elif method().startswith("oauth"):
            browser_sign_in(cfg, send, mid)
        else:
            send({"id": mid, "error": {"code": -32602, "message": "invalid credentials"}})
        return True
    if m == "logout":
        if os.path.exists(token_path()):
            os.remove(token_path())
        send({"id": mid, "result": {}})
        return True
    if m in ("session/new", "session/resume", "session/load") and not credentials():
        send({"id": mid, "error": {"code": -32000, "message": "Authentication required"}})
        return True
    return False
