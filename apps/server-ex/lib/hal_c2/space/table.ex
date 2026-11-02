defmodule HalC2.Space.Table do
  @moduledoc """
  The table of a `table` block, and its GitHub Markdown.

  A table is its columns' `align` (`"left"`, `"center"`, `"right"` or nil), its `rows`,
  the header first and every row a cell per column, and its `widths`, how many
  characters each column's cells are padded to when written. A cell is one line of
  inline Markdown as written, but for `\\|`, which is a `|` in the cell.

  Every row is written `| a | b |`, each cell padded with spaces to its column's width
  (a longer cell is written whole, so only its row is wider), and the row under the
  header is the alignment marks filling the width, `| :--- |`, or with `tight` filling
  the spaces beside it too, `|:-----|`. When the marks are wider or narrower than the
  cells, as in `| a |` over `| --- |`, `ruleWidths` holds their widths. A table made in
  a page is padded to its widest cell, 3 at least, and is not tight:

      | Step | Owner |
      | ---- | ----- |
      | MC   | Ada   |

  A table read from Markdown keeps the widths it was written with: a column's width is
  what its padded cells are padded to, or 0 when none is, so a padded table comes back
  as it was, and so does one whose cells are not padded at all. An edit keeps the
  widths too: it rewrites only the rows it changes.
  """

  @aligns [nil, "left", "center", "right"]

  @doc """
  A table from a map of `rows` and, if given, `align`, `widths`, `ruleWidths` and
  `tight`: widths left out are each column's widest cell. A cell's spaces around it
  are dropped.
  """
  @spec cast(term) :: {:ok, map} | {:error, String.t()}
  def cast(%{"rows" => [[_ | _] = head | _] = rows} = table) do
    columns = length(head)
    align = Map.get(table, "align") || List.duplicate(nil, columns)

    cond do
      not Enum.all?(rows, &(is_list(&1) and length(&1) == columns)) ->
        {:error, "Every row of a table has a cell for each of its #{columns} columns."}

      not Enum.all?(rows, fn row -> Enum.all?(row, &cell?/1) end) ->
        {:error, "A table's cell is one line of text."}

      not (is_list(align) and length(align) == columns and Enum.all?(align, &(&1 in @aligns))) ->
        {:error, "A table's align is left, center, right or null for each column."}

      not (valid_widths?(table["widths"], columns) and
               valid_widths?(table["ruleWidths"], columns)) ->
        {:error, "A table's widths are a number for each column."}

      not is_nil(table["tight"]) and not is_boolean(table["tight"]) ->
        {:error, "A table's tight is true or false."}

      true ->
        rows = Enum.map(rows, fn row -> Enum.map(row, &String.trim/1) end)
        widths = table["widths"] || Enum.map(by_column(rows), &widest/1)
        {:ok, made(align, rows, widths, table["tight"] == true, table["ruleWidths"])}
    end
  end

  def cast(_), do: {:error, "A table is rows of cells, a header row first."}

  defp cell?(cell), do: is_binary(cell) and not String.contains?(cell, ["\n", "\r"])

  defp valid_widths?(nil, _), do: true

  defp valid_widths?(widths, columns),
    do:
      is_list(widths) and length(widths) == columns and
        Enum.all?(widths, &(is_integer(&1) and &1 >= 0))

  # The table, its marks as wide as `rule` (its widths when nil) and at least what each
  # column's marks take; `ruleWidths` only when that is not the cells' widths.
  defp made(align, rows, widths, tight, rule) do
    rule = Enum.zip_with(align, rule || widths, &max(&2, least(&1, tight)))
    table = %{"align" => align, "rows" => rows, "widths" => widths}
    table = if rule == widths, do: table, else: Map.put(table, "ruleWidths", rule)
    if tight, do: Map.put(table, "tight", true), else: table
  end

  defp rule_widths(table), do: table["ruleWidths"] || table["widths"]

  # The marks of a column take a dash, and a colon for each side it is aligned to.
  defp least(align, tight), do: max(need(align) - if(tight, do: 2, else: 0), 0)

  defp need(nil), do: 1
  defp need("center"), do: 3
  defp need(_), do: 2

  defp by_column(rows), do: Enum.zip_with(rows, & &1)

  defp widest(cells),
    do: cells |> Enum.map(&String.length(escape(&1))) |> Enum.max(&>=/2, fn -> 0 end) |> max(3)

  @doc "The table as GitHub Markdown, with no line end after its last row."
  @spec markdown(map) :: String.t()
  def markdown(%{"rows" => [head | body], "widths" => widths, "align" => align} = table) do
    tight = table["tight"] == true

    marks =
      Enum.zip_with(align, rule_widths(table), fn a, w ->
        if tight, do: marks(a, w + 2), else: " " <> marks(a, w) <> " "
      end)

    [row(head, widths), "|" <> Enum.join(marks, "|") <> "|" | Enum.map(body, &row(&1, widths))]
    |> Enum.join("\n")
  end

  defp row(cells, widths) do
    cells = Enum.zip_with(cells, widths, &(" " <> String.pad_trailing(escape(&1), &2) <> " "))
    "|" <> Enum.join(cells, "|") <> "|"
  end

  defp marks("left", n), do: ":" <> dashes(n - 1)
  defp marks("right", n), do: dashes(n - 1) <> ":"
  defp marks("center", n), do: ":" <> dashes(n - 2) <> ":"
  defp marks(nil, n), do: dashes(n)

  defp dashes(n), do: String.duplicate("-", n)

  defp escape(cell), do: String.replace(cell, "|", "\\|")

  @doc """
  The table GitHub Markdown lines are, however they are spaced, or nil when they are
  not one: a header row, a row of alignment marks, and rows of as many cells, every
  line with a `|` and every cell one line.
  """
  @spec read([String.t()]) :: map | nil
  def read([head, rule | body] = lines) do
    with true <- Enum.all?(lines, &Regex.match?(~r/(?<!\\)\|/, &1)),
         {:ok, align, rule_widths, tight} <- rule(cells(rule)),
         written = Enum.map([head | body], &cells/1),
         true <- Enum.all?(written, &(length(&1) == length(align))),
         rows = Enum.map(written, fn row -> Enum.map(row, &unescape(String.trim(&1))) end),
         true <- Enum.all?(rows, fn row -> Enum.all?(row, &cell?/1) end) do
      widths = Enum.map(by_column(written), &padded_to/1)
      made(align, rows, widths, tight, rule_widths)
    else
      _ -> nil
    end
  end

  def read(_), do: nil

  # A row's cells as written, spaces and all: split at each `|` not escaped, the ones
  # at either end dropped.
  defp cells(line) do
    line = String.trim(line)
    line = if String.starts_with?(line, "|"), do: String.slice(line, 1..-1//1), else: line

    line =
      if String.ends_with?(line, "|") and not String.ends_with?(line, "\\|"),
        do: String.slice(line, 0..-2//1),
        else: line

    Regex.split(~r/(?<!\\)\|/, line)
  end

  # What a column's cells, as written, are padded to: the least width that writes each
  # of them as it was, so 0 when none is padded.
  defp padded_to(cells) do
    widest = cells |> Enum.map(&String.length/1) |> Enum.max()

    Enum.find(0..widest//1, 0, fn width ->
      Enum.all?(cells, &(&1 == " " <> String.pad_trailing(String.trim(&1), width) <> " "))
    end)
  end

  defp rule(cells) do
    marks = Enum.map(cells, &String.trim/1)

    if Enum.all?(marks, &Regex.match?(~r/^:?-+:?$/, &1)) do
      tight = marks == cells
      widths = Enum.map(marks, &max(String.length(&1) - if(tight, do: 2, else: 0), 0))
      {:ok, Enum.map(marks, &align/1), widths, tight}
    end
  end

  defp align(marks) do
    case {String.starts_with?(marks, ":"), String.ends_with?(marks, ":")} do
      {true, true} -> "center"
      {true, false} -> "left"
      {false, true} -> "right"
      {false, false} -> nil
    end
  end

  defp unescape(cell), do: String.replace(cell, "\\|", "|")

  @doc """
  The table after one edit, or why it cannot be made: `setCell` (`row`, `column`,
  `text`), `insertRow` (`at`, the new row's index, 1 or more), `deleteRow` (`row`),
  `insertColumn` (`at`, and `align`), `deleteColumn` (`column`) and `setAlign`
  (`column`, `align`). Rows count from the header, which is row 0 and stays; a table
  keeps one column at least. A new column is 3 wide.
  """
  @spec edit(map, map) :: {:ok, map} | {:error, String.t()}
  def edit(table, %{"type" => "setCell", "row" => r, "column" => c, "text" => text}) do
    cond do
      not (index?(r, rows(table)) and index?(c, columns(table))) ->
        {:error, "There is no cell #{inspect(r)}, #{inspect(c)} in this table."}

      not cell?(text) ->
        {:error, "A table's cell is one line of text."}

      true ->
        rows = List.update_at(table["rows"], r, &List.replace_at(&1, c, String.trim(text)))
        {:ok, %{table | "rows" => rows}}
    end
  end

  def edit(table, %{"type" => "insertRow", "at" => at}) do
    if is_integer(at) and at in 1..rows(table)//1,
      do: {:ok, %{table | "rows" => List.insert_at(table["rows"], at, blank_row(table))}},
      else: {:error, "A row goes after the header, at 1 to #{rows(table)}."}
  end

  def edit(table, %{"type" => "deleteRow", "row" => r}) do
    if index?(r, rows(table)) and r > 0,
      do: {:ok, %{table | "rows" => List.delete_at(table["rows"], r)}},
      else: {:error, "There is no row #{inspect(r)} to delete: the header stays."}
  end

  def edit(table, %{"type" => "insertColumn", "at" => at} = edit) do
    align = edit["align"]

    cond do
      not (is_integer(at) and at in 0..columns(table)//1) ->
        {:error, "A column goes at 0 to #{columns(table)}."}

      align not in @aligns ->
        {:error, "A column's align is left, center, right or null."}

      true ->
        %{"align" => as, "rows" => rows, "widths" => widths} = table

        {:ok,
         made(
           List.insert_at(as, at, align),
           Enum.map(rows, &List.insert_at(&1, at, "")),
           List.insert_at(widths, at, 3),
           table["tight"] == true,
           List.insert_at(rule_widths(table), at, 3)
         )}
    end
  end

  def edit(table, %{"type" => "deleteColumn", "column" => c}) do
    cond do
      not index?(c, columns(table)) ->
        {:error, "There is no column #{inspect(c)} in this table."}

      columns(table) == 1 ->
        {:error, "A table keeps one column at least."}

      true ->
        %{"align" => as, "rows" => rows, "widths" => widths} = table

        {:ok,
         made(
           List.delete_at(as, c),
           Enum.map(rows, &List.delete_at(&1, c)),
           List.delete_at(widths, c),
           table["tight"] == true,
           List.delete_at(rule_widths(table), c)
         )}
    end
  end

  def edit(table, %{"type" => "setAlign", "column" => c} = edit) do
    cond do
      not index?(c, columns(table)) ->
        {:error, "There is no column #{inspect(c)} in this table."}

      edit["align"] not in @aligns ->
        {:error, "A column's align is left, center, right or null."}

      true ->
        align = List.replace_at(table["align"], c, edit["align"])

        {:ok,
         made(align, table["rows"], table["widths"], table["tight"] == true, rule_widths(table))}
    end
  end

  def edit(_table, _edit),
    do:
      {:error,
       "A table edit is setCell, insertRow, deleteRow, insertColumn, deleteColumn or setAlign, with its fields."}

  defp rows(table), do: length(table["rows"])
  defp columns(%{"align" => align}), do: length(align)
  defp index?(i, count), do: is_integer(i) and i >= 0 and i < count
  defp blank_row(table), do: List.duplicate("", columns(table))
end
