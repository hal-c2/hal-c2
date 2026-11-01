#!/usr/bin/env python3
# Fake `codex exec` and `grok -p` for image generation tests. Appends each call (argv,
# cwd, prompt) to $FAKE_IMAGE_LOG and leaves a small PNG in the directory it runs in.
# $FAKE_IMAGE_MODE changes that: "none" leaves nothing, "text" leaves a file that is not
# an image, "fail" fails the call, and "hang" outlasts the MC's patience.
import base64, json, os, sys, time

PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)

args = sys.argv[1:]
prompt = sys.stdin.read()

log = os.environ.get("FAKE_IMAGE_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps({"argv": args, "cwd": os.getcwd(), "prompt": prompt}) + "\n")

mode = os.environ.get("FAKE_IMAGE_MODE") or "png"
if mode == "fail":
    sys.stderr.write("the model is overloaded\n")
    sys.exit(1)
if mode == "hang":
    time.sleep(30)
if mode == "text":
    with open("image.png", "w") as f:
        f.write("not an image")
elif mode == "png":
    with open("image.png", "wb") as f:
        f.write(PNG)
