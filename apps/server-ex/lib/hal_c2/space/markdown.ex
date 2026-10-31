defmodule HalC2.Space.Markdown do
  @moduledoc """
  A page as Markdown and back. The page title is the `# ` heading on top, headings
  are `## `, checklist items `- [ ]` and `- [x]`, callouts `> ` quotes, and a link to
  a subpage `[Title](#pageId)`. Everything else is a paragraph.
  """

  @doc "The Markdown of a page; `title_of` names the page a subpage link points at."
  @spec export(map, [map], (String.t() -> String.t() | nil)) :: String.t()
  def export(page, blocks, title_of) do
    # A run of checklist items is one list; every other block stands alone.
    body =
      blocks
      |> Enum.chunk_by(&if(&1["kind"] == "checklist", do: :list, else: &1["id"]))
      |> Enum.map(fn chunk -> Enum.map_join(chunk, "\n", &block(&1, title_of)) end)

    Enum.join(["# " <> page["title"] | body], "\n\n") <> "\n"
  end

  defp block(%{"kind" => "heading", "text" => text}, _), do: "## " <> text

  defp block(%{"kind" => "checklist", "text" => text, "checked" => checked}, _),
    do: if(checked, do: "- [x] ", else: "- [ ] ") <> text

  defp block(%{"kind" => "callout", "text" => text}, _),
    do: text |> String.split("\n") |> Enum.map_join("\n", &String.trim_trailing("> " <> &1))

  defp block(%{"kind" => "subpage_link", "linkedPageId" => id} = block, title_of),
    do: "[#{title_of.(id) || block["text"]}](##{id})"

  defp block(%{"text" => text}, _), do: text

  @doc """
  The title and blocks Markdown holds, each block a map of `kind`, `text`, `checked`
  and, for a subpage link, `linkedPageId`. The title is a leading `# ` heading, if any.
  """
  @spec parse(String.t()) :: {String.t() | nil, [map]}
  def parse(markdown) do
    blocks =
      markdown
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> lines([])

    case blocks do
      [{:title, title} | rest] -> {title, Enum.map(rest, &untitle/1)}
      blocks -> {nil, Enum.map(blocks, &untitle/1)}
    end
  end

  # A `# ` heading anywhere but the top is an ordinary heading.
  defp untitle({:title, text}), do: new("heading", text)
  defp untitle(block), do: block

  defp lines([], acc), do: Enum.reverse(acc)

  defp lines(["```" <> _ = fence | rest], acc) do
    {code, rest} = Enum.split_while(rest, &(not String.starts_with?(&1, "```")))
    {close, rest} = Enum.split(rest, 1)
    lines(rest, [new("paragraph", Enum.join([fence | code] ++ close, "\n")) | acc])
  end

  defp lines([line | rest], acc) do
    cond do
      String.trim(line) == "" ->
        lines(rest, acc)

      match = Regex.run(~r/^#\s+(.*)$/, line) ->
        lines(rest, [{:title, String.trim(Enum.at(match, 1))} | acc])

      match = Regex.run(~r/^\#{2,6}\s+(.*)$/, line) ->
        lines(rest, [new("heading", String.trim(Enum.at(match, 1))) | acc])

      match = Regex.run(~r/^\s*[-*]\s+\[([ xX])\]\s?(.*)$/, line) ->
        [_, mark, text] = match
        lines(rest, [%{new("checklist", text) | "checked" => mark != " "} | acc])

      match = Regex.run(~r/^\[(.+)\]\(#([\w-]+)\)$/, String.trim(line)) ->
        [_, text, id] = match
        lines(rest, [%{new("subpage_link", text) | "linkedPageId" => id} | acc])

      String.starts_with?(line, ">") ->
        {quote, rest} = Enum.split_while([line | rest], &String.starts_with?(&1, ">"))
        text = Enum.map_join(quote, "\n", &(&1 |> String.replace_prefix(">", "") |> trim_one()))
        lines(rest, [new("callout", text) | acc])

      true ->
        {para, rest} = Enum.split_while([line | rest], &paragraph_line?/1)
        lines(rest, [new("paragraph", Enum.join(para, "\n")) | acc])
    end
  end

  defp paragraph_line?(line),
    do:
      String.trim(line) != "" and
        not Regex.match?(~r/^(\#{1,6}\s|>|```|\s*[-*]\s+\[[ xX]\])/, line)

  defp trim_one(" " <> text), do: text
  defp trim_one(text), do: text

  defp new(kind, text),
    do: %{"kind" => kind, "text" => text, "checked" => false, "linkedPageId" => nil}
end
