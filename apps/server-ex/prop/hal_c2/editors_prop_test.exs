defmodule HalC2.EditorsPropTest do
  @moduledoc """
  The splitter of a Windows command line (`HalC2.Editors.command_words/1`, the rules of
  `CommandLineToArgvW`): quoting any argument list with the inverse rules and splitting it
  gives the list back, and no input makes it raise. The module holds no state, so these are
  plain `forall`s.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Editors

  # Characters that make quoting matter: white space, quotes and the backslashes before them.
  defp argument do
    let chars <- resize(8, list(oneof([?a, ?b, ?=, ?\s, ?\t, ?\\, ?\\, ?"]))) do
      List.to_string(chars)
    end
  end

  # Quotes `arg` so the splitter reads it back as one argument: backslashes are doubled
  # before a quote and at the end, and a quote is escaped.
  defp quote_argument(""), do: ~s("")

  defp quote_argument(arg) do
    if String.match?(arg, ~r/[\s"]/), do: ~s(") <> escape(arg, 0, "") <> ~s("), else: arg
  end

  defp escape("", slashes, acc), do: acc <> String.duplicate("\\", slashes * 2)
  defp escape("\\" <> rest, slashes, acc), do: escape(rest, slashes + 1, acc)

  defp escape(~s(") <> rest, slashes, acc),
    do: escape(rest, 0, acc <> String.duplicate("\\", slashes * 2 + 1) <> ~s("))

  defp escape(<<c, rest::binary>>, slashes, acc),
    do: escape(rest, 0, acc <> String.duplicate("\\", slashes) <> <<c>>)

  property "splitting a quoted argument list gives the list back",
    numtests: HalC2.Prop.numtests(300),
    max_size: 40 do
    forall args <- resize(5, list(argument())) do
      line = Enum.map_join(args, " ", &quote_argument/1)
      Editors.command_words(line) == args
    end
  end

  property "white space between arguments does not change them",
    numtests: HalC2.Prop.numtests(200),
    max_size: 40 do
    forall {args, gaps} <-
             {resize(5, non_empty(list(argument()))),
              resize(5, non_empty(list(oneof([" ", "  ", "\t", " \t "]))))} do
      line =
        args
        |> Enum.with_index()
        |> Enum.map_join(fn {arg, i} ->
          quote_argument(arg) <> Enum.at(gaps, rem(i, length(gaps)))
        end)

      Editors.command_words(" " <> line) == args
    end
  end

  property "any text splits into strings without raising",
    numtests: HalC2.Prop.numtests(300),
    max_size: 80 do
    forall line <- binary() do
      Editors.command_words(line) |> Enum.all?(&is_binary/1)
    end
  end
end
