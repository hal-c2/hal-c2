defmodule HalC2.Space.Sites do
  @moduledoc """
  A page published as a site (`features/space/sites.feature`): one `site` entity per
  published page in the Space's stream, its id the secret token of the link. It keeps a
  snapshot of the page taken at publish time, which `html/1` renders and the MC serves
  (`HalC2.Web.Router`) to anyone holding the link. The token names this one entity and
  is no credential anywhere else on the MC.

  Commands return `{changes, reply}`, as `HalC2.Space.Pages` commands do.
  """

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, StreamState}
  alias HalC2.Space
  alias HalC2.Space.{Blocks, Markdown, Pages}

  @lists ~w(bullet numbered checklist)

  @doc "The site of the page `page_id`, if it is published."
  def of_page(state, page_id),
    do: state |> StreamState.list("site") |> Enum.find(&(&1["pageId"] == page_id))

  @doc """
  Publishes the live page `page_id` at `reached` (`HalC2.Web.address/1`), or brings its
  site up to date: the link stays, whichever address it was asked from this time. It only
  moves when it is a link only this machine can open, or with `move: true`, as the user
  asked for that address. `at:` says when, for tests.
  """
  def publish(state, page_id, reached, opts \\ []) do
    case Pages.fetch_live(state, page_id) do
      {:ok, page} ->
        site = of_page(state, page_id)
        token = if site, do: site["id"], else: token()

        where =
          if site && !site["localOnly"] && !opts[:move],
            do: %{"url" => site["url"], "localOnly" => false},
            else: %{
              "url" => "#{reached["address"]}/sites/#{page["spaceId"]}/#{token}",
              "localOnly" => reached["localOnly"]
            }

        next =
          Map.merge(where, %{
            "id" => token,
            "spaceId" => page["spaceId"],
            "pageId" => page_id,
            "publishedAt" => opts[:at] || Entities.now(),
            "behind" => false,
            "snapshot" => snapshot(state, page)
          })

        # Published again in the same instant with nothing changed, there is nothing to write.
        case Patch.diff(site, next) do
          :unchanged -> {[], {:ok, next}}
          patch -> {[{"site", token, patch}], {:ok, next}}
        end

      refused ->
        {[], refused}
    end
  end

  @doc """
  Takes the page's site down, if it has one. Its token is never used again: publishing
  the page later makes a new one.
  """
  def unpublish(state, page_id) do
    cond do
      site = of_page(state, page_id) -> {[{"site", site["id"], Patch.delete()}], {:ok, page_id}}
      Pages.get(state, page_id) -> {[], {:ok, page_id}}
      true -> {[], {:error, :not_found, "There is no page #{page_id} in this Space."}}
    end
  end

  @doc "Whether `changes` to a stream in `state` could concern a site."
  def affected?(state, changes) do
    StreamState.get(state, "site") != %{} and
      Enum.any?(changes, fn {kind, _, _} -> kind in ["page", "block"] end)
  end

  @doc """
  What `changes` taking `before` to `state` mean for sites: the site of a page gone or in
  the trash comes down for good, and the others are behind exactly when publishing now
  would change them.
  """
  def follow(before, state, changes) do
    concerned = concerned(before, state, changes)

    for site <- StreamState.list(state, "site"),
        concerned == :all or site["pageId"] in concerned,
        change = followed(state, site),
        do: change
  end

  # A block only shows on its own page, and blocks are what is edited most. A page can
  # reach any site: trashing a parent takes its children's sites down, and a link shows
  # the title of the page it links to.
  defp concerned(before, state, changes) do
    if Enum.any?(changes, fn {kind, _, _} -> kind == "page" end) do
      :all
    else
      for {"block", id, _} <- changes,
          block <- [StreamState.get(before, "block")[id], StreamState.get(state, "block")[id]],
          block,
          into: MapSet.new(),
          do: block["pageId"]
    end
  end

  defp followed(state, site) do
    page = Pages.get(state, site["pageId"])

    if page && Pages.live?(state, page) do
      behind = snapshot(state, page) != site["snapshot"]

      if behind != site["behind"],
        do: {"site", site["id"], Patch.diff(site, %{site | "behind" => behind})}
    else
      {"site", site["id"], Patch.delete()}
    end
  end

  # What a site shows of the page: never its comments or authors, and of a link to
  # another page only that page's title, unless it is out of reach in the trash. An image
  # is its caption: the picture's file is not published (`features/space/sites.feature`).
  # A list item shows how deep it is, and a numbered one its number.
  defp snapshot(state, page) do
    blocks = state |> Blocks.of_page(page["id"]) |> Enum.flat_map(&ordinary(state, &1))

    blocks =
      blocks
      |> Enum.zip(Markdown.list_items(blocks))
      |> Enum.flat_map(fn {block, item} -> published(state, block, item) end)

    %{"title" => page["title"], "blocks" => blocks}
  end

  # A run's Markdown reads as the blocks removing the update would make of it.
  defp ordinary(state, %{"kind" => "generated"} = block), do: Space.written(state, block["text"])
  defp ordinary(_state, block), do: [block]

  defp published(_state, block, %{depth: depth, number: number}) do
    %{"kind" => block["kind"], "text" => block["text"] || ""}
    |> then(
      &if(block["kind"] == "checklist",
        do: Map.put(&1, "checked", block["checked"] == true),
        else: &1
      )
    )
    |> put_if("depth", depth > 0 && depth)
    |> put_if("number", number)
    |> List.wrap()
  end

  defp published(state, block, nil), do: published(state, block)

  defp put_if(map, _key, value) when value in [nil, false], do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp published(state, %{"kind" => "subpage_link"} = block) do
    linked = Pages.get(state, block["linkedPageId"])

    if linked && Pages.live?(state, linked),
      do: [%{"kind" => "subpage_link", "text" => linked["title"]}],
      else: []
  end

  # A table is its cells and how its columns align, not how its Markdown is padded.
  defp published(_state, %{"kind" => "table", "table" => table} = block),
    do: [
      %{"kind" => "table", "text" => block["text"], "table" => Map.take(table, ~w(align rows))}
    ]

  defp published(_state, %{"kind" => "code"} = block),
    do: [
      %{"kind" => "code", "text" => block["text"] || ""}
      |> then(&if(block["language"], do: Map.put(&1, "language", block["language"]), else: &1))
    ]

  defp published(_state, %{"kind" => "callout"} = block),
    do: [%{"kind" => "callout", "text" => block["text"] || ""} |> put_if("alert", block["alert"])]

  defp published(_state, block), do: [%{"kind" => block["kind"], "text" => block["text"] || ""}]

  # 192 bits from the system's strong random source, URL-safe.
  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  # --- the document -------------------------------------------------------------------

  @style """
  :root{color-scheme:light dark}
  body{font:16px/1.6 system-ui,sans-serif;max-width:42em;margin:3em auto;padding:0 1em}
  h1{font-size:1.8em;line-height:1.2}h2{font-size:1.3em;line-height:1.3;margin-top:1.6em}
  p,li,aside{white-space:pre-wrap;overflow-wrap:anywhere}
  ul{list-style:none;padding:0}
  .d1{margin-left:1.5em}.d2{margin-left:3em}.d3{margin-left:4.5em}
  .d4{margin-left:6em}.d5{margin-left:7.5em}.d6{margin-left:9em}
  aside{border-left:3px solid;padding:.5em 1em;margin:1em 0}
  pre{overflow-x:auto;padding:.75em 1em;border:1px solid;border-radius:4px}
  table{border-collapse:collapse;display:block;overflow-x:auto;margin:1em 0}
  th,td{border:1px solid;padding:.25em .6em;overflow-wrap:anywhere}
  .l{text-align:left}.c{text-align:center}.r{text-align:right}
  footer{margin-top:3em;font-size:.85em;opacity:.7}
  """

  # Only that style: nothing loads, no script runs, no form posts, and no page frames it.
  @policy [
            "default-src 'none'",
            "style-src 'sha256-#{Base.encode64(:crypto.hash(:sha256, @style))}'",
            "base-uri 'none'",
            "form-action 'none'",
            "frame-ancestors 'none'",
            "sandbox"
          ]
          |> Enum.join("; ")

  @doc "The Content-Security-Policy of the document `html/1` writes."
  def policy, do: @policy

  @doc "The site as a readable HTML document. All page text is escaped."
  def html(site) do
    %{"title" => title, "blocks" => blocks} = site["snapshot"]

    [
      "<!doctype html><html><head><meta charset=\"utf-8\">",
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
      "<title>",
      esc(title),
      "</title><style>",
      @style,
      "</style></head><body><main><h1>",
      esc(title),
      "</h1>",
      blocks |> Enum.chunk_by(&(&1["kind"] in @lists)) |> Enum.map(&section/1),
      "</main><footer>Published ",
      esc(String.slice(site["publishedAt"], 0, 10)),
      "</footer></body></html>\n"
    ]
  end

  defp section([%{"kind" => kind} | _] = items) when kind in @lists,
    do: ["<ul>", Enum.map(items, &item/1), "</ul>"]

  defp section(blocks), do: Enum.map(blocks, &block/1)

  defp item(%{"text" => text} = item) do
    depth = min(item["depth"] || 0, 6)
    open = if depth > 0, do: "<li class=\"d#{depth}\">", else: "<li>"
    [open, mark(item), esc(text), "</li>"]
  end

  defp mark(%{"kind" => "checklist", "checked" => true}), do: "☑ "
  defp mark(%{"kind" => "checklist"}), do: "☐ "
  defp mark(%{"number" => number}), do: "#{number}. "
  defp mark(_bullet), do: "• "

  defp block(%{"kind" => "heading", "text" => text}), do: ["<h2>", esc(text), "</h2>"]
  defp block(%{"kind" => "divider"}), do: "<hr>"

  defp block(%{"kind" => "callout", "text" => text, "alert" => alert}),
    do: ["<aside><strong>", String.capitalize(alert), "</strong>\n", esc(text), "</aside>"]

  defp block(%{"kind" => "callout", "text" => text}), do: ["<aside>", esc(text), "</aside>"]

  defp block(%{"kind" => "code", "text" => text}),
    do: ["<pre><code>", esc(text), "</code></pre>"]

  defp block(%{"kind" => "table", "table" => %{"align" => align, "rows" => [head | body]}}) do
    [
      "<table><thead>",
      row("th", align, head),
      "</thead><tbody>",
      Enum.map(body, &row("td", align, &1)),
      "</tbody></table>"
    ]
  end

  defp block(%{"text" => text}), do: ["<p>", esc(text), "</p>"]

  defp row(tag, align, cells) do
    cells =
      Enum.zip_with(align, cells, fn a, cell ->
        ["<", tag, aligned(a), ">", esc(cell), "</", tag, ">"]
      end)

    ["<tr>", cells, "</tr>"]
  end

  defp aligned("left"), do: " class=\"l\""
  defp aligned("center"), do: " class=\"c\""
  defp aligned("right"), do: " class=\"r\""
  defp aligned(nil), do: ""

  defp esc(text), do: Plug.HTML.html_escape(text)
end
