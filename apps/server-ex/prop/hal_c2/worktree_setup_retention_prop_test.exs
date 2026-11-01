defmodule HalC2.WorktreeSetupRetentionPropTest do
  @moduledoc """
  How `HalC2.WorktreeSetup` keeps each thread's setup, against a model: progress counts
  only while it runs, its end is kept with one expiry, and only that expiry's own message
  removes it. Setups are put in the server's state directly, since a real one has a
  worker racing the commands; retention is long enough that only a sent `:expire` acts.

  Beside it, two pure properties: how output is cut into lines does not depend on how it
  arrived, and ending a setup touches only its running stages.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.WorktreeSetup

  @moduletag timeout: :infinity

  @threads ["t1", "t2"]

  property "a setup ends once and only its own expiry removes it",
    numtests: HalC2.Prop.numtests(200),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      Application.put_env(:hal_c2, :worktree_setup_retention, 3_600_000)
      {:ok, server} = GenServer.start(WorktreeSetup, nil, name: WorktreeSetup)

      {history, state, result} =
        try do
          run_commands(__MODULE__, cmds)
        after
          GenServer.stop(server)
          Application.delete_env(:hal_c2, :worktree_setup_retention)
        end

      (result == :ok)
      |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
      |> aggregate(command_names(cmds))
    end
  end

  property "lines do not depend on how the output was split",
    numtests: HalC2.Prop.numtests(200) do
    forall {pieces, cut} <- {list(oneof(["a", "bc", "\n", "\r", "\r\n", "\e[31m", "\a"])), nat()} do
      data = Enum.join(pieces)
      at = min(cut, byte_size(data))
      {first, rest} = {binary_part(data, 0, at), binary_part(data, at, byte_size(data) - at)}

      {lines_a, partial} = WorktreeSetup.script_lines("", first)
      {lines_b, partial} = WorktreeSetup.script_lines(partial, rest)

      # A "\r\n" cut in two is two line ends, and a line cut has no blank: blanks never show.
      shown = &Enum.reject(&1, fn line -> line == "" end)
      {whole, whole_partial} = WorktreeSetup.script_lines("", data)
      shown.(lines_a ++ lines_b) == shown.(whole) and partial == whole_partial
    end
  end

  property "ending a setup settles its running stages and no others",
    numtests: HalC2.Prop.numtests(200) do
    forall {statuses, phase} <-
             {list(oneof(~w(pending running done skipped failed warning))),
              oneof(~w(done failed cancelled))} do
      stages =
        statuses
        |> Enum.with_index()
        |> Enum.map(fn {status, id} -> %{"id" => id, "status" => status, "endedAt" => nil} end)

      ended = WorktreeSetup.finish(%{"stages" => stages}, phase, nil)
      settled = if phase == "cancelled", do: "skipped", else: phase

      ended["phase"] == phase and
        Enum.zip(stages, ended["stages"])
        |> Enum.all?(fn
          {%{"status" => "running"}, stage} -> stage["status"] == settled and stage["endedAt"]
          {stage, same} -> stage == same
        end)
    end
  end

  # --- model ------------------------------------------------------------------------

  # thread => %{phase: "running" | ended phase, sequence: n}
  def initial_state, do: %{}

  def command(_state) do
    frequency([
      {2, {:call, __MODULE__, :seed, [oneof(@threads)]}},
      {4, {:call, __MODULE__, :progress, [oneof(@threads)]}},
      {2, {:call, __MODULE__, :finish, [oneof(@threads), oneof(~w(done failed cancelled))]}},
      {2, {:call, __MODULE__, :expire_own, [oneof(@threads)]}},
      {2, {:call, __MODULE__, :expire_stale, [oneof(@threads)]}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :seed, [thread]}),
    do: Map.put(state, thread, %{phase: "running", sequence: 0})

  def next_state(state, _result, {:call, _, :progress, [thread]}) do
    case state[thread] do
      %{phase: "running"} = setup ->
        Map.put(state, thread, %{setup | sequence: setup.sequence + 1})

      _ ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :finish, [thread, phase]}) do
    case state[thread] do
      %{phase: "running"} = setup ->
        Map.put(state, thread, %{setup | phase: phase, sequence: setup.sequence + 1})

      _ ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :expire_own, [thread]}) do
    case state[thread] do
      %{phase: "running"} -> state
      _ -> Map.delete(state, thread)
    end
  end

  def next_state(state, _result, _call), do: state

  # After every step the server holds what the model does, and an ended setup alone has
  # an expiry.
  def postcondition(state, call, _result) do
    model = next_state(state, nil, call)
    %{setups: setups} = :sys.get_state(WorktreeSetup)

    Map.new(setups, fn {thread, setup} ->
      {thread, %{phase: setup.snapshot["phase"], sequence: setup.snapshot["sequence"]}}
    end) == model and
      Enum.all?(setups, fn {_, setup} ->
        Map.has_key?(setup, :expiry) == (setup.snapshot["phase"] != "running")
      end)
  end

  # --- commands ---------------------------------------------------------------------

  def seed(thread) do
    snapshot = %{
      "threadId" => thread,
      "phase" => "running",
      "sequence" => 0,
      "error" => nil,
      "endedAt" => nil,
      "stages" => [
        %{"id" => "checkout", "status" => "running", "detail" => nil, "endedAt" => nil}
      ]
    }

    :sys.replace_state(WorktreeSetup, fn state ->
      put_in(state.setups[thread], %{snapshot: snapshot, cancellable: true})
    end)
  end

  def progress(thread) do
    GenServer.call(
      WorktreeSetup,
      {:update, thread, &WorktreeSetup.set_stage(&1, "checkout", "running", %{"percent" => 1})}
    )
  end

  def finish(thread, phase) do
    GenServer.call(WorktreeSetup, {:update, thread, &WorktreeSetup.finish(&1, phase, nil)})
  end

  def expire_own(thread) do
    with %{expiry: {_, ref}} <- :sys.get_state(WorktreeSetup).setups[thread] do
      send(WorktreeSetup, {:expire, thread, ref})
    end

    :sys.get_state(WorktreeSetup)
  end

  def expire_stale(thread) do
    send(WorktreeSetup, {:expire, thread, make_ref()})
    :sys.get_state(WorktreeSetup)
  end
end
