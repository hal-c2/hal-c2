import Config

# State lives in the repo's gitignored .hal-c2 sandbox during development so a dev node
# never opens the real ~/.hal-c2/userdata. Releases default HALC2_HOME to ~/.hal-c2/elixir
# (rel/env.sh.eex); runtime.exs reads it.
config :hal_c2, home: Path.expand("../../../.hal-c2/elixir", __DIR__), start_node: true

import_config "#{config_env()}.exs"
