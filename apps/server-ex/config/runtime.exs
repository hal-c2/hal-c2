import Config

if home = System.get_env("T3_HOME"), do: config(:t3, home: home)
if port = System.get_env("T3_PORT"), do: config(:t3, port: String.to_integer(port))
# The address to bind, loopback by default; a LAN or tailnet address lets other devices pair.
if host = System.get_env("T3CODE_HOST"), do: config(:t3, host: host)

# Local trace file and the collector client spans are forwarded to (`T3.Trace`).
if System.get_env("T3CODE_TRACE") in ~w(1 true), do: config(:t3, trace: true)
if url = System.get_env("T3CODE_OTLP_TRACES_URL"), do: config(:t3, otlp_traces_url: url)

if headers = System.get_env("T3CODE_OTLP_HEADERS") do
  otlp_headers =
    for pair <- String.split(headers, ","),
        [key, value] <- [String.split(pair, "=", parts: 2)],
        into: %{},
        do: {String.trim(key), URI.decode(String.trim(value))}

  config(:t3, otlp_headers: otlp_headers)
end

if System.get_env("T3CODE_PROVIDER_EVENT_LOG") in ~w(1 true),
  do: config(:t3, provider_event_log: true)

# The reusable development credential (docs/operations/development.md), dev builds only.
if config_env() == :dev do
  if token = System.get_env("T3CODE_DEV_AUTH_TOKEN"), do: config(:t3, dev_auth_token: token)
end
