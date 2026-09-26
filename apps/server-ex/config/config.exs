import Config

# State lives in the checkout's gitignored .hal-c2 sandbox during development so a dev
# node never opens the real ~/.hal-c2. A checkout that only has the .t3 sandbox from
# before the rename keeps using it. Releases resolve the user's home in rel/env.sh.eex;
# runtime.exs reads the result.
checkout = Path.expand("../../..", __DIR__)
sandbox = Path.join(checkout, ".hal-c2/elixir")
legacy_sandbox = Path.join(checkout, ".t3/elixir")

home =
  if not File.dir?(sandbox) and File.dir?(legacy_sandbox), do: legacy_sandbox, else: sandbox

config :hal_c2, home: home, start_node: true

import_config "#{config_env()}.exs"
