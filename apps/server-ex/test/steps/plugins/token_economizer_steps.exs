defmodule HalC2.Steps.Plugins.TokenEconomizer do
  @moduledoc """
  Steps for `features/plugins/token-economizer-loop-guard.feature`, on the real package
  in the repository's `plugins/token-economizer`, copied into the MC's plugins directory
  as a user would install it.

  Threads run on the fake Claude, whose "loop N" turn edits `a.py` and runs the same
  failing test N times over ("loop N and wait" then stays open). The plugin's judge asks
  the fake text CLI, which answers every turn productive, so what the guard does here
  is its free path. What a project learned is seeded by writing its envelope's file
  before the turn. The plugin's `loopGuard` topic is watched from the start, and the
  steps wait on it for what the guard decided.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @id "token-economizer"
  @package Path.expand("../../../../../plugins/token-economizer", __DIR__)
  @thread "Stuck"
  @instance "claudeAgent"

  # --- background ------------------------------------------------------------------------

  step "an MC running the TokenEconomizer plugin", context do
    dir = Path.join([context.mc.home, "plugins", @id])
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(@package, dir)

    context =
      context
      |> World.fake_providers()
      |> World.fake_text_clis([:claude])
      |> World.update_settings(%{
        "textGenerationModelSelection" => %{
          "instanceId" => @instance,
          "model" => "claude-haiku-5-5"
        }
      })
      |> World.create_project("Shop")
      |> Fixtures.ensure()
      |> Fixtures.rescan()

    accepted = Enum.map(Fixtures.entry(@id)["permissions"], & &1["id"])

    {_, context} =
      World.call!(context, "plugins.enable", %{"id" => @id, "acceptPermissions" => accepted})

    assert %{"status" => "running"} = Fixtures.entry(@id)
    watch(context)
  end

  # --- what the project learned, and the settings ----------------------------------------

  step "a project whose Claude turns that ended green ran {int} tool calls each",
       %{args: [calls]} = context do
    path = envelope_path(context)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      JSON.encode!(%{"level" => "default", "resolved_turns" => List.duplicate(calls, 5)})
    )

    context
  end

  step "a project TokenEconomizer has not learned", context do
    refute File.exists?(envelope_path(context))
    context
  end

  step "TokenEconomizer may send no redirects", context do
    save(context, %{"loopGuardNudges" => 0})
  end

  step "TokenEconomizer only watches", context do
    save(context, %{"loopGuard" => "watch"})
  end

  step "the person pins the threshold {string} to {int}", %{args: [name, value]} = context do
    {reply, context} =
      World.call(context, "plugins.saveSettings", %{
        "id" => @id,
        "settings" => %{"loopGuardThresholds" => %{name => value}}
      })

    Map.put(context, :reply, reply)
  end

  step "the settings are refused with {string}", %{args: [text]} = context do
    assert {:error, message, _} = context.reply
    assert message =~ text
    # The refusal names the thresholds there are.
    assert message =~ "min_turns"
    context
  end

  # --- turns -----------------------------------------------------------------------------

  step "Claude keeps editing a file and getting the same test failure", context do
    context = World.launch_on(context, @thread, @instance, "loop 8 and wait")
    World.await_running(context, @thread)
    context
  end

  step "Claude keeps editing a file and getting the same test failure until the turn ends",
       context do
    turns = context |> runs() |> length()
    context = turn(context, "loop 8")
    await_turns(context, turns + 1)
  end

  step "a Claude turn that runs one command ends green", context do
    turns = context |> runs() |> length()
    context = turn(context, "hello")
    await_turns(context, turns + 1)
  end

  step "the person stops the turn", context do
    run = context |> runs() |> List.last()

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread),
        "runId" => run["id"]
      })

    context
  end

  step "the turn ends interrupted", context do
    World.await_runs(context, @thread, ["interrupted"])
    context
  end

  # --- what the guard did ----------------------------------------------------------------

  step "Claude is sent a redirect in that turn", context do
    {_, context} = await_topic(context, &(&1["nudges"] == 1))

    World.await_provider_log(context, "claude", fn entry ->
      redirect?(entry) and JSON.encode!(entry["in"]) =~ "Process check (automated)"
    end)

    # The redirect cuts the stuck turn short and the agent goes on in it: one turn.
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the turn shows the notice {string} from TokenEconomizer without a way to stop it",
       %{args: [title]} = context do
    notice = await_notice(context)
    assert notice["title"] == title
    assert notice["actions"] in [nil, []]
    context
  end

  step "the turn shows the notice {string} from TokenEconomizer, offering to stop the turn",
       %{args: [title]} = context do
    notice = await_notice(context)
    assert notice["title"] == title
    assert notice["actions"] == ["interrupt"]
    assert notice["runId"] == (context |> runs() |> List.last())["id"]
    context
  end

  step "the turn is still running and Claude was sent no redirect", context do
    {status, context} = await_topic(context, &(&1["aborts"] == 1 and &1))
    assert status["nudges"] == 0
    assert [%{"status" => "running"}] = runs(context)
    refute Enum.any?(World.provider_log(context, "claude"), &redirect?/1)
    context
  end

  step "TokenEconomizer counts one redirect", context do
    # The count can be published before the delivery is: wait for its entry, the receipt.
    {status, context} = await_topic(context, &(&1["nudges"] == 1 and logged?(&1, true) and &1))

    assert [%{"action" => "nudge", "delivered" => true} = entry] = status["recent"]
    assert entry["threadId"] == World.thread_id(context, @thread)
    context
  end

  step "TokenEconomizer counts one redirect it did not deliver", context do
    {status, context} = await_topic(context, &(&1["turns"] == 1 and logged?(&1, false) and &1))

    assert status["mode"] == "watch"
    assert %{"nudges" => 1, "aborts" => 0} = status
    assert [%{"action" => "nudge", "delivered" => false}] = status["recent"]
    context
  end

  step "Claude was sent no redirect and the turn shows no notice from TokenEconomizer",
       context do
    # The topic is published as the turn closes, after anything the guard did in it.
    {status, context} = await_topic(context, &(&1["turns"] >= 1 and &1))
    assert status["aborts"] == 0
    refute Enum.any?(World.provider_log(context, "claude"), &redirect?/1)
    assert notices(context) == []
    context
  end

  step "the project's envelope has learned one turn of {int} tool call",
       %{args: [calls]} = context do
    assert %{"resolved_turns" => [^calls]} = saved(context)
    context
  end

  step "the project's envelope has still learned one turn", context do
    assert %{"resolved_turns" => [_]} = saved(context)
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  # The plugin's module is compiled when the plugin starts, after this file.
  defp envelope_path(context) do
    plugin = Module.concat(HalC2Plugins, TokenEconomizer)
    plugin.envelope_path({World.project(context).id, @instance})
  end

  defp saved(context), do: context |> envelope_path() |> File.read!() |> JSON.decode!()

  defp save(context, patch) do
    # The plugin has the new settings once the call returns.
    {_, context} =
      World.call!(context, "plugins.saveSettings", %{"id" => @id, "settings" => patch})

    context
  end

  # The scenario's thread's next turn: the first launches it.
  defp turn(context, text) do
    if context[:threads][@thread],
      do: World.post_message(context, @thread, text),
      else: World.launch_on(context, @thread, @instance, text)
  end

  defp runs(context),
    do: if(context[:threads][@thread], do: World.runs(context, @thread), else: [])

  # Waits until the guard has closed `count` turns: the topic is published as one closes.
  defp await_turns(context, count) do
    {_, context} = await_topic(context, &(&1["turns"] >= count))
    context
  end

  defp redirect?(%{"in" => %{"type" => "user", "priority" => "now"}}), do: true
  defp redirect?(_), do: false

  defp notices(context) do
    context
    |> World.stream(@thread)
    |> HalC2.StreamState.list("turn-item")
    |> Enum.filter(&(&1["type"] == "system_notice" and &1["pluginId"] == @id))
  end

  defp await_notice(context) do
    World.await_value(context, @thread, fn _ ->
      case notices(context) do
        [notice] -> notice
        _ -> nil
      end
    end)
  end

  # Watches the plugin's `loopGuard` topic; `await_topic/2` waits on it.
  defp watch(context) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "loopGuard"
    }

    client = context |> World.client("token-economizer") |> Mc.sub(sub, shape)

    context
    |> World.put_client("token-economizer", client)
    |> Map.put(:watched, {sub, nil})
  end

  # Whether the topic's recent actions hold a redirect whose delivery came back `delivered`.
  defp logged?(status, delivered),
    do: Enum.any?(List.wrap(status["recent"]), &(&1["delivered"] == delivered))

  # Waits for the topic's value to satisfy `fun`; a topic not published yet has none.
  defp await_topic(context, fun) do
    {sub, last} = context.watched
    fun = &(is_map(&1) and fun.(&1))

    if found = last && fun.(last) do
      {found, context}
    else
      {frame, client} =
        Mc.await(
          World.client(context, "token-economizer"),
          &(&1["t"] == "plugin" and &1["id"] == sub and !!fun.(&1["value"])),
          15_000
        )

      context =
        context
        |> World.put_client("token-economizer", client)
        |> Map.put(:watched, {sub, frame["value"]})

      {fun.(frame["value"]), context}
    end
  end
end
