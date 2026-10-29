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

  @doc "The file's text, or `{:error, reason}` when the checkout has neither."
  def read(root) do
    with {:error, _} <- File.read(Path.join(root, "hal-c2.json")),
         do: File.read(Path.join(root, "t3.json"))
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
end
