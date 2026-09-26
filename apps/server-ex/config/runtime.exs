import Config

if home = System.get_env("HALC2_HOME"), do: config(:hal_c2, home: home)
if port = System.get_env("HALC2_NODE_PORT"), do: config(:hal_c2, port: String.to_integer(port))
# The address to bind, loopback by default; a LAN or tailnet address lets other devices pair.
# `HALC2_HOST` is the Node server's name for it; `HALC2_NODE_HOST` is kept alongside `HALC2_NODE_PORT`.
if host = System.get_env("HALC2_HOST") || System.get_env("HALC2_NODE_HOST"),
  do: config(:hal_c2, host: host)

# Local trace file and the collector client spans are forwarded to (`HalC2.Traces`).
if System.get_env("HALC2_TRACE") in ~w(1 true), do: config(:hal_c2, trace: true)
if url = System.get_env("HALC2_OTLP_TRACES_URL"), do: config(:hal_c2, otlp_traces_url: url)

if headers = System.get_env("HALC2_OTLP_HEADERS") do
  otlp_headers =
    for pair <- String.split(headers, ","),
        [key, value] <- [String.split(pair, "=", parts: 2)],
        into: %{},
        do: {String.trim(key), URI.decode(String.trim(value))}

  config(:hal_c2, otlp_headers: otlp_headers)
end

if System.get_env("HALC2_PROVIDER_EVENT_LOG") in ~w(1 true),
  do: config(:hal_c2, provider_event_log: true)

# The reusable development credential (docs/operations/development.md), dev builds only.
if config_env() == :dev do
  if token = System.get_env("HALC2_DEV_AUTH_TOKEN"), do: config(:hal_c2, dev_auth_token: token)
end
