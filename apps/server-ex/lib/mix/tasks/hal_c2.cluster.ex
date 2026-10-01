defmodule Mix.Tasks.HalC2.Cluster do
  @shortdoc "Shows, invites to, joins and leaves the cluster of your machines"
  @moduledoc """
      mix hal_c2.cluster                               # this machine and the other members
      mix hal_c2.cluster invite [BASE_URL] [--tailscale] # a link another machine joins with
      mix hal_c2.cluster join LINK                     # join the link's machine's cluster
      mix hal_c2.cluster remove MEMBER                 # stop admitting a member anywhere

  Asks the MC running from this checkout (`mise run mc`); see `HalC2.Cluster.Command`.
  An installed MC has the same commands as `hal-c2-service cluster ...`.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case HalC2.Cluster.Command.command(args) do
      {:ok, text} -> Mix.shell().info(text)
      {:error, message} -> Mix.raise(message)
    end
  end
end
