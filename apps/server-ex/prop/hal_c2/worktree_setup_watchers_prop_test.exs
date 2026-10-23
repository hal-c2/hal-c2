defmodule HalC2.WorktreeSetupWatchersPropTest do
  @moduledoc """
  Who `HalC2.WorktreeSetup` tells about each thread's setup, against a model: the refs
  each watcher subscribed a thread under (`nil` for one subscribed without a ref) until
  it lets go of each or exits. After every step the server's watchers, read as
  `thread => pid => refs`, must be exactly the model's, with no thread kept for no one,
  and it must monitor each pid once per thread it still watches.

  Commands subscribe and unsubscribe a pool of watchers to a pool of threads under a
  pool of refs, and end a watcher. A watcher's end is waited on through a receive trace
  of the server, so the step reads its state only after the server took the `:DOWN`.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.WorktreeSetup

  @moduletag timeout: :infinity

  @threads ["t1", "t2"]
  @watchers [:a, :b]
  @refs [nil, :r1, :r2]

  property "each thread's watchers are the refs held until each is let go or its pid exits",
    numtests: HalC2.Prop.numtests(200),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      {:ok, server} = GenServer.start(WorktreeSetup, nil, name: WorktreeSetup)
      :erlang.trace(server, true, [:receive])

      {history, state, result} =
        try do
          run_commands(__MODULE__, cmds)
        after
          :erlang.trace(server, false, [:receive])
          GenServer.stop(server)

          for pid <- Map.values(Process.delete({__MODULE__, :pids}) || %{}),
              do: Process.exit(pid, :kill)

          flush_traces()
        end

      (result == :ok)
      |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
      |> aggregate(command_names(cmds))
    end
  end

  # --- model ------------------------------------------------------------------------

  # {thread, watcher} => the refs it holds there.
  def initial_state, do: %{}

  def command(_state) do
    frequency([
      {4, {:call, __MODULE__, :subscribe, [oneof(@threads), oneof(@watchers), oneof(@refs)]}},
      {3, {:call, __MODULE__, :unsubscribe, [oneof(@threads), oneof(@watchers), oneof(@refs)]}},
      {1, {:call, __MODULE__, :leave, [oneof(@watchers)]}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :subscribe, [thread, watcher, ref]}),
    do: Map.update(state, {thread, watcher}, MapSet.new([ref]), &MapSet.put(&1, ref))

  def next_state(state, _result, {:call, _, :unsubscribe, [thread, watcher, ref]}) do
    case Map.fetch(state, {thread, watcher}) do
      {:ok, refs} ->
        refs = MapSet.delete(refs, ref)

        if MapSet.size(refs) == 0,
          do: Map.delete(state, {thread, watcher}),
          else: Map.put(state, {thread, watcher}, refs)

      :error ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :leave, [watcher]}),
    do: Map.reject(state, &match?({{_, ^watcher}, _}, &1))

  def postcondition(state, call, {watchers, monitors}) do
    expected =
      Enum.reduce(next_state(state, nil, call), %{}, fn {{thread, watcher}, refs}, acc ->
        Map.update(acc, thread, %{watcher => refs}, &Map.put(&1, watcher, refs))
      end)

    watchers == expected and monitors == map_size(next_state(state, nil, call))
  end

  # --- commands -----------------------------------------------------------------------

  def subscribe(thread, watcher, ref) do
    WorktreeSetup.subscribe(thread, pid(watcher), real_ref(ref))
    observe()
  end

  def unsubscribe(thread, watcher, ref) do
    WorktreeSetup.unsubscribe(thread, pid(watcher), real_ref(ref))
    observe()
  end

  # Ends the watcher, waits until the server, if it watched it, has its `:DOWN` in its
  # mailbox (the trace of its receive), and gives the slot a new process.
  def leave(watcher) do
    pid = pid(watcher)
    server = Process.whereis(WorktreeSetup)
    {:monitored_by, by} = Process.info(pid, :monitored_by)
    Process.exit(pid, :kill)

    if server in by do
      receive do
        {:trace, ^server, :receive, {:DOWN, _, :process, ^pid, _}} -> :ok
      after
        5_000 -> raise "the server never received the :DOWN of #{inspect(pid)}"
      end
    end

    Process.put({__MODULE__, :pids}, Map.delete(Process.get({__MODULE__, :pids}, %{}), watcher))
    observe()
  end

  # The server's watchers as `thread => watcher => refs`, and how many processes it
  # monitors. `:sys.get_state/1` queues behind the cast or `:DOWN` the step sent.
  defp observe do
    server = Process.whereis(WorktreeSetup)
    %{watchers: watchers} = :sys.get_state(server)
    {:monitors, monitors} = Process.info(server, :monitors)
    names = Map.new(Process.get({__MODULE__, :pids}, %{}), fn {name, pid} -> {pid, name} end)
    refs = Map.new(Process.get({__MODULE__, :refs}, %{}), fn {name, ref} -> {ref, name} end)
    flush_traces()

    read =
      Map.new(watchers, fn {thread, by_pid} ->
        {thread,
         Map.new(by_pid, fn {pid, {_monitor, held}} ->
           {Map.fetch!(names, pid), MapSet.new(held, &if(&1, do: Map.fetch!(refs, &1)))}
         end)}
      end)

    {read, length(monitors)}
  end

  defp pid(watcher) do
    pids = Process.get({__MODULE__, :pids}, %{})

    case pids do
      %{^watcher => pid} ->
        pid

      _ ->
        pid = spawn(fn -> receive(do: (:never -> :ok)) end)
        Process.put({__MODULE__, :pids}, Map.put(pids, watcher, pid))
        pid
    end
  end

  defp real_ref(nil), do: nil

  defp real_ref(name) do
    refs = Process.get({__MODULE__, :refs}, %{})

    case refs do
      %{^name => ref} ->
        ref

      _ ->
        ref = make_ref()
        Process.put({__MODULE__, :refs}, Map.put(refs, name, ref))
        ref
    end
  end

  defp flush_traces do
    receive do
      {:trace, _, :receive, _} -> flush_traces()
    after
      0 -> :ok
    end
  end
end
