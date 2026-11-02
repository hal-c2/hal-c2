defmodule HalC2.Space.Markdown do
  @moduledoc """
  A page as Markdown and back, without losing a byte.

  A page's Markdown is its title as a `# ` heading on top, then its blocks. Headings are
  `#` to `######` by their `level` (2 when a block has none), checklist items `- [ ]`
  and `- [x]`, callouts `> ` quotes, a link to a subpage `[Title](#pageId)` and an image
  `![Caption](space-image:imageId)`. A table is written as `HalC2.Space.Table` says, and
  code between fences: three backticks unless the block keeps another `fence`, then its
  `language` and the rest of the fence's line as `info`. A run of checklist items is one
  list; other blocks are apart by a blank line.

  Anything else, and anything written in a way those forms would not give back exactly,
  is a `raw` block: its Markdown source, kept as written. A block whose blank lines
  above it are not the usual ones keeps them in `gap`, the text between the end of the
  line above and the block (`"\n"` for none, `"\n\n\n"` for two), so they are written
  back too. `document/2` of `blocks/1` is therefore the Markdown it was given, apart from
  two normalisations: CRLF line ends are read as LF (as is any carriage return at the
  end of a line), and the document ends with exactly one newline (trailing blank lines
  are dropped, a missing newline is added).

  `parse/1` and `export/3` add the title: a document that starts with a `# ` heading
  imports as a page of that title and exports as it was, while a page imported from a
  document with no title on top gains one when exported. `blocks/1` and `document/2` are
  the same without the title, for Markdown that is not a page's own.

  A chart's table comes back as Markdown too, as a raw block: only `space.block.visualize`
  draws a chart.
  """

  alias HalC2.Space.{Chart, Table}

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
      Enum.map_reduce(blocks, start, fn block, above ->
        {[separator(above, block), render(block, title_of)], block["kind"]}
      end)

    IO.iodata_to_binary(parts)
  end

  defp separator(above, block) do
    case {above, block["kind"], gap(block)} do
      {:start, _, nil} -> ""
      {:start, _, "\n" <> gap} -> gap
      {"checklist", "checklist", nil} -> "\n"
      {_, _, nil} -> "\n\n"
      {_, _, gap} -> gap
    end
  end

  # Only blank lines below a line end make a gap; anything else reads as the usual one.
  defp gap(%{"gap" => "\n" <> _ = gap}), do: if(String.trim(gap) == "", do: gap)
  defp gap(_), do: nil

  @doc "A block as Markdown, without what separates it from the block above."
  def render(block, title_of \\ fn _ -> nil end)

  def render(%{"kind" => "heading", "text" => text} = block, _),
    do: String.duplicate("#", level(block)) <> " " <> text

  def render(%{"kind" => "checklist", "text" => text, "checked" => checked}, _),
    do: if(checked, do: "- [x] ", else: "- [ ] ") <> text

  def render(%{"kind" => "callout", "text" => text}, _),
    do: text |> String.split("\n") |> Enum.map_join("\n", &String.trim_trailing("> " <> &1))

  def render(%{"kind" => "subpage_link", "linkedPageId" => id} = block, title_of),
    do: "[#{title_of.(id) || block["text"]}](##{id})"

  def render(%{"kind" => "chart", "chart" => chart}, _), do: Chart.markdown(chart)

  def render(%{"kind" => "table", "table" => table}, _), do: Table.markdown(table)

  def render(%{"kind" => "code", "text" => text} = block, _) do
    lines = if text == "", do: [], else: String.split(text, "\n")
    fence = fence_for(block["fence"] || "```", lines)

    Enum.join(
      [fence <> (block["language"] || "") <> (block["info"] || "") | lines] ++ [fence],
      "\n"
    )
  end

  def render(%{"kind" => "image", "imageId" => id, "text" => text}, _),
    do: "![#{String.replace(text, "\n", " ")}](space-image:#{id})"

  def render(%{"text" => text}, _), do: text

  # A fence no line of the code closes: longer than any that would.
  defp fence_for(fence, lines) do
    if Enum.any?(lines, &closes_fence?(&1, fence)),
      do: fence_for(fence <> String.first(fence), lines),
      else: fence
  end

  @doc """
  Whether a code block's `fence`, `language` and `info` write a line that opens it again:
  three or more backticks or tildes, a language of no spaces, and the rest of the line,
  with no backtick after backticks.
  """
  def code?(block) do
    fence = block["fence"] || "```"
    {language, info} = {block["language"], block["info"]}

    Regex.match?(~r/^(`{3,}|~{3,})$/, fence) and
      (is_nil(language) or (is_binary(language) and Regex.match?(~r/^\S+$/u, language))) and
      (is_nil(info) or (is_binary(info) and not String.contains?(info, ["\n", "\r"]))) and
      (is_nil(info) or language != nil) and
      fence(fence <> (language || "") <> (info || "")) == fence
  end

  @doc "A heading's level, 1 to 6; a heading written before levels is a 2."
  def level(%{"level" => level}) when level in 1..6, do: level
  def level(_), do: 2

  @doc """
  The title and blocks Markdown holds, each block a map of `kind`, `text`, `checked`,
  `linkedPageId` and, when it has them, `level`, `imageId` and `gap`. The title is a
  leading `# ` heading, if any.
  """
  @spec parse(String.t()) :: {String.t() | nil, [map]}
  def parse(markdown) do
    case blocks(markdown) do
      [%{"kind" => "heading", "level" => 1} = top | rest] when not is_map_key(top, "gap") ->
        {top["text"], rest}

      blocks ->
        {nil, blocks}
    end
  end

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
      {what, taken, rest} = segment(lines, acc == [] and blank == [])
      segments(rest, [], [{Enum.reverse(blank), what, taken} | acc])
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
        closed(lines, &(String.trim(&1) == "$$"))

      Regex.match?(~r/^ {0,3}<details[\s>]/i, line) ->
        details(rest, depth(line), [line])

      Regex.match?(~r/^ {0,3}<!--/, line) ->
        if String.contains?(line, "-->"),
          do: {:raw, [line], rest},
          else: closed(lines, &String.contains?(&1, "-->"))

      html?(line) ->
        until_blank(:raw, lines)

      Regex.match?(~r/^ {0,3}\#{1,6}(\s|$)/, line) ->
        {:heading, [line], rest}

      table?(lines) ->
        until_blank(:table, lines)

      Regex.match?(~r/^ {0,3}>/, line) ->
        quoted(rest, [line])

      list_item?(line) ->
        list(rest, [line])

      Regex.match?(~r/^( {4}|\t)/, line) ->
        indented(rest, [line])

      rule?(line) ->
        {:raw, [line], rest}

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

  defp details([line | rest], depth, acc), do: details(rest, depth + depth(line), [line | acc])

  defp depth(line) do
    opens = length(Regex.scan(~r/<details[\s>]/i, line))
    closes = length(Regex.scan(~r/<\/details\s*>/i, line))
    opens - closes
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

  # A list runs past blank lines while what follows is another item or indented under one.
  defp list([], acc), do: {:list, Enum.reverse(acc), []}

  defp list([line | rest] = lines, acc) do
    cond do
      blank?(line) ->
        {blank, after_blank} = Enum.split_while(lines, &blank?/1)

        case after_blank do
          [next | _] ->
            if list_item?(next) or Regex.match?(~r/^\s{2,}\S/, next),
              do: list(after_blank, Enum.reverse(blank) ++ acc),
              else: {:list, Enum.reverse(acc), lines}

          [] ->
            {:list, Enum.reverse(acc), lines}
        end

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

  defp rule?(line), do: Regex.match?(~r/^ {0,3}([-*_])(\s*\1){2,}\s*$/, line)

  defp blank?(line), do: String.trim(line) == ""

  # --- the blocks of what was read ------------------------------------------------------

  # Each part as blocks: a block in a form `render/2` gives back exactly, else raw. A
  # gap is kept on a block only where it is not what `separator/2` would write.
  defp specs(segments) do
    segments
    |> Enum.flat_map(fn {blank, what, lines} ->
      [{first, first_lines} | rest] = blocks_of(what, lines)
      [{"\n" <> Enum.map_join(blank, &(&1 <> "\n")), first, first_lines} | rest]
    end)
    |> Enum.map_reduce(:start, fn {gap, block, _lines}, above ->
      usual = separator(above, block) |> then(&if(above == :start, do: "\n" <> &1, else: &1))
      block = if gap == usual, do: block, else: Map.put(block, "gap", gap)
      {block, block["kind"]}
    end)
    |> elem(0)
  end

  # A part's blocks, each with the gap above it, but the first's, which the part keeps.
  defp blocks_of(:list, lines) do
    items = Enum.map(lines, &checklist/1)

    if Enum.all?(items, & &1),
      do: Enum.map(items, &{&1, nil}) |> regap("\n"),
      else: [{raw(lines), lines}]
  end

  defp blocks_of(what, lines) do
    block = block(what, lines)
    [{if(render(block) == Enum.join(lines, "\n"), do: block, else: raw(lines)), lines}]
  end

  defp regap([first | rest], gap), do: [first | Enum.map(rest, fn {b, l} -> {gap, b, l} end)]

  defp checklist(line) do
    case Regex.run(~r/^- \[([ x])\] (.*)$/, line) do
      [_, mark, text] -> %{new("checklist", text) | "checked" => mark == "x"}
      nil -> nil
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

  defp block(:quote, lines) do
    text = Enum.map_join(lines, "\n", &(&1 |> String.replace_prefix(">", "") |> trim_one()))
    new("callout", text)
  end

  defp block(:paragraph, [line] = lines) do
    cond do
      match = Regex.run(~r/^\[(.+)\]\(#([\w-]+)\)$/, line) ->
        [_, text, id] = match
        %{new("subpage_link", text) | "linkedPageId" => id}

      match = Regex.run(~r/^!\[(.*)\]\(space-image:([\w-]+)\)$/, line) ->
        [_, text, id] = match
        Map.put(new("image", text), "imageId", id)

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

  defp block(:raw, lines), do: raw(lines)

  defp raw(lines), do: new("raw", Enum.join(lines, "\n"))

  defp put_unless(block, _key, value, value), do: block
  defp put_unless(block, key, value, _usual), do: Map.put(block, key, value)

  defp trim_one(" " <> text), do: text
  defp trim_one(text), do: text

  defp new(kind, text),
    do: %{"kind" => kind, "text" => text, "checked" => false, "linkedPageId" => nil}
end
