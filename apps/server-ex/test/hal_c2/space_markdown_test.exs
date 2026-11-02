defmodule HalC2.SpaceMarkdownTest do
  # `HalC2.Space.Markdown` gives back what it read, byte for byte. The fixtures in
  # `test/fixtures/markdown` are synthetic stand-ins for a real repository's docs; set
  # `HAL_C2_MARKDOWN_CORPUS` to a directory to also read every `.md` under it (read
  # only) and check each file comes back as it was.
  use ExUnit.Case, async: true

  alias HalC2.Space.{Blocks, Markdown}

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
      table = "| a | b |\n|---|---|\n| 1 | 2 |"
      fence = "```ts\nconst a = 1\n\n// two\n```"
      list = "1. one\n2. two"

      assert [
               %{"kind" => "raw", "text" => ^table},
               %{"kind" => "raw", "text" => ^fence},
               %{"kind" => "raw", "text" => ^list}
             ] = Markdown.blocks(Enum.join([table, fence, list], "\n\n"))
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

    test "a task list is checklist items; a list with anything else is raw" do
      assert [
               %{"kind" => "checklist", "checked" => true, "text" => "MC"},
               %{"kind" => "checklist", "checked" => false, "text" => "QML"}
             ] = Markdown.blocks("- [x] MC\n- [ ] QML")

      assert kinds("- [x] MC\n- QML") == ["raw"]
      assert kinds("- [X] MC") == ["raw"]
    end

    test "a quote is a callout only when written as one would be" do
      assert [%{"kind" => "callout", "text" => "Mind\nthe trash"}] =
               Markdown.blocks("> Mind\n> the trash")

      assert kinds(">lazy") == ["raw"]
      assert kinds("> [!NOTE]\n> Alerts are quotes for now.") == ["callout"]
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
