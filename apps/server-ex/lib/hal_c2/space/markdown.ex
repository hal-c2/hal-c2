defmodule HalC2.Space.Markdown do
  @moduledoc """
  A page as Markdown and back, without losing a byte.

  A page's Markdown is its title as a `# ` heading on top, then its blocks. Headings are
  `#` to `######` by their `level` (2 when a block has none), callouts `> ` quotes (an
  `alert` one starting `> [!NOTE]` or another of GitHub's; a blank line is `>`, or `> ` for
  one that keeps that as its `marker`), a divider `---` (or the
  rule it was read from, kept as its `marker`, such as `***`), a link to a
  subpage `[Title](#pageId)` and an image `![Caption](space-image:imageId)`, or
  `![Caption](url)` for one by its address. A table is written as `HalC2.Space.Table`
  says, and code between fences: three backticks unless the block keeps another `fence`,
  then its `language` and the rest of the fence's line as `info`. Math is code in `math`,
  and keeps `$$` as its `fence` when it was written between `$$` lines.

  A footnote is `[^label]: ` and its note, the note's further lines indented four spaces.
  A collapsed section is a `details` block, `<details>` and its `<summary>` (its text),
  then the blocks inside it, then a `details_end` block, `</details>`. An opening written
  another way (on one line, `open`, or with its summary indented) is kept as its `marker`.

  Inline formatting (emphasis, strikethrough, code spans, links, autolinks, footnote
  references, inline math, inline images) is part of a block's text, kept as written.

  List items are a block each: a `bullet` `- `, a `numbered` `1. ` and a `checklist`
  `- [ ] ` or `- [x] `, nested by their `depth` (`list_items/1`). From Markdown a bullet
  keeps its `marker` when it is `*` or `+`, a numbered item a `)` one, and an item an
  `indent` other than its parent's text's. A run of list items is one list, and footnotes
  follow one another line under line; other blocks are apart by a blank line.

  Anything else, and anything written in a way those forms would not give back exactly,
  is a `raw` block: its Markdown source, kept as written. A block whose blank lines
  above it are not the usual ones keeps them in `gap`, the text between the end of the
  line above and the block (`"\n"` for none, `"\n\n\n"` for two), so they are written
  back too, except for no blank line at all where the block would then join the one above
  it now (a paragraph under a paragraph, once the heading between them is deleted).
  `document/2` of `blocks/1` is therefore the Markdown it was given, apart from
  two normalisations: CRLF line ends are read as LF (as is any carriage return at the
  end of a line), and the document ends with exactly one newline (trailing blank lines
  are dropped, a missing newline is added).

  `parse/1` and `export/3` add the title: a document that starts with a `# ` heading
  imports as a page of that title and exports as it was (a title written another way,
  `#  Title` or below blank lines, comes back as `# Title`), while a page imported from
  a document with no title on top gains one when exported. `blocks/1` and `document/2` are
  the same without the title, for Markdown that is not a page's own.

  A chart's table comes back as Markdown too, as a raw block: only `space.block.visualize`
  draws a chart.
  """

  alias HalC2.Space.{Chart, Table}

  @lists ~w(bullet numbered checklist)

  # A `<details>` opening and its summary, written as a page writes them.
  @details ~r/\A(<details(?: open)?>(?:\n *)?<summary>)(.*)<\/summary>\z/
  @summary "<details>\n<summary>"

  @alerts Map.new(~w(note tip important warning caution), &{&1, "[!#{String.upcase(&1)}]"})

  @doc "The kinds of block that are list items."
  def lists, do: @lists

  @doc "The kinds of alert a callout may be, as GitHub writes them: `[!NOTE]` and so on."
  def alerts, do: Map.keys(@alerts)

  @doc "The Markdown of a page; `title_of` names the page a subpage link points at."
  @spec export(map, [map], (String.t() -> String.t() | nil)) :: String.t()
  def export(page, blocks, title_of),
    do: "# " <> page["title"] <> join(blocks, title_of, :title) <> "\n"

  @doc "The Markdown of `blocks` with no title: `blocks/1` read back. No blocks is \"\"."
  @spec document([map], (String.t() -> String.t() | nil)) :: String.t()
  def document([], _title_of), do: ""
  def document(blocks, title_of), do: join(blocks, title_of, :start) <> "\n"

  # Each block after what is above it: its own gap, or the usual one.
  defp join(blocks, title_of, start) do
    {parts, _} =
      blocks
      |> Enum.zip(list_items(blocks))
      |> Enum.map_reduce(start, fn {block, item}, above ->
        text = if item, do: render_item(block, item), else: render(block, title_of)

        separator =
          if apart_item?(above, block, item), do: "\n\n", else: separator(above, block, text)

        # What is above the next block: a list item with the items above it in its list,
        # whose indent only reads so under them. The document's first line reads as its
        # top: `---` there is front matter.
        over =
          case above do
            {kind, over} when kind in @lists and item != nil -> over <> separator <> text
            :start when separator == "" -> text
            _ -> "\n" <> text
          end

        {[separator, text], {block["kind"], over}}
      end)

    IO.iodata_to_binary(parts)
  end

  # A list that starts right under an item's text is read as more of that text unless its
  # first item has text and, numbered, starts at 1: elsewhere a blank line goes between,
  # also when the list's gap says none (the block that was between is gone).
  defp apart_item?({kind, _}, block, %{new_list: true} = item) when kind in @lists,
    do: gap(block) in [nil, "\n"] and (item_text(block) == "" or item.number not in [nil, 1])

  defp apart_item?(_above, _block, _item), do: false

  defp separator(above, block, text) do
    case {gap(block), above} do
      {nil, _} -> usual(above, block["kind"])
      {"\n" <> gap, :start} -> gap
      {"\n", {_kind, over}} -> if apart?(over, text), do: "\n", else: usual(above, block["kind"])
      {gap, _} -> gap
    end
  end

  # What is between a block and the one above it when it has no gap of its own.
  defp usual(:start, _kind), do: ""
  defp usual({above, _text}, kind) when above in @lists and kind in @lists, do: "\n"
  defp usual({"footnote", _text}, "footnote"), do: "\n"
  defp usual(_above, _kind), do: "\n\n"

  # Whether `text` right under the block above, with no blank line between, still reads as
  # blocks of its own. It did where it was read, but not under any block: once the heading
  # it sat under is deleted, a paragraph right under another paragraph would join it.
  # `over` starts with a blank line unless it is the document's top.
  defp apart?(over, text),
    do: texts(over <> "\n" <> text) == texts(over) ++ texts("\n" <> text)

  defp texts(markdown), do: markdown |> blocks() |> Enum.map(&{&1["kind"], &1["text"]})

  # Only blank lines below a line end make a gap; anything else reads as the usual one.
  defp gap(%{"gap" => "\n" <> _ = gap}), do: if(String.trim(gap) == "", do: gap)
  defp gap(_), do: nil

  @doc "A block as Markdown, without what separates it from the block above."
  def render(block, title_of \\ fn _ -> nil end)

  def render(%{"kind" => "heading", "text" => text} = block, _),
    do: String.duplicate("#", level(block)) <> " " <> text

  def render(%{"kind" => kind} = block, _) when kind in @lists,
    do: render_item(block, block |> place([]) |> elem(0))

  def render(%{"kind" => "callout", "text" => text} = block, _) do
    lines = String.split(text, "\n")
    lines = if @alerts[block["alert"]], do: [@alerts[block["alert"]] | lines], else: lines
    blank = block["marker"] || ">"
    Enum.map_join(lines, "\n", &if(&1 == "", do: blank, else: "> " <> &1))
  end

  def render(%{"kind" => "divider"} = block, _), do: block["marker"] || "---"

  def render(%{"kind" => "subpage_link", "linkedPageId" => id} = block, title_of),
    do: "[#{title_of.(id) || block["text"]}](##{id})"

  def render(%{"kind" => "chart", "chart" => chart}, _), do: Chart.markdown(chart)

  def render(%{"kind" => "table", "table" => table}, _), do: Table.markdown(table)

  def render(%{"kind" => "code", "fence" => "$$", "text" => text} = block, _) do
    lines = if text == "", do: [], else: String.split(text, "\n")

    # Math holding a `$$` line or a blank one is written between fences instead: the line
    # would close it, and GitHub ends `$$` math at a blank line.
    if Enum.any?(lines, &(String.trim(&1) in ["$$", ""])),
      do: render(Map.delete(block, "fence")),
      else: Enum.join(["$$" | lines] ++ ["$$"], "\n")
  end

  def render(%{"kind" => "code", "text" => text} = block, _) do
    lines = if text == "", do: [], else: String.split(text, "\n")
    fence = fence_for(block["fence"] || "```", lines)

    Enum.join(
      [fence <> (block["language"] || "") <> (block["info"] || "") | lines] ++ [fence],
      "\n"
    )
  end

  def render(%{"kind" => "image", "url" => url, "text" => text}, _),
    do: "![#{String.replace(text, "\n", " ")}](#{url})"

  def render(%{"kind" => "image", "imageId" => id, "text" => text}, _),
    do: "![#{String.replace(text, "\n", " ")}](space-image:#{id})"

  def render(%{"kind" => "footnote", "label" => label, "text" => text}, _) do
    [first | rest] = String.split(text, "\n")
    head = "[^#{label}]:" <> if(first == "", do: "", else: " " <> first)
    Enum.join([head | Enum.map(rest, &if(&1 == "", do: "", else: "    " <> &1))], "\n")
  end

  def render(%{"kind" => "details", "text" => text} = block, _),
    do: (block["marker"] || @summary) <> text <> "</summary>"

  def render(%{"kind" => "details_end"}, _), do: "</details>"

  def render(%{"text" => text}, _), do: text

  @doc """
  Where each of `blocks` sits as a list item, in order: nil for a block that is not one,
  else the `depth` it is written at, with the `indent` and `marker` it is written with
  and a numbered item's `number`. An item is under the open items above it, at most one
  `depth` below the deepest, and a numbered item counts on from the one before it at its
  depth in the same list (the same delimiter), else from its `start` or 1. Any other
  block ends the list.
  """
  def list_items(blocks) do
    blocks
    |> Enum.map_reduce([], fn
      %{"kind" => kind} = block, open when kind in @lists -> place(block, open)
      _block, _open -> {nil, []}
    end)
    |> elem(0)
  end

  # An item under the items still open above it, deepest first, and those open after it.
  # Its `indent` is kept only where it is read back at the same depth: at or past its
  # parent's text, by at most three, and short of the text of the item above it there.
  defp place(block, open) do
    depth = min(item_depth(block), length(open))
    {closed, parents} = Enum.split_while(open, &(&1.depth >= depth))
    sibling = List.last(closed)
    floor = column(parents)
    list = list(block)

    goes_on = same_list?(sibling, list)
    number = if start(block) && goes_on, do: sibling.number + 1, else: start(block)

    marker = marker(list, number)
    ceiling = if sibling, do: min(floor + 3, sibling.column - 1), else: floor + 3
    indent = if block["indent"] in floor..ceiling//1, do: block["indent"], else: floor
    column = indent + String.length(marker) + 1

    item = %{
      depth: depth,
      indent: indent,
      marker: marker,
      number: number,
      column: column,
      list: list,
      new_list: not goes_on
    }

    {item, [item | parents]}
  end

  defp item_depth(%{"depth" => depth}) when is_integer(depth) and depth > 0, do: depth
  defp item_depth(_block), do: 0

  # Where the text of the deepest open item starts.
  defp column([%{column: column} | _]), do: column
  defp column([]), do: 0

  defp list(%{"kind" => "numbered", "marker" => ")"}), do: {:numbered, ")"}
  defp list(%{"kind" => "numbered"}), do: {:numbered, "."}

  defp list(%{"kind" => "bullet", "marker" => marker}) when marker in ["*", "+"],
    do: {:bullet, marker}

  defp list(_block), do: {:bullet, "-"}

  defp same_list?(%{list: list}, list), do: true
  defp same_list?(_item, _list), do: false

  defp start(%{"kind" => "numbered", "start" => start}) when start in 0..999_999_999, do: start
  defp start(%{"kind" => "numbered"}), do: 1
  defp start(_block), do: nil

  defp marker({:numbered, delimiter}, number), do: Integer.to_string(number) <> delimiter
  defp marker({:bullet, bullet}, _number), do: bullet

  @doc "A list item as Markdown where `list_items/1` places it: its marker, then its text."
  def render_item(block, %{indent: indent, marker: marker, column: column}) do
    [first | rest] = String.split(item_text(block), "\n")
    pad = String.duplicate(" ", column)
    head = String.duplicate(" ", indent) <> marker <> if(first == "", do: "", else: " " <> first)
    Enum.join([head | Enum.map(rest, &if(&1 == "", do: "", else: pad <> &1))], "\n")
  end

  defp item_text(%{"kind" => "checklist", "checked" => true, "text" => text}), do: "[x] " <> text
  defp item_text(%{"kind" => "checklist", "text" => text}), do: "[ ] " <> text
  defp item_text(%{"text" => text}), do: text

  # A fence no line of the code closes: longer than any that would.
  defp fence_for(fence, lines) do
    if Enum.any?(lines, &closes_fence?(&1, fence)),
      do: fence_for(fence <> String.first(fence), lines),
      else: fence
  end

  @doc """
  Whether a divider's `marker` writes a rule: three or more of one of `-`, `*` or `_`,
  perhaps spaced, with nothing around them.
  """
  def divider?(marker), do: is_binary(marker) and Regex.match?(~r/^([-*_])( *\1){2,}$/, marker)

  @doc """
  Whether a code block's `fence`, `language` and `info` write a line that opens it again:
  three or more backticks or tildes, a language of no spaces, and the rest of the line
  from a space on, with no backtick after backticks. `$$` is math's alone.
  """
  def code?(%{"fence" => "$$"} = block), do: block["language"] == "math" and block["info"] == nil

  def code?(block) do
    fence = block["fence"] || "```"
    {language, info} = {block["language"], block["info"]}

    Regex.match?(~r/^(`{3,}|~{3,})$/, fence) and
      (is_nil(language) or (is_binary(language) and Regex.match?(~r/^\S+$/u, language))) and
      (is_nil(info) or (is_binary(info) and Regex.match?(~r/^([^\S\r\n][^\r\n]*)?$/u, info))) and
      (is_nil(info) or language != nil) and
      fence(fence <> (language || "") <> (info || "")) == fence
  end

  @doc "Whether a `details` block's `marker` opens it as a page reads it: nil is the usual."
  def details?(marker),
    do: marker == nil or (is_binary(marker) and Regex.match?(@details, marker <> "</summary>"))

  @doc "Whether a footnote's `label` writes `[^label]`: no spaces or brackets."
  def label?(label), do: is_binary(label) and Regex.match?(~r/^[^\s\[\]]+$/u, label)

  @doc """
  Whether an image's `url` writes `![Caption](url)` that reads back as it: no spaces,
  brackets, parentheses or backslashes, and not a Space image's.
  """
  def url?(url),
    do:
      is_binary(url) and Regex.match?(~r/^[^\s()<>\\]+$/u, url) and
        not String.starts_with?(url, "space-image:")

  @doc "A heading's level, 1 to 6; a heading written before levels is a 2."
  def level(%{"level" => level}) when level in 1..6, do: level
  def level(_), do: 2

  @doc """
  The title and blocks Markdown holds, each block a map of `kind`, `text`, `checked`,
  `linkedPageId` and, when it has them, `level`, `imageId` and `gap`. The title is a
  leading level 1 heading, if any.
  """
  @spec parse(String.t()) :: {String.t() | nil, [map]}
  def parse(markdown) do
    blocks = blocks(markdown)

    case blocks |> List.first(%{}) |> title() do
      nil -> {nil, blocks}
      title -> {title, tl(blocks)}
    end
  end

  # The title a document's first block gives: a level 1 heading, however it is spaced and
  # whatever blank lines are above it. The page writes it back as `# Title`.
  defp title(%{"kind" => "heading", "level" => 1, "text" => text}), do: text

  defp title(%{"kind" => "raw", "text" => text}) do
    case Regex.run(~r/^ {0,3}#[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/, text) do
      [_, title] when title != "" -> title
      _ -> nil
    end
  end

  defp title(_block), do: nil

  @doc "The blocks of `markdown`, a title at the top being an ordinary level 1 heading."
  @spec blocks(String.t()) :: [map]
  def blocks(markdown) do
    markdown
    |> unix()
    |> String.split("\n")
    |> segments([], [])
    |> specs()
  end

  # --- reading ------------------------------------------------------------------------

  # LF line ends: a carriage return, or a run of them, before a line end or the end of
  # the document goes, so reading what was written changes nothing more.
  defp unix(markdown), do: String.replace(markdown, ~r/\r+(?=\n|\z)/, "")

  # The document's parts in order, each `{blank lines above it, :what, its lines}`.
  defp segments([], _blank, acc), do: Enum.reverse(acc)

  defp segments([line | rest] = lines, blank, acc) do
    if blank?(line) do
      segments(rest, [line | blank], acc)
    else
      case segment(lines, acc == [] and blank == []) do
        {:details, opener, inner, rest} ->
          {tail, inside} = inner |> Enum.reverse() |> Enum.split_while(&blank?/1)
          inside = Enum.reverse(inside)

          # Right under what is inside, the closing must still read as a line of its own.
          if tail == [] and
               List.last(segments(inside ++ ["</details>"], [], [])) != {[], :raw, ["</details>"]} do
            segments(rest, [], [
              {Enum.reverse(blank), :raw, opener ++ inner ++ ["</details>"]} | acc
            ])
          else
            parts = inside |> segments([], []) |> Enum.reverse()
            close = {Enum.reverse(tail), :details_end, ["</details>"]}
            segments(rest, [], [close | parts] ++ [{Enum.reverse(blank), :details, opener} | acc])
          end

        {what, taken, rest} ->
          segments(rest, [], [{Enum.reverse(blank), what, taken} | acc])
      end
    end
  end

  # One part starting at a line that is not blank; `top?` on the document's first line.
  defp segment([line | rest] = lines, top?) do
    cond do
      top? and String.trim_trailing(line) == "---" ->
        front_matter(lines)

      fence = fence(line) ->
        closed(lines, &closes_fence?(&1, fence), :code)

      String.trim(line) == "$$" ->
        closed(lines, &(String.trim(&1) == "$$"), :math)

      Regex.match?(~r/^ {0,3}<details[\s>]/i, line) ->
        details(rest, details_depth(line), [line]) |> collapsed()

      Regex.match?(~r/^ {0,3}<!--/, line) ->
        if String.contains?(line, "-->"),
          do: {:raw, [line], rest},
          else: closed(lines, &String.contains?(&1, "-->"))

      footnote?(line) ->
        footnote(rest, [line])

      html?(line) ->
        until_blank(:raw, lines)

      Regex.match?(~r/^ {0,3}\#{1,6}(\s|$)/, line) ->
        {:heading, [line], rest}

      table?(lines) ->
        until_blank(:table, lines)

      Regex.match?(~r/^ {0,3}>/, line) ->
        quoted(rest, [line])

      rule?(line) ->
        {:rule, [line], rest}

      list_item?(line) ->
        list(rest, [line])

      Regex.match?(~r/^( {4}|\t)/, line) ->
        indented(rest, [line])

      true ->
        paragraph(rest, [line])
    end
  end

  # Lines up to and including the first after the opener that `close?` holds for, or
  # to the last line that is not blank when none does, which is raw.
  defp closed([open | rest], close?, what \\ :raw) do
    case Enum.split_while(rest, &(not close?.(&1))) do
      {inside, [close | rest]} -> {what, [open | inside] ++ [close], rest}
      {inside, []} -> unclosed([open | inside])
    end
  end

  # A part left open at the end: the blank lines after it are the document's end, which
  # is written as one newline, not part of the part.
  defp unclosed(lines) do
    {blank, taken} = lines |> Enum.reverse() |> Enum.split_while(&blank?/1)
    {:raw, Enum.reverse(taken), Enum.reverse(blank)}
  end

  # YAML between `---` lines on top; with no closing line, the `---` is a rule.
  defp front_matter([open | rest] = lines) do
    if Enum.any?(rest, &(String.trim_trailing(&1) in ["---", "..."])),
      do: closed(lines, &(String.trim_trailing(&1) in ["---", "..."])),
      else: {:raw, [open], rest}
  end

  defp html?(line), do: Regex.match?(~r/^ {0,3}<\/?[a-zA-Z][a-zA-Z0-9-]*(\s|\/?>|$)/, line)

  defp fence(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})(.*)$/, line) do
      [_, "`" <> _ = marks, info] -> if not String.contains?(info, "`"), do: marks
      [_, marks, _] -> marks
      nil -> nil
    end
  end

  defp closes_fence?(line, marks) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})\s*$/, line) do
      [_, close] -> String.first(close) == String.first(marks) and close >= marks
      nil -> false
    end
  end

  # A `<details>` element to its own closing tag, with any nested inside it.
  defp details([], _depth, acc), do: unclosed(Enum.reverse(acc))

  defp details(lines, depth, acc) when depth <= 0, do: {:raw, Enum.reverse(acc), lines}

  defp details([line | rest], depth, acc),
    do: details(rest, depth + details_depth(line), [line | acc])

  defp details_depth(line) do
    opens = length(Regex.scan(~r/<details[\s>]/i, line))
    closes = length(Regex.scan(~r/<\/details\s*>/i, line))
    opens - closes
  end

  # A `<details>` element whose contents are Markdown, as its opening and summary, what is
  # inside and its closing: opened on a line or two as a page writes them, then a blank
  # line, closed by `</details>` alone with nothing right under it. Else raw whole, on to
  # a blank line as HTML runs, so what follows reads the same however the element ends.
  defp collapsed({:raw, [first | _] = lines, rest}) do
    {opener, inner} = Enum.split(lines, if(String.contains?(first, "</summary>"), do: 1, else: 2))

    with true <- Regex.match?(@details, Enum.join(opener, "\n")),
         [open | _] <- inner,
         true <- blank?(open),
         "</details>" <- List.last(inner),
         0 <- lines |> Enum.map(&details_depth/1) |> Enum.sum(),
         true <- rest == [] or blank?(hd(rest)) do
      {:details, opener, Enum.drop(inner, -1), rest}
    else
      _ ->
        {more, rest} = Enum.split_while(rest, &(not blank?(&1)))
        {:raw, lines ++ more, rest}
    end
  end

  defp footnote?(line), do: Regex.match?(~r/^ {0,3}\[\^[^\s\[\]]+\]:/u, line)

  # A footnote runs to a blank line or the next footnote, past blank lines while what
  # follows is indented four spaces, taking lines that continue its text.
  defp footnote([], acc), do: {:footnote, Enum.reverse(acc), []}

  defp footnote([line | rest] = lines, acc) do
    cond do
      blank?(line) ->
        {blank, after_blank} = Enum.split_while(lines, &blank?/1)

        case after_blank do
          ["    " <> _ | _] -> footnote(after_blank, Enum.reverse(blank) ++ acc)
          _ -> {:footnote, Enum.reverse(acc), lines}
        end

      footnote?(line) ->
        {:footnote, Enum.reverse(acc), lines}

      String.starts_with?(line, "    ") or not interrupts?(line) ->
        footnote(rest, [line | acc])

      true ->
        {:footnote, Enum.reverse(acc), lines}
    end
  end

  defp until_blank(what, lines) do
    {taken, rest} = Enum.split_while(lines, &(not blank?(&1)))
    {what, taken, rest}
  end

  # A header row, then a row of `---` cells.
  defp table?([head, delimiter | _]),
    do:
      String.contains?(head, "|") and String.contains?(delimiter, "|") and
        Regex.match?(~r/^ {0,3}\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/, delimiter)

  defp table?(_), do: false

  # A quote runs to a blank line, taking lines that continue its text.
  defp quoted([line | rest] = lines, acc) do
    if blank?(line) or
         (not String.starts_with?(String.trim_leading(line), ">") and interrupts?(line)),
       do: {:quote, Enum.reverse(acc), lines},
       else: quoted(rest, [line | acc])
  end

  defp quoted([], acc), do: {:quote, Enum.reverse(acc), []}

  # A list runs past blank lines while what follows is another item or indented under one,
  # to a rule at the start of a line.
  defp list([], acc), do: {:list, Enum.reverse(acc), []}

  defp list([line | rest] = lines, acc) do
    cond do
      blank?(line) ->
        {blank, after_blank} = Enum.split_while(lines, &blank?/1)

        case after_blank do
          [next | _] ->
            if (list_item?(next) and not ends_list?(next)) or Regex.match?(~r/^\s{2,}\S/, next),
              do: list(after_blank, Enum.reverse(blank) ++ acc),
              else: {:list, Enum.reverse(acc), lines}

          [] ->
            {:list, Enum.reverse(acc), lines}
        end

      ends_list?(line) ->
        {:list, Enum.reverse(acc), lines}

      list_item?(line) or Regex.match?(~r/^\s/, line) or not interrupts?(line) ->
        list(rest, [line | acc])

      true ->
        {:list, Enum.reverse(acc), lines}
    end
  end

  defp indented([], acc), do: {:raw, Enum.reverse(acc), []}

  defp indented([line | rest] = lines, acc) do
    cond do
      Regex.match?(~r/^( {4}|\t)/, line) ->
        indented(rest, [line | acc])

      blank?(line) ->
        {blank, after_blank} = Enum.split_while(lines, &blank?/1)

        case after_blank do
          [next | _] ->
            if Regex.match?(~r/^( {4}|\t)/, next),
              do: indented(after_blank, Enum.reverse(blank) ++ acc),
              else: {:raw, Enum.reverse(acc), lines}

          [] ->
            {:raw, Enum.reverse(acc), lines}
        end

      true ->
        {:raw, Enum.reverse(acc), lines}
    end
  end

  # A paragraph runs to a blank line or a line that starts something else. One
  # underlined by `===` or `---` is a heading in another form, kept as written.
  defp paragraph([], acc), do: {:paragraph, Enum.reverse(acc), []}

  defp paragraph([line | rest] = lines, acc) do
    cond do
      blank?(line) ->
        {:paragraph, Enum.reverse(acc), lines}

      Regex.match?(~r/^ {0,3}(=+|-+)\s*$/, line) ->
        {:raw, Enum.reverse([line | acc]), rest}

      interrupts?(line) ->
        {:paragraph, Enum.reverse(acc), lines}

      true ->
        paragraph(rest, [line | acc])
    end
  end

  # A line that ends a paragraph above it without a blank line between.
  defp interrupts?(line) do
    fence(line) != nil or rule?(line) or html?(line) or
      Regex.match?(~r/^ {0,3}(\#{1,6}(\s|$)|>|<!--|([-*+]|1[.)])\s+\S)/, line)
  end

  defp list_item?(line), do: Regex.match?(~r/^ {0,3}([-*+]|\d{1,9}[.)])(\s|$)/, line)

  defp ends_list?(line), do: rule?(line) and not Regex.match?(~r/^\s/, line)

  defp rule?(line), do: Regex.match?(~r/^ {0,3}([-*_])(\s*\1){2,}\s*$/, line)

  defp blank?(line), do: String.trim(line) == ""

  # --- the blocks of what was read ------------------------------------------------------

  # Each part as blocks: a block in a form `render/2` gives back exactly, else raw. A
  # gap is kept on a block only where it is not the usual one.
  defp specs(segments) do
    segments
    |> Enum.flat_map(fn {blank, what, lines} ->
      [{first, first_lines} | rest] = blocks_of(what, lines)
      [{"\n" <> Enum.map_join(blank, &(&1 <> "\n")), first, first_lines} | rest]
    end)
    |> Enum.map_reduce(:start, fn {gap, block, _lines}, above ->
      usual = usual(above, block["kind"]) |> then(&if(above == :start, do: "\n" <> &1, else: &1))
      block = if gap == usual, do: block, else: Map.put(block, "gap", gap)
      {block, {block["kind"], nil}}
    end)
    |> elem(0)
  end

  # A part's blocks, each with the gap above it, but the first's, which the part keeps.
  # A list is an item a block, kept raw whole unless they write it back as it was.
  defp blocks_of(:list, lines) do
    with {:ok, [{_, first} | rest]} <- read_items(lines, [], [], [], nil),
         blocks = [first | Enum.map(rest, fn {gap, b} -> put_unless(b, "gap", gap, "\n") end)],
         true <- join(blocks, fn _ -> nil end, :start) == Enum.join(lines, "\n") do
      [{first, lines} | Enum.map(rest, fn {gap, block} -> {gap, block, nil} end)]
    else
      _ -> [{raw(lines), lines}]
    end
  end

  defp blocks_of(what, lines) do
    block = block(what, lines)
    [{if(render(block) == Enum.join(lines, "\n"), do: block, else: raw(lines)), lines}]
  end

  # A list's items as `place/2` writes them, each `{the blank lines above it, block}`, or
  # :error. An item is under the deepest item whose text it is indented to, else beside
  # the one it backs out to, and a line indented to the text of the last item goes on
  # with that text. Lines read otherwise (a lazy line, text back under a parent's after
  # its items, a tab) are :error, as is a new list right under a line of text that
  # would go on with that text instead. `items` are newest first, each with its text's
  # lines newest first; `open` the items a line can be under, deepest first; `blank`
  # the blank lines since the line before; `fence` one open in the last item's text.
  defp read_items([], items, _open, _blank, nil) do
    blocks = items |> Enum.reverse() |> Enum.map(&item_block/1)
    if :error in blocks, do: :error, else: {:ok, blocks}
  end

  defp read_items([], _items, _open, _blank, _fence), do: :error

  defp read_items([line | rest], items, open, blank, fence) do
    indent = byte_size(line) - byte_size(String.trim_leading(line, " "))
    column = column(open)

    cond do
      blank?(line) ->
        read_items(rest, items, open, [line | blank], fence)

      Regex.match?(~r/^ *\t/, line) ->
        :error

      open != [] and indent >= column ->
        text = binary_part(line, column, byte_size(line) - column)

        case fence == nil and item_line(text) do
          {by, marker, first} when by <= 3 ->
            read_item(rest, items, open, nil, blank, {indent, marker, first})

          _ ->
            read_text(rest, items, open, blank, fence, text)
        end

      fence != nil ->
        :error

      match = item_line(line) ->
        {closed, parents} = Enum.split_while(open, &(indent < &1.column))

        if indent <= column(parents) + 3,
          do: read_item(rest, items, parents, List.last(closed), blank, match),
          else: :error

      true ->
        :error
    end
  end

  defp read_item(rest, items, parents, sibling, blank, {indent, marker, first}) do
    list = if marker in ~w(- * +), do: {:bullet, marker}, else: {:numbered, String.last(marker)}
    number = if elem(list, 0) == :numbered, do: String.to_integer(String.slice(marker, 0..-2//1))
    goes_on = same_list?(sibling, list)

    with {:ok, text} <- item_first(first),
         true <- goes_on or blank != [] or items == [] or (text != "" and number in [nil, 1]),
         true <- not goes_on or number == nil or number == sibling.number + 1 do
      item = %{
        gap: "\n" <> Enum.map_join(Enum.reverse(blank), &(&1 <> "\n")),
        list: list,
        depth: length(parents),
        indent: indent,
        floor: column(parents),
        start: if(not goes_on and number != 1, do: number),
        text: [text]
      }

      open = %{
        depth: item.depth,
        column: indent + byte_size(marker) + 1,
        list: list,
        number: number
      }

      read_items(rest, [item | items], [open | parents], [], fence(text))
    else
      _ -> :error
    end
  end

  # An item's text starts one space after its marker; no text is an empty item.
  defp item_first(""), do: {:ok, ""}
  defp item_first(" " <> text), do: if(Regex.match?(~r/^\s/, text), do: :error, else: {:ok, text})
  defp item_first(_), do: :error

  # The last item's text goes on, the blank lines before the line with it. An empty item
  # takes no more.
  defp read_text(_rest, [%{text: [""]} | _], _open, _blank, _fence, _text), do: :error

  defp read_text(rest, [item | items], open, blank, fence, text) do
    pad = String.duplicate(" ", column(open))
    lines = [text | Enum.map(blank, &String.replace_prefix(&1, pad, ""))] ++ item.text

    fence =
      cond do
        fence == nil -> fence(text)
        closes_fence?(text, fence) -> nil
        true -> fence
      end

    read_items(rest, [%{item | text: lines} | items], open, [], fence)
  end

  # A line that starts a list item: its indent, marker and what follows the marker.
  defp item_line(line) do
    with false <- rule?(String.trim_leading(line)),
         [_, spaces, marker, rest] <- Regex.run(~r/^( *)([-*+]|\d{1,9}[.)])(\s.*|)$/, line) do
      {byte_size(spaces), marker, rest}
    else
      _ -> nil
    end
  end

  # A task is a `-` item of `[ ] ` or `[x] `; anything else that reads as one is :error.
  defp item_block(item) do
    text = item.text |> Enum.reverse() |> Enum.join("\n")

    block =
      case {item.list, Regex.run(~r/^\[([ x])\] (.*)\z/s, text)} do
        {{:bullet, "-"}, [_, mark, text]} -> %{new("checklist", text) | "checked" => mark == "x"}
        {{:bullet, marker}, nil} -> "bullet" |> new(text) |> put_unless("marker", marker, "-")
        {{:numbered, mark}, nil} -> "numbered" |> new(text) |> put_unless("marker", mark, ".")
        _ -> nil
      end

    if block == nil or
         (block["kind"] != "checklist" and Regex.match?(~r/^\[[ xX]\](\s|\z)/, text)) do
      :error
    else
      block
      |> put_unless("start", item.start, nil)
      |> put_unless("depth", item.depth, 0)
      |> put_unless("indent", item.indent, item.floor)
      |> then(&{item.gap, &1})
    end
  end

  defp block(:heading, [line]) do
    # Text with spaces around it or a closing `#` run is kept as written.
    with [_, marks, text] <- Regex.run(~r/^(\#{1,6}) (.*)$/, line),
         true <- text != "" and text == String.trim(text) and not Regex.match?(~r/\s#+$/, text) do
      Map.put(new("heading", text), "level", String.length(marks))
    else
      _ -> raw([line])
    end
  end

  # A quote whose first line is `[!NOTE]`, or another alert, then more is that alert.
  defp block(:quote, lines) do
    text = Enum.map_join(lines, "\n", &(&1 |> String.replace_prefix(">", "") |> trim_one()))

    callout =
      with [first, rest] <- String.split(text, "\n", parts: 2),
           {alert, _} <- Enum.find(@alerts, &(elem(&1, 1) == first)) do
        "callout" |> new(rest) |> Map.put("alert", alert)
      else
        _ -> new("callout", text)
      end

    if "> " in lines, do: Map.put(callout, "marker", "> "), else: callout
  end

  defp block(:rule, [line]) do
    cond do
      line == "---" -> new("divider", "")
      divider?(line) -> "divider" |> new("") |> Map.put("marker", line)
      true -> raw([line])
    end
  end

  defp block(:paragraph, [line] = lines) do
    cond do
      match = Regex.run(~r/^\[(.+)\]\(#([\w-]+)\)$/, line) ->
        [_, text, id] = match
        %{new("subpage_link", text) | "linkedPageId" => id}

      match = Regex.run(~r/^!\[(.*)\]\(space-image:([\w-]+)\)$/, line) ->
        [_, text, id] = match
        Map.put(new("image", text), "imageId", id)

      (match = Regex.run(~r/^!\[([^\[\]]*)\]\((.*)\)$/u, line)) && url?(Enum.at(match, 2)) ->
        [_, text, url] = match
        Map.put(new("image", text), "url", url)

      true ->
        new("paragraph", Enum.join(lines, "\n"))
    end
  end

  defp block(:paragraph, lines), do: new("paragraph", Enum.join(lines, "\n"))

  defp block(:table, lines) do
    case Table.read(lines) do
      nil -> raw(lines)
      table -> "table" |> new(Table.markdown(table)) |> Map.put("table", table)
    end
  end

  # Code fenced from the start of the line, its language the first word after the fence
  # and anything after that its info. A fence indented or with a space before the
  # language is kept as written.
  defp block(:code, [open | rest] = lines) do
    {inside, _close} = Enum.split(rest, -1)

    case Regex.run(~r/^(`{3,}|~{3,})(?:(\S+)(.*))?$/u, open) do
      [_, fence | info] ->
        "code"
        |> new(Enum.join(inside, "\n"))
        |> put_unless("fence", fence, "```")
        |> put_unless("language", Enum.at(info, 0), nil)
        |> put_unless("info", Enum.at(info, 1) || "", "")

      nil ->
        raw(lines)
    end
  end

  # Math between `$$` lines, each alone on its line, with no blank line between them.
  defp block(:math, ["$$" | rest] = lines) do
    case Enum.split(rest, -1) do
      {inside, ["$$"]} ->
        if Enum.any?(inside, &blank?/1),
          do: raw(lines),
          else:
            "code"
            |> new(Enum.join(inside, "\n"))
            |> Map.merge(%{"language" => "math", "fence" => "$$"})

      _ ->
        raw(lines)
    end
  end

  defp block(:math, lines), do: raw(lines)

  # A footnote's further lines are its text indented four spaces.
  defp block(:footnote, [first | rest] = lines) do
    case Regex.run(~r/^\[\^([^\s\[\]]+)\]:(.*)$/u, first) do
      [_, label, text] ->
        "footnote"
        |> new(
          Enum.map_join([trim_one(text) | rest], "\n", &String.replace_prefix(&1, "    ", ""))
        )
        |> Map.put("label", label)

      nil ->
        raw(lines)
    end
  end

  defp block(:details, lines) do
    [_, marker, summary] = Regex.run(@details, Enum.join(lines, "\n"))
    "details" |> new(summary) |> put_unless("marker", marker, @summary)
  end

  defp block(:details_end, _lines), do: new("details_end", "")

  defp block(:raw, lines), do: raw(lines)

  defp raw(lines), do: new("raw", Enum.join(lines, "\n"))

  defp put_unless(block, _key, value, value), do: block
  defp put_unless(block, key, value, _usual), do: Map.put(block, key, value)

  defp trim_one(" " <> text), do: text
  defp trim_one(text), do: text

  defp new(kind, text),
    do: %{"kind" => kind, "text" => text, "checked" => false, "linkedPageId" => nil}
end
