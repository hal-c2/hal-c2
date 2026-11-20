#!/bin/sh
# Fake `cli-proxy-api -config <path>` for the CLIProxyAPI plugin's scenarios. It listens
# on nothing (`HalC2.Test.FakeCliProxyApi` answers its management API): it notes each
# run in `fake-runs.log` next to its config, says it started, and waits. TERM stops it;
# USR1 makes it fail as a proxy whose port is taken does. It gives up by itself after
# five minutes, so a run the scenario lost never outlives it for long.
trap 'kill $! 2>/dev/null; exit 0' TERM
trap 'kill $! 2>/dev/null; echo "fatal: listen tcp 127.0.0.1: bind: address already in use"; exit 3' USR1
dir=$(dirname "$2")
printf '%s %s %s MANAGEMENT_PASSWORD=%s WRITABLE_PATH=%s\n' "$$" "$1" "$2" \
  "$([ -n "$MANAGEMENT_PASSWORD" ] && echo set || echo unset)" "$WRITABLE_PATH" >> "$dir/fake-runs.log"
echo "CLIProxyAPI Version: 8.0.79 (fake)"
# The traps stop it by `$!`, set as soon as it starts. It is kept off the Port's pipe,
# so the Port sees this script exit even if a signal beat it.
sleep 300 </dev/null >/dev/null 2>&1 &
wait $!
