defmodule HalC2.Space.Blocks do
  @moduledoc """
  The blocks and comments of a Space's pages, decided on its stream state like
  `HalC2.Space.Pages`. Only blocks and comments of a live page change.

  A block's place is its `order` key (`HalC2.Space.Order`): inserting or moving one
  writes that block alone. `afterBlockId` places it: after that block, first when
  nil, last when left out (`:last`).

  A `raw` block is Markdown a page does not model, kept as its source so a page
  imported from Markdown exports exactly as it was (`HalC2.Space.Markdown`). A heading
  has a `level`, 1 to 6, and a block from Markdown may keep the blank lines above it as
  its `gap`; moving a block gives it the usual ones.

  A `table` block has its `table` (`HalC2.Space.Table`), and its text is the table's
  Markdown, which the MC writes: setting the text reads it as a table again. A `code`
  block's text is the code, with its `language` and, from Markdown, the `fence` and the
  `info` after the language it was written with.

  A list item (a `bullet`, a `numbered` item or a `checklist` item) is nested under the
  items above it by its `depth`, 0 when it has none, and a numbered item that begins a
  list may `start` it at a number other than 1. An item that continues a list counts on
  from the one above it, and keeps a start it is given for when it begins one. From
  Markdown an item keeps the `marker` and `indent` it was written with
  (`HalC2.Space.Markdown`); changing its depth or moving it gives it the usual indent. A `callout` may be an `alert`: note, tip, important,
  warning or caution, and from Markdown keeps `> ` as its `marker` when its blank lines
  were written so. A `divider` has no text, and from Markdown keeps the rule it was
  written as when it is not `---`, as its `marker`.

  An `image` is a Space image by its `imageId`, or one by its address, `url`, which the
  MC never fetches. A `footnote` is the note of its `label`, `[^label]` in text. Math is
  a `code` block in `math`. A collapsed section is a `details` block, its text the
  summary, then the blocks inside it, then a `details_end` block, which has no text.

  A block of the kind `generated` is the marked part of a page that updates itself
  (`HalC2.Space.Schedule`): a page has at most one, its text is the Markdown of the last
  run, and only `write_generated/4` writes it. Anyone may move or delete it or comment on
  it, but its text cannot be edited and it cannot be inserted.
  """

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, StreamState}
  alias HalC2.Space.{Chart, Images, Markdown, Order, Pages, Table}

  @kinds ~w(paragraph heading checklist bullet numbered callout divider subpage_link image raw
             table code footnote details details_end)

  @generated "generated"

  @lists ~w(bullet numbered checklist)
  @start "A numbered item's start is a number from 0 to 999999999, or null for 1."
  @alert "A callout's alert is note, tip, important, warning or caution, or null for none."
  @label "A footnote's label is a word with no spaces or brackets, such as 1 or note."
  @url "An image's address has no spaces, brackets, parentheses or backslashes."

  @doc """
  The kinds of block written directly. A `chart` is only made by `put_chart/6`, and a
  `generated` one by `write_generated/4`.
  """
  def kinds, do: @kinds

  @doc "A page's blocks in order."
  def of_page(state, page_id) do
    for(block <- StreamState.list(state, "block"), block["pageId"] == page_id, do: block)
    |> Enum.sort_by(&{&1["order"], &1["id"]})
  end

  @doc "The comments on a page, in the order they were made."
  def comments(state, page_id),
    do: for(c <- StreamState.list(state, "comment"), c["pageId"] == page_id, do: c)

  @doc """
  New blocks on a live page from `specs` (maps of `kind`, `text`, `checked`,
  `linkedPageId`, `imageId`, `url`, `level`, `table`, `language`, `fence`, `info`,
  `depth`, `start`, `marker`, `indent`, `alert`, `label`, `gap`), in order after `after`.
  Used by insert and by imports.
  An image block's text is its caption, the image's name unless given, so a client
  that does not know the kind still shows something true.
  """
  def insert_all(state, page_id, specs, after_id, author) do
    with {:ok, _page} <- Pages.fetch_live(state, page_id),
         {:ok, low, high} <- place(state, page_id, after_id, nil),
         {:ok, specs} <- valid_specs(state, specs) do
      at = Entities.now()

      {blocks, _} =
        Enum.map_reduce(specs, low, fn spec, low ->
          order = Order.between(low, high)
          block = new_block(page_id, Map.put(spec, "text", text(state, spec)), order, author, at)
          {with_extras(block, spec), order}
        end)

      {Enum.map(blocks, &{"block", &1["id"], Patch.diff(nil, &1)}), {:ok, blocks}}
    end
    |> Pages.refused()
  end

  defp new_block(page_id, spec, order, author, at) do
    %{
      "id" => HalC2.Environment.uuid4(),
      "pageId" => page_id,
      "kind" => spec["kind"],
      "text" => spec["text"] || "",
      "checked" => spec["kind"] == "checklist" and spec["checked"] == true,
      "linkedPageId" => if(spec["kind"] == "subpage_link", do: spec["linkedPageId"]),
      "order" => order,
      "createdBy" => author,
      "updatedBy" => author,
      "createdAt" => at,
      "updatedAt" => at
    }
  end

  @doc "The text a block made from `spec` has: an image with no caption reads as its name."
  def text(_state, %{"kind" => "image", "url" => url} = spec) when is_binary(url),
    do: spec["text"] || ""

  def text(state, %{"kind" => "image"} = spec) do
    case spec["text"] do
      text when text in [nil, ""] -> Images.get(state, spec["imageId"])["name"]
      text -> text
    end
  end

  def text(_state, %{"kind" => "table", "table" => table}), do: Table.markdown(table)
  def text(_state, spec), do: spec["text"] || ""

  # Only an image block has `imageId` or `url`, a heading `level`, a table its `table`,
  # code its `language`, `fence` and `info`, a list item its `depth` and `indent`, a
  # bullet, numbered item, divider, callout or collapsed section its `marker`, a numbered
  # item its `start`, a callout its `alert`, a footnote its `label`, and only a block from
  # Markdown a `gap`: every other block stays as it was written.
  defp with_extras(block, spec) do
    code = spec["kind"] == "code"
    item = spec["kind"] in @lists
    image = spec["kind"] == "image"

    block
    |> put_extra("url", image && spec["url"])
    |> put_extra("imageId", image && is_nil(spec["url"]) && spec["imageId"])
    |> put_extra("level", spec["kind"] == "heading" && spec["level"])
    |> put_extra("table", spec["kind"] == "table" && spec["table"])
    |> put_extra("language", code && spec["language"])
    |> put_extra("fence", code && spec["fence"])
    |> put_extra("info", code && spec["info"])
    |> put_extra("depth", item && spec["depth"] != 0 && spec["depth"])
    |> put_extra("indent", item && spec["indent"])
    |> put_extra(
      "marker",
      spec["kind"] in ~w(bullet numbered divider callout details) && spec["marker"]
    )
    |> put_extra("start", spec["kind"] == "numbered" && spec["start"] != 1 && spec["start"])
    |> put_extra("alert", spec["kind"] == "callout" && spec["alert"])
    |> put_extra("label", spec["kind"] == "footnote" && spec["label"])
    |> put_extra("gap", spec["gap"])
  end

  @extras ~w(imageId url level table language fence info depth indent marker start alert label
             gap)

  @doc "The fields a block has only by its kind, or from Markdown: how it is written beyond its text."
  def extras, do: @extras

  defp put_extra(block, _key, value) when value in [nil, false], do: block
  defp put_extra(block, key, value), do: Map.put(block, key, value)

  def insert(state, page_id, spec, after_id, author) do
    case insert_all(state, page_id, [spec], after_id, author) do
      {changes, {:ok, [block]}} -> {changes, {:ok, block}}
      refused -> refused
    end
  end

  @doc """
  Draws `chart` on a live page: a new block placed by `after_id`, or, with `block_id`,
  in place of the chart in that block. A chart with a description `Chart.validate/1`
  refuses is never written.
  """
  def put_chart(state, page_id, chart, nil, after_id, author) do
    with {:ok, page} <- Pages.fetch_live(state, page_id),
         :ok <- not_file(page),
         {:ok, low, high} <- place(state, page_id, after_id, nil),
         {:ok, chart} <- valid_chart(chart) do
      spec = %{"kind" => "chart", "text" => Chart.summary(chart)}
      order = Order.between(low, high)
      block = page_id |> new_block(spec, order, author, Entities.now()) |> Map.put("chart", chart)
      {[{"block", block["id"], Patch.diff(nil, block)}], {:ok, block}}
    end
    |> Pages.refused()
  end

  def put_chart(state, page_id, chart, block_id, _after_id, author) do
    with :ok <- chart_block(state, page_id, block_id),
         {:ok, chart} <- valid_chart(chart) do
      change(state, block_id, author, fn _ ->
        {:ok, %{"chart" => chart, "text" => Chart.summary(chart)}}
      end)
    else
      refused -> Pages.refused(refused)
    end
  end

  @doc "Whether a chart can be drawn on the page, and in `block_id` when there is one."
  def chart_place(state, page_id, block_id) do
    with {:ok, page} <- Pages.fetch_live(state, page_id),
         :ok <- not_file(page),
         :ok <- if(block_id, do: chart_block(state, page_id, block_id), else: :ok),
         do: {:ok, page}
  end

  # A chart is not Markdown a file can hold (`HalC2.Space.Files`).
  defp not_file(%{"file" => %{}}),
    do: {:error, :file_backed, "A chart is not drawn on a page that is a file."}

  defp not_file(_page), do: :ok

  defp chart_block(state, page_id, block_id) do
    case StreamState.get(state, "block")[block_id] do
      %{"pageId" => ^page_id, "kind" => "chart"} -> :ok
      _ -> {:error, :not_found, "There is no chart #{block_id} on this page."}
    end
  end

  defp valid_chart(chart) do
    with {:error, message} <- Chart.validate(chart), do: {:error, :invalid, message}
  end

  def update_text(state, id, text, author) when is_binary(text),
    do: edit(state, id, %{"text" => text}, author)

  def update_text(_state, _id, _text, _author),
    do: Pages.refused({:error, :invalid, "A block's text is a string."})

  def set_checked(state, id, checked, author) when is_boolean(checked),
    do: edit(state, id, %{"checked" => checked}, author)

  def set_checked(_state, _id, _checked, _author),
    do: Pages.refused({:error, :invalid, "checked is true or false."})

  @doc """
  Changes a block's `text`, tick (`checked`), heading `level`, code `language` (nil for
  none), list item `depth`, numbered item `start` (nil for 1), callout `alert` (nil for
  none), footnote `label` and the `url` of an image by its address in one step: either
  refused, nothing changes. What `changes` leaves out, or gives as a nil text, tick,
  level, depth, label or url, stays as it is.
  """
  def edit(state, id, changes, author) do
    change(state, id, author, fn block ->
      with {:ok, text} <- text_change(block, changes["text"]),
           {:ok, tick} <- tick_change(block, changes["checked"]),
           {:ok, level} <- level_change(block, changes["level"]),
           {:ok, language} <- language_change(block, changes),
           {:ok, depth} <- depth_change(block, changes["depth"]),
           {:ok, start} <- start_change(block, changes),
           {:ok, alert} <- alert_change(block, changes),
           {:ok, label} <- label_change(block, changes["label"]),
           {:ok, url} <- url_change(block, changes["url"]) do
        [tick, level, language, depth, start, alert, label, url]
        |> Enum.reduce(text, &Map.merge(&2, &1))
        |> then(&{:ok, &1})
      end
    end)
  end

  @doc "Edits the table of a table block as `HalC2.Space.Table.edit/2` does."
  def edit_table(state, id, edit, author) do
    change(state, id, author, fn
      %{"kind" => "table", "table" => table} ->
        case Table.edit(table, edit) do
          {:ok, table} -> {:ok, %{"table" => table, "text" => Table.markdown(table)}}
          {:error, message} -> {:error, :invalid, message}
        end

      _ ->
        {:error, :invalid, "Only a table's cells can be edited."}
    end)
  end

  defp text_change(_block, nil), do: {:ok, %{}}

  # A table's text is its Markdown: what is written is read as the table, kept as it is
  # when it is in the table's own form and padded to its cells when it is not.
  defp text_change(%{"kind" => "table"}, text) when is_binary(text) do
    text = String.trim_trailing(text)

    case text |> String.split(~r/\r?\n/) |> Table.read() do
      nil ->
        {:error, :invalid,
         "A table's text is a table: a header row, a row of ---, and rows of as many cells."}

      table ->
        {:ok, table} =
          if Table.markdown(table) == text,
            do: {:ok, table},
            else: Table.cast(Map.take(table, ~w(rows align)))

        {:ok, %{"table" => table, "text" => Table.markdown(table)}}
    end
  end

  defp text_change(%{"kind" => @generated}, _text),
    do: {:error, :invalid, "What a page's update wrote cannot be edited by hand."}

  defp text_change(%{"kind" => "chart"}, _),
    do: {:error, :invalid, "A chart cannot be edited. Ask for it again."}

  defp text_change(%{"kind" => "divider"}, text) when text != "",
    do: {:error, :invalid, "A divider has no text."}

  defp text_change(%{"kind" => "details_end"}, text) when text != "",
    do: {:error, :invalid, "The end of a collapsed section has no text."}

  defp text_change(%{"kind" => "details"}, text) when is_binary(text) do
    if String.contains?(text, ["\n", "\r"]),
      do: {:error, :invalid, "A collapsed section's summary is one line."},
      else: {:ok, %{"text" => text}}
  end

  defp text_change(_block, text) when is_binary(text), do: {:ok, %{"text" => text}}
  defp text_change(_block, _), do: {:error, :invalid, "A block's text is a string."}

  defp tick_change(_block, nil), do: {:ok, %{}}

  defp tick_change(%{"kind" => "checklist"}, checked) when is_boolean(checked),
    do: {:ok, %{"checked" => checked}}

  defp tick_change(_block, checked) when is_boolean(checked),
    do: {:error, :invalid, "Only a checklist item can be ticked."}

  defp tick_change(_block, _), do: {:error, :invalid, "checked is true or false."}

  defp level_change(_block, nil), do: {:ok, %{}}

  defp level_change(%{"kind" => "heading"}, level) when level in 1..6,
    do: {:ok, %{"level" => level}}

  defp level_change(%{"kind" => "heading"}, _),
    do: {:error, :invalid, "A heading's level is 1 to 6."}

  defp level_change(_block, _), do: {:error, :invalid, "Only a heading has a level."}

  defp language_change(_block, changes) when not is_map_key(changes, "language"),
    do: {:ok, %{}}

  defp language_change(%{"kind" => "code"} = block, %{"language" => language}) do
    # No language takes the rest of the fence's line with it, and only math keeps `$$`.
    next =
      if language, do: %{"language" => language}, else: %{"language" => :unset, "info" => :unset}

    next =
      if block["fence"] == "$$" and language != "math",
        do: Map.put(next, "fence", :unset),
        else: next

    if Markdown.code?(Map.merge(block, next) |> Map.reject(fn {_, v} -> v == :unset end)),
      do: {:ok, next},
      else: {:error, :invalid, "A code block's language is one word, or null for none."}
  end

  defp language_change(_block, _), do: {:error, :invalid, "Only a code block has a language."}

  defp depth_change(_block, nil), do: {:ok, %{}}

  defp depth_change(%{"kind" => kind} = block, depth) when kind in @lists do
    cond do
      not (is_integer(depth) and depth >= 0) ->
        {:error, :invalid, "A list item's depth is 0 or more."}

      depth == (block["depth"] || 0) ->
        {:ok, %{}}

      true ->
        {:ok, %{"depth" => if(depth == 0, do: :unset, else: depth), "indent" => :unset}}
    end
  end

  defp depth_change(_block, _), do: {:error, :invalid, "Only a list item has a depth."}

  defp start_change(_block, changes) when not is_map_key(changes, "start"), do: {:ok, %{}}

  defp start_change(%{"kind" => "numbered"}, %{"start" => start}) do
    case start do
      start when start in [nil, 1] -> {:ok, %{"start" => :unset}}
      start when start in 0..999_999_999 -> {:ok, %{"start" => start}}
      _ -> {:error, :invalid, @start}
    end
  end

  defp start_change(_block, _), do: {:error, :invalid, "Only a numbered item has a start."}

  defp alert_change(_block, changes) when not is_map_key(changes, "alert"), do: {:ok, %{}}

  defp alert_change(%{"kind" => "callout"}, %{"alert" => alert}) do
    cond do
      alert == nil -> {:ok, %{"alert" => :unset}}
      alert in Markdown.alerts() -> {:ok, %{"alert" => alert}}
      true -> {:error, :invalid, @alert}
    end
  end

  defp alert_change(_block, _), do: {:error, :invalid, "Only a callout has an alert."}

  defp label_change(_block, nil), do: {:ok, %{}}

  defp label_change(%{"kind" => "footnote"}, label) do
    if Markdown.label?(label), do: {:ok, %{"label" => label}}, else: {:error, :invalid, @label}
  end

  defp label_change(_block, _), do: {:error, :invalid, "Only a footnote has a label."}

  defp url_change(_block, nil), do: {:ok, %{}}

  defp url_change(%{"kind" => "image", "url" => _}, url) do
    if Markdown.url?(url), do: {:ok, %{"url" => url}}, else: {:error, :invalid, @url}
  end

  defp url_change(_block, _),
    do: {:error, :invalid, "Only an image by its address has a url."}

  def move(state, id, after_id, author) do
    change(state, id, author, fn block ->
      with {:ok, low, high} <- place(state, block["pageId"], after_id, id),
           do: {:ok, %{"order" => Order.between(low, high), "gap" => :unset, "indent" => :unset}}
    end)
  end

  @doc """
  Deletes a block and the comments on it. Replies with the block's id. The deleting
  author is written on the block first when it is not who last wrote it, which is how
  the log says who deleted it (`HalC2.Space.History`).
  """
  def delete(state, id, author) do
    with {:ok, block} <- fetch(state, id),
         {:ok, _} <- Pages.fetch_live(state, block["pageId"]) do
      comments =
        for c <- StreamState.list(state, "comment"),
            c["blockId"] == id,
            do: {"comment", c["id"], Patch.delete()}

      stamp =
        if block["updatedBy"] == author,
          do: [],
          else: [{"block", id, %{"s" => %{"updatedBy" => author}}}]

      {stamp ++ [{"block", id, Patch.delete()} | comments], {:ok, id}}
    end
    |> Pages.refused()
  end

  # --- the generated part -----------------------------------------------------------

  @doc """
  A run's Markdown as the generated part of a live page, and no other block: the
  page's generated block is rewritten, or made last on the page when it has none.
  Replies with the block.
  """
  def write_generated(state, page_id, markdown, author) do
    at = Entities.now()

    case generated(state, page_id) do
      nil ->
        spec = %{"kind" => @generated, "text" => markdown}
        order = Order.between(last_order(state, page_id), nil)
        block = new_block(page_id, spec, order, author, at)
        {[{"block", block["id"], Patch.diff(nil, block)}], {:ok, block}}

      # The same words from the same author are no edit, and leave the block as it is.
      %{"text" => ^markdown, "updatedBy" => ^author} = block ->
        {[], {:ok, block}}

      block ->
        next = Map.merge(block, %{"text" => markdown, "updatedBy" => author, "updatedAt" => at})
        {[{"block", block["id"], Patch.diff(block, next)}], {:ok, next}}
    end
  end

  @doc """
  Turns a page's generated part into ordinary blocks in the same place, from `specs`
  (as `insert_all/5` takes them). Its first block keeps the id, and so the comments.
  """
  def release_generated(state, page_id, specs, author) do
    case {generated(state, page_id), specs} do
      {nil, _} ->
        []

      {block, []} ->
        {changes, _} = delete(state, block["id"], author)
        changes

      {block, [first | rest]} ->
        next =
          block
          |> Map.merge(%{
            "kind" => first["kind"],
            "text" => text(state, first),
            "checked" => first["kind"] == "checklist" and first["checked"] == true,
            "linkedPageId" => first["linkedPageId"],
            "updatedBy" => author,
            "updatedAt" => Entities.now()
          })
          |> Map.drop(@extras)
          |> with_extras(first)

        {inserted, _} = insert_all(state, page_id, rest, block["id"], author)
        [{"block", block["id"], Patch.diff(block, next)} | inserted]
    end
  end

  defp generated(state, page_id),
    do: Enum.find(of_page(state, page_id), &(&1["kind"] == @generated))

  defp last_order(state, page_id) do
    case List.last(of_page(state, page_id)) do
      nil -> nil
      block -> block["order"]
    end
  end

  # --- comments ---------------------------------------------------------------------

  def comment(state, page_id, block_id, body, author) do
    with {:ok, _} <- Pages.fetch_live(state, page_id),
         :ok <- on_page(state, block_id, page_id),
         {:ok, body} <- body(body) do
      at = Entities.now()

      comment = %{
        "id" => HalC2.Environment.uuid4(),
        "pageId" => page_id,
        "blockId" => block_id,
        "author" => author,
        "body" => body,
        "resolvedAt" => nil,
        "createdAt" => at,
        "updatedAt" => at
      }

      {[{"comment", comment["id"], Patch.diff(nil, comment)}], {:ok, comment}}
    end
    |> Pages.refused()
  end

  def resolve(state, id), do: set_resolved(state, id, Entities.now())
  def reopen(state, id), do: set_resolved(state, id, nil)

  # Resolving a resolved comment (or reopening an open one) changes nothing.
  defp set_resolved(state, id, at) do
    with %{} = comment <- StreamState.get(state, "comment")[id] || not_found("comment", id),
         {:ok, _} <- Pages.fetch_live(state, comment["pageId"]) do
      if comment["resolvedAt"] == nil == (at == nil) do
        {[], {:ok, comment}}
      else
        next = %{comment | "resolvedAt" => at, "updatedAt" => Entities.now()}
        {[{"comment", id, Patch.diff(comment, next)}], {:ok, next}}
      end
    end
    |> Pages.refused()
  end

  # --- helpers ----------------------------------------------------------------------

  defp fetch(state, id) do
    case StreamState.get(state, "block")[id] do
      nil -> not_found("block", id)
      block -> {:ok, block}
    end
  end

  defp not_found(what, id), do: {:error, :not_found, "There is no #{what} #{id} in this Space."}

  # Changes a block of a live page with the fields `fun` decides; `:unset` removes one.
  defp change(state, id, author, fun) do
    with {:ok, block} <- fetch(state, id),
         {:ok, _} <- Pages.fetch_live(state, block["pageId"]),
         {:ok, fields} <- fun.(block) do
      next = block |> Map.merge(fields) |> Map.reject(fn {_, value} -> value == :unset end)

      case Patch.diff(block, next) do
        :unchanged ->
          {[], {:ok, block}}

        _ ->
          next = Map.merge(next, %{"updatedBy" => author, "updatedAt" => Entities.now()})
          {[{"block", id, Patch.diff(block, next)}], {:ok, next}}
      end
    end
    |> Pages.refused()
  end

  # The order keys a block placed `after_id` sits between, leaving out `moving`.
  defp place(state, page_id, after_id, moving) do
    keys = for b <- of_page(state, page_id), b["id"] != moving, do: {b["id"], b["order"]}

    case after_id do
      :last ->
        {:ok, keys |> List.last({nil, nil}) |> elem(1), nil}

      nil ->
        {:ok, nil, keys |> List.first({nil, nil}) |> elem(1)}

      id ->
        case Enum.split_while(keys, &(elem(&1, 0) != id)) do
          {_, [{_, low} | rest]} -> {:ok, low, rest |> List.first({nil, nil}) |> elem(1)}
          _ when id == moving -> {:error, :invalid, "A block cannot go after itself."}
          _ -> {:error, :not_found, "There is no block #{id} on this page."}
        end
    end
  end

  defp valid_specs(state, specs) do
    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, acc} ->
      with :ok <- valid_spec(state, spec), {:ok, spec} <- with_table(spec) do
        {:cont, {:ok, [spec | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      error -> error
    end
  end

  defp valid_spec(state, spec) do
    cond do
      spec["kind"] not in @kinds ->
        {:error, :invalid, "A block is one of #{Enum.join(@kinds, ", ")}."}

      not is_binary(spec["text"] || "") ->
        {:error, :invalid, "A block's text is a string."}

      spec["kind"] == "subpage_link" ->
        case Pages.get(state, spec["linkedPageId"] || "") do
          nil -> {:error, :invalid, "A subpage link needs a page of this Space."}
          _ -> :ok
        end

      spec["kind"] == "image" and spec["url"] != nil ->
        cond do
          spec["imageId"] != nil ->
            {:error, :invalid, "An image has an imageId or a url, not both."}

          Markdown.url?(spec["url"]) ->
            :ok

          true ->
            {:error, :invalid, @url}
        end

      spec["kind"] == "image" ->
        with {:ok, _} <- Images.fetch_live(state, spec["imageId"]), do: :ok

      spec["kind"] == "heading" and spec["level"] not in [nil | Enum.to_list(1..6)] ->
        {:error, :invalid, "A heading's level is 1 to 6."}

      spec["kind"] == "code" and not Markdown.code?(spec) ->
        {:error, :invalid, "A code block's language is one word, or null for none."}

      spec["kind"] in @lists and not item?(spec) ->
        {:error, :invalid,
         "A list item's depth and indent are 0 or more, and its marker one of - * + or . )."}

      spec["kind"] == "numbered" and not (spec["start"] == nil or spec["start"] in 0..999_999_999) ->
        {:error, :invalid, @start}

      spec["kind"] == "callout" and spec["alert"] not in [nil | Markdown.alerts()] ->
        {:error, :invalid, @alert}

      spec["kind"] == "callout" and spec["marker"] not in [nil, "> "] ->
        {:error, :invalid, "A callout's marker is \"> \", for blank lines written so, or null."}

      spec["kind"] in ~w(divider details_end) and spec["text"] not in [nil, ""] ->
        {:error, :invalid, "A divider, or the end of a collapsed section, has no text."}

      spec["kind"] == "footnote" and not Markdown.label?(spec["label"]) ->
        {:error, :invalid, @label}

      spec["kind"] == "details" and String.contains?(spec["text"] || "", ["\n", "\r"]) ->
        {:error, :invalid, "A collapsed section's summary is one line."}

      spec["kind"] == "details" and not Markdown.details?(spec["marker"]) ->
        {:error, :invalid,
         "A collapsed section's marker is how its <details> opening was written."}

      spec["kind"] == "divider" and
          not (spec["marker"] == nil or Markdown.divider?(spec["marker"])) ->
        {:error, :invalid, "A divider's marker is a rule such as *** or ___."}

      not is_nil(spec["gap"]) and not (is_binary(spec["gap"]) and gap?(spec["gap"])) ->
        {:error, :invalid, "A block's gap is blank lines."}

      true ->
        :ok
    end
  end

  # A table's widths, when the spec has none, are its cells'.
  defp with_table(%{"kind" => "table"} = spec) do
    case Table.cast(spec["table"]) do
      {:ok, table} -> {:ok, Map.put(spec, "table", table)}
      {:error, message} -> {:error, :invalid, message}
    end
  end

  defp with_table(spec), do: {:ok, spec}

  defp item?(spec) do
    count? = &(&1 == nil or (is_integer(&1) and &1 >= 0))
    markers = %{"bullet" => [nil, "-", "*", "+"], "numbered" => [nil, ".", ")"]}

    count?.(spec["depth"]) and count?.(spec["indent"]) and
      spec["marker"] in Map.get(markers, spec["kind"], [nil])
  end

  defp gap?("\n" <> rest), do: String.trim(rest) == ""
  defp gap?(_), do: false

  defp on_page(_state, nil, _page_id), do: :ok

  defp on_page(state, block_id, page_id) do
    case StreamState.get(state, "block")[block_id] do
      %{"pageId" => ^page_id} -> :ok
      _ -> {:error, :not_found, "There is no block #{block_id} on this page."}
    end
  end

  defp body(body) when is_binary(body) do
    case String.trim(body) do
      "" -> {:error, :invalid, "A comment needs a body."}
      body -> {:ok, body}
    end
  end

  defp body(_), do: {:error, :invalid, "A comment needs a body."}
end
