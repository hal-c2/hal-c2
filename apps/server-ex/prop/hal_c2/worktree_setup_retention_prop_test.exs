defmodule HalC2.WorktreeSetupRetentionPropTest do
  @moduledoc """
  How `HalC2.WorktreeSetup` keeps each thread's setup, against a model: progress counts
  only while it runs, its end is kept with one expiry, and only that expiry's own message
  removes it; a failure the agent's stage never reached has no expiry, and goes only when
  the thread's agent starts a turn without it. Setups are put in the server's state directly, since a real one has a
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

  # thread => %{phase: "running" | ended phase, sequence: n, branch: what a cancel deletes,
  # renaming: the name it may have taken already}
  def initial_state, do: %{}

  def command(_state) do
    frequency([
      {2, {:call, __MODULE__, :seed, [oneof(@threads)]}},
      {4, {:call, __MODULE__, :progress, [oneof(@threads)]}},
      {2, {:call, __MODULE__, :finish, [oneof(@threads), oneof(~w(done failed cancelled))]}},
      {2, {:call, __MODULE__, :superseded, [oneof(@threads)]}},
      {2, {:call, __MODULE__, :expire_own, [oneof(@threads)]}},
      {2, {:call, __MODULE__, :expire_stale, [oneof(@threads)]}},
      {2, {:call, __MODULE__, :cleaned_up, [oneof(@threads), oneof(~w(own stale))]}},
      {2,
       {:call, __MODULE__, :renaming,
        [oneof(@threads), oneof(~w(own stale)), oneof(["named", nil])]}},
      {2, {:call, __MODULE__, :renamed, [oneof(@threads), oneof(~w(own stale))]}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :seed, [thread]}),
    do:
      Map.put(state, thread, %{phase: "running", sequence: 0, branch: "temporary", renaming: nil})

  # A cancel's cleanup ending counts for its own run only, and only while that runs.
  def next_state(state, _result, {:call, _, :cleaned_up, [thread, "own"]}) do
    case state[thread] do
      %{phase: "running"} = setup ->
        Map.put(state, thread, %{setup | phase: "cancelled", sequence: setup.sequence + 1})

      _ ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :renaming, [thread, "own", name]}) do
    case state[thread] do
      nil -> state
      setup -> Map.put(state, thread, %{setup | renaming: name})
    end
  end

  def next_state(state, _result, {:call, _, :renamed, [thread, "own"]}) do
    case state[thread] do
      %{renaming: name} = setup when is_binary(name) ->
        Map.put(state, thread, %{setup | branch: name, renaming: nil})

      _ ->
        state
    end
  end

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
      %{phase: phase} when phase in ~w(running failed) -> state
      _ -> Map.delete(state, thread)
    end
  end

  def next_state(state, _result, {:call, _, :superseded, [thread]}) do
    case state[thread] do
      %{phase: "failed"} -> Map.delete(state, thread)
      _ -> state
    end
  end

  def next_state(state, _result, _call), do: state

  # After every step the server holds what the model does, and an ended setup that cannot
  # be retried alone has an expiry.
  def postcondition(state, {:call, _, :cleaned_up, _} = call, result),
    do: result == :answered and same_as_model?(state, call)

  def postcondition(state, call, _result), do: same_as_model?(state, call)

  defp same_as_model?(state, call) do
    model = next_state(state, nil, call)
    %{setups: setups} = :sys.get_state(WorktreeSetup)

    Map.new(setups, fn {thread, setup} ->
      {thread,
       %{
         phase: setup.snapshot["phase"],
         sequence: setup.snapshot["sequence"],
         branch: setup.new_branch,
         renaming: setup.renaming
       }}
    end) == model and
      Enum.all?(setups, fn {_, setup} ->
        Map.has_key?(setup, :expiry) == setup.snapshot["phase"] not in ~w(running failed)
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
        %{"id" => "checkout", "status" => "running", "detail" => nil, "endedAt" => nil},
        %{"id" => "agent", "status" => "pending", "detail" => nil, "endedAt" => nil}
      ]
    }

    :sys.replace_state(WorktreeSetup, fn state ->
      setup = %{
        snapshot: snapshot,
        cancellable: true,
        run_id: "run",
        new_branch: "temporary",
        renaming: nil
      }

      put_in(state.setups[thread], setup)
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

  def superseded(thread) do
    WorktreeSetup.superseded(thread)
    :sys.get_state(WorktreeSetup)
  end

  # The caller of a cancel is answered whichever run its cleanup was for.
  def cleaned_up(thread, run) do
    ref = make_ref()
    send(WorktreeSetup, {:cancelled, thread, run_id(run), {self(), ref}})

    receive do
      {^ref, true} -> :answered
    after
      5_000 -> :unanswered
    end
  end

  def renaming(thread, run, name),
    do: GenServer.call(WorktreeSetup, {:renaming, thread, run_id(run), name})

  def renamed(thread, run), do: GenServer.call(WorktreeSetup, {:renamed, thread, run_id(run)})

  defp run_id("own"), do: "run"
  defp run_id("stale"), do: "replaced"

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
