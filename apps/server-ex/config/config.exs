import Config

# Where the MC keeps its files (`HalC2.Paths`). A release uses the user's XDG
# directories unless config/runtime.exs names a root. A dev MC uses the XDG
# `hal-c2-dev` profile from any checkout, main or worktree, so it never opens the
# installed app's files; tests stay in the checkout's .hal-c2. A dev MC never
# migrates from an old home (`HalC2.Migration`).
if config_env() == :prod do
  config :hal_c2, start_mc: true
else
  home =
    if config_env() == :dev,
      do: :dev,
      else: {:root, Path.expand("../../../.hal-c2", __DIR__)}

  config :hal_c2, home: home, migrate: false, start_mc: true
end

import_config "#{config_env()}.exs"
