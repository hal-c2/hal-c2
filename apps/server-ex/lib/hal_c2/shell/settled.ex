defmodule HalC2.Shell.Settled do
  @moduledoc """
  The settled shelf a client asks to be sent only the newest of, with `settledLimit`
  on its shell subscribe (`HalC2.Shell.subscribe/3`). Settled threads are most of a
  long-lived sidebar's rows, yet sit in a collapsed shelf.

  `trim/3` keeps, per project, the `limit` newest settled threads by `settledAt`
  (ties by id) and every older one that is pinned or snoozed, and counts the rest.
  Only shelved rows are trimmed: a settled thread that is not a subagent, archived or
  deleted, and that names its project. Every other row is kept.

  The rows are one MC's: an MC's rows are sent whole on their own (`reset`), so a
  project here is `{mc, projectId}`. Project ids belong to the environment that owns
  them, and a thread that moves to another machine joins a project of that MC
  (`HalC2.ThreadMove`), so each MC's rows hold its projects' threads whole. A client
  that lists one repository's projects of several MCs together adds their counts.
  """

  alias HalC2.Projection.JS

  @typedoc "Settled threads left out, by project id."
  @type left_out :: %{String.t() => pos_integer}

  @doc """
  `rows` (`{id, {kind, row}}`, all of one MC's) without the settled threads past
  `limit` in each project, and how many were left out of each. `now_ms` decides
  whether a thread is still snoozed.
  """
  @spec trim([{String.t(), {String.t(), map}}], pos_integer, integer) ::
          {[{String.t(), {String.t(), map}}], left_out}
  def trim(rows, limit, now_ms \\ System.os_time(:millisecond)) do
    left_out =
      rows
      |> Enum.filter(&shelved?/1)
      |> Enum.group_by(fn {_id, {_kind, row}} -> row["projectId"] end)
      |> Enum.flat_map(fn {_project, shelved} ->
        shelved
        |> Enum.sort_by(&newest_first/1, :desc)
        |> Enum.drop(limit)
        |> Enum.reject(&held?(&1, now_ms))
      end)

    ids = MapSet.new(left_out, &elem(&1, 0))

    {Enum.reject(rows, &MapSet.member?(ids, elem(&1, 0))),
     Enum.frequencies_by(left_out, fn {_id, {_kind, row}} -> row["projectId"] end)}
  end

  defp shelved?({_id, {"thread", row}}) do
    row["settledOverride"] == "settled" and is_binary(row["projectId"]) and
      row["archivedAt"] == nil and row["deletedAt"] == nil and
      get_in(row, ["lineage", "relationshipToParent"]) != "subagent"
  end

  defp shelved?(_row), do: false

  # Undated settled threads (older data) count as the oldest.
  defp newest_first({id, {_kind, row}}), do: {JS.epoch_ms(row["settledAt"]) || 0, id}

  # Pinned and snoozed threads are listed outside the shelf; an unreadable wake time
  # keeps the thread too.
  defp held?({_id, {_kind, row}}, now_ms) do
    row["pinnedAt"] != nil or
      (row["snoozedUntil"] != nil and (JS.epoch_ms(row["snoozedUntil"]) || now_ms + 1) > now_ms)
  end
end
