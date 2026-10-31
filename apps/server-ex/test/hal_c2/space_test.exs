defmodule HalC2.SpaceTest do
  # The commands of `HalC2.Space` on a real store and streams. The scenarios in
  # `features/space/pages.feature` cover the same ground through the RPCs; these pin
  # the edges: what each refusal leaves, what a delete takes with it, and that a
  # block placed between others is the only block written.
  use ExUnit.Case

  alias HalC2.{Space, Streams}
  alias HalC2.Space.{Markdown, Order}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    {:ok, space} = Space.create("Research")
    %{space: space["id"]}
  end

  defp page!(space, title, parent \\ nil) do
    {:ok, page} = Space.create_page(space, title, parent)
    page["id"]
  end

  defp block!(space, page, text, kind \\ "paragraph", after_id \\ :last) do
    {:ok, block} = Space.insert_block(space, page, %{"kind" => kind, "text" => text}, after_id)
    block["id"]
  end

  defp texts(space, page) do
    {:ok, %{blocks: blocks}} = Space.page(space, page)
    Enum.map(blocks, & &1["text"])
  end

  describe "Spaces" do
    test "Personal is made with the first Space, and again only when none are left",
         %{space: space} do
      assert {:ok, [%{"name" => "Personal"} = personal, %{"id" => ^space}]} = Space.list()

      {:ok, _} = Space.delete(space)
      {:ok, _} = Space.delete(personal["id"])
      assert {:ok, [%{"name" => "Personal"} = again]} = Space.list()
      assert again["id"] != personal["id"]
      assert {:ok, [^again]} = Space.list()
    end

    test "ids are random, not counted" do
      {:ok, a} = Space.create("A")
      {:ok, b} = Space.create("B")
      uuid = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      assert a["id"] =~ uuid and b["id"] =~ uuid and a["id"] != b["id"]
    end

    test "a blank name is refused and changes nothing", %{space: space} do
      assert {:error, :invalid, _} = Space.create("  ")
      assert {:error, :invalid, _} = Space.rename(space, "")
      assert {:ok, [_personal, %{"name" => "Research"}]} = Space.list()
    end

    test "a Space with a page, even in the trash, is not deleted", %{space: space} do
      page = page!(space, "Notes")
      {:ok, _} = Space.trash_page(space, page)
      assert {:error, :not_empty, _} = Space.delete(space)

      {:ok, _} = Space.delete_page(space, page)
      assert {:ok, ^space} = Space.delete(space)
      assert {:error, :not_found, _} = Space.create_page(space, "Late")
    end
  end

  describe "pages" do
    test "a page cannot move inside itself or below its own subpage", %{space: space} do
      top = page!(space, "Roadmap")
      mid = page!(space, "Q3", top)
      low = page!(space, "Week 1", mid)

      assert {:error, :cycle, _} = Space.move_page(space, top, top)
      assert {:error, :cycle, _} = Space.move_page(space, top, low)
      assert {:ok, %{"parentPageId" => nil}} = Space.move_page(space, low, nil)
      assert {:ok, %{"parentPageId" => ^low}} = Space.move_page(space, top, low)
    end

    test "trash hides subpages; a restored page whose parent is still trashed goes to the top",
         %{space: space} do
      top = page!(space, "Roadmap")
      sub = page!(space, "Q3", top)
      {:ok, _} = Space.trash_page(space, sub)
      {:ok, _} = Space.trash_page(space, top)

      assert {:error, :trashed, _} = Space.rename_page(space, sub, "Q4")
      assert {:error, :trashed, _} = Space.create_page(space, "Child", top)

      assert {:ok, %{"parentPageId" => nil, "trashedAt" => nil}} = Space.restore_page(space, sub)
      assert {:ok, %{"parentPageId" => nil}} = Space.restore_page(space, top)
      assert {:error, :invalid, _} = Space.restore_page(space, top)
    end

    test "deleting a trashed page takes its subpages, blocks, comments and links to them",
         %{space: space} do
      top = page!(space, "Roadmap")
      sub = page!(space, "Q3", top)
      other = page!(space, "Index")
      block = block!(space, sub, "Ship")
      {:ok, _} = Space.add_comment(space, sub, block, "When?")

      {:ok, link} =
        Space.insert_block(space, other, %{"kind" => "subpage_link", "linkedPageId" => sub})

      {:ok, _} = Space.add_comment(space, other, link["id"], "Still needed?")

      assert {:error, :invalid, _} = Space.delete_page(space, top)
      {:ok, _} = Space.trash_page(space, top)
      assert {:ok, deleted} = Space.delete_page(space, top)
      assert Enum.sort(deleted) == Enum.sort([top, sub])

      state = Streams.state(Space.stream_id(space))
      assert Map.keys(HalC2.StreamState.get(state, "page")) == [other]
      assert HalC2.StreamState.get(state, "block") == %{}
      assert HalC2.StreamState.get(state, "comment") == %{}
    end
  end

  describe "blocks" do
    setup %{space: space}, do: %{page: page!(space, "Roadmap")}

    test "a block placed between two others is the only one written", %{space: space, page: page} do
      one = block!(space, page, "One")
      three = block!(space, page, "Three")
      stream = Space.stream_id(space)
      before = Streams.sequence(stream)

      _two = block!(space, page, "Two", "paragraph", one)
      assert Streams.sequence(stream) == before + 1
      assert texts(space, page) == ~w(One Two Three)

      {:ok, _} = Space.move_block(space, three, nil)
      assert Streams.sequence(stream) == before + 2
      assert texts(space, page) == ~w(Three One Two)
    end

    test "a block cannot go after itself or a block of another page", %{space: space, page: page} do
      one = block!(space, page, "One")
      elsewhere = block!(space, page!(space, "Other"), "There")

      assert {:error, :invalid, _} = Space.move_block(space, one, one)
      assert {:error, :not_found, _} = Space.move_block(space, one, elsewhere)
    end

    test "only a checklist item is ticked, and ticking it again changes nothing",
         %{space: space, page: page} do
      plain = block!(space, page, "Plain")
      item = block!(space, page, "Ship", "checklist")

      assert {:error, :invalid, _} = Space.set_checked(space, plain, true)
      assert {:ok, %{"checked" => true}} = Space.set_checked(space, item, true)
      seq = Streams.sequence(Space.stream_id(space))
      assert {:ok, %{"checked" => true}} = Space.set_checked(space, item, true)
      assert Streams.sequence(Space.stream_id(space)) == seq
    end

    test "an agent's edit names its thread", %{space: space, page: page} do
      block = block!(space, page, "Draft")
      agent = Space.agent("thread-1")

      assert {:ok, %{"createdBy" => %{"type" => "user"}, "updatedBy" => ^agent}} =
               Space.update_block(space, block, "Final", agent)
    end

    test "a subpage link needs a page of the Space", %{space: space, page: page} do
      assert {:error, :invalid, _} =
               Space.insert_block(space, page, %{"kind" => "subpage_link", "linkedPageId" => "x"})

      assert {:error, :invalid, _} = Space.insert_block(space, page, %{"kind" => "table"})
    end
  end

  describe "comments" do
    test "resolve and reopen are each other's way back, and repeating one changes nothing",
         %{space: space} do
      page = page!(space, "Roadmap")
      {:ok, comment} = Space.add_comment(space, page, nil, "Why?")
      id = comment["id"]

      assert {:ok, %{"resolvedAt" => at}} = Space.resolve_comment(space, id)
      assert at != nil
      assert {:ok, %{"resolvedAt" => ^at}} = Space.resolve_comment(space, id)
      assert {:ok, %{"resolvedAt" => nil}} = Space.reopen_comment(space, id)
      assert {:error, :invalid, _} = Space.add_comment(space, page, nil, " ")
    end
  end

  describe "Markdown" do
    test "an exported page imports back as the same blocks", %{space: space} do
      page = page!(space, "Roadmap")
      sub = page!(space, "Q3", page)
      block!(space, page, "Goals", "heading")
      block!(space, page, "Ship pages\nthen slides")
      {:ok, item} = Space.insert_block(space, page, %{"kind" => "checklist", "text" => "MC"})
      {:ok, _} = Space.set_checked(space, item["id"], true)
      block!(space, page, "Mind\nthe trash", "callout")

      {:ok, _} =
        Space.insert_block(space, page, %{"kind" => "subpage_link", "linkedPageId" => sub})

      {:ok, markdown} = Space.export_markdown(space, page)
      {:ok, copy} = Space.import_markdown(space, markdown)

      shape = fn id ->
        {:ok, %{page: page, blocks: blocks}} = Space.page(space, id)
        {page["title"], Enum.map(blocks, &Map.take(&1, ~w(kind text checked linkedPageId)))}
      end

      {title, blocks} = shape.(page)
      # A link's text is the linked page's title, which the export writes out.
      blocks =
        Enum.map(blocks, &if(&1["kind"] == "subpage_link", do: %{&1 | "text" => "Q3"}, else: &1))

      assert shape.(copy["id"]) == {title, blocks}
    end

    test "blocks are apart by a blank line, checklist items only by a line break" do
      blocks = [
        %{"id" => "a", "kind" => "heading", "text" => "Goals"},
        %{"id" => "b", "kind" => "paragraph", "text" => "Ship"},
        %{"id" => "c", "kind" => "paragraph", "text" => "Then rest"},
        %{"id" => "d", "kind" => "checklist", "text" => "MC", "checked" => true},
        %{"id" => "e", "kind" => "checklist", "text" => "QML", "checked" => false}
      ]

      assert Markdown.export(%{"title" => "Plan"}, blocks, fn _ -> nil end) ==
               "# Plan\n\n## Goals\n\nShip\n\nThen rest\n\n- [x] MC\n- [ ] QML\n"
    end

    test "a second top heading is a heading, and a link keeps its page id" do
      assert {"Plan", [%{"kind" => "heading", "text" => "Plan"}]} =
               Markdown.parse("# Plan\n\n# Plan")

      assert {nil, [%{"kind" => "subpage_link", "linkedPageId" => "gone"}]} =
               Markdown.parse("[Old](#gone)")
    end

    test "a blank top heading imports as Untitled", %{space: space} do
      {:ok, page} = Space.import_markdown(space, "#  \n\nShip")
      assert page["title"] == "Untitled"
    end

    test "a link to a page the Space lacks is imported as a paragraph", %{space: space} do
      {:ok, page} = Space.import_markdown(space, "[Old](#gone)", "Copy")
      assert texts(space, page["id"]) == ["[Old](#gone)"]
    end
  end

  describe "order keys" do
    test "keys between neighbours sort between them, at either end and in the middle" do
      first = Order.between(nil, nil)

      keys =
        Enum.reduce(1..40, [first], fn _, [low | _] = acc -> [Order.between(low, nil) | acc] end)

      assert Enum.reverse(keys) == Enum.sort(keys)

      squeezed =
        Enum.reduce(1..40, {first, Order.between(first, nil)}, fn _, {low, high} ->
          mid = Order.between(low, high)
          assert low < mid and mid < high
          {low, mid}
        end)

      assert {_, _} = squeezed
      assert Order.between(nil, first) < first
    end
  end
end
