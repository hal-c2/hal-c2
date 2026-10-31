defmodule HalC2.SpacePropTest do
  @moduledoc """
  A state machine over the pages, blocks and comments of one Space (`HalC2.Space`):
  pages made, moved, trashed, restored and deleted for good; blocks inserted, moved,
  ticked, edited and deleted; comments added, resolved and reopened; and the Space's streams
  restarting, which reads everything back from the event log.

  After each command the test reads the Space's stream back and checks it against
  the model:

  - each command is refused exactly when the model says, with the model's reason;
  - a page is never moved under itself or a page below it (`cycle`);
  - a page in the trash hides its subpages, nothing on a hidden page changes, and a
    restored page whose parent is hidden goes to the top of the Space;
  - deleting a page for good takes its subpages, their blocks and comments with it;
  - a page's blocks are in the order inserted and moved, with strictly ordered keys;
  - an edit of a block's text and tick together is refused whole, or changes both;
  - each command writes one event per entity it changes, and a refusal, a tick to
    the same value, or resolving a resolved comment (reopening an open one) writes none.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Space, StreamState, Streams}
  alias HalC2.Space.Blocks

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @pages ~w(p1 p2 p3 p4)
  @blocks ~w(b1 b2 b3 b4 b5)
  @comments ~w(c1 c2 c3)

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
        Process.put(:names, %{})
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # pages: name => %{parent, trashed}; order: page => its block names in order;
  # blocks: name => %{page, kind, checked, text}; comments: name => %{block, resolved}.
  def initial_state, do: %{pages: %{}, order: %{}, blocks: %{}, comments: %{}}

  def command(s) do
    pages = Map.keys(s.pages)
    blocks = Map.keys(s.blocks)
    comments = Map.keys(s.comments)

    frequency(
      [{3, {:call, __MODULE__, :create_page, [elements(@pages), parent(pages)]}}] ++
        if(pages == [],
          do: [],
          else: [
            {2, {:call, __MODULE__, :move_page, [elements(pages), parent(pages)]}},
            {2, {:call, __MODULE__, :trash_page, [elements(pages)]}},
            {3, {:call, __MODULE__, :restore_page, [in_trash(s, pages)]}},
            {1, {:call, __MODULE__, :delete_page, [in_trash(s, pages)]}},
            {4,
             {:call, __MODULE__, :insert_block,
              [elements(@blocks), elements(pages), kind(), boolean(), after_block(blocks)]}}
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
        [{1, {:call, __MODULE__, :restart, []}}]
    )
  end

  defp parent([]), do: nil
  defp parent(pages), do: frequency([{1, nil}, {3, elements(pages)}])
  # Mostly a page in the trash itself, sometimes one that is not.
  defp in_trash(s, pages) do
    case for {page, %{trashed: true}} <- s.pages, do: page do
      [] -> elements(pages)
      trashed -> frequency([{3, elements(trashed)}, {1, elements(pages)}])
    end
  end

  defp kind, do: elements(~w(paragraph checklist))
  defp after_block([]), do: oneof([:last, nil])
  defp after_block(blocks), do: oneof([:last, nil, elements(blocks)])

  def precondition(s, {:call, _, :create_page, [name, parent]}),
    do: not Map.has_key?(s.pages, name) and (parent == nil or Map.has_key?(s.pages, parent))

  def precondition(s, {:call, _, :move_page, [name, parent]}),
    do: Map.has_key?(s.pages, name) and (parent == nil or Map.has_key?(s.pages, parent))

  def precondition(s, {:call, _, :insert_block, [name, page, _, _, after_id]}),
    do:
      not Map.has_key?(s.blocks, name) and Map.has_key?(s.pages, page) and
        (after_id in [:last, nil] or Map.has_key?(s.blocks, after_id))

  def precondition(s, {:call, _, :move_block, [name, after_id]}),
    do:
      Map.has_key?(s.blocks, name) and
        (after_id in [:last, nil] or Map.has_key?(s.blocks, after_id))

  def precondition(s, {:call, _, :add_comment, [name, block]}),
    do: not Map.has_key?(s.comments, name) and Map.has_key?(s.blocks, block)

  def precondition(s, {:call, _, cmd, [name]})
      when cmd in [:trash_page, :restore_page, :delete_page],
      do: Map.has_key?(s.pages, name)

  def precondition(s, {:call, _, cmd, [name | _]})
      when cmd in [:set_checked, :edit_block, :delete_block],
      do: Map.has_key?(s.blocks, name)

  def precondition(s, {:call, _, cmd, [name]}) when cmd in [:resolve_comment, :reopen_comment],
    do: Map.has_key?(s.comments, name)

  def precondition(_s, {:call, _, :restart, []}), do: true

  def next_state(s, _result, {:call, _, cmd, args}), do: elem(step(s, cmd, args), 1)

  def postcondition(s, {:call, _, cmd, args}, {reply, events, snapshot, ordered}) do
    {expected, next, writes} = step(s, cmd, args)
    reply == expected and events in List.wrap(writes) and snapshot == snapshot(next) and ordered
  end

  # What a command replies, the model after it, and how many events it writes (a list
  # when either is right).
  defp step(s, :create_page, [name, parent]) do
    if parent == nil or live?(s, parent) do
      page = %{parent: parent, trashed: false}
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
        {:ok, put_in(s.pages[name], %{parent: parent, trashed: false}), 1}

      _ ->
        {:invalid, s, 0}
    end
  end

  defp step(s, :delete_page, [name]) do
    if s.pages[name].trashed do
      pages = [name | descendants(s, name)]
      blocks = for {block, %{page: page}} <- s.blocks, page in pages, do: block
      comments = for {comment, %{block: block}} <- s.comments, block in blocks, do: comment

      next = %{
        pages: Map.drop(s.pages, pages),
        order: Map.drop(s.order, pages),
        blocks: Map.drop(s.blocks, blocks),
        comments: Map.drop(s.comments, comments)
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
        block = %{page: page, kind: kind, checked: kind == "checklist" and checked, text: name}
        order = place(s.order[page], after_id, name)
        {:ok, %{s | blocks: Map.put(s.blocks, name, block), order: %{s.order | page => order}}, 1}
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

      {:ok, next, 1 + length(comments)}
    else
      {:trashed, s, 0}
    end
  end

  defp step(s, :add_comment, [name, block]) do
    if live?(s, s.blocks[block].page),
      do: {:ok, put_in(s.comments[name], %{block: block, resolved: false}), 1},
      else: {:trashed, s, 0}
  end

  defp step(s, cmd, [name]) when cmd in [:resolve_comment, :reopen_comment] do
    comment = s.comments[name]
    resolved = cmd == :resolve_comment

    cond do
      not live?(s, s.blocks[comment.block].page) -> {:trashed, s, 0}
      comment.resolved == resolved -> {:ok, s, 0}
      true -> {:ok, put_in(s.comments[name].resolved, resolved), 1}
    end
  end

  defp step(s, :restart, []), do: {:ok, s, 0}

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

  defp snapshot(s), do: Map.take(s, [:pages, :order, :blocks, :comments])

  # --- the system under test ------------------------------------------------------

  def create_page(name, parent),
    do: act(name, &Space.create_page(&1, "Page #{name}", id(parent)))

  def move_page(name, parent), do: act(&Space.move_page(&1, id(name), id(parent)))
  def trash_page(name), do: act(&Space.trash_page(&1, id(name)))
  def restore_page(name), do: act(&Space.restore_page(&1, id(name)))
  def delete_page(name), do: act(&Space.delete_page(&1, id(name)))

  def insert_block(name, page, kind, checked, after_id) do
    spec = %{"kind" => kind, "text" => name, "checked" => checked}
    act(name, &Space.insert_block(&1, id(page), spec, id(after_id)))
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

  def restart do
    act(fn _ ->
      HalC2.Prop.restart_service(HalC2.Streams)
      {:ok, nil}
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
    ids = for kind <- ~w(page block comment), id <- Map.keys(StreamState.get(state, kind)), do: id
    names = Map.filter(Process.get(:names), fn {_, id} -> id in ids end)
    Process.put(:names, names)
    name = Map.new(names, fn {name, id} -> {id, name} end)
    name = &Map.get(name, &1, &1)
    pages = StreamState.list(state, "page")

    order =
      Map.new(pages, fn page ->
        {name.(page["id"]), Blocks.of_page(state, page["id"])}
      end)

    snapshot = %{
      pages:
        Map.new(pages, fn page ->
          {name.(page["id"]),
           %{
             parent: page["parentPageId"] && name.(page["parentPageId"]),
             trashed: page["trashedAt"] != nil
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
             text: block["text"]
           }}
        end),
      comments:
        Map.new(StreamState.list(state, "comment"), fn comment ->
          {name.(comment["id"]),
           %{block: name.(comment["blockId"]), resolved: comment["resolvedAt"] != nil}}
        end)
    }

    ordered =
      Enum.all?(order, fn {_, blocks} ->
        keys = Enum.map(blocks, & &1["order"])
        keys == Enum.uniq(Enum.sort(keys))
      end)

    {snapshot, ordered}
  end

  defp id(name) when is_binary(name), do: Map.fetch!(Process.get(:names), name)
  defp id(other), do: other

  defp stream, do: Space.stream_id(Process.get(:space))
end
