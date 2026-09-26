defmodule HalC2.Keybindings do
  @moduledoc """
  The user's keybinding rules (`<home>/keybindings.json`), as written: `key`,
  `command`, and optional `when`. Clients merge them with the defaults and
  compile them (`@hal-c2/shared/keybindings`), so the node only stores rules and
  says when they change (`{:hal_c2_keybindings, node, rules}` to settings watchers).
  """

  @max 256
  @max_key 64
  @max_when 256
  @max_depth 64
  @script ~r/^script\.([a-z0-9][a-z0-9-]*)\.run$/
  @max_script_id 24

  @doc "The stored rules, skipping entries that are not rules."
  def rules do
    with {:ok, text} <- File.read(path()),
         {:ok, list} when is_list(list) <- JSON.decode(text) do
      for %{"key" => key, "command" => command} = rule <- list,
          is_binary(key) and is_binary(command) and
            (rule["when"] == nil or is_binary(rule["when"])),
          do: Map.take(rule, ~w(key command when))
    else
      _ -> []
    end
  end

  @doc "`server.upsertKeybinding`: adds a rule, replacing an equal one or `replace`."
  def upsert(input) do
    rule = rule(input)
    replace = input["replace"] && rule(input["replace"])

    case invalid(rule) do
      nil ->
        rules()
        |> Enum.reject(&(&1 == rule or &1 == replace))
        |> Kernel.++([rule])
        |> Enum.take(-@max)
        |> save()

      reason ->
        {:error,
         %{
           "_tag" => "KeybindingRuleInvalidError",
           "message" => "Invalid keybinding rule: #{reason}"
         }}
    end
  end

  @doc "`server.removeKeybinding`: removes a rule."
  def remove(input) do
    target = rule(input)
    rules() |> Enum.reject(&(&1 == target)) |> save()
  end

  defp rule(input),
    do: input |> Map.take(~w(key command when)) |> Map.reject(fn {_, v} -> v == nil end)

  # The limits of `KeybindingRule` in @hal-c2/contracts. A condition nested past
  # the parser's depth could never apply, so it is refused here rather than
  # stored and dropped by every client.
  defp invalid(rule) do
    key = rule["key"]
    command = rule["command"]
    condition = rule["when"]

    cond do
      not is_binary(key) or String.trim(key) == "" or String.length(String.trim(key)) > @max_key ->
        "the key must be 1 to #{@max_key} characters"

      not is_binary(command) or String.trim(command) == "" ->
        "the command is missing"

      String.starts_with?(command, "script.") and not script_command?(command) ->
        "a script id is 1 to #{@max_script_id} lowercase letters, digits and dashes, not starting with a dash"

      condition != nil and
          (not is_binary(condition) or String.trim(condition) == "" or
             String.length(String.trim(condition)) > @max_when) ->
        "the condition must be 1 to #{@max_when} characters"

      condition != nil and depth(condition) > @max_depth ->
        "the condition is nested deeper than #{@max_depth} levels"

      true ->
        nil
    end
  end

  defp script_command?(command) do
    case Regex.run(@script, command) do
      [_, id] -> String.length(id) <= @max_script_id
      _ -> false
    end
  end

  # The deepest parenthesis nesting or run of negations in a condition.
  defp depth(condition) do
    condition
    |> String.replace(~r/\s+/, "")
    |> String.graphemes()
    |> Enum.reduce({0, 0, 0}, fn
      "(", {open, _nots, deepest} -> {open + 1, 0, max(deepest, open + 1)}
      ")", {open, _nots, deepest} -> {open - 1, 0, deepest}
      "!", {open, nots, deepest} -> {open, nots + 1, max(deepest, nots + 1)}
      _, {open, _nots, deepest} -> {open, 0, deepest}
    end)
    |> elem(2)
  end

  defp save(rules) do
    file = path()
    tmp = file <> ".tmp"
    File.mkdir_p!(Path.dirname(file))
    File.write!(tmp, JSON.encode!(rules))
    File.rename!(tmp, file)
    HalC2.Settings.notify_keybindings(rules)
    {:ok, %{"rules" => rules}}
  end

  defp path, do: Path.join(HalC2.Paths.config_dir(), "keybindings.json")
end
