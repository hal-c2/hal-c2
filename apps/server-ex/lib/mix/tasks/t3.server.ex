defmodule Mix.Tasks.T3.Server do
  @shortdoc "Runs the node and prints its client URL"
  @moduledoc """
  Starts the node in the foreground and prints the WebSocket URL with its token.

      mix t3.server
      elixir --name t3@HOST -S mix t3.server   # as a named, clusterable node
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    announce()
    Process.sleep(:infinity)
  end

  @doc "Prints the running node's WebSocket URL with its access token."
  def announce do
    Mix.shell().info("T3 node #{node()} #{T3.Web.base_url("ws")}/ws?token=#{T3.Web.token()}")
  end
end
