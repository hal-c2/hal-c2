defmodule HalC2.Space.History do
  @moduledoc """
  A page's versions, read from its Space's event log (`features/space/page-history.feature`).
  The log is the only record: a read folds the Space's `page` and `block` events off
  the writer, on its own connection, so it costs a scan of the Space's edits and
  nothing while nobody asks.

  A version is a run of content edits (the title, a block's kind, text, tick, link,
  image, chart or place) by one author with at most `@gap` between any two of them. It is named by the
  `seq` of its last edit: any `seq` reads the page as it stood then, so a name stays
  good when its run later grows. Moves and the trash are not edits, so they make no
  version and a restore leaves them alone.

  An author is what the edit's block says (`updatedBy`), which is why deleting a block
  someone else last wrote first stamps it (`HalC2.Space.Blocks.delete/3`), as does
  deleting the page a link leads to (`HalC2.Space.Pages.delete/3`). A title is
  the user's, or the source thread's when the page is made from one. There is no agent
  rename, so that holds.

  A restore is the edits that make the page look like the version again, between two
  writes of the page's `restoring` field in one commit, which is how the fold tells
  them from what came before and after. The field is gone again by the end of the
  commit. It keeps blocks' ids, so a block that comes back has the comments it left
  with: a restore that takes a block away leaves its comments on the page. Comments
  themselves are not versioned, and those a user deleted with a block stay deleted.
  Neither are images: a version's image block shows the image as it is now, and comes
  back saying so when the image is in the trash or deleted for good.

  A page's update is not content either (`HalC2.Space.Schedule`): a restore keeps its
  instruction and cadence, and a run's write is an edit by the update. A restore never
  writes the generated part, which is the update's: it leaves the page's as it is, and
  brings a version's back as ordinary blocks only to a page that no longer updates itself.
  """

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, Store}
  alias HalC2.Space
  alias HalC2.Space.{Order, Pages}

  @gap :timer.minutes(5)
  @content ~w(kind text checked linkedPageId imageId level gap chart order)
  @default_limit 30
  @max_limit 100

  @doc """
  A stretch of the page's versions, newest first, `before` the version given (or from
  the newest), with the version to ask `before` next or nil at the oldest.
  """
  def versions(space_id, page_id, before \\ nil, limit \\ nil) do
    with {:ok, _page} <- existing(space_id, page_id),
         :ok <- optional_integer(before, "before"),
         :ok <- optional_integer(limit, "limit") do
      limit = min(max(limit || @default_limit, 1), @max_limit)

      {shown, rest} =
        space_id
        |> fold(page_id)
        |> Map.fetch!(:versions)
        |> Enum.filter(&(before == nil or &1.version < before))
        |> Enum.split(limit)

      {:ok,
       %{versions: with_titles(shown), next_before: if(rest != [], do: List.last(shown).version)}}
    end
  end

  @doc "The page as it stood at `version`: its title and blocks, and when it was written."
  def read(space_id, page_id, version) do
    with {:ok, _page} <- existing(space_id, page_id),
         :ok <- integer(version, "version"),
         %{page: %{} = page, blocks: blocks, at: at} <- fold(space_id, page_id, version) do
      {:ok, %{version: version, at: at, title: page["title"], blocks: in_order(blocks)}}
    else
      %{page: nil} -> no_version(version)
      error -> error
    end
  end

  @doc """
  The changes that make the live page look like the version `read/3` gave, as a Space
  transaction: none when it already does.
  """
  def restore(state, page_id, version, author, at \\ Entities.now()) do
    with {:ok, page} <- Pages.fetch_live(state, page_id) do
      stamp = &Map.merge(&1, %{"updatedBy" => author, "updatedAt" => at})

      current =
        for block <- Space.Blocks.of_page(state, page_id),
            block["kind"] != "generated",
            into: %{},
            do: {block["id"], block}

      new = &new_block(&1, page_id, author, at)
      wanted = ours(Enum.map(version.blocks, &wanted_block(state, &1)), state, page, current, new)
      ids = MapSet.new(wanted, & &1["id"])

      blocks =
        Enum.flat_map(wanted, fn block ->
          case current[block["id"]] do
            nil ->
              [{"block", block["id"], Patch.diff(nil, stamp.(block))}]

            now ->
              next = now |> Map.drop(@content) |> Map.merge(Map.take(block, @content))
              if next == now, do: [], else: [{"block", now["id"], Patch.diff(now, stamp.(next))}]
          end
        end)

      gone = for id <- Map.keys(current), id not in ids, do: {"block", id, Patch.delete()}
      restored = blocks ++ gone
      retitled = page["title"] != version.title

      if restored == [] and not retitled do
        {[], {:ok, page}}
      else
        next = %{page | "title" => version.title, "updatedAt" => at}
        marker = %{"version" => version.version, "at" => version.at, "by" => author}

        # Written in the same millisecond as the page was made, nothing differs.
        updated =
          case Patch.diff(page, next) do
            :unchanged -> []
            patch -> [{"page", page_id, patch}]
          end

        {[{"page", page_id, %{"s" => %{"restoring" => marker}}}] ++
           updated ++ restored ++ [{"page", page_id, %{"u" => ["restoring"]}}], {:ok, next}}
      end
    end
    |> Pages.refused()
  end

  # A restore never writes a generated part: the page's own, left out of `current`, stays
  # as it is. A page that updates itself takes none of a version's. Any other gets a
  # version's back as the blocks it reads as, as when the update is removed
  # (`HalC2.Space.Blocks.release_generated/4`), in blocks that release left and nobody
  # has written since where the page has them, so a version from before the removal is
  # the page as it is. A block someone wrote is theirs, with its comments, whatever it says.
  defp ours(blocks, _state, %{"schedule" => %{}}, _current, _new),
    do: Enum.reject(blocks, &(&1["kind"] == "generated"))

  defp ours(blocks, state, _page, current, new) do
    ids = MapSet.new(blocks, & &1["id"])

    spare =
      current
      |> Map.values()
      |> Enum.filter(&(&1["id"] not in ids and &1["updatedBy"] == Space.Schedule.author()))
      |> Enum.sort_by(& &1["order"])

    blocks
    |> Enum.zip(Enum.drop(blocks, 1) ++ [nil])
    |> Enum.flat_map_reduce(spare, fn
      {%{"kind" => "generated"} = block, next}, spare ->
        released(Space.written(state, block["text"]), block, next, spare, new)

      {block, _next}, spare ->
        {[block], spare}
    end)
    |> elem(0)
  end

  defp released([], _block, _next, spare, _new), do: {[], spare}

  defp released([first | rest], block, next, spare, new) do
    high = next && next["order"]

    {rest, {spare, _low}} =
      Enum.map_reduce(rest, {spare, block["order"]}, fn spec, {spare, low} ->
        order = Order.between(low, high)
        fields = spec |> from_spec() |> Map.put("order", order)

        case Enum.find(spare, &(Map.merge(&1, Map.delete(fields, "order")) == &1)) do
          nil -> {new.(fields), {spare, order}}
          found -> {Map.merge(found, fields), {List.delete(spare, found), order}}
        end
      end)

    {[Map.merge(block, from_spec(first)) | rest], spare}
  end

  # A block's content as `HalC2.Space.Blocks` makes it from a spec of `Space.written/2`.
  defp from_spec(spec) do
    spec
    |> Map.take(~w(imageId level gap))
    |> Map.merge(%{
      "kind" => spec["kind"],
      "text" => spec["text"] || "",
      "checked" => spec["kind"] == "checklist" and spec["checked"] == true,
      "linkedPageId" => if(spec["kind"] == "subpage_link", do: spec["linkedPageId"])
    })
  end

  defp new_block(fields, page_id, author, at) do
    Map.merge(fields, %{
      "id" => HalC2.Environment.uuid4(),
      "pageId" => page_id,
      "createdBy" => author,
      "createdAt" => at
    })
  end

  # An image block stays one whatever became of its image: it says what did.
  defp wanted_block(_state, %{"kind" => "image"} = block), do: block
  defp wanted_block(state, block), do: Space.links(state, block)

  defp existing(space_id, page_id) do
    with {:ok, state} <- Space.state(space_id) do
      case Pages.get(state, page_id) do
        nil -> {:error, :not_found, "There is no page #{page_id} in this Space."}
        page -> {:ok, page}
      end
    end
  end

  defp no_version(version),
    do: {:error, :not_found, "This page has no version #{version}."}

  defp integer(value, _name) when is_integer(value) and value >= 0, do: :ok
  defp integer(_value, name), do: {:error, :invalid, "#{name} is a number."}

  defp optional_integer(nil, _name), do: :ok
  defp optional_integer(value, name), do: integer(value, name)

  defp in_order(blocks), do: blocks |> Map.values() |> Enum.sort_by(&{&1["order"], &1["id"]})

  defp fold(space_id, page_id, through \\ nil) do
    opts = [kinds: ["page", "block"]] ++ if(through, do: [through: through], else: [])
    new = %{id: page_id, page: nil, blocks: %{}, versions: [], at: nil}
    Store.reduce_stream(Store.path(), Space.stream_id(space_id), 0, new, &step/2, opts)
  end

  # The threads named are looked up once each, as they stand now.
  defp with_titles(versions) do
    titles =
      for %{author: %{"threadId" => id}} <- versions, uniq: true, into: %{} do
        {id, thread_title(id)}
      end

    Enum.map(versions, fn version ->
      version
      |> Map.put(:thread_title, titles[version.author["threadId"]])
      |> Map.update!(:at, &iso/1)
    end)
  end

  defp thread_title(id) do
    case HalC2.Shell.row(node(), id) do
      {"thread", row} -> row["title"]
      _ -> nil
    end
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp step(%{kind: "page", entity: id} = event, %{id: id} = acc) do
    prev = acc.page
    next = Patch.apply(prev, event.patch)
    acc = %{acc | page: next}

    cond do
      # A page deleted for good is not asked about; nothing follows it.
      next == nil ->
        acc

      next["restoring"] && !(prev || %{})["restoring"] ->
        restoring(acc, event, next["restoring"])

      (prev || %{})["restoring"] && !next["restoring"] ->
        acc |> extend(event)

      prev == nil ->
        edit(acc, event, creator(next))

      prev["title"] != next["title"] ->
        edit(acc, event, Space.user())

      true ->
        acc
    end
  end

  defp step(%{kind: "block", entity: id} = event, acc) do
    prev = acc.blocks[id]

    if prev != nil or get_in(event.patch, ["s", "pageId"]) == acc.id do
      next = Patch.apply(prev, event.patch)
      blocks = if next, do: Map.put(acc.blocks, id, next), else: Map.delete(acc.blocks, id)
      acc = %{acc | blocks: blocks}

      if content(prev) == content(next),
        do: acc,
        else: edit(acc, event, (next || prev)["updatedBy"] || Space.user())
    else
      acc
    end
  end

  defp step(_event, acc), do: acc

  defp creator(%{"sourceThreadId" => id}) when is_binary(id), do: Space.agent(id)
  defp creator(_page), do: Space.user()

  defp content(nil), do: nil
  defp content(block), do: Map.take(block, @content)

  defp restoring(acc, event, marker) do
    version = %{
      version: event.seq,
      at: event.at,
      author: marker["by"],
      restored_from_at: marker["at"],
      open: true
    }

    %{acc | versions: [version | acc.versions], at: iso(event.at)}
  end

  # Closes the restore in hand.
  defp extend(%{versions: [version | rest]} = acc, event),
    do: %{acc | versions: [%{version | version: event.seq, open: false} | rest]}

  defp edit(%{versions: [%{open: true} = version | rest]} = acc, event, _author),
    do: %{acc | versions: [%{version | version: event.seq} | rest], at: iso(event.at)}

  defp edit(%{versions: [%{restored_from_at: nil} = version | rest]} = acc, event, author)
       when version.author == author and event.at - version.at <= @gap do
    %{acc | versions: [%{version | version: event.seq, at: event.at} | rest], at: iso(event.at)}
  end

  defp edit(acc, event, author) do
    version = %{
      version: event.seq,
      at: event.at,
      author: author,
      restored_from_at: nil,
      open: false
    }

    %{acc | versions: [version | acc.versions], at: iso(event.at)}
  end
end
