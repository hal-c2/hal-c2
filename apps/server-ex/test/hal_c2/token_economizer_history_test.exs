# SPDX-License-Identifier: Apache-2.0

for file <-
      ~w(loop_guard_state loop_guard_rules loop_guard_shell_edits loop_guard_turn loop_guard_envelope loop_guard_judge tool_prune_evidence token_economizer),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerHistoryTest do
  @moduledoc """
  Tool pruning reading a thread's turns back from the MC (`HalC2.Plugins.Host.history/3`):
  the plugin process's state driven event by event, against a thread stream written
  here. Not async: the plugin's grant is in the MC's settings.
  """
  use ExUnit.Case, async: false

  alias HalC2.Orchestration.NativeSubagent
  alias HalC2Plugins.TokenEconomizer
  alias HalC2Plugins.TokenEconomizer.ToolPrune.Evidence, as: Prune

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    File.write!(Path.join(dir, "config.json"), "{}")
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    on_exit(fn -> Application.delete_env(:hal_c2, :settings_check_ms) end)

    start_supervised!(HalC2.Settings)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)

    {settings, version} = HalC2.Settings.get()

    plugins = %{
      "token-economizer" => %{
        "enabled" => true,
        "granted" => ["turns:observe"],
        "settings" => %{}
      }
    }

    {:ok, _} = HalC2.Settings.put(Map.put(settings, "plugins", plugins), version)

    thread = "th-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"thread", thread, %{"s" => %{}}},
        {"provider-thread", "pt", %{"s" => %{"driver" => "claudeAgent"}}}
      ])

    %{thread: thread, project: "p-#{System.unique_integer([:positive])}"}
  end

  test "a segment the feed dropped some of reads its runs back, and what they used counts",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    assert state.seeded[{thread, project}] == :read
    state = observe(state, finished(thread, "r1", 1))

    # Run r2 used CronCreate; the feed dropped all of it.
    ended(thread, "r2", 2, [%{"type" => "dynamic_tool_call", "providerToolName" => "CronCreate"}])

    state =
      observe(
        state,
        started(thread, "r3", p, %{"newConversation" => true, "dropped" => 3, "waiting" => 0})
      )

    prune = state.prunes[project]
    assert "CronCreate" in prune["used"]
    assert prune["prompts"] == 2
    assert Prune.seeded_run(prune, thread) == %{"run" => "r2", "ordinal" => 2}
  end

  test "a use the feed dropped from a segment still open is read back before the next conversation is shaped, and its runs count once",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    # Turned off for the next conversation, and then used in this one: the feed dropped
    # the use, and says so as the turn ends.
    state = apply_tools(state, p, ["CronCreate"])
    state = observe(state, started(thread, "r2", p, %{}))
    ended(thread, "r2", 2, [%{"type" => "dynamic_tool_call", "providerToolName" => "CronCreate"}])

    state =
      observe(state, Map.merge(finished(thread, "r2", 2), %{"dropped" => 1, "waiting" => 0}))

    {shape, state} = shape(state, thread, "r3", p)
    refute "CronCreate" in ((shape || %{})["deniedTools"] || [])
    assert "CronCreate" in state.prunes[project]["used"]

    state = observe(state, started(thread, "r3", p, %{"newConversation" => true}))
    prune = state.prunes[project]
    assert prune["prompts"] == 2
    assert Prune.seeded_run(prune, thread) == %{"run" => "r2", "ordinal" => 2}
  end

  test "a conversation shaped while a segment heard in part cannot be read back is denied nothing",
       %{thread: thread, project: p} do
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    state = apply_tools(state, p, ["CronCreate"])
    assert {%{"deniedTools" => ["CronCreate"]}, state} = shape(state, "other", "o1", p)

    state = observe(state, started(thread, "r2", p, %{"dropped" => 1, "waiting" => 0}))
    state = observe(state, finished(thread, "r2", 2))
    grant([])
    assert {nil, state} = shape(state, "other", "o1", p)
    assert state.shaped[{"other", {p, "claudeAgent"}}] == Prune.candidate_tools("tool")

    # Read back, it is denied again what its segments did not use.
    grant(["turns:observe"])
    ended(thread, "r2", 2, [])
    assert {%{"deniedTools" => ["CronCreate"]}, _} = shape(state, "other", "o1", p)
  end

  test "a segment the feed dropped some of, whose runs cannot be read back, is no evidence and keeps the watermark",
       %{project: p} do
    project = {p, "claudeAgent"}
    {:ok, state} = TokenEconomizer.init(%{})
    # Its earlier turns were read; the thread is gone by the time it folds.
    state = put_in(state.seeded[{"gone", project}], :read)
    state = observe(state, started("gone", "r1", p, %{"newConversation" => true}))
    state = observe(state, finished("gone", "r1", 1))

    state =
      observe(
        state,
        started("gone", "r2", p, %{"newConversation" => true, "dropped" => 1, "waiting" => 0})
      )

    prune = state.prunes[project]
    assert prune["sessions"] == 0 and prune["prompts"] == 0
    assert Prune.seeded_run(prune, "gone") == nil
  end

  test "a segment the feed dropped some of that folds unread is read back at the thread's next turn, though a later segment folds whole",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    {:ok, _} = HalC2.Streams.commit("other", :thread, [{"thread", "other", %{"s" => %{}}}])
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    # Run r2 used CronCreate; the feed dropped all of it, and says so on another thread.
    ended(thread, "r2", 2, [%{"type" => "dynamic_tool_call", "providerToolName" => "CronCreate"}])

    state =
      observe(
        state,
        started("other", "o1", p, %{"newConversation" => true, "dropped" => 1, "waiting" => 0})
      )

    # The segment folds while the history cannot be read.
    grant([])
    state = observe(state, started(thread, "r3", p, %{"newConversation" => true}))
    refute "CronCreate" in state.prunes[project]["used"]

    grant(["turns:observe"])
    ended(thread, "r3", 3, [])
    state = observe(state, finished(thread, "r3", 3))
    state = observe(state, started(thread, "r4", p, %{"newConversation" => true}))

    prune = state.prunes[project]
    assert "CronCreate" in prune["used"]
    # r1 and r2 read back, r3 heard: each once.
    assert prune["prompts"] == 3
    assert Prune.seeded_run(prune, thread) == %{"run" => "r3", "ordinal" => 3}
  end

  test "a segment the feed dropped some of that a quiet project folds unread is read back at the thread's next turn",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPruneQuietMinutes" => 0})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    ended(thread, "r2", 2, [%{"type" => "dynamic_tool_call", "providerToolName" => "CronCreate"}])
    # r1's end tells of r2, which the feed dropped all of.
    state =
      observe(state, Map.merge(finished(thread, "r1", 1), %{"dropped" => 1, "waiting" => 0}))

    grant([])
    {:noreply, state} = TokenEconomizer.handle_info({:toolprune_tick, project}, state)
    refute "CronCreate" in state.prunes[project]["used"]

    grant(["turns:observe"])
    state = observe(state, started(thread, "r3", p, %{}))
    assert "CronCreate" in state.prunes[project]["used"]
  end

  test "a segment the feed dropped some of that a quiet project folds while its turn still runs is read back once the turn has ended",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    {:ok, state} = TokenEconomizer.init(%{"toolPruneQuietMinutes" => 0})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))

    # r1 uses CronCreate, which the feed drops, and says so on another thread's turn.
    state =
      observe(
        state,
        started("other", "o1", p, %{"newConversation" => true, "dropped" => 1, "waiting" => 0})
      )

    state = observe(state, finished("other", "o1", 1))

    # The project goes quiet while r1 runs on, which its history does not have yet.
    {:noreply, state} = TokenEconomizer.handle_info({:toolprune_tick, project}, state)
    ended(thread, "r1", 1, [%{"type" => "dynamic_tool_call", "providerToolName" => "CronCreate"}])
    state = observe(state, finished(thread, "r1", 1))
    state = observe(state, started(thread, "r2", p, %{"newConversation" => true}))

    assert "CronCreate" in state.prunes[project]["used"]
  end

  test "a run the feed tells of after it ended, as a segment heard in part folds, counts once",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    # r1's end tells of r2, which the feed dropped all of.
    ended(thread, "r2", 2, [])

    state =
      observe(state, Map.merge(finished(thread, "r1", 1), %{"dropped" => 1, "waiting" => 0}))

    # r3 has ended by the time the feed tells of its start.
    ended(thread, "r3", 3, [])
    state = observe(state, started(thread, "r3", p, %{"newConversation" => true}))
    assert Prune.seeded_run(state.prunes[project], thread) == %{"run" => "r2", "ordinal" => 2}
    state = observe(state, finished(thread, "r3", 3))
    state = observe(state, started(thread, "r4", p, %{"newConversation" => true}))

    prune = state.prunes[project]
    assert prune["prompts"] == 3 and prune["sessions"] == 2
    assert Prune.seeded_run(prune, thread) == %{"run" => "r3", "ordinal" => 3}
  end

  test "a run a quiet project read back before the feed told of it counts once",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPruneQuietMinutes" => 0})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))

    state =
      observe(state, Map.merge(finished(thread, "r1", 1), %{"dropped" => 1, "waiting" => 0}))

    # r2 ran and ended; the feed has yet to tell of it as the project goes quiet.
    ended(thread, "r2", 2, [])
    {:noreply, state} = TokenEconomizer.handle_info({:toolprune_tick, project}, state)
    assert state.prunes[project]["prompts"] == 2

    state = observe(state, started(thread, "r2", p, %{}))
    state = observe(state, finished(thread, "r2", 2))
    {:noreply, state} = TokenEconomizer.handle_info({:toolprune_tick, project}, state)

    prune = state.prunes[project]
    assert prune["prompts"] == 2
    assert Prune.seeded_run(prune, thread) == %{"run" => "r2", "ordinal" => 2}
  end

  test "runs folded while the thread's history could not be read count once after a restart",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    grant([])
    {:ok, state} = TokenEconomizer.init(%{})
    ended(thread, "r1", 1, [])
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    state = observe(state, started(thread, "r2", p, %{"newConversation" => true}))
    assert state.prunes[project]["prompts"] == 1
    ended(thread, "r2", 2, [])
    _ = observe(state, finished(thread, "r2", 2))

    # The plugin starts again before r2's segment folds, and can read the history now.
    grant(["turns:observe"])
    {:ok, state} = TokenEconomizer.init(%{})
    state = observe(state, started(thread, "r3", p, %{"newConversation" => true}))

    prune = state.prunes[project]
    # r1 heard, r2 read back: each once.
    assert prune["prompts"] == 2
    assert Prune.seeded_run(prune, thread) == %{"run" => "r2", "ordinal" => 2}
    assert prune["foldedRuns"] == %{}
  end

  test "a segment the feed dropped some of, in which a subagent worked, is no evidence any tool went unused",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    ended(thread, "r1", 1, [])

    {:ok, state} =
      TokenEconomizer.init(%{
        "toolPrune" => "propose",
        "toolPruneEvidence" => 1,
        "toolPruneMinSessions" => 1
      })

    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))

    # Run r2's subagent used CronCreate, which its child thread keeps; the feed dropped it.
    ended(thread, "r2", 2, [
      %{"type" => "subagent", "origin" => "provider_native", "title" => "Schedule it"}
    ])

    state =
      observe(
        state,
        started(thread, "r3", p, %{"newConversation" => true, "dropped" => 3, "waiting" => 0})
      )

    prune = state.prunes[project]
    assert prune["prompts"] == 2
    refute "CronCreate" in prune["used"]
    # No tool's streak grew, so nothing is proposed, nor applied with the proposal.
    assert Enum.all?(Map.values(prune["streaks"]), &(&1["prompts"] == 0))
    assert Prune.proposal(prune, Prune.config(state.settings)) == []
  end

  test "a segment the feed dropped some of, in which the agent only delegated, is still evidence",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    ended(thread, "r1", 1, [])

    {:ok, state} =
      TokenEconomizer.init(%{
        "toolPrune" => "propose",
        "toolPruneEvidence" => 1,
        "toolPruneMinSessions" => 1
      })

    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))

    # Run r2 handed work to a thread of its own, whose calls are that thread's turns',
    # not this one's.
    ended(thread, "r2", 2, [
      %{"type" => "subagent", "origin" => "app_owned", "title" => "Review it"}
    ])

    assert {:ok, runs} = HalC2.Plugins.Host.history("token-economizer", thread)
    assert Enum.map(runs, & &1["subagents"]) == [false, false]

    state =
      observe(
        state,
        started(thread, "r3", p, %{"newConversation" => true, "dropped" => 3, "waiting" => 0})
      )

    prune = state.prunes[project]
    assert prune["prompts"] == 2
    assert Enum.any?(Map.values(prune["streaks"]), &(&1["prompts"] > 0))
  end

  test "Codex turns the plugin missed are no evidence any of its packages went unused",
       %{project: p} do
    project = {p, "codex"}
    thread = "codex-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"thread", thread, %{"s" => %{}}},
        {"provider-thread", "pt", %{"s" => %{"driver" => "codex"}}}
      ])

    # While the plugin was not running, Codex viewed an image in r1 and waited on an
    # agent it had already spawned: no item shows either, and no subagent worked then.
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{})
    state = observe(state, started(thread, "r2", p, %{"provider" => "codex"}))

    prune = state.prunes[project]
    assert prune["prompts"] == 1

    for package <- ~w(collaboration goals image_media) do
      assert prune["streaks"][package] in [nil, %{"sessions" => 0, "prompts" => 0}]
      assert prune["loadedSessions"][package] in [nil, 0]
    end
  end

  test "a Codex segment the feed dropped a wait on its agents from is no evidence collaboration went unused",
       %{project: p} do
    project = {p, "codex"}
    thread = "codex-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"thread", thread, %{"s" => %{}}},
        {"provider-thread", "pt", %{"s" => %{"driver" => "codex"}}}
      ])

    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{})
    started = &started(thread, &1, p, Map.put(&2, "provider", "codex"))
    state = observe(state, started.("r1", %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))

    # In r2 Codex waited on an agent it spawned earlier; the feed dropped the wait,
    # which the history does not keep.
    ended(thread, "r2", 2, [])
    state = observe(state, started.("r2", %{"dropped" => 1, "waiting" => 0}))
    state = observe(state, finished(thread, "r2", 2))
    state = observe(state, started.("r3", %{"newConversation" => true}))

    prune = state.prunes[project]
    assert prune["prompts"] == 2
    assert prune["streaks"]["collaboration"] in [nil, %{"sessions" => 0, "prompts" => 0}]
    assert prune["loadedSessions"]["collaboration"] in [nil, 0]
  end

  test "a thread's history says which turns a subagent worked in, also one it ran on into or was resumed in",
       %{thread: thread} do
    at = &"2026-11-09T10:0#{&1}:00.000Z"
    run = &{"run", &1, %{"s" => %{"startedAt" => at.(&2), "completedAt" => at.(&3)}}}
    ended(thread, "r1", 1, [])
    ended(thread, "r2", 2, [])
    ended(thread, "r3", 3, [])
    ended(thread, "r4", 4, [])

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        run.("r1", 0, 1),
        run.("r2", 2, 3),
        run.("r3", 4, 5),
        run.("r4", 6, 7),
        # Started in r1 and ran on into r2.
        {"subagent", "s1",
         %{
           "s" => %{
             "origin" => "provider_native",
             "runId" => "r1",
             "startedAt" => at.(0),
             "completedAt" => at.(2)
           }
         }},
        # Resumed in r4, still running.
        {"subagent", "s2",
         %{
           "s" => %{
             "origin" => "provider_native",
             "runId" => "r1",
             "startedAt" => at.(1),
             "completedAt" => nil
           }
         }},
        # A thread of its own the agent delegated to, whose calls are its own turns'.
        {"subagent", "s3",
         %{
           "s" => %{
             "origin" => "app_owned",
             "runId" => "r3",
             "startedAt" => at.(4),
             "completedAt" => at.(5)
           }
         }}
      ])

    assert {:ok, runs} = HalC2.Plugins.Host.history("token-economizer", thread)
    assert Enum.map(runs, & &1["subagents"]) == [true, true, true, true]

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"subagent", "s2", %{"s" => %{"completedAt" => at.(3)}}}
      ])

    assert {:ok, runs} = HalC2.Plugins.Host.history("token-economizer", thread)
    assert Enum.map(runs, & &1["subagents"]) == [true, true, false, false]
  end

  test "a Claude subagent's call heard after its thread went on in Codex protects Claude's tool",
       %{thread: thread, project: p} do
    start_supervised!({Registry, keys: :unique, name: HalC2.Plugins.Hooks})

    {:ok, _} =
      Registry.register(HalC2.Plugins.Hooks, {:observe, "listener"}, %{
        id: "listener",
        dropped: :counters.new(1, [])
      })

    {:ok, state} = TokenEconomizer.init(%{})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))

    ids = %{
      thread: thread,
      run: "r1",
      root_node: "node:root:r1",
      provider_thread: "pt",
      driver: "claudeAgent"
    }

    sub = NativeSubagent.start(ids, "agent-1", %{"prompt" => "Schedule it"})
    state = Enum.reduce(heard(), state, &observe(&2, &1))
    state = observe(state, finished(thread, "r1", 1))
    # The thread goes on in Codex while the Claude subagent works in the background.
    state = observe(state, started(thread, "r2", p, %{"provider" => "codex"}))

    NativeSubagent.item(sub, "tool-1", "dynamic_tool", "completed", %{
      "providerToolName" => "CronCreate"
    })

    state = Enum.reduce(heard(), state, &observe(&2, &1))
    assert "CronCreate" in state.prunes[{p, "claudeAgent"}]["used"]
  end

  test "a thread handed from Claude to Codex and back keeps each provider's turned-off tools and evidence its own",
       %{thread: thread, project: p} do
    {claude, codex} = {{p, "claudeAgent"}, {p, "codex"}}

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"provider-thread", "pt-codex", %{"s" => %{"driver" => "codex"}}}
      ])

    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    ended(thread, "r1", 1, [])
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    state = apply_tools(state, p, ["CronCreate"])

    # Handed to Codex, the conversation is shaped by Codex's evidence alone.
    assert {nil, state} = shape(state, thread, "r2", p, "codex")
    codex_started = started(thread, "r2", p, %{"provider" => "codex", "newConversation" => true})
    state = observe(state, codex_started)

    goal = %{
      "type" => "turn.item",
      "threadId" => thread,
      "runId" => "r2",
      "provider" => "codex",
      "itemType" => "dynamic_tool",
      "tool" => "update_goal",
      "status" => "completed"
    }

    # A Claude tool's name in a Codex turn is no use of Claude's tool.
    cron = %{goal | "itemType" => "dynamic_tool_call", "tool" => "CronCreate"}
    state = state |> observe(goal) |> observe(cron)
    ended(thread, "r2", 2, [], "pt-codex")
    state = observe(state, finished(thread, "r2", 2))
    state = apply_tools(state, p, ["image_media"], "codex")

    assert "goals" in state.prunes[codex]["used"]
    assert state.prunes[claude]["used"] == []
    assert state.prunes[claude]["off"] == ["CronCreate"]
    assert state.prunes[codex]["off"] == ["image_media"]

    # Back in Claude, each provider's conversation is denied its own tools alone, and
    # each segment counted as its provider's.
    assert {%{"deniedTools" => ["CronCreate"]}, state} = shape(state, thread, "r3", p)
    state = observe(state, started(thread, "r3", p, %{}))
    assert {%{"deniedTools" => ["image_media"]}, state} = shape(state, "other", "o1", p, "codex")
    assert state.prunes[claude]["prompts"] == 1
    assert state.prunes[codex]["prompts"] == 1

    # A Claude use gives back Claude's tool, and nothing of Codex's.
    use = %{cron | "runId" => "r3", "provider" => "claudeAgent"}
    state = observe(state, use)
    assert state.prunes[claude]["off"] == []
    assert state.prunes[codex]["off"] == ["image_media"]
  end

  # A new version of the plugin is a new process (`HalC2.Plugins` stops a plugin whose
  # source changed and starts it again): only the file crosses, written by the version
  # before, perhaps in a shape this one does not know.
  test "evidence saved by an earlier version turns off only what was turned off, and nothing on stale evidence",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    path = TokenEconomizer.toolprune_path(project)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 0,
        "off" => ["CronCreate", "Workflow", "Gone"],
        "used" => ["Workflow"],
        # What auto held, on streaks from before live evidence was counted apart.
        "pending" => %{"items" => ["CronList"], "since" => 0},
        "streaks" => %{"CronList" => %{"sessions" => 9, "prompts" => 99}},
        "seededThreads" => "not a map",
        "foldedRuns" => 7
      })
    )

    {:ok, state} =
      TokenEconomizer.init(%{"toolPrune" => "auto", "toolPruneQuietMinutes" => 0})

    assert {%{"deniedTools" => ["CronCreate"]}, state} = shape(state, thread, "r1", p)
    prune = state.prunes[project]
    assert prune["pending"] == nil
    refute "CronList" in prune["off"]
    assert {:ok, %{} = saved} = path |> File.read!() |> JSON.decode()
    assert saved["pending"] == nil
  end

  test "a thread's history says a subagent resumed later worked in neither the turns between nor after",
       %{thread: thread} do
    at = &"2026-11-09T10:0#{&1}:00.000Z"
    run = &{"run", &1, %{"s" => %{"startedAt" => at.(&2), "completedAt" => at.(&3)}}}
    for {id, n} <- [{"r1", 1}, {"r2", 2}, {"r3", 3}, {"r4", 4}], do: ended(thread, id, n, [])

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        run.("r1", 0, 1),
        run.("r2", 2, 3),
        run.("r3", 4, 5),
        run.("r4", 6, 7),
        {"thread", thread, %{"s" => %{"id" => thread}}}
      ])

    ids = %{thread: thread, run: "r1", root_node: "node:root:r1", provider_thread: "pt"}
    sub = NativeSubagent.start(ids, "agent-1", %{"prompt" => "Look"})
    NativeSubagent.finish(sub, "completed", "Done")
    # Stopped in r1, resumed in r3 and done there: r2 and r4 had no subagent at work.
    {:ok, entity} = subagent(thread)

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"subagent", entity["id"], %{"s" => %{"startedAt" => at.(0), "completedAt" => at.(1)}}}
      ])

    {:ok, entity} = subagent(thread)
    sub = NativeSubagent.resume(%{ids | run: "r3"}, entity, "Look again")
    {:ok, entity} = subagent(thread)

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"subagent", entity["id"], %{"s" => %{"resumedAt" => at.(4)}}}
      ])

    NativeSubagent.finish(sub, "completed", "Done again")
    {:ok, entity} = subagent(thread)

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"subagent", entity["id"], %{"s" => %{"completedAt" => at.(5)}}}
      ])

    assert {:ok, runs} = HalC2.Plugins.Host.history("token-economizer", thread)
    assert Enum.map(runs, & &1["subagents"]) == [true, false, true, false]
  end

  test "a subagent's call heard as the plugin restarted, before its thread's next turn, protects its tool",
       %{thread: thread, project: p} do
    start_supervised!({Registry, keys: :unique, name: HalC2.Plugins.Hooks})

    {:ok, _} =
      Registry.register(HalC2.Plugins.Hooks, {:observe, "listener"}, %{
        id: "listener",
        dropped: :counters.new(1, [])
      })

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [{"thread", thread, %{"s" => %{"projectId" => p}}}])

    ids = %{
      thread: thread,
      run: "r1",
      root_node: "node:root:r1",
      provider_thread: "pt",
      driver: "claudeAgent"
    }

    sub = NativeSubagent.start(ids, "agent-1", %{"prompt" => "Schedule it"})

    NativeSubagent.item(sub, "tool-1", "dynamic_tool", "completed", %{
      "providerToolName" => "CronCreate"
    })

    # The plugin restarted after r1 started: it hears the subagent's work, and nothing
    # of the turn, whose history keeps none of the subagent's calls.
    events = heard()
    assert events != [] and Enum.all?(events, &(&1["projectId"] == p))
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    state = Enum.reduce(events, state, &observe(&2, &1))
    assert "CronCreate" in state.prunes[{p, "claudeAgent"}]["used"]
  end

  test "a conversation shaped while a turn heard in part still runs is denied nothing, and once it has ended what it did not use",
       %{thread: thread, project: p} do
    {:ok, _} = HalC2.Streams.commit("other", :thread, [{"thread", "other", %{"s" => %{}}}])
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    state = apply_tools(state, p, ["CronCreate"])
    state = observe(state, started(thread, "r2", p, %{}))

    # r2 runs on, its history has only r1, and the feed says it dropped something.
    state =
      observe(
        state,
        started("other", "o1", p, %{"newConversation" => true, "dropped" => 1, "waiting" => 0})
      )

    ended("other", "o1", 1, [])
    state = observe(state, finished("other", "o1", 1))
    assert {nil, state} = shape(state, "third", "t1", p)

    ended(thread, "r2", 2, [])
    state = observe(state, finished(thread, "r2", 2))
    assert {%{"deniedTools" => ["CronCreate"]}, _} = shape(state, "third", "t1", p)
  end

  test "a segment heard in part that a quiet project folds unread denies nothing to another thread until it is read back, and then what it did not use",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    {:ok, _} = HalC2.Streams.commit("other", :thread, [{"thread", "other", %{"s" => %{}}}])
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose", "toolPruneQuietMinutes" => 0})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    state = apply_tools(state, p, ["CronCreate"])
    state = observe(state, started(thread, "r2", p, %{}))
    # r2 used CronCreate, which the feed dropped, and says so as r2 ends.
    ended(thread, "r2", 2, [%{"type" => "dynamic_tool_call", "providerToolName" => "CronCreate"}])

    state =
      observe(state, Map.merge(finished(thread, "r2", 2), %{"dropped" => 1, "waiting" => 0}))

    # The project goes quiet while the history cannot be read.
    grant([])
    {:noreply, state} = TokenEconomizer.handle_info({:toolprune_tick, project}, state)
    refute "CronCreate" in state.prunes[project]["used"]
    assert {nil, state} = shape(state, "other", "o1", p)

    grant(["turns:observe"])
    {shape, state} = shape(state, "other", "o1", p)
    refute "CronCreate" in ((shape || %{})["deniedTools"] || [])
    assert "CronCreate" in state.prunes[project]["used"]
    assert state.unresolved == %{}
  end

  test "a segment heard in part whose ended run was rolled back out of its history is read back without it",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    {:ok, _} = HalC2.Streams.commit("other", :thread, [{"thread", "other", %{"s" => %{}}}])
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose", "toolPruneQuietMinutes" => 0})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    state = apply_tools(state, p, ["CronCreate"])
    state = observe(state, started(thread, "r2", p, %{}))

    state =
      observe(state, Map.merge(finished(thread, "r2", 2), %{"dropped" => 1, "waiting" => 0}))

    # r2 was rolled back: its history never has it.
    {:noreply, state} = TokenEconomizer.handle_info({:toolprune_tick, project}, state)
    assert Map.has_key?(state.unresolved, {thread, project})
    assert {%{"deniedTools" => ["CronCreate"]}, state} = shape(state, "other", "o1", p)
    assert state.unresolved == %{}
  end

  test "a segment heard in part whose thread is deleted before its turn ends no longer holds the project's pruning off",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    {:ok, _} = HalC2.Streams.commit("other", :thread, [{"thread", "other", %{"s" => %{}}}])
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose", "toolPruneQuietMinutes" => 0})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    state = apply_tools(state, p, ["CronCreate"])
    state = observe(state, started(thread, "r2", p, %{}))

    # The feed drops some of r2, and the project goes quiet while r2 runs on.
    state = observe(state, started("other", "o1", p, %{"dropped" => 1, "waiting" => 0}))
    ended("other", "o1", 1, [])
    state = observe(state, finished("other", "o1", 1))
    {:noreply, state} = TokenEconomizer.handle_info({:toolprune_tick, project}, state)
    assert {nil, state} = shape(state, "other", "o2", p)
    assert [%{"unresolved" => [^thread]}] = TokenEconomizer.prune_status(state)["projects"]

    # Deleted, the thread never ends r2 here: what r2 used reaches no conversation.
    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"thread", thread, %{"s" => %{"deletedAt" => "2026-11-09T00:00:00Z"}}}
      ])

    assert {%{"deniedTools" => ["CronCreate"]}, state} = shape(state, "other", "o2", p)
    assert state.unresolved == %{}
    assert [%{"unresolved" => []}] = TokenEconomizer.prune_status(state)["projects"]
  end

  test "a segment heard in part whose thread moves away holds nothing off, and is read back when it returns",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    {:ok, _} = HalC2.Streams.commit("other", :thread, [{"thread", "other", %{"s" => %{}}}])
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose", "toolPruneQuietMinutes" => 0})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    state = apply_tools(state, p, ["CronCreate"])
    state = observe(state, started(thread, "r2", p, %{}))

    # The feed drops some of r2, and the project goes quiet while r2 runs on.
    state = observe(state, started("other", "o1", p, %{"dropped" => 1, "waiting" => 0}))
    ended("other", "o1", 1, [])
    state = observe(state, finished("other", "o1", 1))
    {:noreply, state} = TokenEconomizer.handle_info({:toolprune_tick, project}, state)
    assert {nil, state} = shape(state, "other", "o2", p)

    # It moves to another MC, which ends r2 there.
    moved = %{"mc" => "elsewhere@host", "label" => "Elsewhere", "at" => "2026-11-09T00:00:00Z"}

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [{"thread", thread, %{"s" => %{"movedTo" => moved}}}])

    assert {%{"deniedTools" => ["CronCreate"]}, state} = shape(state, "other", "o2", p)
    assert Map.has_key?(state.unresolved, {thread, project})

    assert [%{"unresolved" => [], "away" => [^thread]}] =
             TokenEconomizer.prune_status(state)["projects"]

    # Imported back, it brings r2, which used CronCreate: the project's next
    # conversation reads it back before denying anything, as does the thread's own.
    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [{"thread", thread, %{"s" => %{"movedTo" => nil}}}])

    ended(thread, "r2", 2, [%{"type" => "dynamic_tool_call", "providerToolName" => "CronCreate"}])
    assert {nil, state} = shape(state, "other", "o3", p)
    assert state.unresolved == %{}
    assert {nil, state} = shape(state, thread, "r3", p)
    assert [%{"unresolved" => [], "away" => []}] = TokenEconomizer.prune_status(state)["projects"]
  end

  test "a segment heard in part whose run is older than the last 50 is read back, not taken as rolled back",
       %{thread: thread, project: p} do
    project = {p, "claudeAgent"}
    {:ok, _} = HalC2.Streams.commit("other", :thread, [{"thread", "other", %{"s" => %{}}}])
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose", "toolPruneQuietMinutes" => 0})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    state = apply_tools(state, p, ["CronCreate"])
    state = observe(state, started(thread, "r2", p, %{}))

    # The feed drops some of r2, the project goes quiet while r2 runs on, and r2 ends.
    state = observe(state, started("other", "o1", p, %{"dropped" => 1, "waiting" => 0}))
    ended("other", "o1", 1, [])
    state = observe(state, finished("other", "o1", 1))
    {:noreply, state} = TokenEconomizer.handle_info({:toolprune_tick, project}, state)
    state = observe(state, finished(thread, "r2", 2))

    # r2 used CronCreate, and 50 turns end after it before anything reads it back.
    ended(thread, "r2", 2, [%{"type" => "dynamic_tool_call", "providerToolName" => "CronCreate"}])
    for n <- 3..52, do: ended(thread, "r#{n}", n, [])

    assert {nil, state} = shape(state, "other", "o2", p)
    assert state.unresolved == %{}
  end

  test "a subagent's use heard with no project is its thread's project's at once, though the thread never runs again",
       %{thread: thread, project: p} do
    {:ok, _} = HalC2.Streams.commit("other", :thread, [{"thread", "other", %{"s" => %{}}}])
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    state = apply_tools(state, p, ["CronCreate"])
    assert {%{"deniedTools" => ["CronCreate"]}, _state} = shape(state, "other", "o1", p)

    # The thread's record names its project; the plugin restarted under its subagent.
    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [{"thread", thread, %{"s" => %{"projectId" => p}}}])

    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    state = observe(state, stray_item(thread, "CronCreate"))

    assert state.strays == %{}
    assert "CronCreate" in state.prunes[{p, "claudeAgent"}]["used"]
    assert {nil, _state} = shape(state, "other", "o2", p)
  end

  test "a subagent's use heard with no project holds its provider's pruning off, across a restart, until its thread names one",
       %{thread: thread, project: p} do
    {:ok, _} = HalC2.Streams.commit("other", :thread, [{"thread", "other", %{"s" => %{}}}])
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    state = apply_tools(state, p, ["CronCreate"])
    assert {%{"deniedTools" => ["CronCreate"]}, _state} = shape(state, "other", "o1", p)

    # The plugin restarted under a subagent whose handle had neither run nor project.
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})

    # Its thread's record names no project.
    state = observe(state, stray_item(thread, "CronCreate"))

    assert {nil, state} = shape(state, "other", "o2", p)
    assert [%{"unresolved" => [^thread]}] = TokenEconomizer.prune_status(state)["projects"]

    # Restarted again, it still holds.
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    assert state.strays == %{{thread, "claudeAgent"} => ["CronCreate"]}
    assert {nil, state} = shape(state, "other", "o3", p)

    # Its thread's next turn, on a provider pruning has nothing for, names the project:
    # the use is the project's.
    state = observe(state, started(thread, "r2", p, %{"provider" => "opencode"}))
    assert state.strays == %{}
    assert "CronCreate" in state.prunes[{p, "claudeAgent"}]["used"]
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    assert state.strays == %{}
    assert {nil, _state} = shape(state, "other", "o4", p)
  end

  test "a saved use that does not parse holds its provider's pruning off, or every provider's",
       %{thread: thread, project: p} do
    {:ok, _} = HalC2.Streams.commit("other", :thread, [{"thread", "other", %{"s" => %{}}}])
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    _state = apply_tools(state, p, ["CronCreate"])

    path =
      Path.join([HalC2.Plugins.Host.data_dir("token-economizer"), "toolprune", "strays.json"])

    write = fn saved ->
      File.write!(path, if(is_binary(saved), do: saved, else: JSON.encode!(saved)))
      {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
      state
    end

    # Its tools unreadable, it holds its provider's; a whole entry still counts.
    state =
      write.([
        %{"threadId" => thread, "provider" => "claudeAgent", "tools" => ["CronCreate", 3]},
        %{"threadId" => "else", "provider" => "codex", "tools" => ["image_media"]}
      ])

    assert state.strays == %{{nil, "claudeAgent"} => [], {"else", "codex"} => ["image_media"]}
    assert {nil, state} = shape(state, "other", "o1", p)

    # Its turn names its project, but not which tools it kept: it still holds, across
    # a restart too.
    state = observe(state, started(thread, "r2", p, %{}))
    assert {nil, _state} = shape(state, "other", "o2", p)
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    assert {nil, _state} = shape(state, "other", "o3", p)

    # No provider to read, or no file to read at all: every provider's.
    held = %{{nil, "claudeAgent"} => [], {nil, "codex"} => []}

    for saved <- [
          [%{"threadId" => thread, "provider" => "mystery", "tools" => ["CronCreate"]}],
          [%{"threadId" => thread, "tools" => ["CronCreate"]}],
          [7],
          %{"threadId" => thread},
          "[{"
        ] do
      state = write.(saved)
      assert state.strays == held
      state = observe(state, started(thread, "r3", p, %{}))
      assert {nil, _state} = shape(state, "other", "o4", p)
    end
  end

  test "a hold on saved uses that could not be read shows, and a person's word releases it for good",
       %{thread: thread, project: p} do
    {:ok, _} = HalC2.Streams.commit("other", :thread, [{"thread", "other", %{"s" => %{}}}])
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
    state = observe(state, started(thread, "r1", p, %{"newConversation" => true}))
    state = observe(state, finished(thread, "r1", 1))
    _state = apply_tools(state, p, ["CronCreate"])

    path =
      Path.join([HalC2.Plugins.Host.data_dir("token-economizer"), "toolprune", "strays.json"])

    corrupt = fn ->
      File.write!(path, "[{")
      {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
      {nil, state} = shape(state, "other", "o1", p)
      status = TokenEconomizer.prune_status(state)
      assert status["unreadable"] == ["claudeAgent", "codex"]
      assert [%{"provider" => "claudeAgent", "unreadable" => true}] = status["projects"]
      state
    end

    restarted = fn ->
      {:ok, state} = TokenEconomizer.init(%{"toolPrune" => "propose"})
      state
    end

    # Applying the provider's tools releases that provider's hold, across a restart.
    state = apply_tools(corrupt.(), p, ["CronCreate"])
    assert TokenEconomizer.prune_status(state)["unreadable"] == ["codex"]
    state = restarted.()
    assert TokenEconomizer.prune_status(state)["unreadable"] == ["codex"]
    assert {%{"deniedTools" => ["CronCreate"]}, state} = shape(state, "other", "o2", p)
    assert [%{"unreadable" => false}] = TokenEconomizer.prune_status(state)["projects"]

    # So does restoring them.
    state = corrupt.()

    {:reply, {:ok, %{"projects" => [%{"unreadable" => false}]}}, state} =
      TokenEconomizer.handle_call(
        {:toolprune, :restore, %{"projectId" => p, "provider" => "claudeAgent", "tools" => []}},
        nil,
        state
      )

    assert TokenEconomizer.prune_status(state)["unreadable"] == ["codex"]
    assert TokenEconomizer.prune_status(restarted.())["unreadable"] == ["codex"]

    # Changing the mode releases every provider's; keeping it releases none.
    state = corrupt.()

    {:reply, :ok, state} =
      TokenEconomizer.handle_call({:settings, %{"toolPrune" => "propose"}}, nil, state)

    assert TokenEconomizer.prune_status(state)["unreadable"] == ["claudeAgent", "codex"]

    {:reply, :ok, state} =
      TokenEconomizer.handle_call({:settings, %{"toolPrune" => "auto"}}, nil, state)

    assert TokenEconomizer.prune_status(state)["unreadable"] == []
    state = restarted.()
    assert TokenEconomizer.prune_status(state)["unreadable"] == []
    assert state.strays == %{}
  end

  defp stray_item(thread, tool),
    do: %{
      "type" => "turn.item",
      "threadId" => thread,
      "runId" => nil,
      "projectId" => nil,
      "provider" => "claudeAgent",
      "itemType" => "dynamic_tool_call",
      "tool" => tool,
      "status" => "completed",
      "subagent" => true
    }

  defp subagent(thread) do
    case HalC2.Streams.state(thread) |> HalC2.StreamState.list("subagent") do
      [entity] -> {:ok, entity}
      other -> {:error, other}
    end
  end

  defp apply_tools(state, p, tools, provider \\ "claudeAgent") do
    input = %{"projectId" => p, "provider" => provider, "tools" => tools}

    {:reply, {:ok, _}, state} =
      TokenEconomizer.handle_call({:toolprune, :apply, input}, nil, state)

    state
  end

  defp shape(state, thread, run, p, provider \\ "claudeAgent") do
    run = %{"threadId" => thread, "runId" => run, "projectId" => p, "provider" => provider}
    {:reply, shape, state} = TokenEconomizer.handle_call({:shape, run}, nil, state)
    {shape, state}
  end

  defp grant(granted) do
    {settings, version} = HalC2.Settings.get()

    plugins = %{
      "token-economizer" => %{"enabled" => true, "granted" => granted, "settings" => %{}}
    }

    {:ok, _} = HalC2.Settings.put(Map.put(settings, "plugins", plugins), version)
  end

  defp ended(thread, run, ordinal, items, provider_thread \\ "pt") do
    rows =
      for {item, i} <- Enum.with_index(items, 1) do
        {"turn-item", "#{run}-i#{i}",
         %{"s" => Map.merge(item, %{"id" => "#{run}-i#{i}", "runId" => run, "ordinal" => i})}}
      end

    {:ok, _} =
      HalC2.Streams.commit(
        thread,
        :thread,
        [
          {"run", run,
           %{
             "s" => %{
               "id" => run,
               "ordinal" => ordinal,
               "status" => "completed",
               "providerThreadId" => provider_thread
             }
           }}
        ] ++ rows
      )
  end

  # What this process, listening as a plugin's feed, heard so far.
  defp heard do
    receive do
      {:observe, event} -> [event | heard()]
    after
      0 -> []
    end
  end

  defp observe(state, event) do
    {:reply, :ok, state} = TokenEconomizer.handle_call({:observe, event}, nil, state)
    state
  end

  defp started(thread, run, p, extra) do
    Map.merge(
      %{
        "type" => "turn.started",
        "threadId" => thread,
        "runId" => run,
        "projectId" => p,
        "provider" => "claudeAgent"
      },
      extra
    )
  end

  defp finished(thread, run, ordinal),
    do: %{
      "type" => "turn.finished",
      "threadId" => thread,
      "runId" => run,
      "ordinal" => ordinal,
      "status" => "completed"
    }
end
