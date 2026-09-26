import Config

# Where the node keeps its files (`HalC2.Paths`). A release uses the user's XDG
# directories unless config/runtime.exs names a root. During development the
# checkout's gitignored .hal-c2 is the root, so a dev node never opens the user's
# own files, and it never migrates from an old home (`HalC2.Migration`).
if config_env() == :prod do
  config :hal_c2, start_node: true
else
  checkout = Path.expand("../../..", __DIR__)
  config :hal_c2, home: {:root, Path.join(checkout, ".hal-c2")}, migrate: false, start_node: true
end

import_config "#{config_env()}.exs"
