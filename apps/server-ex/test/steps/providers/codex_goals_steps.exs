defmodule HalC2.Steps.Providers.CodexGoals do
  @moduledoc """
  Steps for the `/goal` scenarios of `features/providers/codex.feature`: Codex's own
  goal, which the fake app-server keeps (`test/support/fake_codex_goals.py`) and works
  toward in turns of its own.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc.World

  @thread "Codex goal"
  @objective "ship the fix"

  # The goal each command finds: one to pause is active, the others a paused one.
  @seeded %{
    "/goal pause" => "active",
    "/goal resume" => "paused",
    "/goal clear" => "paused",
    "/goal" => "paused"
  }

  step "the user sends {string} in a Codex thread", %{args: [input]} = context do
    context = World.fake_providers(context)
    # The fake goes on with the goal at once, so no grace may run out between its turns:
    # a slow runner took longer than the default five seconds and the goal was paused.
    World.put_app_env(:codex_goal_grace_ms, 3_600_000)

    if status = @seeded[input],
      do: World.put_env("FAKE_CODEX_GOAL", JSON.encode!(%{objective: @objective, status: status}))

    context
    |> World.launch_on(@thread, "codex", input)
    |> Map.put(:goal_input, input)
  end

  step "the thread uses Codex's goal for it", context do
    state = World.await_runs(context, @thread, ["completed"], 10_000)
    calls = goal_calls(context)

    case context.goal_input do
      "/goal " <> @objective ->
        assert [
                 {"thread/goal/get", _},
                 {"thread/goal/set", %{"objective" => @objective, "status" => "paused"}},
                 {"thread/goal/set", %{"status" => "active"} = active}
               ] = calls

        refute Map.has_key?(active, "objective")
        assert %{"objective" => @objective, "status" => "complete"} = goal(state)

      "/goal pause" ->
        assert [{"thread/goal/get", _}, {"thread/goal/set", %{"status" => "paused"}}] = calls
        assert %{"objective" => @objective, "status" => "paused"} = goal(state)

      "/goal resume" ->
        assert [{"thread/goal/get", _}, {"thread/goal/set", %{"status" => "active"}}] = calls
        assert %{"objective" => @objective, "status" => "complete"} = goal(state)

      "/goal clear" ->
        assert [{"thread/goal/get", _}, {"thread/goal/clear", _}] = calls
        assert goal(state) == nil

      "/goal" ->
        assert [{"thread/goal/get", _}] = calls
        assert "Goal paused: #{@objective}" in assistant_texts(state)
    end

    Map.put(context, :goal_state, state)
  end

  # The fake works toward an active goal in two turns of its own after the one that
  # set it, completing it in the last.
  step "while a goal is active, Codex's follow-up turns stay in the same run and the thread stays Working",
       context do
    state = context.goal_state
    assert [run] = StreamState.list(state, "run")
    turns = StreamState.list(state, "provider-turn")

    case context.goal_input do
      input when input in ["/goal #{@objective}", "/goal resume"] ->
        native = Enum.map(turns, &get_in(&1, ["nativeTurnRef", "nativeId"]))

        expected =
          if input == "/goal resume",
            do: ["goal-turn-1", "goal-turn-2"],
            else: [first_turn(native), "goal-turn-1", "goal-turn-2"]

        assert native == expected
        assert [attempt] = StreamState.list(state, "run-attempt")
        assert attempt["runId"] == run["id"]

        assert Enum.all?(
                 turns,
                 &(&1["runAttemptId"] == attempt["id"] and &1["status"] == "completed")
               )

        # Working until the last of them ended.
        assert Enum.all?(turns, &(&1["completedAt"] <= run["completedAt"]))
        assert run_running_through_turns?(context)

        assert ["Working toward the goal (1)", "Working toward the goal (2)"] --
                 assistant_texts(state) == []

      _ ->
        assert turns == []
    end

    context
  end

  step "a Codex thread is working toward a goal", context do
    context = World.fake_providers(context)
    World.put_env("FAKE_CODEX_GOAL_STALL", "1")
    World.put_app_env(:codex_goal_grace_ms, 200)
    context = World.launch_on(context, @thread, "codex", "/goal #{@objective}")
    World.await_provider_log(context, "codex", &goal_set?(&1, "active"))
    context
  end

  # The grace is cut short for the test; the run waits it out on the runtime's timer.
  step "the run ends and Codex does not continue the goal within five seconds", context do
    state = World.await_runs(context, @thread, ["completed"])
    assert [_first_turn] = StreamState.list(state, "provider-turn")
    Map.put(context, :goal_state, state)
  end

  step "the goal shows as paused", context do
    assert %{"status" => "paused", "objective" => @objective} = goal(context.goal_state)

    assert [{"thread/goal/set", %{"status" => "paused"}} | _] =
             context |> goal_calls() |> Enum.reverse()

    context
  end

  step "a turn Codex starts for it later is stopped", context do
    {_pid, runtime} = World.codex_runtime(context, @thread)

    World.codex_notify(context, @thread, "turn/started", %{
      "threadId" => runtime.native_thread_id,
      "turn" => %{"id" => "late-goal-turn", "status" => "inProgress"}
    })

    World.await_provider_log(
      context,
      "codex",
      &match?(
        %{"in" => %{"method" => "turn/interrupt", "params" => %{"turnId" => "late-goal-turn"}}},
        &1
      )
    )

    # Stopping it started no run.
    assert ["completed"] ==
             World.stream(context, @thread) |> StreamState.list("run") |> statuses()

    context
  end

  step "the goal never shows as paused while it starts", context do
    World.await_runs(context, @thread, ["completed"], 10_000)
    id = World.thread_id(context, @thread)

    shown =
      HalC2.Store.path()
      |> HalC2.Store.reduce_stream(id, 0, [], fn event, acc ->
        if event.kind == "provider-thread", do: [inspect(event.patch) | acc], else: acc
      end)

    assert Enum.any?(shown, &(&1 =~ ~s("goal")))
    refute Enum.any?(shown, &(&1 =~ ~s("goal") and &1 =~ ~s("paused")))
    context
  end

  step "Codex is asked to start working toward {string}", %{args: [objective]} = context do
    turn_start =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))

    texts = for %{"text" => text} <- get_in(turn_start, ["in", "params", "input"]), do: text
    assert Enum.any?(texts, &(&1 =~ "Start working toward this goal: #{objective}"))
    context
  end

  step "a Codex thread is working toward {string}", %{args: [objective]} = context do
    context = World.fake_providers(context)
    World.put_env("FAKE_CODEX_GOAL", JSON.encode!(%{objective: objective, status: "active"}))
    Map.put(context, :goal_objective, objective)
  end

  # Counted as Codex counts them, in Unicode scalar values, not bytes.
  step ~r/^the user sends "(?<command>[^"]+)" with an objective of (?<count>[\d,]+) characters$/,
       %{args: [command, count]} = context do
    objective = String.duplicate("é", count |> String.replace(",", "") |> String.to_integer())
    text = "#{command} #{objective}"
    context = World.launch_on(context, @thread, "codex", text)
    Map.put(context, :goal_text, text)
  end

  step ~r/^the turn fails saying the objective has (?<count>[\d,]+) characters and must be at most (?<max>[\d,]+)$/,
       %{args: [count, max]} = context do
    state = World.await_runs(context, @thread, ["failed"])
    assert [run] = StreamState.list(state, "run")
    failure = inspect(run["failure"] || run)
    assert failure =~ "#{count} characters"
    assert failure =~ "at most #{max}"
    assert goal_calls(context) == []
    Map.put(context, :goal_state, state)
  end

  step "the message stays in the thread", context do
    assert context.goal_text in (context.goal_state
                                 |> StreamState.list("message")
                                 |> Enum.filter(&(&1["role"] == "user"))
                                 |> Enum.map(& &1["text"]))

    context
  end

  step "the thread is still working toward {string}", %{args: [objective]} = context do
    {:ok, _} = World.send_message(context, @thread, "/goal") |> elem(0)
    state = World.await_runs(context, @thread, ["failed", "completed"])
    assert "Goal active: #{objective}" in assistant_texts(state)
    refute Enum.any?(goal_calls(context), &match?({"thread/goal/" <> m, _} when m != "get", &1))
    context
  end

  # --- helpers ------------------------------------------------------------------------

  defp goal_calls(context) do
    for %{"in" => %{"method" => "thread/goal/" <> _ = method} = msg} <-
          World.provider_log(context, "codex"),
        do: {method, msg["params"]}
  end

  defp goal_set?(entry, status),
    do:
      match?(
        %{"in" => %{"method" => "thread/goal/set", "params" => %{"status" => ^status}}},
        entry
      )

  defp goal(state) do
    assert [thread] = StreamState.list(state, "provider-thread")
    thread["goal"]
  end

  defp assistant_texts(state) do
    for %{"role" => "assistant", "text" => text} <- StreamState.list(state, "message"), do: text
  end

  defp statuses(runs), do: Enum.map(runs, & &1["status"])

  defp first_turn([first | _]), do: first

  # Every provider turn of the run but the last ended while the run was still
  # running: the run's own events say it stayed running until the last one ended.
  defp run_running_through_turns?(context) do
    id = World.thread_id(context, @thread)

    events =
      HalC2.Store.path()
      |> HalC2.Store.reduce_stream(id, 0, [], &[&1 | &2])
      |> Enum.reverse()

    completed_runs =
      Enum.filter(
        events,
        &(&1.kind == "run" and inspect(&1.patch) =~ ~s("completed"))
      )

    last_turn_done =
      events
      |> Enum.filter(&(&1.kind == "provider-turn" and inspect(&1.patch) =~ ~s("completed")))
      |> List.last()

    match?([_], completed_runs) and hd(completed_runs).seq >= last_turn_done.seq
  end
end
