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

  A block of the kind `generated` is the marked part of a page that updates itself
  (`HalC2.Space.Schedule`): a page has at most one, its text is the Markdown of the last
  run, and only `write_generated/4` writes it. Anyone may move or delete it or comment on
  it, but its text cannot be edited and it cannot be inserted.
  """

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, StreamState}
  alias HalC2.Space.{Chart, Images, Order, Pages}

  @kinds ~w(paragraph heading checklist callout subpage_link image raw)

  @generated "generated"

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
  `linkedPageId`, `imageId`, `level`, `gap`), in order after `after`. Used by insert and by imports.
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
  def text(state, %{"kind" => "image"} = spec) do
    case spec["text"] do
      text when text in [nil, ""] -> Images.get(state, spec["imageId"])["name"]
      text -> text
    end
  end

  def text(_state, spec), do: spec["text"] || ""

  # Only an image block has `imageId` and a heading `level`, and only a block from
  # Markdown a `gap`: every other block stays as it was written.
  defp with_extras(block, spec) do
    block
    |> put_extra("imageId", spec["kind"] == "image" && spec["imageId"])
    |> put_extra("level", spec["kind"] == "heading" && spec["level"])
    |> put_extra("gap", spec["gap"])
  end

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
    do: edit(state, id, text, nil, author)

  def update_text(_state, _id, _text, _author),
    do: Pages.refused({:error, :invalid, "A block's text is a string."})

  def set_checked(state, id, checked, author) when is_boolean(checked),
    do: edit(state, id, nil, checked, author)

  def set_checked(_state, _id, _checked, _author),
    do: Pages.refused({:error, :invalid, "checked is true or false."})

  @doc """
  Changes a block's text and tick in one step: either refused, nothing changes. A
  `nil` text or tick stays as it is.
  """
  def edit(state, id, text, checked, author) do
    change(state, id, author, fn block ->
      with {:ok, text} <- text_change(block, text),
           {:ok, tick} <- tick_change(block, checked),
           do: {:ok, Map.merge(text, tick)}
    end)
  end

  defp text_change(_block, nil), do: {:ok, %{}}

  defp text_change(%{"kind" => @generated}, _text),
    do: {:error, :invalid, "What a page's update wrote cannot be edited by hand."}

  defp text_change(%{"kind" => "chart"}, _),
    do: {:error, :invalid, "A chart cannot be edited. Ask for it again."}

  defp text_change(_block, text) when is_binary(text), do: {:ok, %{"text" => text}}
  defp text_change(_block, _), do: {:error, :invalid, "A block's text is a string."}

  defp tick_change(_block, nil), do: {:ok, %{}}

  defp tick_change(%{"kind" => "checklist"}, checked) when is_boolean(checked),
    do: {:ok, %{"checked" => checked}}

  defp tick_change(_block, checked) when is_boolean(checked),
    do: {:error, :invalid, "Only a checklist item can be ticked."}

  defp tick_change(_block, _), do: {:error, :invalid, "checked is true or false."}

  def move(state, id, after_id, author) do
    change(state, id, author, fn block ->
      with {:ok, low, high} <- place(state, block["pageId"], after_id, id),
           do: {:ok, %{"order" => Order.between(low, high), "gap" => :unset}}
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
          |> Map.drop(~w(imageId level gap))
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
      case valid_spec(state, spec) do
        :ok -> {:cont, {:ok, [spec | acc]}}
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

      spec["kind"] == "image" ->
        with {:ok, _} <- Images.fetch_live(state, spec["imageId"]), do: :ok

      spec["kind"] == "heading" and spec["level"] not in [nil | Enum.to_list(1..6)] ->
        {:error, :invalid, "A heading's level is 1 to 6."}

      not is_nil(spec["gap"]) and not (is_binary(spec["gap"]) and gap?(spec["gap"])) ->
        {:error, :invalid, "A block's gap is blank lines."}

      true ->
        :ok
    end
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
