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
