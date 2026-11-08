defmodule HalC2.Steps.Plugins.TokenEconomizerMicroSkills do
  @moduledoc """
  Steps for `features/plugins/token-economizer-micro-skills.feature`, on the
  real package in the repository's `plugins/token-economizer`, copied into the
  MC's plugins directory as a user would install it.

  Threads run on the fake Claude, whose "repair the test command" turn finds
  the bare `pytest` missing and runs the tests through `python -m pytest`.
  What was learned is read through the plugin's own `microSkills` call, and
  the steps wait on its `microSkills` topic, which is published as each turn
  is folded.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @id "token-economizer"
  @package Path.expand("../../../../../plugins/token-economizer", __DIR__)
  @instance "claudeAgent"
  @fact_id "form_repair:run_tests:pytest"

  # --- background ------------------------------------------------------------------------

  step "an MC running the TokenEconomizer plugin with micro-skills", context do
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
    context |> Map.put(:folded, 0) |> watch()
  end

  step "micro-skills are off", context do
    context |> save(%{"microSkills" => "off"}) |> Map.put(:skills_off, true)
  end

  # --- turns --------------------------------------------------------------------------------

  step "Claude repairs the test command in {int} turns in the thread {string}",
       %{args: [turns, title]} = context do
    repair(context, title, turns)
  end

  step "Claude has repaired the test command in {int} turns in the thread {string}",
       %{args: [turns, title]} = context do
    repair(context, title, turns)
  end

  step "Claude starts the thread {string} with {string}", %{args: [title, text]} = context do
    context = World.launch_on(context, title, @instance, text)
    World.await_runs(context, title, ["completed"])
    context = Map.put(context, :started_with, text)

    # This turn folds too, once it ends: stay in step with the count the
    # repair steps wait on.
    if context[:skills_off] do
      context
    else
      expected = context.folded + 1
      {_, context} = await_skills(context, &(&1["turns"] >= expected))
      Map.put(context, :folded, expected)
    end
  end

  # --- what was learned, dropped and staged ------------------------------------------------------

  step "TokenEconomizer has learned the fact about {string}, active and staged",
       %{args: [tool]} = context do
    {view, context} = micro_skills(context)
    skill = skill_about(view, tool)
    assert skill["state"] == "ACTIVE"
    assert skill["staged"] == true
    assert skill["evidence"]["confirms"] >= 3
    assert view["staged"] =~ skill["claim"]
    context
  end

  step "TokenEconomizer still counts the fact about {string} as forming",
       %{args: [tool]} = context do
    {view, context} = micro_skills(context)
    skill = skill_about(view, tool)
    assert skill["state"] == "CANDIDATE"
    assert skill["staged"] == false
    context
  end

  step "TokenEconomizer has learned nothing on the project", context do
    {view, context} = micro_skills(context)
    assert view["skills"] == []
    context
  end

  step "the person drops the fact about {string}", %{args: [tool]} = context do
    {view, context} = micro_skills(context)
    id = skill_about(view, tool)["id"]

    {_reply, context} =
      World.call!(context, "plugins.call", %{
        "id" => @id,
        "method" => "microSkills.drop",
        "input" => %{"projectId" => project_id(context), "id" => id}
      })

    Map.put(context, :dropped_id, id)
  end

  step "the person restores the fact about {string}", %{args: [_tool]} = context do
    {_reply, context} =
      World.call!(context, "plugins.call", %{
        "id" => @id,
        "method" => "microSkills.restore",
        "input" => %{"projectId" => project_id(context), "id" => context.dropped_id}
      })

    context
  end

  step "TokenEconomizer lists the fact about {string} as dropped, with no fact learned",
       %{args: [_tool]} = context do
    {view, context} = micro_skills(context)
    assert view["skills"] == []
    assert view["dropped"] == [@fact_id]
    context
  end

  step "Claude gets the fact about {string} ahead of {string}",
       %{args: [tool, text]} = context do
    prompt = context |> prompts() |> List.last()
    {ahead, _} = :binary.match(prompt, "# environment facts")
    {at, _} = :binary.match(prompt, text)
    assert prompt =~ tool
    assert ahead < at
    context
  end

  step "nothing before that thread was told the fact", context do
    for prompt <- context |> prompts() |> Enum.drop(-1) do
      refute prompt =~ "# environment facts"
    end

    context
  end

  step "Claude is not told anything about {string}", %{args: [_tool]} = context do
    prompt = context |> prompts() |> List.last()
    refute prompt =~ "# environment facts"
    context
  end

  # --- settings -------------------------------------------------------------------------------------

  step "the person sets the micro-skills' most facts to 1.5", context do
    {reply, context} =
      World.call(context, "plugins.saveSettings", %{
        "id" => @id,
        "settings" => %{"microSkillsMaxFacts" => 1.5}
      })

    Map.put(context, :reply, reply)
  end

  step "the settings are refused, naming the most facts", context do
    assert {:error, message, _} = context.reply
    assert message =~ "microSkillsMaxFacts"
    context
  end

  # --- helpers -------------------------------------------------------------------------------------------

  defp repair(context, title, turns) do
    expected = context.folded + turns

    context =
      Enum.reduce(1..turns, context, fn turn, context ->
        if turn == 1 and is_nil(context[:threads][title]) do
          World.launch_on(context, title, @instance, "repair the test command")
        else
          World.post_message(context, title, "repair the test command")
        end
      end)

    if context[:skills_off] do
      # Nothing folds, so the topic never says the turns ended: the runs do.
      World.await_runs(context, title, List.duplicate("completed", turns))
      context
    else
      {_, context} = await_skills(context, &(&1["turns"] >= expected))
      Map.put(context, :folded, expected)
    end
  end

  defp project_id(context), do: World.project(context).id

  defp micro_skills(context) do
    {view, context} =
      World.call!(context, "plugins.call", %{
        "id" => @id,
        "method" => "microSkills",
        "input" => %{"projectId" => project_id(context)}
      })

    [project] = view["projects"]
    {project, context}
  end

  defp skill_about(view, tool) do
    Enum.find(view["skills"], &String.contains?(&1["id"], tool)) ||
      flunk("no micro-skill about #{tool} in #{inspect(view)}")
  end

  defp save(context, patch) do
    {_, context} =
      World.call!(context, "plugins.saveSettings", %{"id" => @id, "settings" => patch})

    context
  end

  defp prompts(context) do
    for %{"in" => %{"type" => "user", "message" => message}} <-
          World.provider_log(context, "claude"),
        do: text(message["content"])
  end

  defp text(content) when is_binary(content), do: content

  defp text(content) when is_list(content),
    do: content |> Enum.map(&(&1["text"] || "")) |> Enum.join("\n")

  defp text(_content), do: ""

  # Watches the plugin's `microSkills` topic; `await_skills/2` waits on the
  # project's entry in it.
  defp watch(context) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "microSkills"
    }

    client = context |> World.client("token-economizer-skills") |> Mc.sub(sub, shape)

    context
    |> World.put_client("token-economizer-skills", client)
    |> Map.put(:skills_watched, {sub, nil})
  end

  defp await_skills(context, fun) do
    {sub, last} = context.skills_watched
    project = fn value -> project_view(value, project_id(context)) end
    found = last && project.(last)

    if found && fun.(found) do
      {found, context}
    else
      {frame, client} =
        Mc.await(
          World.client(context, "token-economizer-skills"),
          fn frame ->
            frame["t"] == "plugin" and frame["id"] == sub and
              !!(project_view(frame["value"], project_id(context)) &&
                   fun.(project_view(frame["value"], project_id(context))))
          end,
          15_000
        )

      context =
        context
        |> World.put_client("token-economizer-skills", client)
        |> Map.put(:skills_watched, {sub, frame["value"]})

      {project.(frame["value"]), context}
    end
  end

  defp project_view(%{"projects" => projects}, project_id),
    do: Enum.find(projects, &(&1["projectId"] == project_id))

  defp project_view(_value, _project_id), do: nil
end
