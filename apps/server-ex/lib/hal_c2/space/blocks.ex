defmodule HalC2.Space.Blocks do
  @moduledoc """
  The blocks and comments of a Space's pages, decided on its stream state like
  `HalC2.Space.Pages`. Only blocks and comments of a live page change.

  A block's place is its `order` key (`HalC2.Space.Order`): inserting or moving one
  writes that block alone. `afterBlockId` places it: after that block, first when
  nil, last when left out (`:last`).
  """

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, StreamState}
  alias HalC2.Space.{Order, Pages}

  @kinds ~w(paragraph heading checklist callout subpage_link)

  @doc "The kinds of block a page holds."
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
  `linkedPageId`), in order after `after`. Used by insert and by imports.
  """
  def insert_all(state, page_id, specs, after_id, author) do
    with {:ok, _page} <- Pages.fetch_live(state, page_id),
         {:ok, low, high} <- place(state, page_id, after_id, nil),
         {:ok, specs} <- valid_specs(state, specs) do
      at = Entities.now()

      {blocks, _} =
        Enum.map_reduce(specs, low, fn spec, low ->
          order = Order.between(low, high)

          block = %{
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

          {block, order}
        end)

      {Enum.map(blocks, &{"block", &1["id"], Patch.diff(nil, &1)}), {:ok, blocks}}
    end
    |> Pages.refused()
  end

  def insert(state, page_id, spec, after_id, author) do
    case insert_all(state, page_id, [spec], after_id, author) do
      {changes, {:ok, [block]}} -> {changes, {:ok, block}}
      refused -> refused
    end
  end

  def update_text(state, id, text, author) when is_binary(text),
    do: change(state, id, author, fn _ -> {:ok, %{"text" => text}} end)

  def update_text(_state, _id, _text, _author),
    do: Pages.refused({:error, :invalid, "A block's text is a string."})

  def set_checked(state, id, checked, author) when is_boolean(checked) do
    change(state, id, author, fn
      %{"kind" => "checklist"} -> {:ok, %{"checked" => checked}}
      _ -> {:error, :invalid, "Only a checklist item can be ticked."}
    end)
  end

  def set_checked(_state, _id, _checked, _author),
    do: Pages.refused({:error, :invalid, "checked is true or false."})

  def move(state, id, after_id, author) do
    change(state, id, author, fn block ->
      with {:ok, low, high} <- place(state, block["pageId"], after_id, id),
           do: {:ok, %{"order" => Order.between(low, high)}}
    end)
  end

  @doc "Deletes a block and the comments on it. Replies with the block's id."
  def delete(state, id) do
    with {:ok, block} <- fetch(state, id),
         {:ok, _} <- Pages.fetch_live(state, block["pageId"]) do
      comments =
        for c <- StreamState.list(state, "comment"),
            c["blockId"] == id,
            do: {"comment", c["id"], Patch.delete()}

      {[{"block", id, Patch.delete()} | comments], {:ok, id}}
    end
    |> Pages.refused()
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

  # Changes a block of a live page with the fields `fun` decides.
  defp change(state, id, author, fun) do
    with {:ok, block} <- fetch(state, id),
         {:ok, _} <- Pages.fetch_live(state, block["pageId"]),
         {:ok, fields} <- fun.(block) do
      next = Map.merge(block, fields)

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

      true ->
        :ok
    end
  end

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
