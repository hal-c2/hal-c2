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

    case args do
      ["install"] ->
        case T3.Service.install() do
          {:ok, result} ->
            Mix.shell().info(
              "Background service #{if result["previouslyInstalled"], do: "updated", else: "installed"}. Logs: #{result["logPath"]}"
            )

          {:error, message} ->
            Mix.raise(message)
        end

      ["status"] ->
        status = T3.Service.status()

        Mix.shell().info(
          cond do
            not status["supported"] ->
              "Background service: not supported on this platform"

            not status["installed"] ->
              "Background service: not installed"

            status["current"] ->
              "Background service: installed\n  Unit: #{status["unitPath"]}\n  Logs: #{status["logPath"]}"

            true ->
              "Background service: installed, needs an update (run `mix t3.service install`)"
          end
        )

      ["uninstall"] ->
        case T3.Service.uninstall() do
          :ok -> Mix.shell().info("Background service removed.")
          {:error, message} -> Mix.raise(message)
        end

      _ ->
        Mix.raise("Usage: mix t3.service install | status | uninstall")
    end
  end
end
