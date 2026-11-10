for file <-
      ~w(micro_skills_lifecycle micro_skills_observe micro_skills_envfacts micro_skills_distiller micro_skills_history loop_guard_state loop_guard_rules loop_guard_shell_edits loop_guard_turn loop_guard_envelope loop_guard_judge tool_prune_evidence token_economizer),
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
  # unset anywhere, or cleared or reassigned after it, and none where a
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
          match?({:unset, ^var}, seg) or (k > i and clears?(seg, var)) or
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
    * a conversation that replaces a staged one (a Handoff) while learning is
      off is given nothing and staged nothing, and a turn holds only what its
      own conversation was staged as it started: one started on a conversation
      given nothing is credited nothing, however learning is switched after;
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
  alias HalC2Plugins.TokenEconomizer.MicroSkills.EnvFacts

  @threads ~w(a b)
  @instances [{"claude-work", "claudeAgent"}, {"claude-home", "claudeAgent"}, {"codex", "codex"}]
  @calls_kept 256

  property "the plugin keeps what the micro-skills fold and stage, over mode switches and restarts",
    numtests: HalC2.Prop.numtests(200) do
    forall cmds <- more_commands(6, commands(__MODULE__)) do
      home = HalC2.Prop.scratch_home("token-economizer-seam")
      learned()
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
  # instance, whether partial, the calls heard while learning, whether their
  # conversation was given facts as they started), the conversations staged,
  # oldest first, and those of them last staged with learning off.
  def initial_state,
    do: %{guard: "off", micro: "envfacts", turns: %{}, staged: [], given_none: MapSet.new()}

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
    key = {thread, instance}
    given = key in state.staged and not MapSet.member?(state.given_none, key)
    turn = %{instance: instance, partial: false, heard: 0, given: given}
    if hears?(state), do: put_in(state.turns[thread], turn), else: state
  end

  def next_state(state, _result, {:call, _, :calls, [thread, n]}) do
    if state.micro != "off" and Map.has_key?(state.turns, thread),
      do: update_in(state.turns[thread].heard, &(&1 + n)),
      else: state
  end

  def next_state(state, _result, {:call, _, :finish, [thread]}),
    do: %{state | turns: Map.delete(state.turns, thread)}

  # Learning off, a conversation is given nothing: one replacing a staged
  # conversation is staged nothing, and one never staged stays unstaged.
  def next_state(state, _result, {:call, _, :stage, [thread, {instance, _driver}]}) do
    key = {thread, instance}

    cond do
      state.micro != "off" ->
        %{
          state
          | staged: (state.staged -- [key]) ++ [key],
            given_none: MapSet.delete(state.given_none, key)
        }

      key in state.staged ->
        %{
          state
          | staged: (state.staged -- [key]) ++ [key],
            given_none: MapSet.put(state.given_none, key)
        }

      true ->
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

          kept.instance == turn.instance and kept.partial == turn.partial and calls_ok and
            (turn.given or kept.injected == [])
        end)

    staged_ok =
      view.staged_order == state.staged and
        Enum.sort(Map.keys(view.staged)) == Enum.sort(state.staged) and
        Enum.all?(state.staged, &(view.staged[&1] != [] or MapSet.member?(state.given_none, &1))) and
        Enum.all?(state.given_none, &(view.staged[&1] == []))

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

  # Project `p` has learned a fact, so a conversation staged while learning is
  # given it: the bare `pytest` is missing, and `python -m pytest` works.
  defp learned do
    skills =
      EnvFacts.add_candidate(EnvFacts.new(), %{
        id: "form_repair:run_tests:pytest",
        family: "form_repair",
        high: false,
        drift: false,
        params: %{
          "intent" => "run_tests",
          "a" => "pytest",
          "b_counts" => %{"python -m pytest" => 3},
          "error_counts" => %{}
        }
      })

    # Promoted, and fired so often no case's folds can sink it below the gate.
    saved =
      skills
      |> EnvFacts.dump()
      |> update_in(["facts", "form_repair:run_tests:pytest", "life"], fn life ->
        %{life | "state" => "ACTIVE", "fire_num" => 1000, "fire_den" => 1000}
      end)

    path = TokenEconomizer.micro_skills_path("p")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(Map.put(saved, "projectId", "p")))
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
          {thread,
           %{
             instance: turn.instance,
             partial: turn.partial,
             calls: turn.calls,
             injected: Map.get(turn, :injected, [])
           }}
        end),
      staged_order: plugin.staged_order,
      staged: plugin.staged,
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

defmodule HalC2.TokenEconomizerHistoryPropTest do
  @moduledoc """
  A state machine model of the first fold from history
  (`plugins/token-economizer/mc/micro_skills_history.ex`), driven as the
  plugin's process drives it: one read asked at a time and answered later,
  or failing; turns ending in the project's threads before the fold starts
  and while it runs; the import turned off and on under it; and the MC
  restarting, the fold and the turns folded saved together. Whatever the
  order:

    * no turn is folded twice, and the fold counts exactly the turns it
      folded itself, not those folded as they ended while it was stopped;
    * only turns that ended are folded: those of the threads before the fold
      started, and those heard live;
    * the turns heard live are folded in the order they ended, and, for a
      fold never stopped, after every turn it imported;
    * a read lost to a restart is asked again from where the fold was saved,
      and what it folded before stands;
    * driven to its end, with the import on, the fold is done and has folded
      every turn, but those of a thread or a held-back turn it could not read.

  The envelope it seeds is `HalC2.TokenEconomizerHistorySeedPropTest`, below.
  """
  use ExUnit.Case, async: true
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.TokenEconomizer.MicroSkills.History

  @threads ~w(a b c)
  @page 2
  @base ~U[2026-11-01 00:00:00Z]

  property "the first fold from history folds every turn once, the live ones after it, in order",
    numtests: HalC2.Prop.numtests(300) do
    forall cmds <- more_commands(4, commands(__MODULE__)) do
      Process.put(:world, %{
        clock: 0,
        runs: [],
        fold: nil,
        offered: [],
        reading: nil,
        lost: [],
        direct: 0,
        stopped: false
      })

      {history, state, result} = run_commands(__MODULE__, cmds)
      drained = drain()

      (result == :ok and drained == :ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history, pretty: true, limit: 60)}
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result, pretty: true)}
        Drained: #{inspect(drained, pretty: true)}
        World: #{inspect(Process.get(:world), pretty: true, limit: :infinity)}
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end

  # The model: whether the fold started. The rest is the world's, checked
  # after every step.
  def initial_state, do: %{started: false}

  def command(%{started: false}) do
    frequency([
      {5, {:call, __MODULE__, :turn, [elements(@threads)]}},
      {1, {:call, __MODULE__, :start, []}}
    ])
  end

  def command(_state) do
    frequency([
      {3, {:call, __MODULE__, :turn, [elements(@threads)]}},
      {4, {:call, __MODULE__, :ask, []}},
      {4, {:call, __MODULE__, :answer, []}},
      {1, {:call, __MODULE__, :fail, []}},
      {1, {:call, __MODULE__, :stop, []}},
      {1, {:call, __MODULE__, :resume, []}},
      {1, {:call, __MODULE__, :restart, []}}
    ])
  end

  def precondition(%{started: started}, {:call, _, :start, []}), do: not started
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :start, []}), do: %{state | started: true}
  def next_state(state, _result, _call), do: state

  def postcondition(_state, _call, world), do: laws(world) == :ok

  # --- the laws ------------------------------------------------------------------------------

  # A fold once stopped, by the import turned off or its threads not listed,
  # imports after the live turns folded while it was stopped.
  defp laws(world) do
    live = for {run, _thread, :live} <- world.runs, do: run
    ended = MapSet.new(world.runs, &elem(&1, 0))
    offered = world.offered
    folded_live = Enum.filter(offered, &(&1 in live))
    turns = world.fold && History.view(world.fold)["turns"]

    cond do
      offered != Enum.uniq(offered) -> {:twice, offered}
      not Enum.all?(offered, &(&1 in ended)) -> {:never_ended, offered}
      turns not in [nil, length(offered) - world.direct] -> {:counted, turns, offered}
      folded_live != Enum.filter(live, &(&1 in folded_live)) -> {:live_order, folded_live}
      not world.stopped and not live_last?(offered, live) -> {:live_before_import, offered}
      true -> :ok
    end
  end

  defp live_last?(offered, live) do
    offered |> Enum.drop_while(&(&1 not in live)) |> Enum.all?(&(&1 in live))
  end

  # Turns the import on and reads until nothing is left; the fold is then
  # done, having folded every turn but those it could not read.
  defp drain do
    world = Process.get(:world)

    if world.fold == nil do
      :ok
    else
      resume()
      Enum.reduce_while(1..500, nil, fn _, _ -> drain_step() end)
      world = Process.get(:world)
      all = MapSet.new(world.runs, &elem(&1, 0))
      expected = MapSet.difference(all, MapSet.new(world.lost))

      cond do
        History.view(world.fold)["state"] != "done" -> {:not_done, world.fold}
        laws(world) != :ok -> laws(world)
        not MapSet.subset?(expected, MapSet.new(world.offered)) -> {:missed, expected}
        true -> :ok
      end
    end
  end

  defp drain_step do
    world = Process.get(:world)

    cond do
      world.reading != nil ->
        answer()
        {:cont, nil}

      History.next(world.fold) == nil ->
        {:halt, nil}

      true ->
        ask()
        {:cont, nil}
    end
  end

  # --- the commands, on the world ---------------------------------------------------------

  # A turn ends in `thread`: before the fold, one it will import; while it
  # runs, one it holds back; else one folded as it ends.
  def turn(thread) do
    world = tick(Process.get(:world))
    run = "r#{world.clock}"

    case world.fold do
      nil ->
        put(%{world | runs: world.runs ++ [{run, thread, :old}]})

      fold ->
        world = %{world | runs: world.runs ++ [{run, thread, :live}]}

        if History.running?(fold),
          do: put(%{world | fold: History.hold(fold, [thread, run, []])}),
          else: put(%{world | offered: world.offered ++ [run], direct: world.direct + 1})
    end
  end

  def start do
    world = tick(Process.get(:world))
    put(%{world | fold: History.new("f", at(world.clock))})
  end

  # Asks the read the fold awaits, if none is under way; the answer is read
  # now, against the threads as they are, and applied by `answer/0`.
  def ask do
    world = Process.get(:world)

    case world.reading == nil and History.next(world.fold) do
      :finish ->
        put(%{world | fold: History.finish(world.fold, at(world.clock))})

      what when what not in [false, nil] ->
        put(%{world | reading: {world.fold["step"], what, read(world, what)}})

      _ ->
        world
    end
  end

  def answer do
    world = Process.get(:world)

    case world.reading do
      {step, what, result} -> put(apply_read(%{world | reading: nil}, step, what, result))
      nil -> world
    end
  end

  # The read under way fails.
  def fail do
    world = Process.get(:world)

    case world.reading do
      {step, what, _result} -> put(apply_read(%{world | reading: nil}, step, what, :error))
      nil -> world
    end
  end

  def stop, do: change(&History.stop(&1, "the history import was turned off"))
  def resume, do: change(&History.resume/1)

  # The MC restarts: the fold loads back from what was saved, and the read
  # under way is lost.
  def restart do
    world = Process.get(:world)
    fold = world.fold && History.load(world.fold |> JSON.encode!() |> JSON.decode!())
    put(%{world | fold: fold, reading: nil})
  end

  defp change(fun) do
    world = Process.get(:world)
    put(%{world | fold: world.fold && fun.(world.fold)})
  end

  # --- reading, as `HalC2Plugins.TokenEconomizer.read_history/6` does ------------------------

  defp read(world, :plan) do
    threads =
      world.runs
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.map(fn {thread, [first | _]} ->
        created = at(String.to_integer(String.trim_leading(first, "r")))
        %{"id" => thread, "createdAt" => created, "latestUserMessageAt" => created}
      end)

    History.plan(threads, DateTime.add(@base, world.clock, :second), 3650, 200)
  end

  defp read(world, {:page, thread, after_run}) do
    runs = for {run, ^thread, _} <- world.runs, do: run

    runs =
      if after_run, do: Enum.drop(runs, Enum.find_index(runs, &(&1 == after_run)) + 1), else: runs

    page = Enum.take(runs, @page)
    {page, length(page) == @page}
  end

  defp read(_world, {:pending, entries}), do: entries

  # The answer applied to the fold that asked it, if it still awaits it.
  defp apply_read(world, step, what, result) do
    fold = world.fold

    if History.running?(fold) and fold["step"] == step,
      do: applied(world, what, result),
      else: world
  end

  defp applied(world, :plan, :error),
    do: %{world | fold: History.stop(world.fold, "the project's threads could not be listed")}

  defp applied(world, :plan, {ids, skipped}),
    do: %{world | fold: History.planned(world.fold, ids, skipped)}

  defp applied(world, {:page, thread, _after}, :error) do
    lost = for {run, ^thread, :old} <- world.runs, run not in world.offered, do: run
    %{world | fold: History.unreadable(world.fold), lost: world.lost ++ lost}
  end

  defp applied(world, {:page, _thread, _after}, {runs, more}) do
    fold = world.fold
    held = History.held(fold)
    ended = Map.new(world.runs, fn {run, _thread, _} -> {run, at(clock_of(run))} end)
    kept = Enum.filter(runs, &(&1 not in held and History.imported?(fold, ended[&1])))

    %{
      world
      | offered: world.offered ++ kept,
        fold: History.paged(fold, length(kept), List.last(runs), more)
    }
  end

  defp applied(world, {:pending, entries}, :error) do
    lost = Enum.map(entries, fn [_thread, run, _ids] -> run end)
    %{world | fold: History.drained(world.fold, entries, 0), lost: world.lost ++ lost}
  end

  defp applied(world, {:pending, entries}, entries) do
    runs = Enum.map(entries, fn [_thread, run, _ids] -> run end)

    %{
      world
      | offered: world.offered ++ runs,
        fold: History.drained(world.fold, entries, length(runs))
    }
  end

  defp clock_of("r" <> n), do: String.to_integer(n)

  defp tick(world), do: %{world | clock: world.clock + 1}
  defp at(clock), do: @base |> DateTime.add(clock, :second) |> DateTime.to_iso8601()

  defp put(world) do
    fold = world.fold || %{}

    world = %{
      world
      | stopped: world.stopped or fold["state"] == "stopped" or Map.has_key?(fold, "stop")
    }

    Process.put(:world, world)
    world
  end
end

defmodule HalC2.TokenEconomizerHistorySeedPropTest do
  @moduledoc """
  What the first fold from history seeds the loop guard's envelope with
  (`History.claim/2`, `seed/4`, `record_turn/3`, `unseed/2`), over pages of
  imported green turns, pages read again after a crash, live turns recorded
  meanwhile, and the tracker saved and loaded back, in any order. Whatever
  the order, the envelope holds each page's turns once, in the order read,
  ahead of the live turns, in the order they ended; and taking the seed back
  out leaves exactly the live turns.
  """
  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2Plugins.TokenEconomizer.LoopGuard.{Envelope, Turn}
  alias HalC2Plugins.TokenEconomizer.MicroSkills.History

  property "the envelope holds the imported turns once, ahead of the live ones, until unseeded",
    numtests: HalC2.Prop.numtests(300) do
    forall ops <- list(frequency([{3, :page}, {2, :again}, {3, :live}, {1, :restart}])) do
      fold = History.new("f", "2026-11-09T12:00:00Z")

      {tracker, _step, seeded, live} =
        Enum.reduce(ops, {Envelope.new(), -1, [], []}, fn
          :page, {tracker, step, seeded, live} ->
            samples = samples(step + 1)
            tracker = History.seed(tracker, "f", step + 1, samples)
            {tracker, step + 1, seeded ++ Enum.map(samples, & &1["turns"]), live}

          :again, {tracker, step, seeded, live} ->
            {History.seed(tracker, "f", max(step, 0), samples(max(step, 0))), step, seeded, live}

          :live, {tracker, step, seeded, live} ->
            {g, _, _} = Turn.fold(Turn.new(), "Bash", %{"command" => "pytest -q"}, "3 passed", 0)
            tracker = tracker |> History.claim(fold) |> History.record_turn(g, true)
            {tracker, step, seeded, live ++ [1]}

          :restart, {tracker, step, seeded, live} ->
            saved = tracker[:seed] |> JSON.encode!() |> JSON.decode!()
            {Map.put(tracker, :seed, History.load_seed(saved)), step, seeded, live}
        end)

      unseeded = History.unseed(tracker, "f")

      (tracker.resolved_turns == seeded ++ live and
         length(tracker.resolved_snaps) == length(tracker.resolved_turns) and
         unseeded.resolved_turns == live and History.seedable(tracker, "f") == :seeding)
      |> when_fail(
        IO.puts("""
        Ops: #{inspect(ops)}
        Turns: #{inspect(tracker.resolved_turns)}
        Seed: #{inspect(tracker[:seed])}
        Unseeded: #{inspect(unseeded.resolved_turns)}
        """)
      )
    end
  end

  # A page's green turns: told apart from the live ones (1) and from each
  # other page's, and the same each time the page is read.
  defp samples(step) do
    sample =
      History.replay(
        [{"Bash", %{"command" => "pytest -q"}, "3 passed", 0}],
        "completed",
        "default",
        %{}
      )

    for n <- 1..rem(step, 3)//1, do: %{sample | "turns" => 100 + step * 10 + n}
  end
end

defmodule HalC2.TokenEconomizerProposerPropTest do
  @moduledoc """
  The paid proposer's laws (`plugins/token-economizer/mc/micro_skills_distiller.ex`),
  over one project's turns, the model's replies (facts and extractors, well or badly
  made, citing turns in the window or long gone), drops, restores, renders with the
  proposer on or off, and restarts, in any order. Whatever the order:

    * a fact enters only from a reply, never from a turn, and only when its
      detector confirms it on at least `Distiller.min_cite/0` distinct turns it
      cites that are still in the window;
    * a reply admits at most `Distiller.max_cands/0` facts, and what it does not
      admit or revise is left exactly as it was;
    * a proposed fact may be revised only in its contradiction condition: its
      revision counts up by one and what it earned is kept;
    * a dropped id is never admitted, however often the model proposes it, until
      restored;
    * extractors are append-only and at most `Distiller.max_extractors/0`;
    * the window holds at most `Distiller.window_size/0` turns, and a turn folds once;
    * a proposal is due exactly when the window holds a turn and `every` turns have
      passed since the last, so a model is never asked twice in fewer;
    * with the proposer off its facts are kept but never staged;
    * saving and loading changes nothing.

  The model call around these, off the plugin's process, and what the plugin does
  with an answer that fails or never comes, are
  `features/plugins/token-economizer-micro-skills.feature`.
  """
  use ExUnit.Case, async: true
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.TokenEconomizer.MicroSkills.{Distiller, EnvFacts}

  @ids ~w(build-first tests-as-module lint-here)
  @manual "# repo operating manual"

  property "the proposer admits only what its detector grounds, in any order",
    numtests: HalC2.Prop.numtests(200) do
    forall cmds <- more_commands(4, commands(__MODULE__, initial_state())) do
      Process.put(:skills, EnvFacts.new(proposing: true))
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

  # The model: the cadence only -- turns folded, the turn of the last proposal, and
  # the reused runs folded. What a reply admits is checked against the state before it.
  def initial_state, do: %{turns: 0, last: -1, folded: MapSet.new()}

  def command(_state) do
    frequency([
      {8,
       {:call, __MODULE__, :turn,
        [
          elements([:build_test, :build_test, :test_only, :pytest_broken, :regen, :none]),
          elements([:fresh, :fresh, "run-a", "run-b"])
        ]}},
      {5, {:call, __MODULE__, :propose, [integer(1, 4), reply()]}},
      {1, {:call, __MODULE__, :drop, [elements(@ids)]}},
      {1, {:call, __MODULE__, :restore, [elements(@ids)]}},
      {2, {:call, __MODULE__, :render, [boolean()]}},
      {2, {:call, __MODULE__, :restart, []}}
    ])
  end

  defp reply do
    frequency([
      {1, :garbage},
      {6,
       {resize(5, list(fact_spec())),
        resize(2, list({elements(~w(built regen bad-name)), elements([:ok, :bad])}))}}
    ])
  end

  defp fact_spec do
    {elements(@ids),
     elements([:build, :build, :build_contra, :module, :tests_pred, :built_feature, :bad]),
     resize(4, list(oneof([integer(0, 9), :gone]))), elements([:ok, :ok, :ok, :lint])}
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :turn, [_kind, run]}) do
    if run != :fresh and MapSet.member?(state.folded, run) do
      state
    else
      folded = if run == :fresh, do: state.folded, else: MapSet.put(state.folded, run)
      %{state | folded: folded, turns: state.turns + 1}
    end
  end

  def next_state(state, _result, {:call, _, :propose, [every, _reply]}),
    do: if(due?(state, every), do: %{state | last: state.turns}, else: state)

  def next_state(state, _result, _call), do: state

  defp due?(state, every), do: state.turns > 0 and state.turns - state.last >= every

  # --- the commands at work ---------------------------------------------------------------------

  def turn(kind, run) do
    before = Process.get(:skills)
    iid = if run == :fresh, do: "run-#{System.unique_integer([:positive])}", else: run
    calls = calls(kind)

    after_turn =
      before |> Distiller.fold(calls, iid) |> EnvFacts.update_turn(calls, iid)

    Process.put(:skills, after_turn)
    %{before: before, after: after_turn, reused: run != :fresh and iid in before.folded}
  end

  # Asks when due, as the plugin does, and admits the reply against the window as
  # it is then. The reply's citations are read against that window: 0 is the newest
  # turn in it, and a position past it (or `:gone`) names a turn long gone.
  def propose(every, reply) do
    before = Process.get(:skills)
    due = Distiller.due?(before, every)

    if due do
      raw = raw(reply, before)
      asked = Distiller.proposed(before)
      {after_admit, outcomes} = Distiller.admit(asked, raw)
      Process.put(:skills, after_admit)

      %{
        before: before,
        asked: asked,
        after: after_admit,
        due: true,
        raw: raw,
        outcomes: outcomes
      }
    else
      %{before: before, after: before, due: false, outcomes: []}
    end
  end

  def drop(id) do
    before = Process.get(:skills)

    after_drop =
      case EnvFacts.drop(before, id) do
        {:ok, skills} -> skills
        {:error, _} -> before
      end

    Process.put(:skills, after_drop)
    %{before: before, after: after_drop}
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

  # What would be staged with the proposer on or off; rendering marks what was
  # staged, so the state is left as it was.
  def render(proposing) do
    skills = Process.get(:skills)
    {text, _} = EnvFacts.render(%{skills | proposing: proposing})
    %{skills: skills, text: text, proposing: proposing}
  end

  def restart do
    before = Process.get(:skills)

    loaded =
      before
      |> EnvFacts.dump()
      |> JSON.encode!()
      |> JSON.decode!()
      |> EnvFacts.load(proposing: true)

    Process.put(:skills, loaded)
    %{before: before, after: loaded}
  end

  defp bash(command, output, code \\ 0), do: {"Bash", %{"command" => command}, output, code}
  defp edit(path), do: {"Edit", %{"file_path" => path}, "ok", nil}

  defp calls(:build_test),
    do: [edit("src/m.go"), bash("make build", "built"), bash("make test", "ok  ./... 0.01s")]

  defp calls(:test_only),
    do: [bash("make test", "make: *** No rule to make target 'build'.  Stop.", 2)]

  defp calls(:pytest_broken),
    do: [
      edit("pkg/a.py"),
      bash("pytest -q", "bash: pytest: command not found", 127),
      bash("python -m pytest -q", "4 passed in 0.01s")
    ]

  defp calls(:regen), do: [bash("./scripts/regen-protos.sh --all", "done")]
  defp calls(:none), do: []

  @detectors %{
    build: %{"scope" => "make test", "confirm" => "make build"},
    build_contra: %{
      "scope" => "make test",
      "confirm" => "make build",
      "contradict" => "No rule to make target"
    },
    module: %{"scope" => "pytest", "confirm" => "python -m pytest"},
    tests_pred: %{"scope" => "ran_tests", "confirm" => "passed", "fired" => "ran_tests"},
    built_feature: %{"scope" => "built", "confirm" => "make build"},
    bad: %{"scope" => "make test", "confirm" => "make (build"}
  }

  defp raw(:garbage, _skills), do: "claude payload"

  defp raw({facts, extractors}, skills) do
    window = skills.proposer.window |> Enum.map(& &1["iid"]) |> Enum.reverse()

    facts =
      for {id, detector, cites, line} <- facts do
        %{
          "id" => id,
          "claim" => "#{id} holds here",
          "injection" =>
            if(line == :lint,
              do: "Skip the tests once `make build` passes.",
              else: "In this repository, #{id}."
            ),
          "detector" => @detectors[detector],
          "cite" =>
            Enum.map(cites, fn
              :gone -> "gone"
              k -> Enum.at(window, k) || "gone-#{k}"
            end)
        }
      end

    extractors =
      for {name, pattern} <- extractors do
        %{
          "name" => name,
          "kind" => "out_regex",
          "pattern" => if(pattern == :ok, do: "^built$", else: "(built")
        }
      end

    JSON.encode!(%{"facts" => facts, "extractors" => extractors})
  end

  # --- the laws -------------------------------------------------------------------------------------

  def postcondition(state, {:call, _, :turn, [_kind, _run]}, %{before: before, after: skills} = r) do
    after_state =
      if r.reused, do: state, else: next_state(state, nil, {:call, nil, :turn, [nil, :fresh]})

    # A turn folded twice changes nothing; a turn never brings a proposed fact in,
    # nor changes what one says.
    (not r.reused or skills == before) and
      skills.proposer.turns == after_state.turns and
      MapSet.equal?(proposed_ids(skills), proposed_ids(before)) and
      Enum.all?(proposed_ids(skills), &(skills.facts[&1].params == before.facts[&1].params)) and
      lawful?(skills)
  end

  def postcondition(state, {:call, _, :propose, [every, reply]}, %{due: due} = r) do
    due == due?(state, every) and
      if due do
        admitted?(r, reply) and r.after.proposer.last_propose == r.after.proposer.turns and
          not Distiller.due?(r.after, every) and lawful?(r.after)
      else
        r.after == r.before
      end
  end

  def postcondition(_state, {:call, _, :drop, [id]}, %{before: before, after: skills}) do
    lawful?(skills) and
      (not Map.has_key?(before.facts, id) or
         (not Map.has_key?(skills.facts, id) and MapSet.member?(skills.dropped, id)))
  end

  def postcondition(_state, {:call, _, :restore, [id]}, %{after: skills}),
    do: lawful?(skills) and not MapSet.member?(skills.dropped, id)

  def postcondition(_state, {:call, _, :render, _}, %{proposing: false} = r) do
    proposed = Enum.map(proposed_ids(r.skills), &r.skills.facts[&1].params["injection"])

    not String.contains?(r.text, @manual) and
      Enum.all?(proposed, &(not String.contains?(r.text, &1)))
  end

  def postcondition(_state, {:call, _, :render, _}, %{text: text}),
    do: text == "" or String.length(text) <= 150 * 4 + 1

  def postcondition(_state, {:call, _, :restart, _}, %{before: before, after: skills}) do
    EnvFacts.dump(skills) == EnvFacts.dump(before) and
      Distiller.due?(skills, 1) == Distiller.due?(before, 1) and lawful?(skills)
  end

  # What a reply did, item by item, against the state it was read in.
  defp admitted?(r, reply) do
    asked = r.asked
    skills = r.after
    facts = r.outcomes |> Enum.filter(&match?({:fact, _, _}, &1))
    specs = r.raw |> Distiller.parse_payload() |> elem(1)
    changed = for {:fact, id, reason} <- facts, reason in ~w(admitted revised), do: id

    # One outcome per fact asked, in order, up to the cap; a reply may name an id twice.
    read = Enum.take(specs, Distiller.max_cands())
    count_ok = length(facts) == length(read)
    garbage_ok = reply != :garbage or r.outcomes == []

    admitted_ok =
      facts
      |> Enum.zip(read)
      |> Enum.reduce_while(MapSet.new(), fn {outcome, spec}, earlier ->
        if lawful_outcome?(outcome, spec, asked, skills, earlier) do
          {:cont,
           if(match?({:fact, _, "admitted"}, outcome),
             do: MapSet.put(earlier, spec["id"]),
             else: earlier
           )}
        else
          {:halt, false}
        end
      end)
      |> Kernel.!=(false)

    # What was not admitted or revised is exactly as it was.
    rest_ok =
      MapSet.equal?(
        MapSet.new(Map.keys(skills.facts)),
        MapSet.union(MapSet.new(Map.keys(asked.facts)), MapSet.new(changed))
      ) and
        Enum.all?(asked.facts, fn {id, fact} -> id in changed or skills.facts[id] == fact end)

    extractors_ok =
      Enum.all?(asked.proposer.extractors, fn {name, spec} ->
        skills.proposer.extractors[name] == spec
      end)

    count_ok and garbage_ok and admitted_ok and rest_ok and extractors_ok and
      skills.dropped == asked.dropped
  end

  # Each admitted fact was new, not dropped, and grounded on two distinct turns still
  # in the window that its own detector confirms; a revision keeps the fact's life
  # and changes only its contradict condition.
  defp lawful_outcome?({:fact, id, "admitted"}, spec, asked, skills, earlier) do
    id == spec["id"] and not Map.has_key?(asked.facts, id) and
      not MapSet.member?(earlier, id) and not MapSet.member?(asked.dropped, id) and
      grounded(skills, spec) >= Distiller.min_cite() and
      skills.facts[id].family == Distiller.family()
  end

  # A fact admitted earlier in the same reply has no state of its own to compare against.
  defp lawful_outcome?({:fact, id, "revised"}, spec, asked, skills, earlier) do
    now = skills.facts[id]

    case asked.facts[id] do
      nil ->
        id == spec["id"] and MapSet.member?(earlier, id) and now.params["rev"] >= 2

      was ->
        id == spec["id"] and was.family == Distiller.family() and now.life == was.life and
          now.params["rev"] > was.params["rev"] and
          Map.delete(now.params["detector"], "contradict") ==
            Map.delete(was.params["detector"], "contradict") and
          Map.drop(now.params, ~w(detector rev)) == Map.drop(was.params, ~w(detector rev))
    end
  end

  defp lawful_outcome?({:fact, id, "dropped"}, _spec, asked, skills, _earlier),
    do: MapSet.member?(asked.dropped, id) and not Map.has_key?(skills.facts, id)

  defp lawful_outcome?({:fact, _id, _refused}, _spec, _asked, _skills, _earlier), do: true

  # The cited turns, still in the window, the detector confirms on: read with the
  # window as admitted against (its features include extractors the reply added).
  defp grounded(skills, spec) do
    detector =
      for {key, value} <- spec["detector"],
          is_binary(value) and value != "",
          into: %{},
          do: {key, value}

    cited = MapSet.new(spec["cite"] || [])

    skills.proposer.window
    |> Enum.filter(&MapSet.member?(cited, &1["iid"]))
    |> Enum.count(&(Distiller.verdict(detector, &1) |> elem(0) == "confirm"))
  end

  defp proposed_ids(skills),
    do: for({id, fact} <- skills.facts, Distiller.fact?(fact), into: MapSet.new(), do: id)

  # What holds after every command: no dropped id among the facts, the window and the
  # extractors within their caps.
  # The proposer is made by the first turn folded, so before it there is none.
  defp lawful?(skills) do
    MapSet.disjoint?(skills.dropped, MapSet.new(Map.keys(skills.facts))) and
      case skills.proposer do
        nil ->
          true

        proposer ->
          length(proposer.window) <= Distiller.window_size() and
            length(proposer.window) == min(proposer.turns, Distiller.window_size()) and
            map_size(proposer.extractors) <= Distiller.max_extractors()
      end
  end
end

defmodule HalC2.TokenEconomizerHeldPropTest do
  @moduledoc """
  A state machine model of a held project (`HalC2Plugins.TokenEconomizer`):
  one whose saved micro-skills file does not read, found so by an MC
  restarting over it, driven through turns, forgetting, settings saves
  switching learning and the history import, and the file repaired under
  the running process. Whatever the order, after every step:

    * a project is held exactly while its file does not read, and is read
      again, and learned from, at its first use after it is repaired;
    * a held project has no fold from history and learns from no turn, and
      its file keeps its bytes;
    * forgetting a held project is refused, saying it is held; forgetting one
      that reads is not;
    * a turn in a project that reads, with learning and the import on, leaves
      it a fold, so the hold is what keeps a held one from folding;
    * once the project's entry is published, the last `microSkillsProjects`
      naming it says held as that entry does, so a page listing the projects
      lists it, held or not; and no process names it twice saying the same.
  """
  # The plugin keeps the micro-skills under the MC's home, which a scratch
  # home sets for the whole VM.
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.TokenEconomizer
  alias HalC2Plugins.TokenEconomizer.MicroSkills.EnvFacts

  @garbled "{\"facts\": not json"

  property "a held project folds nothing, is never forgotten, and keeps its file until it reads",
    numtests: HalC2.Prop.numtests(150) do
    forall cmds <- more_commands(4, commands(__MODULE__)) do
      home = HalC2.Prop.scratch_home("token-economizer-held")
      readable()
      # The test stands in for the plugin host, which publishes what it is cast.
      Process.register(self(), HalC2.Plugins)
      {:ok, plugin} = TokenEconomizer.init(settings(initial_state()))
      Process.put(:plugin, plugin)
      {history, state, result} = run_commands(__MODULE__, cmds)
      stop(Process.delete(:plugin))
      Process.unregister(HalC2.Plugins)
      Enum.each([:entry_held, :pulsed, :listed, :repeated], &Process.delete/1)
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

  # The model: the settings in force, and whether project `p`'s file does not read.
  def initial_state, do: %{micro: "envfacts", import: true, held: false}

  def command(state) do
    frequency(
      [
        {2, {:call, __MODULE__, :settings, [elements(~w(off envfacts on)), boolean()]}},
        {5, {:call, __MODULE__, :turn, []}},
        {3, {:call, __MODULE__, :forget, []}},
        {2, {:call, __MODULE__, :garble, []}},
        {1, {:call, __MODULE__, :restart, []}}
      ] ++ if(state.held, do: [{2, {:call, __MODULE__, :repair, []}}], else: [])
    )
  end

  def precondition(state, {:call, _, :repair, []}), do: state.held
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :settings, [micro, import]}),
    do: %{state | micro: micro, import: import}

  def next_state(state, _result, {:call, _, :garble, []}), do: %{state | held: true}
  def next_state(state, _result, {:call, _, :repair, []}), do: %{state | held: false}
  def next_state(state, _result, _call), do: state

  def postcondition(state, call, seen) do
    state = next_state(state, seen, call)

    common =
      if state.held,
        do:
          seen.entry["held"] =~ "not valid JSON" and seen.entry["file"] == path() and
            seen.fold == nil and seen.entry["turns"] == 0 and seen.file == @garbled,
        else: seen.entry["held"] == nil and not Map.has_key?(seen.entry, "file")

    common and called(state, call, seen) and listed?(seen)
  end

  # The page's two topics agree: the listing names `p` as its entry shows it.
  defp listed?(%{entry_held: entry_held, listed: listed, repeated: repeated}),
    do: (entry_held == :none or listed == entry_held) and not repeated

  defp called(state, {:call, _, :forget, []}, %{reply: reply}) do
    case {state.held, reply} do
      {true, {:error, message}} -> message =~ "held" and message =~ "not valid JSON"
      {false, {:ok, _view}} -> true
      _ -> false
    end
  end

  defp called(state, {:call, _, :turn, []}, %{fold: fold}) do
    if not state.held and state.micro != "off" and state.import, do: fold != nil, else: true
  end

  defp called(_state, _call, _seen), do: true

  # --- the commands, against the process's callbacks ---------------------------------------

  defp settings(state),
    do: %{
      "microSkills" => state.micro,
      "historyImport" => state.import,
      "microSkillsProposeEvery" => 1000
    }

  def settings(micro, import) do
    {:reply, :ok, plugin} =
      TokenEconomizer.handle_call(
        {:settings, settings(%{micro: micro, import: import})},
        nil,
        Process.get(:plugin)
      )

    seen(plugin)
  end

  # A turn in project `p` that would teach a fact: started, one call, finished.
  def turn do
    run = "run-#{System.unique_integer([:positive])}"
    at = %{"threadId" => "a", "runId" => run}

    observe(
      Map.merge(at, %{
        "type" => "turn.started",
        "projectId" => "p",
        "provider" => "claudeAgent",
        "newConversation" => true
      })
    )

    observe(
      Map.merge(at, %{
        "type" => "turn.item",
        "itemType" => "command_execution",
        "status" => "completed",
        "input" => "pytest -q",
        "output" => "3 passed in 0.10s",
        "exitCode" => 0
      })
    )

    observe(Map.merge(at, %{"type" => "turn.finished", "ordinal" => 1, "status" => "completed"}))
    seen(Process.get(:plugin))
  end

  def forget do
    {:reply, reply, plugin} =
      TokenEconomizer.handle_call(
        {:micro_skill_forget, %{"projectId" => "p"}},
        nil,
        Process.get(:plugin)
      )

    plugin |> seen() |> Map.put(:reply, reply)
  end

  # The MC restarts over a file that no longer reads.
  def garble do
    File.write!(path(), @garbled)
    restart()
  end

  # The file reads again, under the running process.
  def repair do
    readable()
    seen(Process.get(:plugin))
  end

  # The MC restarts: the process starts afresh from what it saved, with the
  # settings it had.
  def restart do
    old = Process.get(:plugin)
    stop(old)
    published()
    # A new process names each project afresh.
    Process.delete(:pulsed)
    {:ok, plugin} = TokenEconomizer.init(old.settings)
    seen(plugin)
  end

  # Project `p` has learned a fact, so the import has nothing to read: a fold
  # it starts is skipped at once, and no read leaves the process.
  defp readable do
    skills =
      EnvFacts.add_candidate(EnvFacts.new(), %{
        id: "form_repair:run_tests:pytest",
        family: "form_repair",
        high: false,
        drift: false,
        params: %{
          "intent" => "run_tests",
          "a" => "pytest",
          "b_counts" => %{"python -m pytest" => 3},
          "error_counts" => %{}
        }
      })

    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), JSON.encode!(Map.put(EnvFacts.dump(skills), "projectId", "p")))
  end

  defp path, do: TokenEconomizer.micro_skills_path("p")

  defp observe(event) do
    {:reply, :ok, plugin} =
      TokenEconomizer.handle_call({:observe, event}, nil, Process.get(:plugin))

    Process.put(:plugin, plugin)
  end

  # What a person would see of project `p`, looked at without keeping what
  # looking loads, its fold, and its file's bytes.
  # Also what its two topics last said, as a page would have them.
  defp seen(plugin) do
    Process.put(:plugin, plugin)
    published()

    {:reply, {:ok, %{"projects" => [entry]}}, _} =
      TokenEconomizer.handle_call({:micro_skills, %{"projectId" => "p"}}, nil, plugin)

    %{
      entry: entry,
      fold: plugin.folds["p"],
      file: File.read!(path()),
      entry_held: Process.get(:entry_held, :none),
      listed: Process.get(:listed, :none),
      repeated: Process.get(:repeated, false)
    }
  end

  # Takes what the plugin published since, in order.
  defp published do
    receive do
      {:"$gen_cast", {:publish, "token-economizer", "microSkills:p", entry}} ->
        Process.put(:entry_held, entry["held"] != nil)
        published()

      {:"$gen_cast", {:publish, "token-economizer", "microSkillsProjects", named}} ->
        %{"projectId" => "p", "held" => held} = named
        if Process.get(:pulsed) == held, do: Process.put(:repeated, true)
        Process.put(:pulsed, held)
        Process.put(:listed, held)
        published()

      {:"$gen_cast", {:publish, "token-economizer", _topic, _value}} ->
        published()
    after
      0 -> :ok
    end
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
      {kind, _, _, _, _} when kind in [:history, :verdict, :delivered, :DOWN] -> flush()
      {:proposed, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end
