defmodule Mix.Tasks.HalC2.Server do
  @shortdoc "Runs the node and prints its client URL"
  @moduledoc """
  Starts the node in the foreground and prints the WebSocket URL with its token.

      mix hal_c2.server
      elixir --name hal_c2@HOST -S mix hal_c2.server   # as a named, clusterable node
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    announce()
    Process.sleep(:infinity)
  end

  @doc """
  Prints the running node's WebSocket URL with its access token, and how to pair a
  client: the access token is for local tools, and pairing takes a one-time code.
  """
  def announce do
    Mix.shell().info(
      "HAL-C2 node #{node()} #{HalC2.Web.base_url("ws")}/ws?token=#{HalC2.Web.token()}"
    )

    Mix.shell().info(
      "To pair a client, run `mise run node:pair` (`--tailscale` to reach it from other devices); the token above is not a pairing code."
    )
  end
end
