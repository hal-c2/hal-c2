defmodule HalC2.Steps.Space.Visualize do
  @moduledoc """
  Steps for `features/space/visualize.feature`. Requests go over the socket as
  `space.block.visualize`, with the fake text generation CLI answering; what a chart
  holds is read from the Space's stream. `HalC2.Steps.Space.Pages` owns the page steps.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.{Space, Store, StreamState, Streams}
  alias HalC2.Space.{Blocks, Chart}
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # The second client `HalC2.Steps.Space.Pages` subscribes.
  @watch 71
  @page_source "Numbers from this page"

  # --- real numbers ------------------------------------------------------------------

  step "this MC's threads took turns this week", context do
    context =
      context
      |> World.create_project("shop")
      |> World.create_thread("Work", "shop")
      |> World.add_message("Work", "user", "one")
      |> World.add_message("Work", "assistant", "not a turn")
      |> World.add_message("Work", "user", "two")

    # The pass a start runs, which may not have ended. Its write also waits out the index,
    # a cast the store has by the time it answers.
    :ok = HalC2.Search.backfill()
    Store.put_meta("test.flush", "1")
    Map.put(context, :turns_taken, 2)
  end

  step "an agent, a schedule and the MC each sent {string} a message",
       %{args: [title]} = context do
    [
      %{"senderThreadId" => "th-other"},
      %{"scheduledTaskId" => "task-1"},
      %{"notification" => %{"kind" => "task"}},
      %{"delegatedCompletion" => %{"taskIds" => ["task-2"]}},
      %{"providerWake" => true}
    ]
    |> Enum.reduce(context, &World.add_message(&2, title, "user", "not typed", nil, &1))
    |> tap(fn _ -> Store.put_meta("test.flush", "1") end)
  end

  step "a worker took turns on this MC", context do
    lineage = %{"parentThreadId" => "th-parent", "relationshipToParent" => "subagent"}

    context = World.create_thread(context, "A worker", "shop")
    worker = World.thread(context, "A worker")

    context
    |> World.put_entity("A worker", "thread", worker["id"], %{
      "s" => Map.put(worker, "lineage", lineage)
    })
    |> World.add_message("A worker", "user", "its prompt")
    |> tap(fn _ -> Store.put_meta("test.flush", "1") end)
  end

  step "a client forked {string}, and the fork took a turn of its own",
       %{args: [title]} = context do
    run = "run-to-fork"
    # A moment ago: a fork tells what it copied by being older than the fork.
    at = World.iso_from_now(-1_000)

    context =
      context
      |> World.add_run(title, "completed", at, %{"id" => run})
      |> World.add_message(title, "user", "before the fork", at, %{"runId" => run})
      |> World.fork_thread(title, "#{title} fork")
      |> World.add_message("#{title} fork", "user", "after the fork")

    assert Enum.any?(
             StreamState.list(World.stream(context, "#{title} fork"), "message"),
             &(&1["text"] == "before the fork")
           )

    Store.put_meta("test.flush", "1")
    Map.update!(context, :turns_taken, &(&1 + 2))
  end

  step "the user took back a message they sent to {string}", %{args: [title]} = context do
    id = "msg-taken-back"

    context
    |> World.add_message(title, "user", "never mind", nil, %{"id" => id})
    |> World.put_entity(title, "message", id, HalC2.Patch.delete())
    |> tap(fn _ -> Store.put_meta("test.flush", "1") end)
  end

  step "an older MC indexed them, not saying who typed what", context do
    # Index casts land before this write returns.
    Store.delete_meta("messages_typed")
    {:ok, db} = Exqlite.Sqlite3.open(Store.path())
    :ok = Exqlite.Sqlite3.execute(db, "PRAGMA busy_timeout = 5000")
    :ok = Exqlite.Sqlite3.execute(db, "UPDATE messages SET typed = NULL")
    :ok = Exqlite.Sqlite3.close(db)
    context
  end

  step "an older MC has run on this store since it read them", context do
    # Its rows say nothing of who typed them, one of them a message since deleted.
    Store.put_meta("test.flush", "1")
    {:ok, db} = Exqlite.Sqlite3.open(Store.path())
    :ok = Exqlite.Sqlite3.execute(db, "PRAGMA busy_timeout = 5000")

    :ok =
      Exqlite.Sqlite3.execute(db, """
      UPDATE messages SET typed = NULL;
      INSERT INTO messages (stream, id, role, text, created_at)
        SELECT stream, 'since-deleted', 'user', 'gone', created_at FROM messages LIMIT 1;
      """)

    :ok = Exqlite.Sqlite3.close(db)
    context
  end

  step "a thread of {string} moved to another MC", %{args: [project]} = context do
    context = World.create_thread(context, "Moved away", project)
    moved = World.thread(context, "Moved away")

    context
    |> World.put_entity("Moved away", "thread", moved["id"], %{
      "s" => Map.put(moved, "movedTo", "elsewhere")
    })
    |> tap(fn _ -> Store.put_meta("test.flush", "1") end)
  end

  step "a thread file holds one turn of the thread {string}", %{args: [id]} = context do
    context =
      context
      |> World.create_thread("To file", "shop")
      |> World.add_message("To file", "user", "one")

    source = World.thread_id(context, "To file")
    Store.put_meta("test.flush", "1")
    {:ok, archive} = HalC2.ThreadArchive.build(source)
    thread_file(context, archive |> HalC2.ThreadArchive.encode() |> String.replace(source, id))
  end

  step "a previous server's thread file holds one turn of the thread {string}",
       %{args: [id]} = context do
    project = World.project(context, "shop")
    at = "2026-09-01T00:00:00.000Z"

    payload = %{
      "id" => "m1",
      "threadId" => id,
      "role" => "user",
      "text" => "one",
      "createdAt" => at
    }

    events =
      Enum.map(
        [
          {"thread.created",
           %{"id" => id, "projectId" => project.id, "title" => "Filed", "createdAt" => at}},
          {"message.updated", payload}
        ],
        &v1_event(id, at, &1)
      )

    thread_file(context, JSON.encode!(v1_archive(id, "Filed", project, events)))
  end

  # A forwarding record that kept a copy, which `changes/3` allows for in a thread coming back.
  step "a thread of {string} kept two turns here", %{args: [project]} = context do
    context =
      context
      |> World.create_thread("Coming back", project)
      |> World.add_message("Coming back", "user", "kept", nil, %{"id" => "msg-kept"})
      |> World.add_message("Coming back", "user", "gone", nil, %{"id" => "msg-gone"})

    Store.put_meta("test.flush", "1")
    context
  end

  step "that thread moved away, and a thread file holds it with one turn fewer", context do
    id = World.thread_id(context, "Coming back")
    {:ok, archive} = HalC2.ThreadArchive.build(id)
    entities = Enum.reject(archive["entities"], &match?(["message", "msg-gone", _], &1))
    assert length(entities) < length(archive["entities"])
    moved_away(context)
    thread_file(context, HalC2.ThreadArchive.encode(%{archive | "entities" => entities}))
  end

  step "that thread moved away, and a previous server's thread file reverts its last turn",
       context do
    id = World.thread_id(context, "Coming back")
    project = World.project(context, "shop")
    at = "2026-09-01T00:00:00.000Z"

    sent = fn message, turn ->
      {"thread.message-sent",
       %{
         "messageId" => message,
         "role" => "user",
         "text" => message,
         "turnId" => turn,
         "createdAt" => at
       }}
    end

    done = fn turn, count ->
      {"thread.turn-diff-completed", %{"turnId" => turn, "checkpointTurnCount" => count}}
    end

    events =
      Enum.map(
        [
          {"thread.created",
           %{
             "threadId" => id,
             "projectId" => project.id,
             "title" => "Coming back",
             "createdAt" => at
           }},
          sent.("msg-kept", "t1"),
          done.("t1", 1),
          sent.("msg-gone", "t2"),
          done.("t2", 2),
          {"thread.reverted", %{"turnCount" => 1}}
        ],
        &v1_event(id, at, &1, 1)
      )

    moved_away(context)
    thread_file(context, JSON.encode!(v1_archive(id, "Coming back", project, events)))
  end

  # `mix hal_c2.thread.import` as the operator runs it.
  step "the operator imports the thread file with no MC up", context do
    # The pass a start runs, which may not have ended when the MC stops.
    :ok = HalC2.Search.backfill()
    project = World.project(context, "shop")
    shell = Mix.shell()

    mc =
      Mc.restart(context.mc, fn ->
        Mix.shell(Mix.Shell.Process)

        try do
          Mix.Tasks.HalC2.Thread.Import.run([context.thread_file, "--project", project.id])
        after
          Mix.shell(shell)
          GenServer.stop(Store)
        end
      end)

    %{context | mc: mc, clients: %{}}
  end

  defp moved_away(context) do
    thread = World.thread(context, "Coming back")

    World.put_entity(context, "Coming back", "thread", thread["id"], %{
      "s" => Map.put(thread, "movedTo", %{"label" => "elsewhere"})
    })

    Store.put_meta("test.flush", "1")
  end

  defp v1_event(id, at, {type, payload}, version \\ 2) do
    %{
      "aggregateKind" => "thread",
      "streamId" => id,
      "eventType" => type,
      "occurredAt" => at,
      "payloadJson" => JSON.encode!(payload),
      "applicationEventVersion" => version
    }
  end

  defp v1_archive(id, title, project, events) do
    %{
      "format" => "hal-c2-thread-export",
      "version" => 1,
      "thread" => %{
        "id" => id,
        "title" => title,
        "sourceProjectId" => project.id,
        "sourceWorkspaceRoot" => project.root
      },
      "events" => events,
      "attachments" => [],
      "terminalLogs" => []
    }
  end

  defp thread_file(context, contents) do
    file = Path.join(Mc.tmp_dir(context.mc, "thread-file"), "filed.hal-c2-thread")
    File.write!(file, contents)
    Map.put(context, :thread_file, file)
  end

  step "the MC counts {int} turn(s) for the thread that came back",
       %{args: [count]} = context do
    id = World.thread_id(context, "Coming back")
    Store.put_meta("test.flush", "1")

    assert [{^id, _day, ^count}] =
             Store.path()
             |> Store.typed_messages_since("2000-01-01")
             |> Enum.filter(&(elem(&1, 0) == id))

    context
  end

  step "the MC counts {int} turn(s) for {string}", %{args: [count, title]} = context do
    id = context.t3.ids[title]
    Store.put_meta("test.flush", "1")

    assert [{^id, _day, ^count}] =
             Store.path()
             |> Store.typed_messages_since("2000-01-01")
             |> Enum.filter(&(elem(&1, 0) == id))

    context
  end

  step "the MC has read its older threads", context do
    :ok = HalC2.Search.backfill()
    context
  end

  # --- what the model says -----------------------------------------------------------

  step "text generation charts the request from the MC's threads", context do
    writes(context, %{
      "source" => "turns_by_week",
      "type" => "bar",
      "title" => "Weekly turns",
      "chart" => ""
    })
  end

  step "text generation charts the request from the MC's threads and invents the values",
       context do
    writes(context, %{
      "source" => "turns_by_week",
      "type" => "bar",
      "title" => "Weekly turns",
      "chart" => JSON.encode!(data(%{"May" => 999}))
    })
  end

  step "text generation charts the request from the dataset {string}", %{args: [id]} = context do
    writes(context, %{"source" => id, "type" => "bar", "title" => "Counted", "chart" => ""})
  end

  step "text generation says the request cannot be answered", context do
    writes(context, %{"source" => "none", "type" => "bar", "title" => "None", "chart" => ""})
  end

  step ~r/^text generation answers with a (?<type>bar|line) chart of (?<points>.+)$/,
       %{args: [type, points]} = context do
    title = if type == "line", do: "Signups", else: "Chart"
    writes(context, page_answer(type, title, JSON.encode!(data(points(points)))))
  end

  step ~r/^text generation answers with the chart (?<json>\{.+\})$/, %{args: [json]} = context do
    writes(context, page_answer("bar", "Chart", json))
  end

  step ~r/^text generation answers with a chart with (?<what>.+)$/, %{args: [what]} = context do
    {title, data} = over_limit(what)
    writes(context, page_answer("bar", title, JSON.encode!(data)))
  end

  # --- asking ------------------------------------------------------------------------

  step "the user asks for {string} on the page {string}", %{args: [request, title]} = context do
    ask(context, %{"pageId" => page_id(context, title), "request" => request})
  end

  step "the user asks again for {string}", %{args: [request]} = context do
    block = chart_block(context)
    ask(context, %{"pageId" => block["pageId"], "blockId" => block["id"], "request" => request})
  end

  step ~r/^the page "(?<title>[^"]+)" has a chart of (?<points>.+)$/,
       %{args: [title, points]} = context do
    put_chart(context, title, points(points))
    context
  end

  step ~r/^the page "(?<title>[^"]+)" has the blocks "(?<before>[^"]+)" and a chart of (?<points>.+) and the blocks "(?<last>[^"]+)"$/,
       %{args: [title, before, points, last]} = context do
    insert(context, title, before)
    put_chart(context, title, points(points))
    insert(context, title, last)
    context
  end

  step "{string} also says {string}", %{args: [title, text]} = context do
    insert(context, title, text)
    context
  end

  # The title and its line break come first in the text the model reads, up to 8,000 bytes.
  step "{string} has the number {int} where the model stops reading",
       %{args: [title, number]} = context do
    padding = String.duplicate("x", 8_000 - byte_size(title) - 1 - 4)
    insert(context, title, "#{padding} #{number}")
    context
  end

  step "{string} also holds a number too large to read", %{args: [title]} = context do
    insert(context, title, String.duplicate("9", 400))
    context
  end

  step "the user asks to see the numbers behind the chart", context do
    assert chart_block(context)
    context
  end

  step "the user deletes the chart", context do
    payload = %{"spaceId" => context.space, "blockId" => chart_block(context)["id"]}
    {_, context} = World.call!(context, "space.block.delete", payload)
    context
  end

  step "the user edits the text of the chart", context do
    payload = %{
      "spaceId" => context.space,
      "blockId" => chart_block(context)["id"],
      "text" => "x"
    }

    {reply, context} = World.call(context, "space.block.update", payload)
    Map.put(context, :space_reply, reply)
  end

  # --- what the page shows -----------------------------------------------------------

  step "the page shows a {word} chart titled {string}", %{args: [type, title]} = context do
    assert %{"type" => ^type, "title" => ^title} = chart_block(context)["chart"]
    context
  end

  step "the chart says its numbers came from this MC's threads", context do
    assert chart_block(context)["chart"]["source"] =~ "Counted by this MC from its 1 thread"
    context
  end

  step "the chart says its numbers came from this page", context do
    assert chart_block(context)["chart"]["source"] == @page_source
    context
  end

  step "the second client sees a chart titled {string}", %{args: [title]} = context do
    match? = fn frame ->
      frame["t"] == "events" and frame["id"] == @watch and
        Enum.any?(frame["events"], fn [_seq, kind, _id, patch | _] ->
          kind == "block" and patch["s"]["chart"]["title"] == title
        end)
    end

    {_, client} = Mc.await(World.client(context, "second"), match?, 5_000)
    World.put_client(context, "second", client)
  end

  step ~r/^the numbers read (?<points>.+)$/, %{args: [points]} = context do
    assert numbers(chart_block(context)["chart"]) == points(points)
    context
  end

  step "the page shows one chart, between {string} and {string}",
       %{args: [before, last]} = context do
    block = chart_block(context)
    assert [_] = charts(context)

    assert [^before, :chart, ^last | _] =
             state(context)
             |> Blocks.of_page(block["pageId"])
             |> Enum.map(&if(&1["kind"] == "chart", do: :chart, else: &1["text"]))

    context
  end

  step "the page shows no chart", context do
    assert charts(context) == []
    context
  end

  step "the user is told no chart was drawn", context do
    assert {:error, message, %{"_tag" => "SpaceChartError"}} = context.space_reply
    assert message =~ "No chart was drawn"
    context
  end

  step "the chart holds the turns the MC counted", context do
    values = hd(chart_block(context)["chart"]["series"])["values"]
    assert Enum.sum(values) == context.turns_taken
    assert List.last(values) == context.turns_taken
    context
  end

  step "the chart's series is {string} with a value for {string}",
       %{args: [name, label]} = context do
    chart = chart_block(context)["chart"]
    assert [%{"name" => ^name, "values" => values}] = chart["series"]
    assert Enum.at(values, Enum.find_index(chart["labels"], &(&1 == label))) > 0
    context
  end

  step "the chart holds one thread for {string}", %{args: [label]} = context do
    chart = chart_block(context)["chart"]
    assert chart["labels"] == [label]
    assert hd(chart["series"])["values"] == [1]
    assert chart["source"] =~ "from its 1 thread"
    context
  end

  step "the request and the page's text went to the model outside any project's folder",
       context do
    [call] =
      Path.join(context.mc.home, "text-calls.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert call["prompt"] =~ "signups"
    assert call["prompt"] =~ "Signups were 3 in May"
    refute Map.has_key?(context[:projects] || %{}, call["cwd"])
    refute HalC2.Projects.at(call["cwd"])
    context
  end

  step "the largest chart a page can hold takes under 8 KiB on the Space's stream", context do
    assert {:ok, chart} = Chart.validate(largest())
    put_raw_chart(context, chart)
    size = chart_block(context) |> JSON.encode!() |> byte_size()
    assert size < 8 * 1024
    assert byte_size(JSON.encode!(chart)) <= Chart.max_bytes()
    context
  end

  step "the chart's text says {string} is a chart and where its numbers came from",
       %{args: [title]} = context do
    assert chart_block(context)["text"] == "#{title} (a chart; #{@page_source})"
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp writes(context, answer), do: World.text_writers(context, [:codex, :claude], answer)

  defp page_answer(type, title, json),
    do: %{"source" => "page", "type" => type, "title" => title, "chart" => json}

  defp ask(context, input) do
    payload = Map.put(input, "spaceId", context.space)
    {reply, context} = World.call(context, "space.block.visualize", payload)
    Map.put(context, :space_reply, reply)
  end

  # `"May" 3 and "June" 5` as `[{"May", 3}, {"June", 5}]`.
  defp points(text) do
    for [_, label, value] <- Regex.scan(~r/"([^"]+)" (\d+)/, text),
        do: {label, String.to_integer(value)}
  end

  defp data(points) do
    points = Enum.to_list(points)

    %{
      "labels" => Enum.map(points, &elem(&1, 0)),
      "series" => [%{"name" => "s", "values" => Enum.map(points, &elem(&1, 1))}]
    }
  end

  defp over_limit("25 labels"), do: {"Chart", data(for i <- 1..25, do: {"l#{i}", 1})}
  defp over_limit("a 41 byte label"), do: {"Chart", data([{String.duplicate("a", 41), 1}])}
  defp over_limit("a 121 byte title"), do: {String.duplicate("a", 121), data([{"a", 1}])}

  defp over_limit("5 series") do
    series = for i <- 1..5, do: %{"name" => "s#{i}", "values" => [1]}
    {"Chart", %{"labels" => ["a"], "series" => series}}
  end

  defp largest do
    wide = &String.duplicate("é", div(&1, 2))
    labels = for i <- 1..24, do: wide.(36) <> String.pad_leading("#{i}", 4, "0")

    %{
      "type" => "line",
      "title" => wide.(120),
      "request" => wide.(200),
      "source" => wide.(160),
      "labels" => labels,
      "series" =>
        for i <- 1..4 do
          name = wide.(38) <> "s#{i}"
          %{"name" => name, "values" => for(_ <- 1..24, do: 123_456_789_012.34567)}
        end
    }
  end

  defp put_chart(context, title, points) do
    put_raw_chart(
      context,
      %{
        "type" => "bar",
        "title" => "Signups",
        "request" => "signups",
        "source" => @page_source,
        "labels" => Enum.map(points, &elem(&1, 0)),
        "series" => [%{"name" => "Signups", "values" => Enum.map(points, &elem(&1, 1))}]
      },
      title
    )
  end

  defp put_raw_chart(context, chart, title \\ "Status") do
    assert {:ok, _} = Space.put_chart(context.space, page_id(context, title), chart, nil)
  end

  defp insert(context, title, text) do
    spec = %{"kind" => "paragraph", "text" => text}
    assert {:ok, _} = Space.insert_block(context.space, page_id(context, title), spec)
  end

  defp numbers(%{"labels" => labels, "series" => [%{"values" => values}]}),
    do: Enum.zip(labels, values)

  defp state(context), do: Streams.state(Space.stream_id(context.space))

  defp charts(context) do
    for block <- StreamState.list(state(context), "block"), block["kind"] == "chart", do: block
  end

  defp chart_block(context) do
    case charts(context) do
      [block] -> block
      other -> flunk("expected one chart, found #{length(other)}")
    end
  end

  defp page_id(context, title) do
    page =
      state(context)
      |> StreamState.list("page")
      |> Enum.find(&(&1["title"] == title))

    (page || flunk("no page #{inspect(title)}"))["id"]
  end
end
