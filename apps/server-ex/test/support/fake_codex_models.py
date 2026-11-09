# Model, check and config behaviour of the fake `codex app-server` (fake_codex.py
# calls `handle` before its own dispatch; True means the message was answered here).
#
# FAKE_CODEX_PROBE_DELAY_MS delays the initialize answer, a slow but healthy start.
# FAKE_CODEX_SERVICE_TIER is the `service_tier` config/read answers with.
# FAKE_CODEX_CATALOG plays Codex's shared model catalog (pingdotgg/t3code#18200):
# initialize reports CODEX_HOME as `codexHome`, model/list answers from
# `$CODEX_HOME/models_cache.json`, and the first model/list refreshes that file as the
# backend would for this process's originator: Ultrafast only for an account entitled
# to it (FAKE_ULTRAFAST_ENTITLED=1) on an app's originator, never the plain CLI's.
import json, os, time
from datetime import datetime, timezone

refreshed = False

def cache_path():
    return os.path.join(os.environ["CODEX_HOME"], "models_cache.json")

def refresh(models):
    originator = os.environ.get("CODEX_INTERNAL_ORIGINATOR_OVERRIDE") or "codex_cli_rs"
    entitled = os.environ.get("FAKE_ULTRAFAST_ENTITLED") == "1" and originator != "codex_cli_rs"
    tiers = ["priority", "ultrafast"] if entitled else ["priority"]
    fresh = [{**m, "serviceTiers": [{"id": t, "name": t, "description": ""} for t in tiers]} for m in models]
    with open(cache_path(), "w") as f:
        json.dump({"fetched_at": datetime.now(timezone.utc).isoformat(), "models": fresh}, f)

def handle(method, mid, params, send):
    global refreshed
    if method == "initialize" and os.environ.get("FAKE_CODEX_PROBE_DELAY_MS"):
        time.sleep(int(os.environ["FAKE_CODEX_PROBE_DELAY_MS"]) / 1000)
    if method == "initialize" and os.environ.get("FAKE_CODEX_CATALOG"):
        send({"id": mid, "result": {"userAgent": "fake", "platformOs": "test", "codexHome": os.environ["CODEX_HOME"]}})
        return True
    if method == "model/list" and os.environ.get("FAKE_CODEX_CATALOG"):
        with open(cache_path()) as f:
            models = json.load(f)["models"]
        if not refreshed:
            refreshed = True
            refresh(models)
        send({"id": mid, "result": {"data": models, "nextCursor": None}})
        return True
    if method == "config/read":
        tier = os.environ.get("FAKE_CODEX_SERVICE_TIER")
        send({"id": mid, "result": {"config": {"service_tier": tier} if tier else {}}})
        return True
    return False
