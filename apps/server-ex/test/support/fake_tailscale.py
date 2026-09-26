#!/usr/bin/env python3
"""A stand-in for the `tailscale` CLI: `status --json`, `serve status --json`,
`serve --bg --https=N TARGET` and `serve --https=N off`, over a JSON state file
named by FAKE_TAILSCALE_STATE:

    {"self": {"DNSName": "box.tail.ts.net.", "TailscaleIPs": [...]},
     "peers": {"key": {"Online": true, "TailscaleIPs": [...]}},
     "serve": {"box.tail.ts.net:443": "http://127.0.0.1:3780"}}
"""
import json, os, sys

path = os.environ["FAKE_TAILSCALE_STATE"]
with open(path) as f:
    state = json.load(f)
args = sys.argv[1:]
name = state["self"].get("DNSName", "").rstrip(".")

if args == ["status", "--json"]:
    print(json.dumps({"BackendState": "Running", "Self": state["self"], "Peer": state.get("peers", {})}))
elif args == ["serve", "status", "--json"]:
    web = {host: {"Handlers": {"/": {"Proxy": target}}} for host, target in state.get("serve", {}).items()}
    print(json.dumps({"Web": web} if web else {}))
elif args[:1] == ["serve"]:
    port = next(a.split("=", 1)[1] for a in args if a.startswith("--https="))
    rest = [a for a in args[1:] if not a.startswith("--")]
    serve = state.setdefault("serve", {})
    if rest == ["off"]:
        serve.pop(f"{name}:{port}", None)
    else:
        serve[f"{name}:{port}"] = rest[0]
        print(f"Available within your tailnet:\n\nhttps://{name}:{port}/\n|-- proxy {rest[0]}")
    with open(path, "w") as f:
        json.dump(state, f)
else:
    sys.stderr.write(f"fake tailscale: unsupported {args}\n")
    sys.exit(2)
