# SPDX-License-Identifier: Apache-2.0

for file <-
      ~w(micro_skills_lifecycle micro_skills_observe micro_skills_envfacts micro_skills_distiller micro_skills_history loop_guard_state loop_guard_rules loop_guard_shell_edits loop_guard_turn loop_guard_envelope loop_guard_judge tool_prune_evidence token_economizer),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerHeldProjectTest do
  @moduledoc """
  A project whose saved micro-skills file does not read is held
  (`plugins/token-economizer/mc/token_economizer.ex`): with learning and the history
  import on, its turns start no fold and teach nothing, forgetting it is refused, and
  its file is left as it was. The plugin process's state driven event by event. Not
  async: the plugin's data directory is under the MC's home.
  """
  use ExUnit.Case, async: false

  alias HalC2Plugins.TokenEconomizer

  @moduletag :tmp_dir

  @garbled "{\"facts\": not json"

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    File.write!(Path.join(dir, "config.json"), "{}")
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    on_exit(fn -> Application.delete_env(:hal_c2, :settings_check_ms) end)

    start_supervised!(HalC2.Settings)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)

    p = "p-#{System.unique_integer([:positive])}"
    path = TokenEconomizer.micro_skills_path(p)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @garbled)

    %{project: p, path: path}
  end

  test "with the import on, a held project folds nothing, is not forgotten, and keeps its file",
       %{project: p, path: path} do
    {:ok, state} = TokenEconomizer.init(%{"microSkills" => "on", "historyImport" => true})

    state =
      observe(state, %{
        "type" => "turn.started",
        "threadId" => "a",
        "runId" => "r1",
        "projectId" => p,
        "provider" => "claudeAgent",
        "newConversation" => true
      })

    # The turn starts no fold from history.
    assert state.folds[p] == nil
    assert state.skills[p].held =~ "not valid JSON"

    # A turn that would teach a fact teaches the held project nothing.
    state =
      observe(state, %{
        "type" => "turn.item",
        "threadId" => "a",
        "runId" => "r1",
        "itemType" => "command_execution",
        "status" => "completed",
        "input" => "pytest -q",
        "output" => "3 passed in 0.10s",
        "exitCode" => 0
      })

    state =
      observe(state, %{
        "type" => "turn.finished",
        "threadId" => "a",
        "runId" => "r1",
        "ordinal" => 1,
        "status" => "completed"
      })

    assert state.folds[p] == nil
    assert state.skills[p].now == 0
    assert state.skills[p].folded == []

    # Forgetting it is refused, saying why.
    assert {:reply, {:error, message}, state} =
             TokenEconomizer.handle_call({:micro_skill_forget, %{"projectId" => p}}, nil, state)

    assert message =~ "held"
    assert message =~ "not valid JSON"
    assert state.folds[p] == nil

    assert File.read!(path) == @garbled
  end

  test "a held project's entry names its file, and reads again once the file is repaired",
       %{project: p, path: path} do
    {:ok, state} = TokenEconomizer.init(%{"microSkills" => "envfacts"})

    assert {:reply, {:ok, %{"projects" => [held]}}, state} =
             TokenEconomizer.handle_call({:micro_skills, %{"projectId" => p}}, nil, state)

    assert held["held"] =~ "not valid JSON"
    assert held["file"] == path

    File.rm!(path)

    assert {:reply, {:ok, %{"projects" => [entry]}}, _state} =
             TokenEconomizer.handle_call({:micro_skills, %{"projectId" => p}}, nil, state)

    assert entry["held"] == nil
    refute Map.has_key?(entry, "file")
  end

  test "a project is named on microSkillsProjects as it first shows and as its hold ends",
       %{project: p, path: path} do
    # The test stands in for the plugin host, which publishes what it is cast.
    Process.register(self(), HalC2.Plugins)
    {:ok, state} = TokenEconomizer.init(%{"microSkills" => "envfacts"})

    state = turn(state, p, "r1")
    assert projects_published() == [%{"projectId" => p, "held" => true}]

    # Another turn of the held project changes nothing the listing shows.
    state = turn(state, p, "r2")
    assert projects_published() == []

    # Repaired and asked for by name (a page's Read again), the hold ends for every page.
    File.rm!(path)

    {:reply, {:ok, _view}, state} =
      TokenEconomizer.handle_call({:micro_skills, %{"projectId" => p}}, nil, state)

    assert projects_published() == [%{"projectId" => p, "held" => false}]

    # Its next turn names it no more.
    state = turn(state, p, "r3")
    assert projects_published() == []

    # Learning in a project already listed is its own topic's alone.
    _state = turn(state, p, "r4")
    assert projects_published() == []
  end

  defp turn(state, p, run) do
    state
    |> observe(%{
      "type" => "turn.started",
      "threadId" => "a",
      "runId" => run,
      "projectId" => p,
      "provider" => "claudeAgent",
      "newConversation" => true
    })
    |> observe(%{
      "type" => "turn.item",
      "threadId" => "a",
      "runId" => run,
      "itemType" => "command_execution",
      "status" => "completed",
      "input" => "pytest -q",
      "output" => "bash: pytest: command not found",
      "exitCode" => 127
    })
    |> observe(%{
      "type" => "turn.finished",
      "threadId" => "a",
      "runId" => run,
      "ordinal" => 1,
      "status" => "completed"
    })
  end

  defp projects_published do
    receive do
      {:"$gen_cast", {:publish, "token-economizer", "microSkillsProjects", value}} ->
        [value | projects_published()]

      {:"$gen_cast", {:publish, "token-economizer", _topic, _value}} ->
        projects_published()
    after
      0 -> []
    end
  end

  defp observe(state, event) do
    {:reply, :ok, state} = TokenEconomizer.handle_call({:observe, event}, nil, state)
    state
  end
end
