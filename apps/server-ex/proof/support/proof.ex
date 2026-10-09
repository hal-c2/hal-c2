defmodule HalC2.Proof do
  @moduledoc """
  Model checks a Maude model of the MC's code, and checks that the model still covers
  the code. A proof is an ExUnit module:

      use HalC2.Proof,
        model: "thread_move.maude",
        module: "THREAD-MOVE",
        check: "THREAD-MOVE-PROPS",
        code: [{:exports, HalC2.ThreadMove}, {:messages, HalC2.ThreadMove}],
        covers: %{"HalC2.ThreadMove.taking/2" => ~w(taking taking-gone)},
        abstracts: %{"HalC2.ThreadMove.fit/1" => "picks a project, before any move begins"},
        environment: %{"crash" => "an MC stops"},
        scenarios: %{"threads/moving-between-machines.feature" => ["A moved thread ..."]}

  `model` is a file in proof/models, `module` the Maude module holding its rules, and
  `check` the one with its states and propositions (`module` if omitted), whose whole
  states are of sort `state` ("Sys" if omitted). The proof gets the test "the model
  covers the code", and its own tests get the loaded model as `%{proof: proof}` for
  `refute_reachable/4`, `refute_deadlock/4` and `assert_ltl/4`.

  `code` lists what to read of the code, as facts:

    * `{:exports, M}`: "M.fun/arity" for each public function but behaviour callbacks;
    * `{:messages, M}`: "M handle_cast {:done, _, _}" for each message a GenServer
      matches, variables as `_`;
    * `{:state, M}`: "M state :key" for each field of M's struct, or each key of the
      maps its `init/1` writes out;
    * `{:calls, M, fun}`: "M fun(:arg)" for each literal first argument M passes `fun`;
    * `{:type, M, type}`: "M t:type :atom" for each atom of the type.

  Exports and types come from the compiled module (its docs and typespecs), the rest
  from its source. Every fact is a key of `covers`, naming the rule labels or ops of
  the model it is, or of `abstracts`, saying why the model leaves it out. Every rule
  of the model is named by `covers` or `environment`, which says what it stands for.
  `scenarios` names, per file under features/, the scenarios the proof proves.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @models Path.expand("../models", __DIR__)
  @fair Path.expand("fair.maude", __DIR__)
  @features Path.expand("../../../../features", __DIR__)

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, async: true
      # Maude gives up first, so a slow check fails rather than leave Maude busy.
      @moduletag timeout: Keyword.get(unquote(opts), :timeout, 300_000) + 30_000
      import HalC2.Proof, only: [refute_reachable: 4, refute_deadlock: 4, assert_ltl: 4]

      setup_all do
        [proof: HalC2.Proof.load(__MODULE__, unquote(opts))]
      end

      test "the model covers the code", %{proof: proof} do
        HalC2.Proof.assert_covers(proof)
      end
    end
  end

  @doc "Starts a Maude of the proof's own and loads its model."
  def load(test, opts) do
    pool = Module.concat(test, Maude)
    pool_spec = ExMaude.Pool.child_spec(name: pool, pool_size: 1, pool_max_overflow: 0)
    ExUnit.Callbacks.start_supervised!(Map.put(pool_spec, :id, pool))

    proof =
      %{check: opts[:module], state: "Sys", code: [], covers: %{}, abstracts: %{}}
      |> Map.merge(%{environment: %{}, scenarios: %{}, timeout: 300_000})
      |> Map.merge(Map.new(opts))
      |> Map.put(:pool, pool)

    loaded!(ExMaude.load_file(@fair, pool: pool), @fair)
    model = Path.join(@models, proof.model)
    loaded!(ExMaude.load_file(model, pool: pool), model)

    own = maude(proof, "show module #{proof.module} .")
    rules = for [_, label] <- Regex.scan(~r/^\s*c?rl \[([^\]]+)\] :/m, own), uniq: true, do: label

    check =
      if proof.check == proof.module, do: "", else: maude(proof, "show module #{proof.check} .")

    ops =
      for [_, names] <- Regex.scan(~r/^\s*ops? (.+?) :/m, own <> check),
          name <- String.split(names),
          into: MapSet.new(),
          do: name

    proof = Map.merge(proof, %{rules: rules, ops: ops})

    meta = """
    mod #{proof.check}-PROOF is
      including FAIR .
      including #{proof.check} .
      eq model = upModule('#{proof.check}, false) .
      eq labels = #{qids(rules)} .
    endm
    """

    loaded!(ExMaude.load_module(meta, pool: pool), meta)
    proof
  end

  defp loaded!(:ok, _what), do: :ok
  defp loaded!(error, what), do: flunk("Maude did not load #{what}: #{inspect(error)}")

  @doc """
  Fails if a state for which `bad` (an op of the model, from a state to Bool) holds is
  reachable from `init`, printing the path to it. `depth: n` bounds the search.
  """
  def refute_reachable(proof, init, bad, opts) do
    bound = if opts[:depth], do: "[1, #{opts[:depth]}]", else: "[1]"
    s = "S:#{proof.state}"
    search = "search #{bound} in #{proof.check} : #{init} =>* #{s} such that #{bad}(#{s}) ."
    found(proof, maude(proof, search), "#{bad} is reachable from #{init}")
  end

  @doc """
  Fails if a state is reachable from `init` in which `done` (an op of the model, from a
  state to Bool) does not hold and no rule can happen, printing the path to it. Rules
  named in `besides:` (faults, say) do not count as something that can happen.
  """
  def refute_deadlock(proof, init, done, opts) do
    s = "S:#{proof.state}"
    labels = proof.rules -- Keyword.get(opts, :besides, [])
    stuck = "stuck(upTerm(#{s}), #{qids(labels)})"

    search =
      "search [1] in #{proof.check}-PROOF : #{init} =>* #{s} such that not #{done}(#{s}) and #{stuck} ."

    found(proof, maude(proof, search), "#{init} gets stuck short of #{done}")
  end

  @doc """
  Fails if the LTL `formula` (over the model's propositions) does not hold from `init`,
  printing a counterexample. `fair:` names rule labels assumed weakly fair: a rule
  that stays enabled is taken in the end. With none, every path counts, including
  those on which the code stops taking steps.
  """
  def assert_ltl(proof, init, formula, opts) do
    fair = Keyword.get(opts, :fair, [])

    command =
      if fair == [] do
        "red in #{proof.check}-PROOF : modelCheck(#{init}, #{formula}) ."
      else
        labels = Enum.map_join(fair, " ", &"'#{&1}")
        start = "fair('init, #{labels}, #{labels}, upTerm(#{init}))"
        "red in #{proof.check}-PROOF : modelCheck(#{start}, ([] <> round) -> (#{formula})) ."
      end

    out = maude(proof, command)

    # ex_maude answers a reduction with its value alone.
    unless String.trim(out) == "true" do
      {path, loop} = counterexample(out)
      start = loop |> hd() |> elem(0) |> shown(proof, init)

      flunk("""
      #{formula} fails from #{init}#{if fair != [], do: ", fair in #{Enum.join(fair, " ")}"}.
      The labels of the path, then of the loop it ends in, forever:

        #{Enum.map_join(path, " ", &elem(&1, 1))}
        loop: #{Enum.map_join(loop, " ", &elem(&1, 1))}

      The loop starts at:

        #{start}
      """)
    end

    :ok
  end

  # A search found a state: the path to it, label by label.
  defp found(proof, out, what) do
    case Regex.run(~r/Solution 1 \(state (\d+)\)/, out) do
      nil ->
        :ok

      [_, n] ->
        labels =
          proof
          |> maude("show path labels #{n} .")
          |> String.split()
          |> Enum.reject(&(&1 == "Bye."))

        states =
          proof
          |> maude("show path #{n} .")
          |> String.split(~r/===\[.*?\]===>/s)
          |> Enum.map(&(&1 |> String.replace(~r/\s+/, " ") |> String.trim()))

        steps = Enum.zip_with(labels, tl(states), &"  --#{&1}-->\n  #{&2}")

        flunk("""
        #{what}, in #{length(labels)} steps: #{Enum.join(labels, " ")}

          #{hd(states)}
        #{Enum.join(steps, "\n")}
        """)
    end
  end

  # The path and loop of `counterexample(path, loop)`, each a list of {state, label}.
  defp counterexample(out) do
    [_, body] = String.split(out, "counterexample(", parts: 2)
    body = String.replace(body, ~r/\s+/, " ")
    {path, loop} = split_top(body)
    {elements(path), elements(loop)}
  end

  # The text before and after the first comma outside any brackets.
  defp split_top(text), do: split_top(text, 0, "")

  defp split_top("`" <> <<c::utf8, rest::binary>>, d, acc),
    do: split_top(rest, d, acc <> "`" <> <<c::utf8>>)

  defp split_top("," <> rest, 0, acc), do: {acc, rest}

  defp split_top(<<c::utf8, rest::binary>>, d, acc),
    do: split_top(rest, d + depth(c), acc <> <<c::utf8>>)

  # `{state, 'label} {state, 'label} ...` as {state, label}; for the fair model,
  # `{fair('label, left, all, state), 'step}`, its label the rule that led to the state.
  defp elements(text) do
    text
    |> chunks(0, "", [])
    |> Enum.map(fn chunk ->
      {state, label} = last_label(chunk)

      case Regex.run(~r/^fair\('([^,]+), [^,]*, [^,]*, (.*)\)$/s, state) do
        [_, label, state] -> {String.trim(state), label}
        nil -> {state, label}
      end
    end)
  end

  defp chunks("", _d, _acc, out), do: Enum.reverse(out)

  defp chunks("`" <> <<c::utf8, rest::binary>>, d, acc, out),
    do: chunks(rest, d, acc <> "`" <> <<c::utf8>>, out)

  defp chunks("{" <> rest, 0, _acc, out), do: chunks(rest, 1, "", out)
  defp chunks("}" <> rest, 1, acc, out), do: chunks(rest, 0, "", [acc | out])

  defp chunks(<<c::utf8, rest::binary>>, d, acc, out),
    do: chunks(rest, d + depth(c), if(d > 0, do: acc <> <<c::utf8>>, else: acc), out)

  defp depth(c) when c in ~c"([{", do: 1
  defp depth(c) when c in ~c")]}", do: -1
  defp depth(_), do: 0

  defp last_label(text) do
    [label | state] = text |> String.split(", '") |> Enum.reverse()
    {state |> Enum.reverse() |> Enum.join(", '") |> String.trim(), label |> String.trim()}
  end

  # A state as the model writes it: the fair model's states are meta terms.
  defp shown(state, proof, init) do
    if String.starts_with?(state, "'") do
      proof
      |> maude("red in #{proof.check}-PROOF : downTerm(#{state}, #{init}) .")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    else
      state
    end
  end

  defp qids([]), do: "none"
  defp qids(labels), do: Enum.map_join(labels, " ; ", &"'#{&1}")

  defp maude(proof, command) do
    case ExMaude.execute(command, pool: proof.pool, timeout: proof.timeout) do
      {:ok, out} ->
        if out =~ ~r/^(Warning|Error)/m, do: flunk("Maude: #{command}\n#{out}"), else: out

      {:error, error} ->
        flunk("Maude failed: #{command}\n#{inspect(error)}")
    end
  end

  # --- coverage ----------------------------------------------------------------------

  @doc "Fails, naming each, if the code and the model's mapping have drifted apart."
  def assert_covers(proof) do
    facts = proof.code |> Enum.flat_map(&facts/1) |> Enum.uniq()
    mapped = Enum.uniq(Map.keys(proof.covers) ++ Map.keys(proof.abstracts))
    named = proof.covers |> Map.values() |> List.flatten()

    problems =
      for(
        f <- facts,
        f not in mapped,
        do: "#{f} is in the code, but neither covered nor abstracted"
      ) ++
        for(f <- mapped, f not in facts, do: "#{f} is mapped, but no longer in the code") ++
        for(
          f <- Map.keys(proof.covers),
          is_map_key(proof.abstracts, f),
          do: "#{f} is both covered and abstracted"
        ) ++
        for(
          {f, why} <- proof.abstracts,
          String.trim(why) == "",
          do: "#{f} is abstracted without a reason"
        ) ++
        for(
          {f, refs} <- proof.covers,
          ref <- List.wrap(refs),
          ref not in proof.rules and not MapSet.member?(proof.ops, ref),
          do: "#{f} is covered by #{ref}, which the model has no rule or op for"
        ) ++
        for(
          rule <- proof.rules,
          rule not in named and not is_map_key(proof.environment, rule),
          do:
            "rule [#{rule}] stands for nothing in the code; cover a fact with it, or list it in environment"
        ) ++
        for(
          rule <- Map.keys(proof.environment),
          rule not in proof.rules,
          do: "environment rule [#{rule}] is not in the model"
        ) ++
        if(proof.scenarios == %{}, do: ["the proof names no scenarios it proves"], else: []) ++
        Enum.flat_map(proof.scenarios, &missing_scenarios/1)

    if problems != [],
      do: flunk("The model and the code differ:\n\n" <> Enum.join(problems, "\n"))

    :ok
  end

  defp missing_scenarios({file, names}) do
    case File.read(Path.join(@features, file)) do
      {:ok, text} ->
        have =
          for [_, name] <- Regex.scan(~r/^\s*Scenario(?: Outline)?:\s*(.+?)\s*$/m, text), do: name

        for name <- names,
            name not in have,
            do: "scenario #{inspect(name)} is not in features/#{file}"

      {:error, _} ->
        ["features/#{file} does not exist"]
    end
  end

  @doc "The facts of the code that `spec` names, as strings (see the moduledoc)."
  def facts({:exports, mod}) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)
    # A function with default arguments also exports its shorter arities.
    shorter = for {{:function, f, a}, _, _, _, %{defaults: n}} <- docs, k <- 1..n, do: {f, a - k}
    callbacks = for b <- behaviours(mod), cb <- b.behaviour_info(:callbacks), do: cb
    # Generated by `use GenServer` and the like.
    generated = [child_spec: 1, module_info: 0, module_info: 1, __info__: 1]

    for {f, a} <- mod.module_info(:exports),
        {f, a} not in shorter and {f, a} not in callbacks and {f, a} not in generated,
        do: "#{inspect(mod)}.#{f}/#{a}"
  end

  def facts({:messages, mod}) do
    {_, found} =
      Macro.prewalk(source(mod), [], fn
        {:def, _, [head | _]} = node, acc ->
          case head(head) do
            {f, [message | _]} when f in [:handle_call, :handle_cast, :handle_info] ->
              {node, ["#{inspect(mod)} #{f} #{pattern(message)}" | acc]}

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found |> Enum.reverse() |> Enum.uniq()
  end

  def facts({:state, mod}) do
    keys =
      if function_exported?(mod, :__struct__, 0) do
        mod.__struct__() |> Map.keys() |> List.delete(:__struct__)
      else
        {_, keys} =
          Macro.prewalk(source(mod), [], fn
            {:def, _, [head, body]} = node, acc ->
              case head(head) do
                {:init, _} -> {node, acc ++ started(body)}
                _ -> {node, acc}
              end

            node, acc ->
              {node, acc}
          end)

        keys
      end

    for key <- Enum.uniq(keys), do: "#{inspect(mod)} state #{inspect(key)}"
  end

  def facts({:calls, mod, fun}) do
    {_, found} =
      Macro.prewalk(source(mod), [], fn
        {^fun, _, [arg | _]} = node, acc when is_atom(arg) or is_binary(arg) or is_number(arg) ->
          {node, ["#{inspect(mod)} #{fun}(#{inspect(arg)})" | acc]}

        node, acc ->
          {node, acc}
      end)

    found |> Enum.reverse() |> Enum.uniq()
  end

  def facts({:type, mod, type}) do
    {:ok, types} = Code.Typespec.fetch_types(mod)

    case for({kind, {^type, ast, _}} <- types, kind in [:type, :typep, :opaque], do: ast) do
      [ast | _] -> for atom <- atoms(ast), do: "#{inspect(mod)} t:#{type} #{inspect(atom)}"
      [] -> flunk("#{inspect(mod)} has no type #{type}")
    end
  end

  defp behaviours(mod),
    do: mod.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

  defp source(mod) do
    mod.module_info(:compile)[:source]
    |> List.to_string()
    |> File.read!()
    |> Code.string_to_quoted!()
  end

  defp head({:when, _, [head | _]}), do: head(head)
  defp head({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp head(_), do: nil

  # A pattern with its variables, bound or pinned, as `_`.
  defp pattern(ast) do
    ast
    |> Macro.prewalk(fn
      {:^, _, _} -> {:_, [], nil}
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> {:_, [], nil}
      other -> other
    end)
    |> Macro.to_string()
  end

  # The keys of the map an `init/1` body returns in `{:ok, %{...}}`.
  # The keys of every map init/1 writes out, however it then returns its state: bound
  # first, piped through a helper, or with a timeout. Updates add no keys.
  defp started(body) do
    {_, keys} =
      Macro.prewalk(body, [], fn
        {:%{}, _, pairs} = node, acc ->
          if Keyword.keyword?(pairs), do: {node, acc ++ Keyword.keys(pairs)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    keys
  end

  defp atoms({:atom, _, atom}), do: [atom]
  defp atoms(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> atoms()
  defp atoms(list) when is_list(list), do: Enum.flat_map(list, &atoms/1)
  defp atoms(_), do: []
end
