defmodule HalC2.Acp.CursorSkills do
  @moduledoc """
  The skills Cursor loads for a workspace, read from its skill folders the way
  upstream's `CursorSkills.ts` reads them, without opening an ACP session:
  the project's and the user's `.cursor`, `.agents`, `.codex` and `.claude`
  skills folders, then Cursor's built-in `~/.cursor/skills-cursor` as system
  skills. The first skill of a name wins (a skill is known by its folder),
  so a project's skill beats the user's, and both beat a built-in.

  The scan keeps upstream's budgets: 10,000 folders descended, 100,000 stats,
  8 MB of skill files, at most ten folders deep. A scan that cannot finish is
  reported (`probe/2`), never silently cut short. Only folders spend the
  descent budget, `node_modules` is never entered, and a folder linked from
  two roots is read once, so one heavy skill cannot hide the others.
  """

  @max_depth 10
  @max_skill_bytes 1_000_000
  @max_entries 10_000
  @max_stats 100_000
  @max_bytes 8_000_000

  @doc """
  The skills discovered for `cwd`, sorted by name: what a mention may name.
  A scan that could not finish still gives what it found.
  """
  @spec discover(String.t() | nil, String.t() | nil) :: [map]
  def discover(cwd \\ nil, home \\ nil), do: inspect_skills(cwd, home).skills

  @doc """
  The skills discovered for `cwd`, or `{:error, detail}` when the scan could
  not finish (its budget spent, or a folder it could not read).
  """
  @spec probe(String.t() | nil, String.t() | nil) :: {:ok, [map]} | {:error, String.t()}
  def probe(cwd \\ nil, home \\ nil) do
    case inspect_skills(cwd, home) do
      %{failure: nil, skills: skills} ->
        {:ok, skills}

      %{failure: reason} ->
        location = if cwd, do: " for '#{cwd}'", else: ""
        {:error, "Cursor skill discovery#{location} was incomplete (#{reason})."}
    end
  end

  @doc "The entry's workspace snapshots of Cursor skills read so far."
  def workspaces(id) do
    for {cwd, snapshot} <- :persistent_term.get({HalC2.Acp, id, :workspaces}, %{}),
        do: Map.put(snapshot, "cwd", cwd)
  end

  @doc """
  Reads the skills Cursor offers in `cwd` and keeps them on the entry:
  `:ok`, or `{:error, detail}` with no snapshot kept, so a failed read never
  leaves a partial skill list behind.
  """
  def refresh_workspace(id, cwd) do
    epoch = HalC2.Acp.workspaces_epoch(id)

    case probe(cwd) do
      {:ok, found} ->
        snapshot = %{
          "checkedAt" => HalC2.Orchestration.Entities.now(),
          "slashCommands" => [],
          "skills" => found
        }

        # The scan and the notification stay outside the instance's lock.
        with :ok <- HalC2.Acp.put_workspace(id, cwd, snapshot, epoch) do
          HalC2.Settings.notify_providers()
          :ok
        else
          :dropped -> {:error, "The instance was removed while its skills were read."}
        end

      {:error, _detail} = error ->
        error
    end
  end

  defp inspect_skills(cwd, home) do
    home = home || HalC2.Paths.user_home()

    budget = %{
      entries: @max_entries,
      stats: @max_stats,
      bytes: @max_bytes,
      exhausted: false,
      incomplete: false,
      scanned: MapSet.new()
    }

    roots =
      if(cwd, do: roots_below(cwd, "project"), else: []) ++
        roots_below(home, "user") ++
        [{Path.join([home, ".cursor", "skills-cursor"]), "system"}]

    {budget, found} =
      Enum.reduce_while(roots, {budget, %{}}, fn {dir, scope}, {budget, found} ->
        if budget.exhausted do
          {:halt, {budget, found}}
        else
          {budget, skills} = discover_root(dir, scope, budget)

          found =
            Enum.reduce(skills, found, fn skill, acc ->
              Map.put_new(acc, skill["name"], skill)
            end)

          {:cont, {budget, found}}
        end
      end)

    %{
      skills: found |> Map.values() |> Enum.sort_by(& &1["name"]),
      failure:
        cond do
          budget.exhausted -> "scan-budget-exhausted"
          budget.incomplete -> "filesystem-error"
          true -> nil
        end
    }
  end

  defp roots_below(base, scope) do
    for root <- ~w(.cursor .agents .codex .claude),
        do: {Path.join([base, root, "skills"]), scope}
  end

  # Roots are remembered by real path across the scan: two roots linked to
  # one tree are one scan, charged once.
  defp discover_root(dir, scope, budget) do
    case real_path(dir, budget) do
      {nil, budget} ->
        {budget, []}

      {root, budget} ->
        if MapSet.member?(budget.scanned, root) do
          {budget, []}
        else
          budget = %{budget | scanned: MapSet.put(budget.scanned, root)}
          {budget, _visited, skills} = visit(root, root, scope, 0, budget, MapSet.new(), [])
          {budget, Enum.reverse(skills)}
        end
    end
  end

  # Reads only skill folders under the fixed roots named above; a path inside
  # one is the scan's own, never one a client sent.
  # sobelow_skip ["Traversal.FileModule"]
  defp visit(directory, root, scope, depth, budget, visited, skills) do
    if budget.exhausted do
      {budget, visited, skills}
    else
      case real_path(directory, budget) do
        {nil, budget} ->
          {budget, visited, skills}

        {resolved, budget} ->
          if MapSet.member?(visited, resolved) do
            {budget, visited, skills}
          else
            visited = MapSet.put(visited, resolved)
            inside? = resolved == root or String.starts_with?(resolved, root <> "/")
            {budget, skills} = maybe_skill(directory, scope, budget, skills)

            if inside? do
              case File.ls(directory) do
                {:ok, entries} ->
                  entries
                  |> Enum.sort()
                  |> Enum.reduce({budget, visited, skills}, fn entry, {budget, visited, skills} ->
                    descend(entry, directory, root, scope, depth, budget, visited, skills)
                  end)

                {:error, reason} ->
                  {note_error(budget, reason), visited, skills}
              end
            else
              {budget, visited, skills}
            end
          end
      end
    end
  end

  defp descend("node_modules", _dir, _root, _scope, _depth, budget, visited, skills),
    do: {budget, visited, skills}

  defp descend(entry, directory, root, scope, depth, budget, visited, skills) do
    child = Path.join(directory, entry)

    case stat(child, budget) do
      {%File.Stat{type: :directory}, budget} ->
        cond do
          depth >= @max_depth ->
            {budget, visited, skills}

          budget.entries == 0 ->
            {%{budget | exhausted: true}, visited, skills}

          true ->
            visit(
              child,
              root,
              scope,
              depth + 1,
              %{budget | entries: budget.entries - 1},
              visited,
              skills
            )
        end

      {_other, budget} ->
        {budget, visited, skills}
    end
  end

  # The folder's own skill, when it keeps one: known by the folder's name,
  # shown by the name in its header. A header that cannot be read drops it;
  # a skill file over the reading limit is offered with no description. A
  # file the remaining byte budget cannot pay to read exhausts the scan:
  # its header might have hidden the skill, so the list may be wrong.
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_skill(directory, scope, budget, skills) do
    path = Path.join(directory, "SKILL.md")

    case stat(path, budget) do
      {%File.Stat{type: :regular, size: size}, budget} ->
        {frontmatter, budget} =
          cond do
            size > @max_skill_bytes ->
              {%{cli_visible: true}, budget}

            size > budget.bytes ->
              {%{cli_visible: true}, %{budget | exhausted: true}}

            true ->
              case File.read(path) do
                {:ok, body} -> {parse_frontmatter(body), %{budget | bytes: budget.bytes - size}}
                _ -> {nil, budget}
              end
          end

        name = directory |> Path.basename() |> String.trim()

        if frontmatter && frontmatter.cli_visible && name != "" do
          skill =
            %{"name" => name, "path" => path, "scope" => scope, "enabled" => true}
            |> put_present(
              "displayName",
              if(frontmatter[:display_name] not in [nil, name], do: frontmatter.display_name)
            )
            |> put_present("description", frontmatter[:description])
            |> put_flag("userInvocationOnly", frontmatter[:user_invocation_only] == true)
            |> put_flag("userInvocable", frontmatter[:user_invocable] == false, false)

          {budget, [skill | skills]}
        else
          {budget, skills}
        end

      {_other, budget} ->
        {budget, skills}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_flag(map, key, on, value \\ true),
    do: if(on, do: Map.put(map, key, value), else: map)

  # A stat costs the stats budget; spent stats exhaust the scan.
  # sobelow_skip ["Traversal.FileModule"]
  defp stat(_path, %{stats: 0} = budget), do: {nil, %{budget | exhausted: true}}

  defp stat(path, budget) do
    budget = %{budget | stats: budget.stats - 1}

    case File.stat(path) do
      {:ok, info} -> {info, budget}
      {:error, reason} -> {nil, note_error(budget, reason)}
    end
  end

  defp real_path(path, budget) do
    case HalC2.Paths.real(path) do
      {:ok, real} -> {real, budget}
      {:error, reason} -> {nil, note_error(budget, reason)}
    end
  end

  # A missing folder is no failure; anything else makes the scan incomplete.
  defp note_error(budget, reason) when reason in [:enoent, :enotdir], do: budget
  defp note_error(budget, _reason), do: %{budget | incomplete: true}

  # --- the skill header -------------------------------------------------------

  # The header's fields Cursor acts on, or nil when the header cannot be read
  # as one. No header at all is a skill with defaults.
  defp parse_frontmatter(body) do
    case HalC2.Claude.Skills.frontmatter(body) do
      {:ok, fields} ->
        surfaces = metadata_surfaces(body)

        %{
          cli_visible:
            surfaces == [] or
              Enum.any?(surfaces, &(String.downcase(String.trim(&1)) == "cli")),
          display_name: trimmed(fields["name"]),
          description: trimmed(fields["description"]),
          user_invocation_only: flag(fields, "disable-model-invocation"),
          user_invocable: flag(fields, "user-invocable")
        }

      :error ->
        nil
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  defp flag(fields, key) do
    case fields[key] do
      nil -> nil
      value -> boolean(value)
    end
  end

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(1), do: true
  defp boolean(0), do: false

  defp boolean(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      word when word in ["true", "yes", "on"] -> true
      word when word in ["false", "no", "off"] -> false
      _ -> nil
    end
  end

  defp boolean(_value), do: nil

  # `metadata.surfaces`, as a flow list, a comma list, or a block list in the
  # small indented header below `metadata:` (the scalar header reader skips it).
  defp metadata_surfaces(body) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)/s, body) do
      [_, header] -> surfaces_in(String.split(header, ~r/\r?\n/))
      _ -> []
    end
  end

  defp surfaces_in(lines) do
    lines
    |> Enum.drop_while(&(not Regex.match?(~r/^metadata:\s*$/, &1)))
    |> Enum.drop(1)
    |> Enum.take_while(&String.starts_with?(&1, [" ", "\t"]))
    |> read_surfaces()
  end

  defp read_surfaces([]), do: []

  defp read_surfaces([line | rest]) do
    case Regex.run(~r/^\s+surfaces:\s*(.*)$/, line) do
      [_, ""] ->
        rest
        |> Enum.take_while(&Regex.match?(~r/^\s+-\s*/, &1))
        |> Enum.map(&(&1 |> String.replace(~r/^\s+-\s*/, "") |> scalar()))

      [_, "[" <> _ = flow] ->
        flow
        |> String.trim()
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.split(",")
        |> Enum.map(&scalar/1)

      [_, value] ->
        value |> String.split(",") |> Enum.map(&scalar/1)

      _ ->
        read_surfaces(rest)
    end
  end

  defp scalar(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        String.slice(value, 1..-2//1)

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        String.slice(value, 1..-2//1)

      true ->
        value
    end
  end
end
