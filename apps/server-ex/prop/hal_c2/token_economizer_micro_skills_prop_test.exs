for file <-
      ~w(micro_skills_lifecycle micro_skills_observe micro_skills_envfacts loop_guard_state loop_guard_rules loop_guard_shell_edits loop_guard_turn loop_guard_envelope loop_guard_judge token_economizer),
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
      fired count never exceeds the turns folded since it was created;
    * an environment value is vouched for only by a successful workload that
      received it, inline or exported before it down a plain `&&` chain, and
      whose exit status speaks for it: a value only an inert builtin, a later
      segment, an export beside a pipe or in a subshell got, or one unset,
      reassigned, un-exported or cleared by `env`, is never learned as working.

  The settings' mode gate (off learns and stages nothing) is the plugin
  process's two lines around these pure functions and is covered by
  `features/plugins/token-economizer-micro-skills.feature`; the caps a person
  pins are state here and change mid-run like a settings save does. What the
  process keeps around them (the turns it hears, what it staged) is
  `HalC2.TokenEconomizerMicroSkillsSeamPropTest`, below.
  """
  use ExUnit.Case, async: true
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.TokenEconomizer.MicroSkills.{EnvFacts, Lifecycle, Observe}

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

  # --- environment values ----------------------------------------------------------------------

  @workload "python -c 'import app'"

  property "an environment value is vouched for only by a successful workload that received it",
    numtests: HalC2.Prop.numtests(300) do
    forall {segs, code, out} <-
             {env_command(), oneof([0, 1, nil]),
              elements(["ran", "", "Traceback (most recent call last):\n"])} do
      cmd =
        Enum.map_join(segs, fn {seg, sep} ->
          env_text(seg) <> if(sep, do: " #{sep} ", else: "")
        end)

      entries = Observe.observe_turn([bash(cmd, out, code)]).env
      received = env_received(segs)
      workloads? = Enum.any?(segs, fn {seg, _sep} -> env_run(seg) != nil end)

      lawful =
        Enum.all?(entries, fn entry ->
          # Where anything ran, a value it reports is one a workload got.
          # Vouched for: the call exited 0 and a workload its status speaks
          # for got the value.
          (not workloads? or
             Enum.all?(entry.sets, fn kv -> Enum.any?(received, fn {_j, got} -> kv in got end) end)) and
            (entry.ok != true or
               (code == 0 and
                  Enum.all?(entry.sets, fn kv ->
                    Enum.any?(received, fn {j, got} -> kv in got and env_covered?(segs, j) end)
                  end)))
        end)

      lawful
      |> when_fail(IO.puts("cmd: #{cmd}\ncode: #{inspect(code)}\nentries: #{inspect(entries)}"))
    end
  end

  # Ways to clear or un-export a variable: `env`'s options for the command it
  # runs, and the builtins' for the shell.
  @env_scrubs ["env -u APP_SETTINGS", "env -uDEBUG_LEVEL", "env --unset=APP_SETTINGS", "env -i"]
  @scrubs @env_scrubs ++ ["export -n APP_SETTINGS", "export -n DEBUG_LEVEL"]

  defp env_assigns,
    do: resize(2, list({elements(~w(APP_SETTINGS DEBUG_LEVEL)), elements(~w(conf.a conf.b))}))

  defp env_segment, do: frequency([{4, env_simple()}, {1, {:subshell, env_simple()}}])

  defp env_simple do
    oneof([
      {:run, env_assigns()},
      {:inert, env_assigns(), elements(["true", ":", "echo set", "cd .", "pwd", "set -e"])},
      {:export, non_empty(env_assigns())},
      {:plain, non_empty(env_assigns())},
      {:unset, elements(~w(APP_SETTINGS DEBUG_LEVEL))},
      {:scrub, elements(@scrubs)},
      {:scrubbed_run, elements(@env_scrubs)}
    ])
  end

  # Segments, each with the operator after it (nil after the last).
  defp env_command do
    let pairs <- resize(4, non_empty(list({env_segment(), elements(["&&", "||", ";", "|"])}))) do
      List.update_at(pairs, -1, fn {seg, _} -> {seg, nil} end)
    end
  end

  defp env_text({:run, assigns}), do: env_words(assigns, @workload)
  defp env_text({:inert, assigns, head}), do: env_words(assigns, head)
  defp env_text({:export, assigns}), do: "export " <> env_words(assigns, "")
  defp env_text({:plain, assigns}), do: env_words(assigns, "")
  defp env_text({:unset, var}), do: "unset #{var}"
  defp env_text({:scrub, "env" <> _ = scrub}), do: "#{scrub} true"
  defp env_text({:scrub, scrub}), do: scrub
  defp env_text({:scrubbed_run, scrub}), do: "#{scrub} #{@workload}"
  defp env_text({:subshell, seg}), do: "(#{env_text(seg)})"

  defp env_words(assigns, tail),
    do:
      (Enum.map(assigns, fn {k, v} -> "#{k}=#{v}" end) ++ [tail])
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

  # What each workload surely got: its own values, and those exported before
  # it that the shell passes on down a plain `&&` chain -- not an export beside
  # a pipe (its subshell loses it), nor one past a `;`, `||` or `|`, nor one
  # unset or cleared anywhere or reassigned after it, and none where a
  # subshell runs.
  defp env_received(segs) do
    seps = Enum.map(segs, &elem(&1, 1))
    subshell? = Enum.any?(segs, &match?({{:subshell, _}, _}, &1))

    for {{seg, _sep}, j} <- Enum.with_index(segs), assigns = env_run(seg), assigns != nil do
      carried = if subshell?, do: %{}, else: env_carried(segs, seps, j)
      {j, carried |> Map.merge(Map.new(assigns)) |> Map.to_list()}
    end
  end

  defp env_run({:run, assigns}), do: assigns
  defp env_run({:subshell, {:run, assigns}}), do: assigns
  defp env_run({:scrubbed_run, _scrub}), do: []
  defp env_run({:subshell, {:scrubbed_run, _scrub}}), do: []
  defp env_run(_seg), do: nil

  defp env_carried(segs, seps, j) do
    segs
    |> Enum.take(j)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {{{:export, assigns}, _sep}, i}, acc ->
        Map.merge(acc, Map.new(assigns, fn {var, value} -> {var, {value, i}} end))

      _, acc ->
        acc
    end)
    |> Enum.filter(fn {var, {_value, i}} ->
      seps |> Enum.slice(i..(j - 1)//1) |> Enum.all?(&(&1 == "&&")) and
        (i == 0 or Enum.at(seps, i - 1) != "|") and
        not Enum.any?(Enum.with_index(segs), fn {{seg, _sep}, k} ->
          match?({:unset, ^var}, seg) or clears?(seg, var) or
            (match?({:plain, _}, seg) and k > i and List.keymember?(elem(seg, 1), var, 0))
        end)
    end)
    |> Map.new(fn {var, {value, _i}} -> {var, value} end)
  end

  # Whether a segment may clear or un-export `var`.
  defp clears?({:subshell, seg}, var), do: clears?(seg, var)

  defp clears?({kind, scrub}, var) when kind in [:scrub, :scrubbed_run],
    do: scrub == "env -i" or String.ends_with?(scrub, var)

  defp clears?(_seg, _var), do: false

  # A call's status speaks for workload `j` when only `&&` follows it and it
  # did not run only because something before it failed.
  defp env_covered?(segs, j) do
    seps = Enum.map(segs, &elem(&1, 1))

    seps |> Enum.slice(j..-2//1) |> Enum.all?(&(&1 == "&&")) and
      (j == 0 or Enum.at(seps, j - 1) != "||")
  end
end

defmodule HalC2.TokenEconomizerMicroSkillsSeamPropTest do
  @moduledoc """
  A state machine model of what TokenEconomizer's process
  (`HalC2Plugins.TokenEconomizer`) keeps for the micro-skills: two threads'
  turns, each on one of three provider instances (two accounts of one
  driver among them), heard while the guard or learning is on; conversations
  staged as they start; settings saves switching the guard and learning on
  and off; and the MC restarting. Whatever the order, after every step:

    * it holds exactly the turns under way it heard start while the guard or
      learning was on, each on the instance it started on, and a settings
      save drops them only when both are off;
    * a turn is partial exactly when learning was switched under it, or the
      guard was switched on under it;
    * a turn keeps at most 256 calls in memory, all of those it heard
      while learning, and past that none: it is read back whole at its end;
    * what was staged is keyed by thread and instance, in the order staged,
      and survives a restart, which forgets the turns;
    * the guard watches no turn while it is off.

  The laws of the facts themselves are `HalC2.TokenEconomizerMicroSkillsPropTest`,
  above; the guard's are `prop/hal_c2/token_economizer_plugin_prop_test.exs`.
  """
  # The plugin keeps what it staged under the MC's home, which a scratch home
  # sets for the whole VM.
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.TokenEconomizer

  @threads ~w(a b)
  @instances [{"claude-work", "claudeAgent"}, {"claude-home", "claudeAgent"}, {"codex", "codex"}]
  @calls_kept 256

  property "the plugin keeps what the micro-skills fold and stage, over mode switches and restarts",
    numtests: HalC2.Prop.numtests(200) do
    forall cmds <- more_commands(6, commands(__MODULE__)) do
      home = HalC2.Prop.scratch_home("token-economizer-seam")
      {:ok, plugin} = TokenEconomizer.init(settings(initial_state()))
      Process.put(:plugin, plugin)
      {history, state, result} = run_commands(__MODULE__, cmds)
      stop(Process.delete(:plugin))
      HalC2.Prop.restore_env()
      File.rm_rf!(home)

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

  # The model: the modes in force, the turns under way by thread (their
  # instance, whether partial, the calls heard while learning), and the
  # conversations staged, oldest first.
  def initial_state, do: %{guard: "off", micro: "envfacts", turns: %{}, staged: []}

  def command(_state) do
    frequency([
      {3, {:call, __MODULE__, :settings, [elements(~w(off watch)), elements(~w(off envfacts))]}},
      {4, {:call, __MODULE__, :start, [elements(@threads), elements(@instances)]}},
      {6, {:call, __MODULE__, :calls, [elements(@threads), integer(1, 200)]}},
      {3, {:call, __MODULE__, :finish, [elements(@threads)]}},
      {3, {:call, __MODULE__, :stage, [elements(@threads), elements(@instances)]}},
      {1, {:call, __MODULE__, :restart, []}}
    ])
  end

  def precondition(_state, _call), do: true

  defp hears?(state), do: state.guard != "off" or state.micro != "off"

  def next_state(state, _result, {:call, _, :settings, [guard, micro]}) do
    was_on = state.guard != "off"
    was_micro = state.micro != "off"
    state = %{state | guard: guard, micro: micro}

    turns =
      cond do
        not hears?(state) ->
          %{}

        micro != "off" != was_micro or (guard != "off" and not was_on) ->
          Map.new(state.turns, fn {t, turn} -> {t, %{turn | partial: true}} end)

        true ->
          state.turns
      end

    %{state | turns: turns}
  end

  def next_state(state, _result, {:call, _, :start, [thread, {instance, _driver}]}) do
    if hears?(state),
      do: put_in(state.turns[thread], %{instance: instance, partial: false, heard: 0}),
      else: state
  end

  def next_state(state, _result, {:call, _, :calls, [thread, n]}) do
    if state.micro != "off" and Map.has_key?(state.turns, thread),
      do: update_in(state.turns[thread].heard, &(&1 + n)),
      else: state
  end

  def next_state(state, _result, {:call, _, :finish, [thread]}),
    do: %{state | turns: Map.delete(state.turns, thread)}

  def next_state(state, _result, {:call, _, :stage, [thread, {instance, _driver}]}) do
    if state.micro != "off" do
      key = {thread, instance}
      %{state | staged: (state.staged -- [key]) ++ [key]}
    else
      state
    end
  end

  def next_state(state, _result, {:call, _, :restart, []}), do: %{state | turns: %{}}

  def postcondition(state, call, view) do
    state = next_state(state, view, call)

    turns_ok =
      Map.keys(view.turns) |> Enum.sort() == Map.keys(state.turns) |> Enum.sort() and
        Enum.all?(state.turns, fn {thread, turn} ->
          kept = view.turns[thread]

          calls_ok =
            if turn.heard > @calls_kept,
              do: kept.calls == :history,
              else: is_list(kept.calls) and length(kept.calls) == turn.heard

          kept.instance == turn.instance and kept.partial == turn.partial and calls_ok
        end)

    staged_ok =
      view.staged_order == state.staged and
        Enum.sort(view.staged_keys) == Enum.sort(state.staged)

    watching_ok =
      view.watching == if(state.guard == "off", do: 0, else: map_size(state.turns))

    turns_ok and staged_ok and watching_ok
  end

  # --- the commands, against the process's callbacks ---------------------------------------

  defp settings(state), do: %{"loopGuard" => state.guard, "microSkills" => state.micro}

  def settings(guard, micro) do
    {:reply, :ok, plugin} =
      TokenEconomizer.handle_call(
        {:settings, settings(%{guard: guard, micro: micro})},
        nil,
        Process.get(:plugin)
      )

    put(plugin)
  end

  def start(thread, {instance, driver}) do
    observe(%{
      "type" => "turn.started",
      "threadId" => thread,
      "runId" => "run-#{System.unique_integer([:positive])}",
      "projectId" => "p",
      "instanceId" => instance,
      "provider" => driver
    })
  end

  def calls(thread, n) do
    case Process.get(:plugin).turns[thread] do
      nil ->
        view(Process.get(:plugin))

      turn ->
        item = %{
          "type" => "turn.item",
          "threadId" => thread,
          "runId" => turn.run,
          "itemType" => "command_execution",
          "status" => "completed",
          "input" => "ls",
          "output" => "a.py"
        }

        Enum.reduce(1..n, nil, fn _, _ -> observe(item) end)
    end
  end

  def finish(thread) do
    case Process.get(:plugin).turns[thread] do
      nil ->
        view(Process.get(:plugin))

      turn ->
        observe(%{
          "type" => "turn.finished",
          "threadId" => thread,
          "runId" => turn.run,
          "status" => "completed"
        })
    end
  end

  def stage(thread, {instance, driver}) do
    run = %{
      "threadId" => thread,
      "projectId" => "p",
      "instanceId" => instance,
      "provider" => driver
    }

    deadline = System.monotonic_time(:millisecond) + 60_000

    plugin =
      case TokenEconomizer.handle_call({:shape_run, run, deadline}, nil, Process.get(:plugin)) do
        {:reply, _answer, plugin, {:continue, :save_staged}} ->
          {:noreply, plugin} = TokenEconomizer.handle_continue(:save_staged, plugin)
          plugin

        {:reply, _answer, plugin} ->
          plugin
      end

    put(plugin)
  end

  # The MC restarts: the process starts afresh from what it saved, with the
  # settings it had.
  def restart do
    old = Process.get(:plugin)
    stop(old)
    {:ok, plugin} = TokenEconomizer.init(old.settings)
    put(plugin)
  end

  defp observe(event) do
    {:reply, :ok, plugin} =
      TokenEconomizer.handle_call({:observe, event}, nil, Process.get(:plugin))

    put(plugin)
  end

  defp put(plugin) do
    Process.put(:plugin, plugin)
    view(plugin)
  end

  defp view(plugin) do
    %{
      turns:
        Map.new(plugin.turns, fn {thread, turn} ->
          {thread, %{instance: turn.instance, partial: turn.partial, calls: turn.calls}}
        end),
      staged_order: plugin.staged_order,
      staged_keys: Map.keys(plugin.staged),
      watching: TokenEconomizer.status(plugin)["watching"]
    }
  end

  # Ends the process's tasks, as its end would, and forgets what they sent.
  defp stop(plugin) do
    ref = Process.monitor(plugin.sup)
    Process.unlink(plugin.sup)
    Process.exit(plugin.sup, :shutdown)
    receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
    flush()
  end

  defp flush do
    receive do
      {kind, _, _, _, _} when kind in [:verdict, :delivered, :DOWN] -> flush()
    after
      0 -> :ok
    end
  end
end
