defmodule HalC2.RuntimeRecord do
  @moduledoc """
  `<state dir>/server-runtime.json`: where local tools (the TUI) find a running node.

  Written once the listener is bound and removed when the node stops, with the Node
  server's field names (`apps/server/src/serverRuntimeState.ts`) so a tool can read
  either. A node killed without stopping leaves it behind; readers check `pid`.
  Starts after `HalC2.Web` so it stops before the listener does.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The record's path under the node's state directory."
  def path, do: Path.join(HalC2.Paths.state_dir(), "server-runtime.json")

  @doc "The record this node writes: `version`, `pid`, `port`, `origin`, `startedAt`, and `host` when one is set."
  def record do
    host = Application.get_env(:hal_c2, :host)
    port = HalC2.Web.port()

    %{
      "version" => 1,
      "pid" => String.to_integer(System.pid()),
      "port" => port,
      "origin" => "http://#{origin_host(host)}:#{port}",
      "startedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> then(&if(host, do: Map.put(&1, "host", host), else: &1))
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    contents = JSON.encode!(record()) <> "\n"
    path = path()
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, contents)
    File.rename!(tmp, path)
    {:ok, %{path: path, contents: contents}}
  end

  @impl true
  def terminate(_reason, %{path: path, contents: contents}) do
    # Another node may have taken the state directory over since; leave its record alone.
    if File.read(path) == {:ok, contents}, do: File.rm(path)
    :ok
  end

  # A wildcard bind is reached on loopback, as the Node server records it.
  defp origin_host(host) when host in [nil, "0.0.0.0", "::"], do: "127.0.0.1"
  defp origin_host(host), do: if(String.contains?(host, ":"), do: "[#{host}]", else: host)
end
