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
    ended(thread, "r2", 2, [%{"type" => "subagent", "title" => "Schedule it"}])

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

  test "Codex turns the plugin missed are no evidence its goal and image packages went unused",
       %{project: p} do
    project = {p, "codex"}
    thread = "codex-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"thread", thread, %{"s" => %{}}},
        {"provider-thread", "pt", %{"s" => %{"driver" => "codex"}}}
      ])

    # Codex viewed an image in r1 while the plugin was not running: no item shows it.
    ended(thread, "r1", 1, [])
    {:ok, state} = TokenEconomizer.init(%{})
    state = observe(state, started(thread, "r2", p, %{"provider" => "codex"}))

    prune = state.prunes[project]
    assert prune["prompts"] == 1
    assert %{"prompts" => 1} = prune["streaks"]["collaboration"]
    assert prune["loadedSessions"]["collaboration"] == 1

    for package <- ~w(goals image_media) do
      assert prune["streaks"][package] in [nil, %{"sessions" => 0, "prompts" => 0}]
      assert prune["loadedSessions"][package] in [nil, 0]
    end
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

  defp grant(granted) do
    {settings, version} = HalC2.Settings.get()

    plugins = %{
      "token-economizer" => %{"enabled" => true, "granted" => granted, "settings" => %{}}
    }

    {:ok, _} = HalC2.Settings.put(Map.put(settings, "plugins", plugins), version)
  end

  defp ended(thread, run, ordinal, items) do
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
               "providerThreadId" => "pt"
             }
           }}
        ] ++ rows
      )
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
