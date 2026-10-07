defmodule HalC2.RuntimeRecord do
  @moduledoc """
  `<state dir>/server-runtime.json`: where local tools (the TUI) find a running MC.

  Written once the listener is bound and removed when the MC stops, with the Node
  server's field names (`apps/server/src/serverRuntimeState.ts`) so a tool can read
  either. An MC killed without stopping leaves it behind; readers check `pid`.
  Starts after `HalC2.Web` so it stops before the listener does.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The record's path under the MC's state directory."
  def path, do: Path.join(HalC2.Paths.state_dir(), "server-runtime.json")

  @doc "The record this MC writes: `version`, `pid`, `port`, `origin`, `startedAt`, and `host` when one is set."
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

  @doc """
  The MC running with no HAL-C2 home configured, for a tool started with none either
  (`own` is its `:home`, `nil` or `:dev`): `{home, record}` of the profile that has a
  live record, the tool's own profile first, or nil when neither runs. So
  `mix hal_c2.pair` from a checkout finds the installed MC, and the other way round.
  """
  def locate(own) when own in [nil, :dev] do
    Enum.find_value([own | [nil, :dev] -- [own]], fn home ->
      if record = running(home), do: {home, record}
    end)
  end

  def locate(_own), do: nil

  @doc """
  The live record of the MC of one profile (`nil` the installed one, `:dev` one run
  from a checkout), or nil when that one is not running: for a tool that was told
  which of the two it means, as `mix hal_c2.pair --release` is.
  """
  def running(home) when home in [nil, :dev] do
    state = HalC2.Paths.mc_dirs(home, System.get_env(), HalC2.Paths.user_home()).state

    with {:ok, text} <- File.read(Path.join(state, "server-runtime.json")),
         {:ok, %{"pid" => pid, "origin" => origin} = record} when is_integer(pid) <-
           JSON.decode(text),
         true <- is_binary(origin) and alive?(pid) do
      record
    else
      _ -> nil
    end
  end

  # A record outlives an MC that was killed; its process does not.
  defp alive?(pid) do
    case HalC2.Paths.platform() do
      :windows ->
        # tasklist exits 0 either way; a pid that is gone gets a line of prose instead.
        {out, 0} = System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/FO", "CSV", "/NH"])
        String.contains?(out, ",\"#{pid}\",")

      :unix ->
        match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
    end
  rescue
    _ -> false
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
    # Another MC may have taken the state directory over since; leave its record alone.
    if File.read(path) == {:ok, contents}, do: File.rm(path)
    :ok
  end

  # A wildcard bind is reached on loopback, as the Node server records it.
  defp origin_host(host) when host in [nil, "0.0.0.0", "::"], do: "127.0.0.1"
  defp origin_host(host), do: if(String.contains?(host, ":"), do: "[#{host}]", else: host)
end
