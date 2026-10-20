defmodule HalC2.EditorsPropTest do
  @moduledoc """
  The splitter of a Windows command line (`HalC2.Editors.command_words/1`, the MSVC CRT
  rules — `CommandLineToArgvW` toggles quoting on a doubled quote instead): quoting any
  argument list with the inverse rules and splitting it gives the list back, and no input
  makes it raise. The module holds no state, so these are plain `forall`s.
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

  # How a quote inside quoted text is written: `\"` (after any backslashes, doubled), `""`
  # (which no backslash may precede), or the two in turn.
  defp quote_style, do: oneof([:backslash, :double, :mixed])

  # Quotes `arg` so the splitter reads it back as one argument: backslashes are doubled
  # before a quote and at the end, and a quote is escaped in the `style`.
  defp quote_argument(arg, style)

  defp quote_argument("", _style), do: ~s("")

  defp quote_argument(arg, style) do
    if String.match?(arg, ~r/[\s"]/),
      do: ~s(") <> escape(arg, 0, "", style, 0) <> ~s("),
      else: arg
  end

  defp escape("", slashes, acc, _style, _quotes), do: acc <> String.duplicate("\\", slashes * 2)

  defp escape("\\" <> rest, slashes, acc, style, quotes),
    do: escape(rest, slashes + 1, acc, style, quotes)

  defp escape(~s(") <> rest, slashes, acc, style, quotes) do
    doubled? = slashes == 0 and (style == :double or (style == :mixed and rem(quotes, 2) == 1))

    escaped =
      if doubled?,
        do: ~s(""),
        else: String.duplicate("\\", slashes * 2 + 1) <> ~s(")

    escape(rest, 0, acc <> escaped, style, quotes + 1)
  end

  defp escape(<<c, rest::binary>>, slashes, acc, style, quotes),
    do: escape(rest, 0, acc <> String.duplicate("\\", slashes) <> <<c>>, style, quotes)

  property "splitting a quoted argument list gives the list back",
    numtests: HalC2.Prop.numtests(300),
    max_size: 40 do
    forall {args, style} <- {resize(5, list(argument())), quote_style()} do
      line = Enum.map_join(args, " ", &quote_argument(&1, style))
      Editors.command_words(line) == args
    end
  end

  property "white space between arguments does not change them",
    numtests: HalC2.Prop.numtests(200),
    max_size: 40 do
    forall {args, gaps, style} <-
             {resize(5, non_empty(list(argument()))),
              resize(5, non_empty(list(oneof([" ", "  ", "\t", " \t "])))), quote_style()} do
      line =
        args
        |> Enum.with_index()
        |> Enum.map_join(fn {arg, i} ->
          quote_argument(arg, style) <> Enum.at(gaps, rem(i, length(gaps)))
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
