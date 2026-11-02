defmodule HalC2.SpaceMarkdownPropTest do
  @moduledoc """
  A page's Markdown (`HalC2.Space.Markdown`) loses nothing, whatever GitHub Markdown it
  is given:

  - the blocks of a document write back as that document, apart from LF line ends and
    exactly one newline at the end;
  - a document with a title on top imports as a page of that title and exports as it was;
  - writing back what was written back changes nothing more;
  - every block is a kind a page has, and every heading has a level.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Space.{Blocks, Markdown}

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
    "```",
    "```ts",
    "```mermaid",
    "flowchart LR",
    "    A --> B",
    "~~~",
    "````",
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

  property "every block is a kind a page has, and a heading has a level",
    numtests: HalC2.Prop.numtests(300) do
    forall markdown <- document() do
      Enum.all?(Markdown.blocks(markdown), fn block ->
        block["kind"] in Blocks.kinds() and
          (block["kind"] != "heading" or block["level"] in 1..6)
      end)
    end
  end
end
