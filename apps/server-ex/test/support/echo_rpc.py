# Fake JSON-RPC peer for tests. Echoes requests; "ask" round-trips a server->client
# request first; "notify_me" emits a notification before replying; "stderr" writes
# params["lines"] to stderr before replying; the "exit" notification writes params["said"]
# to stderr and exits with params["code"].
import json, sys

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    msg = json.loads(line)
    if "method" not in msg:
        continue
    method, params = msg["method"], msg.get("params")
    if method == "exit":
        sys.stderr.write(params["said"] + "\n")
        sys.stderr.flush()
        sys.exit(params["code"])
    if "id" not in msg:
        continue
    if method == "notify_me":
        send({"method": "progress", "params": params})
    if method == "stderr":
        sys.stderr.write("".join(l + "\n" for l in params["lines"]))
        sys.stderr.flush()
    if method == "ask":
        send({"id": "srv-1", "method": "approve", "params": params})
        answer = json.loads(sys.stdin.readline())
        send({"id": msg["id"], "result": {"answer": answer.get("result")}})
        continue
    send({"id": msg["id"], "result": {"method": method, "params": params}})
