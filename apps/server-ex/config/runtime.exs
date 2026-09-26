import Config

if home = System.get_env("T3_HOME"), do: config(:t3, home: home)
if port = System.get_env("T3_PORT"), do: config(:t3, port: String.to_integer(port))
# The listener's bind address (loopback by default); a LAN or tailnet address lets
# other machines pair.
if host = System.get_env("T3_HOST"), do: config(:t3, host: host)
