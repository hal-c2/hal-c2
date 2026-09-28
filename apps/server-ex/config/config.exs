import Config

# Where the node keeps its files (`HalC2.Paths`). A release uses the user's XDG
# directories unless config/runtime.exs names a root. A dev node follows the dev
# runner (`packages/shared/src/devHome.ts`): a linked git worktree keeps its files in
# its own gitignored .hal-c2, any other checkout in the XDG `hal-c2-dev` profile, so
# it never opens the installed app's files. Tests stay in the checkout's .hal-c2. A
# dev node never migrates from an old home (`HalC2.Migration`).
if config_env() == :prod do
  config :hal_c2, start_node: true
else
  checkout = Path.expand("../../..", __DIR__)

  # A linked worktree's `.git` is a file pointing at `<common-dir>/worktrees/<name>`.
  linked_worktree? =
    case File.read(Path.join(checkout, ".git")) do
      {:ok, pointer} -> pointer =~ ~r{^gitdir:\s*\S.*[/\\]worktrees[/\\][^/\\\s]+[/\\]?\s*$}m
      {:error, _} -> false
    end

  home =
    if config_env() == :dev and not linked_worktree?,
      do: :dev,
      else: {:root, Path.join(checkout, ".hal-c2")}

  config :hal_c2, home: home, migrate: false, start_node: true
end

import_config "#{config_env()}.exs"
