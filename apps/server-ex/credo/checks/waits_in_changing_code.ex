defmodule HalC2.Credo.WaitsInChangingCode do
  use Credo.Check,
    id: "HC001",
    base_priority: :high,
    category: :warning,
    param_defaults: [baseline: nil],
    explanations: [
      check: """
      A process must not wait for long in a module that can change.

      Erlang moves a process to a module's new code only when the process next calls
      into the module by name. One waiting in a `receive`, or in a blocking call made
      from the module, stays on the code it waits in for as long as it waits. A module
      keeps one old version, so the load after the next one refuses while such a
      process is still there (`{:old_processes, M}`), and every quiet reader, idle
      loop or parked process blocks hot code updates from then on.

      `gen_server` and friends are safe because they wait in OTP's own loop and only
      enter the callback module to handle a message. Flagged here, outside modules
      that `use HalC2.Frozen`:

        * a `receive` with no `after`, or `after :infinity`, and
          `Process.sleep(:infinity)`: it waits forever in this module's code.
        * a loop a process spawned in this module runs (a function reached from a
          `spawn`, `spawn_link`, `spawn_monitor`, `Task.start` or `:proc_lib` entry
          that calls itself again): it lives in this module's code. Run it on
          `HalC2.Pump` instead, which waits in frozen code and calls the module by
          name once per event.

      A wait that truly ends soon can be bounded with `after`. Anything else that
      must wait in its own code goes in a `HalC2.Frozen` module, which changes only
      at a restart.

      `credo/waits_baseline.exs` lists the places that predate the check, by file
      and function. Fixing one means removing its entry, which the check asks for.
      """
    ]

  @spawners %{
    {[:Kernel], :spawn} => true,
    {[:Kernel], :spawn_link} => true,
    {[:Kernel], :spawn_monitor} => true,
    {[:Process], :spawn} => true,
    {[:Task], :start} => true,
    {[:Task], :start_link} => true,
    {:proc_lib, :spawn} => true,
    {:proc_lib, :spawn_link} => true,
    {:proc_lib, :spawn_opt} => true,
    {:erlang, :spawn} => true,
    {:erlang, :spawn_link} => true,
    {:erlang, :spawn_monitor} => true
  }

  # Remote calls that block until a peer acts, by function name.
  @blocking [:read, :read_stderr, :read_any, :recv, :accept, :transfer_accept, :binread]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    path = relative(source_file.filename)
    known = baseline(params)[path] || MapSet.new()

    found =
      source_file
      |> SourceFile.ast()
      |> findings()

    keys = MapSet.new(found, fn {_line, fun, kind, _message} -> {fun, kind} end)

    stale =
      for {fun, kind} <- known, not MapSet.member?(keys, {fun, kind}) do
        {1, "the baseline lists `#{fun}` (#{kind}), which no longer needs it: remove it"}
      end

    fresh =
      for {line, fun, kind, message} <- found,
          not MapSet.member?(known, {fun, kind}),
          do: {line, message}

    (fresh ++ stale)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {line, message} ->
      format_issue(issue_meta, message: message, line_no: line)
    end)
  end

  @doc """
  What the check finds in `ast`, as `{line, function, kind, message}` with `kind`
  `:wait` or `:loop`; the baseline lists `{function, kind}` per file.
  """
  def findings(ast) do
    ast
    |> modules()
    |> Enum.reject(&frozen?/1)
    |> Enum.flat_map(&issues/1)
    |> Enum.uniq()
  end

  defp relative(filename) do
    filename
    |> Path.expand()
    |> Path.relative_to(Path.expand(File.cwd!()))
  end

  defp baseline(params) do
    case Params.get(params, :baseline, __MODULE__) do
      nil ->
        %{}

      file ->
        key = {__MODULE__, :baseline, file}

        case :persistent_term.get(key, nil) do
          nil ->
            {entries, _} = Code.eval_file(file)

            table =
              Map.new(entries, fn {path, funs} ->
                {path, MapSet.new(funs)}
              end)

            :persistent_term.put(key, table)
            table

          table ->
            table
        end
    end
  end

  # Each module with its own body, nested modules apart.
  defp modules(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [name, [do: body]]} = node, acc ->
          {node, [{alias_parts(name), body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.map(found, fn {name, body} -> {name, strip_modules(body)} end)
  end

  defp strip_modules(body) do
    Macro.prewalk(body, fn
      {:defmodule, _, _} -> nil
      node -> node
    end)
  end

  defp alias_parts({:__aliases__, _, parts}), do: parts
  defp alias_parts(_), do: nil

  defp frozen?({_name, body}) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:use, _, [{:__aliases__, _, [:HalC2, :Frozen]} | _]} = node, _ -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  defp issues({name, body}) do
    defs = definitions(body)
    endless_waits(defs) ++ spawned_loops(name, body, defs)
  end

  # --- waits with no end ------------------------------------------------------------

  defp endless_waits(defs) do
    for {fun, {_line, bodies}} <- defs, {line, message} <- endless(bodies) do
      {line, fun, :wait, message}
    end
  end

  defp endless(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:receive, meta, [blocks]} = node, acc when is_list(blocks) ->
          if endless?(blocks[:after]),
            do: {node, [{meta[:line], "`receive` waits with no end in code that changes"} | acc]},
            else: {node, acc}

        {{:., _, [mod, :sleep]}, meta, [:infinity]} = node, acc
        when mod == :timer or (is_tuple(mod) and elem(mod, 2) == [:Process]) ->
          {node, [{meta[:line], "sleeps forever in code that changes"} | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp endless?(nil), do: true
  defp endless?([{:->, _, [[:infinity], _]}]), do: true
  defp endless?(_), do: false

  # --- loops of processes spawned here ---------------------------------------------

  defp spawned_loops(name, body, defs) do
    names = MapSet.new(Map.keys(defs))

    calls =
      Map.new(defs, fn {fun, {_line, bodies}} -> {fun, local_calls(bodies, name, names)} end)

    for fun <- reach(spawn_entries(body, name, names), calls),
        MapSet.member?(reach(Map.get(calls, fun, []), calls), fun),
        {line, bodies} = defs[fun],
        waits?(bodies) do
      {line, fun, :loop,
       "`#{fun}` is the waiting loop of a process spawned here: run it on `HalC2.Pump`"}
    end
  end

  defp waits?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:receive, _, _} = node, _ ->
          {node, true}

        {{:., _, [_mod, fun]}, _, args} = node, _ when fun in @blocking and is_list(args) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # name => {first line, [bodies]}, over every arity and clause.
  defp definitions(body) do
    {_, defs} =
      Macro.prewalk(body, %{}, fn
        {kind, meta, [head | rest]} = node, acc when kind in [:def, :defp] ->
          case head_name(head) do
            nil ->
              {node, acc}

            fun ->
              {node,
               Map.update(acc, fun, {meta[:line], [rest]}, fn {line, bodies} ->
                 {line, [rest | bodies]}
               end)}
          end

        node, acc ->
          {node, acc}
      end)

    defs
  end

  defp head_name({:when, _, [head | _]}), do: head_name(head)
  defp head_name({fun, _, args}) when is_atom(fun) and is_list(args), do: fun
  defp head_name({fun, _, nil}) when is_atom(fun), do: fun
  defp head_name(_), do: nil

  # The functions of this module that `ast` calls or captures.
  defp local_calls(ast, name, names) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        case called(node, name, names) do
          nil -> {node, acc}
          fun -> {node, [fun | acc]}
        end
      end)

    Enum.uniq(found)
  end

  defp called({:&, _, [{:/, _, [ref, _arity]}]}, name, names), do: captured(ref, name, names)

  defp called({{:., _, [mod, fun]}, _, args}, name, names) when is_atom(fun) and is_list(args),
    do: if(own?(mod, name) and MapSet.member?(names, fun), do: fun)

  defp called({fun, _, args}, _name, names) when is_atom(fun) and is_list(args),
    do: if(MapSet.member?(names, fun), do: fun)

  defp called(_node, _name, _names), do: nil

  defp captured({fun, _, ctx}, _name, names) when is_atom(fun) and is_atom(ctx),
    do: if(MapSet.member?(names, fun), do: fun)

  defp captured({{:., _, [mod, fun]}, _, []}, name, names),
    do: if(own?(mod, name) and MapSet.member?(names, fun), do: fun)

  defp captured(_ref, _name, _names), do: nil

  defp own?({:__MODULE__, _, _}, _name), do: true
  defp own?({:__aliases__, _, parts}, name), do: parts == name
  defp own?(_mod, _name), do: false

  # The functions of this module a process spawned here starts in.
  defp spawn_entries(body, name, names) do
    {_, found} =
      Macro.prewalk(body, [], fn node, acc ->
        case spawn_args(node) do
          nil -> {node, acc}
          args -> {node, entries(args, name, names) ++ acc}
        end
      end)

    Enum.uniq(found)
  end

  defp spawn_args({spawner, _, args})
       when spawner in [:spawn, :spawn_link, :spawn_monitor] and is_list(args),
       do: args

  defp spawn_args({{:., _, [{:__aliases__, _, mod}, fun]}, _, args}) when is_list(args),
    do: if(Map.has_key?(@spawners, {mod, fun}), do: args)

  defp spawn_args({{:., _, [mod, fun]}, _, args}) when is_atom(mod) and is_list(args),
    do: if(Map.has_key?(@spawners, {mod, fun}), do: args)

  defp spawn_args(_node), do: nil

  defp entries([{:fn, _, _} = fun | _], name, names), do: local_calls(fun, name, names)
  defp entries([{:&, _, _} = ref | _], name, names), do: local_calls(ref, name, names)

  # `spawn(node, fun)` and `Process.spawn(fun, opts)`.
  defp entries([_node, {:fn, _, _} = fun | _], name, names), do: local_calls(fun, name, names)

  defp entries([mod, fun | _], name, names) when is_atom(fun),
    do: if(own?(mod, name) and MapSet.member?(names, fun), do: [fun], else: [])

  defp entries(_args, _name, _names), do: []

  defp reach(from, calls), do: reach(from, calls, MapSet.new())

  defp reach([], _calls, seen), do: seen

  defp reach([fun | rest], calls, seen) do
    if MapSet.member?(seen, fun),
      do: reach(rest, calls, seen),
      else: reach(Map.get(calls, fun, []) ++ rest, calls, MapSet.put(seen, fun))
  end
end
