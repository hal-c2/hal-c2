defmodule HalC2.SpaceTest do
  # The commands of `HalC2.Space` on a real store and streams. The scenarios in
  # `features/space/pages.feature` cover the same ground through the RPCs; these pin
  # the edges: what each refusal leaves, what a delete takes with it, and that a
  # block placed between others is the only block written.
  use ExUnit.Case

  alias HalC2.{Space, Streams}
  alias HalC2.Space.{Decks, ImageFile, Images, Markdown, Order}

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

  describe "decks" do
    defp slides(space, deck) do
      {:ok, state} = Space.state(space)
      Decks.slides(state, deck)
    end

    defp slide!(space, deck, title, after_id \\ :last) do
      {:ok, slide} = Space.insert_slide(space, deck, %{"title" => title}, after_id)
      slide["id"]
    end

    test "a page's link and blocks become a slide's lines, heading by heading",
         %{space: space} do
      page = page!(space, "Roadmap")
      sub = page!(space, "Q3", page)
      block!(space, page, "Goals", "heading")

      {:ok, _} =
        Space.insert_block(space, page, %{"kind" => "subpage_link", "linkedPageId" => sub})

      block!(space, page, "Risks", "heading")
      block!(space, page, "", "heading")

      {:ok, deck} = Space.create_deck_from_page(space, page)

      assert [{"Goals", "Q3"}, {"Risks", ""}, {"", ""}] =
               Enum.map(slides(space, deck["id"]), &{&1["title"], &1["body"]})
    end

    test "an image on the page is marked on its slide, with its caption", %{space: space} do
      page = page!(space, "Roadmap")
      {:ok, image} = Space.add_image(space, upload(), "cat.png")

      {:ok, _} =
        Space.insert_block(space, page, %{
          "kind" => "image",
          "text" => "The cat",
          "imageId" => image["id"]
        })

      {:ok, deck} = Space.create_deck_from_page(space, page)
      assert [%{"title" => "Roadmap", "body" => "[image: The cat]"}] = slides(space, deck["id"])
    end

    test "an empty page makes one blank slide under its title", %{space: space} do
      {:ok, deck} = Space.create_deck_from_page(space, page!(space, "Roadmap"))
      assert [%{"title" => "Roadmap", "body" => ""}] = slides(space, deck["id"])
    end

    test "a slide placed or moved between others is the only one written", %{space: space} do
      {:ok, deck} = Space.create_deck(space, "Pitch")
      [blank] = slides(space, deck["id"])
      three = slide!(space, deck["id"], "Three")
      stream = Space.stream_id(space)
      before = Streams.sequence(stream)

      slide!(space, deck["id"], "Two", blank["id"])
      assert Streams.sequence(stream) == before + 1

      {:ok, _} = Space.move_slide(space, three, nil)
      assert Streams.sequence(stream) == before + 2
      assert ["Three", "", "Two"] = Enum.map(slides(space, deck["id"]), & &1["title"])
    end

    test "a slide cannot go after itself or a slide of another deck", %{space: space} do
      {:ok, deck} = Space.create_deck(space, "Pitch")
      {:ok, other} = Space.create_deck(space, "Other")
      [mine] = slides(space, deck["id"])
      [theirs] = slides(space, other["id"])

      assert {:error, :invalid, _} = Space.move_slide(space, mine["id"], mine["id"])
      assert {:error, :not_found, _} = Space.move_slide(space, mine["id"], theirs["id"])
    end

    test "an edit that changes nothing writes nothing; a title must be a string", %{space: space} do
      {:ok, deck} = Space.create_deck(space, "Pitch")
      [slide] = slides(space, deck["id"])
      seq = Streams.sequence(Space.stream_id(space))

      assert {:ok, _} = Space.update_slide(space, slide["id"], %{"title" => "", "body" => ""})
      assert {:error, :invalid, _} = Space.update_slide(space, slide["id"], %{"title" => 1})
      assert Streams.sequence(Space.stream_id(space)) == seq
    end

    test "a Space with a deck, even in the trash, is not deleted", %{space: space} do
      {:ok, deck} = Space.create_deck(space, "Pitch")
      assert {:error, :not_empty, _} = Space.delete(space)
      {:ok, _} = Space.trash_deck(space, deck["id"])
      assert {:error, :not_empty, _} = Space.delete(space)
      {:ok, _} = Space.delete_deck(space, deck["id"])
      assert {:ok, ^space} = Space.delete(space)
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

  describe "images" do
    @png <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 3::32, 2::32, 8, 6, 0, 0, 0>>

    defp upload(bytes \\ @png) do
      id = "pending-#{HalC2.Environment.uuid4()}"
      File.mkdir_p!(HalC2.Attachments.dir())
      File.write!(Path.join(HalC2.Attachments.dir(), id <> ".png"), bytes)
      id
    end

    test "the size comes from the file, whatever was claimed", %{space: space} do
      assert {:ok, %{"width" => 3, "height" => 2, "mimeType" => "image/png"}} =
               Space.add_image(space, upload(), "cat.png")
    end

    test "a name loses its folders", %{space: space} do
      assert {:ok, %{"name" => "cat.png"}} =
               Space.add_image(space, upload(), "../../secret/cat.png")
    end

    test "only an upload can be taken, not any file by its id", %{space: space} do
      for id <- ["../../etc/passwd", "thread-1", "pending-../x", nil] do
        assert {:error, :invalid, _} = Space.add_image(space, id, "x.png")
      end
    end

    test "an upload still being written is not taken", %{space: space} do
      id = "pending-#{HalC2.Environment.uuid4()}"
      File.mkdir_p!(HalC2.Attachments.dir())
      part = Path.join(HalC2.Attachments.dir(), id <> ".part")
      File.write!(part, @png)
      assert {:error, :invalid, _} = Space.add_image(space, id, "x.png")
      assert File.exists?(part)
    end

    test "an upload to a Space that is not there stays where it was" do
      id = upload()
      assert {:error, _, _} = Space.add_image("nothing", id, "x.png")
      assert HalC2.Attachments.path(%{"id" => id})
    end

    test "a deleted image cannot be placed or restored", %{space: space} do
      {:ok, image} = Space.add_image(space, upload(), "cat.png")
      page = page!(space, "Roadmap")
      {:ok, _} = Space.trash_image(space, image["id"])
      {:ok, _} = Space.delete_image(space, image["id"])
      refute ImageFile.existing(image["id"])

      assert {:error, :not_found, _} =
               Space.insert_block(space, page, %{
                 "kind" => "image",
                 "imageId" => image["id"]
               })

      assert {:error, :not_found, _} = Space.restore_image(space, image["id"])
    end

    test "an image block needs an image", %{space: space} do
      page = page!(space, "Roadmap")
      assert {:error, _, _} = Space.insert_block(space, page, %{"kind" => "image"})
    end

    test "other blocks gain no imageId", %{space: space} do
      page = page!(space, "Roadmap")

      {:ok, block} =
        Space.insert_block(space, page, %{"kind" => "paragraph", "imageId" => "x"})

      refute Map.has_key?(block, "imageId")
    end

    test "a generated image's name is the start of its prompt, on one line" do
      name = Images.name_from("a red\n fox / " <> String.duplicate("x", 100))
      assert String.length(name) <= 60
      refute name =~ "\n"
      refute name =~ "/"
    end

    test "each kind of file reads its own size" do
      assert {:ok, "image/gif", 2, 3} =
               ImageFile.sniff(<<"GIF87a", 2::little-16, 3::little-16, 0>>)

      assert {:ok, "image/jpeg", 5, 4} =
               ImageFile.sniff(
                 <<0xFF, 0xD8, 0xFF, 0xFF, 0xE0, 4::16, 0, 0, 0xFF, 0xC2, 17::16, 8, 4::16,
                   5::16>>
               )

      assert {:ok, "image/webp", 2, 3} =
               ImageFile.sniff(
                 <<"RIFF", 0::32, "WEBP", "VP8X", 0::32, 0::32, 1::little-24, 2::little-24>>
               )

      bits = Bitwise.bor(6, Bitwise.bsl(7, 14))

      assert {:ok, "image/webp", 7, 8} =
               ImageFile.sniff(<<"RIFF", 0::32, "WEBP", "VP8L", 0::32, 0x2F, bits::little-32>>)
    end

    test "a file whose headers lie or end early is refused" do
      for bytes <- [
            "",
            <<0xFF, 0xD8>>,
            <<0xFF, 0xD8, 0xFF, 0xE0, 200::16, 0>>,
            <<0xFF, 0xD8, 0xFF, 0xE0, 0::16>>,
            <<0xFF, 0xD8, 0xFF, 0xDA, 0::16>>,
            <<"GIF89a", 0::little-16, 3::little-16>>,
            <<"RIFF", 0::32, "WEBPXXXX">>,
            ~s(<svg xmlns="http://www.w3.org/2000/svg"/>)
          ] do
        assert ImageFile.sniff(bytes) == :error
      end
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
