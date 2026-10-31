defmodule HalC2.Space.Pages do
  @moduledoc """
  The pages of one Space, decided on its stream state (`HalC2.Space.transact/2`).
  Each command returns `{changes, reply}`: the reply is `{:ok, value}` or
  `{:error, reason, message}` with no changes.

  A page in the trash hides its subpages with it. A page is *live* when neither it
  nor a page above it is in the trash; only a live page is edited. Restoring a page
  whose parent is not live puts it at the top of the Space, so it is seen again.
  Only a page in the trash is deleted, with its subpages, blocks and comments.
  """

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, StreamState}

  @doc "The page `id`, or nil."
  def get(state, id), do: StreamState.get(state, "page")[id]

  @doc "The pages that are not hidden by the trash, in the order they were made."
  def live(state), do: state |> StreamState.list("page") |> Enum.filter(&live?(state, &1))

  @doc "The pages in the trash themselves, in the order they were made."
  def trashed(state), do: state |> StreamState.list("page") |> Enum.filter(& &1["trashedAt"])

  @doc "Whether neither `page` nor a page above it is in the trash."
  def live?(state, page),
    do: Enum.all?([page | ancestors(state, page)], &(&1["trashedAt"] == nil))

  @doc "The live page `id`, or why it cannot be edited."
  def fetch_live(state, id) do
    case get(state, id) do
      nil -> {:error, :not_found, "There is no page #{id} in this Space."}
      page -> if live?(state, page), do: {:ok, page}, else: in_trash(page)
    end
  end

  defp in_trash(page), do: {:error, :trashed, "The page \"#{page["title"]}\" is in the trash."}

  # The pages above `page`, nearest first. A parent that is gone ends the chain.
  defp ancestors(state, page, seen \\ MapSet.new()) do
    with id when is_binary(id) <- page["parentPageId"],
         false <- MapSet.member?(seen, id),
         %{} = parent <- get(state, id) do
      [parent | ancestors(state, parent, MapSet.put(seen, id))]
    else
      _ -> []
    end
  end

  @doc "A new page; `extra` sets fields such as `sourceThreadId`."
  def create(state, space_id, title, parent_id, extra \\ %{}) do
    with {:ok, title} <- title(title),
         :ok <- parent(state, parent_id) do
      at = Entities.now()

      page =
        Map.merge(
          %{
            "id" => HalC2.Environment.uuid4(),
            "spaceId" => space_id,
            "title" => title,
            "parentPageId" => parent_id,
            "sourceThreadId" => nil,
            "trashedAt" => nil,
            "createdAt" => at,
            "updatedAt" => at
          },
          extra
        )

      {[{"page", page["id"], Patch.diff(nil, page)}], {:ok, page}}
    end
    |> refused()
  end

  def rename(state, id, title) do
    with {:ok, page} <- fetch_live(state, id),
         {:ok, title} <- title(title) do
      update(page, %{"title" => title})
    end
    |> refused()
  end

  @doc "Moves a page under `parent_id`, or to the top with nil; never under itself."
  def move(state, id, parent_id) do
    with {:ok, page} <- fetch_live(state, id),
         :ok <- parent(state, parent_id),
         :ok <- not_below(state, page, parent_id) do
      update(page, %{"parentPageId" => parent_id})
    end
    |> refused()
  end

  def trash(state, id) do
    with {:ok, page} <- fetch_live(state, id) do
      update(page, %{"trashedAt" => Entities.now()})
    end
    |> refused()
  end

  def restore(state, id) do
    case get(state, id) do
      %{"trashedAt" => at} = page when at != nil ->
        parent = page["parentPageId"] && get(state, page["parentPageId"])
        keep = parent != nil and live?(state, parent)
        update(page, %{"trashedAt" => nil, "parentPageId" => if(keep, do: parent["id"])})

      nil ->
        refused({:error, :not_found, "There is no page #{id} in this Space."})

      page ->
        refused({:error, :invalid, "The page \"#{page["title"]}\" is not in the trash."})
    end
  end

  @doc """
  Deletes a page in the trash for good, with its subpages, their blocks and comments,
  and the links to them from other pages. Replies with the deleted page ids.
  """
  def delete(state, id) do
    case get(state, id) do
      %{"trashedAt" => at} when at != nil ->
        ids = MapSet.new([id | descendants(state, id)])
        blocks = StreamState.list(state, "block")

        gone_blocks =
          for block <- blocks,
              block["pageId"] in ids or block["linkedPageId"] in ids,
              do: block["id"]

        gone_blocks = MapSet.new(gone_blocks)

        comments =
          for comment <- StreamState.list(state, "comment"),
              comment["pageId"] in ids or comment["blockId"] in gone_blocks,
              do: {"comment", comment["id"], Patch.delete()}

        changes =
          Enum.map(ids, &{"page", &1, Patch.delete()}) ++
            Enum.map(gone_blocks, &{"block", &1, Patch.delete()}) ++ comments

        {changes, {:ok, Enum.to_list(ids)}}

      nil ->
        refused({:error, :not_found, "There is no page #{id} in this Space."})

      page ->
        refused(
          {:error, :invalid,
           "Only a page in the trash can be deleted; move \"#{page["title"]}\" there first."}
        )
    end
  end

  defp descendants(state, id) do
    children =
      for page <- StreamState.list(state, "page"), page["parentPageId"] == id, do: page["id"]

    children ++ Enum.flat_map(children, &descendants(state, &1))
  end

  defp update(page, fields) do
    next = Map.merge(page, fields)

    case Patch.diff(page, next) do
      :unchanged ->
        {[], {:ok, page}}

      _ ->
        next = Map.put(next, "updatedAt", Entities.now())
        {[{"page", page["id"], Patch.diff(page, next)}], {:ok, next}}
    end
  end

  defp title(title) when is_binary(title) do
    case String.trim(title) do
      "" -> {:error, :invalid, "A page needs a title."}
      title -> {:ok, title}
    end
  end

  defp title(_), do: {:error, :invalid, "A page needs a title."}

  defp parent(_state, nil), do: :ok

  defp parent(state, id) do
    with {:ok, _} <- fetch_live(state, id), do: :ok
  end

  defp not_below(_state, _page, nil), do: :ok

  defp not_below(state, page, parent_id) do
    if parent_id == page["id"] or parent_id in descendants(state, page["id"]),
      do: {:error, :cycle, "A page cannot move inside itself."},
      else: :ok
  end

  @doc "A refusal as a decision: no changes."
  def refused({:error, _, _} = error), do: {[], error}
  def refused(decision), do: decision
end
