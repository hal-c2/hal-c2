import Config

# The node's state directory. `HAL_C2_NODE_HOME` names it outright (rel/env.sh.eex and
# service units set it); `HAL_C2_HOME` is the HAL-C2 home shared with the Node server,
# whose state is under `userdata/`, and the node keeps its own under `elixir/`.
# `T3_HOME` and `T3CODE_HOME` are those two from before the rename. A checkout ignores
# the shared home a dev server or agent may have exported, like the Node dev runner:
# its own `.hal-c2` wins (config.exs).
present = fn name -> if (value = System.get_env(name)) not in [nil, ""], do: value end
shared = config_env() == :prod

home =
  cond do
    dir = present.("HAL_C2_NODE_HOME") -> dir
    base = shared && present.("HAL_C2_HOME") -> Path.join(base, "elixir")
    dir = present.("T3_HOME") -> dir
    base = shared && present.("T3CODE_HOME") -> Path.join(base, "elixir")
    true -> nil
  end

if home, do: config(:hal_c2, home: home)
if port = present.("HAL_C2_NODE_PORT"), do: config(:hal_c2, port: String.to_integer(port))
# The address to bind, loopback by default; a LAN or tailnet address lets other devices pair.
# `HAL_C2_NODE_HOST` sits alongside `HAL_C2_NODE_PORT`; `HAL_C2_HOST`, the Node server's name
# for it, is the fallback.
if host = present.("HAL_C2_NODE_HOST") || present.("HAL_C2_HOST"),
  do: config(:hal_c2, host: host)

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
