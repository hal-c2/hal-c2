defmodule HalC2.Steps.Space.Pages do
  @moduledoc """
  Steps for `features/space/pages.feature`. The user's edits go over the socket as
  `space.*` RPCs; outcomes are read from the Space's stream, and a second client
  follows it through the stream shape. The last refusal is `context.space_reply`.
  The scenario's Space is `context.space`; pages, blocks and comments are found by
  title, text and body in its stream.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.{Space, StreamState, Streams}
  alias HalC2.Space.{Blocks, Pages}
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @watch 71

  # --- Spaces --------------------------------------------------------------------------

  step("the user lists their Spaces", context, do: list(context) |> elem(1))
  step("the user has listed their Spaces", context, do: list(context) |> elem(1))

  step "the Spaces are {string}", %{args: [names]} = context do
    {spaces, context} = list(context)
    assert Enum.map_join(spaces, ", ", & &1["name"]) == names
    context
  end

  step "the user makes the Space {string}", %{args: [name]} = context do
    request(context, "space.create", %{"name" => name}, &remember_space/2)
  end

  step("the Space {string}", %{args: [name]} = context, do: make_space(context, name))

  step "the Space {string} with the page {string}", %{args: [name, title]} = context do
    context |> make_space(name) |> make_page(title)
  end

  step "the user renames the Space {string} to {string}", %{args: [name, next]} = context do
    request(context, "space.rename", %{"spaceId" => space_id(context, name), "name" => next})
  end

  step "the user deletes the Space {string}", %{args: [name]} = context do
    request(context, "space.delete", %{"spaceId" => space_id(context, name)})
  end

  step("the Space request is refused", context, do: refused(context))

  step("a second client watching the Spaces", context, do: watch(context, Space.index()))

  step "a second client watching the Space {string}", %{args: [name]} = context do
    watch(context, Space.stream_id(space_id(context, name)))
  end

  step "the second client sees the Space {string}", %{args: [name]} = context do
    sees(context, "space", &(&1["name"] == name))
  end

  step "the second client sees the block {string}", %{args: [text]} = context do
    sees(context, "block", &(&1["text"] == text))
  end

  # --- pages ---------------------------------------------------------------------------

  step("the page {string}", %{args: [title]} = context, do: make_page(context, title))

  step "the pages {string} and {string}", %{args: [first, second]} = context do
    context |> make_page(first) |> make_page(second)
  end

  step "the page {string} inside {string}", %{args: [title, parent]} = context do
    context = if page(context, parent), do: context, else: make_page(context, parent)
    make_page(context, title, page_id(context, parent))
  end

  step "the page {string} reads {string}", %{args: [title, text]} = context do
    context = if page(context, title), do: context, else: make_page(context, title)
    add_blocks(context, title, "paragraph", [text])
  end

  step "the page {string} is in the trash", %{args: [title]} = context do
    context = if page(context, title), do: context, else: make_page(context, title)
    {_, context} = World.call!(context, "space.page.trash", page_ref(context, title))
    context
  end

  step "the user makes the page {string}", %{args: [title]} = context do
    request(context, "space.page.create", %{"spaceId" => context.space, "title" => title})
  end

  step "the user makes the page {string} inside {string}", %{args: [title, parent]} = context do
    request(context, "space.page.create", %{
      "spaceId" => context.space,
      "title" => title,
      "parentPageId" => page_id(context, parent)
    })
  end

  step "the user renames the page {string} to {string}", %{args: [title, next]} = context do
    request(context, "space.page.rename", Map.put(page_ref(context, title), "title", next))
  end

  step "the user moves the page {string} to the top of the Space", %{args: [title]} = context do
    request(context, "space.page.move", Map.put(page_ref(context, title), "parentPageId", nil))
  end

  step "the user moves the page {string} into {string}", %{args: [title, parent]} = context do
    payload = Map.put(page_ref(context, title), "parentPageId", page_id(context, parent))
    request(context, "space.page.move", payload)
  end

  step "the user moves the page {string} to the trash", %{args: [title]} = context do
    request(context, "space.page.trash", page_ref(context, title))
  end

  step "the user restores the page {string}", %{args: [title]} = context do
    request(context, "space.page.restore", page_ref(context, title))
  end

  step "the user deletes the page {string} for good", %{args: [title]} = context do
    ids = descendants(context, page_id(context, title))
    context = Map.put(context, :deleted_pages, ids)
    request(context, "space.page.delete", page_ref(context, title))
  end

  step "the user writes {string} on the page {string}", %{args: [text, title]} = context do
    request(context, "space.block.insert", block_input(context, title, "paragraph", text))
  end

  step("the page request is refused", context, do: refused(context))
  step("the user is told only a checklist item can be ticked", context, do: refused(context))

  step "the pages of {string} are {string}", %{args: [name, titles]} = context do
    state = Streams.state(Space.stream_id(space_id(context, name)))
    assert Enum.map_join(Pages.live(state), ", ", & &1["title"]) == titles
    context
  end

  step "the trash of {string} holds {string}", %{args: [name, titles]} = context do
    state = Streams.state(Space.stream_id(space_id(context, name)))
    assert Enum.map_join(Pages.trashed(state), ", ", & &1["title"]) == titles
    context
  end

  step "{string} is a subpage of {string}", %{args: [title, parent]} = context do
    assert page(context, title)["parentPageId"] == page_id(context, parent)
    context
  end

  step "{string} is not inside another page", %{args: [title]} = context do
    assert page(context, title)["parentPageId"] == nil
    context
  end

  step "the page {string} still reads {string}", %{args: [title, text]} = context do
    assert texts(context, title) == [text]
    context
  end

  step "no blocks or comments of {string} or {string} remain",
       %{args: [_first, _second]} = context do
    state = state(context)
    gone = MapSet.new(context.deleted_pages)
    assert MapSet.size(gone) == 2
    refute Enum.any?(Map.values(StreamState.get(state, "page")), &(&1["id"] in gone))
    refute Enum.any?(Map.values(StreamState.get(state, "block")), &(&1["pageId"] in gone))
    refute Enum.any?(Map.values(StreamState.get(state, "comment")), &(&1["pageId"] in gone))
    context
  end

  # --- blocks --------------------------------------------------------------------------

  step "{string} has the blocks {string}", %{args: [title, texts]} = context do
    add_blocks(context, title, "paragraph", String.split(texts, ", "))
  end

  step "{string} has the checklist item {string}", %{args: [title, text]} = context do
    add_blocks(context, title, "checklist", [text])
  end

  step "the user adds a {word} block {string} to {string}",
       %{args: [kind, text, title]} = context do
    request(context, "space.block.insert", block_input(context, title, kind, text))
  end

  step "{string} has a {word} block {string}", %{args: [title, kind, text]} = context do
    assert Enum.any?(blocks(context, title), &(&1["kind"] == kind and &1["text"] == text))
    context
  end

  step "the user links {string} from {string}", %{args: [linked, title]} = context do
    input =
      context
      |> block_input(title, "subpage_link", nil)
      |> Map.put("linkedPageId", page_id(context, linked))

    request(context, "space.block.insert", input)
  end

  # What a client does for "New subpage" in the link menu: the page, then the link.
  step "the user makes the subpage {string} from a link on {string}",
       %{args: [linked, title]} = context do
    context =
      request(context, "space.page.create", %{
        "spaceId" => context.space,
        "title" => linked,
        "parentPageId" => page_id(context, title)
      })

    input =
      context
      |> block_input(title, "subpage_link", nil)
      |> Map.put("linkedPageId", page_id(context, linked))

    request(context, "space.block.insert", input)
  end

  step "{string} links to {string}", %{args: [title, linked]} = context do
    id = page_id(context, linked)

    assert Enum.any?(
             blocks(context, title),
             &(&1["kind"] == "subpage_link" and &1["linkedPageId"] == id)
           )

    context
  end

  step "the user adds {string} after {string} on {string}",
       %{args: [text, after_text, title]} = context do
    input =
      context
      |> block_input(title, "paragraph", text)
      |> Map.put("afterBlockId", block(context, after_text)["id"])

    request(context, "space.block.insert", input)
  end

  step "the blocks of {string} read {string}", %{args: [title, texts]} = context do
    assert Enum.map_join(blocks(context, title), ", ", & &1["text"]) == texts
    context
  end

  step "the user changes the block {string} to {string}", %{args: [text, next]} = context do
    request(context, "space.block.update", Map.put(block_ref(context, text), "text", next))
  end

  step("the user ticks {string}", %{args: [text]} = context, do: tick(context, text, true))
  step("the user unticks {string}", %{args: [text]} = context, do: tick(context, text, false))

  step "{string} is ticked", %{args: [text]} = context do
    assert block(context, text)["checked"] == true
    context
  end

  step "{string} is not ticked", %{args: [text]} = context do
    assert block(context, text)["checked"] == false
    context
  end

  step "the user moves the block {string} before {string}",
       %{args: [text, before_text]} = context do
    before = block(context, before_text)
    page = Enum.map(blocks(context, page_title(context, before["pageId"])), & &1["id"])
    index = Enum.find_index(page, &(&1 == before["id"]))
    after_id = if index == 0, do: nil, else: Enum.at(page, index - 1)
    stream = Space.stream_id(context.space)

    context
    |> Map.put(:sequence_before, Streams.sequence(stream))
    |> request("space.block.move", Map.put(block_ref(context, text), "afterBlockId", after_id))
  end

  step "only the block {string} changed", %{args: [text]} = context do
    id = block(context, text)["id"]

    events =
      HalC2.Store.path()
      |> HalC2.Store.reduce_stream(
        Space.stream_id(context.space),
        context.sequence_before,
        [],
        &[&1 | &2]
      )

    assert [%{kind: "block", entity: ^id}] = events
    context
  end

  step "the user deletes the block {string}", %{args: [text]} = context do
    request(context, "space.block.delete", block_ref(context, text))
  end

  # --- comments ------------------------------------------------------------------------

  step "the user comments {string} on the block {string}", %{args: [body, text]} = context do
    request(context, "space.comment.add", comment_input(context, text, body))
  end

  step "the comment {string} on the block {string}", %{args: [body, text]} = context do
    {_, context} = World.call!(context, "space.comment.add", comment_input(context, text, body))
    context
  end

  step "the comment {string} is resolved already", %{args: [body]} = context do
    {_, context} = World.call!(context, "space.comment.resolve", comment_ref(context, body))
    context
  end

  step "the user resolves the comment {string}", %{args: [body]} = context do
    request(context, "space.comment.resolve", comment_ref(context, body))
  end

  step "the user reopens the comment {string}", %{args: [body]} = context do
    request(context, "space.comment.reopen", comment_ref(context, body))
  end

  step "the block {string} has the open comment {string}", %{args: [text, body]} = context do
    comment = comment(context, body)
    assert comment["blockId"] == block(context, text)["id"]
    assert comment["resolvedAt"] == nil
    context
  end

  step "the comment {string} is resolved", %{args: [body]} = context do
    assert comment(context, body)["resolvedAt"] != nil
    context
  end

  # --- Markdown ------------------------------------------------------------------------

  step "the page {string} with the blocks:", %{args: [title]} = context do
    context = make_page(context, title)

    Enum.reduce(context.datatable.maps, context, fn row, context ->
      input = block_input(context, title, row["kind"], row["text"])
      {%{"block" => block}, context} = World.call!(context, "space.block.insert", input)

      if row["checked"] == "yes" do
        payload = %{"spaceId" => context.space, "blockId" => block["id"], "checked" => true}
        {_, context} = World.call!(context, "space.block.setChecked", payload)
        context
      else
        context
      end
    end)
  end

  step "the user exports {string} as Markdown", %{args: [title]} = context do
    request(context, "space.page.exportMarkdown", page_ref(context, title))
  end

  step "the Markdown is:", context do
    assert {:ok, %{"markdown" => markdown}} = context.space_reply
    assert markdown == context.docstring <> "\n"
    context
  end

  step "the user imports this Markdown into {string}:", %{args: [name]} = context do
    payload = %{"spaceId" => space_id(context, name), "markdown" => context.docstring}
    request(context, "space.page.importMarkdown", payload)
  end

  step "the page {string} has the blocks:", %{args: [title]} = context do
    expected =
      Enum.map(context.datatable.maps, fn row ->
        {row["kind"], row["text"], row["checked"] == "yes"}
      end)

    assert Enum.map(blocks(context, title), &{&1["kind"], &1["text"], &1["checked"]}) ==
             expected

    context
  end

  # --- a page from a thread ------------------------------------------------------------

  step "the thread {string} talked about a release plan", %{args: [title]} = context do
    context
    |> World.add_message(title, "user", "Plan the 2.0 release: tag, notes, then ship.")
    |> World.add_message(title, "assistant", "Tag v2.0 first, then write the notes.")
  end

  step "text generation is available", context do
    answer = %{"title" => "Release plan", "markdown" => "## Steps\n\n- [ ] Tag v2.0"}
    World.text_writers(context, [:codex, :claude], answer)
  end

  step "no text generation provider is available", context do
    context
    |> World.text_writers([])
    |> World.update_settings(%{
      "providers" => Map.new(~w(cursor grok opencode), &{&1, %{"enabled" => false}})
    })
  end

  step "text generation fails", context do
    context = World.text_writers(context)
    World.put_env("FAKE_TEXT_FAIL", "the model is overloaded")
    context
  end

  step "the user makes a page in {string} from the thread {string}",
       %{args: [name, thread]} = context do
    payload = %{
      "spaceId" => space_id(context, name),
      "threadId" => World.thread_id(context, thread)
    }

    request(context, "space.page.createFromThread", payload, &remember_page/2)
  end

  step "the new page holds the generated summary", context do
    assert %{"title" => "Release plan"} = context.new_page

    assert [{"heading", "Steps"}, {"checklist", "Tag v2.0"}] =
             Enum.map(blocks(context, "Release plan"), &{&1["kind"], &1["text"]})

    context
  end

  step "the new page remembers it came from {string}", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    assert context.new_page["sourceThreadId"] == id
    assert Enum.all?(blocks(context, "Release plan"), &(&1["createdBy"]["threadId"] == id))
    context
  end

  step "the summary was written in the project's folder", context do
    [call] =
      Path.join(context.mc.home, "text-calls.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert call["cwd"] == World.project(context).root
    assert call["prompt"] =~ "Tag v2.0 first"
    context
  end

  step "the user is told text generation is unavailable", context do
    assert {:error, _, %{"_tag" => "SpaceTextGenerationError", "reason" => "unavailable"}} =
             context.space_reply

    context
  end

  step "the user is told text generation failed", context do
    assert {:error, _, %{"_tag" => "SpaceTextGenerationError", "reason" => "failed"}} =
             context.space_reply

    context
  end

  # --- helpers -------------------------------------------------------------------------

  defp list(context) do
    {%{"spaces" => spaces}, context} = World.call!(context, "space.list")
    {spaces, context}
  end

  # Calls `method`, keeping the reply as `context.space_reply`; `on_ok` sees a success.
  defp request(context, method, payload, on_ok \\ fn _, context -> context end) do
    {reply, context} = World.call(context, method, payload)
    context = Map.put(context, :space_reply, reply)

    case reply do
      {:ok, result} -> on_ok.(result, context)
      _ -> context
    end
  end

  defp refused(context) do
    assert {:error, _, %{"_tag" => "SpaceError"}} = context.space_reply
    context
  end

  defp make_space(context, name) do
    {result, context} = World.call!(context, "space.create", %{"name" => name})
    remember_space(result, context)
  end

  defp remember_space(%{"space" => space}, context) do
    context
    |> Map.update(
      :spaces,
      %{space["name"] => space["id"]},
      &Map.put(&1, space["name"], space["id"])
    )
    |> Map.put(:space, space["id"])
  end

  defp remember_page(%{"page" => page}, context), do: Map.put(context, :new_page, page)

  defp space_id(context, name) do
    (context[:spaces] || %{})[name] || flunk("no Space #{inspect(name)} in this scenario")
  end

  defp make_page(context, title, parent \\ nil) do
    payload = %{"spaceId" => context.space, "title" => title, "parentPageId" => parent}
    {_, context} = World.call!(context, "space.page.create", payload)
    context
  end

  defp add_blocks(context, title, kind, texts) do
    Enum.reduce(texts, context, fn text, context ->
      {_, context} =
        World.call!(context, "space.block.insert", block_input(context, title, kind, text))

      context
    end)
  end

  defp tick(context, text, checked) do
    request(
      context,
      "space.block.setChecked",
      Map.put(block_ref(context, text), "checked", checked)
    )
  end

  defp state(context), do: Streams.state(Space.stream_id(context.space))

  defp page(context, title),
    do: Enum.find(Map.values(StreamState.get(state(context), "page")), &(&1["title"] == title))

  defp page_id(context, title),
    do: (page(context, title) || flunk("no page #{inspect(title)}"))["id"]

  defp page_title(context, id), do: StreamState.get(state(context), "page")[id]["title"]

  defp page_ref(context, title),
    do: %{"spaceId" => context.space, "pageId" => page_id(context, title)}

  defp descendants(context, id) do
    pages = Map.values(StreamState.get(state(context), "page"))
    children = for p <- pages, p["parentPageId"] == id, do: descendants(context, p["id"])
    [id | List.flatten(children)]
  end

  defp blocks(context, title), do: Blocks.of_page(state(context), page_id(context, title))
  defp texts(context, title), do: Enum.map(blocks(context, title), & &1["text"])

  defp block(context, text) do
    Enum.find(Map.values(StreamState.get(state(context), "block")), &(&1["text"] == text)) ||
      flunk("no block #{inspect(text)}")
  end

  defp block_ref(context, text),
    do: %{"spaceId" => context.space, "blockId" => block(context, text)["id"]}

  defp block_input(context, title, kind, text) do
    %{"spaceId" => context.space, "pageId" => page_id(context, title), "kind" => kind}
    |> then(&if(text, do: Map.put(&1, "text", text), else: &1))
  end

  defp comment(context, body) do
    Enum.find(Map.values(StreamState.get(state(context), "comment")), &(&1["body"] == body)) ||
      flunk("no comment #{inspect(body)}")
  end

  defp comment_ref(context, body),
    do: %{"spaceId" => context.space, "commentId" => comment(context, body)["id"]}

  defp comment_input(context, text, body) do
    block = block(context, text)

    %{
      "spaceId" => context.space,
      "pageId" => block["pageId"],
      "blockId" => block["id"],
      "body" => body
    }
  end

  # A second socket subscribed to `stream`, caught up to its live edge.
  defp watch(context, stream) do
    shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => stream}
    client = context.mc |> Mc.connect() |> Mc.sub(@watch, shape)
    {_, client} = Mc.await(client, &(&1["t"] == "live" and &1["id"] == @watch))
    World.put_client(context, "second", client)
  end

  # The second client receives an event that makes a `kind` entity matching `fun`.
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
