defmodule HalC2.Search do
  @moduledoc """
  Thread search (`orchestration.searchThreads`): finished user and assistant
  messages whose text contains the query, one match per active thread, preferring
  what the user wrote. Messages are indexed in `HalC2.Store` as they finish, with whether
  a person typed them; threads an older MC wrote are read once at startup (`backfill/0`).
  """

  alias HalC2.{Store, StreamState}

  @roles ["user", "assistant"]
  @snippet 240
  @not_typed ~w(senderThreadId scheduledTaskId notification delegatedCompletion providerWake)
  @read "messages_typed"

  @doc "Indexes the messages `events` finished or deleted, reading them from the committed `stream`."
  def index(stream_id, events, stream) do
    messages = StreamState.get(stream, "message")
    thread = StreamState.get(stream, "thread")[stream_id]

    entries =
      for %{kind: "message", entity: id} <- events,
          entry = entry(id, messages[id], thread),
          uniq: true,
          do: entry

    if entries != [], do: Store.index_messages(stream_id, entries)
    :ok
  end

  @doc "Indexes every thread's messages once, for logs an older MC wrote."
  def backfill do
    path = Store.path()

    if not read?() do
      for %{id: id, kind: "thread"} <- Store.list_streams(path) do
        state = StreamState.load(path, id)
        thread = StreamState.get(state, "thread")[id]

        entries =
          for message <- StreamState.list(state, "message"),
              entry = entry(message["id"], message, thread),
              do: entry

        if entries != [], do: Store.index_messages(id, entries)
      end

      Store.put_meta(@read, "1")
    end

    :ok
  end

  @doc "Whether the index says who typed every message, so turns can be counted from it."
  def read?, do: Store.meta(Store.path(), @read) == "1"

  defp entry(id, nil, _thread), do: {id, :deleted}

  defp entry(id, %{"role" => role} = message, thread) when role in @roles do
    if message["streaming"] != true,
      do: {id, role, message["text"] || "", message["createdAt"], typed?(message, thread)}
  end

  defp entry(_id, _message, _thread), do: nil

  # What an agent, a schedule or the MC sent has the role of a user's message too, and so
  # does what a fork copied from its source, which keeps the time it was first sent.
  defp typed?(%{"role" => "user"} = message, thread) do
    not Enum.any?(@not_typed, &(message[&1] != nil)) and
      not (get_in(thread, ["lineage", "relationshipToParent"]) == "fork" and
             message["createdAt"] < thread["createdAt"])
  end

  defp typed?(_message, _thread), do: false

  @doc """
  Searches with `query` (trimmed, 2 to 200 characters) for up to `limit` (1 to 50,
  default 50) threads, as the contract's `OrchestrationSearchThreadsInput` allows.
  """
  @spec threads(map) :: {:ok, map} | {:error, String.t()}
  def threads(input) do
    query = if is_binary(input["query"]), do: String.trim(input["query"])
    limit = Map.get(input, "limit", 50)

    cond do
      query == nil or String.length(query) not in 2..200 ->
        {:error, "Invalid search: the query must be 2 to 200 characters."}

      not is_integer(limit) or limit not in 1..50 ->
        {:error, "Invalid search: the limit must be 1 to 50."}

      true ->
        {:ok, %{"matches" => matches(query, limit)}}
    end
  end

  defp matches(query, limit) do
    pattern = "%" <> String.replace(query, ~r/[!%_]/, "!\\0") <> "%"

    active =
      for {{mc, id}, {"thread", row}} <- HalC2.Shell.rows(),
          mc == node() and row["archivedAt"] == nil and row["deletedAt"] == nil,
          into: %{},
          do: {id, row}

    Store.path()
    |> Store.search_messages(pattern, 2_000)
    |> Enum.filter(fn {thread_id, _, _, _} -> Map.has_key?(active, thread_id) end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {thread_id, found} ->
      # Newest first already; a user message wins over an assistant one.
      {_, role, text, at} = Enum.find(found, &(elem(&1, 1) == "user")) || hd(found)
      thread = active[thread_id]

      {thread["updatedAt"] || "",
       %{
         "threadId" => thread_id,
         "projectId" => thread["projectId"],
         "source" => role,
         "snippet" => snippet(text, query),
         "messageCreatedAt" => at
       }}
    end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 1))
  end

  # The text around the first match, cut to fit.
  defp snippet(text, query) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) <= @snippet do
      text
    else
      body = @snippet - 4
      index = text |> String.downcase() |> :binary.match(String.downcase(query))

      match =
        case index do
          {byte, _} -> text |> binary_part(0, byte) |> String.length()
          :nomatch -> 0
        end

      start = min(max(match - 72, 0), String.length(text) - body)
      cut = String.slice(text, start, body)

      "#{if start > 0, do: "…"}#{cut}#{if start + body < String.length(text), do: "…"}"
    end
  end
end
