defmodule HalC2.Steps.Plugins.TokenEconomizerMicroSkills do
  @moduledoc """
  Steps for `features/plugins/token-economizer-micro-skills.feature`, on the
  real package in the repository's `plugins/token-economizer`, copied into the
  MC's plugins directory as a user would install it.

  Threads run on the fake Claude, whose "repair the test command" turn finds
  the bare `pytest` missing and runs the tests through `python -m pytest`,
  and whose "run the tests the working way" turn runs only the latter.
  What was learned is read through the plugin's own `microSkills` call; the
  steps wait for a turn to be folded on the `loopGuard` topic, published in
  the same close that folds it, before the plugin answers anything else.

  The model the micro-skills ask for facts is the fake text CLI: its answer
  for the `payload` asked for is "claude payload", not the facts' JSON, unless
  a step sets `FAKE_TEXT_ANSWER`. A proposal's answer is waited for on the same
  topic, published once the plugin has read it.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Plugins.Host
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

    # Off until turned on: these scenarios are about them on, say so.
    context = save(context, %{"microSkills" => "envfacts"})
    context |> Map.put(:folded, 0) |> watch()
  end

  step "micro-skills are off", context do
    save(context, %{"microSkills" => "off"})
  end

  step "micro-skills are on", context do
    save(context, %{"microSkills" => "envfacts"})
  end

  # A turn the plugin is told it half heard: its start, then its end marked
  # with what the feed dropped in between. Sent through the plugin as the
  # feed would, against a run the thread really ran (learned whole from
  # history) or one it never did (nothing to learn).
  step "the plugin is told it partly missed the thread {string}'s last turn",
       %{args: [title]} = context do
    run = context |> World.runs(title) |> List.last()
    replay_missed(context, title, run["id"])
  end

  step "the plugin is told it partly missed a turn the thread {string} never ran",
       %{args: [title]} = context do
    replay_missed(context, title, "run-never-ran")
  end

  # The feed carried the turn's start and a first look around, then lost its test runs
  # with its end: only a sweep can close it.
  step "the plugin heard the thread {string}'s last turn start and look around, then nothing more",
       %{args: [title]} = context do
    plugin = Module.concat(HalC2Plugins, TokenEconomizer)
    thread_id = World.thread_id(context, title)
    run_id = context |> World.runs(title) |> List.last() |> Map.fetch!("id")
    at = %{"threadId" => thread_id, "runId" => run_id}

    :ok =
      plugin.observe(
        Map.merge(at, %{
          "type" => "turn.started",
          "projectId" => project_id(context),
          "instanceId" => @instance
        }),
        %{}
      )

    :ok =
      plugin.observe(
        Map.merge(at, %{
          "type" => "turn.item",
          "itemType" => "command_execution",
          "status" => "completed",
          "input" => "ls",
          "output" => "tests"
        }),
        %{}
      )

    context
  end

  # The sweep the plugin's timer runs, twice so a run found ended on both is dropped;
  # `:sys.get_state/1` returns once both are handled.
  step "the plugin sweeps twice for turns whose run has ended", context do
    pid = Process.whereis(Module.concat(HalC2Plugins, TokenEconomizer))
    send(pid, :sweep)
    send(pid, :sweep)
    assert :sys.get_state(pid).turns == %{}
    context
  end

  defp replay_missed(context, title, run_id) do
    plugin = Module.concat(HalC2Plugins, TokenEconomizer)
    thread_id = World.thread_id(context, title)

    :ok =
      plugin.observe(
        %{
          "type" => "turn.started",
          "threadId" => thread_id,
          "runId" => run_id,
          "projectId" => project_id(context),
          "instanceId" => @instance
        },
        %{}
      )

    :ok =
      plugin.observe(
        %{
          "type" => "turn.finished",
          "threadId" => thread_id,
          "runId" => run_id,
          "status" => "completed",
          "dropped" => 2,
          "waiting" => 0
        },
        %{}
      )

    context
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
    expected = context.folded + 1
    {_, context} = await_turns(context, expected)
    Map.put(context, :folded, expected)
  end

  step "Claude runs the tests the working way in the thread {string}",
       %{args: [title]} = context do
    expected = context.folded + 1
    context = World.post_message(context, title, "run the tests the working way")
    {_, context} = await_turns(context, expected)
    Map.put(context, :folded, expected)
  end

  # What the fact had fired before, then the MC starts again with the plugin
  # enabled: its turn count, which the steps wait on, starts again from none.
  step "the MC restarts with TokenEconomizer running", context do
    {view, context} = micro_skills(context)
    fired = skill_about(view, "pytest")["evidence"]["fired"]

    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    assert %{"status" => "running"} = Fixtures.entry(@id)

    context
    |> Map.merge(%{fired_before: fired, folded: 0})
    |> watch()
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

  # A turn that ran only the working form fires the fact only when its
  # conversation was given it.
  step "the fact about {string} counts that turn as having been given it",
       %{args: [tool]} = context do
    {view, context} = micro_skills(context)
    assert skill_about(view, tool)["evidence"]["fired"] == context.fired_before + 1
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

  # --- the history import (features/plugins/token-economizer-history-import.feature) ---------------

  step "the loop guard is off", context do
    save(context, %{"loopGuard" => "off"})
  end

  step "the loop guard only watches", context do
    save(context, %{"loopGuard" => "watch"})
  end

  # The plugin hears none of these turns, so its turn count, which the other
  # steps wait on, does not move: the runs are waited on instead.
  step "Claude ran {int} turns repairing the test command in the thread {string}, with nothing listening",
       %{args: [turns, title]} = context do
    context =
      Enum.reduce(1..turns, context, fn turn, context ->
        context =
          if turn == 1,
            do: World.launch_on(context, title, @instance, "repair the test command"),
            else: World.post_message(context, title, "repair the test command")

        World.await_runs(context, title, List.duplicate("completed", turn), 15_000)
        context
      end)

    context
  end

  # The threads so far are in the shell the import lists them from, and the
  # project's topic is watched from here on: the receipt the import's end is
  # reached by (`await_history/2`).
  step "the history import is on", context do
    for {title, _} <- context[:threads] || %{},
        do: :ok = HalC2.Streams.flush_shell(World.thread_id(context, title))

    context |> save(%{"historyImport" => true}) |> watch_history()
  end

  # Watches the project's topic: the receipt the import's states are reached
  # by (`await_history/2`).
  defp watch_history(context) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "microSkills:#{project_id(context)}"
    }

    client = context |> World.client("token-economizer-history") |> Mc.sub(sub, shape)

    context
    |> World.put_client("token-economizer-history", client)
    |> Map.put(:history_watched, sub)
  end

  # The fold as the plugin saves it mid-import, nothing learned yet: planned
  # and part way through a thread.
  step "TokenEconomizer's history import on the project was under way when the MC stopped",
       context do
    Map.put(context, :saved_fold, %{
      "state" => "running",
      "id" => "under-way",
      "startedAt" => "2026-01-01T00:00:00Z",
      "plan" => ["thread-read-before"],
      "next" => 0,
      "after" => "run-read-before",
      "step" => 2,
      "turns" => 0,
      "skipped" => %{},
      "pending" => [],
      "envelopes" => %{}
    })
  end

  # The setting is off and the project's micro-skills file holds the fold
  # under way as the MC starts again, so the plugin never hears it turned off.
  step "the history import was turned off before the MC started again", context do
    context = save(context, %{"historyImport" => false})

    key =
      :crypto.hash(:sha256, project_id(context))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    path = Path.join([Host.data_dir(@id), "micro-skills", key <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    saved = %{"projectId" => project_id(context), "history" => context.saved_fold}
    File.write!(path, JSON.encode!(saved))

    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    assert %{"status" => "running"} = Fixtures.entry(@id)
    context |> Map.put(:folded, 0) |> watch() |> watch_history()
  end

  step "TokenEconomizer's history import stopped, the import having been turned off, the project having learned from {int} turns",
       %{args: [turns]} = context do
    {entry, context} = await_history(context, "stopped")
    assert entry["history"]["reason"] =~ "turned off"
    assert entry["history"]["pending"] == 0
    {view, context} = micro_skills(context)
    assert view["history"]["state"] == "stopped"
    assert view["turns"] == turns
    context
  end

  step "TokenEconomizer's history import is done, the project having learned from {int} turns",
       %{args: [turns]} = context do
    {_entry, context} = await_history(context, "done")
    {view, context} = micro_skills(context)
    assert view["history"]["state"] == "done"
    assert view["turns"] == turns
    assert view["history"]["pending"] == 0
    context
  end

  step "the import left the loop guard's envelope as it was, having learned already", context do
    {view, context} = micro_skills(context)
    assert [%{"left" => reason}] = Map.values(view["history"]["envelopes"])
    assert reason =~ "already learned"
    context
  end

  step "the import seeded the loop guard's envelope with {int} turns",
       %{args: [turns]} = context do
    {view, context} = micro_skills(context)
    assert Map.values(view["history"]["envelopes"]) == [%{"seeded" => turns}]
    context
  end

  step "TokenEconomizer skipped the history import, the project having learned already",
       context do
    {view, context} = micro_skills(context)
    assert view["history"]["state"] == "skipped"
    assert view["history"]["reason"] =~ "already learned"
    context
  end

  # With the import on, forgetting starts it again at once: its first
  # publication says so, past what the topic carried before.
  step "the person forgets what TokenEconomizer learned on the project", context do
    {view, context} =
      World.call!(context, "plugins.call", %{
        "id" => @id,
        "method" => "microSkills.forget",
        "input" => %{"projectId" => project_id(context)}
      })

    [project] = view["projects"]
    assert project["skills"] == []

    if context[:history_watched] do
      assert project["history"]["state"] == "running"
      {_entry, context} = await_history(context, "running")
      context
    else
      context
    end
  end

  step "TokenEconomizer has not imported into the project", context do
    {view, context} = micro_skills(context)
    assert view["history"] == %{"state" => "none"}
    context
  end

  step "the person cannot forget what TokenEconomizer learned on the project, being told it is held",
       context do
    {reply, context} =
      World.call(context, "plugins.call", %{
        "id" => @id,
        "method" => "microSkills.forget",
        "input" => %{"projectId" => project_id(context)}
      })

    assert {:error, message, _} = reply
    assert message =~ "held"
    assert message =~ "not valid JSON"
    context
  end

  step "TokenEconomizer has learned nothing on the project and imported nothing", context do
    {view, context} = micro_skills(context)
    assert view["skills"] == []
    assert view["turns"] == 0
    assert view["history"] == %{"state" => "none"}
    context
  end

  step "the person sets {string} to 0", %{args: [key]} = context do
    {reply, context} =
      World.call(context, "plugins.saveSettings", %{"id" => @id, "settings" => %{key => 0}})

    Map.put(context, :reply, reply)
  end

  # --- the model's proposals ---------------------------------------------------------------------------

  step "micro-skills ask the model for facts every {int} turns", %{args: [every]} = context do
    save(context, %{"microSkills" => "on", "microSkillsProposeEvery" => every})
  end

  # The model's next answers: one fact, its check held to a thread's latest
  # turns, as the fake text CLI hands back for the `payload` it is asked for.
  # Read when the call starts, so set before the turn that makes it due.
  step "the model will propose that the tests run as a module, citing the thread {string}'s last {int} turns",
       %{args: [title, n]} = context do
    cite = context |> World.runs(title) |> Enum.take(-n) |> Enum.map(& &1["id"])

    fact = %{
      "id" => "tests-as-module",
      "claim" => "the bare pytest is missing here; python -m pytest runs the tests",
      "injection" =>
        "Run the tests here with `python -m pytest`; the bare `pytest` is not installed.",
      "detector" => %{"scope" => "pytest", "confirm" => "python -m pytest"},
      "cite" => cite
    }

    payload = JSON.encode!(%{"facts" => [fact], "extractors" => []})
    World.put_env("FAKE_TEXT_ANSWER", JSON.encode!(%{"payload" => payload}))
    context
  end

  step "asking the model fails", context do
    World.put_env("FAKE_TEXT_FAIL", "the model is unavailable")
    context
  end

  # The receipt of a proposal's answer: the plugin publishes its status once
  # it has read one, kept or not.
  step "the model has answered {int} times", %{args: [n]} = context do
    {_, context} = await_status(context, "proposerReplies", n)
    context
  end

  # Counted when asked, in the same fold that makes a proposal due, so the
  # plugin's `status` after a folded turn has every ask; each is answered
  # before the scenario counts the model's calls.
  step "the model was asked for facts {int} times", %{args: [n]} = context do
    {status, context} = World.call!(context, "plugins.call", %{"id" => @id, "method" => "status"})
    assert status["proposerCalls"] == n

    asked =
      Enum.count(
        World.text_calls(context),
        &(&1["prompt"] =~ "DURABLE, REPO-SPECIFIC operating manual")
      )

    assert asked == n
    context
  end

  step "TokenEconomizer lists the proposed fact {string} with its check",
       %{args: [id]} = context do
    {view, context} = micro_skills(context)
    skill = Enum.find(view["skills"], &(&1["id"] == id)) || flunk("no #{id} in #{inspect(view)}")
    assert skill["source"] == "proposer"
    assert skill["detector"] == %{"scope" => "pytest", "confirm" => "python -m pytest"}
    assert skill["rev"] == 1
    # Its check ran over the turns already heard; a proposed fact drifts, so
    # its confirms count only newly edited files and the repairs all edit one.
    assert skill["evidence"]["exercised"] >= 2
    assert skill["claim"] =~ "python -m pytest"

    # Learned beside, not instead of, what the turns taught on their own.
    assert %{"source" => "envfacts"} = skill_about(view, "form_repair")
    context
  end

  step "TokenEconomizer has kept no fact from the model", context do
    {view, context} = micro_skills(context)
    assert Enum.filter(view["skills"], &(&1["source"] == "proposer")) == []
    context
  end

  step "the person drops the fact {string}", %{args: [id]} = context do
    {_reply, context} =
      World.call!(context, "plugins.call", %{
        "id" => @id,
        "method" => "microSkills.drop",
        "input" => %{"projectId" => project_id(context), "id" => id}
      })

    context
  end

  step "the person restores the fact {string}", %{args: [id]} = context do
    {_reply, context} =
      World.call!(context, "plugins.call", %{
        "id" => @id,
        "method" => "microSkills.restore",
        "input" => %{"projectId" => project_id(context), "id" => id}
      })

    context
  end

  step "TokenEconomizer lists {string} as dropped, with no fact kept from the model",
       %{args: [id]} = context do
    {view, context} = micro_skills(context)
    assert id in view["dropped"]
    assert Enum.filter(view["skills"], &(&1["source"] == "proposer")) == []
    context
  end

  # --- a file that does not read -----------------------------------------------------------------------

  @garbled "{\"facts\": not json"

  step "the project's saved micro-skills are not valid JSON", context do
    path = Module.concat(HalC2Plugins, TokenEconomizer).micro_skills_path(project_id(context))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @garbled)
    Map.put(context, :skills_file, path)
  end

  step "TokenEconomizer holds the project's micro-skills, saying its file is not valid JSON and naming it",
       context do
    {view, context} = micro_skills(context)
    assert view["held"] =~ "not valid JSON"

    assert view["file"] ==
             Module.concat(HalC2Plugins, TokenEconomizer).micro_skills_path(project_id(context))

    assert view["skills"] == []
    assert view["turns"] == 0
    context
  end

  step "the project's saved micro-skills are as they were", context do
    assert File.read!(context.skills_file) == @garbled
    context
  end

  step "the person cannot drop a fact on the project, being told it is held", context do
    {reply, context} =
      World.call(context, "plugins.call", %{
        "id" => @id,
        "method" => "microSkills.drop",
        "input" => %{"projectId" => project_id(context), "id" => @fact_id}
      })

    assert {:error, message, _} = reply
    assert message =~ "held"
    assert message =~ "not valid JSON"
    context
  end

  step "the person sets the turns between the model's proposals to 0", context do
    {reply, context} =
      World.call(context, "plugins.saveSettings", %{
        "id" => @id,
        "settings" => %{"microSkillsProposeEvery" => 0}
      })

    Map.put(context, :reply, reply)
  end

  step "the settings are refused, naming {string}", %{args: [key]} = context do
    assert {:error, message, _} = context.reply
    assert message =~ key
    context
  end

  step "the settings are refused, naming the turns between proposals", context do
    assert {:error, message, _} = context.reply
    assert message =~ "microSkillsProposeEvery"
    context
  end

  # --- helpers -------------------------------------------------------------------------------------------

  # The next publication of the project's entry whose import is in `state`.
  defp await_history(context, state) do
    sub = context.history_watched

    {frame, client} =
      Mc.await(
        World.client(context, "token-economizer-history"),
        &(&1["t"] == "plugin" and &1["id"] == sub and
            get_in(&1, ["value", "history", "state"]) == state),
        15_000
      )

    {frame["value"], World.put_client(context, "token-economizer-history", client)}
  end

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

    {_, context} = await_turns(context, expected)
    Map.put(context, :folded, expected)
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

  # Watches the plugin's `loopGuard` topic, published as each turn the
  # plugin heard closes: the receipt a folded turn's fold is reached by, the
  # micro-skills folding in the same close before the plugin answers anything
  # else. (`await_turns/2`.)
  defp watch(context) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "loopGuard"
    }

    client = context |> World.client("token-economizer-skills") |> Mc.sub(sub, shape)

    context
    |> World.put_client("token-economizer-skills", client)
    |> Map.put(:skills_watched, {sub, nil})
  end

  defp await_turns(context, expected), do: await_status(context, "turns", expected)

  defp await_status(context, key, expected) do
    {sub, last} = context.skills_watched

    if is_map(last) && last[key] >= expected do
      {last, context}
    else
      {frame, client} =
        Mc.await(
          World.client(context, "token-economizer-skills"),
          &(&1["t"] == "plugin" and &1["id"] == sub and is_map(&1["value"]) and
              &1["value"][key] >= expected),
          15_000
        )

      context =
        context
        |> World.put_client("token-economizer-skills", client)
        |> Map.put(:skills_watched, {sub, frame["value"]})

      {frame["value"], context}
    end
  end
end
