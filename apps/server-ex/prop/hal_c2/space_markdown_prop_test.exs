defmodule HalC2.SpaceMarkdownPropTest do
  @moduledoc """
  A page's Markdown (`HalC2.Space.Markdown`) loses nothing, whatever GitHub Markdown it
  is given:

  - the blocks of a document write back as that document, apart from LF line ends and
    exactly one newline at the end;
  - a document with a title on top imports as a page of that title and exports as it was;
  - writing back what was written back changes nothing more;
  - every block is a kind a page has, and every heading has a level;
  - a table (`HalC2.Space.Table`) reads back from its Markdown as the same cells writing
    the same Markdown, before and after any edits, an edit of a cell rewrites only its row, and adding a row or a column then
    removing it gives the table back;
  - a code block reads back from its Markdown as itself, whatever its text holds.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Space.{Blocks, Markdown, Table}

  # Lines of GitHub Markdown, many of them odd: what the corpus holds and what breaks a
  # reader that guesses. Documents are runs of them, with blank lines between or not.
  @lines [
    "# Title",
    "#  Spaced title",
    "## Section",
    "### Sub ###",
    "###### Six",
    "#",
    "Text with **bold**, *italic*, ~~gone~~ and `code`.",
    "A line ending in two spaces  ",
    "Setext heading",
    "===",
    "---",
    "***",
    "- item",
    "- [ ] open task",
    "- [x] done task",
    "* [X] shouted task",
    "  - nested item",
    "    1. deeper",
    "1. first",
    "3) third",
    "+ plus",
    "> quote",
    ">",
    ">lazy quote",
    "> [!NOTE]",
    "| a | b |",
    "| :- | -: |",
    "|---|---|",
    "| `x \\| y` | 2 |",
    "| Name | Note |",
    "| ---- | :--: |",
    "| x    | y    |",
    "|:-|-:|",
    "|a|b|",
    "| --- | --- |",
    "a | b",
    "--- | ---",
    "```",
    "```ts",
    "```mermaid",
    "flowchart LR",
    "    A --> B",
    "~~~",
    "````",
    "~~~~js filename=\"a.js\"",
    "``` ts",
    "```ts title",
    "   ```",
    "```js`",
    "~~~~~",
    "    indented code",
    "\tTab code",
    "$$",
    "x^2",
    "<details>",
    "<summary>More</summary>",
    "</details>",
    "<!-- note",
    "-->",
    "<div>html</div>",
    "<https://example.com>",
    "[^1]: A note.",
    "Text[^1] with a note.",
    "![Image](./a.png)",
    "![Caption](space-image:img-1)",
    "[Linked](#page-1)",
    "[Linked](#page-1) and more",
    "name: front",
    "...",
    "   ",
    " trailing space ",
    "é€ unicode"
  ]

  defp line, do: oneof([elements(@lines), elements(["", "", ""]), utf8(8)])

  defp document do
    let [lines, ending] <- [resize(40, list(line())), elements(["", "\n", "\n\n", "\r\n"])] do
      Enum.join(lines, line_end(lines)) <> ending
    end
  end

  # Mostly LF documents; now and then one written with CRLF throughout.
  defp line_end(lines), do: if(rem(length(lines), 7) == 3, do: "\r\n", else: "\n")

  # The document as it is written back: LF line ends, no blank lines at the end, and one
  # newline after the last line.
  defp normal(markdown) do
    markdown
    |> String.replace(~r/\r+(?=\n|\z)/, "")
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> case do
      [] -> ""
      lines -> lines |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n")
    end
  end

  property "a document's blocks write back as the document", numtests: HalC2.Prop.numtests(500) do
    forall markdown <- document() do
      written = markdown |> Markdown.blocks() |> Markdown.document(fn _ -> nil end)

      (written == normal(markdown))
      |> when_fail(
        IO.puts("""
        markdown: #{inspect(markdown)}
        written:  #{inspect(written)}
        blocks:   #{inspect(Markdown.blocks(markdown))}
        """)
      )
    end
  end

  property "a titled document is a page that exports as it was",
    numtests: HalC2.Prop.numtests(300) do
    forall body <- document() do
      markdown = "# Plan\n\n" <> body

      case Markdown.parse(markdown) do
        {"Plan", blocks} ->
          Markdown.export(%{"title" => "Plan"}, blocks, fn _ -> nil end) == normal(markdown)

        other ->
          when_fail(IO.inspect(other, label: "parsed"), false)
      end
    end
  end

  property "writing back what was written back changes nothing",
    numtests: HalC2.Prop.numtests(300) do
    forall markdown <- document() do
      once = markdown |> Markdown.blocks() |> Markdown.document(fn _ -> nil end)
      twice = once |> Markdown.blocks() |> Markdown.document(fn _ -> nil end)
      Markdown.blocks(once) == Markdown.blocks(twice) and once == twice
    end
  end

  # A gap is the spacing a block was read under. After a page deletes the block above it,
  # the gap must not join it to the block now above where the usual blank line would keep
  # them apart. (Some blocks join whatever the spacing, such as two raw lists once the
  # heading between them goes: Markdown has nothing that keeps those apart.)
  property "a gap never joins a block to a new block above it",
    numtests: HalC2.Prop.numtests(300) do
    forall {markdown, n} <- {document(), non_neg_integer()} do
      blocks = Markdown.blocks(markdown)
      left = if blocks == [], do: [], else: List.delete_at(blocks, rem(n, length(blocks)))

      read = fn blocks ->
        blocks
        |> Markdown.document(fn _ -> nil end)
        |> Markdown.blocks()
        |> Enum.map(&{&1["kind"], &1["text"]})
      end

      gapped = read.(left)
      usual = read.(Enum.map(left, &Map.delete(&1, "gap")))
      kept = Enum.map(left, &{&1["kind"], &1["text"]})

      (usual != kept or gapped == kept)
      |> when_fail(IO.puts("markdown: #{inspect(markdown)}\nleft: #{inspect(left)}"))
    end
  end

  property "every block is a kind a page has, and a heading has a level",
    numtests: HalC2.Prop.numtests(300) do
    forall markdown <- document() do
      Enum.all?(Markdown.blocks(markdown), fn block ->
        block["kind"] in Blocks.kinds() and
          (block["kind"] != "heading" or block["level"] in 1..6)
      end)
    end
  end

  # --- tables -------------------------------------------------------------------------

  @cells ["", "a", "Step", "a | b", "`x \\| y`", "**bold**", "é€", " spaced ", "\\", "-", ":--"]

  defp cell, do: oneof([elements(@cells), utf8(6)])

  defp table do
    let [columns, rows, tight, widths?, rule?] <- [
          integer(1, 4),
          integer(0, 3),
          boolean(),
          boolean(),
          boolean()
        ] do
      let [rows, align, widths, rule] <- [
            vector(rows + 1, vector(columns, cell())),
            vector(columns, elements([nil, "left", "center", "right"])),
            vector(columns, integer(0, 8)),
            vector(columns, integer(0, 8))
          ] do
        rows = Enum.map(rows, fn row -> Enum.map(row, &String.replace(&1, ~r/[\r\n]/, "")) end)

        spec =
          %{"rows" => rows, "align" => align, "tight" => tight}
          |> then(&if(widths?, do: Map.put(&1, "widths", widths), else: &1))
          |> then(&if(rule?, do: Map.put(&1, "ruleWidths", rule), else: &1))

        {:ok, table} = Table.cast(spec)
        table
      end
    end
  end

  defp table_edit do
    oneof([
      {:setCell, integer(0, 4), integer(0, 4), cell()},
      {:insertRow, integer(0, 5)},
      {:deleteRow, integer(0, 4)},
      {:insertColumn, integer(0, 4), elements([nil, "left", "center", "right"])},
      {:deleteColumn, integer(0, 4)},
      {:setAlign, integer(0, 4), elements([nil, "left", "center", "right"])}
    ])
  end

  defp edit_of({:setCell, r, c, text}),
    do: %{
      "type" => "setCell",
      "row" => r,
      "column" => c,
      "text" => String.replace(text, ~r/[\r\n]/, "")
    }

  defp edit_of({:insertRow, at}), do: %{"type" => "insertRow", "at" => at}
  defp edit_of({:deleteRow, r}), do: %{"type" => "deleteRow", "row" => r}
  defp edit_of({:insertColumn, at, a}), do: %{"type" => "insertColumn", "at" => at, "align" => a}
  defp edit_of({:deleteColumn, c}), do: %{"type" => "deleteColumn", "column" => c}
  defp edit_of({:setAlign, c, a}), do: %{"type" => "setAlign", "column" => c, "align" => a}

  # Its Markdown reads as a table of the same cells that writes that Markdown again, and
  # as one table block of it. Widths a table's Markdown does not show (a column whose
  # cells are all as wide as it or wider) need not come back.
  defp reads_back?(table) do
    markdown = Table.markdown(table)
    read = Table.read(String.split(markdown, "\n"))
    same = &Map.take(&1, ~w(align rows tight))

    read != nil and same.(read) == same.(table) and Table.markdown(read) == markdown and
      match?([%{"kind" => "table", "table" => ^read}], Markdown.blocks(markdown))
  end

  property "a table reads back as the same table, before and after any edits",
    numtests: HalC2.Prop.numtests(500) do
    forall {table, edits} <- {table(), list(table_edit())} do
      tables =
        Enum.scan(edits, table, fn edit, table ->
          case Table.edit(table, edit_of(edit)) do
            {:ok, edited} -> edited
            {:error, _} -> table
          end
        end)

      Enum.all?([table | tables], &reads_back?/1)
      |> when_fail(IO.puts("table: #{inspect(table)}\nedits: #{inspect(edits)}"))
    end
  end

  property "an edit of a cell rewrites only its row", numtests: HalC2.Prop.numtests(500) do
    forall {table, r, c, text} <- {table(), integer(0, 3), integer(0, 3), cell()} do
      edit = edit_of({:setCell, r, c, text})

      case Table.edit(table, edit) do
        {:ok, edited} ->
          line = if r == 0, do: 0, else: r + 1
          before = String.split(Table.markdown(table), "\n")
          now = String.split(Table.markdown(edited), "\n")
          List.delete_at(before, line) == List.delete_at(now, line)

        {:error, _} ->
          r >= length(table["rows"]) or c >= length(table["align"])
      end
    end
  end

  property "adding a row or a column then removing it gives the table back",
    numtests: HalC2.Prop.numtests(500) do
    forall {table, at} <- {table(), integer(0, 4)} do
      row =
        with {:ok, more} <- Table.edit(table, %{"type" => "insertRow", "at" => at}),
             do: Table.edit(more, %{"type" => "deleteRow", "row" => at})

      column =
        with {:ok, more} <- Table.edit(table, %{"type" => "insertColumn", "at" => at}),
             do: Table.edit(more, %{"type" => "deleteColumn", "column" => at})

      (row == {:ok, table} or (at == 0 or at > length(table["rows"]))) and
        (column == {:ok, table} or at > length(table["align"]))
    end
  end

  @table_lines [
    "| a | b |",
    "|---|---|",
    "| --- | :-: |",
    "|a\rb|c|",
    "",
    "Notes for later",
    "| Step |",
    "| --- |",
    "a | b",
    "--- | ---",
    "| x \\| y |"
  ]

  property "text read as a table is a table a page accepts, every line of it a row",
    numtests: HalC2.Prop.numtests(500) do
    forall lines <- list(oneof([elements(@table_lines), utf8(6)])) do
      case Table.read(lines) do
        nil ->
          true

        read ->
          Table.cast(Map.take(read, ~w(rows align widths ruleWidths tight))) == {:ok, read} and
            length(read["rows"]) == length(lines) - 1
      end
    end
  end

  # --- code ---------------------------------------------------------------------------

  @code_lines [
    "",
    "  ",
    "x = 1",
    "```",
    "~~~",
    "````",
    "  ```",
    "```ts",
    "~~~~",
    "   ~~~ ",
    "\tTab"
  ]

  defp code_block do
    let [lines, fence, language, info] <- [
          resize(6, list(oneof([elements(@code_lines), utf8(6)]))),
          elements(["```", "~~~", "````", "~~~~"]),
          elements([nil, "ts", "mermaid", "c++", "x`y", "~js"]),
          elements([nil, "", " title=\"a\"", "  {.x} ", "x"])
        ] do
      text = lines |> Enum.join("\n") |> String.replace("\r", "")

      %{"kind" => "code", "text" => text, "fence" => fence}
      |> then(&if(language, do: Map.put(&1, "language", language), else: &1))
      |> then(&if(info, do: Map.put(&1, "info", info), else: &1))
    end
  end

  property "a code block reads back as itself, whatever its text holds",
    numtests: HalC2.Prop.numtests(500) do
    forall block <- code_block() do
      implies Markdown.code?(block) do
        read = Markdown.blocks(Markdown.render(block))
        fields = &Map.take(&1, ~w(kind text language info))

        (match?([_], read) and
           fields.(hd(read)) ==
             fields.(if(block["info"] == "", do: Map.delete(block, "info"), else: block)))
        |> when_fail(IO.puts("block: #{inspect(block)}\nread: #{inspect(read)}"))
      end
    end
  end
end
