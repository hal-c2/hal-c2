import Config

# Tests start the pieces they need under their own supervisors.
config :hal_c2, start_node: false
config :logger, level: :warning

# Text generation never reaches a real model; tests that need it set a fake.
config :hal_c2, text_claude_command: "hal-c2-test-no-claude", text_codex_command: "hal-c2-test-no-codex"

# Provider update checks never reach the npm registry.
config :hal_c2, provider_update_checks: false

# Usage pricing never fetches the LiteLLM table; tests that price point this at a file.
config :hal_c2, usage_rates_url: "hal-c2-test-no-usage-rates.json"

# The background policy never reads this machine's power supplies; tests that do
# point this at a directory of fake ones.
config :hal_c2, power_supply_dir: nil
