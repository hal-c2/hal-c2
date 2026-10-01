defmodule Mix.Tasks.HalC2.Server do
  @shortdoc "Runs the MC and prints its client URL"
  @moduledoc """
  Starts the MC in the foreground and prints the WebSocket URL with its token.

      mix hal_c2.server

  It clusters when the VM was booted for it (`mise run mc`, `HalC2.Cluster`).
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    announce()
    Process.sleep(:infinity)
  end

  @doc """
  Prints the running MC's WebSocket URL with its access token, and how to pair a
  client: the access token is for local tools, and pairing takes a one-time code.
  """
  def announce do
    Mix.shell().info(
      "HAL-C2 MC #{node()} #{HalC2.Web.base_url("ws")}/ws?token=#{HalC2.Web.token()}"
    )

    Mix.shell().info(
      "To pair a client, run `mise run mc:pair` (`--tailscale` to reach it from other devices); the token above is not a pairing code."
    )
  end
end
