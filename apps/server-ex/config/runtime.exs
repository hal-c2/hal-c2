import Config

# Where the MC keeps its files (`HalC2.Paths`). `HAL_C2_MC_HOME` is a root for the
# MC alone; `HAL_C2_HOME` is the HAL-C2 root shared with the TypeScript server, which
# `HalC2.Paths` ignores when it names an old home (`~/.t3`, `~/.hal-c2`). With neither,
# a release uses the XDG directories. A checkout ignores the HAL_C2_HOME a dev server
# or agent may have exported: its own `.hal-c2` wins (config.exs). T3CODE_HOME and
# T3_HOME only say where to migrate from (`HalC2.Migration`).
present = fn name -> if (value = System.get_env(name)) not in [nil, ""], do: value end

cond do
  dir = present.("HAL_C2_MC_HOME") -> config(:hal_c2, home: {:mc, dir})
  root = config_env() == :prod && present.("HAL_C2_HOME") -> config(:hal_c2, home: {:root, root})
  true -> :ok
end

if port = present.("HAL_C2_MC_PORT"), do: config(:hal_c2, port: String.to_integer(port))
# The address to bind, loopback by default; a LAN or tailnet address lets other devices pair.
# `HAL_C2_MC_HOST` sits alongside `HAL_C2_MC_PORT`; `HAL_C2_HOST`, the Node server's name
# for it, is the fallback.
if host = present.("HAL_C2_MC_HOST") || present.("HAL_C2_HOST"),
  do: config(:hal_c2, host: host)

# A scratch MC on a copy of real data, whose projects are real checkouts, does nothing nobody
# asked for: no restart continuations or requeued runs (`HalC2.Orchestration.Recovery`), no
# limit resumes (`HalC2.Orchestration.LimitRecovery`), no boot pulls (`HalC2.Projects`), no
# background fetches (`HalC2.Vcs.Watch`).
if System.get_env("HAL_C2_MC_NO_AUTO_ACTIONS") in ~w(1 true),
  do: config(:hal_c2, auto_actions: false)

# Local trace file and the collector client spans are forwarded to (`HalC2.Traces`).
if System.get_env("HAL_C2_TRACE") in ~w(1 true), do: config(:hal_c2, trace: true)
if url = System.get_env("HAL_C2_OTLP_TRACES_URL"), do: config(:hal_c2, otlp_traces_url: url)

if headers = System.get_env("HAL_C2_OTLP_HEADERS") do
  otlp_headers =
    for pair <- String.split(headers, ","),
        [key, value] <- [String.split(pair, "=", parts: 2)],
        into: %{},
        do: {String.trim(key), URI.decode(String.trim(value))}

  config(:hal_c2, otlp_headers: otlp_headers)
end

if System.get_env("HAL_C2_PROVIDER_EVENT_LOG") in ~w(1 true),
  do: config(:hal_c2, provider_event_log: true)

# The reusable development credential (docs/operations/development.md), dev builds only.
if config_env() == :dev do
  if token = System.get_env("HAL_C2_DEV_AUTH_TOKEN"), do: config(:hal_c2, dev_auth_token: token)
end
