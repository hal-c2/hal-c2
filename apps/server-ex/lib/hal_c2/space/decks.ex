defmodule HalC2.Space.Decks do
  @moduledoc """
  The slide decks of one Space, decided on its stream state like `HalC2.Space.Pages`.

  A deck in the trash takes no edits; only a deck in the trash is deleted, with its
  slides. A slide's place is its `order` key (`HalC2.Space.Order`), so adding or moving
  one writes that slide alone. A deck made from a page is a copy, with no link back.
  """

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, Space, StreamState}
  alias HalC2.Space.{Blocks, Markdown, Order, Pages}

  @doc "The deck `id`, or nil."
  def get(state, id), do: StreamState.get(state, "deck")[id]

  @doc "The decks out of the trash, in the order they were made."
  def live(state), do: state |> StreamState.list("deck") |> Enum.reject(& &1["trashedAt"])

  @doc "The decks in the trash, in the order they were made."
  def trashed(state), do: state |> StreamState.list("deck") |> Enum.filter(& &1["trashedAt"])

  @doc "A deck's slides in order."
  def slides(state, deck_id) do
    for(slide <- StreamState.list(state, "slide"), slide["deckId"] == deck_id, do: slide)
    |> Enum.sort_by(&{&1["order"], &1["id"]})
  end

  @doc "A new deck with one blank slide."
  def create(_state, space_id, title) do
    with {:ok, title} <- title(title) do
      made(space_id, title, [%{"title" => "", "body" => ""}])
    end
    |> Pages.refused()
  end

  @doc "A new deck copied from the live page `page_id`, one slide per section."
  def create_from_page(state, space_id, page_id) do
    with {:ok, page} <- Pages.fetch_live(state, page_id) do
      made(space_id, page["title"], sections(state, page))
    end
    |> Pages.refused()
  end

  defp made(space_id, title, specs) do
    at = Entities.now()

    deck = %{
      "id" => HalC2.Environment.uuid4(),
      "spaceId" => space_id,
      "title" => title,
      "trashedAt" => nil,
      "createdAt" => at,
      "updatedAt" => at
    }

    {slides, _} = new_slides(deck["id"], specs, nil, nil)
    changes = for slide <- slides, do: {"slide", slide["id"], Patch.diff(nil, slide)}
    {[{"deck", deck["id"], Patch.diff(nil, deck)} | changes], {:ok, deck}}
  end

  # A slide for each heading and what follows it. What comes before the first heading,
  # or a page with no heading at all, goes under the page's title.
  defp sections(state, page) do
    blocks = state |> Blocks.of_page(page["id"]) |> Enum.flat_map(&ordinary(state, &1))
    {lead, rest} = Enum.split_while(blocks, &(&1["kind"] != "heading"))

    lead =
      if lead != [] or rest == [],
        do: [%{"title" => page["title"], "body" => body(state, lead)}],
        else: []

    lead ++
      (rest
       |> Enum.chunk_while(
         nil,
         fn
           %{"kind" => "heading"} = heading, nil -> {:cont, {heading, []}}
           %{"kind" => "heading"} = heading, section -> {:cont, section, {heading, []}}
           block, {heading, blocks} -> {:cont, {heading, [block | blocks]}}
         end,
         &if(&1, do: {:cont, &1, nil}, else: {:cont, nil})
       )
       |> Enum.map(fn {heading, blocks} ->
         %{"title" => heading["text"], "body" => body(state, Enum.reverse(blocks))}
       end))
  end

  # A run's Markdown reads as the blocks removing the update would make of it.
  defp ordinary(state, %{"kind" => "generated"} = block), do: Space.written(state, block["text"])
  defp ordinary(_state, block), do: [block]

  defp body(state, blocks), do: Enum.map_join(blocks, "\n", &line(state, &1))

  defp line(_state, %{"kind" => "checklist", "checked" => true} = b), do: "- [x] " <> b["text"]
  defp line(_state, %{"kind" => "checklist"} = b), do: "- [ ] " <> b["text"]
  defp line(_state, %{"kind" => "callout"} = b), do: "> " <> b["text"]
  defp line(_state, %{"kind" => "image"} = b), do: "[image: " <> b["text"] <> "]"
  defp line(_state, %{"kind" => "code"} = b), do: Markdown.render(b)

  defp line(state, %{"kind" => "subpage_link"} = b),
    do: (Pages.get(state, b["linkedPageId"]) || %{})["title"] || b["text"]

  defp line(_state, block), do: block["text"]

  def rename(state, id, title) do
    with {:ok, deck} <- fetch_live(state, id),
         {:ok, title} <- title(title) do
      update(deck, %{"title" => title})
    end
    |> Pages.refused()
  end

  def trash(state, id) do
    with {:ok, deck} <- fetch_live(state, id) do
      update(deck, %{"trashedAt" => Entities.now()})
    end
    |> Pages.refused()
  end

  def restore(state, id) do
    case get(state, id) do
      %{"trashedAt" => at} = deck when at != nil ->
        update(deck, %{"trashedAt" => nil})

      nil ->
        Pages.refused(no_deck(id))

      deck ->
        Pages.refused({:error, :invalid, "The deck \"#{deck["title"]}\" is not in the trash."})
    end
  end

  @doc "Deletes a deck in the trash for good, with its slides. Replies with its id."
  def delete(state, id) do
    case get(state, id) do
      %{"trashedAt" => at} when at != nil ->
        slides = for slide <- slides(state, id), do: {"slide", slide["id"], Patch.delete()}
        {[{"deck", id, Patch.delete()} | slides], {:ok, id}}

      nil ->
        Pages.refused(no_deck(id))

      deck ->
        Pages.refused(
          {:error, :invalid,
           "Only a deck in the trash can be deleted; move \"#{deck["title"]}\" there first."}
        )
    end
  end

  # --- slides -------------------------------------------------------------------------

  @doc "A new slide in a live deck from `spec` (`title`, `body`), after `after_id`."
  def insert_slide(state, deck_id, spec, after_id) do
    with {:ok, _deck} <- fetch_live(state, deck_id),
         {:ok, fields} <- text_fields(spec),
         {:ok, low, high} <- place(state, deck_id, after_id, nil) do
      {[slide], _} = new_slides(deck_id, [fields], low, high)
      {[{"slide", slide["id"], Patch.diff(nil, slide)}], {:ok, slide}}
    end
    |> Pages.refused()
  end

  @doc "Changes what `fields` gives of a slide's title and body."
  def update_slide(state, id, fields) do
    change_slide(state, id, fn _slide -> text_fields(fields) end)
  end

  def move_slide(state, id, after_id) do
    change_slide(state, id, fn slide ->
      with {:ok, low, high} <- place(state, slide["deckId"], after_id, id),
           do: {:ok, %{"order" => Order.between(low, high)}}
    end)
  end

  @doc "Deletes a slide of a live deck. Replies with its id."
  def delete_slide(state, id) do
    with {:ok, slide} <- fetch_slide(state, id),
         {:ok, _} <- fetch_live(state, slide["deckId"]) do
      {[{"slide", id, Patch.delete()}], {:ok, id}}
    end
    |> Pages.refused()
  end

  # --- helpers ------------------------------------------------------------------------

  defp new_slides(deck_id, specs, low, high) do
    at = Entities.now()

    Enum.map_reduce(specs, low, fn spec, low ->
      order = Order.between(low, high)

      slide = %{
        "id" => HalC2.Environment.uuid4(),
        "deckId" => deck_id,
        "title" => spec["title"] || "",
        "body" => spec["body"] || "",
        "order" => order,
        "createdAt" => at,
        "updatedAt" => at
      }

      {slide, order}
    end)
  end

  defp fetch_live(state, id) do
    case get(state, id) do
      nil -> no_deck(id)
      %{"trashedAt" => nil} = deck -> {:ok, deck}
      deck -> {:error, :trashed, "The deck \"#{deck["title"]}\" is in the trash."}
    end
  end

  defp no_deck(id), do: {:error, :not_found, "There is no deck #{id} in this Space."}

  defp fetch_slide(state, id) do
    case StreamState.get(state, "slide")[id] do
      nil -> {:error, :not_found, "There is no slide #{id} in this Space."}
      slide -> {:ok, slide}
    end
  end

  defp change_slide(state, id, fun) do
    with {:ok, slide} <- fetch_slide(state, id),
         {:ok, _} <- fetch_live(state, slide["deckId"]),
         {:ok, fields} <- fun.(slide) do
      next = Map.merge(slide, fields)

      case Patch.diff(slide, next) do
        :unchanged ->
          {[], {:ok, slide}}

        _ ->
          next = Map.put(next, "updatedAt", Entities.now())
          {[{"slide", id, Patch.diff(slide, next)}], {:ok, next}}
      end
    end
    |> Pages.refused()
  end

  defp text_fields(fields) do
    fields = Map.take(fields, ~w(title body))

    if Enum.all?(fields, fn {_, text} -> is_binary(text) end),
      do: {:ok, fields},
      else: {:error, :invalid, "A slide's title and body are strings."}
  end

  # The order keys a slide placed `after_id` sits between, leaving out `moving`.
  defp place(state, deck_id, after_id, moving) do
    keys = for s <- slides(state, deck_id), s["id"] != moving, do: {s["id"], s["order"]}

    case after_id do
      :last ->
        {:ok, keys |> List.last({nil, nil}) |> elem(1), nil}

      nil ->
        {:ok, nil, keys |> List.first({nil, nil}) |> elem(1)}

      id ->
        case Enum.split_while(keys, &(elem(&1, 0) != id)) do
          {_, [{_, low} | rest]} -> {:ok, low, rest |> List.first({nil, nil}) |> elem(1)}
          _ when id == moving -> {:error, :invalid, "A slide cannot go after itself."}
          _ -> {:error, :not_found, "There is no slide #{id} in this deck."}
        end
    end
  end

  defp update(deck, fields) do
    next = Map.merge(deck, fields)

    case Patch.diff(deck, next) do
      :unchanged ->
        {[], {:ok, deck}}

      _ ->
        next = Map.put(next, "updatedAt", Entities.now())
        {[{"deck", deck["id"], Patch.diff(deck, next)}], {:ok, next}}
    end
  end

  defp title(title) when is_binary(title) do
    case String.trim(title) do
      "" -> {:error, :invalid, "A deck needs a title."}
      title -> {:ok, title}
    end
  end

  defp title(_), do: {:error, :invalid, "A deck needs a title."}
end
