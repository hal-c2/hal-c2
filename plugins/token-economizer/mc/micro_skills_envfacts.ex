# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported in part from tokeneconomizer/microskills/envfacts.py and
# tokeneconomizer/microskills/stage.py (the render-before / fold-after shape,
# here the plugin process's `shape_run/2` and turn close), and
# tokeneconomizer/plugin/fold.py (a turn folded once, keyed by its run id)
# (microsoft/TokenEconomizer@cb42207e3e09). Changed: a pure struct the plugin
# keeps per project and saves as JSON, fed a turn's calls instead of a
# transcript path; the paid distiller is not ported yet, so the composed stage
# is only this layer -- a later proposer adds its candidates through
# `add_candidate/2` and the same lifecycle. A person may drop a fact (it is
# then not learned again) and restore it, which upstream had no way to do.

defmodule HalC2Plugins.TokenEconomizer.MicroSkills.EnvFacts do
  @moduledoc """
  Environment facts: micro-skills learned for free from recurring failures.

  As a project's turns finish, this looks for recurring shapes of evidence
  that an agent rediscovers the same environment fact by failing at it, turn
  after turn. When a shape recurs, it becomes a one-line declarative fact,
  staged ahead of the first message of the next conversation. Every specific
  string in a rendered fact -- an interpreter path, a runner form, a refused
  host -- is a parameter learned from the turns; nothing here names a path, an
  environment manager or a project.

  The families (upstream's, under its generic reading):

    * form repair: form A of an intent fails with an infrastructure error and
      a later form B succeeds. "`A ...` fails here with <error>; `B ...` works."
    * boundary: every fetch fails with one environmental error and none
      succeeds. "Connections to <hosts> are refused here."
    * empty probe: VCS probes beyond the checkout return nothing every time.
    * arg repair: the test runner loads a label only rewritten another way.
    * env value: code asks for an environment variable; a later run setting
      it succeeds.
    * absent tool: a bare tool is not found and no way of running it works.

  Each fact goes through the shared `MicroSkills.Lifecycle`. No model is
  involved. The staged block is capped at `max_facts` and `max_tokens`, and a
  lint refuses any fact that reads as completion or verification advice.
  """

  alias HalC2Plugins.TokenEconomizer.MicroSkills.{Lifecycle, Observe}

  @max_facts 4
  @max_tokens 150
  @header "# environment facts learned from earlier sessions in this repository"
  # FormRepair: consecutive contradicted turns before one counts.
  @contradict_streak 2
  # Run ids remembered as folded, so a turn is never counted twice.
  @folded_kept 100

  # Words that would turn a fact into completion or verification advice.
  @lint_re ~r/\b(skip|no need|don'?t|do not|stop|done|completed?|finish(?:ed)?|verify|verification|instead of (?:running|testing))\b/i

  @error_phrase %{
    "module_missing" => "ModuleNotFoundError",
    "command_missing" => "command not found",
    "script_missing" => "a file-not-found error",
    "usage_error" => "a usage error",
    "permission_denied" => "permission denied"
  }

  defmodule Fact do
    @moduledoc "One learned fact: a family, its learned parameters, and its lifecycle."
    defstruct [:id, :family, params: %{}, life: nil]
  end

  defstruct now: 0,
            facts: %{},
            last_injected: MapSet.new(),
            last_digest: nil,
            max_facts: @max_facts,
            max_tokens: @max_tokens,
            # Ids a person dropped: not learned again until restored.
            dropped: MapSet.new(),
            # The run ids of the turns folded, newest first.
            folded: []

  @doc "The header of the staged block."
  def header, do: @header
  def max_facts, do: @max_facts
  def max_tokens, do: @max_tokens

  def new(opts \\ []) do
    %__MODULE__{
      max_facts: cap(Keyword.get(opts, :max_facts), @max_facts),
      max_tokens: cap(Keyword.get(opts, :max_tokens), @max_tokens)
    }
  end

  defp cap(value, _default) when is_integer(value) and value > 0, do: value
  defp cap(_value, default), do: default

  # --- candidates: the seam every proposer uses -------------------------------------

  @doc """
  Adds a candidate fact `{id, family, high, drift, params}` if there is none
  with its id and a person has not dropped it. The families below add theirs
  this way (an environment fact never drifts: whether `pytest` is missing does
  not depend on which file a turn edits); a later proposer adds its own
  through the same door and the same lifecycle.
  """
  def add_candidate(%__MODULE__{} = state, %{id: id} = candidate) do
    if Map.has_key?(state.facts, id) or MapSet.member?(state.dropped, id) do
      state
    else
      fact = %Fact{
        id: id,
        family: candidate.family,
        params: candidate.params || %{},
        life: Lifecycle.new(id, candidate.high, Map.get(candidate, :drift, false))
      }

      put_in(state.facts[id], fact)
    end
  end

  defp ensure_fact(state, id, family, high, params) do
    add_candidate(state, %{id: id, family: family, high: high, drift: false, params: params})
  end

  # --- rendering ----------------------------------------------------------------------

  @doc """
  The block staged for the next conversation, and the state remembering what
  it chose (`injected_ids/1`), so the turns that follow it can count the waste
  it prevented as firing.
  """
  def render(%__MODULE__{} = state) do
    chosen = select(state)
    state = %{state | last_injected: MapSet.new(chosen, & &1.id)}
    {render_text(chosen), state}
  end

  defp render_text([]), do: ""

  defp render_text(chosen) do
    lines = [@header | Enum.map(merged_lines(chosen), &"- #{&1}")]
    Enum.join(lines, "\n") <> "\n"
  end

  @doc "The ids of the facts the last `render/1` chose: what the next conversation is given."
  def injected_ids(%__MODULE__{} = state),
    do: state.last_injected |> MapSet.to_list() |> Enum.sort()

  @doc """
  Says which facts the turn about to be folded was actually given. Rendering
  happens as a conversation starts and folding as its turns end, so the plugin
  seeds the fold with the staged ids, or a staged fact never counts as having
  fired and decays out of the block while it works.
  """
  def seed_injected(%__MODULE__{} = state, ids) do
    %{
      state
      | last_injected:
          MapSet.new(ids || [], & &1) |> MapSet.filter(&Map.has_key?(state.facts, &1))
    }
  end

  @doc "The claims that would be staged now, one string each (no header)."
  def injectable_claims(%__MODULE__{} = state), do: Enum.map(select(state), &claim/1)

  defp select(%__MODULE__{} = state) do
    prio = %{
      "form_repair" => 0,
      "arg_repair" => 1,
      "env_value" => 2,
      "absent_tool" => 3,
      "empty_probe" => 4,
      "boundary" => 5
    }

    candidates =
      state.facts
      |> Map.values()
      |> Enum.filter(fn fact ->
        Lifecycle.injectable?(fact.life) and claim(fact) != "" and lint_ok?(claim(fact))
      end)
      |> Enum.sort_by(fn fact ->
        {Map.get(prio, fact.family, 9),
         if(fact.params["intent"] == "run_interpreter", do: 0, else: 1),
         -Lifecycle.firing_rate(fact.life), fact.id}
      end)

    Enum.reduce_while(candidates, [], fn fact, chosen ->
      trial = chosen ++ [fact]

      cond do
        length(trial) > state.max_facts ->
          {:halt, chosen}

        String.length(
          @header <> "\n" <> Enum.join(Enum.map(merged_lines(trial), &"- #{&1}"), "\n")
        ) >
            state.max_tokens * 4 ->
          {:cont, chosen}

        true ->
          {:cont, trial}
      end
    end)
  end

  # FormRepair facts whose working forms share a root (the same activation
  # prefix or the same directory) collapse into one line: they are one
  # environment fact. Those lines go ahead of the others.
  defp merged_lines(facts) do
    {repairs, others} = Enum.split_with(facts, &(&1.family == "form_repair"))

    groups =
      Enum.reduce(repairs, [], fn fact, groups ->
        root = root_of(working_form(fact) || "")

        case Enum.find_index(groups, fn {key, _} -> key == root end) do
          nil -> groups ++ [{root, [fact]}]
          i -> List.update_at(groups, i, fn {key, grouped} -> {key, grouped ++ [fact]} end)
        end
      end)

    repair_lines =
      groups
      |> Enum.map(fn
        {_root, [fact]} ->
          claim(fact)

        {_root, grouped} ->
          a_forms = join(Enum.map(grouped, &usage(&1.params["a"])))

          errors =
            grouped
            |> Enum.map(&Map.get(@error_phrase, best(&1, "error_counts") || "", ""))
            |> Enum.uniq()
            |> Enum.sort()
            |> Enum.reject(&(&1 == ""))

          bs = grouped |> Enum.map(&usage(working_form(&1))) |> Enum.uniq() |> Enum.sort()

          "#{a_forms} fail here (#{Enum.join(errors, ", ") |> empty_as("environment error")}); " <>
            "#{join(bs)} #{if length(bs) == 1, do: "works", else: "work"}."
      end)
      |> Enum.reverse()

    repair_lines ++ Enum.map(others, &claim/1)
  end

  defp empty_as("", fallback), do: fallback
  defp empty_as(text, _fallback), do: text

  # --- claims ---------------------------------------------------------------------------

  @doc "The one line a fact states, or \"\" when it makes no claim (yet)."
  def claim(%Fact{family: "form_repair"} = fact) do
    case working_form(fact) do
      nil ->
        ""

      working ->
        error = best(fact, "error_counts") || "module_missing"

        "#{usage(fact.params["a"])} fails here with #{Map.get(@error_phrase, error, error)}; " <>
          "#{usage(working)} works."
    end
  end

  def claim(%Fact{family: "boundary"} = fact) do
    hosts =
      (fact.params["hosts"] || %{})
      |> Enum.sort_by(fn {host, n} -> {-n, host} end)
      |> Enum.take(3)
      |> Enum.map(&elem(&1, 0))

    "Outbound connections to " <>
      join(hosts) <> " are refused here; nothing can be fetched from them."
  end

  def claim(%Fact{family: "arg_repair"} = fact) do
    params = fact.params

    if params["kind"] == "sep" do
      "#{usage(params["form"], "")} takes dotted test labels (`module.Class.test`, " <>
        "not `module::Class::test`)."
    else
      {a, b} =
        (params["examples"] || %{"x x" => 1})
        |> Map.keys()
        |> Enum.min_by(&example_rank/1)
        |> String.split(" ", parts: 2)
        |> List.to_tuple()
        |> then(fn
          {a, b} -> {a, b}
          {a} -> {a, ""}
        end)

      "#{usage(params["form"], "")} takes test labels without the `#{params["param"]}` prefix " <>
        "(`#{b}`, not `#{a}`)."
    end
  end

  def claim(%Fact{family: "env_value"} = fact) do
    good = best(fact, "good") || ""

    bad =
      (fact.params["bad"] || %{})
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reject(&(&1 == good))
      |> Enum.take(1)

    "Code that imports the project needs `#{fact.params["var"]}` set here: " <>
      "`#{fact.params["var"]}=#{good}` works" <>
      if(bad == [], do: ".", else: ", `#{hd(bad)}` does not.")
  end

  def claim(%Fact{family: "absent_tool"} = fact) do
    "`#{fact.params["tool"]} …` fails here with command not found, and no other way to run it has worked."
  end

  # Only what was probed is claimed: four empty `git remote` calls say
  # nothing about tags. `kinds` counts the probes by kind.
  def claim(%Fact{family: "empty_probe"} = fact) do
    surveyed =
      [
        {"remote", "no git remote"},
        {"branch", "no remote branches"},
        {"tag", "no tags pointing past the checked-out commit"},
        {"fsck", "no unreachable objects"},
        {"stash", "no stashes"},
        {"refs", "no refs beyond the checked-out commit"}
      ]
      |> Enum.filter(fn {kind, _} -> (fact.params["kinds"][kind] || 0) > 0 end)
      |> Enum.map(&elem(&1, 1))

    case surveyed do
      [] ->
        ""

      parts ->
        "Probes of this checkout found " <>
          join(parts) <>
          "; they have returned nothing every time."
    end
  end

  # A fact another proposer authored states its own claim.
  def claim(%Fact{} = fact), do: fact.params["claim"] || ""

  defp best(%Fact{} = fact, key) do
    case fact.params[key] || %{} do
      counts when map_size(counts) == 0 -> nil
      counts -> counts |> Enum.sort_by(fn {name, n} -> {-n, name} end) |> hd() |> elem(0)
    end
  end

  @doc """
  The working form a form-repair fact names: the one with the best record,
  turns it worked in as typed less turns it failed in -- among those that
  leave the shell where it is whenever one of them has a good record at all.
  Nil when no form has: then the fact makes no claim.
  """
  def working_form(%Fact{} = fact) do
    counts = fact.params["b_counts"] || %{}
    fails = fact.params["b_fails"] || %{}

    net =
      counts
      |> Enum.filter(fn {form, n} -> n > Map.get(fails, form, 0) end)
      |> Map.new(fn {form, n} -> {form, n - Map.get(fails, form, 0)} end)

    still = Map.reject(net, fn {form, _} -> moves_shell?(form) end)
    pool = if map_size(still) == 0, do: net, else: still

    if map_size(pool) == 0 do
      nil
    else
      pool
      |> Enum.sort_by(fn {form, n} -> {-n, -Map.get(counts, form, 0), form} end)
      |> hd()
      |> elem(0)
    end
  end

  @doc "Whether a line is a fact, not completion or verification advice."
  def lint_ok?(text), do: not Regex.match?(@lint_re, text || "")

  # --- the way back ----------------------------------------------------------------------

  @doc """
  Drops a fact at a person's word: it is gone, and it is not learned again
  until it is restored (`restore/2`), however much evidence for it recurs.
  """
  def drop(%__MODULE__{} = state, id) do
    cond do
      MapSet.member?(state.dropped, id) ->
        {:ok, state}

      Map.has_key?(state.facts, id) ->
        state = %{
          state
          | facts: Map.delete(state.facts, id),
            dropped: MapSet.put(state.dropped, id),
            last_injected: MapSet.delete(state.last_injected, id)
        }

        {:ok, state}

      true ->
        {:error, "There is no micro-skill #{id} on this project to drop."}
    end
  end

  @doc "Restores a dropped fact's id, so it may be learned again from new evidence."
  def restore(%__MODULE__{} = state, id) do
    if MapSet.member?(state.dropped, id) do
      {:ok, %{state | dropped: MapSet.delete(state.dropped, id)}}
    else
      {:error, "The micro-skill #{id} is not dropped on this project."}
    end
  end

  # --- what a client is shown ----------------------------------------------------------------

  @doc """
  The skills and facts of one project as the plugin's `microSkills` call and
  topic carry them: each with its state and the evidence behind it, what the
  next conversation would be staged, and what a person has dropped.
  """
  def view(%__MODULE__{} = state) do
    staged = select(state)
    staged_ids = MapSet.new(staged, & &1.id)

    %{
      "turns" => state.now,
      "staged" => render_text(staged),
      "skills" =>
        state.facts
        |> Map.values()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn fact ->
          %{
            "id" => fact.id,
            "family" => fact.family,
            "claim" => claim(fact),
            "state" => fact.life.state,
            "staged" => MapSet.member?(staged_ids, fact.id),
            "high" => fact.life.high,
            "evidence" => %{
              "confirms" => Lifecycle.drifted_confirms(fact.life),
              "contradicts" => Lifecycle.contradictions(fact.life),
              "fired" => fact.life.fire_num,
              "exercised" => fact.life.fire_den,
              "firingRate" => Lifecycle.firing_rate(fact.life)
            }
          }
        end),
      "dropped" => state.dropped |> MapSet.to_list() |> Enum.sort()
    }
  end

  # An arg repair keeps the one example its claim shows, the shortest label it
  # rewrote, and how often that one came back; every label it ever saw would
  # grow the stored fact with each new test file.
  defp keep_example(examples, key) do
    case Enum.min_by(Map.keys(examples), &example_rank/1, fn -> nil end) do
      nil ->
        %{key => 1}

      ^key ->
        %{key => examples[key] + 1}

      best ->
        if example_rank(key) < example_rank(best),
          do: %{key => 1},
          else: %{best => examples[best]}
    end
  end

  defp example_rank(key), do: {key |> String.split(" ", parts: 2) |> hd() |> String.length(), key}

  # --- helpers over forms ----------------------------------------------------------------------

  defp typed_ok?(o), do: Observe.form_worked(o) and not o.env

  @run_words ~w(run exec npx uv uvx pipx poetry pipenv conda mamba micromamba bundle yarn pnpm -m python python3)
  @script_runners ~w(npm bun)

  # Can `form` stand in for the failing `a_form`? Another form -- and, outside
  # test runs and builds, not a bare one. A build or check is repaired only by
  # the same tool spelled another way: `make build` does not repair `ruff`, nor
  # `cargo build`.
  defp repairs?(form, a_form, intent) do
    cond do
      form == a_form ->
        false

      intent == "run_build" ->
        build_tool(form) != nil and build_tool(form) == build_tool(a_form)

      true ->
        intent == "run_tests" or not Observe.bare?(form)
    end
  end

  # The tool a build form runs: its first word past the `cd x &&` and
  # activation prefixes and the launchers, by its basename. `./gradlew build`
  # and `gradlew build` run `gradlew`, `uv run ruff` and `.venv/bin/ruff` run
  # `ruff`, `npm run build` and `yarn build` both run the `build` script, and
  # `mise exec node@20 -- make build` runs `make`.
  defp build_tool(form) do
    form
    |> String.split(" && ")
    |> List.last()
    |> String.split(" -- ")
    |> List.last()
    |> String.split()
    |> Enum.map(&Path.basename/1)
    |> Enum.find(&(&1 not in @run_words and &1 not in @script_runners))
  end

  # The executable a form runs, by its last word.
  defp tool_of(form) do
    case String.split(form || "") do
      [] -> ""
      words -> words |> List.last() |> String.split("/") |> List.last()
    end
  end

  defp moves_shell?(form),
    do: String.starts_with?(form, "cd ") and String.contains?(form, " && ")

  # A form as a claim shows it. One that starts with `cd DIR &&` is shown as a
  # subshell, so an agent whose shell keeps its directory does not move it.
  defp usage(form, args \\ " …")

  defp usage(form, args) do
    if moves_shell?(form || ""), do: "`(#{form}#{args})`", else: "`#{form}#{args}`"
  end

  # The part of a working form that carries the environment: its activation
  # prefix, or the directory of its explicit path.
  defp root_of(form) do
    cond do
      String.contains?(form, " && ") ->
        form |> String.split(" && ", parts: 2) |> hd()

      Regex.match?(~r/^(?:conda|poetry|pipenv|uv|bundle|yarn|pnpm|pipx)\s+(?:run|exec)\b/, form) or
          String.starts_with?(form, "npx") ->
        form |> String.split() |> Enum.take(3) |> Enum.join(" ")

      true ->
        head = form |> String.split() |> List.first("")

        if String.contains?(head, "/") do
          head |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
        else
          head
        end
    end
  end

  defp join([]), do: "the hosts it tried"
  defp join([one]), do: one
  defp join(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)

  # Folds one turn's verdict into a fact's lifecycle. Two adjustments to the
  # shared state machine, upstream's: a high-stakes candidate that is
  # contradicted retires at once, and a form-repair contradiction counts only
  # after two consecutive exercised turns said so.
  defp fold_fact(%Fact{} = fact, now, verdict, fired, exercised, files) do
    {fact, verdict} =
      if fact.family == "form_repair" and exercised do
        streak = fact.params["contra_streak"] || 0
        streak = if verdict == "contradict", do: streak + 1, else: 0
        fact = put_in(fact.params["contra_streak"], streak)

        if verdict == "contradict" and streak < @contradict_streak,
          do: {fact, nil},
          else: {fact, verdict}
      else
        {fact, verdict}
      end

    fact = %{fact | life: Lifecycle.update(fact.life, now, verdict, fired, exercised, files)}

    if verdict == "contradict" and fact.life.high and fact.life.state == "CANDIDATE" do
      %{fact | life: %{fact.life | state: "RETIRED", retired_at: now}}
    else
      fact
    end
  end

  defp fold_family(state, family, now, files, verdicts, judge) do
    state.facts
    |> Map.values()
    |> Enum.filter(&(&1.family == family))
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce({state, verdicts}, fn fact, {state, verdicts} ->
      {verdict, fired, exercised} = judge.(fact)
      fact = fold_fact(fact, now, verdict, fired, exercised, files)

      {put_in(state.facts[fact.id], fact),
       Map.put(verdicts, fact.id, {verdict, fired, exercised})}
    end)
  end

  # --- folding a finished turn in ------------------------------------------------------------------

  @doc """
  Folds one finished turn's calls in. A turn is folded once: a run id already
  folded (`iid`) changes nothing, so a turn heard twice, or read back on a
  catch-up after it was folded live, earns no second confirmation.
  """
  def update_turn(%__MODULE__{} = state, calls, iid \\ nil) do
    if iid != nil and iid in state.folded do
      state
    else
      digest = Observe.observe_turn(calls)
      now = state.now
      injected = state.last_injected
      files = MapSet.new(digest.edited)
      by_intent = Enum.group_by(digest.obs, & &1.intent)

      {state, verdicts} =
        {state, %{}}
        |> form_repairs(by_intent, injected, files, now)
        |> absent_tools(digest.obs, injected, files, now)
        |> arg_repairs(by_intent, injected, files, now)
        |> env_values(digest.env, injected, files, now)
        |> boundary(by_intent, files, now)
        |> empty_probe(by_intent, files, now)

      %{
        state
        | now: now + 1,
          last_injected: MapSet.new(),
          last_digest: %{
            iid: iid,
            injected: injected |> MapSet.to_list() |> Enum.sort(),
            verdicts: verdicts,
            n_calls: digest.n_calls
          },
          folded: if(iid, do: Enum.take([iid | state.folded], @folded_kept), else: state.folded)
      }
    end
  end

  # FormRepair: discover candidates, count the forms, then fold every fact.
  defp form_repairs({state, verdicts}, by_intent, injected, files, now) do
    intents = ["run_interpreter", "run_tests", "run_build", "package_tool"]

    state =
      Enum.reduce(intents, state, fn intent, state ->
        seq = Map.get(by_intent, intent, [])

        # A test run that failed because its label did not load says nothing
        # about the way the runner was called: those are ArgRepair's, and
        # form_failed leaves them out already.
        fails =
          seq
          |> Enum.filter(&Observe.form_failed/1)
          |> then(fn fails ->
            # Outside tests and builds, only a bare form can be repaired by a
            # fuller one; an explicit path failing is a missing dependency.
            if intent in ["run_tests", "run_build"],
              do: fails,
              else: Enum.filter(fails, &Observe.bare?(&1.form))
          end)

        # A repair comes after the failure: a later call, or a later segment
        # of the same one (`pytest -q || python -m pytest -q`).
        state =
          Enum.reduce(fails, state, fn a, state ->
            if Enum.any?(
                 seq,
                 &(typed_ok?(&1) and {&1.call, &1.index} > {a.call, a.index} and
                     repairs?(&1.form, a.form, intent))
               ) do
              id = "form_repair:#{intent}:#{a.form}"

              state =
                ensure_fact(state, id, "form_repair", false, %{
                  "intent" => intent,
                  "a" => a.form,
                  "b_counts" => %{},
                  "error_counts" => %{}
                })

              case state.facts[id] do
                nil ->
                  state

                fact ->
                  counts =
                    Map.update(fact.params["error_counts"] || %{}, a.outcome, 1, &(&1 + 1))

                  put_in(state.facts[id], put_in(fact.params["error_counts"], counts))
              end
            else
              state
            end
          end)

        # A turn is one piece of evidence per form: every form that worked as
        # typed adds one, and a known working form that failed as typed (and
        # never worked) takes one back.
        ok = seq |> Enum.filter(&typed_ok?/1) |> MapSet.new(& &1.form)

        failed =
          seq
          |> Enum.filter(&(Observe.form_failed(&1) and not &1.env))
          |> MapSet.new(& &1.form)
          |> MapSet.difference(ok)

        state.facts
        |> Map.values()
        |> Enum.filter(&(&1.family == "form_repair" and &1.params["intent"] == intent))
        |> Enum.reduce(state, fn fact, state ->
          counts =
            Enum.reduce(ok, fact.params["b_counts"] || %{}, fn form, counts ->
              if repairs?(form, fact.params["a"], intent),
                do: Map.update(counts, form, 1, &(&1 + 1)),
                else: counts
            end)

          b_fails =
            Enum.reduce(
              MapSet.intersection(failed, MapSet.new(Map.keys(counts))),
              fact.params["b_fails"] || %{},
              fn form, acc -> Map.update(acc, form, 1, &(&1 + 1)) end
            )

          fact = %{
            fact
            | params: Map.merge(fact.params, %{"b_counts" => counts, "b_fails" => b_fails})
          }

          put_in(state.facts[fact.id], fact)
        end)
      end)

    fold_family(state, "form_repair", now, files, verdicts, fn fact ->
      intent = fact.params["intent"]
      a_form = fact.params["a"]
      seq = Map.get(by_intent, intent, [])
      exercised = seq != []
      a_failed = Enum.any?(seq, &(&1.form == a_form and Observe.form_failed(&1)))
      b_forms = MapSet.new(Map.keys(fact.params["b_counts"] || %{}))

      b_ran =
        Enum.any?(seq, &(&1.form in b_forms and Observe.form_worked(&1))) or
          Enum.any?(
            seq,
            &(Observe.form_worked(&1) and not Observe.bare?(&1.form) and
                repairs?(&1.form, a_form, intent))
          )

      # Contradiction: the bare form ran the test runner or build tool without
      # an environment error. A bare interpreter one-liner succeeding is not
      # evidence.
      runner_seq =
        Map.get(by_intent, if(intent == "run_build", do: "run_build", else: "run_tests"), [])

      a_runner_ok = Enum.any?(runner_seq, &(&1.form == a_form and Observe.form_worked(&1)))
      fired = a_failed or (MapSet.member?(injected, fact.id) and b_ran and not a_failed)

      verdict =
        cond do
          a_failed or (b_ran and not a_runner_ok) -> "confirm"
          a_runner_ok -> "contradict"
          true -> nil
        end

      {verdict, fired, exercised}
    end)
  end

  # AbsentTool: a bare tool that is not installed and has no working form here.
  defp absent_tools({state, verdicts}, obs, injected, files, now) do
    repaired =
      state.facts
      |> Map.values()
      |> Enum.filter(&(&1.family == "form_repair" and working_form(&1) != nil))
      |> MapSet.new(& &1.params["a"])

    missing =
      Enum.reduce(obs, %{}, fn o, acc ->
        if o.intent in ["run_build", "run_tests", "package_tool"] and
             o.outcome == "command_missing" and o.not_found and Observe.bare?(o.form) and
             not String.contains?(o.form, " ") and not MapSet.member?(repaired, o.form) do
          Map.put_new(acc, o.form, o.intent)
        else
          acc
        end
      end)

    worked = obs |> Enum.filter(&Observe.form_worked/1) |> MapSet.new(&tool_of(&1.form))

    state =
      Enum.reduce(missing, state, fn {tool, intent}, state ->
        if MapSet.member?(worked, tool) do
          state
        else
          ensure_fact(state, "absent_tool:#{tool}", "absent_tool", true, %{
            "tool" => tool,
            "intent" => intent
          })
        end
      end)

    fold_family(state, "absent_tool", now, files, verdicts, fn fact ->
      tool = fact.params["tool"]
      seen = Enum.filter(obs, &(tool_of(&1.form) == tool))
      contradicted = MapSet.member?(repaired, tool) or Enum.any?(seen, &Observe.form_worked/1)

      missing_now =
        Enum.any?(
          seen,
          &(&1.outcome == "command_missing" and &1.not_found and &1.form == tool and
              Observe.bare?(&1.form))
        )

      # Staged, it counts a turn only when that turn ran another check of the
      # same kind: one that never needed the tool says nothing about it.
      prevented =
        MapSet.member?(injected, fact.id) and not contradicted and
          Enum.any?(obs, &(&1.intent == fact.params["intent"]))

      fired = missing_now or prevented
      exercised = fired or contradicted

      verdict =
        cond do
          contradicted -> "contradict"
          fired -> "confirm"
          true -> nil
        end

      {verdict, fired, exercised}
    end)
  end

  # ArgRepair: labels the runner loads only in another shape.
  defp arg_repairs({state, verdicts}, by_intent, injected, files, now) do
    runs = Map.get(by_intent, "run_tests", []) |> Enum.filter(&(&1.labels != []))

    state =
      runs
      |> Enum.with_index()
      |> Enum.filter(fn {o, _i} -> o.label_err end)
      |> Enum.reduce(state, fn {a_obs, i}, state ->
        Enum.reduce(a_obs.labels, state, fn a, state ->
          found =
            runs
            |> Enum.drop(i + 1)
            |> Enum.filter(&(&1.form == a_obs.form and &1.loaded))
            |> Enum.find_value(fn b_obs ->
              Enum.find_value(b_obs.labels, fn b ->
                case Observe.label_rule(a, b) do
                  nil -> nil
                  rule -> {rule, b}
                end
              end)
            end)

          case found do
            nil ->
              state

            {{kind, param}, b} ->
              id = "arg_repair:#{a_obs.form}:#{kind}:#{param}"

              state =
                ensure_fact(state, id, "arg_repair", false, %{
                  "form" => a_obs.form,
                  "kind" => kind,
                  "param" => param,
                  "examples" => %{}
                })

              case state.facts[id] do
                nil ->
                  state

                fact ->
                  examples = keep_example(fact.params["examples"] || %{}, "#{a} #{b}")
                  put_in(state.facts[id], put_in(fact.params["examples"], examples))
              end
          end
        end)
      end)

    fold_family(state, "arg_repair", now, files, verdicts, fn fact ->
      mine = Enum.filter(runs, &(&1.form == fact.params["form"]))

      bad =
        if fact.params["kind"] == "sep" do
          &String.contains?(&1, "::")
        else
          prefix = fact.params["param"]
          &String.starts_with?(&1, prefix)
        end

      bad_failed = Enum.any?(mine, &(&1.label_err and Enum.any?(&1.labels, bad)))
      bad_loaded = Enum.any?(mine, &(&1.loaded and Enum.any?(&1.labels, bad)))

      good_loaded =
        Enum.any?(mine, &(&1.loaded and Enum.any?(&1.labels, fn l -> not bad.(l) end)))

      exercised = mine != []
      fired = bad_failed or (MapSet.member?(injected, fact.id) and good_loaded and not bad_failed)

      verdict =
        cond do
          bad_loaded -> "contradict"
          bad_failed or good_loaded -> "confirm"
          true -> nil
        end

      {verdict, fired, exercised}
    end)
  end

  # EnvValue: a variable the code asks for, and the value that satisfied it.
  defp env_values({state, verdicts}, env, injected, files, now) do
    state =
      env
      |> Enum.with_index()
      |> Enum.reduce(state, fn {call, i}, state ->
        Enum.reduce(call.need, state, fn var, state ->
          later = env |> Enum.drop(i + 1) |> Enum.filter(&Map.has_key?(&1.sets, var))

          good =
            later
            |> Enum.filter(&(&1.ok == true and var not in &1.need))
            |> Enum.map(& &1.sets[var])

          case good do
            [] ->
              state

            [first | _] ->
              id = "env_value:#{var}"

              state =
                ensure_fact(state, id, "env_value", false, %{
                  "var" => var,
                  "good" => %{},
                  "bad" => %{}
                })

              case state.facts[id] do
                nil ->
                  state

                fact ->
                  good_counts = Map.update(fact.params["good"] || %{}, first, 1, &(&1 + 1))

                  bad_counts =
                    Enum.reduce(later, fact.params["bad"] || %{}, fn later_call, acc ->
                      value = later_call.sets[var]

                      # A call that only set it ran nothing, failing or not.
                      if later_call.ok == false and value != first,
                        do: Map.update(acc, value, 1, &(&1 + 1)),
                        else: acc
                    end)

                  params = Map.merge(fact.params, %{"good" => good_counts, "bad" => bad_counts})
                  put_in(state.facts[id], %{fact | params: params})
              end
          end
        end)
      end)

    fold_family(state, "env_value", now, files, verdicts, fn fact ->
      var = fact.params["var"]
      good = best(fact, "good")
      asked = Enum.any?(env, &(var in &1.need))
      good_ok = Enum.any?(env, &(&1.sets[var] == good and &1.ok))
      good_failed = Enum.any?(env, &(&1.sets[var] == good and var in &1.need))
      exercised = asked or Enum.any?(env, &Map.has_key?(&1.sets, var))
      fired = asked or (MapSet.member?(injected, fact.id) and good_ok)

      # Only the value working confirms the fact: code asking again shows the
      # waste recurs (it fires), not that the learned value is right.
      verdict =
        cond do
          good_failed -> "contradict"
          good_ok -> "confirm"
          true -> nil
        end

      {verdict, fired, exercised}
    end)
  end

  # Boundary: hosts refused.
  defp boundary({state, verdicts}, by_intent, files, now) do
    fetches = Map.get(by_intent, "fetch_remote", [])

    failed_hosts =
      fetches
      |> Enum.filter(&(&1.outcome in Observe.network_errors()))
      |> Enum.flat_map(& &1.hosts)
      |> Enum.frequencies()

    ok_hosts =
      fetches |> Enum.filter(&(&1.outcome == "ran")) |> Enum.flat_map(& &1.hosts) |> MapSet.new()

    id = "boundary:fetch_remote"

    state =
      if map_size(failed_hosts) > 0,
        do: ensure_fact(state, id, "boundary", true, %{"hosts" => %{}}),
        else: state

    case state.facts[id] do
      nil ->
        {state, verdicts}

      fact ->
        hosts =
          Enum.reduce(failed_hosts, fact.params["hosts"] || %{}, fn {host, n}, acc ->
            Map.update(acc, host, n, &(&1 + n))
          end)

        state = put_in(state.facts[id], put_in(fact.params["hosts"], hosts))
        known = MapSet.new(Map.keys(hosts))
        exercised = Enum.any?(fetches, &(&1.hosts != []))
        fired = map_size(failed_hosts) > 0

        verdict =
          cond do
            not MapSet.disjoint?(ok_hosts, known) -> "contradict"
            fired -> "confirm"
            true -> nil
          end

        fact = fold_fact(state.facts[id], now, verdict, fired, exercised, files)
        {put_in(state.facts[id], fact), Map.put(verdicts, id, {verdict, fired, exercised})}
    end
  end

  # EmptyProbe: refs beyond the checkout.
  defp empty_probe({state, verdicts}, by_intent, files, now) do
    probes =
      Map.get(by_intent, "probe_vcs_refs", []) |> Enum.filter(&(&1.outcome in ["hit", "empty"]))

    id = "empty_probe:vcs_refs"

    state =
      if probes != [],
        do: ensure_fact(state, id, "empty_probe", true, %{"kinds" => %{}}),
        else: state

    case state.facts[id] do
      nil ->
        {state, verdicts}

      fact ->
        kinds =
          Enum.reduce(probes, fact.params["kinds"] || %{}, fn o, acc ->
            Map.update(acc, o.probe, 1, &(&1 + 1))
          end)

        state = put_in(state.facts[id], put_in(fact.params["kinds"], kinds))
        exercised = probes != []
        fired = exercised

        verdict =
          cond do
            Enum.any?(probes, &(&1.outcome == "hit")) -> "contradict"
            exercised -> "confirm"
            true -> nil
          end

        fact = fold_fact(state.facts[id], now, verdict, fired, exercised, files)
        {put_in(state.facts[id], fact), Map.put(verdicts, id, {verdict, fired, exercised})}
    end
  end

  # --- persistence ------------------------------------------------------------------------------------

  @doc "The state as JSON-shaped maps, small: short facts and their evidence, nothing else."
  def dump(%__MODULE__{} = state) do
    %{
      "now" => state.now,
      "facts" =>
        Map.new(state.facts, fn {id, fact} ->
          {id,
           %{
             "id" => fact.id,
             "family" => fact.family,
             "params" => fact.params,
             "life" => Lifecycle.dump(fact.life)
           }}
        end),
      "dropped" => state.dropped |> MapSet.to_list() |> Enum.sort(),
      "folded" => state.folded
    }
  end

  @doc "A state read back from `dump/1`; reloading changes nothing it would stage."
  def load(saved, opts \\ [])

  def load(%{} = saved, opts) do
    base = new(opts)

    facts =
      Map.new(saved["facts"] || %{}, fn {id, saved_fact} ->
        life = saved_fact["life"] |> Lifecycle.load()

        {id,
         %Fact{
           id: saved_fact["id"] || id,
           family: saved_fact["family"],
           params: saved_fact["params"] || %{},
           life: life
         }}
      end)

    # A fact learned before the micro-skills knew to leave a credential out
    # is never read back, so never stated.
    facts = Map.reject(facts, fn {_id, fact} -> leaks?(fact) end)

    %{
      base
      | now: saved["now"] || 0,
        facts: facts,
        dropped: MapSet.new(saved["dropped"] || []),
        folded: saved["folded"] || []
    }
  end

  def load(_saved, opts), do: new(opts)

  defp leaks?(%Fact{family: "env_value", params: %{"var" => var}} = fact) when is_binary(var),
    do: Observe.secret_var?(var) or leaks_in?(fact.params)

  defp leaks?(%Fact{family: "boundary", params: %{"hosts" => hosts}} = fact) when is_map(hosts),
    do:
      Enum.any?(Map.keys(hosts), &String.contains?(&1, ["@", "?", "#"])) or
        leaks_in?(fact.params)

  defp leaks?(%Fact{params: params}), do: leaks_in?(params)

  defp leaks_in?(text) when is_binary(text), do: Observe.secret_value?(text)
  defp leaks_in?(map) when is_map(map), do: Enum.any?(map, &leaks_in?/1)
  defp leaks_in?({key, value}), do: leaks_in?(key) or leaks_in?(value)
  defp leaks_in?(list) when is_list(list), do: Enum.any?(list, &leaks_in?/1)
  defp leaks_in?(_), do: false
end
