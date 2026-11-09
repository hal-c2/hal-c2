defmodule HalC2.Test.SystemdUnit do
  @moduledoc """
  A unit's settings as systemd reads them, for the settings HAL-C2's units write
  (systemd.unit(5) "Specifiers", systemd.service(5) "Command lines").

  Each reader raises when systemd would read the value as something other than its
  literal text: a `%` specifier it would expand, or an `ExecStart=` `$` variable it
  would substitute. `%%` and `$$` are the literal characters.
  """

  @doc "The values of every `key=` line in `unit`, as written."
  def values(unit, key) do
    for line <- String.split(unit, "\n"),
        String.starts_with?(line, key <> "="),
        do: String.replace_prefix(line, key <> "=", "")
  end

  @doc "A path setting's value (`WorkingDirectory=`, `append:`): taken as written."
  def path(raw), do: specifiers(raw)

  @doc "An `Environment=` value: one word, unquoted, `{name, value}`."
  def env(raw) do
    [word] = words(raw)
    [name, value] = String.split(word, "=", parts: 2)
    {name, specifiers(value)}
  end

  @doc "`ExecStart=`'s argv."
  def exec(raw), do: for(word <- words(raw), do: word |> specifiers() |> variables())

  defp specifiers(text), do: unescape(text, "%", "a specifier")
  defp variables(text), do: unescape(text, "$", "a variable")

  defp unescape(text, char, what) do
    text
    |> String.split(char <> char)
    |> Enum.map_join(char, fn part ->
      if String.contains?(part, char),
        do: raise(ArgumentError, "systemd reads #{what} in #{inspect(text)}"),
        else: part
    end)
  end

  # Words split at unquoted whitespace; quotes group, a backslash escapes the next
  # character, in quotes and out of them.
  defp words(raw), do: words(String.to_charlist(raw), nil, nil, [])

  defp words([], nil, word, acc), do: Enum.reverse(push(acc, word))
  defp words([], quote, _word, _acc), do: raise(ArgumentError, "unclosed #{[quote]}")
  defp words([?\\, c | rest], quote, word, acc), do: words(rest, quote, [c | word || []], acc)

  defp words([c | rest], nil, word, acc) when c in [?\s, ?\t],
    do: words(rest, nil, nil, push(acc, word))

  defp words([c | rest], nil, word, acc) when c in [?", ?'], do: words(rest, c, word || [], acc)
  defp words([c | rest], c, word, acc), do: words(rest, nil, word, acc)
  defp words([c | rest], quote, word, acc), do: words(rest, quote, [c | word || []], acc)

  defp push(acc, nil), do: acc
  defp push(acc, word), do: [word |> Enum.reverse() |> List.to_string() | acc]
end
