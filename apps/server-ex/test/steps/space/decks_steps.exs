defmodule HalC2.Steps.Space.Decks do
  @moduledoc """
  Steps for `features/space/slides.feature` on the MC: edits go over the socket as
  `space.deck.*` and `space.slide.*` RPCs, outcomes are read from the Space's stream.
  Decks are found by title and slides by title. Presenting is the clients'.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.{Space, StreamState, Streams}
  alias HalC2.Space.Decks
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @watch 71

  step("the deck {string}", %{args: [title]} = context, do: make_deck(context, title) |> elem(1))

  step "the deck {string} with the slides {string}", %{args: [title, titles]} = context do
    {deck, context} = make_deck(context, title)
    state = state(context)
    [blank] = Decks.slides(state, deck["id"])
    {_, context} = World.call!(context, "space.slide.delete", slide_ref(context, blank))
    names = if titles == "", do: [], else: String.split(titles, ", ")

    Enum.reduce(names, context, fn name, context ->
      payload = %{"spaceId" => context.space, "deckId" => deck["id"], "title" => name}
      {_, context} = World.call!(context, "space.slide.insert", payload)
      context
    end)
  end

  step "the deck {string} is in the trash", %{args: [title]} = context do
    {_, context} = World.call!(context, "space.deck.trash", deck_ref(context, title))
    context
  end

  step "the user makes the deck {string}", %{args: [title]} = context do
    request(context, "space.deck.create", %{"spaceId" => context.space, "title" => title})
  end

  step "the user makes a deck from the page {string}", %{args: [title]} = context do
    page =
      Enum.find(Map.values(StreamState.get(state(context), "page")), &(&1["title"] == title))

    request(context, "space.deck.createFromPage", %{
      "spaceId" => context.space,
      "pageId" => page["id"]
    })
  end

  step "the user renames the deck {string} to {string}", %{args: [title, next]} = context do
    request(context, "space.deck.rename", Map.put(deck_ref(context, title), "title", next))
  end

  step "the user moves the deck {string} to the trash", %{args: [title]} = context do
    request(context, "space.deck.trash", deck_ref(context, title))
  end

  step "the user restores the deck {string}", %{args: [title]} = context do
    request(context, "space.deck.restore", deck_ref(context, title))
  end

  step "the user deletes the deck {string} for good", %{args: [title]} = context do
    request(context, "space.deck.delete", deck_ref(context, title))
  end

  step "the deck request is refused", context do
    assert {:error, _, %{"_tag" => "SpaceError"}} = context.space_reply
    context
  end

  step "the decks of {string} are {string}", %{args: [_name, titles]} = context do
    assert Enum.map_join(Decks.live(state(context)), ", ", & &1["title"]) == titles
    context
  end

  step "the deck {string} has the slides:", %{args: [title]} = context do
    expected =
      Enum.map(context.datatable.maps, fn row ->
        {row["title"] || "", String.replace(row["body"] || "", " / ", "\n")}
      end)

    assert Enum.map(slides(context, title), &{&1["title"], &1["body"]}) == expected
    context
  end

  step "the slides of {string} are {string}", %{args: [title, titles]} = context do
    assert Enum.map_join(slides(context, title), ", ", & &1["title"]) == titles
    context
  end

  step "the slides of {string} are still {string}", %{args: [title, titles]} = context do
    assert Enum.map_join(slides(context, title), ", ", & &1["title"]) == titles
    context
  end

  step "the user adds the slide {string} to {string}", %{args: [name, title]} = context do
    request(context, "space.slide.insert", Map.put(deck_ref(context, title), "title", name))
  end

  step "the user adds the slide {string} after {string} in {string}",
       %{args: [name, after_title, title]} = context do
    payload =
      deck_ref(context, title)
      |> Map.put("title", name)
      |> Map.put("afterSlideId", slide(context, after_title)["id"])

    request(context, "space.slide.insert", payload)
  end

  step "the user changes the slide {string} to {string} reading {string}",
       %{args: [name, next, body]} = context do
    payload =
      slide_ref(context, slide(context, name))
      |> Map.merge(%{"title" => next, "body" => body})

    request(context, "space.slide.update", payload)
  end

  step "the user moves the slide {string} before {string}",
       %{args: [name, before_title]} = context do
    before = slide(context, before_title)
    ids = Enum.map(Decks.slides(state(context), before["deckId"]), & &1["id"])
    index = Enum.find_index(ids, &(&1 == before["id"]))
    after_id = if index == 0, do: nil, else: Enum.at(ids, index - 1)
    payload = Map.put(slide_ref(context, slide(context, name)), "afterSlideId", after_id)
    request(context, "space.slide.move", payload)
  end

  step "the user deletes the slide {string}", %{args: [name]} = context do
    request(context, "space.slide.delete", slide_ref(context, slide(context, name)))
  end

  step "no slides remain in {string}", %{args: [_name]} = context do
    assert StreamState.get(state(context), "slide") == %{}
    context
  end

  step "the second client sees the deck {string}", %{args: [title]} = context do
    sees(context, "deck", &(&1["title"] == title))
  end

  step "the second client sees the slide {string}", %{args: [title]} = context do
    sees(context, "slide", &(&1["title"] == title))
  end

  defp make_deck(context, title) do
    payload = %{"spaceId" => context.space, "title" => title}
    {%{"deck" => deck}, context} = World.call!(context, "space.deck.create", payload)
    {deck, context}
  end

  defp request(context, method, payload) do
    {reply, context} = World.call(context, method, payload)
    Map.put(context, :space_reply, reply)
  end

  defp state(context), do: Streams.state(Space.stream_id(context.space))

  defp deck(context, title) do
    Enum.find(Map.values(StreamState.get(state(context), "deck")), &(&1["title"] == title)) ||
      flunk("no deck #{inspect(title)}")
  end

  defp deck_ref(context, title),
    do: %{"spaceId" => context.space, "deckId" => deck(context, title)["id"]}

  defp slides(context, title), do: Decks.slides(state(context), deck(context, title)["id"])

  defp slide(context, title) do
    Enum.find(Map.values(StreamState.get(state(context), "slide")), &(&1["title"] == title)) ||
      flunk("no slide #{inspect(title)}")
  end

  defp slide_ref(context, slide), do: %{"spaceId" => context.space, "slideId" => slide["id"]}

  # The second client (`HalC2.Steps.Space.Pages`) receives an event making a `kind`.
  defp sees(context, kind, fun) do
    match? = fn frame ->
      frame["t"] == "events" and frame["id"] == @watch and
        Enum.any?(frame["events"], fn [_seq, k, _id, patch | _] ->
          k == kind and is_map(patch["s"]) and fun.(patch["s"])
        end)
    end

    {_, client} = Mc.await(World.client(context, "second"), match?, 5_000)
    World.put_client(context, "second", client)
  end
end
