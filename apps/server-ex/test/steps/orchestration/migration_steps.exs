defmodule T3.Steps.Orchestration.Migration do
  @moduledoc """
  Steps for `features/node/orchestration/migration.feature`. The snapshot is a
  Node server database holding `orchestration_events` (`World.node_log/2`), built
  from `context.snapshot` (oldest first) when the operator imports it. The operator
  runs `mix t3.import` (`Mix.Tasks.T3.Import`) while the node is stopped, and the
  node starts on the result.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Exqlite.Sqlite3
  alias T3.Test.Node
  alias T3.Test.Node.World

  # 2026-09-01T00:00:00Z; each snapshot event is a second after the one before.
  @start 1_788_220_800_000

  step "a snapshot of a Node server's database with V2 orchestration history", context do
    context
    |> Map.put(:snapshot, [])
    |> event("project", "p1", "project.created", %{
      "projectId" => "p1",
      "title" => "Demo",
      "workspaceRoot" => "/work/demo",
      "scripts" => []
    })
    |> event("thread", "t1", "thread.created", thread())
    |> event("thread", "t1", "message.updated", %{
      "id" => "m0",
      "threadId" => "t1",
      "role" => "user",
      "text" => "Hello"
    })
  end

  # --- importing ---------------------------------------------------------------------

  step "the operator imports the snapshot into a node", context do
    source = snapshot(context)
    dir = Path.dirname(source)
    before = {File.read!(source), File.ls!(dir)}

    # Nothing may write the source: neither the file nor a journal beside it.
    File.chmod!(source, 0o444)
    File.chmod!(dir, 0o555)
    ExUnit.Callbacks.on_exit(fn -> File.chmod(dir, 0o755) end)

    node = Node.restart(context.node, fn -> send(self(), {:imported, import!(source)}) end)
    File.chmod!(dir, 0o755)
    assert_received {:imported, output}

    %{context | node: node, clients: %{}}
    |> Map.merge(%{output: output, source: source, before: before})
  end

  step "every project and thread stream of the snapshot exists on the node", context do
    expected = for {aggregate, id, _, _, _} <- context.snapshot, uniq: true, do: {aggregate, id}
    streams = for %{id: id, kind: kind} <- T3.Store.list_streams(T3.Store.path()), do: {kind, id}
    assert Enum.sort(streams) == Enum.sort(expected)
    for {kind, id} <- expected, do: assert({^kind, _} = T3.Shell.row(node(), id))
    context
  end

  step "the operator is told how many streams, events and bytes went in and were kept",
       context do
    streams = context.snapshot |> Enum.uniq_by(&elem(&1, 1)) |> length()

    assert [_, ^streams] =
             Regex.run(~r/^Imported (\d+) streams in \d+ ms into /, context.output)
             |> then(fn [all, n] -> [all, String.to_integer(n)] end)

    assert [_, from, to] = Regex.run(~r/events:\s+(\d+) -> (\d+)/, context.output)
    assert String.to_integer(from) == length(context.snapshot)
    assert String.to_integer(to) == store_count("SELECT COUNT(*) FROM events")
    assert context.output =~ ~r/payload: \d+\.\d MB -> \d+\.\d MB/
    context
  end

  step "the snapshot is opened read-only and is unchanged afterwards", context do
    dir = Path.dirname(context.source)
    assert {File.read!(context.source), File.ls!(dir)} == context.before
    context
  end

  # --- streamed text and re-emits ----------------------------------------------------

  step "the snapshot stored a streamed reply as {int} full copies of the growing message",
       %{args: [copies]} = context do
    Enum.reduce(1..copies, context, fn n, context ->
      event(context, "thread", "t1", "message.updated", reply(n, n < copies))
    end)
    |> Map.put(:copies, copies)
  end

  step "the node keeps only what changed between the copies", context do
    [first | rest] = for event <- events("t1"), event.entity == "m1", do: event.patch
    assert length(rest) == context.copies - 1
    assert first["s"]["text"] == "word1"

    for {patch, n} <- Enum.with_index(rest, 2) do
      assert patch["a"] == %{"text" => " word#{n}"}
      refute Map.has_key?(patch["s"] || %{}, "text")
    end

    context
  end

  step "the imported message reads the same as in the Node server", context do
    assert entity("t1", "message", "m1") == reply(context.copies, false)
    context
  end

  step "the snapshot records the same thread state twice in a row", context do
    renamed = Map.put(thread(), "title", "Renamed")

    context
    |> event("thread", "t1", "thread.meta-updated", renamed)
    |> event("thread", "t1", "thread.meta-updated", renamed)
  end

  step "only one change is kept for it", context do
    patches = for event <- events("t1"), event.entity == "t1", do: event.patch
    assert [%{"s" => %{"title" => "First"}}, %{"s" => %{"title" => "Renamed"}}] = patches
    context
  end

  # --- provider sessions and threads -------------------------------------------------

  step "the snapshot attaches a provider session to {string}, updates it, detaches it, then updates it again",
       %{args: [thread]} = context do
    session = %{"id" => "ps-1", "status" => "ready"}

    context
    |> event("thread", thread, "provider-session.attached", session)
    |> event("thread", thread, "provider-session.updated", %{session | "status" => "running"})
    |> event("thread", thread, "provider-session.detached", %{
      "providerSessionId" => "ps-1",
      "detachedAt" => iso(@start)
    })
    |> event("thread", thread, "provider-session.updated", %{session | "status" => "stopped"})
  end

  step "the update after detaching does not change {string}", %{args: [thread]} = context do
    sessions = for event <- events(thread), event.kind == "provider-session", do: event.patch

    assert [%{"s" => %{"status" => "ready"}}, %{"s" => %{"status" => "running"}}, %{"d" => true}] =
             sessions

    assert T3.StreamState.get(state(thread), "provider-session") == %{}
    context
  end

  step "the snapshot updates provider thread {string} of {string} after {string}",
       %{args: [later, thread, earlier]} = context do
    context
    |> event("thread", thread, "provider-thread.updated", provider_thread(earlier, thread))
    |> event("thread", thread, "provider-thread.updated", provider_thread(later, thread))
  end

  step "{string} has {string} as its active provider thread",
       %{args: [thread, active]} = context do
    assert entity(thread, "thread", thread)["activeProviderThreadId"] == active
    context
  end

  step "the snapshot records a queued placeholder provider thread for {string}",
       %{args: [thread]} = context do
    # Queued for a future run: not loaded, with no run, native thread or session yet.
    placeholder = %{"id" => "queued", "appThreadId" => thread, "status" => "not_loaded"}

    context
    |> event("thread", thread, "provider-thread.updated", provider_thread("p1", thread))
    |> event("thread", thread, "provider-thread.updated", placeholder)
  end

  step "{string} keeps its previous active provider thread", %{args: [thread]} = context do
    assert entity(thread, "provider-thread", "queued")
    assert entity(thread, "thread", thread)["activeProviderThreadId"] == "p1"
    context
  end

  # --- activity ----------------------------------------------------------------------

  step "the snapshot records a visit to {string} after its last activity",
       %{args: [thread]} = context do
    context =
      event(context, "thread", thread, "message.updated", %{
        "id" => "m2",
        "threadId" => thread,
        "role" => "user",
        "text" => "Still there?"
      })

    {_, _, _, _, last} = List.last(context.snapshot)

    context
    |> event("thread", thread, "thread.visited", Map.put(thread(), "lastVisitedAt", iso(last)))
    |> event("thread", thread, "thread.marked-unread", thread())
    |> Map.put(:last_activity, last)
  end

  step "the activity time of {string} is its last real activity", %{args: [thread]} = context do
    assert {"thread", row} = T3.Shell.row(node(), thread)
    {:ok, at, 0} = DateTime.from_iso8601(row["updatedAt"])
    assert DateTime.to_unix(at, :millisecond) == context.last_activity
    context
  end

  # --- many threads ------------------------------------------------------------------

  step "the snapshot holds thousands of threads", context do
    ids = for n <- 1..2_000, do: "t-" <> String.pad_leading("#{n}", 4, "0")

    # First active in reverse order of their ids, and their events interleaved.
    context =
      Enum.reduce(Enum.reverse(ids), context, fn id, context ->
        event(context, "thread", id, "thread.created", thread(id))
      end)

    Enum.reduce(ids, context, fn id, context ->
      event(context, "thread", id, "thread.meta-updated", Map.put(thread(id), "title", id))
    end)
  end

  step "the node imports them in order of first activity, holding one thread in memory at a time",
       context do
    first_active = for {_, id, _, _, _} <- context.snapshot, uniq: true, do: id

    blocks =
      store_rows("""
      SELECT s.id, MIN(e.seq), MAX(e.seq), COUNT(*) FROM events e
      JOIN streams s ON s.key = e.stream GROUP BY s.key ORDER BY MIN(e.seq)
      """)

    assert Enum.map(blocks, &hd/1) == first_active

    # A stream's events are all written before the next stream's first one: the
    # import finishes a thread, and lets it go, before it reads the next.
    for [id, min, max, count] <- blocks, do: assert(max - min + 1 == count, "#{id} was split")
    context
  end

  # --- when imports happen -----------------------------------------------------------

  step "a node starts next to a Node server's database", context do
    source = Path.join([context.node.home, "userdata", "state.sqlite"])
    File.mkdir_p!(Path.dirname(source))
    World.node_log(source, context.snapshot)
    %{context | node: Node.restart(context.node), clients: %{}} |> Map.put(:source, source)
  end

  step "nothing is imported until the operator runs the import", context do
    assert T3.Store.list_streams(T3.Store.path()) == []

    node = Node.restart(context.node, fn -> import!(context.source) end)
    assert Enum.map(T3.Store.list_streams(T3.Store.path()), & &1.id) == ["p1", "t1"]
    %{context | node: node, clients: %{}}
  end

  # --- helpers -----------------------------------------------------------------------

  defp event(context, aggregate, stream, type, payload) do
    at = @start + length(context.snapshot) * 1_000
    Map.update!(context, :snapshot, &(&1 ++ [{aggregate, stream, type, payload, at}]))
  end

  defp thread(id \\ "t1"),
    do: %{"id" => id, "projectId" => "p1", "title" => "First", "createdAt" => iso(@start)}

  defp reply(n, streaming?) do
    %{
      "id" => "m1",
      "threadId" => "t1",
      "role" => "assistant",
      "text" => Enum.map_join(1..n, " ", &"word#{&1}"),
      "streaming" => streaming?
    }
  end

  defp provider_thread(id, thread) do
    %{
      "id" => id,
      "appThreadId" => thread,
      "status" => "idle",
      "providerSessionId" => "ps-#{id}",
      "firstRunOrdinal" => 1
    }
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp snapshot(context) do
    path = Path.join(Node.tmp_dir(context.node, "node-server"), "state.sqlite")
    World.node_log(path, context.snapshot)
  end

  # `mix t3.import` as the operator runs it; returns what it printed.
  defp import!(source) do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Tasks.T3.Import.run([source])
    after
      Mix.shell(shell)
      GenServer.stop(T3.Store)
    end

    assert_received {:mix_shell, :info, [output]}
    output
  end

  defp events(id) do
    T3.Store.path() |> T3.Store.reduce_stream(id, 0, [], &[&1 | &2]) |> Enum.reverse()
  end

  defp state(id), do: T3.StreamState.load(T3.Store.path(), id)
  defp entity(stream, kind, id), do: T3.StreamState.get(state(stream), kind)[id]

  defp store_count(sql), do: sql |> store_rows() |> hd() |> hd()

  defp store_rows(sql) do
    {:ok, db} = Sqlite3.open(T3.Store.path(), mode: :readonly)

    try do
      {:ok, stmt} = Sqlite3.prepare(db, sql)
      {:ok, rows} = Sqlite3.fetch_all(db, stmt)
      rows
    after
      Sqlite3.close(db)
    end
  end
end
