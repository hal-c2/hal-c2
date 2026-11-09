# The ChatGPT sign-in of the fake `codex app-server` (fake_codex.py), on while
# FAKE_CODEX_CHATGPT is set. The login lives in $CODEX_HOME/auth.json, as Codex's does:
# account/read reads it, account/logout removes it, and account/login/start
# {type: "chatgpt"} answers OpenAI's sign-in link (its redirect is Codex's
# http://localhost:1455/auth/callback) and listens for that callback on
# FAKE_CODEX_LOGIN_PORT, standing in for Codex's own login server. A callback with
# a code (and the link's state, when it carries one) writes the login, as
# FAKE_CODEX_EMAIL (default me@example.com) on FAKE_CODEX_PLAN (default "pro"), and
# ends the sign-in with account/login/completed; one with an error fails it. Nothing
# here reaches OpenAI.
import http.server, json, os, threading, urllib.parse, uuid

ON = bool(os.environ.get("FAKE_CODEX_CHATGPT"))
REDIRECT = "http://localhost:1455/auth/callback"


def auth_path():
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    return os.path.join(home, "auth.json")


def account():
    try:
        with open(auth_path()) as f:
            login = json.load(f)
    except (OSError, ValueError):
        return None
    fake = login.get("fake_account") or {}
    return {"type": "chatgpt", "email": fake.get("email"), "planType": fake.get("planType")}


def login_server(send, login_id, state):
    port = int(os.environ["FAKE_CODEX_LOGIN_PORT"])

    class Callback(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(url.query)
            if url.path != "/auth/callback" or query.get("state", [state]) != [state]:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"State mismatch")
                return
            if "code" in query:
                path = auth_path()
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    json.dump({"auth_mode": "chatgpt", "tokens": {"refresh_token": "fake-" + query["code"][0]},
                               "fake_account": {"email": os.environ.get("FAKE_CODEX_EMAIL", "me@example.com"),
                                                "planType": os.environ.get("FAKE_CODEX_PLAN", "pro")}}, f)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"Signed in to Codex")
                send({"method": "account/login/completed", "params": {"loginId": login_id, "success": True, "error": None}})
            else:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"Sign-in failed")
                error = query.get("error", ["access_denied"])[0]
                send({"method": "account/login/completed", "params": {"loginId": login_id, "success": False, "error": error}})
            threading.Thread(target=self.server.shutdown, daemon=True).start()

    http.server.HTTPServer.allow_reuse_address = True
    server = http.server.HTTPServer(("127.0.0.1", port), Callback)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


SERVERS = {}


def handle(method, params, mid, send):
    """Answers the request when it is the ChatGPT sign-in's; True when it did."""
    if not ON:
        return False
    if method == "account/read":
        send({"id": mid, "result": {"account": account(), "requiresOpenaiAuth": True}})
    elif method == "account/login/start" and params.get("type") == "chatgpt":
        login_id, state = str(uuid.uuid4()), uuid.uuid4().hex
        SERVERS[login_id] = login_server(send, login_id, state)
        query = urllib.parse.urlencode({"response_type": "code", "client_id": "app_fake",
                                        "redirect_uri": REDIRECT, "state": state})
        send({"id": mid, "result": {"type": "chatgpt", "loginId": login_id,
                                    "authUrl": "https://auth.openai.com/oauth/authorize?" + query}})
    elif method == "account/login/cancel":
        server = SERVERS.pop(params.get("loginId"), None)
        if server:
            threading.Thread(target=server.shutdown, daemon=True).start()
        send({"id": mid, "result": {"status": "canceled" if server else "notFound"}})
    elif method == "account/logout":
        try:
            os.remove(auth_path())
        except FileNotFoundError:
            pass
        send({"id": mid, "result": {}})
    else:
        return False
    return True
