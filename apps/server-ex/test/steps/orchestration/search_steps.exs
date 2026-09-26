defmodule T3.Steps.Orchestration.Search do
  @moduledoc """
  Steps for `features/node/orchestration/search.feature`: messages are committed to
  thread streams (which indexes the finished ones), and clients search over the
  socket (`orchestration.searchThreads`). Threads are named by id (`"t1"`).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node.World

  # --- threads and messages ------------------------------------------------------------

  step "thread {string} has an assistant message {string}", %{args: [thread, text]} = context do
    context |> ensure_thread(thread) |> World.add_message(thread, "assistant", text)
  end

  step "thread {string} has a user message {string}", %{args: [thread, text]} = context do
    context |> ensure_thread(thread) |> World.add_message(thread, "user", text)
  end

  step "thread {string} has a message {string}", %{args: [thread, text]} = context do
    context |> ensure_thread(thread) |> World.add_message(thread, "user", text)
  end

  step "thread {string} has a user message and an assistant message both containing {string}",
       %{args: [thread, word]} = context do
    context
    |> ensure_thread(thread)
    |> World.add_message(thread, "user", "please look at the #{word} layer")
    # The assistant answered later, so it is the newest match in the thread.
    |> World.add_message(thread, "assistant", "the #{word} layer is fixed")
  end

  step "an archived thread's message contains {string}", %{args: [word]} = context do
    context = context |> ensure_thread("t1") |> World.add_message("t1", "user", word)
    context = World.command(context, %{"type" => "thread.archive", "threadId" => "t1"})
    assert {:ok, _} = context.reply
    World.await_row("t1", & &1["archivedAt"])
    context
  end

  step "a deleted thread's message contains {string}", %{args: [word]} = context do
    context = context |> ensure_thread("t1") |> World.add_message("t1", "user", word)
    context = World.command(context, %{"type" => "thread.delete", "threadId" => "t1"})
    assert {:ok, _} = context.reply
    assert World.thread(context, "t1")["deletedAt"]
    context
  end

  step "an assistant message still streaming contains {string}", %{args: [word]} = context do
    context
    |> ensure_thread("t1")
    |> World.add_message("t1", "assistant", word, nil, %{"streaming" => true})
  end

  step "a tool call's output contains {string}", %{args: [word]} = context do
    context
    |> ensure_thread("t1")
    |> World.add_item("t1", "item-tool", "command", nil, %{"input" => "grep", "output" => word})
  end

  step "threads {string} and {string} both mention {string} and {string} was active more recently",
       %{args: [old, new, word, new]} = context do
    context =
      context
      |> ensure_thread(old)
      |> World.add_message(old, "user", "#{word} the api")
      |> ensure_thread(new)
      |> World.add_message(new, "user", "#{word} the web")

    assert epoch(World.row(context, new)) > epoch(World.row(context, old))
    context
  end

  step "{int} threads mention {string}", %{args: [count, word]} = context do
    project = World.project(context).id

    # Committed without waiting out each sidebar debounce; `settle/1` flushes them.
    Enum.reduce(1..count, context, fn n, context ->
      id = "t#{n}"

      {:ok, _} =
        T3.Orchestration.dispatch(%{
          "type" => "thread.create",
          "commandId" => "cmd-#{id}",
          "threadId" => id,
          "projectId" => project,
          "title" => id,
          "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
        })

      {:ok, _} = T3.Streams.commit(id, :thread, [{"message", "m-#{id}", message(id, word)}])
      put_in(context, [:threads, id], id)
    end)
  end

  step "thread {string} has a 2,000 character message with {string} in the middle",
       %{args: [thread, word]} = context do
    # Words split by runs of spaces and newlines, which the snippet collapses.
    half = "lorem  ipsum\n dolor " |> String.duplicate(60) |> String.slice(0, 997)
    text = half <> word <> String.reverse(half)
    assert String.length(text) == 2_000

    context
    |> ensure_thread(thread)
    |> World.add_message(thread, "assistant", text)
    |> Map.put(:word, word)
  end

  step "threads written by a node that had no search index", context do
    context =
      context
      |> ensure_thread("t1")
      |> World.add_message("t1", "user", "migrate the ledger")
      |> ensure_thread("t2")
      |> World.add_message("t2", "assistant", "the ledger is migrated")

    # The index as an older node left it: no rows and never backfilled.
    settle(context)
    {:ok, db} = Exqlite.Sqlite3.open(context.node.store)
    :ok = Exqlite.Sqlite3.execute(db, "PRAGMA busy_timeout = 5000")
    :ok = Exqlite.Sqlite3.execute(db, "DELETE FROM messages")
    :ok = Exqlite.Sqlite3.execute(db, "DELETE FROM meta WHERE key = 'messages_indexed'")
    :ok = Exqlite.Sqlite3.close(db)

    {reply, context} = search(context, %{"query" => "ledger"})
    assert {:ok, %{"matches" => []}} = reply
    context
  end

  # --- searching -----------------------------------------------------------------------

  step "a client searches for {string}", %{args: [query]} = context do
    {reply, context} = search(context, %{"query" => query})
    Map.put(context, :reply, reply)
  end

  step "a client searches for a query of {int} characters", %{args: [length]} = context do
    {reply, context} = search(context, %{"query" => String.duplicate("q", length)})
    Map.put(context, :reply, reply)
  end

  step "a client searches for {string} with limit {int}", %{args: [query, limit]} = context do
    {reply, context} = search(context, %{"query" => query, "limit" => limit})
    Map.put(context, :reply, reply)
  end

  # --- outcomes ------------------------------------------------------------------------

  step "{string} is found with an assistant match", %{args: [thread]} = context do
    assert [%{"source" => "assistant"}] = found(context, thread)
    context
  end

  step "{string} is found", %{args: [thread]} = context do
    assert [_] = found(context, thread)
    context
  end

  step "{string} is found once, with its user message as the match",
       %{args: [thread]} = context do
    assert [%{"source" => "user", "snippet" => snippet}] = found(context, thread)
    assert snippet =~ "please look"
    context
  end

  step "nothing is found", context do
    assert matches(context) == []
    context
  end

  step "only {string} is found", %{args: [thread]} = context do
    assert Enum.map(matches(context), & &1["threadId"]) == [thread]
    context
  end

  step "{string} comes before {string}", %{args: [first, second]} = context do
    ids = Enum.map(matches(context), & &1["threadId"])
    assert Enum.find_index(ids, &(&1 == first)) < Enum.find_index(ids, &(&1 == second))
    context
  end

  step "{int} matches are returned", %{args: [count]} = context do
    assert length(matches(context)) == count
    context
  end

  step "asking with limit {int} returns {int}", %{args: [limit, count]} = context do
    {reply, context} = search(context, %{"query" => "deploy", "limit" => limit})
    assert {:ok, %{"matches" => matches}} = reply
    assert length(matches) == count
    context
  end

  step "the snippet is at most {int} characters with whitespace collapsed",
       %{args: [max]} = context do
    assert [%{"snippet" => snippet}] = matches(context)
    assert String.length(snippet) <= max
    refute snippet =~ ~r/\s\s|\n/
    context
  end

  step "it starts shortly before {string} and is marked with ellipses on both cut ends",
       %{args: [word]} = context do
    assert [%{"snippet" => snippet}] = matches(context)
    assert String.starts_with?(snippet, "…") and String.ends_with?(snippet, "…")
    {at, _} = :binary.match(snippet, word)
    offset = snippet |> binary_part(0, at) |> String.length()
    assert offset in 1..100, "#{word} starts #{offset} characters into #{inspect(snippet)}"
    context
  end

  step "their finished messages can be searched", context do
    {reply, context} = search(context, %{"query" => "ledger"})
    assert {:ok, %{"matches" => matches}} = reply
    assert matches |> Enum.map(& &1["threadId"]) |> Enum.sort() == ["t1", "t2"]
    context
  end

  step "the request is rejected as invalid", context do
    assert {:error, error, _} = context.reply, "expected a refusal, got #{inspect(context.reply)}"
    assert error =~ "Invalid"
    context
  end

  # --- helpers -------------------------------------------------------------------------

  defp ensure_thread(context, thread) do
    if (context[:threads] || %{})[thread],
      do: context,
      else: World.named_thread(context, thread)
  end

  # Searches once every committed message is indexed and every sidebar row is written.
  defp search(context, input) do
    settle(context)
    World.call(context, "orchestration.searchThreads", input)
  end

  defp settle(context) do
    for {_, id} <- context[:threads] || %{}, do: :ok = T3.Streams.flush_shell(id)
    :sys.get_state(T3.Shell)
    :sys.get_state(T3.Store)
  end

  defp matches(context) do
    assert {:ok, %{"matches" => matches}} = context.reply
    matches
  end

  defp found(context, thread), do: Enum.filter(matches(context), &(&1["threadId"] == thread))

  defp epoch(row), do: T3.Projection.JS.epoch_ms(row["updatedAt"])

  defp message(thread, text) do
    at = World.iso_from_now(0)

    %{
      "s" => %{
        "id" => "m-#{thread}",
        "threadId" => thread,
        "createdBy" => "user",
        "creationSource" => "web",
        "runId" => nil,
        "nodeId" => nil,
        "role" => "user",
        "text" => "#{text} #{thread}",
        "attachments" => [],
        "streaming" => false,
        "createdAt" => at,
        "updatedAt" => at
      }
    }
  end
end
