defmodule HalC2.Search do
  @moduledoc """
  Thread search (`orchestration.searchThreads`): finished user and assistant
  messages whose text contains the query, one match per active thread, preferring
  what the user wrote. Messages are indexed in `HalC2.Store` as they finish, with whether
  a person typed them. What did not pass through a stream is read whole: an import's thread
  when it lands (`index_thread/2`), and at startup what an older MC or an import with no MC
  running wrote (`backfill/0`).
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

  @doc "Indexes every thread's messages, for what an older MC or an offline import wrote."
  def backfill do
    path = Store.path()

    if not read?() do
      # A thread an import has not finished is left to it: the import indexes it when
      # it lands, and a stream opened on it now would miss the rest it then writes.
      unfinished = HalC2.Import.PreviousInstall.unfinished(path)
      long = MapSet.new(Store.legacy_streams(path, StreamState.max_legacy()))

      for %{id: id, kind: "thread"} <- Store.list_streams(path),
          id not in unfinished,
          do: read(path, id, id in long, &index_thread(id, &1))

      :ok = Store.forget_untyped_messages()
      Store.put_meta(@read, "1")
    end

    :ok
  end

  @doc "Has the next start read every thread again, after an import with no MC running."
  def read_again, do: Store.delete_meta(@read)

  @doc """
  Runs `write`, which stores the thread `id` with no stream to index it, and indexes what
  the thread then holds, even if `write` raises. What `write` may drop is forgotten first:
  should this be cut off before indexing, the next start reads every thread again, and that
  only adds. The mark comes back only if every thread had been read at the start.
  """
  def storing_thread(id, write) do
    read? = read?()
    :ok = read_again()

    gone =
      for message <- StreamState.all(load(id), "message"),
          do: {message["id"], :deleted}

    if gone != [], do: Store.index_messages(id, gone)

    try do
      write.()
    after
      :ok = index_thread(id, load(id))
      if read?, do: Store.put_meta(@read, "1")
    end
  end

  # `fun` of a thread's state, read from disk without opening its stream: opening
  # every thread at boot is what this read must not do. Only a `long` one, whose older
  # MC's whole snapshot is too big to read at once, is read through its stream, which
  # migrates it a page at a time (and `HalC2.Streams.Migrations` opens at boot anyway).
  defp read(path, id, long?, fun) do
    if long? and Process.whereis(HalC2.Streams) != nil,
      do: HalC2.Streams.read(id, fun),
      else: StreamState.load_read(path, id, fun)
  end

  # The thread as `storing_thread/2` finds it. With no streams running nothing else
  # writes it, so it is loaded as its stream would load it, the older runs written to
  # disk, instead of folding a long log whole.
  defp load(id) do
    if Process.whereis(HalC2.Streams),
      do: StreamState.load(Store.path(), id),
      else: StreamState.load(Store.path(), id, store: Store, max_legacy: :infinity)
  end

  @doc "Indexes all of a thread's messages from its loaded `state`, as an import needs."
  def index_thread(id, state) do
    thread = StreamState.get(state, "thread")[id]

    entries =
      for message <- StreamState.all(state, "message"),
          entry = entry(message["id"], message, thread),
          do: entry

    if entries != [], do: Store.index_messages(id, entries)
    :ok
  end

  @doc """
  Whether the index says who typed every message, so turns can be counted from it. An older
  MC run on this store since it was read leaves messages that do not say, so it is read again.
  """
  def read? do
    path = Store.path()
    Store.meta(path, @read) == "1" and not Store.untyped_messages?(path)
  end

  defp entry(id, nil, _thread), do: {id, :deleted}

  defp entry(id, %{"role" => role} = message, thread) when role in @roles do
    if message["streaming"] != true,
      do: {id, role, message["text"] || "", message["createdAt"], typed?(message, thread)}
  end

  defp entry(_id, _message, _thread), do: nil

  @doc """
  Whether the user typed `message` in `thread`. What an agent, a schedule or the MC sent has
  the role of a user's message too, and so does what a fork copied from its source, which
  keeps the time it was first sent.
  """
  @spec typed?(map, map) :: boolean
  def typed?(%{"role" => "user"} = message, thread) do
    not Enum.any?(@not_typed, &(message[&1] not in [nil, :null])) and
      not (get_in(thread, ["lineage", "relationshipToParent"]) == "fork" and
             message["createdAt"] < thread["createdAt"])
  end

  def typed?(_message, _thread), do: false

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

      {thread["updatedAt"] || "", text,
       %{
         "threadId" => thread_id,
         "projectId" => thread["projectId"],
         "source" => role,
         "messageCreatedAt" => at
       }}
    end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(limit)
    # Only the kept matches pay for a snippet.
    |> Enum.map(fn {_, text, match} -> Map.put(match, "snippet", snippet(text, query)) end)
  end

  # The text around the first match, cut to fit, without the markup HAL-C2
  # wraps around what it hands an agent (a delegated task's result, with its
  # task and thread ids), so a reader sees words, never ids.
  defp snippet(text, query) do
    text = text |> unwrap() |> String.replace(~r/\s+/u, " ") |> String.trim()

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

  # Drops the tags HAL-C2 wraps around what it hands an agent (a delegated
  # task's result, a composer's context envelope), opening and closing, and
  # leaves every other tag, such as `<a href="…">` or `Vec<String>`, as written.
  defp unwrap(text) do
    Regex.replace(
      ~r{</?(?:delegated_task_result|hal_c2_context|context)(?:\s+[\w:-]+="[^"]*")*\s*/?>}u,
      text,
      " "
    )
  end
end
