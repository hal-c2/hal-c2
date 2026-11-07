defmodule HalC2.Terminal.Hub do
  @moduledoc """
  This MC's terminals as a list (`subscribeTerminalMetadata`), and which command
  each shell is running.

  Terminals report their summary here; watchers (client sockets, possibly on other
  MCs) get the list once and then `{:hal_c2_terminals, mc, event}` messages shaped
  as `TerminalMetadataStreamEvent`. While any shell runs, one `ps` per second finds
  each shell's child process and tells the terminal when it changes, so its label
  can show the running command.

  It also holds what outlives one terminal's process: who follows a closed terminal
  until it opens again (`closed/3`), and how many ended terminals stay in memory.
  """

  use GenServer

  @poll_ms 1_000
  @ended_limit 128
  @ended ~w(exited error)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Adds `pid` as a watcher; returns every terminal's summary."
  def watch(pid, ref \\ nil), do: GenServer.call(__MODULE__, {:watch, pid, ref})

  def unwatch(pid, ref \\ nil), do: GenServer.cast(__MODULE__, {:unwatch, pid, ref})

  @doc "Records a terminal's current summary; `session` is its process."
  def upsert(summary, session), do: GenServer.cast(__MODULE__, {:upsert, summary, session})

  @doc "A terminal has closed; `followers` are handed to its next process when it reports."
  def closed(thread_id, terminal_id, followers),
    do: GenServer.cast(__MODULE__, {:closed, {thread_id, terminal_id}, followers})

  @doc "`pid` no longer follows a closed terminal."
  def forget(thread_id, terminal_id, pid),
    do: GenServer.cast(__MODULE__, {:forget, {thread_id, terminal_id}, pid})

  @doc "Every terminal's summary, without watching."
  def summaries do
    GenServer.call(__MODULE__, :summaries)
  catch
    :exit, {:noproc, _} -> []
  end

  @impl true
  def init(nil) do
    {:ok,
     %{
       terminals: %{},
       sessions: %{},
       watchers: %{},
       activity: %{},
       polling: false,
       # Closed terminal => %{following pid => monitor}.
       followers: %{}
     }, {:continue, :resync}}
  end

  # A restarted hub starts empty while the terminals live on: each running terminal is
  # asked to report its summary again. Watchers have to watch again.
  @impl true
  def handle_continue(:resync, state) do
    pids =
      try do
        Registry.select(HalC2.Terminal.Registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
      rescue
        ArgumentError -> []
      end

    for pid <- pids, do: send(pid, :report)
    {:noreply, state}
  end

  @impl true
  def handle_call(:summaries, _from, state),
    do: {:reply, for({_key, {summary, _session}} <- state.terminals, do: summary), state}

  def handle_call({:watch, pid, ref}, _from, state) do
    watchers = HalC2.Watchers.add(state.watchers, pid, ref)
    summaries = for {_key, {summary, _session}} <- state.terminals, do: summary
    {:reply, summaries, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:unwatch, pid, ref}, state) do
    watchers = HalC2.Watchers.remove(state.watchers, pid, ref)
    {:noreply, %{state | watchers: watchers}}
  end

  def handle_cast({:upsert, summary, session}, state) do
    key = {summary["threadId"], summary["terminalId"]}

    sessions =
      if Map.has_key?(state.sessions, session),
        do: state.sessions,
        else: Map.put(state.sessions, session, {key, Process.monitor(session)})

    broadcast(state, %{"type" => "upsert", "terminal" => summary})

    {followers, waiting} = Map.pop(state.followers, key, %{})
    for {_pid, ref} <- followers, do: Process.demonitor(ref, [:flush])
    if followers != %{}, do: send(session, {:followers, Map.keys(followers)})

    state = %{
      state
      | terminals: Map.put(state.terminals, key, {summary, session}),
        sessions: sessions,
        followers: waiting
    }

    if summary["status"] in @ended, do: evict_ended(state)
    {:noreply, maybe_poll(state)}
  end

  def handle_cast({:closed, key, followers}, state) do
    followers =
      if followers == [],
        do: state.followers,
        else: Map.put(state.followers, key, Map.new(followers, &{&1, Process.monitor(&1)}))

    {:noreply, drop(%{state | followers: followers}, key)}
  end

  def handle_cast({:forget, key, pid}, state) do
    followers = Map.get(state.followers, key, %{})
    if ref = followers[pid], do: Process.demonitor(ref, [:flush])

    {:noreply,
     %{state | followers: put_followers(state.followers, key, Map.delete(followers, pid))}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    cond do
      (watchers = HalC2.Watchers.down(state.watchers, ref, pid)) != state.watchers ->
        {:noreply, %{state | watchers: watchers}}

      match?(%{^pid => {_, ^ref}}, state.sessions) ->
        {key, _} = state.sessions[pid]
        state = %{state | sessions: Map.delete(state.sessions, pid)}

        # A terminal reopened under the same key may have reported before this DOWN.
        case state.terminals do
          %{^key => {_summary, ^pid}} -> {:noreply, drop(state, key)}
          _ -> {:noreply, state}
        end

      true ->
        followers =
          Enum.reduce(state.followers, state.followers, fn {key, pids}, acc ->
            put_followers(acc, key, Map.delete(pids, pid))
          end)

        {:noreply, %{state | followers: followers}}
    end
  end

  def handle_info(:poll, state) do
    hub = self()
    Task.start(fn -> send(hub, {:processes, process_table()}) end)
    {:noreply, state}
  end

  def handle_info({:processes, table}, state) do
    activity =
      for {key, {%{"status" => "running", "pid" => pid}, session}} <- state.terminals,
          is_integer(pid),
          into: %{} do
        current = child(table, pid)

        if current != Map.get(state.activity, key, {false, nil}),
          do: send(session, {:activity, elem(current, 0), elem(current, 1)})

        {key, current}
      end

    {:noreply, maybe_poll(%{state | activity: activity, polling: false})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A hub from before followers has no field for them.
  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.put_new(state, :followers, %{})}

  defp put_followers(followers, key, pids) when pids == %{}, do: Map.delete(followers, key)
  defp put_followers(followers, key, pids), do: Map.put(followers, key, pids)

  # An ended terminal is only there to be read, and its scrollback stays on disk, so past
  # the limit those that changed least recently are told to go.
  defp evict_ended(state) do
    limit = Application.get_env(:hal_c2, :terminal_ended_limit, @ended_limit)

    ended =
      for {_key, {%{"status" => status, "updatedAt" => at}, session}} <- state.terminals,
          status in @ended,
          do: {at, session}

    for {_at, session} <- ended |> Enum.sort() |> Enum.take(max(length(ended) - limit, 0)),
        do: send(session, :evict)
  end

  defp drop(state, key) do
    case Map.pop(state.terminals, key) do
      {nil, _} ->
        state

      {_, terminals} ->
        {thread_id, terminal_id} = key

        broadcast(state, %{
          "type" => "remove",
          "threadId" => thread_id,
          "terminalId" => terminal_id
        })

        %{state | terminals: terminals, activity: Map.delete(state.activity, key)}
    end
  end

  defp broadcast(state, event) do
    HalC2.Watchers.notify(state.watchers, {:hal_c2_terminals, node(), event})
  end

  # Polls only while some shell is running.
  defp maybe_poll(%{polling: true} = state), do: state

  defp maybe_poll(state) do
    if Enum.any?(state.terminals, fn {_, {summary, _}} -> summary["status"] == "running" end) do
      Process.send_after(self(), :poll, @poll_ms)
      %{state | polling: true}
    else
      state
    end
  end

  # `{first child by parent pid, command by pid}` from `ps`, which lists by pid.
  defp process_table do
    ps =
      Application.get_env(:hal_c2, :terminal_ps) ||
        Enum.find(["/bin/ps", "/usr/bin/ps"], &File.exists?/1) || "ps"

    case System.cmd(ps, ["-eo", "pid=,ppid=,comm="], stderr_to_stdout: true) do
      {out, 0} ->
        for line <- String.split(out, "\n"),
            [_, pid, ppid, command] <- [Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(.+)$/, line)],
            reduce: {%{}, %{}} do
          {children, commands} ->
            pid = String.to_integer(pid)
            ppid = String.to_integer(ppid)
            {Map.put_new(children, ppid, pid), Map.put(commands, pid, String.trim(command))}
        end

      _ ->
        {%{}, %{}}
    end
  rescue
    _ -> {%{}, %{}}
  end

  # The shell's first child and its command name, e.g. `{true, "vim"}`.
  defp child({children, commands}, shell_pid) do
    case Map.fetch(children, shell_pid) do
      {:ok, pid} -> {true, command_name(Map.get(commands, pid, ""))}
      :error -> {false, nil}
    end
  end

  defp command_name(raw) do
    raw = String.trim(raw)

    raw =
      if Regex.match?(~r/^(\[.*\]|\(.*\))$/, raw),
        do: raw |> String.slice(1..-2//1) |> String.trim(),
        else: raw

    case String.split(raw) do
      [first | _] -> first |> Path.basename() |> String.slice(0, 128)
      [] -> nil
    end
  end
end
