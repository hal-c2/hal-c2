defmodule HalC2.SpaceMarkdownTest do
  # `HalC2.Space.Markdown` gives back what it read, byte for byte. The fixtures in
  # `test/fixtures/markdown` are synthetic stand-ins for a real repository's docs; set
  # `HAL_C2_MARKDOWN_CORPUS` to a directory to also read every `.md` under it (read
  # only) and check each file comes back as it was.
  use ExUnit.Case, async: true

  alias HalC2.Space.{Blocks, Markdown, Table}

  @fixtures Path.expand("../fixtures/markdown", __DIR__)
  defp none(_id), do: nil

  defp round_trip(markdown), do: markdown |> Markdown.blocks() |> Markdown.document(&none/1)

  defp kinds(markdown), do: markdown |> Markdown.blocks() |> Enum.map(& &1["kind"])

  describe "fixtures" do
    for file <- Path.wildcard(Path.join(@fixtures, "*.md")) do
      @file_path file
      test "#{Path.basename(file)} comes back byte for byte" do
        markdown = File.read!(@file_path)
        assert round_trip(markdown) == markdown

        case Markdown.parse(markdown) do
          {nil, _} ->
            :ok

          {title, blocks} ->
            assert Markdown.export(%{"title" => title}, blocks, &none/1) == markdown
        end
      end
    end
  end

  describe "the corpus" do
    @corpus System.get_env("HAL_C2_MARKDOWN_CORPUS")
    @tag skip: is_nil(@corpus) && "set HAL_C2_MARKDOWN_CORPUS to a directory of Markdown"
    test "every Markdown file under HAL_C2_MARKDOWN_CORPUS comes back as it was" do
      files = Path.wildcard(Path.join(Path.expand(@corpus || "."), "**/*.md"))
      assert files != []

      changed =
        for file <- files,
            markdown = File.read!(file),
            String.valid?(markdown),
            round_trip(markdown) != normal(markdown),
            do: file

      assert changed == []
    end
  end

  # What a document is once written back: LF line ends and one newline at the end.
  defp normal(markdown) do
    case markdown |> String.replace(~r/\r+(?=\n|\z)/, "") |> String.split("\n") |> trim_blank() do
      [] -> ""
      lines -> Enum.join(lines, "\n") <> "\n"
    end
  end

  defp trim_blank(lines),
    do: lines |> Enum.reverse() |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()

  describe "blocks" do
    test "a form a page does not model is a raw block of its source" do
      html = "<p align=\"center\">one</p>"
      assert [%{"kind" => "raw", "text" => ^html}] = Markdown.blocks(html)
    end

    test "a table is its cells, how its columns align and how wide it was written" do
      table = "| Step | Owner |\n| :--- | ----: |\n| MC   | Ada   |\n| QML  | Grace |"

      assert [
               %{
                 "kind" => "table",
                 "text" => ^table,
                 "table" => %{
                   "align" => ["left", "right"],
                   "rows" => [["Step", "Owner"], ["MC", "Ada"], ["QML", "Grace"]],
                   "widths" => [4, 5]
                 }
               }
             ] = Markdown.blocks(table)
    end

    test "a table comes back padded, compact or tight as it was written" do
      for table <- [
            "| a | b |\n|---|---|\n| 1 | 2 |",
            "| a | b |\n| --- | --- |\n| 1 | 2 |",
            "| Name     | Note |\n| --- | :-: |\n| x        | y    |\n| a longer one | four |",
            "| Name | Note |\n|------|------|\n| x    | a longer note |",
            "| a | b |\n|:-:|--:|\n| 1 | 2 |",
            "| Pipe | Code |\n| ---- | ---- |\n| a \\| b | `x`  |"
          ] do
        assert kinds(table) == ["table"]
        assert round_trip(table) == table <> "\n"
      end

      assert [%{"table" => %{"rows" => [_, ["a | b", "`x`"]]}}] =
               Markdown.blocks("| Pipe | Code |\n| ---- | ---- |\n| a \\| b | `x`  |")
    end

    test "a table written another way is raw" do
      for table <- [
            "| a | b |\n| --- | --- |\n|  1 | 2 |",
            "a | b\n--- | ---\n1 | 2",
            "| a | b |\n|---|---|\n| 1 |",
            "| Total |\n| ----: |\n|    12 |"
          ] do
        assert kinds(table) == ["raw"]
        assert round_trip(table) == table <> "\n"
      end
    end

    test "a table made in a page is padded to its widest cell" do
      {:ok, table} = Table.cast(%{"rows" => [["Step", "Owner"], ["MC", "a | b"]]})

      assert Table.markdown(table) ==
               "| Step | Owner  |\n| ---- | ------ |\n| MC   | a \\| b |"

      assert Table.read(String.split(Table.markdown(table), "\n")) == table
    end

    test "cells not padded stay so, whatever the rule row's width" do
      [%{"table" => table}] = Markdown.blocks("| Step | Owner |\n| --- | --- |\n| MC | Ada |")
      assert %{"widths" => [0, 0], "ruleWidths" => [3, 3]} = table

      {:ok, edited} =
        Table.edit(table, %{"type" => "setCell", "row" => 1, "column" => 1, "text" => "Barbara"})

      assert Table.markdown(edited) == "| Step | Owner |\n| --- | --- |\n| MC | Barbara |"
      {:ok, wider} = Table.edit(table, %{"type" => "insertColumn", "at" => 2})
      {:ok, back} = Table.edit(wider, %{"type" => "deleteColumn", "column" => 2})
      assert back == table
    end

    test "an edit rewrites only the rows it changes" do
      [%{"table" => table}] =
        Markdown.blocks("| Step | Owner |\n| ---- | ----- |\n| MC   | Ada   |\n| QML  | Grace |")

      {:ok, edited} =
        Table.edit(table, %{"type" => "setCell", "row" => 1, "column" => 1, "text" => "Barbara"})

      assert Table.markdown(edited) ==
               "| Step | Owner |\n| ---- | ----- |\n| MC   | Barbara |\n| QML  | Grace |"

      {:ok, wider} = Table.edit(table, %{"type" => "insertColumn", "at" => 2, "align" => "right"})
      assert hd(String.split(Table.markdown(wider), "\n")) == "| Step | Owner |     |"
      assert Enum.at(String.split(Table.markdown(wider), "\n"), 1) == "| ---- | ----- | --: |"

      assert {:ok, %{"rows" => [_, ["", ""], _, _]}} =
               Table.edit(table, %{"type" => "insertRow", "at" => 1})

      assert {:error, _} = Table.edit(table, %{"type" => "deleteRow", "row" => 0})
      assert {:ok, one} = Table.edit(table, %{"type" => "deleteColumn", "column" => 0})
      assert {:error, _} = Table.edit(one, %{"type" => "deleteColumn", "column" => 0})
    end

    test "code is its text, with the fence, language and info it was written with" do
      assert [%{"kind" => "code", "text" => "const a = 1\n\n// two", "language" => "ts"} = code] =
               Markdown.blocks("```ts\nconst a = 1\n\n// two\n```")

      refute Map.has_key?(code, "fence") or Map.has_key?(code, "info")

      assert [%{"fence" => "~~~~", "language" => "js", "info" => " filename=\"a.js\""}] =
               Markdown.blocks("~~~~js filename=\"a.js\"\n~~~\n~~~~")

      for code <- [
            "```\n```",
            "```mermaid\ngraph TD\n  A --> B\n```",
            "````md\n```ts\nx\n```\n````",
            "~~~\nplain\n~~~"
          ] do
        assert kinds(code) == ["code"]
        assert round_trip(code) == code <> "\n"
      end
    end

    test "a fence written another way is raw" do
      for code <- ["  ```ts\n  x\n  ```", "``` ts\nx\n```", "```ts\nx\n````", "```ts\nx"] do
        assert kinds(code) == ["raw"]
        assert round_trip(code) == code <> "\n"
      end
    end

    test "code whose text would close its fence is written with a longer one" do
      block = %{"kind" => "code", "text" => "```\ninside\n```", "language" => "md"}
      assert Markdown.render(block) == "````md\n```\ninside\n```\n````"

      assert [%{"kind" => "code", "text" => "```\ninside\n```", "fence" => "````"}] =
               Markdown.blocks(Markdown.render(block))
    end

    test "headings keep their level, and one written another way is raw" do
      assert [
               %{"kind" => "heading", "level" => 1, "text" => "One"},
               %{"kind" => "heading", "level" => 3, "text" => "Three"},
               %{"kind" => "heading", "level" => 6, "text" => "Six"}
             ] = Markdown.blocks("# One\n\n### Three\n\n###### Six")

      assert kinds("## Closed ##") == ["raw"]
      assert kinds("##  Spaced") == ["raw"]
      assert kinds("Setext\n===") == ["raw"]
    end

    test "a task list is checklist items, beside other items or under them" do
      assert [
               %{"kind" => "checklist", "checked" => true, "text" => "MC"},
               %{"kind" => "checklist", "checked" => false, "text" => "QML"}
             ] = Markdown.blocks("- [x] MC\n- [ ] QML")

      assert kinds("- [x] MC\n- QML") == ["checklist", "bullet"]
      assert [_, %{"kind" => "checklist", "depth" => 1}] = Markdown.blocks("1. MC\n   - [ ] QML")
      assert kinds("- [X] MC") == ["raw"]
      assert kinds("* [ ] MC") == ["raw"]
    end

    test "each list item is a block of its kind, depth, marker and start" do
      assert [
               %{"kind" => "bullet", "text" => "a"} = a,
               %{"kind" => "numbered", "depth" => 1, "start" => 3, "marker" => ")"},
               %{"kind" => "numbered", "depth" => 1, "text" => "c"} = c,
               %{"kind" => "bullet", "depth" => 2, "indent" => 7, "marker" => "*"}
             ] = Markdown.blocks("- a\n\n  3) b\n  4) c\n       * d")

      refute Map.has_key?(a, "depth")
      refute Map.has_key?(c, "start")
    end

    test "an item's text runs on in the lines under it, blank lines and code too" do
      assert [%{"text" => "a\nmore\n\n```\n- x\n```"}, %{"text" => "b"}] =
               Markdown.blocks("- a\n  more\n\n  ```\n  - x\n  ```\n- b")
    end

    test "a list keeps how it was written, or is raw" do
      for written <- [
            "* a\n* b\n\n+ c",
            "1. a\n2. b\n\n3. c",
            "- a\n    - b\n- c",
            "-\n- b",
            "- a\n---\n- b",
            "- a\n\n  3. b",
            "- a\n-\n- c"
          ] do
        assert round_trip(written) == written <> "\n"
        refute "raw" in kinds(written), written
      end

      for written <- [
            "- a\nlazy",
            "1. a\n3. b",
            "- a\n  - b\n  c",
            "- a\n2. b",
            "-\ta",
            "- a\n\t- b",
            "-\n  a",
            "1. a\n   - b\n\n   more a\n2. c",
            "- a\n  3. b",
            "- a\n*"
          ] do
        assert round_trip(written) == written <> "\n"
        assert kinds(written) == ["raw"], written
      end
    end

    test "a list item is numbered after the one before it in its list" do
      blocks = [
        %{"kind" => "numbered", "text" => "a", "start" => 7},
        %{"kind" => "numbered", "text" => "b"},
        %{"kind" => "bullet", "text" => "c", "depth" => 1},
        %{"kind" => "numbered", "text" => "d"},
        %{"kind" => "numbered", "text" => "e", "marker" => ")"},
        %{"kind" => "paragraph", "text" => "f"},
        %{"kind" => "numbered", "text" => "g", "depth" => 3}
      ]

      assert Markdown.document(blocks, &none/1) ==
               "7. a\n8. b\n   - c\n9. d\n1) e\n\nf\n\n1. g\n"
    end

    test "a list that would read as an item's text is written a blank line under it" do
      a = %{"kind" => "bullet", "text" => "a"}

      for {item, written} <- [
            {%{"kind" => "numbered", "text" => "b", "start" => 3, "depth" => 1},
             "- a\n\n  3. b\n"},
            {%{"kind" => "bullet", "text" => "", "marker" => "*"}, "- a\n\n*\n"},
            {%{"kind" => "numbered", "text" => "b", "depth" => 1}, "- a\n  1. b\n"},
            {%{"kind" => "bullet", "text" => ""}, "- a\n-\n"}
          ] do
        assert Markdown.document([a, item], &none/1) == written
        assert round_trip(written) == written
      end

      # The heading between them deleted, the second list keeps its gap of no blank line.
      [item, _heading, third] = Markdown.blocks("- item\n# Title\n3) third")
      written = Markdown.document([item, third], &none/1)
      assert written == "- item\n\n3) third\n"
      assert kinds(written) == ["bullet", "numbered"]
    end

    test "a quote is a callout only when written as one would be" do
      assert [%{"kind" => "callout", "text" => "Mind\nthe trash"} = callout] =
               Markdown.blocks("> Mind\n> the trash")

      refute Map.has_key?(callout, "alert")
      assert kinds(">lazy") == ["raw"]
    end

    test "a quote keeps its blank lines written `> `, and a line's break of two spaces" do
      assert [%{"text" => "Mind\n\nthe trash", "marker" => "> "}] =
               Markdown.blocks("> Mind\n> \n> the trash")

      assert [%{"text" => "Mind\n\nthe trash"} = plain] =
               Markdown.blocks("> Mind\n>\n> the trash")

      refute Map.has_key?(plain, "marker")
      assert [%{"text" => "Mind  \nthe trash"}] = Markdown.blocks("> Mind  \n> the trash")

      for written <- ["> Mind\n> \n> the trash", "> [!NOTE]\n> \n> Mind", "> Mind  \n> the trash"] do
        assert round_trip(written) == written <> "\n"
      end

      assert kinds("> a\n>\n> b\n> \n> c") == ["raw"]
    end

    test "a GitHub alert is a callout of its kind" do
      for alert <- Markdown.alerts() do
        written = "> [!#{String.upcase(alert)}]\n> Mind\n> the trash"

        assert [%{"kind" => "callout", "alert" => ^alert, "text" => "Mind\nthe trash"}] =
                 Markdown.blocks(written)

        assert round_trip(written) == written <> "\n"
      end

      assert [%{"text" => "[!TIP]"} = tip] = Markdown.blocks("> [!TIP]")
      refute Map.has_key?(tip, "alert")
      assert [%{"text" => "[!note]\nx"} = lower] = Markdown.blocks("> [!note]\n> x")
      refute Map.has_key?(lower, "alert")
    end

    test "a rule is a divider that keeps how it was written; one with spaces around is raw" do
      assert [_, %{"kind" => "divider"} = divider, _] = Markdown.blocks("a\n\n---\n\nb")
      refute Map.has_key?(divider, "marker")

      for rule <- ["***", "___", "- - -", "----", "* * *"] do
        assert [_, %{"kind" => "divider", "marker" => ^rule}, _] =
                 Markdown.blocks("a\n\n#{rule}\n\nb")

        assert round_trip("a\n\n#{rule}\n\nb") == "a\n\n#{rule}\n\nb\n"
      end

      for rule <- [" ---", "***  ", "*\t*\t*"] do
        assert kinds("a\n\n#{rule}\n\nb") == ["paragraph", "raw", "paragraph"], rule
      end

      assert kinds("+ a\n\n\n* * *") == ["bullet", "divider"]
      assert round_trip("+ a\n\n\n* * *") == "+ a\n\n\n* * *\n"
      assert kinds("a\n***") == ["paragraph", "divider"]
      assert round_trip("a\n***") == "a\n***\n"
      assert Markdown.document([%{"kind" => "divider", "text" => ""}], &none/1) == "---\n"
    end

    test "blank lines that are not the usual ones are the block's gap" do
      assert [_, %{"gap" => "\n"}, %{"gap" => "\n\n\n"}] =
               Markdown.blocks("# Plan\nText under it\n\n\nTwo lines down")

      assert [%{"gap" => "\n\n"}] = Markdown.blocks("\nAfter a blank line")

      assert Enum.all?(
               Markdown.blocks("# Plan\n\nText\n\n- [ ] a\n- [ ] b"),
               &(not Map.has_key?(&1, "gap"))
             )
    end

    test "CRLF reads as LF and the document ends with one newline" do
      assert round_trip("# Plan\r\n\r\nShip\r\n") == "# Plan\n\nShip\n"
      # Found by the round-trip property: `\r\r\n` once read as `\r\n`, which the next
      # read took for a line end again.
      assert round_trip("Ship\r\r\nit\r") == "Ship\nit\n"
      assert round_trip("Ship\n\n\n") == "Ship\n"
      assert round_trip("Ship") == "Ship\n"
      assert round_trip("\n \n") == ""
    end

    # Found by the round-trip property: an open fence took the blank lines at the end of
    # the file into its block, so each export grew the file by a line.
    test "a part left open at the end does not take the blank lines after it" do
      for open <- ["```", "$$", "<details>", "<!-- note"] do
        assert Markdown.blocks(open <> "\n\n\n") == Markdown.blocks(open)
        assert round_trip(round_trip(open <> "\n\n")) == open <> "\n"
      end
    end

    test "front matter, details, comments and math are kept whole" do
      markdown = """
      ---
      name: role

      tags: [a]
      ---

      <details>
      <summary>More</summary>

      <details>
      Inner
      </details>

      Still inside
      </details>

      <!-- a

      note -->

      $$
      x^2

      y
      $$
      """

      assert kinds(markdown) == ~w(raw raw raw raw)
      assert round_trip(markdown) == markdown
    end

    test "a page's own blocks write as they always have" do
      blocks = [
        %{"kind" => "heading", "text" => "Goals"},
        %{"kind" => "paragraph", "text" => "Ship"},
        %{"kind" => "raw", "text" => "| a |\n|---|"},
        %{"kind" => "checklist", "text" => "MC", "checked" => true},
        %{"kind" => "checklist", "text" => "QML", "checked" => false}
      ]

      assert Markdown.export(%{"title" => "Plan"}, blocks, &none/1) ==
               "# Plan\n\n## Goals\n\nShip\n\n| a |\n|---|\n\n- [x] MC\n- [ ] QML\n"
    end

    # Found in review: a block right under a heading kept writing no blank line above it
    # once the heading was deleted, and joined the paragraph that was now above it.
    test "no blank line is written only where the block still reads apart" do
      [intro, _heading, para, fence] = Markdown.blocks("Intro\n\n## H\nPara\n```\ncode\n```\n")
      assert para["gap"] == "\n" and fence["gap"] == "\n"

      written = Markdown.document([intro, para, fence], &none/1)
      assert written == "Intro\n\nPara\n```\ncode\n```\n"
      assert written |> Markdown.blocks() |> length() == 3
    end

    # Found in review: the title was taken only from `# X` on the very first line.
    test "a title is a level 1 heading however it is spaced" do
      for markdown <- ["\n# Plan\n\nShip\n", "#  Plan\n\nShip\n", "# Plan #\n\nShip\n"] do
        assert {"Plan", [%{"text" => "Ship"} = ship]} = Markdown.parse(markdown)

        assert Markdown.export(%{"title" => "Plan"}, [ship], &none/1) == "# Plan\n\nShip\n"
      end

      assert {nil, _} = Markdown.parse("## Plan\n\nShip\n")
      assert {nil, _} = Markdown.parse("#\n\nShip\n")
    end

    test "a gap that is not blank lines is ignored" do
      blocks = [
        %{"kind" => "paragraph", "text" => "One"},
        %{"kind" => "paragraph", "text" => "Two", "gap" => "\nnot blank\n"}
      ]

      assert Markdown.document(blocks, &none/1) == "One\n\nTwo\n"
    end

    test "every block is a kind the page has" do
      for file <- Path.wildcard(Path.join(@fixtures, "*.md")),
          block <- Markdown.blocks(File.read!(file)),
          do: assert(block["kind"] in Blocks.kinds())
    end
  end
end
