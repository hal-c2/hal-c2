defmodule HalC2Plugins.CliProxyApi.Proxy do
  @moduledoc """
  The `cli-proxy-api` process, run through a Port. One spec at a time: `run/1` starts
  it (and is a no-op when the same spec already runs), `halt/0` stops it. A process
  that exits is started again after a backoff that doubles from a second to a minute,
  and starts over at a second once one has run for a minute. Every start, exit and
  restart is sent to the process that last called `run/1` as
  `{:cliproxyapi_proxy, status}`.

  It is stopped by the OS pid the Port reported, `TERM` and then `KILL`, never by a
  name or pattern. That pid is kept in a pidfile next to the config, so a proxy left
  running by an MC that died is stopped at the next start, and only when that pid
  still runs with this config.

  `config :hal_c2, :cliproxyapi, backoff_ms: {first, max}` sets the backoff, as the
  property test does.
  """

  use GenServer, shutdown: 10_000

  @backoff {1_000, 60_000}
  @healthy_ms 60_000
  @stop_ms 3_000
  @lines 20

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Runs `spec`: `%{binary, args, env, cd, pidfile}`, `env` a map of variables. Answers
  the status.
  """
  def run(spec), do: GenServer.call(__MODULE__, {:run, spec}, @stop_ms * 3)

  @doc "Stops the proxy and forgets its spec."
  def halt, do: GenServer.call(__MODULE__, :halt, @stop_ms * 3)

  @doc "The status: `%{state, pid, restarts, lines, code}`."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       spec: nil,
       owner: nil,
       port: nil,
       os_pid: nil,
       started: nil,
       restarts: 0,
       backoff: first_backoff(),
       timer: nil,
       lines: [],
       code: nil,
       state: "stopped"
     }}
  end

  @impl true
  def handle_call({:run, spec}, {owner, _}, %{spec: spec} = state)
      when state.state in ["running", "restarting"],
      do: {:reply, view(state), %{state | owner: owner}}

  def handle_call({:run, spec}, {owner, _}, state) do
    state =
      state
      |> stop()
      |> Map.merge(%{spec: spec, owner: owner, restarts: 0, backoff: first_backoff()})

    state = start(state)
    {:reply, view(state), state}
  end

  def handle_call(:halt, _from, state) do
    state = %{stop(state) | spec: nil, state: "stopped"}
    {:reply, view(state), state}
  end

  def handle_call(:status, _from, state), do: {:reply, view(state), state}

  @impl true
  def handle_info({port, {:data, {_eol, line}}}, %{port: port} = state),
    do:
      {:noreply, %{state | lines: Enum.take([String.slice(line, 0, 500) | state.lines], @lines)}}

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    File.rm(state.spec.pidfile)
    ran = System.monotonic_time(:millisecond) - state.started
    backoff = if ran >= @healthy_ms, do: first_backoff(), else: state.backoff
    timer = Process.send_after(self(), :restart, backoff)

    state = %{
      state
      | port: nil,
        os_pid: nil,
        code: code,
        timer: timer,
        backoff: min(backoff * 2, max_backoff()),
        state: "restarting"
    }

    {:noreply, tell(state, %{"retryInMs" => backoff})}
  end

  # Only a proxy waiting to restart: a timer that fired as `run/1` or `halt/0` cancelled
  # it leaves its message behind, and starting on it would start a second process.
  def handle_info(:restart, %{state: "restarting", port: nil} = state),
    do: {:noreply, start(%{state | timer: nil, restarts: state.restarts + 1})}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop(state)

  defp start(%{spec: spec} = state) do
    stop_left_behind(spec)

    port =
      Port.open({:spawn_executable, spec.binary}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 2_000},
        {:args, spec.args},
        {:cd, spec.cd},
        {:env, Enum.map(spec.env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    File.write!(spec.pidfile, "#{os_pid}\n")

    state = %{
      state
      | port: port,
        os_pid: os_pid,
        started: System.monotonic_time(:millisecond),
        code: nil,
        state: "running"
    }

    tell(state, %{})
  rescue
    error ->
      tell(
        %{
          state
          | port: nil,
            os_pid: nil,
            state: "failed",
            lines: [Exception.message(error) | state.lines]
        },
        %{}
      )
  end

  # Stops what runs now: TERM the pid the Port gave, wait for its exit, then KILL.
  defp stop(%{port: nil} = state), do: cancel(state)

  defp stop(%{port: port, os_pid: os_pid} = state) do
    signal("TERM", os_pid)

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      @stop_ms ->
        signal("KILL", os_pid)

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          1_000 -> :ok
        end
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    if state.spec, do: File.rm(state.spec.pidfile)
    cancel(%{state | port: nil, os_pid: nil, state: "stopped"})
  end

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  # A pid this plugin recorded and that still runs with this config is a proxy an MC
  # that died left behind; any other pid in the file is someone else's by now.
  defp stop_left_behind(spec) do
    with {:ok, text} <- File.read(spec.pidfile),
         {pid, _} <- Integer.parse(String.trim(text)),
         {:unix, _} <- :os.type(),
         {command, 0} <-
           System.cmd("ps", ["-o", "command=", "-p", to_string(pid)], stderr_to_stdout: true),
         true <- Enum.all?(spec.args, &String.contains?(command, &1)) do
      # It holds the port the new one listens on: wait for it to go.
      signal("TERM", pid)
      unless gone?(pid, div(@stop_ms, 100)), do: signal("KILL", pid)
    end

    File.rm(spec.pidfile)
  end

  defp gone?(pid, tries) do
    cond do
      not match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)) ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(100)
        gone?(pid, tries - 1)
    end
  end

  defp signal(name, os_pid) do
    case :os.type() do
      {:unix, _} ->
        System.cmd("kill", ["-#{name}", to_string(os_pid)], stderr_to_stdout: true)

      {:win32, _} ->
        System.cmd("taskkill", ["/F", "/PID", to_string(os_pid)], stderr_to_stdout: true)
    end
  rescue
    _ -> :ok
  end

  defp first_backoff, do: elem(backoff(), 0)
  defp max_backoff, do: elem(backoff(), 1)

  defp backoff,
    do: Keyword.get(Application.get_env(:hal_c2, :cliproxyapi, []), :backoff_ms, @backoff)

  defp tell(%{owner: owner} = state, extra) do
    if owner, do: send(owner, {:cliproxyapi_proxy, Map.merge(view(state), extra)})
    state
  end

  defp view(state) do
    %{
      "state" => state.state,
      "pid" => state.os_pid,
      "restarts" => state.restarts,
      "code" => state.code,
      "lines" => Enum.reverse(state.lines)
    }
  end
end
