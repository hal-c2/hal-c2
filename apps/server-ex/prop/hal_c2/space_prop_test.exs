defmodule HalC2.SpacePropTest do
  @moduledoc """
  A state machine over the pages, blocks and comments of one Space (`HalC2.Space`):
  pages made, moved, trashed, restored and deleted for good; blocks inserted, moved,
  ticked, edited and deleted; comments added, resolved and reopened; versions of a page
  remembered and restored; decks made blank or from a page, trashed, restored and deleted;
  slides added, edited, moved and deleted; images added, placed, trashed, restored and
  deleted for good; and the Space's streams restarting, which reads everything back from
  the event log.

  After each command the test reads the Space's stream back and checks it against
  the model:

  - each command is refused exactly when the model says, with the model's reason;
  - a page is never moved under itself or a page below it (`cycle`);
  - a page in the trash hides its subpages, nothing on a hidden page changes, and a
    restored page whose parent is hidden goes to the top of the Space;
  - deleting a page for good takes its subpages, their blocks and comments with it;
  - a page's blocks are in the order inserted and moved, with strictly ordered keys;
  - an edit of a block's text and tick together is refused whole, or changes both;
  - a chart is drawn in a new block or in place of a chart, and only there: its text
    cannot be edited, and asking again keeps its place and its comments;
  - each command writes one event per entity it changes, and a refusal, a tick to
    the same value, or resolving a resolved comment (reopening an open one) writes none;
  - a restore makes a live page look as it did, keeps every comment, moves no page, and
    writes nothing when the page already looks like it;
  - a page's update is not content: each run writes the page's one generated part,
    removing the update leaves it as the ordinary block it reads as, and a restore keeps
    the update and never writes a generated part: it leaves the page's as it is, takes
    none of a version's while the page updates itself, and brings a version's back as
    the ordinary block it reads as to a page that no longer does;
  - reading a page's history writes nothing, its versions go strictly back in time, and
    the newest of them reads as the page does now;
  - deleting a page for good is its deleter's edit of a page that linked to it, whoever
    wrote the link;
  - a deck made from a page has a slide per section of the page as it was, and no later
    change of the page reaches it; a deck in the trash takes no edits, and its slides go
    with it when it is deleted for good;
  - a published page's site comes down when the page is deleted or hidden in the trash
    and stays down when it is restored; its snapshot changes only on publishing, and it
    is behind exactly when publishing again would change it;
  - a site's link opens while it stands and never again after, and publishing again
    keeps a standing site's link;
  - an image has its file exactly as long as its entity exists, whatever shows it: a page
    or block going takes no image with it, and an image going leaves its blocks in place;
    a trashed image cannot be placed, and only a trashed image can be deleted.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Space, StreamState, Streams}
  alias HalC2.Space.{Blocks, Chart, Decks, ImageFile, Schedule}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @pages ~w(p1 p2 p3 p4)
  @blocks ~w(b1 b2 b3 b4 b5 b6 b7 b8)
  @comments ~w(c1 c2 c3)
  @saves ~w(s1 s2)
  @decks ~w(d1 d2 d3)
  @slides ~w(s1 s2 s3 s4)
  @images ~w(i1 i2 i3)

  property "a Space's pages, blocks and comments follow the model",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("space")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams
        ])

        {:ok, space} = Space.create("Prop")
        Process.put(:space, space["id"])
        File.mkdir_p!(HalC2.Attachments.dir())
        Process.put(:names, %{})
        Process.put(:saves, %{})
        Process.delete(:links)
        Process.delete(:tokens)
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  property "a link's removal is the deleter's edit, whoever wrote the link",
    numtests: HalC2.Prop.numtests(20) do
    forall {writer, deleter} <- {author(), author()} do
      home = HalC2.Prop.scratch_home("space")

      HalC2.Prop.start_services([
        {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
        HalC2.Streams
      ])

      {:ok, space} = Space.create("Prop")
      {:ok, %{"id" => holder}} = Space.create_page(space["id"], "Holder", nil)
      {:ok, %{"id" => linked}} = Space.create_page(space["id"], "Linked", nil)
      spec = %{"kind" => "subpage_link", "linkedPageId" => linked}
      {:ok, _} = Space.insert_block(space["id"], holder, spec, :last, writer)
      {:ok, _} = Space.trash_page(space["id"], linked)
      {:ok, _} = Space.delete_page(space["id"], linked, deleter)
      {:ok, %{versions: [newest | _]}} = Space.page_versions(space["id"], holder)
      HalC2.Prop.stop_services()
      newest.author == deleter
    end
  end

  defp author, do: oneof([Space.user(), Space.agent("thread-1"), Space.agent("thread-2")])

  # --- model ----------------------------------------------------------------------

  # pages: name => %{parent, trashed, update}, `update` whether it updates itself; order: page => its block names in order;
  # blocks: name => %{page, kind, checked, text, chart}; comments: name => %{page, block, resolved};
  # used: every block name so far, since a restore brings a deleted block back under its
  # own; saves: name => %{page, order, blocks}, the page as it stood when remembered;
  # decks: name => %{title, trashed}; deck_order: deck => its slide names in order;
  # slides: name => %{deck, title, body}. A slide a deck is made with is "<deck>.<n>".
  # sites: page => %{shown, behind}, `shown` being what `view/2` said when it published.
  # images: name => %{trashed}. ran: the blocks a page's update has written, which a
  # delete may first stamp as its deleter's (the model does not hold who wrote last).
  def initial_state do
    %{
      pages: %{},
      order: %{},
      blocks: %{},
      comments: %{},
      used: [],
      saves: %{},
      decks: %{},
      deck_order: %{},
      slides: %{},
      sites: %{},
      images: %{},
      ran: []
    }
  end

  def command(s) do
    pages = Map.keys(s.pages)
    blocks = Map.keys(s.blocks)
    comments = Map.keys(s.comments)
    decks = Map.keys(s.decks)
    slides = Map.keys(s.slides)
    images = Map.keys(s.images)

    frequency(
      [{3, {:call, __MODULE__, :create_page, [elements(@pages), parent(pages)]}}] ++
        if(pages == [],
          do: [],
          else: [{2, {:call, __MODULE__, :set_update, [elements(pages), boolean()]}}]
        ) ++
        case runs(s) do
          [] -> []
          runs -> [{6, {:call, __MODULE__, :run_update, [elements(runs), elements(~w(G H))]}}]
        end ++
        if(pages == [],
          do: [],
          else: [
            {2, {:call, __MODULE__, :move_page, [elements(pages), parent(pages)]}},
            {2, {:call, __MODULE__, :trash_page, [elements(pages)]}},
            {3, {:call, __MODULE__, :restore_page, [in_trash(s, pages)]}},
            {1, {:call, __MODULE__, :delete_page, [in_trash(s, pages)]}},
            {3, {:call, __MODULE__, :publish_page, [elements(pages)]}},
            {1, {:call, __MODULE__, :unpublish_page, [elements(pages)]}},
            {4,
             {:call, __MODULE__, :insert_block,
              [elements(@blocks), elements(pages), kind(), boolean(), after_block(blocks)]}},
            {2, {:call, __MODULE__, :save_version, [elements(@saves), elements(pages)]}},
            {1, {:call, __MODULE__, :read_history, [elements(pages)]}},
            {2,
             {:call, __MODULE__, :insert_chart,
              [elements(@blocks), elements(pages), title(), after_block(blocks)]}}
          ]
        ) ++
        if(blocks == [],
          do: [],
          else: [
            {3, {:call, __MODULE__, :move_block, [elements(blocks), after_block(blocks)]}},
            {2, {:call, __MODULE__, :set_checked, [elements(blocks), boolean()]}},
            {2,
             {:call, __MODULE__, :edit_block,
              [elements(blocks), oneof([nil, "x", "y"]), oneof([nil, boolean()])]}},
            {2,
             {:call, __MODULE__, :replace_chart, [elements(blocks), elements(pages), title()]}},
            {1, {:call, __MODULE__, :delete_block, [elements(blocks)]}},
            {2, {:call, __MODULE__, :add_comment, [elements(@comments), elements(blocks)]}}
          ]
        ) ++
        if(comments == [],
          do: [],
          else: [
            {2, {:call, __MODULE__, :resolve_comment, [elements(comments)]}},
            {2, {:call, __MODULE__, :reopen_comment, [elements(comments)]}}
          ]
        ) ++
        if(s.saves == %{},
          do: [],
          else: [{3, {:call, __MODULE__, :restore_version, [elements(Map.keys(s.saves))]}}]
        ) ++
        [{2, {:call, __MODULE__, :create_deck, [elements(@decks)]}}] ++
        if(pages == [],
          do: [],
          else: [
            {2, {:call, __MODULE__, :create_deck_from_page, [elements(@decks), elements(pages)]}}
          ]
        ) ++
        if(decks == [],
          do: [],
          else: [
            {2, {:call, __MODULE__, :trash_deck, [elements(decks)]}},
            {2, {:call, __MODULE__, :restore_deck, [elements(decks)]}},
            {1, {:call, __MODULE__, :delete_deck, [elements(decks)]}},
            {3,
             {:call, __MODULE__, :insert_slide,
              [elements(@slides), elements(decks), after_slide(slides)]}}
          ]
        ) ++
        if(slides == [],
          do: [],
          else: [
            {3, {:call, __MODULE__, :move_slide, [elements(slides), after_slide(slides)]}},
            {2,
             {:call, __MODULE__, :update_slide,
              [elements(slides), oneof([nil, "x", ""]), oneof([nil, "y", ""])]}},
            {1, {:call, __MODULE__, :delete_slide, [elements(slides)]}}
          ]
        ) ++
        [{2, {:call, __MODULE__, :add_image, [elements(@images)]}}] ++
        if(images == [],
          do: [],
          else:
            [
              {2, {:call, __MODULE__, :trash_image, [elements(images)]}},
              {2, {:call, __MODULE__, :restore_image, [elements(images)]}},
              {1, {:call, __MODULE__, :delete_image, [elements(images)]}}
            ] ++
              if(pages == [],
                do: [],
                else: [
                  {3,
                   {:call, __MODULE__, :place_image,
                    [elements(@blocks), elements(pages), elements(images)]}}
                ]
              )
        ) ++
        [{1, {:call, __MODULE__, :restart, []}}]
    )
  end

  # What a run of each page that updates itself writes: `{block, page}`, the block being
  # the page's generated part, or a name not used yet when it has none.
  defp runs(s) do
    fresh = Enum.find(Enum.map(1..(length(s.used) + 1), &"g#{&1}"), &(&1 not in s.used))
    for {page, %{update: true}} <- s.pages, do: {generated_of(s, page) || fresh, page}
  end

  defp generated_of(s, page),
    do: Enum.find(Map.get(s.order, page, []), &(s.blocks[&1].kind == "generated"))

  defp parent([]), do: nil
  defp parent(pages), do: frequency([{1, nil}, {3, elements(pages)}])
  # Mostly a page in the trash itself, sometimes one that is not.
  defp in_trash(s, pages) do
    case for {page, %{trashed: true}} <- s.pages, do: page do
      [] -> elements(pages)
      trashed -> frequency([{3, elements(trashed)}, {1, elements(pages)}])
    end
  end

  defp kind, do: elements(~w(paragraph checklist heading callout))
  defp title, do: elements(~w(T1 T2))
  defp after_block([]), do: oneof([:last, nil])
  defp after_block(blocks), do: oneof([:last, nil, elements(blocks)])
  defp after_slide([]), do: oneof([:last, nil])
  defp after_slide(slides), do: oneof([:last, nil, elements(slides)])

  def precondition(s, {:call, _, :create_page, [name, parent]}),
    do: not Map.has_key?(s.pages, name) and (parent == nil or Map.has_key?(s.pages, parent))

  # `HalC2.Space.Schedule.remove/2` releases what an update wrote, and only on a live page.
  def precondition(s, {:call, _, :set_update, [page, on]}),
    do: is_map_key(s.pages, page) and (on or generated_of(s, page) == nil or live?(s, page))

  def precondition(s, {:call, _, :run_update, [{name, page}, _]}),
    do: is_map_key(s.pages, page) and s.pages[page].update and {name, page} in runs(s)

  def precondition(s, {:call, _, :move_page, [name, parent]}),
    do: Map.has_key?(s.pages, name) and (parent == nil or Map.has_key?(s.pages, parent))

  def precondition(s, {:call, _, :insert_block, [name, page, _, _, after_id]}),
    do:
      name not in s.used and Map.has_key?(s.pages, page) and
        (after_id in [:last, nil] or Map.has_key?(s.blocks, after_id))

  def precondition(s, {:call, _, :insert_chart, [name, page, _, after_id]}),
    do:
      name not in s.used and is_map_key(s.pages, page) and
        (not is_binary(after_id) or is_map_key(s.blocks, after_id))

  def precondition(s, {:call, _, :replace_chart, [name, page, _]}),
    do: is_map_key(s.blocks, name) and is_map_key(s.pages, page)

  def precondition(s, {:call, _, :move_block, [name, after_id]}),
    do:
      Map.has_key?(s.blocks, name) and
        (after_id in [:last, nil] or Map.has_key?(s.blocks, after_id))

  def precondition(s, {:call, _, :add_comment, [name, block]}),
    do: not Map.has_key?(s.comments, name) and Map.has_key?(s.blocks, block)

  def precondition(s, {:call, _, cmd, [name]})
      when cmd in [:trash_page, :restore_page, :delete_page, :publish_page, :unpublish_page],
      do: Map.has_key?(s.pages, name)

  def precondition(s, {:call, _, cmd, [name | _]})
      when cmd in [:set_checked, :edit_block, :delete_block],
      do: Map.has_key?(s.blocks, name)

  def precondition(s, {:call, _, cmd, [name]}) when cmd in [:resolve_comment, :reopen_comment],
    do: Map.has_key?(s.comments, name)

  def precondition(s, {:call, _, cmd, [_, page]}) when cmd == :save_version,
    do: Map.has_key?(s.pages, page)

  def precondition(s, {:call, _, :read_history, [page]}), do: Map.has_key?(s.pages, page)
  def precondition(s, {:call, _, :restore_version, [save]}), do: Map.has_key?(s.saves, save)

  def precondition(s, {:call, _, :create_deck, [name]}), do: not Map.has_key?(s.decks, name)

  def precondition(s, {:call, _, :create_deck_from_page, [name, page]}),
    do: not Map.has_key?(s.decks, name) and Map.has_key?(s.pages, page)

  def precondition(s, {:call, _, cmd, [name]})
      when cmd in [:trash_deck, :restore_deck, :delete_deck],
      do: Map.has_key?(s.decks, name)

  def precondition(s, {:call, _, :insert_slide, [name, deck, after_id]}),
    do:
      not Map.has_key?(s.slides, name) and Map.has_key?(s.decks, deck) and
        (after_id in [:last, nil] or Map.has_key?(s.slides, after_id))

  def precondition(s, {:call, _, :move_slide, [name, after_id]}),
    do:
      Map.has_key?(s.slides, name) and
        (after_id in [:last, nil] or Map.has_key?(s.slides, after_id))

  def precondition(s, {:call, _, cmd, [name | _]}) when cmd in [:update_slide, :delete_slide],
    do: Map.has_key?(s.slides, name)

  def precondition(s, {:call, _, :add_image, [name]}), do: not Map.has_key?(s.images, name)

  def precondition(s, {:call, _, cmd, [name]})
      when cmd in [:trash_image, :restore_image, :delete_image],
      do: Map.has_key?(s.images, name)

  def precondition(s, {:call, _, :place_image, [name, page, image]}),
    do:
      name not in s.used and Map.has_key?(s.pages, page) and
        Map.has_key?(s.images, image)

  def precondition(_s, {:call, _, :restart, []}), do: true

  def next_state(s, _result, {:call, _, cmd, args}), do: elem(with_sites(s, cmd, args), 1)

  def postcondition(s, {:call, _, cmd, args}, {reply, events, snapshot, ordered}) do
    {expected, next, writes} = with_sites(s, cmd, args)
    reply == expected and events in writes and snapshot == snapshot(next) and ordered
  end

  # A command as `step/3` says, then its sites following what it did to their pages,
  # each change one more event.
  defp with_sites(s, cmd, args) do
    {reply, next, writes} = step(s, cmd, args)

    {next, followed} =
      Enum.reduce(next.sites, {next, 0}, fn {page, site}, {s, n} ->
        cond do
          not (Map.has_key?(s.pages, page) and live?(s, page)) ->
            {%{s | sites: Map.delete(s.sites, page)}, n + 1}

          view(s, page) != site.shown != site.behind ->
            {put_in(s.sites[page].behind, not site.behind), n + 1}

          true ->
            {s, n}
        end
      end)

    {reply, next, Enum.map(List.wrap(writes), &(&1 + followed))}
  end

  # What a site of `page` shows of its blocks.
  defp view(s, page) do
    for name <- Map.get(s.order, page, []) do
      block = s.blocks[name]
      kind = if block.kind == "generated", do: "paragraph", else: block.kind
      {kind, block.text, if(block.kind == "checklist", do: block.checked == true)}
    end
  end

  # What a command replies, the model after it, and how many events it writes (a list
  # when either is right).
  defp step(s, :create_page, [name, parent]) do
    if parent == nil or live?(s, parent) do
      page = %{parent: parent, trashed: false, update: false}
      {:ok, %{s | pages: Map.put(s.pages, name, page), order: Map.put(s.order, name, [])}, 1}
    else
      {:trashed, s, 0}
    end
  end

  defp step(s, :move_page, [name, parent]) do
    cond do
      not live?(s, name) -> {:trashed, s, 0}
      parent != nil and not live?(s, parent) -> {:trashed, s, 0}
      parent == name or parent in descendants(s, name) -> {:cycle, s, 0}
      s.pages[name].parent == parent -> {:ok, s, 0}
      true -> {:ok, put_in(s.pages[name].parent, parent), 1}
    end
  end

  defp step(s, :trash_page, [name]) do
    if live?(s, name),
      do: {:ok, put_in(s.pages[name].trashed, true), 1},
      else: {:trashed, s, 0}
  end

  defp step(s, :restore_page, [name]) do
    case s.pages[name] do
      %{trashed: true, parent: parent} ->
        parent = if parent != nil and live?(s, parent), do: parent

        {:ok,
         %{s | pages: %{s.pages | name => %{s.pages[name] | parent: parent, trashed: false}}}, 1}

      _ ->
        {:invalid, s, 0}
    end
  end

  defp step(s, :delete_page, [name]) do
    if s.pages[name].trashed do
      pages = [name | descendants(s, name)]
      blocks = for {block, %{page: page}} <- s.blocks, page in pages, do: block
      comments = for {comment, %{page: page}} <- s.comments, page in pages, do: comment
      saves = for {save, %{page: page}} <- s.saves, page in pages, do: save

      next = %{
        s
        | pages: Map.drop(s.pages, pages),
          order: Map.drop(s.order, pages),
          blocks: Map.drop(s.blocks, blocks),
          comments: Map.drop(s.comments, comments),
          saves: Map.drop(s.saves, saves)
      }

      {:ok, next, length(pages) + length(blocks) + length(comments)}
    else
      {:invalid, s, 0}
    end
  end

  defp step(s, :insert_block, [name, page, kind, checked, after_id]) do
    cond do
      not live?(s, page) ->
        {:trashed, s, 0}

      is_binary(after_id) and s.blocks[after_id].page != page ->
        {:not_found, s, 0}

      true ->
        block = %{
          page: page,
          kind: kind,
          checked: kind == "checklist" and checked,
          text: name,
          chart: nil
        }

        order = place(s.order[page], after_id, name)

        {:ok,
         %{
           s
           | blocks: Map.put(s.blocks, name, block),
             order: %{s.order | page => order},
             used: [name | s.used]
         }, 1}
    end
  end

  defp step(s, :insert_chart, [name, page, title, after_id]) do
    cond do
      not live?(s, page) ->
        {:trashed, s, 0}

      is_binary(after_id) and s.blocks[after_id].page != page ->
        {:not_found, s, 0}

      true ->
        block = %{page: page, kind: "chart", checked: false, text: summary(title), chart: title}
        order = place(s.order[page], after_id, name)

        {:ok,
         %{
           s
           | blocks: Map.put(s.blocks, name, block),
             order: %{s.order | page => order},
             used: [name | s.used]
         }, 1}
    end
  end

  defp step(s, :replace_chart, [name, page, title]) do
    block = s.blocks[name]

    cond do
      block.kind != "chart" or block.page != page -> {:not_found, s, 0}
      not live?(s, page) -> {:trashed, s, 0}
      block.chart == title -> {:ok, s, 0}
      true -> {:ok, put_in(s.blocks[name], %{block | chart: title, text: summary(title)}), 1}
    end
  end

  defp step(s, :move_block, [name, after_id]) do
    page = s.blocks[name].page

    cond do
      not live?(s, page) ->
        {:trashed, s, 0}

      after_id == name ->
        {:invalid, s, 0}

      is_binary(after_id) and s.blocks[after_id].page != page ->
        {:not_found, s, 0}

      true ->
        order = place(List.delete(s.order[page], name), after_id, name)
        # A block moved to where it is gets a new key between the same neighbours.
        writes = if order == s.order[page], do: [0, 1], else: 1
        {:ok, put_in(s.order[page], order), writes}
    end
  end

  defp step(s, :set_checked, [name, checked]) do
    block = s.blocks[name]

    cond do
      not live?(s, block.page) -> {:trashed, s, 0}
      block.kind != "checklist" -> {:invalid, s, 0}
      block.checked == checked -> {:ok, s, 0}
      true -> {:ok, put_in(s.blocks[name].checked, checked), 1}
    end
  end

  defp step(s, :edit_block, [name, text, checked]) do
    block = s.blocks[name]

    next = %{
      block
      | text: text || block.text,
        checked: if(checked == nil, do: block.checked, else: checked)
    }

    cond do
      not live?(s, block.page) -> {:trashed, s, 0}
      text != nil and block.kind in ~w(chart generated) -> {:invalid, s, 0}
      checked != nil and block.kind != "checklist" -> {:invalid, s, 0}
      next == block -> {:ok, s, 0}
      true -> {:ok, put_in(s.blocks[name], next), 1}
    end
  end

  defp step(s, :delete_block, [name]) do
    page = s.blocks[name].page

    if live?(s, page) do
      comments = for {comment, %{block: ^name}} <- s.comments, do: comment

      next = %{
        s
        | blocks: Map.delete(s.blocks, name),
          order: %{s.order | page => List.delete(s.order[page], name)},
          comments: Map.drop(s.comments, comments)
      }

      writes = if name in s.ran, do: [1, 2], else: [1]
      {:ok, next, Enum.map(writes, &(&1 + length(comments)))}
    else
      {:trashed, s, 0}
    end
  end

  defp step(s, :add_comment, [name, block]) do
    page = s.blocks[block].page

    if live?(s, page),
      do: {:ok, put_in(s.comments[name], %{page: page, block: block, resolved: false}), 1},
      else: {:trashed, s, 0}
  end

  defp step(s, cmd, [name]) when cmd in [:resolve_comment, :reopen_comment] do
    comment = s.comments[name]
    resolved = cmd == :resolve_comment

    cond do
      not live?(s, comment.page) -> {:trashed, s, 0}
      comment.resolved == resolved -> {:ok, s, 0}
      true -> {:ok, put_in(s.comments[name].resolved, resolved), 1}
    end
  end

  defp step(s, :save_version, [save, page]) do
    blocks = Map.new(s.order[page], &{&1, s.blocks[&1]})
    {:ok, put_in(s.saves[save], %{page: page, order: s.order[page], blocks: blocks}), 0}
  end

  defp step(s, :read_history, [_page]), do: {:ok, s, 0}

  # The events it takes are two or three on the page and one a block that changes, and
  # any block can differ by its order key alone, which the model does not hold. The
  # page's generated part stays as it is, and is then moved last (`restore_version/1`),
  # which may be one more.
  defp step(s, :restore_version, [save]) do
    %{page: page, order: order, blocks: blocks} = s.saves[save]
    kept = generated_of(s, page)

    {order, blocks} =
      if s.pages[page].update do
        order = Enum.reject(order, &(blocks[&1].kind == "generated"))
        {order, Map.take(blocks, order)}
      else
        {order, Map.new(blocks, &released/1)}
      end

    if live?(s, page) do
      now = s.order[page] -- List.wrap(kept)
      gone = now -- order
      changed = for name <- order, s.blocks[name] != blocks[name], do: name
      moved = if now -- gone == order -- (order -- now), do: 0, else: 1
      least = length(gone) + length(changed)
      most = length(Enum.uniq(now ++ order))

      next = %{
        s
        | blocks: s.blocks |> Map.drop(gone) |> Map.merge(blocks),
          order: %{s.order | page => order ++ List.wrap(kept)}
      }

      writes =
        if least + moved == 0,
          do: [0 | Enum.to_list(3..(3 + most))],
          else: Enum.to_list((2 + least + moved)..(3 + most))

      writes = if kept, do: Enum.uniq(Enum.flat_map(writes, &[&1, &1 + 1])), else: writes
      {:ok, next, writes}
    else
      {:trashed, s, 0}
    end
  end

  # Removing it releases the generated part in the same step: one more event.
  defp step(s, :set_update, [page, on]) do
    cond do
      s.pages[page].update == on ->
        {:ok, s, 0}

      on or generated_of(s, page) == nil ->
        {:ok, put_in(s.pages[page].update, on), 1}

      true ->
        {name, block} = released({generated_of(s, page), s.blocks[generated_of(s, page)]})
        {:ok, %{put_in(s.pages[page].update, false) | blocks: %{s.blocks | name => block}}, 2}
    end
  end

  # The page's `writtenAt`, and its generated part: a new one, or the one it has, which
  # a run within the same millisecond as the last with the same words leaves as it is.
  defp step(s, :run_update, [{name, page}, text]) do
    cond do
      not live?(s, page) ->
        {:trashed, s, 0}

      Map.has_key?(s.blocks, name) ->
        {:ok, %{put_in(s.blocks[name].text, text) | ran: [name | s.ran]}, [0, 1, 2]}

      true ->
        block = %{page: page, kind: "generated", checked: false, text: text, chart: nil}

        {:ok,
         %{
           s
           | blocks: Map.put(s.blocks, name, block),
             order: %{s.order | page => s.order[page] ++ [name]},
             used: [name | s.used],
             ran: [name | s.ran]
         }, [1, 2]}
    end
  end

  defp step(s, :create_deck, [name]), do: made(s, name, name, [{"", ""}])

  defp step(s, :create_deck_from_page, [name, page]) do
    if live?(s, page),
      do: made(s, name, "Page #{page}", sections(s, page)),
      else: {:trashed, s, 0}
  end

  defp step(s, :trash_deck, [name]) do
    if s.decks[name].trashed,
      do: {:trashed, s, 0},
      else: {:ok, put_in(s.decks[name].trashed, true), 1}
  end

  defp step(s, :restore_deck, [name]) do
    if s.decks[name].trashed,
      do: {:ok, put_in(s.decks[name].trashed, false), 1},
      else: {:invalid, s, 0}
  end

  defp step(s, :delete_deck, [name]) do
    if s.decks[name].trashed do
      slides = s.deck_order[name]

      next = %{
        s
        | decks: Map.delete(s.decks, name),
          deck_order: Map.delete(s.deck_order, name),
          slides: Map.drop(s.slides, slides)
      }

      {:ok, next, 1 + length(slides)}
    else
      {:invalid, s, 0}
    end
  end

  defp step(s, :insert_slide, [name, deck, after_id]) do
    cond do
      s.decks[deck].trashed ->
        {:trashed, s, 0}

      is_binary(after_id) and s.slides[after_id].deck != deck ->
        {:not_found, s, 0}

      true ->
        order = place(s.deck_order[deck], after_id, name)
        slide = %{deck: deck, title: name, body: ""}

        {:ok,
         %{
           s
           | slides: Map.put(s.slides, name, slide),
             deck_order: %{s.deck_order | deck => order}
         }, 1}
    end
  end

  defp step(s, :move_slide, [name, after_id]) do
    deck = s.slides[name].deck

    cond do
      s.decks[deck].trashed ->
        {:trashed, s, 0}

      after_id == name ->
        {:invalid, s, 0}

      is_binary(after_id) and s.slides[after_id].deck != deck ->
        {:not_found, s, 0}

      true ->
        order = place(List.delete(s.deck_order[deck], name), after_id, name)
        # A slide moved to where it is gets a new key between the same neighbours.
        writes = if order == s.deck_order[deck], do: [0, 1], else: 1
        {:ok, put_in(s.deck_order[deck], order), writes}
    end
  end

  defp step(s, :update_slide, [name, title, body]) do
    slide = s.slides[name]
    next = %{slide | title: title || slide.title, body: body || slide.body}

    cond do
      s.decks[slide.deck].trashed -> {:trashed, s, 0}
      next == slide -> {:ok, s, 0}
      true -> {:ok, put_in(s.slides[name], next), 1}
    end
  end

  defp step(s, :delete_slide, [name]) do
    deck = s.slides[name].deck

    if s.decks[deck].trashed do
      {:trashed, s, 0}
    else
      next = %{
        s
        | slides: Map.delete(s.slides, name),
          deck_order: %{s.deck_order | deck => List.delete(s.deck_order[deck], name)}
      }

      {:ok, next, 1}
    end
  end

  defp step(s, :publish_page, [name]) do
    cond do
      not live?(s, name) ->
        {:trashed, s, 0}

      # In the same instant, with nothing changed, publishing again has nothing to write.
      Map.has_key?(s.sites, name) and view(s, name) == s.sites[name].shown ->
        {:ok, put_in(s.sites[name].behind, false), [0, 1]}

      true ->
        {:ok, put_in(s.sites[name], %{shown: view(s, name), behind: false}), 1}
    end
  end

  defp step(s, :unpublish_page, [name]) do
    if Map.has_key?(s.sites, name),
      do: {:ok, %{s | sites: Map.delete(s.sites, name)}, 1},
      else: {:ok, s, 0}
  end

  defp step(s, :add_image, [name]),
    do: {:ok, put_in(s.images[name], %{trashed: false}), 1}

  defp step(s, :trash_image, [name]) do
    if s.images[name].trashed,
      do: {:trashed, s, 0},
      else: {:ok, put_in(s.images[name].trashed, true), 1}
  end

  defp step(s, :restore_image, [name]) do
    if s.images[name].trashed,
      do: {:ok, put_in(s.images[name].trashed, false), 1},
      else: {:invalid, s, 0}
  end

  defp step(s, :delete_image, [name]) do
    if s.images[name].trashed,
      do: {:ok, %{s | images: Map.delete(s.images, name)}, 1},
      else: {:invalid, s, 0}
  end

  defp step(s, :place_image, [name, page, image]) do
    cond do
      not live?(s, page) ->
        {:trashed, s, 0}

      s.images[image].trashed ->
        {:trashed, s, 0}

      true ->
        block = %{page: page, kind: "image", checked: false, text: name, chart: nil}
        order = s.order[page] ++ [name]

        {:ok,
         %{
           s
           | blocks: Map.put(s.blocks, name, block),
             order: %{s.order | page => order},
             used: [name | s.used]
         }, 1}
    end
  end

  defp step(s, :restart, []), do: {:ok, s, 0}

  defp summary(title), do: Chart.summary(chart(title))

  # A run's words, one paragraph here, as the block they read as with no update.
  defp released({name, %{kind: "generated"} = block}),
    do: {name, %{block | kind: "paragraph", checked: false}}

  defp released(entry), do: entry

  # A deck `name` with a slide for each `{title, body}`, named "<deck>.<n>".
  defp made(s, name, title, specs) do
    named = Enum.with_index(specs, fn spec, n -> {"#{name}.#{n}", spec} end)

    slides =
      Map.new(named, fn {slide, {title, body}} ->
        {slide, %{deck: name, title: title, body: body}}
      end)

    next = %{
      s
      | decks: Map.put(s.decks, name, %{title: title, trashed: false}),
        deck_order: Map.put(s.deck_order, name, Enum.map(named, &elem(&1, 0))),
        slides: Map.merge(s.slides, slides)
    }

    {:ok, next, 1 + length(specs)}
  end

  # The sections of a page: a slide per heading, what is before the first under its title.
  defp sections(s, page) do
    blocks = Enum.map(s.order[page], &s.blocks[&1])
    {lead, rest} = Enum.split_while(blocks, &(&1.kind != "heading"))
    title = "Page #{page}"
    start = if lead != [] or rest == [], do: [{title, lines(lead)}], else: []

    start ++
      (rest
       |> Enum.reduce([], fn
         %{kind: "heading", text: text}, acc -> [{text, []} | acc]
         block, [{text, under} | acc] -> [{text, under ++ [block]} | acc]
       end)
       |> Enum.reverse()
       |> Enum.map(fn {text, under} -> {text, lines(under)} end))
  end

  defp lines(blocks), do: Enum.map_join(blocks, "\n", &line/1)

  defp line(%{kind: "checklist", checked: true, text: text}), do: "- [x] " <> text
  defp line(%{kind: "checklist", text: text}), do: "- [ ] " <> text
  defp line(%{kind: "callout", text: text}), do: "> " <> text
  defp line(%{kind: "image", text: text}), do: "[image: " <> text <> "]"
  defp line(%{text: text}), do: text

  defp live?(s, name) do
    page = s.pages[name]
    not page.trashed and (page.parent == nil or live?(s, page.parent))
  end

  defp descendants(s, name) do
    children = for {child, %{parent: ^name}} <- s.pages, do: child
    children ++ Enum.flat_map(children, &descendants(s, &1))
  end

  defp place(order, :last, name), do: order ++ [name]
  defp place(order, nil, name), do: [name | order]

  defp place(order, after_id, name) do
    {before, [^after_id | rest]} = Enum.split_while(order, &(&1 != after_id))
    before ++ [after_id, name | rest]
  end

  defp snapshot(s) do
    Map.take(s, [
      :pages,
      :order,
      :blocks,
      :comments,
      :decks,
      :deck_order,
      :slides,
      :sites,
      :images
    ])
  end

  # --- the system under test ------------------------------------------------------

  def create_page(name, parent),
    do: act(name, &Space.create_page(&1, "Page #{name}", id(parent)))

  def move_page(name, parent), do: act(&Space.move_page(&1, id(name), id(parent)))

  # The page's view of an update as the scheduler shows it; the scheduler itself is not
  # running, so ending one is what `HalC2.Space.Schedule.remove/2` writes to the page.
  def set_update(name, true) do
    view = %{
      "instruction" => "Summarise",
      "cadence" => %{"type" => "interval", "everyMs" => 3_600_000},
      "enabled" => true
    }

    act(fn space ->
      :ok = Schedule.show(%{"spaceId" => space, "pageId" => id(name)}, view)
      {:ok, nil}
    end)
  end

  def set_update(name, false) do
    page_id = id(name)

    act(fn space ->
      Space.transact(space, fn state ->
        page = Space.Pages.get(state, page_id)

        if page["schedule"] == nil do
          {[], {:ok, nil}}
        else
          specs =
            case generated(state, page_id) do
              nil -> []
              block -> Space.written(state, block["text"])
            end

          released = Blocks.release_generated(state, page_id, specs, %{"type" => "schedule"})

          {[{"page", page_id, %{"s" => %{"schedule" => nil, "writtenAt" => nil}}} | released],
           {:ok, nil}}
        end
      end)
    end)
  end

  def run_update({name, page}, text), do: act(name, &Schedule.write(&1, id(page), text))
  def trash_page(name), do: act(&Space.trash_page(&1, id(name)))
  def restore_page(name), do: act(&Space.restore_page(&1, id(name)))
  def delete_page(name), do: act(&Space.delete_page(&1, id(name)))

  def publish_page(name),
    do: act(&Space.publish_page(&1, id(name), %{"baseUrl" => "http://mc.test:1"}))

  def unpublish_page(name), do: act(&Space.unpublish_page(&1, id(name)))

  def insert_block(name, page, kind, checked, after_id) do
    spec = %{"kind" => kind, "text" => name, "checked" => checked}
    act(name, &Space.insert_block(&1, id(page), spec, id(after_id)))
  end

  def insert_chart(name, page, title, after_id),
    do: act(name, &Space.put_chart(&1, id(page), chart(title), nil, id(after_id)))

  def replace_chart(name, page, title),
    do: act(&Space.put_chart(&1, id(page), chart(title), id(name)))

  defp chart(title) do
    %{
      "type" => "bar",
      "title" => title,
      "request" => "turns",
      "source" => "Numbers from this page",
      "labels" => ["a"],
      "series" => [%{"name" => "s", "values" => [1]}]
    }
  end

  def move_block(name, after_id), do: act(&Space.move_block(&1, id(name), id(after_id)))
  def set_checked(name, checked), do: act(&Space.set_checked(&1, id(name), checked))

  def edit_block(name, text, checked),
    do: act(&Space.edit_block(&1, id(name), text, checked))

  def delete_block(name), do: act(&Space.delete_block(&1, id(name)))

  def add_comment(name, block) do
    page = Streams.get(stream(), "block", id(block))["pageId"]
    act(name, &Space.add_comment(&1, page, id(block), "Comment #{name}"))
  end

  def resolve_comment(name), do: act(&Space.resolve_comment(&1, id(name)))
  def reopen_comment(name), do: act(&Space.reopen_comment(&1, id(name)))

  # Any point in the log is a version, so this remembers the next one to be asked for.
  def save_version(save, page) do
    saved = %{version: Streams.sequence(stream()), page: id(page)}
    Process.put(:saves, Map.put(Process.get(:saves), save, saved))
    act(fn _ -> {:ok, nil} end)
  end

  # A restore that writes the page's generated part is a failure. The model holds no
  # order keys, so the part is then moved last for it to know where it is.
  def restore_version(save) do
    %{version: version, page: page} = Map.fetch!(Process.get(:saves), save)

    act(fn space ->
      kept = generated(Streams.state(stream()), page)
      reply = Space.restore_page_version(space, page, version)

      cond do
        kept == nil or elem(reply, 0) != :ok ->
          reply

        generated(Streams.state(stream()), page) != kept ->
          {:error, :generated_written, nil}

        true ->
          {:ok, _} = Space.move_block(space, kept["id"], :last)
          reply
      end
    end)
  end

  defp generated(state, page_id),
    do: Enum.find(Blocks.of_page(state, page_id), &(&1["kind"] == "generated"))

  # Replies :ok when the versions go back in time and the newest reads as the page does.
  def read_history(page) do
    act(fn space ->
      {:ok, %{versions: versions}} = Space.page_versions(space, id(page))
      seqs = Enum.map(versions, & &1.version)
      {:ok, newest} = Space.page_version(space, id(page), hd(seqs))
      state = Streams.state(stream())
      content = &Map.take(&1, ~w(id kind text checked linkedPageId imageId chart order))

      cond do
        seqs != seqs |> Enum.uniq() |> Enum.sort(:desc) ->
          {:error, :versions_out_of_order, nil}

        Enum.map(newest.blocks, content) !=
            Enum.map(Blocks.of_page(state, id(page)), content) ->
          {:error, :newest_is_not_the_page, nil}

        true ->
          {:ok, nil}
      end
    end)
  end

  def create_deck(name), do: act_deck(name, &Space.create_deck(&1, name))

  def create_deck_from_page(name, page),
    do: act_deck(name, &Space.create_deck_from_page(&1, id(page)))

  def trash_deck(name), do: act(&Space.trash_deck(&1, id(name)))
  def restore_deck(name), do: act(&Space.restore_deck(&1, id(name)))
  def delete_deck(name), do: act(&Space.delete_deck(&1, id(name)))

  def insert_slide(name, deck, after_id),
    do: act(name, &Space.insert_slide(&1, id(deck), %{"title" => name}, id(after_id)))

  def move_slide(name, after_id), do: act(&Space.move_slide(&1, id(name), id(after_id)))

  def update_slide(name, title, body) do
    fields = %{"title" => title, "body" => body} |> Map.reject(fn {_, text} -> text == nil end)
    act(&Space.update_slide(&1, id(name), fields))
  end

  def delete_slide(name), do: act(&Space.delete_slide(&1, id(name)))

  def add_image(name) do
    upload = "pending-#{HalC2.Environment.uuid4()}"
    file = Path.join(HalC2.Attachments.dir(), upload <> ".png")

    File.write!(
      file,
      <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 2::32, 2::32, 8, 6, 0, 0, 0>>
    )

    act(name, &Space.add_image(&1, upload, "Image #{name}"))
  end

  def trash_image(name), do: act(&Space.trash_image(&1, id(name)))
  def restore_image(name), do: act(&Space.restore_image(&1, id(name)))

  def delete_image(name) do
    act(fn space ->
      with {:ok, _} = deleted <- Space.delete_image(space, id(name)), do: deleted
    end)
  end

  def place_image(name, page, image) do
    spec = %{"kind" => "image", "text" => name, "imageId" => id(image)}
    act(name, &Space.insert_block(&1, id(page), spec))
  end

  def restart do
    act(fn _ ->
      HalC2.Prop.restart_service(HalC2.Streams)
      {:ok, nil}
    end)
  end

  # Names a new deck and the slides it was made with before reading the Space back.
  defp act_deck(name, fun) do
    act(fn space ->
      with {:ok, %{"id" => id}} = reply <- fun.(space) do
        slides = Decks.slides(Streams.state(stream()), id)

        made =
          slides |> Enum.with_index(fn slide, n -> {"#{name}.#{n}", slide["id"]} end) |> Map.new()

        Process.put(:names, Process.get(:names) |> Map.merge(made) |> Map.put(name, id))
        reply
      end
    end)
  end

  # Runs one command and reads the Space back: its reply, the events it wrote, the
  # Space in the model's names, and whether every page's order keys strictly ascend.
  # A command that makes something under `name` names its id.
  defp act(name \\ nil, fun) do
    before = Streams.sequence(stream())
    reply = fun.(Process.get(:space))

    with true <- name != nil,
         {:ok, %{"id" => id}} <- reply,
         do: Process.put(:names, Map.put(Process.get(:names), name, id))

    events =
      HalC2.Store.reduce_stream(HalC2.Store.path(), stream(), before, 0, fn _, n -> n + 1 end)

    {snapshot, ordered} = read_back()
    {elem(reply, 0) |> reason(reply), events, snapshot, ordered}
  end

  defp reason(:ok, _), do: :ok
  defp reason(:error, {:error, reason, _}), do: reason

  defp read_back do
    state = Streams.state(stream())
    # Named things that are gone stay named: a restore can bring a block back.
    name = Map.new(Process.get(:names), fn {name, id} -> {id, name} end)
    name = &Map.get(name, &1, &1)
    pages = StreamState.list(state, "page")
    sites = StreamState.list(state, "site")

    order =
      Map.new(pages, fn page ->
        {name.(page["id"]), Blocks.of_page(state, page["id"])}
      end)

    decks = StreamState.list(state, "deck")
    deck_order = Map.new(decks, &{name.(&1["id"]), Decks.slides(state, &1["id"])})

    snapshot = %{
      pages:
        Map.new(pages, fn page ->
          {name.(page["id"]),
           %{
             parent: page["parentPageId"] && name.(page["parentPageId"]),
             trashed: page["trashedAt"] != nil,
             update: page["schedule"] != nil
           }}
        end),
      order: Map.new(order, fn {page, blocks} -> {page, Enum.map(blocks, &name.(&1["id"]))} end),
      blocks:
        Map.new(StreamState.list(state, "block"), fn block ->
          {name.(block["id"]),
           %{
             page: name.(block["pageId"]),
             kind: block["kind"],
             checked: block["checked"],
             text: block["text"],
             chart: block["chart"]["title"]
           }}
        end),
      comments:
        Map.new(StreamState.list(state, "comment"), fn comment ->
          {name.(comment["id"]),
           %{
             page: name.(comment["pageId"]),
             block: name.(comment["blockId"]),
             resolved: comment["resolvedAt"] != nil
           }}
        end),
      decks:
        Map.new(decks, fn deck ->
          {name.(deck["id"]), %{title: deck["title"], trashed: deck["trashedAt"] != nil}}
        end),
      deck_order:
        Map.new(deck_order, fn {deck, slides} -> {deck, Enum.map(slides, &name.(&1["id"]))} end),
      slides:
        Map.new(StreamState.list(state, "slide"), fn slide ->
          {name.(slide["id"]),
           %{deck: name.(slide["deckId"]), title: slide["title"], body: slide["body"]}}
        end),
      sites:
        Map.new(sites, fn site ->
          {name.(site["pageId"]),
           %{
             behind: site["behind"],
             shown: Enum.map(site["snapshot"]["blocks"], &{&1["kind"], &1["text"], &1["checked"]})
           }}
        end),
      images:
        Map.new(StreamState.list(state, "image"), fn image ->
          {name.(image["id"]), %{trashed: image["trashedAt"] != nil}}
        end)
    }

    ordered =
      Enum.all?(Map.values(order) ++ Map.values(deck_order), fn entities ->
        keys = Enum.map(entities, & &1["order"])
        keys == Enum.uniq(Enum.sort(keys))
      end)

    # Every image has its file and no file outlives its image.
    files =
      Path.wildcard(Path.join(HalC2.Attachments.dir(), "space_image_*")) |> Enum.sort()

    kept =
      StreamState.get(state, "image") |> Map.keys() |> Enum.map(&ImageFile.path/1) |> Enum.sort()

    {snapshot,
     ordered and files == kept and links_hold?(Map.new(sites, &{&1["pageId"], &1["id"]}))}
  end

  # Every standing site opens at the link it has had since it was published, and a link
  # that came down stays down, whatever came after.
  defp links_hold?(links) do
    space = Process.get(:space)
    standing = Map.values(links)
    gone = MapSet.difference(Process.get(:tokens, MapSet.new()), MapSet.new(standing))
    earlier = Process.get(:links, %{})
    Process.put(:links, links)
    Process.put(:tokens, MapSet.union(gone, MapSet.new(standing)))

    Enum.all?(links, fn {page, token} -> Map.get(earlier, page, token) == token end) and
      Enum.all?(standing, &Space.site(space, &1)) and
      not Enum.any?(gone, &Space.site(space, &1))
  end

  defp id(name) when is_binary(name), do: Map.fetch!(Process.get(:names), name)
  defp id(other), do: other

  defp stream, do: Space.stream_id(Process.get(:space))
end
