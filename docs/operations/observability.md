# Observability

> For maintainers. Using HAL-C2? See [docs/user](../user/).

The MC has three sources of diagnostic data:

- logs go to stdout for humans
- while tracing is on, finished spans go to a local NDJSON trace file
- client spans can be forwarded over OTLP to a real backend like Grafana LGTM

Resource sampling is separate: see [resource telemetry](../internals/resource-telemetry.md).

## Where to find things

### Logs

Logs are human-facing: Elixir's `Logger` writes to stdout. Under the background service, stdout and
stderr append to `logs/boot-service.log` in the MC's state directory ([Running HAL-C2 in the
background](../user/background-service.md)). A foreground `mise run mc` has no log file.

### Traces

[`HalC2.Traces`](../../apps/server-ex/lib/hal_c2/traces.ex) owns the trace file. Tracing is off
until `HAL_C2_TRACE=1` is in the MC's environment at start. While it is on, `Traces.span/3` appends
one `effect-span` record per finished span to `logs/server.trace.ndjson` in the MC's state
directory, rotating at 10 MiB into `.1` … `.10`. The state directory is
`~/.local/state/hal-c2/elixir` for an installed MC, `~/.local/state/hal-c2-dev/elixir` for the dev
MC, and `<dir>/state` for an MC given `HAL_C2_MC_HOME=<dir>` ([storage](../internals/storage.md)).
Settings → Diagnostics reads the files back (`server.getTraceDiagnostics`).

Spans cover boundaries the MC chose to trace, such as `orchestration.dispatchCommand` and
`checkpoint.capture`; grep for `HalC2.Traces.span` to see them all. Records have:

- `type`: `effect-span` for the MC's own spans, `otlp-span` for a client's
- `name`, `traceId`, `spanId`, `durationMs`
- `attributes`: structured context
- `exit` on `effect-span` records: `Success` or `Failure`

Clients post OTLP JSON to `/api/observability/v1/traces`. While tracing is on the MC keeps those
spans in the same file as `otlp-span` records.

### Metrics

The MC exports no metrics and keeps no metrics file.

## Forwarding to an OTLP backend

Set `HAL_C2_OTLP_TRACES_URL` to a collector's trace endpoint, and `HAL_C2_OTLP_HEADERS`
(`key=value,key=value`, values URL-encoded) for any headers it needs. The MC forwards the client
spans it accepts there, whether or not tracing is on. It does not forward its own spans.

With Grafana LGTM:

```bash
docker run --name lgtm -p 3000:3000 -p 4317:4317 -p 4318:4318 --rm -ti grafana/otel-lgtm
HAL_C2_OTLP_TRACES_URL=http://localhost:4318/v1/traces mise run mc
```

Grafana is then at `http://localhost:3000` (login `admin` / `admin`). The MC reads this at start,
so restart it after changing the variables. The installed service takes its environment from the
unit or launch agent, not from your shell.

## Debugging from the trace file

```bash
TRACE_FILE=~/.local/state/hal-c2-dev/elixir/logs/server.trace.ndjson
tail -f "$TRACE_FILE"
```

Failed spans:

```bash
jq -c 'select(.type == "effect-span" and .exit._tag != "Success") | {name, durationMs, exit, attributes}' "$TRACE_FILE"
```

Slow spans:

```bash
jq -c 'select(.durationMs > 1000) | {name, durationMs, traceId, spanId}' "$TRACE_FILE"
```

## Adding tracing

Wrap a boundary, not a tiny helper: a command dispatch, a checkpoint, a request to a provider. Put
high-cardinality detail (ids, paths) in the span's attributes. A function returning `{:error, reason}`
or raising records a failure and returns its result unchanged, so wrapping does not change
behavior.
