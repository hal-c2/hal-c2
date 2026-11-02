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
  - a code block reads back from its Markdown as itself, whatever its text holds;
  - list items the page writes, however nested, numbered and marked, read back as the
    same items writing the same Markdown;
  - a callout, alert or not, however its blank lines are written, and a divider, however
    its rule is, read back as themselves.
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
    "> [!WARNING]",
    "> [!tip]",
    "- - -",
    "* * *",
    "___",
    "  continued text",
    "   1. three in",
    "2. second",
    "4) fourth",
    "-",
    "1.",
    "- [ ] ",
    "      - six in",
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
    "<details open><summary>Open</summary>",
    "  <summary>Set in</summary>",
    "</details>",
    "<!-- note",
    "-->",
    "<div>html</div>",
    "<https://example.com>",
    "[^1]: A note.",
    "[^long-note]:",
    "    more of the note",
    "Text[^1] with a note.",
    "![Image](./a.png)",
    "![A cat](https://example.com/cat.png)",
    "![Titled](a.png \"T\")",
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

  # --- lists, callouts and dividers -----------------------------------------------------

  @item_texts ["Tag", "Ship it", "", "two\nlines", "a\n\nparagraph", "```\n- x\n```", "**bold**"]

  defp list_item do
    let [kind, depth, indent, text, marker, start, checked] <- [
          elements(["bullet", "numbered", "checklist"]),
          integer(0, 4),
          oneof([nil, integer(0, 9)]),
          elements(@item_texts),
          elements([nil, "*", "+", ")"]),
          oneof([nil, integer(0, 12)]),
          boolean()
        ] do
      # A task's text starts as a paragraph after its `[ ]`, so it cannot open with code.
      text = if kind == "checklist" and String.starts_with?(text, "```"), do: "Tag", else: text

      %{"kind" => kind, "text" => text, "depth" => depth}
      |> then(&if(indent, do: Map.put(&1, "indent", indent), else: &1))
      |> then(&if(kind == "checklist", do: Map.put(&1, "checked", checked), else: &1))
      |> then(&if(kind == "numbered" and start, do: Map.put(&1, "start", start), else: &1))
      |> then(&if(marker(kind, marker), do: Map.put(&1, "marker", marker), else: &1))
    end
  end

  defp marker("bullet", marker) when marker in ["*", "+"], do: true
  defp marker("numbered", ")"), do: true
  defp marker(_kind, _marker), do: false

  # A page's blocks around its lists: items, now and then a paragraph or a divider.
  defp list_blocks do
    resize(
      12,
      list(
        frequency([
          {8, list_item()},
          {1, exactly(%{"kind" => "paragraph", "text" => "Between"})},
          {1, divider()}
        ])
      )
    )
  end

  # A divider, written `---` or as a rule it keeps.
  defp divider do
    let marker <- elements([nil, "***", "___", "- - -", "----", "* * *"]) do
      if marker,
        do: %{"kind" => "divider", "text" => "", "marker" => marker},
        else: %{"kind" => "divider", "text" => ""}
    end
  end

  # Each item as it is written: its kind, text, tick, depth and number.
  defp items(blocks) do
    blocks
    |> Enum.zip(Markdown.list_items(blocks))
    |> Enum.map(fn
      {block, nil} -> {block["kind"], block["text"], block["marker"]}
      {block, item} -> {block["kind"], block["text"], checked(block), item.depth, item.number}
    end)
  end

  defp checked(%{"kind" => "checklist", "checked" => checked}), do: checked
  defp checked(_block), do: nil

  # A page's Markdown, under its title, and the blocks it reads back as.
  defp page(blocks) do
    written = Markdown.export(%{"title" => "Plan"}, blocks, fn _ -> nil end)
    {"Plan", read} = Markdown.parse(written)
    {written, read}
  end

  property "list items the page writes read back as the same items",
    numtests: HalC2.Prop.numtests(500) do
    forall blocks <- list_blocks() do
      {written, read} = page(blocks)

      (items(read) == items(blocks) and elem(page(read), 0) == written)
      |> when_fail(
        IO.puts("""
        blocks:  #{inspect(blocks)}
        written: #{inspect(written)}
        read:    #{inspect(read)}
        """)
      )
    end
  end

  property "a callout and a divider read back as themselves",
    numtests: HalC2.Prop.numtests(500) do
    forall {text, alert, marker, divider} <-
             {elements(["a line  \nbroken" | @item_texts]), elements([nil | Markdown.alerts()]),
              elements([nil, "> "]), divider()} do
      callout =
        %{"kind" => "callout", "text" => text}
        |> then(&if(alert, do: Map.put(&1, "alert", alert), else: &1))
        |> then(
          &if(marker && String.contains?(text, "\n\n"),
            do: Map.put(&1, "marker", marker),
            else: &1
          )
        )

      blocks = [callout, divider]
      {_, read} = page(blocks)

      (Enum.map(read, &Map.take(&1, ~w(kind text alert marker))) == blocks)
      |> when_fail(IO.puts("blocks: #{inspect(blocks)}\nread: #{inspect(read)}"))
    end
  end

  # --- footnotes, math, collapsed sections and images by address ------------------------

  # A note whose first line starts with spaces reads back raw, so it is kept whole.
  @note_texts ["A note.", "", "two\nlines", "a\n\nparagraph", "a\n    set in", "- not a list"]

  defp footnote do
    let [label, text] <- [elements(["1", "note", "a-b_2", "é"]), elements(@note_texts)] do
      %{"kind" => "footnote", "text" => text, "label" => label}
    end
  end

  # Math between `$$` lines holds no blank line and no `$$` line: those write as fences.
  defp math do
    let text <- elements(["x^2", "", "a\nb", "\\frac{1}{2}", "```", " $ "]) do
      %{"kind" => "code", "text" => text, "language" => "math", "fence" => "$$"}
    end
  end

  defp url_image do
    let [text, url] <- [
          elements(["A cat", "", "**b**"]),
          elements([
            "https://x.test/a.png",
            "./a.png",
            "a.png?x=1&y=2",
            "data:image/png;base64,A="
          ])
        ] do
      %{"kind" => "image", "text" => text, "url" => url}
    end
  end

  @between %{"kind" => "paragraph", "text" => "Between"}

  # A collapsed section: its opening, the blocks inside and its end.
  defp section do
    let [summary, marker, inside] <- [
          elements(["Logs", "", "a <b>b</b>"]),
          elements([
            nil,
            "<details open>\n<summary>",
            "<details><summary>",
            "<details>\n  <summary>"
          ]),
          resize(4, list(oneof([footnote(), math(), url_image(), exactly(@between)])))
        ] do
      details = %{"kind" => "details", "text" => summary}
      details = if marker, do: Map.put(details, "marker", marker), else: details
      [details | inside] ++ [%{"kind" => "details_end", "text" => ""}]
    end
  end

  defp step3_blocks do
    let parts <-
          resize(
            8,
            list(
              frequency([
                {2, let(b <- footnote(), do: [b])},
                {2, let(b <- math(), do: [b])},
                {2, let(b <- url_image(), do: [b])},
                {1, exactly([@between])},
                {2, section()}
              ])
            )
          ) do
      Enum.concat(parts)
    end
  end

  property "footnotes, math, collapsed sections and images read back as themselves",
    numtests: HalC2.Prop.numtests(500) do
    forall blocks <- step3_blocks() do
      {written, read} = page(blocks)
      fields = &Map.take(&1, ~w(kind text label language fence marker url))

      (Enum.map(read, fields) == blocks and elem(page(read), 0) == written)
      |> when_fail(
        IO.puts("""
        blocks:  #{inspect(blocks)}
        written: #{inspect(written)}
        read:    #{inspect(read)}
        """)
      )
    end
  end
end
