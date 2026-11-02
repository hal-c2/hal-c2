defmodule HalC2.ProjectFile do
  @moduledoc """
  A checkout's `hal-c2.json`, the shared defaults for everyone who opens it. A checkout
  that only has the `t3.json` from before the rename is read the same way.
  """

  require Logger

  @icons ~w(play test lint configure build debug)
  @max_scripts 50
  @max_path 512
  @flags ~w(runOnWorktreeCreate async autoOpenPreview)

  @space_kinds ~w(page)
  @default_spaces [%{"path" => "**/*.md", "kind" => "page"}]

  @doc "The file's text, or `{:error, reason}` when the checkout has neither."
  def read(root) do
    with {:error, _} <- File.read(Path.join(root, "hal-c2.json")),
         do: File.read(Path.join(root, "t3.json"))
  end

  # The file `read/1` reads, or the one to make.
  defp path(root) do
    Enum.find(
      [Path.join(root, "hal-c2.json"), Path.join(root, "t3.json")],
      Path.join(root, "hal-c2.json"),
      &File.regular?/1
    )
  end

  @doc """
  The scripts `root`'s file declares, in file order; `[]` without a file. A file that
  cannot be read or does not match the format declares nothing, and is logged.
  """
  def scripts(root) do
    with {:ok, text} <- read(root),
         {:ok, file} <- parse(text) do
      file["scripts"]
    else
      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("ignoring the project file in #{root}: #{:file.format_error(reason)}")
        []

      :error ->
        Logger.warning("ignoring the project file in #{root}: it does not match the format")
        []
    end
  end

  @doc """
  The file's contents, read as the clients read it (`packages/contracts`
  `HalC2ProjectFile`, the desktop's `ProjectFile.cpp`): JSON that may carry comments and
  trailing commas, whose scripts get trimmed names and commands. A file that does not
  match the format is `:error` as a whole.
  """
  def parse(text) do
    with {:ok, %{} = file} <- HalC2.Claude.Skills.decode_lenient(text),
         true <- valid?(file),
         {:ok, scripts} <- parse_scripts(Map.get(file, "scripts", [])) do
      {:ok, Map.put(file, "scripts", scripts)}
    else
      _ -> :error
    end
  end

  defp valid?(file) do
    optional?(file, "$schema", &is_binary/1) and
      optional?(file, "iconPath", &(trimmed(&1) && String.length(&1) <= @max_path)) and
      optional?(file, "defaultThreadEnvMode", &(&1 in ~w(local worktree))) and
      optional?(file, "worktreeSubmodules", &(&1 in ~w(recursive top-level none)))
  end

  defp parse_scripts(scripts) when is_list(scripts) and length(scripts) <= @max_scripts do
    parsed = Enum.map(scripts, &parse_script/1)
    if nil in parsed, do: :error, else: {:ok, parsed}
  end

  defp parse_scripts(_), do: :error

  # A script with its strings trimmed, or nil when it does not match the format.
  defp parse_script(%{"name" => _, "command" => _} = script) do
    strings =
      for key <- ~w(name command previewUrl),
          Map.has_key?(script, key),
          into: %{},
          do: {key, trimmed(script[key])}

    if nil not in Map.values(strings) and optional?(script, "icon", &(&1 in @icons)) and
         Enum.all?(@flags, fn flag -> optional?(script, flag, &is_boolean/1) end),
       do: Map.merge(script, strings)
  end

  defp parse_script(_), do: nil

  defp optional?(map, key, valid?), do: not Map.has_key?(map, key) or !!valid?.(map[key])

  # A non-empty string, trimmed; nil when it is anything else.
  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_), do: nil

  # --- the spaces section ---------------------------------------------------------------

  @doc """
  Which of the checkout's files are Space content (`features/space/project-files.feature`):
  `{:ok, source, entries}`, each entry a `path` glob (`*`, `**`, `?`) and the `kind` a
  matching file opens as, the first match deciding. `source` is `:project` when the file
  has a `spaces` section and `:default` (every Markdown file a page) when it has none.
  A section that does not match the format is `{:error, :invalid}` and counts no files;
  it is read apart from the rest, so the scripts stay as they are.
  """
  def spaces(root) do
    with {:ok, text} <- read(root) do
      case HalC2.Claude.Skills.decode_lenient(text) do
        {:ok, %{"spaces" => section}} -> section(section)
        {:ok, %{}} -> {:ok, :default, @default_spaces}
        _ -> {:error, :invalid}
      end
    else
      {:error, _} -> {:ok, :default, @default_spaces}
    end
  end

  defp section(%{"files" => entries}) when is_list(entries) do
    if Enum.all?(entries, &space_entry?/1),
      do: {:ok, :project, Enum.map(entries, &Map.take(&1, ~w(path kind)))},
      else: {:error, :invalid}
  end

  defp section(_), do: {:error, :invalid}

  defp space_entry?(%{"path" => path, "kind" => kind}),
    do: is_binary(path) and trimmed(path) != nil and kind in @space_kinds

  defp space_entry?(_), do: false

  @doc "The kind `relative` opens as under `entries` (`spaces/1`), or nil."
  def space_kind(entries, relative) do
    Enum.find_value(entries, fn %{"path" => glob, "kind" => kind} ->
      if Regex.match?(glob(glob), relative), do: kind
    end)
  end

  # A path glob as a regex: `**` crosses folders, `*` and `?` do not.
  defp glob(glob) do
    body =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*/", "\u0000")
      |> String.replace("/\\*\\*", "\u0001")
      |> String.replace("\\*\\*", "\u0002")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")
      |> String.replace("\u0000", "(?:.*/)?")
      |> String.replace("\u0001", "(?:/.*)?")
      |> String.replace("\u0002", ".*")

    Regex.compile!("\\A" <> body <> "\\z")
  end

  @doc """
  The section a scan proposes for `files` (paths relative to the checkout): `*.md` for
  Markdown at the top, `<folder>/**/*.md` for each top folder holding some, hidden folders
  left out. `[]` when there is no Markdown.
  """
  def propose_spaces(files) do
    markdown =
      Enum.filter(files, fn path ->
        String.ends_with?(path, ".md") and
          not Enum.any?(Path.split(path), &String.starts_with?(&1, "."))
      end)

    top = if Enum.any?(markdown, &(not String.contains?(&1, "/"))), do: ["*.md"], else: []

    folders =
      for path <- markdown, String.contains?(path, "/"), uniq: true do
        (path |> Path.split() |> hd()) <> "/**/*.md"
      end

    Enum.map(top ++ Enum.sort(folders), &%{"path" => &1, "kind" => "page"})
  end

  @doc """
  Writes `entries` as the file's `spaces` section, keeping the rest of its text (comments
  included) as it is, or makes the file with only that section.
  """
  def put_spaces(root, entries) do
    file = path(root)
    section = section_text(entries)

    text =
      case File.read(file) do
        {:ok, text} -> splice(text, section)
        {:error, :enoent} -> {:ok, "{\n  \"spaces\": " <> section <> "\n}\n"}
        {:error, reason} -> {:error, reason}
      end

    with {:ok, text} <- text, do: File.write(file, text)
  end

  defp section_text(entries) do
    lines =
      Enum.map_join(entries, ",\n", fn entry ->
        ~s(      { "path": #{JSON.encode!(entry["path"])}, "kind": #{JSON.encode!(entry["kind"])} })
      end)

    "{\n    \"files\": [\n" <> lines <> "\n    ]\n  }"
  end

  # The text with the top object's `spaces` value replaced, or the member added last.
  defp splice(text, section) do
    tokens = json_tokens(text, 0, 0, [])

    case Enum.find_index(tokens, &match?({:close, 0, _, _}, &1)) do
      nil ->
        {:error, :invalid}

      close ->
        case spaces_value(tokens) do
          {from, to} ->
            {:ok,
             binary_part(text, 0, from) <> section <> binary_part(text, to, byte_size(text) - to)}

          nil ->
            last = tokens |> Enum.at(close - 1) |> elem(3)

            {before, rest} =
              {binary_part(text, 0, last), binary_part(text, last, byte_size(text) - last)}

            comma = if binary_part(text, last - 1, 1) in ["{", ","], do: "", else: ","
            {:ok, before <> comma <> "\n  \"spaces\": " <> section <> rest}
        end
    end
  end

  # The byte span of the top object's `spaces` value.
  defp spaces_value(tokens) do
    tokens
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value(fn
      [{:string, 1, _, _, "spaces"}, {:colon, 1, _, _}, value] -> value_span(tokens, value)
      _ -> nil
    end)
  end

  defp value_span(tokens, {:open, depth, from, _} = open) do
    {:close, _, _, to} =
      tokens
      |> Enum.drop_while(&(&1 != open))
      |> Enum.find(&match?({:close, ^depth, _, _}, &1))

    {from, to}
  end

  defp value_span(_tokens, value), do: {elem(value, 2), elem(value, 3)}

  # JSON with comments as tokens `{type, depth, from, to}` (a string's also with its
  # value), whitespace and comments left out. An object or array opens at its depth and
  # closes at the same one.
  defp json_tokens(text, at, depth, acc) do
    case text do
      <<>> ->
        Enum.reverse(acc)

      <<"//", _::binary>> ->
        skip = until(text, "\n")
        json_tokens(binary_part(text, skip, byte_size(text) - skip), at + skip, depth, acc)

      <<"/*", _::binary>> ->
        skip = until(text, "*/") + 2
        skip = min(skip, byte_size(text))
        json_tokens(binary_part(text, skip, byte_size(text) - skip), at + skip, depth, acc)

      <<"\"", _::binary>> ->
        size = string_size(text, 1)
        value = binary_part(text, 1, max(size - 2, 0))
        rest = binary_part(text, size, byte_size(text) - size)
        json_tokens(rest, at + size, depth, [{:string, depth, at, at + size, value} | acc])

      <<c, rest::binary>> when c in [?{, ?[] ->
        json_tokens(rest, at + 1, depth + 1, [{:open, depth, at, at + 1} | acc])

      <<c, rest::binary>> when c in [?}, ?]] ->
        json_tokens(rest, at + 1, depth - 1, [{:close, depth - 1, at, at + 1} | acc])

      <<?:, rest::binary>> ->
        json_tokens(rest, at + 1, depth, [{:colon, depth, at, at + 1} | acc])

      <<?,, rest::binary>> ->
        json_tokens(rest, at + 1, depth, [{:comma, depth, at, at + 1} | acc])

      <<c, rest::binary>> when c in [?\s, ?\t, ?\r, ?\n] ->
        json_tokens(rest, at + 1, depth, acc)

      <<_, rest::binary>> ->
        case acc do
          [{:word, ^depth, from, ^at} | acc] ->
            json_tokens(rest, at + 1, depth, [{:word, depth, from, at + 1} | acc])

          acc ->
            json_tokens(rest, at + 1, depth, [{:word, depth, at, at + 1} | acc])
        end
    end
  end

  defp until(text, mark) do
    case :binary.match(text, mark) do
      {at, _} -> at
      :nomatch -> byte_size(text)
    end
  end

  # The bytes of the string literal at the start of `text`, both quotes included.
  defp string_size(text, at) when at >= byte_size(text), do: at

  defp string_size(text, at) do
    case :binary.at(text, at) do
      ?\\ -> string_size(text, at + 2)
      ?" -> at + 1
      _ -> string_size(text, at + 1)
    end
  end
end
