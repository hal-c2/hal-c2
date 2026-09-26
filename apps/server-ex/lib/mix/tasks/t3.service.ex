defmodule Mix.Tasks.T3.Service do
  @shortdoc "Installs, shows or removes the node's background service"
  @moduledoc """
  Runs this node as a background service for the current user (`t3 service`,
  `apps/server/src/cli/service.ts`): a systemd user unit on Linux, a LaunchAgent
  on macOS (`T3.Service`).

      mix t3.service install     # start now and at every boot (Linux) or login (macOS)
      mix t3.service status      # whether it is installed and up to date
      mix t3.service uninstall   # stop it and remove it from startup

  Signing out of T3 Connect leaves the service alone.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case T3.Service.command(args) do
      {:ok, text} -> Mix.shell().info(text)
      {:error, message} -> Mix.raise(message)
    end
  end
end
