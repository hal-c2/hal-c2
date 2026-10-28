defmodule HalC2.Claude.Skills do
  @moduledoc """
  Claude's skills as the picker offers them and as a `$mention` runs them,
  following upstream's `ClaudeSkills`/`ClaudeSkillDispatch`: skills live in the
  Claude config directory's `skills` folder and the project's `.claude/skills`
  (never `.agents/skills`), a skill is known by its folder's name, and Claude's
  own `skillOverrides` settings — layered user, project, project-local,
  repository-root-local, managed policy — decide which are on.
  """

  alias HalC2.Claude.Provider

  @doc """
  The skills of instance `instance` for a thread in `cwd` (project skills are
  read only when a folder is given), as `ServerProviderSkill` maps, sorted by
  name. The user's own skill wins over a project skill of the same name.
  """
  @spec discover(String.t(), String.t() | nil, String.t() | nil) :: [map]
  def discover(instance \\ "claudeAgent", cwd \\ nil, config_dir \\ nil) do
    config_dir = config_dir || Provider.config_dir(instance, cwd)
    overrides = skill_overrides(config_dir, cwd)

    roots =
      [{Path.join(config_dir, "skills"), "user"}] ++
        if(cwd, do: [{Path.join([cwd, ".claude", "skills"]), "project"}], else: [])

    roots
    |> Enum.flat_map(fn {root, scope} -> read_root(root, scope, overrides) end)
    |> Enum.uniq_by(& &1["name"])
    |> Enum.sort_by(& &1["name"])
  end

  @doc "The names a `$mention` may run: offered, on, and not kept from the user."
  @spec user_invocable_names(String.t(), String.t() | nil) :: MapSet.t()
  def user_invocable_names(instance \\ "claudeAgent", cwd \\ nil) do
    if HalC2.Settings.instance_enabled?(instance, "claudeAgent") do
      instance
      |> discover(cwd)
      |> Enum.filter(&(&1["enabled"] and &1["userInvocable"] != false))
      |> MapSet.new(& &1["name"])
    else
      MapSet.new()
    end
  end

  defp read_root(root, scope, overrides) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(&read_skill(Path.join(root, &1), &1, scope, overrides))

      _ ->
        []
    end
  end

  defp read_skill(dir, entry, scope, overrides) do
    name = String.trim(entry)
    path = Path.join(dir, "SKILL.md")

    with true <- name != "",
         {:ok, content} <- File.read(path),
         {:ok, frontmatter} <- frontmatter(content) do
      override = overrides[name]

      skill =
        %{
          "name" => name,
          "path" => path,
          "scope" => scope,
          "enabled" => override_enabled(override)
        }
        |> put_present("description", description(frontmatter))
        |> put_flag(
          "userInvocationOnly",
          flag(frontmatter, "disable-model-invocation") == true or
            override == "user-invocable-only"
        )
        |> put_flag("userInvocable", flag(frontmatter, "user-invocable") == false, false)

      [skill]
    else
      _ -> []
    end
  end

  defp override_enabled("off"), do: false
  defp override_enabled(_), do: true

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_flag(map, key, on, value \\ true),
    do: if(on, do: Map.put(map, key, value), else: map)

  defp description(%{"description" => value}) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp description(_frontmatter), do: nil

  # A frontmatter flag as Claude reads it, including the spellings YAML 1.1
  # booleans take (`yes`, `on`, ...).
  defp flag(frontmatter, key) do
    case frontmatter[key] do
      nil -> nil
      value -> boolean(value)
    end
  end

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(1), do: true
  defp boolean(0), do: false

  defp boolean(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      word when word in ["true", "yes", "on", "y"] -> true
      word when word in ["false", "no", "off", "n"] -> false
      _ -> nil
    end
  end

  defp boolean(_value), do: nil

  # The header between its fences, as the small set of scalar keys a skill's
  # header carries. No header at all is fine; a header that cannot be read as
  # one (a line that is not a key, an unclosed bracket or quote) drops the
  # skill, as a YAML error does for Claude itself. (The MC has no YAML reader;
  # a header with nested lists under other keys reads as those keys absent.)
  @spec frontmatter(String.t()) :: {:ok, map} | :error
  def frontmatter(content) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)/s, content) do
      [_, body] -> parse_frontmatter(body)
      _ -> {:ok, %{}}
    end
  end

  defp parse_frontmatter(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      cond do
        String.trim(line) == "" or String.starts_with?(String.trim_leading(line), "#") ->
          {:cont, {:ok, acc}}

        String.starts_with?(line, [" ", "\t"]) ->
          {:cont, {:ok, acc}}

        true ->
          case Regex.run(~r/^([A-Za-z0-9_-]+):\s*(.*)$/, line) do
            [_, key, value] ->
              if unreadable?(value),
                do: {:halt, :error},
                else: {:cont, {:ok, Map.put(acc, key, scalar(value))}}

            _ ->
              {:halt, :error}
          end
      end
    end)
  end

  defp unreadable?(value) do
    value = String.trim(value)

    (String.starts_with?(value, "[") and not String.ends_with?(value, "]")) or
      (String.starts_with?(value, "{") and not String.ends_with?(value, "}")) or
      (String.starts_with?(value, "\"") and
         not (String.ends_with?(value, "\"") and String.length(value) > 1)) or
      (String.starts_with?(value, "'") and
         not (String.ends_with?(value, "'") and String.length(value) > 1))
  end

  defp scalar(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") -> String.slice(value, 1..-2//1)
      String.starts_with?(value, "'") -> String.slice(value, 1..-2//1)
      value in ["true", "false"] -> value == "true"
      true -> value
    end
  end

  # --- skillOverrides ---------------------------------------------------------

  @overrides ["on", "off", "name-only", "user-invocable-only"]

  # The layered `skillOverrides`, lowest first: the user's settings, the
  # project's, the project's local ones, the repository root's local ones
  # (never its shared ones), and the organisation's managed policy on top —
  # the layering Claude itself reads. A file holding a value Claude cannot
  # read has all its overrides dropped.
  @spec skill_overrides(String.t(), String.t() | nil) :: map
  def skill_overrides(config_dir, cwd) do
    Enum.reduce(settings_paths(config_dir, cwd), %{}, fn path, acc ->
      Map.merge(acc, read_overrides(path))
    end)
  end

  defp settings_paths(config_dir, cwd) do
    user = [Path.join(config_dir, "settings.json")]

    {project, root_local} =
      if cwd do
        local = Path.join([cwd, ".claude", "settings.local.json"])

        root_local =
          case repository_root(cwd) do
            nil -> []
            root when root == cwd -> []
            root -> [Path.join([root, ".claude", "settings.local.json"])]
          end

        {[Path.join([cwd, ".claude", "settings.json"]), local], root_local}
      else
        {[], []}
      end

    managed =
      case managed_settings_path() do
        nil -> []
        path -> [path]
      end

    user ++ project ++ root_local ++ managed
  end

  defp repository_root(cwd) do
    cwd = Path.expand(cwd)

    Stream.unfold(cwd, fn
      "/" -> nil
      dir -> {dir, Path.dirname(dir)}
    end)
    |> Enum.find(fn dir ->
      path = Path.join(dir, ".git")
      File.dir?(path) or File.regular?(path)
    end)
  end

  @doc "The managed policy's file, or nil when this system names none."
  @spec managed_settings_path() :: String.t() | nil
  def managed_settings_path do
    Application.get_env(:hal_c2, :claude_managed_settings_path) ||
      default_managed_path(Application.get_env(:hal_c2, :os_type, :os.type()))
  end

  @doc "Where the organisation's managed Claude settings live on a system."
  @spec default_managed_path(:os.type()) :: String.t() | nil
  def default_managed_path({:unix, :darwin}),
    do: "/Library/Application Support/ClaudeCode/managed-settings.json"

  def default_managed_path({:win32, _}) do
    case System.get_env("PROGRAMDATA") do
      nil -> nil
      "" -> nil
      dir -> Path.join([String.trim(dir), "ClaudeCode", "managed-settings.json"])
    end
  end

  def default_managed_path(_os), do: "/etc/claude-code/managed-settings.json"

  defp read_overrides(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"skillOverrides" => overrides}} when is_map(overrides) <-
           decode_lenient(text),
         true <- Enum.all?(overrides, fn {_, value} -> value in @overrides end) do
      overrides
    else
      _ -> %{}
    end
  end

  # Claude's settings are JSON with comments and trailing commas allowed.
  @spec decode_lenient(String.t()) :: {:ok, term} | :error
  def decode_lenient(text) do
    text
    |> strip_comments()
    |> strip_trailing_commas()
    |> JSON.decode()
    |> case do
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end

  # Comments outside strings; string literals pass through word for word.
  defp strip_comments(text), do: strip_comments(text, [])

  defp strip_comments("", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_comments("\"" <> rest, acc) do
    {string, rest} = take_string(rest)
    strip_comments(rest, ["\"" <> string | acc])
  end

  defp strip_comments("//" <> rest, acc) do
    strip_comments(drop_line(rest), acc)
  end

  defp strip_comments("/*" <> rest, acc) do
    strip_comments(drop_block(rest), acc)
  end

  defp strip_comments(<<char::utf8, rest::binary>>, acc),
    do: strip_comments(rest, [<<char::utf8>> | acc])

  defp take_string(text), do: take_string(text, [])

  defp take_string("", acc), do: {finish(acc), ""}
  defp take_string("\"" <> rest, acc), do: {finish(["\"" | acc]), rest}

  defp take_string("\\" <> <<char::utf8, rest::binary>>, acc),
    do: take_string(rest, [<<char::utf8>>, "\\" | acc])

  defp take_string(<<char::utf8, rest::binary>>, acc),
    do: take_string(rest, [<<char::utf8>> | acc])

  defp finish(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp drop_line(text) do
    case :binary.split(text, "\n") do
      [_line, rest] -> "\n" <> rest
      [_line] -> ""
    end
  end

  defp drop_block(text) do
    case :binary.split(text, "*/") do
      [_block, rest] -> rest
      [_block] -> ""
    end
  end

  defp strip_trailing_commas(text), do: strip_trailing_commas(text, [])

  defp strip_trailing_commas("", acc), do: finish(acc)

  defp strip_trailing_commas("\"" <> rest, acc) do
    {string, rest} = take_string(rest)
    strip_trailing_commas(rest, ["\"" <> string | acc])
  end

  defp strip_trailing_commas(text, acc) do
    case Regex.run(~r/\A,\s*([}\]])/, text) do
      [whole, closing] ->
        rest = binary_part(text, byte_size(whole), byte_size(text) - byte_size(whole))
        strip_trailing_commas(closing <> rest, acc)

      _ ->
        <<char::utf8, rest::binary>> = text
        strip_trailing_commas(rest, [<<char::utf8>> | acc])
    end
  end

  # --- $mention dispatch --------------------------------------------------------

  # A currency sign at the start or after a space, a name with a letter in it
  # ending at a space or the end — but not an amount of money.
  @mention ~S/(^|\s)\p{Sc}(?![0-9][0-9_]*(?:[kKmMbBtT]|[eE][0-9]+)?(?:\s|$))(?=[a-zA-Z0-9:_-]*[a-zA-Z])([a-zA-Z0-9][a-zA-Z0-9:_-]*)(?=\s|$)/

  @doc """
  Plans a message's skill dispatch: the last known `$mention` runs as Claude's
  own `/skill` command (the last text block, where Claude expands it), earlier
  known mentions are rewritten to `/name` in the leading text, and everything
  else stays as typed. `nil` when the message runs no skill.
  """
  @spec dispatch(String.t(), MapSet.t()) :: {String.t() | nil, String.t()} | nil
  def dispatch(text, names) do
    known =
      text
      |> mentions()
      |> Enum.filter(fn {_at, _length, _currency_at, name} -> MapSet.member?(names, name) end)

    case List.last(known) do
      nil ->
        nil

      {at, length, _currency_at, name} ->
        leading =
          known
          |> Enum.drop(-1)
          |> Enum.reverse()
          |> Enum.reduce(binary_part(text, 0, at), fn {m_at, m_length, m_currency, m_name}, acc ->
            # Right to left, so an earlier mention's offsets still hold after
            # a later one (whose currency sign may be wider than `/`) is rewritten.
            replace_mention(acc, m_at, m_length, m_currency, m_name)
          end)

        command =
          ("/" <> name <> binary_part(text, at + length, byte_size(text) - at - length))
          |> String.trim_trailing()

        leading = String.trim_trailing(leading)
        {if(leading == "", do: nil, else: leading), command}
    end
  end

  defp replace_mention(leading, at, length, currency_at, name) do
    head = binary_part(leading, 0, currency_at)
    tail = binary_part(leading, at + length, byte_size(leading) - at - length)
    head <> "/" <> name <> tail
  end

  # {match start, match byte length, byte offset of the currency sign, name}
  defp mentions(text) do
    {:ok, pattern} = :re.compile(@mention, [:unicode, :ucp])

    case :re.run(text, pattern, [:global, {:capture, :all, :index}]) do
      {:match, matches} ->
        for [{at, length}, {_space_at, space_length}, {name_at, name_length}] <- matches do
          {at, length, at + max(space_length, 0), binary_part(text, name_at, name_length)}
        end

      _ ->
        []
    end
  end
end
