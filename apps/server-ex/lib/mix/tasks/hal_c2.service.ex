defmodule Mix.Tasks.HalC2.Service do
  @shortdoc "Installs, shows, restarts or removes the MC's background service"
  @moduledoc """
  Runs this MC as a background service for the current user (`hal-c2 service`,
  `apps/server/src/cli/service.ts`): a systemd user unit on Linux, a LaunchAgent
  on macOS (`HalC2.Service`).

      mix hal_c2.service install     # start now and at every boot (Linux) or login (macOS)
      mix hal_c2.service status      # whether it is installed and up to date, and what to fix
      mix hal_c2.service restart     # start it again on the version installed now
      mix hal_c2.service uninstall   # stop it and remove it from startup

  Signing out of HAL-C2 Connect leaves the service alone.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case HalC2.Service.command(args) do
      {:ok, text} -> Mix.shell().info(text)
      {:error, message} -> Mix.raise(message)
    end
  end
end
