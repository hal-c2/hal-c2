#!/usr/bin/env python3
"""A minimal ACP agent that dies on its first prompt.

Answers `initialize` and `session/new`, then exits with code 3 when a
prompt arrives, as an agent whose process goes away mid-generation does.
Used by the text-generation tests; every other request gets a plain
result so model selection can go through.
"""

import json
import os
import sys

sys.dont_write_bytecode = True  # no __pycache__ in the source tree

OPTIONS = [
    {
        "id": "model",
        "name": "Model",
        "type": "select",
        "currentValue": "fake/one",
        "options": [{"value": "fake/one", "name": "Fake/One"}],
    }
]


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


while True:
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    msg = json.loads(line)
    mid = msg.get("id")
    method = msg.get("method")
    if method == "initialize":
        send(
            {
                "id": mid,
                "result": {
                    "protocolVersion": 1,
                    "agentInfo": {"name": "Dying", "version": "1.0.0"},
                    "authMethods": [],
                    "agentCapabilities": {},
                },
            }
        )
    elif method == "session/new":
        send({"id": mid, "result": {"sessionId": "dying-1", "configOptions": OPTIONS}})
    elif method == "session/prompt":
        sys.stdout.flush()
        os._exit(3)
    elif mid is not None and method is not None:
        send({"id": mid, "result": {"configOptions": OPTIONS}})
