defmodule HalC2.WakePropTest do
  @moduledoc """
  `HalC2.Orchestration.Wake` against a model of two threads the user archives,
  unarchives and deletes, woken between those for work their provider finished in the
  background, one wake at a time or several at once. Each wake's tries are refused
  (with an error or a raise) a scripted number of times before the engine takes one.
  The model checks what a wake promises:

  - a thread archived or deleted is never sent the wake, and the wake is dropped;
  - otherwise the wake is tried until the engine takes it, at most ten times, waiting
    `retry_delay/1` of each failed attempt in turn; ten refusals drop it;
  - every try of one wake is the same `message.dispatch`: one message id and command id,
    queued behind the running turn, from the agent by way of the provider;
  - `drain/0` returns only once every wake on its way has been sent or dropped.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration.Wake

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @threads ["t1", "t2"]
  @tries 10

  property "a wake is sent once, unless its thread was put away or every try failed",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("wake")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch,
          HalC2.Orchestration.Wake
        ])

        :ets.new(__MODULE__, [:named_table, :public, :duplicate_bag])
        Application.put_env(:hal_c2, :wake_hook, {__MODULE__, :engine, []})
        Application.put_env(:hal_c2, :wake_pause, {__MODULE__, :pause, []})

        for id <- @threads do
          {:ok, _} =
            HalC2.Orchestration.dispatch(%{
              "type" => "thread.create",
              "threadId" => id,
              "projectId" => "project-1",
              "title" => id,
              "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
              "runtimeMode" => "full-access",
              "interactionMode" => "default"
            })
        end

        {history, state, result} = run_commands(__MODULE__, cmds)
        Application.delete_env(:hal_c2, :wake_hook)
        Application.delete_env(:hal_c2, :wake_pause)
        :ets.delete(__MODULE__)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  property "the wait between tries doubles from 100 ms to at most 5 s" do
    forall attempt <- non_neg_integer() do
      delay = Wake.retry_delay(attempt)

      delay == min(100 * 2 ** min(attempt, 6), 5_000) and delay >= 100 and delay <= 5_000 and
        Wake.retry_delay(attempt + 1) >= delay
    end
  end

  # --- model ----------------------------------------------------------------------

  # `away`: the threads archived or deleted; `deleted`: those deleted, for good.
  # `next`: the number of the next wake.
  def initial_state, do: %{away: MapSet.new(), deleted: MapSet.new(), next: 0}

  def command(state) do
    live = Enum.reject(@threads, &(&1 in state.deleted))

    frequency(
      [
        {5, {:call, __MODULE__, :wake, [state.next, oneof(@threads), refusals()]}},
        {2,
         {:call, __MODULE__, :wakes,
          [state.next, resize(3, non_empty(list({oneof(@threads), refusals()})))]}}
      ] ++
        if(live == [],
          do: [],
          else: [
            {2, {:call, __MODULE__, :archive, [oneof(live)]}},
            {2, {:call, __MODULE__, :unarchive, [oneof(live)]}},
            {1, {:call, __MODULE__, :delete, [oneof(live)]}}
          ]
        )
    )
  end

  # How each refused try fails, the engine taking the try after them. Mostly a few;
  # now and then every try.
  defp refusals,
    do:
      frequency([
        {6, resize(3, list(oneof([:error, :raise])))},
        {1, vector(@tries, oneof([:error, :raise]))}
      ])

  def precondition(state, {:call, _, :archive, [thread]}), do: thread not in state.away

  def precondition(state, {:call, _, :unarchive, [thread]}),
    do: thread in state.away and thread not in state.deleted

  def precondition(state, {:call, _, :delete, [thread]}), do: thread not in state.deleted
  def precondition(state, {:call, _, :wake, [n | _]}), do: n == state.next
  def precondition(state, {:call, _, :wakes, [n | _]}), do: n == state.next
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :wake, _}), do: %{state | next: state.next + 1}

  def next_state(state, _result, {:call, _, :wakes, [_, wakes]}),
    do: %{state | next: state.next + length(wakes)}

  def next_state(state, _result, {:call, _, :archive, [thread]}),
    do: %{state | away: MapSet.put(state.away, thread)}

  def next_state(state, _result, {:call, _, :unarchive, [thread]}),
    do: %{state | away: MapSet.delete(state.away, thread)}

  def next_state(state, _result, {:call, _, :delete, [thread]}),
    do: %{
      state
      | away: MapSet.put(state.away, thread),
        deleted: MapSet.put(state.deleted, thread)
    }

  def postcondition(state, {:call, _, :wake, [n, thread, refusals]}, [outcome]),
    do: kept?(state, {n, thread, refusals}, outcome)

  def postcondition(state, {:call, _, :wakes, [n, wakes]}, outcomes) do
    expected = Enum.with_index(wakes, fn {thread, refusals}, i -> {n + i, thread, refusals} end)

    length(outcomes) == length(expected) and
      Enum.all?(Enum.zip(expected, outcomes), fn {w, o} -> kept?(state, w, o) end)
  end

  def postcondition(_state, _call, result), do: result == :ok

  defp kept?(state, {_n, thread, refusals}, %{tries: tries, pauses: pauses, dropped: dropped}) do
    cond do
      thread in state.away ->
        tries == [] and dropped

      length(refusals) >= @tries ->
        length(tries) == @tries and one_wake?(tries, thread) and dropped and
          pauses == Enum.to_list(0..(@tries - 2))

      true ->
        length(tries) == length(refusals) + 1 and one_wake?(tries, thread) and not dropped and
          pauses == Enum.to_list(0..(length(refusals) - 1)//1)
    end
  end

  defp one_wake?([first | _] = tries, thread) do
    Enum.all?(tries, &(&1 == first)) and
      match?(
        %{
          "type" => "message.dispatch",
          "threadId" => ^thread,
          "dispatchMode" => %{"type" => "queue_after_active"},
          "createdBy" => "agent",
          "creationSource" => "provider"
        },
        first
      ) and first["commandId"] == "command:wake:#{first["messageId"]}"
  end

  # --- commands -------------------------------------------------------------------

  def wake(n, thread, refusals), do: wakes(n, [{thread, refusals}])

  # Sends each wake at once and waits on the drain; each wake's tries and waits are
  # told apart by its text.
  def wakes(n, wakes) do
    parent = self()

    for {{thread, refusals}, i} <- Enum.with_index(wakes) do
      text = "wake #{n + i}"
      :ets.insert(__MODULE__, {{:script, text}, refusals})

      Wake.deliver(thread, %{"text" => text},
        on_dropped: fn -> send(parent, {:dropped, text}) end
      )
    end

    :ok = Wake.drain()

    for i <- 0..(length(wakes) - 1) do
      text = "wake #{n + i}"

      %{
        tries:
          for({{:try, ^text}, command} <- :ets.lookup(__MODULE__, {:try, text}), do: command),
        pauses:
          for({{:pause, ^text}, attempt} <- :ets.lookup(__MODULE__, {:pause, text}), do: attempt),
        dropped:
          receive do
            {:dropped, ^text} -> true
          after
            0 -> false
          end
      }
    end
  end

  def archive(thread), do: put_away(thread, "thread.archive")
  def unarchive(thread), do: put_away(thread, "thread.unarchive")
  def delete(thread), do: put_away(thread, "thread.delete")

  defp put_away(thread, type) do
    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => type, "threadId" => thread})
    :ok
  end

  # --- the engine's stand-in ------------------------------------------------------

  @doc false
  # Refuses the wake's next scripted try, then takes it in place of the engine.
  def engine(%{"text" => text} = command) do
    :ets.insert(__MODULE__, {{:try, text}, command})
    Process.put({:wake_text, self()}, text)
    [{_, refusals}] = :ets.lookup(__MODULE__, {:script, text})
    tried = length(:ets.lookup(__MODULE__, {:try, text}))

    case Enum.at(refusals, tried - 1) do
      nil -> {:ok, :sent}
      :error -> {:error, "refused"}
      :raise -> raise "refused"
    end
  end

  @doc false
  # Records the wait asked for, by the wake this task is trying, and waits none.
  def pause(attempt) do
    text = Process.get({:wake_text, self()})
    :ets.insert(__MODULE__, {{:pause, text}, attempt})
    0
  end
end
