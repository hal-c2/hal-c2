for file <- ~w(micro_skills_lifecycle micro_skills_observe micro_skills_envfacts),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerMicroSkillsPropTest do
  @moduledoc """
  The micro-skills' lifecycle laws (`plugins/token-economizer/mc/micro_skills_*`),
  over one project's facts fed turns, conversation starts, caps changes, drops,
  restores and restarts (the state saved and loaded back), in any order.
  Whatever the order:

    * nothing is staged that is not active and past the firing gate, with a
      claim the lint accepts;
    * what is staged fits the block's budget: at most `max_facts` facts and
      `max_tokens` tokens of text;
    * promotion needs the evidence the rules name: every active or retired
      fact once had (and keeps) at least `Lifecycle.k_promote` drifted
      confirmations, and a fact with fewer is a candidate;
    * an active fact's recency score is never below the floor once it has
      been folded as active: promotion is decided in the candidate branch, so
      the score is first applied at the next fold, as upstream has it, and a
      fact promoted into a negative score retires there;
    * a dropped fact is gone and never comes back -- however much confirming
      evidence recurs -- until it is restored;
    * a turn folds once: folding a run already folded changes nothing;
    * saving and loading changes nothing: the dump of the reloaded state is
      the dump that was saved, and both stage the same block;
    * every fact ever staged was learned from evidence, never invented: its
      fired count never exceeds the turns folded since it was created.

  The settings' mode gate (off learns and stages nothing) is the plugin
  process's two lines around these pure functions and is covered by
  `features/plugins/token-economizer-micro-skills.feature`; the caps a person
  pins are state here and change mid-run like a settings save does.
  """
  use ExUnit.Case, async: true
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.TokenEconomizer.MicroSkills.{EnvFacts, Lifecycle}

  @repair_id "form_repair:run_tests:python -m pytest"
  @absent_id "absent_tool:ruff"
  @boundary_id "boundary:fetch_remote"
  @probe_id "empty_probe:vcs_refs"
  @ids [@repair_id, @absent_id, @boundary_id, @probe_id]

  # --- the state machine ---------------------------------------------------------------------

  property "the micro-skills keep their lifecycle laws in any order",
    numtests: HalC2.Prop.numtests(200) do
    forall cmds <- more_commands(4, commands(__MODULE__, initial_state())) do
      Process.put(:skills, EnvFacts.new())
      {history, state, result} = run_commands(__MODULE__, cmds)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history, pretty: true, limit: 60)}
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result, pretty: true)}
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end

  # The model: only what the laws need -- which ids a person dropped, which
  # facts exist (a fact is created by its family's first evidence and removed
  # only by a drop), which runs were folded, the caps in force, and how many
  # turns were folded.
  def initial_state do
    %{
      dropped: MapSet.new(),
      present: MapSet.new(),
      folded: MapSet.new(),
      max_facts: 4,
      max_tokens: 150,
      turns: 0
    }
  end

  # The facts one turn's calls create, by their families' discovery rules.
  defp created(kinds) do
    []
    |> then(&if(:broken in kinds, do: [@repair_id | &1], else: &1))
    |> then(&if(:absent in kinds and :tool_runs not in kinds, do: [@absent_id | &1], else: &1))
    |> then(&if(:refused in kinds, do: [@boundary_id | &1], else: &1))
    |> then(&if(:probe_empty in kinds or :probe_hit in kinds, do: [@probe_id | &1], else: &1))
  end

  def command(_state) do
    frequency([
      {10,
       {:call, __MODULE__, :turn,
        [
          resize(
            4,
            non_empty(
              list(
                elements([
                  :broken,
                  :broken,
                  :fixed,
                  :absent,
                  :tool_runs,
                  :refused,
                  :reachable,
                  :probe_empty,
                  :probe_hit,
                  :other
                ])
              )
            )
          ),
          elements([:fresh, "run-a", "run-b"])
        ]}},
      {3, {:call, __MODULE__, :render, []}},
      {1, {:call, __MODULE__, :drop, [elements(@ids)]}},
      {1, {:call, __MODULE__, :restore, [elements(@ids)]}},
      {1, {:call, __MODULE__, :caps, [integer(1, 6), integer(40, 200)]}},
      {2, {:call, __MODULE__, :restart, []}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :turn, [kinds, run]}) do
    if run != :fresh and MapSet.member?(state.folded, run) do
      state
    else
      folded = if run == :fresh, do: state.folded, else: MapSet.put(state.folded, run)

      present =
        Enum.reduce(created(kinds), state.present, fn id, present ->
          if MapSet.member?(state.dropped, id), do: present, else: MapSet.put(present, id)
        end)

      %{state | folded: folded, present: present, turns: state.turns + 1}
    end
  end

  # A drop of a fact that is not there is refused and records nothing.
  def next_state(state, _result, {:call, _, :drop, [id]}) do
    if MapSet.member?(state.present, id) do
      %{state | dropped: MapSet.put(state.dropped, id), present: MapSet.delete(state.present, id)}
    else
      state
    end
  end

  def next_state(state, _result, {:call, _, :restore, [id]}),
    do: %{state | dropped: MapSet.delete(state.dropped, id)}

  def next_state(state, _result, {:call, _, :caps, [facts, tokens]}),
    do: %{state | max_facts: facts, max_tokens: tokens}

  def next_state(state, _result, _call), do: state

  # --- the commands at work ---------------------------------------------------------------------

  # One turn made of the given call kinds, folded under a fresh run id (never
  # folded before) or one of two reused ones (folded at most once).
  def turn(kinds, run) do
    before = Process.get(:skills)
    iid = if run == :fresh, do: "run-#{System.unique_integer([:positive])}", else: run
    calls = Enum.flat_map(kinds, &calls/1)
    after_turn = EnvFacts.update_turn(before, calls, iid)
    Process.put(:skills, after_turn)
    %{before: before, after: after_turn, reused: run != :fresh and iid in before.folded}
  end

  def render do
    before = Process.get(:skills)
    {text, after_render} = EnvFacts.render(before)
    Process.put(:skills, after_render)
    %{before: before, after: after_render, text: text, ids: EnvFacts.injected_ids(after_render)}
  end

  def drop(id) do
    before = Process.get(:skills)

    after_drop =
      case EnvFacts.drop(before, id) do
        {:ok, skills} -> skills
        {:error, _} -> before
      end

    Process.put(:skills, after_drop)
    %{before: before, after: after_drop, existed: Map.has_key?(before.facts, id)}
  end

  def restore(id) do
    before = Process.get(:skills)

    after_restore =
      case EnvFacts.restore(before, id) do
        {:ok, skills} -> skills
        {:error, _} -> before
      end

    Process.put(:skills, after_restore)
    %{before: before, after: after_restore}
  end

  def caps(max_facts, max_tokens) do
    skills = %{Process.get(:skills) | max_facts: max_facts, max_tokens: max_tokens}
    Process.put(:skills, skills)
    :ok
  end

  # A plugin restart: the state as it is saved, read back.
  def restart do
    before = Process.get(:skills)
    loaded = before |> EnvFacts.dump() |> JSON.encode!() |> JSON.decode!() |> EnvFacts.load()
    loaded = %{loaded | max_facts: before.max_facts, max_tokens: before.max_tokens}
    Process.put(:skills, loaded)
    %{before: before, after: loaded}
  end

  defp bash(command, output, code), do: {"Bash", %{"command" => command}, output, code}
  defp edit(path), do: {"Edit", %{"file_path" => path}, "ok", nil}

  # The bare runner fails, the explicit path works: form repair confirms.
  defp calls(:broken) do
    [
      edit("pkg/a.py"),
      bash("python -m pytest tests -q", "/opt/base/bin/python: No module named pytest", 1),
      bash("/opt/proj/bin/python -m pytest tests -q", "2 passed in 0.1s", 0)
    ]
  end

  # The bare runner works: form repair is contradicted.
  defp calls(:fixed) do
    [edit("pkg/b.py"), bash("python -m pytest tests -q", "2 passed in 0.1s", 0)]
  end

  defp calls(:absent) do
    [edit("pkg/c.py"), bash("ruff check .", "Exit code 127\nbash: ruff: command not found", 127)]
  end

  defp calls(:tool_runs) do
    [edit("pkg/d.py"), bash("ruff check .", "All checks passed!", 0)]
  end

  defp calls(:refused) do
    [
      bash(
        "curl -sS https://api.example.org/x",
        "curl: (7) Failed to connect to api.example.org port 443: Connection refused",
        7
      )
    ]
  end

  defp calls(:reachable) do
    [bash("curl -sS https://api.example.org/x", "{\"ok\": true}", 0)]
  end

  defp calls(:probe_empty), do: [bash("git remote -v", "", 0)]
  defp calls(:probe_hit), do: [bash("git remote -v", "origin https://x/y (fetch)", 0)]
  defp calls(:other), do: [bash("ls", "pkg", 0), edit("pkg/e.py")]

  # --- the laws -------------------------------------------------------------------------------------

  def postcondition(
        state,
        {:call, _, :turn, [kinds, _run]},
        %{before: before, after: skills} = result
      ) do
    reused_ok = not result.reused or skills == before

    after_state =
      if result.reused,
        do: state,
        else: next_state(state, nil, {:call, nil, :turn, [kinds, :fresh]})

    reused_ok and skills.now == state.turns + if(result.reused, do: 0, else: 1) and
      lawful?(after_state, skills) and
      MapSet.equal?(MapSet.new(Map.keys(skills.facts)), after_state.present) and
      Enum.all?(skills.facts, fn {_id, fact} ->
        fact.life.fire_den <= skills.now and fact.life.fire_num <= fact.life.fire_den
      end)
  end

  def postcondition(state, {:call, _, :render, _}, %{after: skills} = result) do
    staged = result.ids
    facts = Enum.map(staged, &skills.facts[&1])

    lawful?(state, skills) and
      length(staged) <= state.max_facts and
      length(Enum.uniq(staged)) == length(staged) and
      (result.text == "" or String.length(result.text) <= state.max_tokens * 4 + 1) and
      Enum.all?(facts, fn fact ->
        fact != nil and Lifecycle.injectable?(fact.life) and
          EnvFacts.claim(fact) != "" and EnvFacts.lint_ok?(EnvFacts.claim(fact))
      end) and
      Enum.all?(facts, fn fact ->
        fact == nil or String.contains?(result.text, first_line(fact))
      end)
  end

  def postcondition(state, {:call, _, :drop, [id]}, %{after: skills} = result) do
    lawful?(next_state(state, nil, {:call, nil, :drop, [id]}), skills) and
      result.existed == MapSet.member?(state.present, id) and
      (not result.existed or
         (not Map.has_key?(skills.facts, id) and MapSet.member?(skills.dropped, id)))
  end

  def postcondition(state, {:call, _, :restore, [id]}, %{after: skills}) do
    lawful?(next_state(state, nil, {:call, nil, :restore, [id]}), skills) and
      not MapSet.member?(skills.dropped, id)
  end

  def postcondition(state, {:call, _, :restart, _}, %{before: before, after: skills}) do
    lawful?(state, skills) and EnvFacts.dump(skills) == EnvFacts.dump(before) and
      render_text(skills) == render_text(before)
  end

  def postcondition(state, {:call, _, :caps, _}, :ok),
    do: lawful?(state, Process.get(:skills))

  defp render_text(skills), do: skills |> EnvFacts.render() |> elem(0)

  # A staged fact shows in the block: its own line, unless form repairs merged
  # (then its failing form is named there).
  defp first_line(fact) do
    if fact.family == "form_repair",
      do: fact.params["a"] || "",
      else: EnvFacts.claim(fact)
  end

  # What holds of the state after every command, against the model's record of
  # drops and folded turns.
  defp lawful?(state, skills) do
    # A dropped fact never comes back without a restore, and the drops on
    # record are the ones the model saw a person make.
    dropped_ok =
      MapSet.equal?(skills.dropped, state.dropped) and
        MapSet.disjoint?(state.dropped, MapSet.new(Map.keys(skills.facts)))

    facts_ok =
      Enum.all?(skills.facts, fn {_id, fact} ->
        confirms = Lifecycle.drifted_confirms(fact.life)

        # Promotion needs the evidence the rules name, and keeps it: past
        # candidate is exactly having reached it.
        # An active fact folded as active would have retired at a score
        # below the floor; one promoted at the last fold has not been yet.
        fact.life.state == "CANDIDATE" ==
          (confirms < Lifecycle.k_promote() and fact.life.state != "RETIRED") and
          (fact.life.state != "ACTIVE" or fact.life.promoted_at == skills.now - 1 or
             Lifecycle.score(fact.life, skills.now) >= Lifecycle.score_floor()) and
          fact.life.fire_num <= fact.life.fire_den
      end)

    dropped_ok and facts_ok and skills.now == state.turns
  end
end
