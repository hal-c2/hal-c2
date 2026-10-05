defmodule HalC2.Steps.Threads do
  @moduledoc "Steps for `features/threads/`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Orchestration.{LimitRecovery, Settlement}
  alias HalC2.Projection.JS
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # --- settle.feature ------------------------------------------------------------------

  step "the auto-settle rule is {string}", %{args: [rule]} = context do
    [days] = Regex.run(~r/after (\d+) days? of inactivity/, rule, capture: :all_but_first)

    context
    |> settings()
    |> write_settings(%{"sidebarAutoSettleAfterDays" => String.to_integer(days)})
  end

  step "the environment settles threads after {int} days", %{args: [days]} = context do
    context |> settings() |> write_settings(%{"sidebarAutoSettleAfterDays" => days})
  end

  step "the project {string} settles threads after {int} day(s)",
       %{args: [title, days]} = context do
    id = World.project(context, title).id

    context
    |> settings()
    |> write_settings(%{
      "projectSettingsOverrides" => %{id => %{"sidebarAutoSettleAfterDays" => days}}
    })
  end

  step "{string} has had no activity for {int} day(s)", %{args: [thread, days]} = context do
    at = World.iso_from_now(-World.days(days) - 60_000)
    context = World.patch_thread(context, thread, %{"createdAt" => at})
    World.add_message(context, thread, "user", "Ship it", at)
  end

  step "{string} is linked to a pull request", %{args: [thread]} = context do
    link(context, thread, 5)
  end

  step "{string} is on a branch with an open pull request", %{args: [thread]} = context do
    World.patch_thread(context, thread, %{
      "branchPullRequest" => %{
        "projectId" => World.project(context, "shop").id,
        "host" => "github.com",
        "repository" => "acme/shop",
        "number" => 5,
        "url" => "https://github.com/acme/shop/pull/5",
        "snapshot" => %{"state" => "open", "title" => "PR 5", "syncedAt" => World.iso_from_now(0)}
      }
    })
  end

  step "{string} is pinned", %{args: [thread]} = context do
    World.patch_thread(context, thread, %{"pinnedAt" => World.iso_from_now(-1000)})
  end

  step "{string} stays active and pinned", %{args: [thread]} = context do
    row = World.row(context, thread)
    assert row["settledOverride"] in [nil, "active"]
    assert row["pinnedAt"] != nil
    context
  end

  step "{string} settled automatically after {int} days", %{args: [thread, days]} = context do
    settle_automatically(context, thread, days)
  end

  step "the user changes the rule to {string}", %{args: [rule]} = context do
    [days] = Regex.run(~r/after (\d+) days? of inactivity/, rule, capture: :all_but_first)
    write_settings(context, %{"sidebarAutoSettleAfterDays" => String.to_integer(days)})
  end

  step "{string} stays settled", %{args: [thread]} = context do
    :ok = Settlement.sweep()
    assert World.row(context, thread)["settledOverride"] == "settled"
    context
  end

  # A linked pull request merging is the relevant change here; the settlement
  # service sweeps that thread on its own, with no sweep asked for.
  step "an agent run ends, a pull request changes or the auto-settle settings change",
       context do
    thread = "Ship checkout"
    context = context |> settings() |> link(thread, 5)
    :ok = Settlement.sweep()
    assert World.row(context, thread)["settledOverride"] in [nil, "active"]
    sync(context, thread, 5, %{"state" => "merged", "mergedAt" => World.iso_from_now(0)})
  end

  step "the settle sweep runs without waiting for the next minute", context do
    World.await_row(
      World.thread_id(context, "Ship checkout"),
      &(&1["settledOverride"] == "settled")
    )

    context
  end

  step "the pull request is merged", context do
    sync(context, "Ship checkout", 5, %{"state" => "merged", "mergedAt" => World.iso_from_now(0)})
  end

  step "the user has not written since the pull request was closed", context do
    sync(context, "Ship checkout", 5, %{"state" => "closed", "closedAt" => World.iso_from_now(0)})
  end

  step "{string} was linked to a pull request that merged last week",
       %{args: [thread]} = context do
    context = link(context, thread, 5)

    sync(context, thread, 5, %{
      "state" => "merged",
      "mergedAt" => World.iso_from_now(-World.days(7))
    })
  end

  step "{string} settled automatically", %{args: [thread]} = context do
    settle_automatically(context, thread, 3)
  end

  step "the settle sweep decided to settle {string}", %{args: [thread]} = context do
    context =
      World.add_message(context, thread, "user", "Ship it", World.iso_from_now(-World.days(4)))

    row = World.row(context, thread)

    Map.put(context, :pending_settle, %{
      "type" => "thread.auto-settle",
      "commandId" => "server:auto-settle:#{row["id"]}:#{HalC2.Environment.uuid4()}",
      "threadId" => row["id"],
      "snapshotAt" => row["updatedAt"],
      "settledAt" => row["latestUserMessageAt"]
    })
  end

  step "the user writes in {string} before the settle is applied", %{args: [thread]} = context do
    context = World.add_message(context, thread, "user", "One more thing")
    assert {:error, _} = HalC2.Orchestration.dispatch(context.pending_settle)
    context
  end

  step "{string} has an agent run in progress", %{args: [thread]} = context do
    World.add_run(context, thread, "running")
  end

  step "{string} is waiting for an approval or an answer", %{args: [thread]} = context do
    id = "rr-#{System.unique_integer([:positive])}"
    at = World.iso_from_now(0)

    World.put_entity(context, thread, "runtime-request", id, %{
      "s" => %{
        "id" => id,
        "threadId" => World.thread_id(context, thread),
        "kind" => "approval",
        "status" => "pending",
        "createdAt" => at,
        "updatedAt" => at
      }
    })
  end

  step "{string} is still snoozed", %{args: [thread]} = context do
    World.patch_thread(context, thread, %{
      "snoozedAt" => World.iso_from_now(-1000),
      "snoozedUntil" => World.iso_from_now(World.days(1))
    })
  end

  step "{string} received a message from the user just now", %{args: [thread]} = context do
    World.add_message(context, thread, "user", "Also this")
  end

  step "the user sends a new message in {string}", %{args: [thread]} = context do
    World.add_message(context, thread, "user", "Also this")
  end

  step "the user un-settles {string}", %{args: [thread]} = context do
    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.unsettle",
        "threadId" => World.thread_id(context, thread)
      })

    World.await_row(World.thread_id(context, thread), &(&1["settledOverride"] == "active"))
    context
  end

  step "the settle sweep runs", context do
    context = settings(context)
    :ok = Settlement.sweep()
    context
  end

  step "{string} is settled automatically", %{args: [thread]} = context do
    context = settings(context)
    :ok = Settlement.sweep()
    id = World.thread_id(context, thread)
    World.await_row(id, &(&1["settledOverride"] == "settled"))
    context
  end

  step "{string} stays active", %{args: [thread]} = context do
    assert World.row(context, thread)["settledOverride"] in [nil, "active"]
    context
  end

  # --- pinning-and-order.feature -----------------------------------------------------

  # Listed in display order: the newest thread tops the active list, so Alpha is newest.
  # A second device ("phone") follows the sidebar from the start.
  step "a connected environment with the active threads {string}, {string} and {string}",
       %{args: titles} = context do
    context = World.create_project(context, "shop")

    titles
    |> Enum.with_index(1)
    |> Enum.reduce(context, fn {title, age}, context ->
      context
      |> World.create_thread(title, "shop")
      |> World.patch_thread(title, %{"createdAt" => World.iso_from_now(-age * 1_000)})
    end)
    |> then(&World.put_client(&1, World.client(&1)))
    |> World.watch_shell("phone")
    |> Map.put(:listed, titles)
  end

  step "{string} and {string} are pinned in that order", %{args: titles} = context do
    pin_in_order(context, titles)
  end

  step "{string}, {string} and {string} are pinned in that order", %{args: titles} = context do
    pin_in_order(context, titles)
  end

  step "a client moves {string} above {string}", %{args: [moved, target]} = context do
    move(context, moved, fn order -> List.insert_at(order, index(order, target), moved) end)
  end

  step "a client moves {string} between {string} and {string}",
       %{args: [moved, first, second]} = context do
    move(context, moved, fn order ->
      assert index(order, second) == index(order, first) + 1
      List.insert_at(order, index(order, second), moved)
    end)
  end

  step "the pinned threads are listed as {string}, {string}", %{args: titles} = context do
    assert order(context, :pinned, rows(context)) == titles
    Map.put(context, :expected_order, {:pinned, titles})
  end

  step "the order survives a refresh", context do
    {section, titles} = context.expected_order
    fresh = World.fresh_shell(context)

    assert order(context, section, Map.new(context.threads, fn {t, id} -> {t, fresh[id]} end)) ==
             titles

    context
  end

  step "the active threads are listed with {string} before {string}",
       %{args: [first, second]} = context do
    order = order(context, :active, rows(context))
    assert index(order, first) + 1 == index(order, second)
    assert World.row(context, first)["activeOrderKey"] != nil
    Map.put(context, :expected_order, {:active, order})
  end

  # The phone saw each key the move wrote, and sorts to the same order with them.
  step "every connected device sees the same order", context do
    {section, titles} = context.expected_order
    ids = Map.new(context.threads, fn {title, id} -> {id, title} end)
    {pushed, context} = phone_rows(context, ids, context.writes, %{})

    seen =
      Map.new(context.threads, fn {title, id} ->
        {title, pushed[id] || World.row(context, title)}
      end)

    assert order(context, section, seen) == titles
    context
  end

  step "only {string} is changed", %{args: [moved]} = context do
    assert [{^moved, _key}] = context.writes

    for {title, entity} <- context.before_move,
        title != moved,
        do: assert(World.thread(context, title) == entity)

    assert World.thread(context, moved)["pinOrderKey"] !=
             context.before_move[moved]["pinOrderKey"]

    context
  end

  defp pin_in_order(context, titles) do
    titles
    |> Enum.zip(spread_keys(length(titles)))
    |> Enum.reduce(context, fn {title, key}, context ->
      id = World.thread_id(context, title)

      {{:ok, _}, context} =
        World.dispatch(context, %{"type" => "thread.pin", "threadId" => id, "orderKey" => key})

      World.await_row(id, &(&1["pinOrderKey"] == key))
      context
    end)
  end

  # Moves a thread as a client does (`planPinnedReorder` in threadSort.ts): one key
  # between its new neighbours, or fresh keys for the section when a neighbour has none.
  defp move(context, moved, place) do
    section = if World.row(context, moved)["pinnedAt"], do: :pinned, else: :active

    {type, field} =
      if section == :pinned,
        do: {"thread.pin.reorder", "pinOrderKey"},
        else: {"thread.active.reorder", "activeOrderKey"}

    rows = rows(context)
    order = place.(List.delete(order(context, section, rows), moved))
    keys = Map.new(order, &{&1, rows[&1][field]})
    writes = plan(order, keys, moved)
    before = Map.new(context.threads, fn {title, _} -> {title, World.thread(context, title)} end)

    context =
      Enum.reduce(writes, context, fn {title, key}, context ->
        id = World.thread_id(context, title)

        {{:ok, _}, context} =
          World.dispatch(context, %{"type" => type, "threadId" => id, "orderKey" => key})

        World.await_row(id, &(&1[field] == key))
        context
      end)

    Map.merge(context, %{writes: writes, before_move: before})
  end

  defp phone_rows(context, _ids, [], seen), do: {seen, context}

  defp phone_rows(context, ids, writes, seen) do
    client = World.client(context, "phone")
    {frame, client} = Mc.await(client, &(&1["t"] == "shell.rows"))
    context = World.put_client(context, "phone", client)

    seen =
      for [id, "thread", row] <- frame["rows"], Map.has_key?(ids, id), into: seen, do: {id, row}

    left =
      Enum.reject(writes, fn {title, key} ->
        row = seen[World.thread_id(context, title)]
        row && key in [row["pinOrderKey"], row["activeOrderKey"]]
      end)

    phone_rows(context, ids, left, seen)
  end

  defp rows(context),
    do: Map.new(context.threads, fn {title, _} -> {title, World.row(context, title)} end)

  # The sidebar's order for a section of this scenario's threads (threadSort.ts).
  defp order(_context, :pinned, rows) do
    rows
    |> Enum.filter(fn {_, row} -> row["pinnedAt"] != nil and row["archivedAt"] == nil end)
    |> Enum.sort_by(fn {_, row} ->
      key = row["pinOrderKey"]
      {key == nil, key || "", -HalC2.Projection.JS.epoch_ms(row["createdAt"]), row["id"]}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp order(_context, :active, rows) do
    rows
    |> Enum.filter(fn {_, row} -> row["pinnedAt"] == nil and row["archivedAt"] == nil end)
    |> Enum.sort_by(fn {_, row} ->
      key = row["activeOrderKey"]

      anchor =
        max(
          HalC2.Projection.JS.epoch_ms(row["createdAt"]),
          HalC2.Projection.JS.epoch_ms(row["unsettledAt"]) || 0
        )

      {key != nil, key || "", -anchor, row["id"]}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp index(order, title),
    do: Enum.find_index(order, &(&1 == title)) || flunk("#{title} is not listed")

  defp plan(order, keys, moved) do
    at = index(order, moved)
    before = if at > 0, do: Enum.at(order, at - 1)
    after_ = Enum.at(order, at + 1)

    if (before == nil or keys[before] != nil) and (after_ == nil or keys[after_] != nil) do
      [{moved, midpoint(keys[before] || "", keys[after_] || "")}]
    else
      order
      |> Enum.zip(spread_keys(length(order)))
      |> Enum.reject(fn {title, key} -> keys[title] == key end)
    end
  end

  # `pinOrderMidpoint` from threadSort.ts: base-26 digit strings as fractions in (0, 1).
  defp midpoint(a, b) do
    n = if b == "", do: 0, else: shared_prefix(a, b, 0)

    if n > 0 do
      binary_part(b, 0, n) <> midpoint(tail(a, n), tail(b, n))
    else
      da = if a == "", do: 0, else: :binary.first(a) - ?a
      db = if b == "", do: 26, else: :binary.first(b) - ?a

      cond do
        db - da > 1 -> <<?a + round((da + db) / 2)>>
        byte_size(b) > 1 -> binary_part(b, 0, 1)
        true -> <<?a + da>> <> midpoint(tail(a, 1), "")
      end
    end
  end

  defp shared_prefix(a, b, n) do
    digit = if n < byte_size(a), do: :binary.at(a, n), else: ?a
    if n < byte_size(b) and digit == :binary.at(b, n), do: shared_prefix(a, b, n + 1), else: n
  end

  defp tail(s, n) when byte_size(s) <= n, do: ""
  defp tail(s, n), do: binary_part(s, n, byte_size(s) - n)

  # `generateSpreadPinOrderKeys` from threadSort.ts.
  defp spread_keys(count) do
    width = Stream.iterate(2, &(&1 + 1)) |> Enum.find(&(Integer.pow(26, &1) > (count + 1) * 2))
    step = Integer.pow(26, width) / (count + 1)

    for i <- 1..count do
      value = round(step * i)
      value = if rem(value, 26) == 0, do: value + 1, else: value
      digits = Integer.digits(value, 26)
      padded = List.duplicate(0, width - length(digits)) ++ digits
      for digit <- padded, into: "", do: <<?a + digit>>
    end
  end

  # --- snooze.feature --------------------------------------------------------------

  step "the local time is Wednesday {int}:{int}", %{args: [hour, minute]} = context do
    today = Date.utc_today()
    ahead = Integer.mod(3 - Date.day_of_week(today), 7)
    date = Date.add(today, if(ahead == 0, do: 7, else: ahead))
    context = World.watch_shell(context, "phone")
    Map.put(context, :local_now, NaiveDateTime.new!(date, Time.new!(hour, minute, 0)))
  end

  step "{string} is snoozed until Wednesday {int}:{int}",
       %{args: [thread, hour, minute]} = context do
    until =
      World.local_time(context, "Wednesday #{hour}:#{String.pad_leading("#{minute}", 2, "0")}")

    assert World.row(context, thread)["snoozedUntil"] == until
    assert World.thread(context, thread)["snoozedAt"] != nil
    context
  end

  step "every connected client lists it as snoozed", context do
    until = context.snoozed_until

    {_, context} =
      World.await_shell_row(context, "phone", "Refactor cart", &(&1["snoozedUntil"] == until))

    assert World.fresh_shell(context)[World.thread_id(context, "Refactor cart")]["snoozedUntil"] ==
             until

    context
  end

  step "{string} is snoozed until tomorrow", %{args: [thread]} = context do
    until = World.local_time(context, "tomorrow")
    id = World.thread_id(context, thread)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.snooze",
        "threadId" => id,
        "snoozedUntil" => until
      })

    World.await_row(id, &(&1["snoozedUntil"] == until))
    context
  end

  # --- unread-and-status.feature ---------------------------------------------------

  step "{string} finished work the user has not seen", %{args: [thread]} = context do
    context = World.add_run(context, thread, "completed")
    row = World.row(context, thread)
    assert row["lastVisitedAt"] == nil
    World.watch_shell(context, "phone")
  end

  step "the user opens {string} on the desktop", %{args: [thread]} = context do
    visit(context, thread, World.iso_from_now(0), "desktop")
  end

  step "{string} is read on the phone too", %{args: [thread]} = context do
    completed = context |> World.runs(thread) |> List.last() |> Map.fetch!("completedAt")

    {_, context} =
      World.await_shell_row(
        context,
        "phone",
        thread,
        &(&1["lastVisitedAt"] != nil and &1["lastVisitedAt"] >= completed)
      )

    context
  end

  step "{string} was visited at {int}:{int} on the desktop",
       %{args: [thread, hour, minute]} = context do
    visit(context, thread, clock(hour, minute), "desktop")
  end

  step "the phone reports a visit at {int}:{int}", %{args: [hour, minute]} = context do
    visit(context, "Build search", clock(hour, minute), "phone")
  end

  step "{string} stays read as of {int}:{int}", %{args: [thread, hour, minute]} = context do
    assert World.row(context, thread)["lastVisitedAt"] == clock(hour, minute)

    assert World.fresh_shell(context)[World.thread_id(context, thread)]["lastVisitedAt"] ==
             clock(hour, minute)

    context
  end

  step "{string} is read", %{args: [thread]} = context do
    context = visit(context, thread, World.iso_from_now(0), "default")
    context |> World.watch_shell("desktop") |> World.watch_shell("phone")
  end

  step "{string} is unread on every device", %{args: [thread]} = context do
    Enum.reduce(["desktop", "phone"], context, fn device, context ->
      {_, context} = World.await_shell_row(context, device, thread, &(&1["lastVisitedAt"] == nil))
      context
    end)
  end

  defp visit(context, thread, at, device) do
    id = World.thread_id(context, thread)

    {{:ok, _}, context} =
      World.dispatch(
        context,
        %{"type" => "thread.visit", "threadId" => id, "visitedAt" => at},
        device
      )

    World.await_row(id, &(&1["lastVisitedAt"] != nil and &1["lastVisitedAt"] >= at))
    context
  end

  # Today at a wall-clock time, as the ISO text a client sends.
  defp clock(hour, minute),
    do:
      Date.utc_today()
      |> NaiveDateTime.new!(Time.new!(hour, minute, 0))
      |> DateTime.from_naive!("Etc/UTC")
      |> Map.put(:microsecond, {0, 3})
      |> DateTime.to_iso8601()

  # --- archive-delete.feature ------------------------------------------------------

  step "{string} has a queued turn", %{args: [thread]} = context do
    context = World.working_thread(context, thread)
    {{:ok, _}, context} = World.send_message(context, thread, "Queued follow-up")
    [{_, run}] = World.queued(context, thread)
    Map.merge(context, %{queued_run: run["id"], queued_thread: thread})
  end

  step "the queued turn is cancelled", context do
    {title, run} = {context.queued_thread, context.queued_run}

    World.await_thread(
      context,
      title,
      &(HalC2.StreamState.get(&1, "run")[run]["status"] == "cancelled")
    )

    context
  end

  step "{string} and {string} are archived", %{args: titles} = context do
    Enum.reduce(titles, context, fn title, context ->
      context =
        if context.threads[title], do: context, else: World.create_thread(context, title, "shop")

      id = World.thread_id(context, title)
      {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => id})
      World.await_row(id, &(&1["archivedAt"] != nil))
      context
    end)
    |> Map.put(:archived, titles)
  end

  # The client saw the archived list before "Old spike" was archived.
  step "{string} was archived after the client last looked", %{args: [thread]} = context do
    {result, context} = World.call!(context, "orchestration.getArchivedShellSnapshot")
    id = World.thread_id(context, thread)
    refute Enum.any?(result["threads"], &(&1["id"] == id))
    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => id})
    World.await_row(id, &(&1["archivedAt"] != nil))
    context
  end

  step "a client asks for the archived threads", context do
    {result, context} = World.call!(context, "orchestration.getArchivedShellSnapshot")
    Map.put(context, :archived_list, result)
  end

  step "both threads are returned with their project", context do
    %{"threads" => threads, "projects" => projects} = context.archived_list
    ids = Enum.map(context.archived, &World.thread_id(context, &1))
    project = World.project(context, "shop").id
    assert Enum.sort(Enum.map(threads, & &1["id"])) == Enum.sort(ids)
    assert Enum.all?(threads, &(&1["projectId"] == project))
    assert Enum.any?(projects, &(&1["id"] == project))
    context
  end

  step "{string} is in the answer", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    assert Enum.any?(context.archived_list["threads"], &(&1["id"] == id))
    context
  end

  # Clients drop deleted rows (`shellShape.ts`); a fresh client gets it marked deleted.
  step "no client lists {string}", %{args: [thread]} = context do
    assert World.fresh_shell(context)[World.thread_id(context, thread)]["deletedAt"] != nil
    context
  end

  # The MC keeps the stream, as the TypeScript server does; what a client reads
  # from it is the thread marked deleted, which it treats as `thread.deleted`.
  step "its history can no longer be read", context do
    id = World.thread_id(context, "Old spike")

    client =
      context.mc
      |> Mc.connect()
      |> Mc.sub(1, %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => id})

    rows = snapshot_rows(client, [])
    assert [thread] = for(["thread", ^id, row] <- rows, do: row)
    assert thread["deletedAt"] != nil
    context
  end

  defp snapshot_rows(client, rows) do
    {frame, client} = Mc.await(client, &(&1["t"] == "snapshot"))
    rows = rows ++ frame["rows"]
    if frame["done"], do: rows, else: snapshot_rows(client, rows)
  end

  step "the agent session is stopped", context do
    id = World.thread_id(context, "Old spike")
    state = World.stream(context, "Old spike")

    assert Enum.all?(
             HalC2.StreamState.list(state, "provider-session"),
             &(&1["status"] == "stopped")
           )

    refute Enum.any?(
             HalC2.StreamState.list(state, "run"),
             &(&1["status"] in ~w(queued preparing starting running waiting))
           )

    assert Registry.lookup(HalC2.Codex.Registry, id) == []
    context
  end

  # --- search.feature --------------------------------------------------------------

  # Each thread starts with the user asking for what its title says.
  step "a connected environment with the threads {string} and {string} in the project {string}",
       %{args: [first, second, project]} = context do
    context = World.create_project(context, project)

    Enum.reduce([first, second], context, fn title, context ->
      context
      |> World.create_thread(title, project)
      |> World.add_message(title, "user", title)
    end)
  end

  step "the agent in {string} said {string}", %{args: [thread, text]} = context do
    World.add_message(context, thread, "assistant", text)
  end

  step "a client searches threads for {string}", %{args: [query]} = context do
    search(context, query)
  end

  step "{string} is returned with the matching words in a short excerpt",
       %{args: [thread]} = context do
    [match] = matches(context, thread)
    assert match["snippet"] =~ context.query
    assert String.length(match["snippet"]) <= 240
    assert match["source"] == "assistant"
    context
  end

  step "the user and the agent both wrote {string} in {string}",
       %{args: [text, thread]} = context do
    context
    |> World.add_message(
      thread,
      "user",
      "Can we add a #{text} to the token endpoint?",
      World.iso_from_now(-2_000)
    )
    |> World.add_message(thread, "assistant", "Added a #{text} of ten requests a minute.")
  end

  step "{string} is returned once", %{args: [thread]} = context do
    assert [_] = matches(context, thread)
    Map.put(context, :match_thread, thread)
  end

  step "its excerpt comes from the user's message", context do
    [match] = matches(context, context.match_thread)
    assert match["source"] == "user"
    assert match["snippet"] == "Can we add a #{context.query} to the token endpoint?"
    context
  end

  step "the agent is still writing {string} in {string}", %{args: [text, thread]} = context do
    id = "msg-streaming-#{System.unique_integer([:positive])}"

    context
    |> World.add_message(thread, "assistant", "Looking into the #{text} now", nil, %{
      "id" => id,
      "streaming" => true
    })
    |> Map.put(:streaming_message, {thread, id})
  end

  step "{string} is not returned until the message is finished", %{args: [thread]} = context do
    assert matches(context, thread) == []
    {^thread, id} = context.streaming_message

    context =
      World.put_entity(context, thread, "message", id, %{
        "s" => %{"streaming" => false, "updatedAt" => World.iso_from_now(0)}
      })

    context = search(context, context.query)
    assert [_] = matches(context, thread)
    context
  end

  # The index is emptied behind the MC's back, as a log from before it existed.
  step "the environment has threads written before it kept a search index", context do
    context =
      context
      |> World.create_project("shop")
      |> World.create_thread("Old work", "shop")
      |> World.add_message("Old work", "user", "migrate the invoices table")

    # Waits out the store's queued writes (the index is written asynchronously).
    path = HalC2.Store.path()
    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "DELETE FROM messages; DELETE FROM meta WHERE key = 'messages_indexed'"
      )

    :ok = Exqlite.Sqlite3.close(db)

    context = search(context, "invoices table")
    assert context.matches == []
    context
  end

  step "the environment starts", context do
    %{context | mc: Mc.restart(context.mc), clients: %{}}
  end

  step "the old threads are indexed once and can be searched", context do
    context = search(context, "invoices table")
    assert [_] = matches(context, "Old work")
    assert HalC2.Store.meta(HalC2.Store.path(), "messages_indexed") == "1"
    context
  end

  step "{int} threads mention {string}", %{args: [count, text]} = context do
    Enum.reduce(1..count, context, fn n, context ->
      title = "Thread #{n}"

      context
      |> World.create_thread(title)
      |> World.add_message(title, "user", "please #{text} module #{n}")
    end)
  end

  step "{int} threads are returned", %{args: [count]} = context do
    assert length(context.matches) == count
    assert context.matches |> Enum.map(& &1["threadId"]) |> Enum.uniq() |> length() == count
    context
  end

  # --- titles.feature --------------------------------------------------------------

  step "a new thread titled {string}", %{args: [title]} = context do
    refute Map.has_key?(context.threads, title)
    Map.put(context, :draft, title)
  end

  step "the thread gets a generated title describing the login loop", context do
    title = settled_title(context)["title"]
    assert title =~ ~r/login/i and title =~ ~r/loop/i
    context
  end

  step "the title generator fails twice and then succeeds", context do
    World.title_generator(context, ["fail", "fail", "Fix the login redirect loop"])
  end

  step "the title generator answers {string}", %{args: [answer]} = context do
    World.title_generator(context, [answer])
  end

  step "the user sends the first message of a new thread", context do
    context = if context[:title_generator], do: context, else: World.title_generator(context)

    {{:ok, _}, context} =
      World.launch_thread(context, "shop", "The login page loops after OAuth callback", %{
        "title" => "Login loops after OAuth",
        "generateTitle" => true
      })

    Map.put(context, :current, "Login loops after OAuth")
  end

  step "the thread gets the generated title", context do
    assert settled_title(context)["title"] == "Fix the login redirect loop"
    context
  end

  # Two failed attempts are retried quietly: the thread is titled and not left
  # marked as titling, and its first turn still ran.
  step "no error is shown to the user", context do
    assert length(World.title_calls(context)) == 3
    assert settled_title(context)["titleRegeneration"] == nil
    World.await_runs(context, World.current(context), ["completed"])
    context
  end

  step "the thread keeps its previous title", context do
    assert settled_title(context)["title"] == "Login loops after OAuth"
    assert length(World.title_calls(context)) == 1
    context
  end

  step "{string} has a conversation about rate limiting", %{args: [thread]} = context do
    context
    |> World.add_message(
      thread,
      "user",
      "How should we rate limit the login endpoint?",
      World.iso_from_now(-2_000)
    )
    |> World.add_message(thread, "assistant", "A token bucket per IP rate limits logins well.")
    |> Map.put(:current, thread)
  end

  step "the user asks for a new title", context do
    context = if context[:title_generator], do: context, else: World.title_generator(context)
    id = World.thread_id(context, World.current(context))

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.metadata.update",
        "threadId" => id,
        "regenerateTitle" => true
      })

    context
  end

  step "the thread gets a title describing rate limiting", context do
    assert settled_title(context)["title"] =~ ~r/rate limit/i
    context
  end

  step "the thread keeps the title {string}", %{args: [title]} = context do
    assert settled_title(context)["title"] == title
    context
  end

  step "the thread is no longer marked as regenerating", context do
    assert settled_title(context)["titleRegeneration"] == nil

    World.await_row(
      World.thread_id(context, World.current(context)),
      &(&1["titleRegeneration"] == nil)
    )

    context
  end

  step "the thread has no messages", context do
    assert HalC2.StreamState.get(World.stream(context, World.current(context)), "message") == %{}
    context
  end

  # With nothing to title from, the generator is not asked.
  step "the thread keeps its title", context do
    assert settled_title(context)["title"] == World.current(context)
    assert World.title_calls(context) == []
    context
  end

  step "the agent renames its thread to {string}", %{args: [title]} = context do
    Mc.ensure(HalC2.Mcp)

    %{authorization: auth} =
      HalC2.Mcp.server(World.thread_id(context, World.current(context)), "codex")

    {200, %{"result" => result}} =
      HalC2.Mcp.handle(
        auth,
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "hal_c2_thread_update",
            "arguments" => %{"action" => "rename", "title" => title}
          }
        })
      )

    assert result["isError"] != true, inspect(result)
    context
  end

  step "the thread is listed as {string}", %{args: [title]} = context do
    World.await_row(World.thread_id(context, World.current(context)), &(&1["title"] == title))

    assert World.fresh_shell(context)[World.thread_id(context, World.current(context))]["title"] ==
             title

    context
  end

  step "the thread's worktree changed after the client last saw it", context do
    title = World.current(context)
    seen = World.row(context, title)["worktreePath"]
    moved = Mc.tmp_dir(context.mc, "moved-worktree")

    context
    |> World.patch_thread(title, %{"worktreePath" => moved})
    |> Map.put(:seen_worktree, seen)
  end

  step "a client updates the thread expecting the old worktree", context do
    {reply, context} =
      World.dispatch(context, %{
        "type" => "thread.metadata.update",
        "threadId" => World.thread_id(context, World.current(context)),
        "title" => "Fix login for real",
        "expectedWorktreePath" => context.seen_worktree
      })

    Map.put(context, :reply, reply)
  end

  step "the update is rejected with {string}", %{args: [message]} = context do
    assert {:error, error, _} = context.reply
    assert error =~ message
    assert World.thread(context, World.current(context))["title"] == World.current(context)
    context
  end

  # --- creating.feature ------------------------------------------------------------

  step ~r/^a client launches a thread in "(?<project>[^"]+)" with the (?<strategy>project root|existing worktree|new worktree) workspace$/,
       %{args: [project, strategy]} = context do
    root = World.project(context, project).root

    {strategy, context} =
      case strategy do
        "project root" ->
          {%{"type" => "root"}, context}

        "existing worktree" ->
          path = Path.join(Mc.tmp_dir(context.mc, "worktrees"), "cart")
          World.git!(root, ["worktree", "add", "-q", "-b", "feature/cart", path])

          {%{"type" => "existing_worktree", "worktreePath" => path, "branch" => "feature/cart"},
           Map.put(context, :chosen_worktree, path)}

        "new worktree" ->
          {%{"type" => "worktree", "baseRef" => "main"}, World.thread_worktrees(context)}
      end

    launch(context, project, strategy)
  end

  step "the thread is created with the project root as its workspace", context do
    thread = launched_thread(context)
    assert thread["worktreePath"] == nil
    assert agent_cwd(context) == World.project(context).root
    context
  end

  step "the thread is created with the chosen existing worktree as its workspace", context do
    thread = launched_thread(context)
    assert thread["worktreePath"] == context.chosen_worktree
    assert thread["branch"] == "feature/cart"
    assert agent_cwd(context) == context.chosen_worktree
    context
  end

  step "the thread is created with a worktree prepared from the base branch before run",
       context do
    thread = launched_thread(context)
    path = thread["worktreePath"]
    assert path != nil and File.dir?(path)
    root = World.project(context).root
    assert World.git!(path, ~w(rev-parse HEAD)) == World.git!(root, ~w(rev-parse main))
    assert agent_cwd(context) == path
    context
  end

  step "the first message is sent to the agent", context do
    World.await_runs(context, "Launched", ["completed"])
    assert context.launch_text in World.started_turns(context)
    context
  end

  step "a client launches a thread in {string} with a new worktree from {string}",
       %{args: [project, base]} = context do
    context = World.thread_worktrees(context)
    launch(context, project, %{"type" => "worktree", "baseRef" => base})
  end

  # Read from what the thread's stream committed, in order, as a client sees it.
  step "the thread shows that its workspace is being prepared", context do
    history =
      history(
        context,
        &Enum.any?(&1, fn {kind, _, patch} -> kind == "run" and patch["status"] == "running" end)
      )

    assert [{"run", _, %{"status" => "preparing"}} | _] =
             Enum.filter(history, &(elem(&1, 0) == "run"))

    Map.put(context, :history, history)
  end

  step "the agent starts only after the worktree is ready", context do
    history = context.history

    ready =
      Enum.find_index(history, fn {kind, _, patch} ->
        kind == "thread" and is_binary(patch["worktreePath"])
      end)

    started =
      Enum.find_index(history, fn {kind, _, patch} ->
        kind == "run" and patch["status"] in ["starting", "running"]
      end)

    assert ready != nil and started != nil and ready < started
    World.await_runs(context, "Launched", ["completed"])
    assert agent_cwd(context) == launched_thread(context)["worktreePath"]
    context
  end

  step "a client launches a thread with title generation requested", context do
    context = World.title_generator(context)

    launch(context, "shop", %{"type" => "root"}, %{
      "generateTitle" => true,
      "initialMessage" => %{
        "text" => "Checkout totals ignore the discount code",
        "attachments" => []
      }
    })
  end

  step "the thread title is generated from the first message", context do
    context = Map.put(context, :current, "Launched")
    assert settled_title(context)["title"] == "Checkout totals ignore the discount code"
    context
  end

  step "the thread {string} exists", %{args: [id]} = context do
    World.create_thread(context, id, "shop", %{"threadId" => id})
  end

  step "a client creates another thread with the id {string}", %{args: [id]} = context do
    {reply, context} =
      World.dispatch(context, %{
        "type" => "thread.create",
        "threadId" => id,
        "projectId" => World.project(context, "shop").id,
        "title" => "Another",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
      })

    Map.put(context, :reply, reply)
  end

  step "the command is rejected with {string}", %{args: [message]} = context do
    assert {:error, ^message, _} = context.reply
    assert World.thread(context, "t-1")["title"] == "t-1"
    context
  end

  step "an empty draft thread exists for {string}", %{args: [project]} = context do
    context = World.create_thread(context, "Draft", project)
    Map.put(context, :threads_before, project_threads(context, project))
  end

  step "a client launches a thread in {string} and asks to reuse the existing thread",
       %{args: [project]} = context do
    launch(context, project, %{"type" => "root"}, %{
      "title" => "Draft",
      "threadId" => World.thread_id(context, "Draft"),
      "reuseExistingThread" => true
    })
  end

  step "the first message is sent in the existing thread", context do
    state = World.await_runs(context, "Draft", ["completed"])

    assert [%{"text" => text}] =
             HalC2.StreamState.list(state, "message") |> Enum.filter(&(&1["role"] == "user"))

    assert text == context.launch_text
    assert text in World.started_turns(context)
    context
  end

  step "no second thread is created", context do
    assert project_threads(context, "shop") == context.threads_before
    context
  end

  # --- pull-request-links.feature --------------------------------------------------

  # "shop" is a GitHub checkout (acme/shop); `gh` is the fake in test/support.
  step "a connected environment with the thread {string} on the branch {string}",
       %{args: [thread, branch]} = context do
    context = World.create_project(context, "shop")

    World.git!(
      World.project(context, "shop").root,
      ~w(remote add origin https://github.com/acme/shop.git)
    )

    context
    |> gh([])
    |> World.create_thread(thread, "shop", %{"branch" => branch})
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a pull request is opened for {string}", %{args: [branch]} = context do
    open_pull_request(context, branch, 7)
  end

  # With every client gone, so the MC finds it on its own.
  step "the environment looks for pull requests", context do
    for {_, client} <- context.clients, do: Mint.HTTP.close(client.conn)
    discover(%{context | clients: %{}})
  end

  step "{string} is linked to that pull request", %{args: [thread]} = context do
    number = context.branch_pr
    row = World.await_row(World.thread_id(context, thread), &(&1["branchPullRequest"] != nil))
    assert %{"number" => ^number, "repository" => "acme/shop"} = row["branchPullRequest"]
    context
  end

  step "no client needs to be open for this to happen", context do
    assert context.clients == %{}

    assert World.thread(context, World.current(context))["branchPullRequest"]["number"] ==
             context.branch_pr

    context
  end

  step "the environment finds a pull request for {string}", %{args: [branch]} = context do
    context |> open_pull_request(branch, 7) |> discover()
  end

  step "{string} is not linked to it", %{args: [thread]} = context do
    thread = World.thread(context, thread)
    assert thread["branchPullRequest"] == nil
    assert pull_request_numbers(thread) == []
    context
  end

  step "{string} is linked to the pull request for {string}",
       %{args: [thread, branch]} = context do
    context = context |> open_pull_request(branch, 7) |> discover()
    World.await_row(World.thread_id(context, thread), &(&1["branchPullRequest"] != nil))
    context
  end

  step "the user links {string} to pull request {int}", %{args: [thread, number]} = context do
    manual_link(context, thread, number)
  end

  step "{string} is linked to pull request {int} and the branch pull request",
       %{args: [thread, number]} = context do
    assert pull_request_numbers(World.thread(context, thread)) == [context.branch_pr, number]
    context
  end

  # A setup, unless a step just linked it: then it is what the scenario expects.
  step "{string} is linked to pull request {int}", %{args: [thread, number]} = context do
    if context[:agent_link] == number do
      assert number in pull_request_numbers(World.thread(context, thread))
      context
    else
      manual_link(context, thread, number)
    end
  end

  step "the user links {string} to pull request {int} again",
       %{args: [thread, number]} = context do
    before =
      HalC2.Streams.Server.state(HalC2.Streams.ensure(World.thread_id(context, thread))).seq

    context = manual_link(context, thread, number)
    Map.put(context, :seq_before, before)
  end

  step "{string} has one link to pull request {int}", %{args: [thread, number]} = context do
    assert pull_request_numbers(World.thread(context, thread)) == [number]

    assert HalC2.Streams.Server.state(HalC2.Streams.ensure(World.thread_id(context, thread))).seq ==
             context.seq_before

    context
  end

  step "the user unlinks pull request {int} from {string}", %{args: [number, thread]} = context do
    unlink(context, thread, number)
  end

  step "{string} is no longer linked to pull request {int}",
       %{args: [thread, number]} = context do
    refute number in pull_request_numbers(World.thread(context, thread))
    context
  end

  step "{string} is linked to a stack of pull requests", %{args: [thread]} = context do
    stack(context, thread)
  end

  step "the user unlinks one layer of the stack", context do
    unlink(context, World.current(context), 6)
  end

  step "the environment refreshes the stack", context do
    HalC2.PullRequests.Sync.request(%{"repository" => "acme/shop", "number" => 5})
    :ok = HalC2.PullRequests.Sync.sweep()
    context
  end

  step "that layer is not linked again", context do
    thread = World.thread(context, World.current(context))
    assert pull_request_numbers(thread) == [5]

    assert %{"source" => "stack-dismissed"} =
             Enum.find(HalC2.Projection.PullRequests.of(thread), &(&1["number"] == 6))

    context
  end

  step "the user unlinked a layer of the stack from {string}", %{args: [thread]} = context do
    context |> stack(thread) |> unlink(thread, 6)
  end

  step "the user links that layer again", context do
    manual_link(context, World.current(context), 6)
  end

  step "{string} is linked to that layer", %{args: [thread]} = context do
    thread = World.thread(context, thread)
    assert pull_request_numbers(thread) == [5, 6]

    assert %{"source" => "manual"} =
             Enum.find(HalC2.Projection.PullRequests.of(thread), &(&1["number"] == 6))

    context
  end

  step "the agent in {string} opened pull request {int}", %{args: [thread, number]} = context do
    refute number in pull_request_numbers(World.thread(context, thread))
    Map.put(context, :current, thread)
  end

  step "the agent links pull request {int} to its thread", %{args: [number]} = context do
    Mc.ensure(HalC2.Mcp)

    %{authorization: auth} =
      HalC2.Mcp.server(World.thread_id(context, World.current(context)), "codex")

    {200, %{"result" => result}} =
      HalC2.Mcp.handle(
        auth,
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "link_pull_request",
            "arguments" => %{"url" => "https://github.com/acme/shop/pull/#{number}"}
          }
        })
      )

    assert result["isError"] != true, inspect(result)
    Map.put(context, :agent_link, number)
  end

  step "{string} is settled and linked to pull request {int}",
       %{args: [thread, number]} = context do
    context = manual_link(context, thread, number)
    id = World.thread_id(context, thread)

    {{:ok, _}, context} = World.dispatch(context, %{"type" => "thread.settle", "threadId" => id})
    World.await_row(id, &(&1["settledOverride"] == "settled"))
    context
  end

  step "a new pull request is opened for {string}", %{args: [branch]} = context do
    context |> open_pull_request(branch, 44) |> discover()
  end

  step "{string} stays linked to pull request {int}", %{args: [thread, number]} = context do
    assert number in pull_request_numbers(World.thread(context, thread))
    context
  end

  # --- limited-threads.feature -----------------------------------------------------
  # Times are the next such wall-clock time (UTC), so a reset is always ahead of the
  # stop; the recovery sweep (`HalC2.Orchestration.LimitRecovery`) is run with the clock
  # the step names.

  step "a connected environment with the thread {string} on Claude", %{args: [title]} = context do
    context
    |> World.agents()
    |> World.create_project("shop")
    |> World.create_thread(title, nil, %{
      "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "claude-haiku-4-5"}
    })
    |> then(&World.put_client(&1, World.client(&1)))
    |> Map.put(:current, title)
  end

  step ~r/^Claude stops "(?<thread>[^"]+)" on a usage limit that resets at (?<time>\d{1,2}:\d{2})$/,
       %{args: [thread, time]} = context do
    limit_stop(context, thread, time)
  end

  step ~r/^"(?<thread>[^"]+)" stopped on a usage limit that resets at (?<time>\d{1,2}:\d{2})$/,
       %{args: [thread, time]} = context do
    limit_stop(context, thread, time)
  end

  step "{string} is marked as limited", %{args: [thread]} = context do
    row = World.row(context, thread)
    assert row["status"] == "failed"
    assert row["lastErrorClass"] == "usage_limit"
    context
  end

  step ~r/^its reset time is (?<time>\d{1,2}:\d{2})$/, %{args: [time]} = context do
    reset = World.row(context, World.current(context))["usageLimitResetAt"]
    assert JS.epoch_ms(reset) == context.limit_reset
    assert reset |> NaiveDateTime.from_iso8601!() |> Calendar.strftime("%H:%M") == pad(time)
    context
  end

  step "the user chooses to resume at the reset", context do
    choose_recovery(context, World.current(context), %{"autoResume" => true})
  end

  step "the user cancels the scheduled resume", context do
    context = choose_recovery(context, World.current(context), %{"autoResume" => false})
    refute World.row(context, World.current(context))["limitRecovery"]["autoResume"]
    context
  end

  # Given: stopped and chosen by the user. Then: the recovery sweep armed it on its own.
  step ~r/^"(?<thread>[^"]+)" (?:is|was) scheduled to resume at (?<time>\d{1,2}:\d{2})$/,
       %{args: [thread, time]} = context do
    context =
      if context[:limit_reset],
        do: Map.put(context, :armed, LimitRecovery.sweep()),
        else:
          context
          |> limit_stop(thread, time)
          |> choose_recovery(thread, %{"autoResume" => true})

    id = World.thread_id(context, thread)

    row =
      World.await_row(id, &(&1["limitRecovery"] != nil and &1["limitRecovery"]["autoResume"]))

    assert JS.epoch_ms(row["limitRecovery"]["resetAt"]) == next_clock(time)
    assert row["limitRecovery"]["runId"] == row["latestRunId"]
    context
  end

  step ~r/^"(?<thread>[^"]+)" continues on its own at (?<time>\d{1,2}:\d{2})$/,
       %{args: [thread, time]} = context do
    at = next_clock(time)
    assert resumes(context, thread, at - 1) == []
    continues(context, thread, at)
  end

  step ~r/^"(?<thread>[^"]+)" does not continue at (?<time>\d{1,2}:\d{2})$/,
       %{args: [thread, time]} = context do
    assert resumes(context, thread, next_clock(time)) == []
    refute continued?(context, thread)
    context
  end

  step ~r/^the user (?<action>sends a new message|archives "[^"]+"|settles "[^"]+") before (?<time>\d{1,2}:\d{2})$/,
       %{args: [action, _time]} = context do
    thread = World.current(context)
    id = World.thread_id(context, thread)

    case action do
      "sends" <> _ ->
        {{:ok, _}, context} = World.send_message(context, thread, "Let's try something else")
        World.await_runs(context, thread, ["failed", "completed"])
        context

      "archives" <> _ ->
        {{:ok, _}, context} =
          World.dispatch(context, %{"type" => "thread.archive", "threadId" => id})

        World.await_row(id, &(&1["archivedAt"] != nil))
        context

      "settles" <> _ ->
        {{:ok, _}, context} =
          World.dispatch(context, %{"type" => "thread.settle", "threadId" => id})

        World.await_row(id, &(&1["settledOverride"] == "settled"))
        context
    end
  end

  step "{string} does not continue on its own", %{args: [thread]} = context do
    assert resumes(context, thread, context.limit_reset + 60_000) == []
    refute continued?(context, thread)
    context
  end

  step ~r/^the environment was stopped from (?<from>\d{1,2}:\d{2}) until (?<until>\d{1,2}:\d{2})$/,
       %{args: [from, until]} = context do
    # Nothing was due before it stopped.
    assert resumes(context, World.current(context), clock_at(context, from)) == []
    Map.put(context, :clock, clock_at(context, until))
  end

  step "the environment starts again", context do
    Map.put(context, :mc, Mc.restart(context.mc))
  end

  # The sweep a started MC runs finds the resume that became due while it was down.
  step "{string} continues", %{args: [thread]} = context do
    continues(context, thread, context.clock)
  end

  step "the user turned on auto-resume for limited threads", context do
    Mc.ensure(HalC2.Settings)
    write_settings(context, %{"autoResumeLimitedThreads" => true})
    assert HalC2.Settings.settings()["autoResumeLimitedThreads"] == true
    context
  end

  # The fake Claude stops on a limit resetting at the epoch its message names.
  defp limit_stop(context, thread, time) do
    reset = next_clock(time)

    {{:ok, _}, context} =
      World.send_message(context, thread, "usage limit until #{div(reset, 1000)}")

    World.await_runs(context, thread, ["failed"])
    World.await_row(World.thread_id(context, thread), &(&1["lastErrorClass"] == "usage_limit"))
    Map.merge(context, %{limit_reset: reset, limit_time: time, current: thread})
  end

  defp choose_recovery(context, thread, choice) do
    row = World.row(context, thread)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.metadata.update",
        "threadId" => row["id"],
        "limitRecovery" =>
          Map.merge(
            %{"runId" => row["latestRunId"], "resetAt" => row["usageLimitResetAt"]},
            choice
          )
      })

    World.await_row(row["id"], &(&1["limitRecovery"]["autoResume"] == choice["autoResume"]))
    context
  end

  # The continuation messages a sweep at `at` sends to the thread.
  defp resumes(context, thread, at) do
    id = World.thread_id(context, thread)

    for %{"type" => "message.dispatch", "threadId" => ^id} = command <- LimitRecovery.sweep(at),
        do: command
  end

  defp continues(context, thread, at) do
    assert [%{"usageLimitContinuationOfRunId" => run_id}] = resumes(context, thread, at)

    World.await_thread(context, thread, fn state ->
      runs = state |> HalC2.StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
      length(runs) == 2 and hd(runs)["id"] == run_id
    end)

    assert continued?(context, thread)
    # A second sweep sends nothing more.
    assert resumes(context, thread, at) == []
    context
  end

  defp continued?(context, thread) do
    context
    |> World.stream(thread)
    |> HalC2.StreamState.list("message")
    |> Enum.any?(&(&1["role"] == "user" and &1["text"] == "Continue where you left off."))
  end

  # The next time the wall clock (UTC) shows `time`, at least a minute ahead.
  defp next_clock(time) do
    [hour, minute] = time |> String.split(":") |> Enum.map(&String.to_integer/1)
    now = System.system_time(:millisecond)

    today =
      Date.utc_today()
      |> DateTime.new!(Time.new!(hour, minute, 0))
      |> DateTime.to_unix(:millisecond)

    if today > now + 60_000, do: today, else: today + 24 * 60 * 60 * 1_000
  end

  # `time` on the day of the scenario's reset.
  defp clock_at(context, time) do
    minutes = fn t ->
      [hour, minute] = t |> String.split(":") |> Enum.map(&String.to_integer/1)
      hour * 60 + minute
    end

    context.limit_reset + (minutes.(time) - minutes.(context.limit_time)) * 60_000
  end

  defp pad(time), do: String.pad_leading(time, 5, "0")

  # --- fork-and-lineage.feature ------------------------------------------------------
  # The fake agents answer "where are we" with the native thread the turn ran on and
  # whether handed-off history (and merged work) came ahead of the message.

  step "a connected environment with the thread {string} whose last agent run finished",
       %{args: [title]} = context do
    context
    |> World.agents()
    |> World.create_project("shop")
    |> World.create_thread(title)
    |> then(&World.put_client(&1, World.client(&1)))
    |> World.finished_turns(title, ["hello"])
    |> Map.put(:current, title)
  end

  step "a client forks {string}", %{args: [source]} = context do
    client_fork(context, source, %{})
  end

  step ~r/^a client forks "(?<source>[^"]+)" at its (?<nth>first|second|third) run with the title "(?<title>[^"]+)"$/,
       %{args: [source, nth, title]} = context do
    run = Enum.at(finished_runs(context, source), ordinal(nth))
    client_fork(context, source, %{"title" => title, "sourcePoint" => run_point(run)})
  end

  step "a client forks {string} at the running run", %{args: [source]} = context do
    run = context |> World.runs(source) |> Enum.find(&(&1["status"] == "running"))
    assert run, "no running run in #{source}"
    client_fork(context, source, %{"sourcePoint" => run_point(run)})
  end

  step "a new thread {string} exists", %{args: [title]} = context do
    assert {:ok, _} = context.reply
    row = World.await_row(context.fork_id, & &1)
    assert row["title"] == title
    context |> put_in([:threads, title], context.fork_id) |> Map.put(:current, title)
  end

  step "it holds the history of {string} up to its last finished run",
       %{args: [source]} = context do
    assert conversation(context, World.current(context)) == conversation(context, source)
    context
  end

  step "{string} has three finished runs", %{args: [title]} = context do
    done = length(finished_runs(context, title))
    context = World.finished_turns(context, title, Enum.map(done..2//1, &"step #{&1 + 1}"))
    assert length(finished_runs(context, title)) == 3
    context
  end

  step ~r/^the thread "(?<title>[^"]+)" holds the history through the (?<nth>first|second|third) run only$/,
       %{args: [title, nth]} = context do
    assert {:ok, _} = context.reply
    context = put_in(context, [:threads, title], context.fork_id)
    [source] = Map.keys(context.threads) -- [title]
    through = Enum.take(finished_runs(context, source), ordinal(nth) + 1)
    assert World.thread(context, title)["title"] == title
    assert conversation(context, title) == conversation(context, source, through)
    context
  end

  step "the agent is still working in {string}", %{args: [title]} = context do
    World.working_thread(context, title)
  end

  step "the fork is rejected because only finished runs can be used", context do
    assert {:error, message, _} = context.reply
    assert message =~ "only finished runs can be used"
    target = HalC2.Streams.Server.state(HalC2.Streams.ensure(context.fork_id))
    assert HalC2.StreamState.list(target, "thread") == []
    context
  end

  step "the thread {string} has no finished runs", %{args: [title]} = context do
    context = World.create_thread(context, title)
    assert finished_runs(context, title) == []
    context
  end

  step "the fork is rejected with {string}", %{args: [message]} = context do
    assert {:error, ^message, _} = context.reply
    context
  end

  step "no agent session is started for the fork", context do
    assert {:ok, _} = context.reply
    context = put_in(context, [:threads, "fork"], context.fork_id)
    state = World.await_thread(context, "fork", &(HalC2.StreamState.list(&1, "thread") != []))
    assert HalC2.StreamState.list(state, "provider-session") == []
    assert Registry.lookup(HalC2.Codex.Registry, context.fork_id) == []
    assert Enum.all?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "completed"))
    context
  end

  step "the fork's context is carried over when its first message is sent", context do
    context = put_in(context, [:threads, "fork"], context.fork_id)
    {reply, state} = ask_where(context, "fork", "Codex")
    assert reply =~ ~r/^on forked-native-thread-1-at-native-turn-1 history False/

    assert [%{"status" => "consumed", "resolution" => %{"strategy" => "native_fork"}}] =
             HalC2.StreamState.list(state, "context-transfer")

    context
  end

  step "{string} ran on Codex", %{args: [title]} = context do
    assert context |> finished_runs(title) |> Enum.map(& &1["providerInstanceId"]) |> Enum.uniq() ==
             ["codex"]

    context
  end

  step ~r/^the user sends the first message in a fork of "(?<source>[^"]+)" on (?<agent>Codex|Claude)$/,
       %{args: [source, agent]} = context do
    context = World.fork_thread(context, source, "#{source} fork")
    {reply, state} = ask_where(context, "#{source} fork", agent)
    Map.merge(context, %{where: reply, fork_state: state, current: "#{source} fork"})
  end

  step "the agent continues from its own copy of the conversation", context do
    assert context.where =~ ~r/^on forked-native-thread-1-at-native-turn-1 history False/

    assert [%{"resolution" => %{"strategy" => "native_fork"}}] =
             HalC2.StreamState.list(context.fork_state, "context-transfer")

    context
  end

  step "Claude receives a transcript of the history ahead of the message", context do
    if World.fakes_feature?(context) do
      title = World.current_thread(context)

      sent =
        for entry <- World.provider_log(context, "claude"),
            content = get_in(entry, ["in", "message", "content"]),
            content != nil,
            # A message with attachments comes as content blocks.
            do:
              if(is_binary(content),
                do: content,
                else: Enum.map_join(content, &(&1["text"] || ""))
              )

      text =
        Enum.find(sent, &String.ends_with?(&1, "where are we")) ||
          flunk("Claude got #{inspect(sent)}")

      assert [_, rest] = String.split(text, "<conversation_history>", parts: 2)
      assert rest =~ "User: hello"
      assert Enum.any?(World.replies(context, title), &(&1 =~ "history True"))
      context
    else
      assert context.where =~ "history True"

      assert [%{"strategy" => "full_thread_summary", "summaryText" => summary}] =
               HalC2.StreamState.list(context.fork_state, "context-handoff")

      assert summary =~ "User: hello"
      assert summary =~ "Assistant: Hello from codex"
      context
    end
  end

  step "{string} has more history than fits in a handoff", %{args: [title]} = context do
    World.finished_turns(context, title, [
      "oldest " <> String.duplicate("x", 70_000),
      "newest work"
    ])
  end

  step "the user sends the first message in a fork on another agent", context do
    source = World.current(context)
    context = World.fork_thread(context, source, "#{source} fork")
    {reply, state} = ask_where(context, "#{source} fork", "Claude")
    Map.merge(context, %{where: reply, fork_state: state})
  end

  step "the first request and the newest messages are kept whole", context do
    assert context.where =~ "history True"

    assert [%{"summaryText" => "[earlier messages omitted]\n\n" <> kept}] =
             HalC2.StreamState.list(context.fork_state, "context-handoff")

    assert kept =~ ~r/\AUser: hello\n\n/

    assert kept =~
             ~r/User: newest work\n\n(Command: [^\n]+\n[^\n]+\n[^\n]+\n\n)?Assistant: [^\n]+\z/

    Map.put(context, :kept, kept)
  end

  step "the message that does not fit is left out", context do
    refute context.kept =~ "User: oldest"
    assert String.length(context.kept) < 1_000
    context
  end

  step "{string} still holds its history", %{args: [fork]} = context do
    assert World.thread(context, fork)["deletedAt"] == nil
    assert [%{"text" => "hello"} | _] = messages(context, fork)
    assert Enum.map(finished_runs(context, fork), & &1["status"]) == ["completed"]
    context
  end

  step ~r/^"(?<fork>[^"]+)" is a fork of "(?<source>[^"]+)" with a finished run$/,
       %{args: [fork, source]} = context do
    context |> World.fork_thread(source, fork) |> World.finished_turns(fork, ["write fork.txt"])
  end

  step ~r/^a client merges "(?<fork>[^"]+)" back into "(?<source>[^"]+)"$/,
       %{args: [fork, source]} = context do
    merge_back(context, fork, source)
  end

  step "the next message in {string} carries a summary of the work done in {string}",
       %{args: [source, fork]} = context do
    assert {:ok, _} = context.reply
    {reply, state} = ask_where(context, source, "Codex")
    assert reply =~ "merged True"

    assert [%{"strategy" => "fork_delta_summary", "summaryText" => summary}] =
             HalC2.StreamState.list(state, "context-handoff")

    assert summary =~ "User: write fork.txt"
    refute summary =~ "User: hello"

    assert World.thread(context, fork)["lineage"]["parentThreadId"] ==
             World.thread_id(context, source)

    context
  end

  step ~r/^the merge is rejected because "(?<other>[^"]+)" is not a fork of "(?<source>[^"]+)"$/,
       %{args: [other, source]} = context do
    assert {:error, message, _} = context.reply

    assert message ==
             "Thread #{World.thread_id(context, other)} is not a fork of #{World.thread_id(context, source)}."

    assert World.stream(context, source) |> HalC2.StreamState.list("context-transfer") == []
    context
  end

  step ~r/^"(?<fork>[^"]+)" was merged back into "(?<source>[^"]+)" but no message has been sent since$/,
       %{args: [fork, source]} = context do
    context =
      context
      |> World.fork_thread(source, fork)
      |> World.finished_turns(fork, ["write fork.txt"])
      |> merge_back(fork, source)

    assert {:ok, _} = context.reply
    Map.put(context, :merged_into, source)
  end

  step ~r/^"(?<fork>[^"]+)" is merged back again after more work$/, %{args: [fork]} = context do
    context =
      context
      |> World.finished_turns(fork, ["write more.txt"])
      |> merge_back(fork, context.merged_into)

    assert {:ok, _} = context.reply
    context
  end

  step "only the newer merge is carried with the next message", context do
    {reply, state} = ask_where(context, context.merged_into, "Codex")
    assert reply =~ "merged True"

    assert ["consumed", "superseded"] =
             state
             |> HalC2.StreamState.list("context-transfer")
             |> Enum.map(& &1["status"])
             |> Enum.sort()

    assert [%{"summaryText" => summary}] = HalC2.StreamState.list(state, "context-handoff")
    assert summary =~ "User: write more.txt"
    context
  end

  step ~r/^the user switches "(?<title>[^"]+)" (?:back )?to (?<agent>Codex|Claude) and sends a message$/,
       %{args: [title, agent]} = context do
    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "provider.switch",
        "threadId" => World.thread_id(context, title),
        "modelSelection" => model(agent)
      })

    {reply, state} = ask_where(context, title, nil)
    Map.merge(context, %{where: reply, current: title, switched_state: state})
  end

  step "Claude receives the conversation so far ahead of the message", context do
    assert context.where =~ ~r/^resumed at None fork False history True/

    assert List.last(finished_runs(context, World.current(context)))["providerInstanceId"] ==
             "claudeAgent"

    context
  end

  step "{string} ran on Codex and then on Claude", %{args: [title]} = context do
    context = World.finished_turns(context, title, [])

    {{:ok, _}, context} =
      World.send_message(context, title, "claude work", %{"modelSelection" => model("Claude")})

    World.await_runs(context, title, ["completed", "completed"])

    assert context |> finished_runs(title) |> Enum.map(& &1["providerInstanceId"]) ==
             ["codex", "claudeAgent"]

    context
  end

  step "Codex resumes its own conversation", context do
    [first | _] = World.codex_requests(context, "turn/start")
    assert context.where =~ ~r/^on #{first["threadId"]} history True/
    context
  end

  step "receives only what happened while Claude was working", context do
    input = List.last(World.codex_requests(context, "turn/start"))["input"]
    text = Enum.map_join(input, "\n", &(&1["text"] || ""))
    assert text =~ "User: claude work"
    assert text =~ "Assistant: Hello from claude"
    refute text =~ "User: hello"
    context
  end

  defp client_fork(context, source, fields) do
    id = "th-fork-#{System.unique_integer([:positive])}"

    {reply, context} =
      World.dispatch(
        context,
        Map.merge(
          %{
            "type" => "thread.fork",
            "sourceThreadId" => World.thread_id(context, source),
            "targetThreadId" => id
          },
          fields
        )
      )

    Map.merge(context, %{reply: reply, fork_id: id})
  end

  defp merge_back(context, fork, source) do
    {reply, context} =
      World.dispatch(context, %{
        "type" => "thread.merge_back",
        "createdBy" => "user",
        "sourceThreadId" => World.thread_id(context, fork),
        "targetThreadId" => World.thread_id(context, source)
      })

    Map.put(context, :reply, reply)
  end

  # Sends "where are we" (on `agent`, or the thread's own) and returns the agent's
  # answer with the thread's state once it finished.
  defp ask_where(context, title, agent) do
    extra = if agent, do: %{"modelSelection" => model(agent)}, else: %{}
    done = length(World.runs(context, title))
    {{:ok, _}, context} = World.send_message(context, title, "where are we", extra)

    state =
      World.await_thread(context, title, fn state ->
        runs = HalC2.StreamState.list(state, "run")
        length(runs) == done + 1 and Enum.all?(runs, &(&1["status"] == "completed"))
      end)

    reply =
      state
      |> HalC2.StreamState.list("message")
      |> Enum.filter(&(&1["role"] == "assistant"))
      |> Enum.max_by(& &1["createdAt"])

    {reply["text"], state}
  end

  defp model("Codex"), do: %{"instanceId" => "codex", "model" => "gpt-5.4"}
  defp model("Claude"), do: %{"instanceId" => "claudeAgent", "model" => "claude-haiku-4-5"}

  defp finished_runs(context, title),
    do: context |> World.runs(title) |> Enum.filter(&(&1["status"] == "completed"))

  defp run_point(run), do: %{"type" => "run", "runId" => run["id"]}

  defp ordinal("first"), do: 0
  defp ordinal("second"), do: 1
  defp ordinal("third"), do: 2

  defp messages(context, title) do
    context
    |> World.stream(title)
    |> HalC2.StreamState.list("message")
    |> Enum.sort_by(&{&1["createdAt"], &1["role"] != "user"})
  end

  # The conversation as `{role, text}` in order, for the given runs of the thread (all by default).
  defp conversation(context, title, runs \\ nil) do
    ids = runs && MapSet.new(runs, & &1["id"])

    for message <- messages(context, title),
        ids == nil or MapSet.member?(ids, message["runId"]),
        do: {message["role"], message["text"]}
  end

  # --- worktree-setup.feature -----------------------------------------------------------
  # The launch waits until the scenario's Givens have shaped the project and the
  # workspace strategy (`context.setup`); the first step that needs the setup
  # running launches it. Snapshots the test process receives are kept in order in
  # `context.snapshots`.

  step "the project {string} has a setup script", %{args: [title]} = context do
    context
    |> World.create_project(title)
    |> Map.put(:setup_script, %{
      "id" => "setup",
      "name" => "Setup",
      "command" => "echo installing packages && echo linking",
      "icon" => "configure",
      "runOnWorktreeCreate" => true,
      "async" => false
    })
  end

  step "the user started the thread {string} in a new worktree from {string}",
       %{args: [title, base]} = context do
    id = "th-#{World.slug(title)}-#{System.unique_integer([:positive])}"

    context
    |> World.thread_worktrees()
    |> World.agents()
    |> World.title_generator()
    |> put_in([:threads, title], id)
    |> Map.merge(%{
      current: title,
      setup: %{"type" => "worktree", "baseRef" => base},
      snapshots: []
    })
  end

  step "the environment prepares the worktree", context do
    context |> prepare() |> await_setup(&(&1["phase"] != "running")) |> elem(1)
  end

  step "it fetches {string} when asked, checks out the worktree and runs the setup script",
       %{args: [base]} = context do
    {final, context} = await_setup(context, &(&1["phase"] != "running"))
    assert %{"phase" => "done", "baseRef" => ^base, "worktreePath" => path} = final

    assert statuses(final) == %{
             "fetch" => "skipped",
             "checkout" => "done",
             "setup-script" => "done",
             "agent" => "done"
           }

    root = World.project(context).root
    assert World.git!(path, ~w(rev-parse HEAD)) == World.git!(root, ["rev-parse", base])
    context
  end

  step "the agent starts only after those steps finish", context do
    first = Enum.find(context.snapshots, &(statuses(&1)["agent"] != "pending"))

    assert Map.drop(statuses(first), ["agent"])
           |> Map.values()
           |> Enum.all?(&(&1 in ~w(done skipped)))

    World.await_runs(context, World.current(context), ["completed"])

    assert List.last(World.codex_requests(context, "thread/start"))["cwd"] ==
             first["worktreePath"]

    context
  end

  step "the worktree is checked out", context do
    {snapshot, context} =
      context |> prepare() |> await_setup(&(statuses(&1)["checkout"] == "done"))

    Map.merge(context, %{checked_out: snapshot, worktree_path: snapshot["worktreePath"]})
  end

  step "it is on a temporary branch", context do
    assert context.checked_out["branch"] =~ ~r"^hal-c2/[0-9a-f]{8}$"
    context
  end

  step "the branch is renamed from the first message in the background", context do
    temporary = context.checked_out["branch"]

    state =
      World.await_thread(context, World.current(context), fn state ->
        branch = HalC2.StreamState.list(state, "thread") |> hd() |> Map.get("branch")
        branch not in [nil, temporary]
      end)

    branch = hd(HalC2.StreamState.list(state, "thread"))["branch"]
    assert World.git!(context.worktree_path, ~w(branch --show-current)) == branch
    assert [prompt] = branch_prompts(context)
    assert prompt =~ context.setup_text
    context
  end

  step "a client is watching the setup of {string}", %{args: [title]} = context do
    shape = %{
      "type" => "worktreeSetup",
      "mc" => Atom.to_string(node()),
      "threadId" => World.thread_id(context, title)
    }

    client = context |> World.client() |> Mc.sub(7, shape)
    {%{"event" => nil}, client} = Mc.await(client, &(&1["t"] == "worktreeSetup"))
    World.put_client(context, client)
  end

  step "the setup moves from checkout to the setup script", context do
    context |> prepare() |> await_setup(&(statuses(&1)["setup-script"] != "pending")) |> elem(1)
  end

  step "the client sees the new step and the last lines of its output", context do
    event = &(&1["t"] == "worktreeSetup" and &1["event"] != nil)
    stage = &Enum.find(&1["event"]["stages"], fn stage -> stage["id"] == "setup-script" end)
    client = World.client(context)

    {_moved, client} =
      Mc.await(
        client,
        &(event.(&1) and statuses(&1["event"])["checkout"] == "done" and
            stage.(&1)["status"] == "running"),
        10_000
      )

    {_output, client} =
      Mc.await(client, &(event.(&1) and "linking" in stage.(&1)["tail"]), 10_000)

    World.put_client(context, client)
  end

  step "the setup script is still running", context do
    {snapshot, context} =
      context
      |> put_in([:setup_script, "command"], "echo installing packages && sleep 60")
      |> prepare()
      |> await_setup(&(statuses(&1)["setup-script"] == "running"))

    Map.put(context, :worktree_path, snapshot["worktreePath"])
  end

  step "the thread's first run is cancelled", context do
    assert {:ok, %{"cancelled" => true}} = context.reply
    World.await_runs(context, World.current(context), ["cancelled"])
    assert World.setup_result(context, World.current(context))["phase"] == "cancelled"
    context
  end

  step "the agent has started working in {string}", %{args: [title]} = context do
    {snapshot, context} = context |> prepare() |> await_setup(&(&1["phase"] == "done"))
    assert statuses(snapshot)["agent"] == "done"
    World.await_runs(context, title, ["completed"])
    Map.put(context, :worktree_path, snapshot["worktreePath"])
  end

  step "the user tries to cancel the setup", context do
    {reply, context} =
      World.call(context, "worktreeSetup.cancel", %{
        "threadId" => World.thread_id(context, World.current(context))
      })

    assert File.dir?(context.worktree_path)
    Map.put(context, :reply, reply)
  end

  step "the worktree for {string} was prepared", %{args: [title]} = context do
    {snapshot, context} = context |> prepare() |> await_setup(&(&1["phase"] == "done"))
    World.await_runs(context, title, ["completed"])
    Map.put(context, :worktree_path, snapshot["worktreePath"])
  end

  # Setup progress is held by `HalC2.WorktreeSetup`, which the MC starts afresh.
  step "the environment restarts", context do
    ExUnit.Callbacks.stop_supervised(HalC2.WorktreeSetup)
    %{context | mc: Mc.restart(context.mc), clients: %{}} |> World.thread_worktrees()
  end

  step "{string} shows no setup progress", %{args: [title]} = context do
    shape = %{
      "type" => "worktreeSetup",
      "mc" => Atom.to_string(node()),
      "threadId" => World.thread_id(context, title)
    }

    client = context |> World.client() |> Mc.sub(8, shape)
    {frame, client} = Mc.await(client, &(&1["t"] == "worktreeSetup"))
    assert frame["event"] == nil
    assert World.thread(context, title)["worktreePath"] == context.worktree_path
    World.put_client(context, client)
  end

  step "the user did not ask to start from origin", context do
    root = World.project(context).root
    origin = Mc.tmp_dir(context.mc, "origin")
    World.git!(origin, ~w(init -q --bare -b main))
    World.git!(root, ["remote", "add", "origin", origin])
    World.git!(root, ~w(push -q origin main))
    put_in(context, [:setup, "startFromOrigin"], false)
  end

  step "the project has no \"origin\" remote", context do
    assert World.git!(World.project(context).root, ~w(remote)) == ""
    put_in(context, [:setup, "startFromOrigin"], true)
  end

  step "the project has no script to run on new worktrees", context do
    Map.put(context, :setup_script, nil)
  end

  step ~r/^the (?<step>fetch|setup script) step is shown as skipped$/,
       %{args: [step]} = context do
    {final, context} = await_setup(context, &(&1["phase"] != "running"))
    assert statuses(final)[stage_id(step)] == "skipped"
    Map.put(context, :skipped, stage_id(step))
  end

  step "the remaining steps still run", context do
    {final, context} = await_setup(context, &(&1["phase"] != "running"))
    assert final["phase"] == "done"
    ran = ["checkout", "agent" | if(context.skipped == "fetch", do: ["setup-script"], else: [])]
    assert Map.take(statuses(final), ran) |> Map.values() |> Enum.all?(&(&1 == "done"))
    World.await_runs(context, World.current(context), ["completed"])
    context
  end

  step "the user asked to start from origin", context do
    put_in(context, [:setup, "startFromOrigin"], true)
  end

  step "\"origin\" has no branch {string}", %{args: [branch]} = context do
    root = World.project(context).root
    origin = Mc.tmp_dir(context.mc, "origin")
    World.git!(origin, ~w(init -q --bare -b main))
    World.git!(root, ["remote", "add", "origin", origin])
    World.git!(root, ~w(push -q origin main:elsewhere))
    assert World.git!(root, ["ls-remote", "--heads", "origin", branch]) == ""
    context
  end

  step "the worktree starts from the local {string}", %{args: [branch]} = context do
    {final, context} = await_setup(context, &(&1["phase"] != "running"))
    assert %{"phase" => "done", "worktreePath" => path} = final
    assert statuses(final)["fetch"] == "done"
    root = World.project(context).root
    World.git!(root, ~w(commit -q --allow-empty -m local-only))
    assert World.git!(path, ~w(rev-parse HEAD)) == World.git!(root, ["rev-parse", "#{branch}~1"])
    context
  end

  step "the user named the branch {string} for the new worktree", %{args: [branch]} = context do
    put_in(context, [:setup, "branch"], branch)
  end

  step "it is on {string}", %{args: [branch]} = context do
    assert context.checked_out["branch"] == branch
    assert World.git!(context.worktree_path, ~w(branch --show-current)) == branch
    context
  end

  step "the branch is not renamed later", context do
    {final, context} = await_setup(context, &(&1["phase"] != "running"))
    World.await_runs(context, World.current(context), ["completed"])
    assert World.git!(context.worktree_path, ~w(branch --show-current)) == final["branch"]
    assert World.thread(context, World.current(context))["branch"] == final["branch"]
    assert branch_prompts(context) == []
    context
  end

  step "the setup script starts", context do
    {snapshot, context} = context |> prepare() |> await_setup(&(&1["setupScript"] != nil))
    Map.merge(context, %{started: snapshot, worktree_path: snapshot["worktreePath"]})
  end

  step "it runs in the worktree in a terminal named {string} on {string}",
       %{args: [terminal, title]} = context do
    assert context.started["threadId"] == World.thread_id(context, title)
    assert %{"terminalId" => ^terminal, "name" => "Setup"} = context.started["setupScript"]
    Map.put(context, :setup_terminal, terminal)
  end

  step "the user can open that terminal to follow it", context do
    shape = %{
      "type" => "terminal",
      "mc" => Atom.to_string(node()),
      "input" => %{
        "threadId" => World.thread_id(context, World.current(context)),
        "terminalId" => context.setup_terminal
      }
    }

    client = context |> World.client() |> Mc.sub(9, shape)

    {%{"event" => %{"snapshot" => snapshot}}, client} =
      Mc.await(client, &(&1["t"] == "terminal" and &1["event"]["type"] == "snapshot"))

    assert snapshot["cwd"] == context.worktree_path

    client =
      if snapshot["history"] =~ "linking" do
        client
      else
        {_, client} =
          Mc.await(
            client,
            &(&1["t"] == "terminal" and &1["event"]["type"] == "output" and
                &1["event"]["data"] =~ "linking"),
            10_000
          )

        client
      end

    World.put_client(context, client)
  end

  step "the setup script must finish before the agent starts", context do
    put_in(context, [:setup_script, "async"], false)
  end

  step "the setup script exits with 1", context do
    context
    |> put_in([:setup_script, "command"], "echo installing packages && (exit 1)")
    |> prepare()
    |> await_setup(&(&1["phase"] != "running"))
    |> elem(1)
  end

  step "the setup script runs alongside the agent", context do
    put_in(context, [:setup_script, "async"], true)
  end

  # The script is awaited only once the agent is released, so its failure lands after.
  step "the setup script exits with 1 after the agent started", context do
    {final, context} =
      context
      |> put_in([:setup_script, "command"], "echo installing packages && (exit 1)")
      |> prepare()
      |> await_setup(&(&1["phase"] != "running"))

    agent = Enum.find_index(context.snapshots, &(statuses(&1)["agent"] == "done"))
    failed = Enum.find_index(context.snapshots, &(statuses(&1)["setup-script"] == "failed"))
    assert agent != nil and failed != nil and agent < failed
    Map.put(context, :final, final)
  end

  step "the setup script step is shown as failed with {string}", %{args: [detail]} = context do
    stage = Enum.find(context.final["stages"], &(&1["id"] == "setup-script"))
    assert %{"status" => "failed", "detail" => ^detail} = stage
    context
  end

  step "the agent keeps working in {string}", %{args: [title]} = context do
    assert %{"phase" => "done", "error" => nil} = context.final
    World.await_runs(context, title, ["completed"])
    assert World.codex_requests(context, "turn/start") != []
    context
  end

  step "the worktree cannot be created", context do
    File.rm_rf!(Path.join(World.project(context).root, ".git"))
    context
  end

  # With no terminal service the script has nowhere to run.
  step "the setup script cannot be started", context do
    :ok = ExUnit.Callbacks.stop_supervised(HalC2.Terminal.Supervisor)
    context
  end

  step "the agent cannot be started", context do
    Application.put_env(:hal_c2, :codex_command, ["sh", "-c", "exit 1"])
    context
  end

  step "the thread's first run fails", context do
    World.await_runs(context, World.current(context), ["failed"])
    context
  end

  # Launches the thread in a new worktree once, with the script the Givens chose,
  # watching its setup from the test process.
  defp prepare(%{launched: true} = context), do: context

  defp prepare(context) do
    project = World.project(context)
    title = World.current(context)
    id = World.thread_id(context, title)

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => project.id,
        "scripts" => List.wrap(context.setup_script)
      })

    World.await_row(project.id, &(&1["scripts"] == List.wrap(context.setup_script)))
    nil = HalC2.WorktreeSetup.subscribe(id, self())
    text = "Add totals to the cart"

    {{:ok, _}, context} =
      World.launch_thread(context, nil, text, %{
        "threadId" => id,
        "title" => title,
        "workspaceStrategy" => context.setup
      })

    Map.merge(context, %{launched: true, setup_text: text})
  end

  # The first snapshot, in arrival order, for which `done` holds.
  defp await_setup(context, done) do
    case Enum.find(context.snapshots, done) do
      nil ->
        id = World.thread_id(context, World.current(context))

        receive do
          {:hal_c2_worktree_setup, ^id, snapshot} ->
            await_setup(%{context | snapshots: context.snapshots ++ [snapshot]}, done)
        after
          15_000 -> flunk("the setup never got there: #{inspect(List.last(context.snapshots))}")
        end

      snapshot ->
        {snapshot, context}
    end
  end

  defp statuses(snapshot), do: Map.new(snapshot["stages"], &{&1["id"], &1["status"]})

  defp stage_id("fetch"), do: "fetch"
  defp stage_id("setup script"), do: "setup-script"

  defp branch_prompts(context) do
    case File.read(Path.join(context.mc.home, "text-calls.log")) do
      {:ok, log} ->
        for line <- String.split(log, "\n", trim: true),
            %{"prompt" => prompt} = JSON.decode!(line),
            prompt =~ "git branch names",
            do: prompt

      {:error, _} ->
        []
    end
  end

  # --- migration-and-handoffs.feature ---------------------------------------------

  step "the previous server's event log holds the threads {string} and {string}",
       %{args: [a, b]} = context do
    events =
      [
        {"project", "v2-project", "project.created", "2026-09-01T10:00:00.000Z",
         %{
           "projectId" => "v2-project",
           "title" => "legacy shop",
           "workspaceRoot" => "/tmp/legacy-shop"
         }}
      ] ++
        Enum.flat_map([a, b], fn title ->
          id = "v2-#{String.downcase(title)}"
          thread = v2_thread(id, title)

          [
            {"thread", id, "thread.created", "2026-09-01T10:00:00.000Z", thread},
            {"thread", id, "message.sent", "2026-09-01T11:00:00.000Z",
             %{
               "id" => "#{id}-m1",
               "threadId" => id,
               "role" => "user",
               "text" => "#{title} question",
               "createdAt" => "2026-09-01T11:00:00.000Z"
             }},
            {"thread", id, "message.sent", "2026-09-01T11:00:01.000Z",
             %{
               "id" => "#{id}-m2",
               "threadId" => id,
               "role" => "assistant",
               "text" => "#{title} answer",
               "createdAt" => "2026-09-01T11:00:01.000Z"
             }}
          ]
        end)

    v2_log(context, events, [a, b])
  end

  step "the previous server recorded visits to {string}", %{args: [title]} = context do
    id = "v2-#{String.downcase(title)}"
    thread = v2_thread(id, title)

    v2_log(
      context,
      [
        {"thread", id, "thread.created", "2026-09-01T10:00:00.000Z", thread},
        {"thread", id, "message.sent", "2026-09-01T11:00:00.000Z",
         %{
           "id" => "#{id}-m1",
           "threadId" => id,
           "role" => "assistant",
           "text" => "done",
           "createdAt" => "2026-09-01T11:00:00.000Z"
         }},
        {"thread", id, "thread.visited", "2026-09-01T12:00:00.000Z",
         Map.put(thread, "lastVisitedAt", "2026-09-01T12:00:00.000Z")}
      ],
      [title]
    )
  end

  step "the MC imports that log", context do
    {log, titles} = context.v2_log
    assert {:ok, %{streams: streams}} = HalC2.Import.V2.run(log, HalC2.Store)
    assert streams > 0
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    Enum.reduce(titles, context, &put_in(&2, [:threads, &1], "v2-#{String.downcase(&1)}"))
  end

  step "{string} and {string} are listed with their messages, titles and projects",
       %{args: titles} = context do
    for title <- titles do
      assert %{"title" => ^title, "projectId" => "v2-project"} = World.row(context, title)

      assert context
             |> World.stream(title)
             |> HalC2.StreamState.list("message")
             |> Enum.map(& &1["text"])
             |> Enum.sort() ==
               ["#{title} answer", "#{title} question"]
    end

    assert {_kind, %{"title" => "legacy shop"}} = HalC2.Shell.row(node(), "v2-project")
    context
  end

  step "the previous server's log is left unchanged", context do
    {log, _} = context.v2_log
    assert :crypto.hash(:sha256, File.read!(log)) == context.v2_log_hash
    context
  end

  step "a T3 Code install on this machine holds the threads {string} and {string}",
       %{args: [a, b]} = context do
    home = Path.join(context.mc.home, "t3")
    dir = Path.join(home, "dev")
    root = Path.join(context.mc.home, "legacy-shop")
    File.mkdir_p!(Path.join(dir, "attachments"))
    File.mkdir_p!(Path.join([dir, "logs", "terminals"]))
    File.mkdir_p!(root)
    World.put_env("T3CODE_HOME", home)

    [a_id, b_id] = for title <- [a, b], do: "t3-#{String.downcase(title)}"
    sub = a_id <> "-sub"
    at = "2026-09-01T10:00:00.000Z"

    message = fn id, n, role, text, attachments ->
      {"thread", id, "message.sent", "2026-09-01T11:00:0#{n}.000Z",
       %{
         "id" => "#{id}-m#{n}",
         "threadId" => id,
         "role" => role,
         "text" => text,
         "attachments" => attachments,
         "createdAt" => "2026-09-01T11:00:0#{n}.000Z"
       }}
    end

    thread = fn id, title ->
      {"thread", id, "thread.created", at, Map.put(v2_thread(id, title), "worktreePath", root)}
    end

    image = %{"type" => "image", "id" => "#{a_id}-img", "name" => "cart.png"}

    events = [
      thread.(a_id, a),
      message.(a_id, 1, "user", "#{a} question", [image]),
      message.(a_id, 2, "assistant", "#{a} answer", []),
      {"thread", a_id, "provider-thread.updated", at,
       %{
         "id" => "pt-t3",
         "appThreadId" => a_id,
         "driver" => "codex",
         "status" => "idle",
         "nativeThreadRef" => %{"driver" => "codex", "nativeId" => "thr-t3"}
       }},
      # The turn T3 Code was still running.
      {"thread", a_id, "run.updated", at,
       %{"id" => "run-t3", "threadId" => a_id, "ordinal" => 1, "status" => "running"}},
      thread.(sub, "Look into the cart"),
      message.(sub, 1, "assistant", "The cart rounds twice.", []),
      thread.(b_id, b),
      message.(b_id, 1, "user", "#{b} question", [])
    ]

    File.write!(Path.join([dir, "attachments", "#{a_id}-img.png"]), <<0x89, "PNG t3">>)

    File.write!(
      Path.join([
        dir,
        "logs",
        "terminals",
        "terminal_#{Base.url_encode64(a_id, padding: false)}.log"
      ]),
      "$ make\nbuilt\n"
    )

    context = v2_log(context, events, [a, b], 2, Path.join(dir, "state.sqlite"))
    {log, _} = context.v2_log
    {:ok, db} = Exqlite.Sqlite3.open(log)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE projection_projects (
        project_id TEXT, title TEXT, workspace_root TEXT, scripts_json TEXT, deleted_at TEXT);
      CREATE TABLE orchestration_v2_projection_threads (
        thread_id TEXT, project_id TEXT, title TEXT, updated_at TEXT, payload_json TEXT);
      INSERT INTO projection_projects VALUES ('v2-project', 'legacy shop', '#{root}', '[]', NULL);
      INSERT INTO orchestration_v2_projection_threads VALUES
        ('#{a_id}', 'v2-project', '#{a}', '2026-09-01T11:00:02.000Z', '{}'),
        ('#{b_id}', 'v2-project', '#{b}', '2026-09-02T11:00:01.000Z', '{}'),
        ('t3-settled', 'v2-project', 'Done long ago', '2026-09-04T11:00:01.000Z',
         '{"settledOverride":"settled","settledAt":"2026-09-04T12:00:00.000Z"}'),
        ('#{sub}', 'v2-project', 'Look into the cart', '2026-09-03T11:00:01.000Z',
         '{"lineage":{"parentThreadId":"#{a_id}","relationshipToParent":"subagent"}}');
      """)

    :ok = Exqlite.Sqlite3.close(db)

    Map.merge(context, %{
      t3: %{dir: dir, root: root, ids: %{a => a_id, b => b_id}, sub: sub},
      v2_log_hash: :crypto.hash(:sha256, File.read!(log))
    })
  end

  step "the user asks which threads that install holds", context do
    assert {:ok, %{"sources" => sources}} =
             HalC2.Cluster.Command.request(:get, "/api/previous-installs")

    assert [%{"path" => path, "label" => "T3 Code (development)"}] =
             Enum.filter(sources, &(&1["path"] == context.t3.dir))

    {:ok, %{"threads" => offered}} =
      HalC2.Cluster.Command.request(:post, "/api/previous-installs/threads", %{"source" => path})

    Map.put(context, :offered, offered)
  end

  step "{string} and {string} are offered with their project, newest first",
       %{args: titles} = context do
    assert for(
             t <- context.offered,
             not t["settled"],
             do: {t["title"], t["project"], t["imported"]}
           ) ==
             for(title <- titles, do: {title, "legacy shop", false})

    context
  end

  step "a thread that was settled there is offered after them, as settled", context do
    assert %{"title" => "Done long ago", "settled" => true} = List.last(context.offered)
    context
  end

  step "the thread {string}'s subagent ran in is counted with it, not offered on its own",
       %{args: [title]} = context do
    assert for(t <- context.offered, not t["settled"], do: {t["title"], t["subagents"]})
           |> Enum.sort() ==
             Enum.sort(for {t, _} <- context.t3.ids, do: {t, if(t == title, do: 1, else: 0)})

    context
  end

  step "the user imports/imported {string} from that install", %{args: [title]} = context do
    id = context.t3.ids[title]

    answer =
      HalC2.Cluster.Command.request(:post, "/api/previous-installs/import", %{
        "source" => context.t3.dir,
        "threadIds" => [id]
      })

    context |> Map.put(:t3_answer, answer) |> put_in([:threads, title], id)
  end

  step "{string} is listed in a new project at the folder it worked in",
       %{args: [title]} = context do
    id = context.t3.ids[title]
    assert {:ok, %{"imported" => [^id], "failed" => []}} = context.t3_answer
    assert %{"title" => ^title, "projectId" => "v2-project"} = World.row(context, title)

    assert %{"title" => "legacy shop", "workspaceRoot" => root} =
             World.await_row("v2-project", & &1)

    assert root == context.t3.root
    context
  end

  step "{string} is listed in {string}", %{args: [title, project]} = context do
    id = context.t3.ids[title]
    assert {:ok, %{"imported" => [^id], "failed" => []}} = context.t3_answer
    here = World.project(context, project)
    assert %{"projectId" => project_id} = World.row(context, title)
    assert project_id == here.id
    assert World.thread(context, title)["worktreePath"] == here.root
    assert HalC2.Shell.row(node(), "v2-project") == nil
    context
  end

  step "{string} has its messages, its subagent's thread, its attachment and its terminal scrollback",
       %{args: [title]} = context do
    id = context.t3.ids[title]

    texts =
      for m <- HalC2.StreamState.list(World.stream(context, title), "message"), do: m["text"]

    assert Enum.sort(texts) == ["#{title} answer", "#{title} question"]

    assert {_kind, %{"title" => "Look into the cart"}} = HalC2.Shell.row(node(), context.t3.sub)
    assert File.read!(HalC2.Attachments.path(%{"id" => "#{id}-img"})) == <<0x89, "PNG t3">>
    assert HalC2.Terminal.saved_scrollback(id) == [{"term-1", "$ make\nbuilt\n"}]
    context
  end

  step "{string} keeps its tie to the agent's session, with the turn it was running ended",
       %{args: [title]} = context do
    state = World.stream(context, title)

    assert [%{"nativeThreadRef" => %{"nativeId" => "thr-t3"}}] =
             HalC2.StreamState.list(state, "provider-thread")

    assert [%{"status" => "interrupted"}] = HalC2.StreamState.list(state, "run")
    context
  end

  step "{string} is not imported", %{args: [title]} = context do
    assert HalC2.Shell.row(node(), context.t3.ids[title]) == nil
    context
  end

  step "the install is left unchanged", context do
    {log, _} = context.v2_log
    assert :crypto.hash(:sha256, File.read!(log)) == context.v2_log_hash
    context
  end

  step "the user is told {string} is already here", %{args: [title]} = context do
    id = context.t3.ids[title]

    assert {:ok, %{"imported" => [], "failed" => [%{"id" => ^id, "message" => message}]}} =
             context.t3_answer

    assert message == "It is already here."
    context
  end

  step "that install offers {string} as imported", %{args: [title]} = context do
    {:ok, %{"threads" => offered}} =
      HalC2.Cluster.Command.request(:post, "/api/previous-installs/threads", %{
        "source" => context.t3.dir
      })

    assert for(t <- offered, t["imported"], do: t["title"]) == [title]
    context
  end

  step "the project {string} is at the folder that install worked in",
       %{args: [title]} = context do
    World.create_project(context, title, %{"workspaceRoot" => context.t3.root})
  end

  step "{string} keeps its read state without showing new activity", %{args: [title]} = context do
    row = World.row(context, title)
    assert row["lastVisitedAt"] == "2026-09-01T12:00:00.000Z"
    # The last activity is the message at 11:00, not the visit at 12:00.
    {:ok, updated, _} = DateTime.from_iso8601(row["updatedAt"])
    assert DateTime.compare(updated, ~U[2026-09-01 11:00:00Z]) == :eq
    context
  end

  # A thread the first version (the Node server's version 1 orchestrator) logged, with
  # a user and an agent message and whatever `detail` names; the MC's import folds it
  # (`HalC2.Import.V1Thread`) as the Node server's startup migration does.
  step ~r/^the first version's thread "(?<title>[^"]+)" had (?<detail>.+)$/,
       %{args: [title, detail]} = context do
    id = "v1-" <> (title |> String.downcase() |> String.replace(" ", "-"))
    {created, extra} = v1_detail(detail, id)

    events =
      [
        {"project", "v1-project", "project.created", "2026-08-01T09:00:00.000Z",
         %{"projectId" => "v1-project", "title" => "legacy shop", "workspaceRoot" => "/tmp/shop"}},
        {"thread", id, "thread.created", "2026-08-01T10:00:00.000Z",
         Map.merge(
           %{
             "threadId" => id,
             "projectId" => "v1-project",
             "title" => title,
             "createdAt" => "2026-08-01T10:00:00.000Z",
             "updatedAt" => "2026-08-01T10:00:00.000Z"
           },
           created
         )},
        v1_message(id, 1, "user", "Fix the cart", v1_attachments(detail)),
        v1_message(id, 2, "assistant", "Fixed the cart total", [])
      ] ++ Enum.map(extra, fn {type, at, payload} -> {"thread", id, type, at, payload} end)

    context
    |> v2_log(events, [title], 1)
    |> Map.merge(%{v1_thread: id, v1_detail: detail})
  end

  step "the thread is migrated", context do
    {log, [title]} = context.v2_log
    assert {:ok, %{streams: 2}} = HalC2.Import.V2.run(log, HalC2.Store)
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}

    Map.update(
      context,
      :threads,
      %{title => context.v1_thread},
      &Map.put(&1, title, context.v1_thread)
    )
  end

  step ~r/^"(?<title>[^"]+)" still has (?<detail>its title and project|its agent and model|its permission and interaction modes|its branch and worktree|its archive, settle, snooze and pin state|its linked pull request|its user and agent messages with timestamps|its supported attachments)$/,
       %{args: [title, detail]} = context do
    assert detail == context.v1_detail
    thread = World.thread(context, title)
    assert thread["historyOrigin"] == "v1_import"
    v1_kept(detail, context, title, thread)
    context
  end

  # Only the conversation comes over: the thread, its messages and their turn items.
  step ~r/^"(?<title>[^"]+)" does not have (?<detail>a live agent session|checkpoints and diffs|tool activity|pending approvals|plans)$/,
       %{args: [title, detail]} = context do
    assert detail == context.v1_detail
    state = World.stream(context, title)
    assert state.entities |> Map.keys() |> Enum.sort() == ["message", "thread", "turn-item"]

    assert state |> HalC2.StreamState.list("turn-item") |> Enum.map(& &1["type"]) |> Enum.sort() ==
             ["assistant_message", "user_message"]

    assert World.thread(context, title)["activeProviderThreadId"] == nil
    context
  end

  defp v1_message(id, n, role, text, attachments) do
    at = "2026-08-01T10:0#{n}:00.000Z"

    {"thread", id, "thread.message-sent", at,
     %{
       "threadId" => id,
       "messageId" => "#{id}-m#{n}",
       "role" => role,
       "text" => text,
       "attachments" => attachments,
       "turnId" => "#{id}-turn-1",
       "streaming" => false,
       "createdAt" => at,
       "updatedAt" => at
     }}
  end

  defp v1_attachments("its supported attachments"),
    do: [%{"type" => "image", "id" => "img-1", "name" => "cart.png", "mimeType" => "image/png"}]

  defp v1_attachments(_detail), do: []

  @v1_pull_request %{
    "projectId" => "v1-project",
    "repository" => "acme/shop",
    "url" => "https://github.com/acme/shop/pull/7",
    "number" => 7
  }

  # `{fields of thread.created, [{type, occurred_at, payload}]}` for each detail.
  defp v1_detail("its agent and model", _id),
    do:
      {%{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "claude-opus-4-6"}}, []}

  defp v1_detail("its permission and interaction modes", id),
    do:
      {%{},
       [
         {"thread.runtime-mode-set", "2026-08-01T11:00:00.000Z",
          %{
            "threadId" => id,
            "runtimeMode" => "approval-required",
            "updatedAt" => "2026-08-01T11:00:00.000Z"
          }},
         {"thread.interaction-mode-set", "2026-08-01T11:01:00.000Z",
          %{
            "threadId" => id,
            "interactionMode" => "plan",
            "updatedAt" => "2026-08-01T11:01:00.000Z"
          }}
       ]}

  defp v1_detail("its branch and worktree", id),
    do:
      {%{},
       [
         {"thread.meta-updated", "2026-08-01T11:00:00.000Z",
          %{
            "threadId" => id,
            "branch" => "feature/cart",
            "worktreePath" => "/tmp/shop-cart",
            "updatedAt" => "2026-08-01T11:00:00.000Z"
          }}
       ]}

  defp v1_detail("its archive, settle, snooze and pin state", id) do
    at = "2026-08-01T11:00:00.000Z"

    {%{},
     [
       {"thread.settled", at, %{"threadId" => id, "settledAt" => at, "updatedAt" => at}},
       {"thread.snoozed", at,
        %{
          "threadId" => id,
          "snoozedUntil" => "2026-08-02T09:00:00.000Z",
          "snoozedAt" => at,
          "updatedAt" => at
        }},
       {"thread.pinned", at,
        %{"threadId" => id, "pinnedAt" => at, "pinOrderKey" => "a0", "updatedAt" => at}},
       {"thread.archived", at, %{"threadId" => id, "archivedAt" => at, "updatedAt" => at}}
     ]}
  end

  defp v1_detail("its linked pull request", id),
    do:
      {%{},
       [
         {"thread.meta-updated", "2026-08-01T11:00:00.000Z",
          %{
            "threadId" => id,
            "linkedPullRequest" => @v1_pull_request,
            "updatedAt" => "2026-08-01T11:00:00.000Z"
          }}
       ]}

  defp v1_detail("a live agent session", id),
    do:
      {%{},
       [
         {"thread.session-set", "2026-08-01T10:03:00.000Z",
          %{
            "threadId" => id,
            "session" => %{
              "threadId" => id,
              "status" => "running",
              "providerName" => "codex",
              "activeTurnId" => "#{id}-turn-1",
              "updatedAt" => "2026-08-01T10:03:00.000Z"
            }
          }}
       ]}

  defp v1_detail("checkpoints and diffs", id),
    do:
      {%{},
       [
         {"thread.turn-diff-completed", "2026-08-01T10:03:00.000Z",
          %{
            "threadId" => id,
            "turnId" => "#{id}-turn-1",
            "checkpointTurnCount" => 1,
            "checkpointRef" => "refs/hal-c2/checkpoints/#{id}/turn/1",
            "status" => "ready",
            "files" => [
              %{"path" => "cart.ts", "kind" => "modified", "additions" => 2, "deletions" => 1}
            ],
            "completedAt" => "2026-08-01T10:03:00.000Z"
          }}
       ]}

  defp v1_detail("tool activity", id), do: {%{}, [v1_activity(id, "tool.completed", "Ran tests")]}

  defp v1_detail("pending approvals", id),
    do:
      {%{},
       [
         v1_activity(id, "approval.requested", "Run npm install?"),
         {"thread.approval-response-requested", "2026-08-01T10:04:00.000Z",
          %{"threadId" => id, "requestId" => "approval-1", "decision" => "accept"}}
       ]}

  defp v1_detail("plans", id),
    do:
      {%{},
       [
         {"thread.proposed-plan-upserted", "2026-08-01T10:03:00.000Z",
          %{
            "threadId" => id,
            "proposedPlan" => %{
              "id" => "plan-1",
              "turnId" => "#{id}-turn-1",
              "planMarkdown" => "1. Fix the cart",
              "createdAt" => "2026-08-01T10:03:00.000Z",
              "updatedAt" => "2026-08-01T10:03:00.000Z"
            }
          }}
       ]}

  # Details every first-version thread has: its title, project and messages.
  defp v1_detail(_detail, _id), do: {%{}, []}

  defp v1_activity(id, kind, summary),
    do:
      {"thread.activity-appended", "2026-08-01T10:03:00.000Z",
       %{
         "threadId" => id,
         "activity" => %{
           "id" => "activity-#{kind}",
           "tone" => "tool",
           "kind" => kind,
           "summary" => summary,
           "payload" => %{},
           "turnId" => "#{id}-turn-1",
           "createdAt" => "2026-08-01T10:03:00.000Z"
         }
       }}

  defp v1_kept("its title and project", context, title, thread) do
    assert %{"title" => ^title, "projectId" => "v1-project"} = thread
    assert %{"title" => ^title, "projectId" => "v1-project"} = World.row(context, title)
    assert {_kind, %{"title" => "legacy shop"}} = HalC2.Shell.row(node(), "v1-project")
  end

  defp v1_kept("its agent and model", _context, _title, thread) do
    assert thread["modelSelection"] == %{
             "instanceId" => "claudeAgent",
             "model" => "claude-opus-4-6"
           }

    assert thread["providerInstanceId"] == "claudeAgent"
  end

  defp v1_kept("its permission and interaction modes", _context, _title, thread),
    do: assert(%{"runtimeMode" => "approval-required", "interactionMode" => "plan"} = thread)

  defp v1_kept("its branch and worktree", _context, _title, thread),
    do: assert(%{"branch" => "feature/cart", "worktreePath" => "/tmp/shop-cart"} = thread)

  defp v1_kept("its archive, settle, snooze and pin state", _context, _title, thread) do
    at = "2026-08-01T11:00:00.000Z"

    assert %{
             "archivedAt" => ^at,
             "settledOverride" => "settled",
             "settledAt" => ^at,
             "snoozedUntil" => "2026-08-02T09:00:00.000Z",
             "pinnedAt" => ^at,
             "pinOrderKey" => "a0"
           } = thread
  end

  defp v1_kept("its linked pull request", _context, _title, thread) do
    assert thread["linkedPullRequest"] == @v1_pull_request
    assert [%{"number" => 7, "source" => "manual"}] = HalC2.Projection.PullRequests.of(thread)
  end

  defp v1_kept("its user and agent messages with timestamps", context, title, _thread) do
    assert context
           |> World.stream(title)
           |> HalC2.StreamState.list("message")
           |> Enum.sort_by(& &1["createdAt"])
           |> Enum.map(&{&1["role"], &1["text"], &1["createdAt"]}) == [
             {"user", "Fix the cart", "2026-08-01T10:01:00.000Z"},
             {"assistant", "Fixed the cart total", "2026-08-01T10:02:00.000Z"}
           ]
  end

  defp v1_kept("its supported attachments", context, title, _thread) do
    messages = context |> World.stream(title) |> HalC2.StreamState.list("message")

    assert [%{"attachments" => [%{"name" => "cart.png"}]}] =
             Enum.filter(messages, &(&1["role"] == "user"))
  end

  step "the thread {string} has a short conversation on Codex", %{args: [title]} = context do
    context
    |> handoff_thread(title)
    |> World.finished_turns(title, ["sum the cart totals", "now add the discount"])
  end

  step "Claude receives the whole conversation ahead of the message", context do
    prompt = List.last(World.claude_prompts(context))
    assert prompt =~ ~r/^<conversation_history>\n/
    refute prompt =~ "[earlier messages omitted]"

    for line <- ["User: sum the cart totals", "User: now add the discount", "Assistant: "],
        do: assert(prompt =~ line)

    assert prompt =~ ~r{</conversation_history>\n\nwhere are we$}
    context
  end

  step "the thread {string} has attachments and tool activity", %{args: [title]} = context do
    context = handoff_thread(context, title)
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      HalC2.Attachments.create_upload_url(%{
        "name" => "a.png",
        "mimeType" => "image/png",
        "sizeBytes" => byte_size(png)
      })

    :ok = HalC2.Attachments.store(token, png)

    image = %{
      "type" => "image",
      "id" => id,
      "name" => "a.png",
      "mimeType" => "image/png",
      "sizeBytes" => byte_size(png)
    }

    {{:ok, _}, context} =
      World.send_message(context, title, "check this screenshot", %{"attachments" => [image]})

    # The fake Codex runs `ls` (output "a.txt") in every turn.
    state =
      World.await_thread(context, title, fn state ->
        Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "completed")) and
          Enum.any?(HalC2.StreamState.list(state, "turn-item"), &(&1["input"] == "ls"))
      end)

    assert [%{"attachments" => [_]}] =
             state |> HalC2.StreamState.list("message") |> Enum.filter(&(&1["role"] == "user"))

    context
  end

  step "the user switches {string} to another agent", %{args: [title]} = context do
    switch_and_ask(context, title)
  end

  step "the user switches {string} to another agent and sends a message",
       %{args: [title]} = context do
    switch_and_ask(context, title)
  end

  step "the new agent receives each command with its exit code and output", context do
    assert handed_history(context) =~
             ~r/\AUser: check this screenshot\n\nCommand: ls\nExit code: 0\na\.txt\n\nAssistant: [^\n]+\z/

    context
  end

  step "the new agent receives only what was said and the commands that ran", context do
    history = handed_history(context)
    assert history =~ "User: check this screenshot"

    for block <- String.split(history, "\n\n"),
        do:
          assert(
            String.starts_with?(block, ["User: ", "Assistant: ", "Command: "]),
            "neither a message nor a command: #{block}"
          )

    refute history =~ "a.png"
    context
  end

  step "the thread {string} has a conversation longer than the handoff budget",
       %{args: [title]} = context do
    texts = for n <- 1..3, do: "part #{n} " <> String.duplicate("cart ", 5_000)

    context
    |> handoff_thread(title)
    |> World.finished_turns(title, ["the original request"] ++ texts ++ ["the newest request"])
  end

  # Parts 2 and 3 fit beside the original request and the newest turn; part 1 does not.
  # The fake Codex names its answer and its command the same in every turn, so only the
  # newest turn has them.
  step "Claude receives the original request, the recent turns and command outcomes", context do
    assert "[earlier messages omitted]\n\n" <> kept = handed_history(context)
    assert String.length(kept) <= 60_000

    assert ["User: the original request", "User: part 2 " <> _, "User: part 3 " <> _ | newest] =
             String.split(kept, "\n\n")

    assert ["User: the newest request", "Command: ls\nExit code: 0\na.txt", "Assistant: " <> _] =
             newest

    context
  end

  step "the new message is never shortened", context do
    assert String.ends_with?(
             List.last(World.claude_prompts(context)),
             "</conversation_history>\n\nwhere are we"
           )

    context
  end

  step "the thread {string} has more than 60,000 characters of history",
       %{args: [title]} = context do
    texts = for n <- 1..3, do: "part #{n} " <> String.duplicate("cart ", 5_000)

    context
    |> handoff_thread(title)
    |> World.finished_turns(title, texts ++ ["the newest request"])
  end

  step "the agent receives at most 60,000 characters of history", context do
    assert "[earlier messages omitted]\n\n" <> kept = handed_history(context)
    assert String.length(kept) in 50_000..60_000

    assert kept =~
             ~r/User: the newest request\n\nCommand: ls\n[^\n]+\n[^\n]+\n\nAssistant: [^\n]+\z/

    Map.put(context, :kept, kept)
  end

  # The first request and the newest long one, with the one between them left out.
  step "every message it receives is whole", context do
    requests = for "User: part " <> _ = block <- String.split(context.kept, "\n\n"), do: block

    assert requests ==
             for(
               n <- [1, 3],
               do: String.trim("User: part #{n} " <> String.duplicate("cart ", 5_000))
             )

    context
  end

  step "parts of the conversation did not fit in the handoff", context do
    texts = for n <- 1..3, do: "part #{n} " <> String.duplicate("cart ", 5_000)

    context =
      context
      |> handoff_thread("Alpha")
      |> World.finished_turns("Alpha", texts ++ ["the newest request"])
      |> switch_and_ask("Alpha")

    # The first request and the newest two fit; the one between them does not.
    assert "[earlier messages omitted]\n\n" <> kept = handed_history(context)
    assert kept =~ "part 1 "
    refute kept =~ "part 2 "
    Map.put(context, :left_out, Enum.at(texts, 1))
  end

  # Claude, now the thread's agent, pages to the thread's second request with the MC's tool.
  step "the agent needs one of the left-out parts", context do
    read =
      World.mcp_tool(
        context,
        "Alpha",
        "hal_c2_thread_read",
        %{
          "threadId" => World.thread_id(context, "Alpha"),
          "afterPosition" => 1,
          "limit" => 1,
          "maxCharsPerItem" => String.length(context.left_out)
        },
        "claudeAgent"
      )

    Map.put(context, :read, read)
  end

  step "the agent can read it through the thread-reading tool", context do
    assert {:ok, %{"items" => [item], "hasMore" => true}} = context.read
    assert %{"type" => "user_message", "truncated" => false} = item
    assert item["text"] == context.left_out
    context
  end

  defp v2_thread(id, title),
    do: %{
      "id" => id,
      "projectId" => "v2-project",
      "title" => title,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    }

  # Writes a Node server event log (its `orchestration_events` table) of
  # `{aggregate, stream, type, occurred_at, payload}` events.
  defp v2_log(context, events, titles, version \\ 2, path \\ nil) do
    path = path || Path.join(context.mc.home, "previous-state.sqlite")
    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE orchestration_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_kind TEXT, stream_id TEXT,
        event_type TEXT, payload_json TEXT, occurred_at TEXT, application_event_version INTEGER)
      """)

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        db,
        "INSERT INTO orchestration_events (aggregate_kind, stream_id, event_type, payload_json, occurred_at, application_event_version) VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
      )

    for {agg, stream, type, at, payload} <- events do
      :ok =
        Exqlite.Sqlite3.bind(stmt, [
          agg,
          stream,
          type,
          JSON.encode!(payload),
          at,
          if(agg == "project", do: nil, else: version)
        ])

      :done = Exqlite.Sqlite3.step(db, stmt)
    end

    :ok = Exqlite.Sqlite3.release(db, stmt)
    :ok = Exqlite.Sqlite3.close(db)

    Map.merge(context, %{
      v2_log: {path, titles},
      v2_log_hash: :crypto.hash(:sha256, File.read!(path))
    })
  end

  defp handoff_thread(context, title) do
    context = World.agents(context)

    context =
      if context[:projects] in [nil, %{}],
        do: World.create_project(context, "shop"),
        else: context

    context |> World.create_thread(title) |> Map.put(:current, title)
  end

  # Switches `title` to Claude and asks it "where are we".
  defp switch_and_ask(context, title) do
    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "provider.switch",
        "threadId" => World.thread_id(context, title),
        "modelSelection" => model("Claude")
      })

    {reply, state} = ask_where(context, title, nil)
    assert reply =~ "history True"
    Map.merge(context, %{where: reply, current: title, switched_state: state})
  end

  # The history block of the prompt the last Claude turn was sent.
  defp handed_history(context) do
    prompt = List.last(World.claude_prompts(context))

    assert [_, history] =
             Regex.run(
               ~r/\A<conversation_history>\nThis conversation started in another agent session\. Continue from it\.\n\n(.*)\n<\/conversation_history>\n\nwhere are we\z/s,
               prompt
             )

    history
  end

  # Answers `gh` with `rules` (see test/support/fake_gh.py).
  defp gh(context, rules) do
    home = context.mc.home
    File.write!(Path.join(home, "gh-rules.json"), JSON.encode!(rules))

    unless context[:gh] do
      previous = Application.get_env(:hal_c2, :gh_command)
      Application.put_env(:hal_c2, :gh_command, Path.expand("../support/fake_gh.py", __DIR__))
      System.put_env("FAKE_GH_RULES", Path.join(home, "gh-rules.json"))
      System.put_env("FAKE_GH_LOG", Path.join(home, "gh.log"))

      ExUnit.Callbacks.on_exit(fn ->
        if previous,
          do: Application.put_env(:hal_c2, :gh_command, previous),
          else: Application.delete_env(:hal_c2, :gh_command)

        System.delete_env("FAKE_GH_RULES")
        System.delete_env("FAKE_GH_LOG")
      end)
    end

    Map.put(context, :gh, rules)
  end

  defp open_pull_request(context, branch, number) do
    rules = [
      %{
        "args" => ["pr list", "--head #{branch}"],
        "stdout" => [%{"number" => number, "url" => pr_url(number), "state" => "OPEN"}]
      }
    ]

    context |> gh(rules ++ context.gh) |> Map.put(:branch_pr, number)
  end

  defp discover(context) do
    Mc.ensure({HalC2.PullRequests.Discovery, interval: nil})
    :ok = HalC2.PullRequests.Discovery.sweep()
    context
  end

  defp pr_url(number), do: "https://github.com/acme/shop/pull/#{number}"

  defp manual_link(context, thread, number) do
    id = World.thread_id(context, thread)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.pull-request.link",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/shop",
        "number" => number,
        "url" => pr_url(number),
        "source" => "manual"
      })

    Map.put(context, :current, thread)
  end

  defp unlink(context, thread, number) do
    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.pull-request.unlink",
        "threadId" => World.thread_id(context, thread),
        "host" => "github.com",
        "repository" => "acme/shop",
        "number" => number
      })

    context
  end

  defp pull_request_numbers(thread),
    do:
      thread
      |> HalC2.Projection.PullRequests.of()
      |> HalC2.Projection.PullRequests.visible()
      |> Enum.map(& &1["number"])

  # Links pull request 5, whose native stack also holds 6, and lets the sync bring 6.
  defp stack(context, thread) do
    pr = %{
      "title" => "PR",
      "url" => pr_url(5),
      "state" => "OPEN",
      "isDraft" => false,
      "headRefName" => "feature/cart",
      "baseRefName" => "main",
      "updatedAt" => "2026-03-01T00:00:00Z",
      "mergedAt" => nil,
      "author" => %{"login" => "someone"}
    }

    context =
      gh(context, [
        %{
          "args" => ["api graphql"],
          "stdin" => ["PullRequestSummaries"],
          "stdout" => %{
            "data" => %{"s0" => %{"pullRequest" => pr}, "s1" => %{"pullRequest" => pr}}
          }
        },
        %{
          "args" => ["stacks?pull_request="],
          "stdout" => [
            %{
              "id" => 42,
              "number" => 1,
              "html_url" => "https://github.com/acme/shop/stacks/1",
              "base" => "main",
              "pull_requests" => [
                %{"number" => 5, "head" => %{"ref" => "feature/cart"}, "state" => "open"},
                %{"number" => 6, "head" => %{"ref" => "feature/cart-2"}, "state" => "open"}
              ]
            }
          ]
        }
      ])

    Mc.ensure({HalC2.PullRequests.Sync, interval: nil})
    context = manual_link(context, thread, 5)
    # The sync reads links from the sidebar rows.
    World.await_row(World.thread_id(context, thread), &match?([_], &1["pullRequests"]))
    :ok = HalC2.PullRequests.Sync.sweep()
    assert pull_request_numbers(World.thread(context, thread)) == [5, 6]
    context
  end

  defp search(context, query) do
    {%{"matches" => matches}, context} =
      World.call!(context, "orchestration.searchThreads", %{"query" => query})

    Map.merge(context, %{query: query, matches: matches})
  end

  defp matches(context, thread) do
    id = World.thread_id(context, thread)
    Enum.filter(context.matches, &(&1["threadId"] == id))
  end

  # The current thread once no title is being generated for it. Read from its
  # stream: the sidebar row trails a commit, so it could still show the old state.
  defp settled_title(context) do
    title = World.current(context)
    id = World.thread_id(context, title)

    context
    |> World.await_thread(
      title,
      &(HalC2.StreamState.get(&1, "thread")[id]["titleRegeneration"] == nil),
      10_000
    )
    |> HalC2.StreamState.get("thread")
    |> Map.fetch!(id)
  end

  # Launches the thread "Launched" as the web client does, remembering its first message.
  defp launch(context, project, strategy, fields \\ %{}) do
    text = "List the files in the checkout"

    {{:ok, _}, context} =
      World.launch_thread(
        context,
        project,
        text,
        Map.merge(%{"title" => "Launched", "workspaceStrategy" => strategy}, fields)
      )

    Map.put(context, :launch_text, text)
  end

  defp launched_thread(context) do
    World.await_runs(context, "Launched", ["completed"])
    World.thread(context, "Launched")
  end

  # The directory the fake Codex was started in for the launched thread.
  defp agent_cwd(context) do
    context |> World.codex_requests("thread/start") |> List.last() |> Map.fetch!("cwd")
  end

  # The launched thread's committed changes as `{kind, entity, set fields}`, in
  # order, until `done` holds for them (the launch subscribed the test process).
  defp history(context, done, seen \\ []) do
    id = World.thread_id(context, "Launched")

    if seen != [] and done.(seen) do
      seen
    else
      receive do
        {:hal_c2_stream, ^id, {:events, events}} ->
          changes = for event <- events, do: {event.kind, event.entity, event.patch["s"] || %{}}
          history(context, done, seen ++ changes)
      after
        10_000 -> flunk("the launched thread never got that far: #{inspect(seen)}")
      end
    end
  end

  defp project_threads(context, project) do
    project_id = World.project(context, project).id

    for {id, row} <- World.fresh_shell(context),
        row["projectId"] == project_id,
        into: MapSet.new(),
        do: id
  end

  defp settle_automatically(context, thread, days) do
    at = World.iso_from_now(-World.days(days + 1))

    context =
      context
      |> settings()
      |> write_settings(%{"sidebarAutoSettleAfterDays" => days})
      |> World.patch_thread(thread, %{"createdAt" => at})
      |> World.add_message(thread, "user", "Ship it", at)

    :ok = Settlement.sweep()
    World.await_row(World.thread_id(context, thread), &(&1["settledOverride"] == "settled"))
    context
  end

  # The settlement service reads settings and sweeps only when asked.
  defp settings(context) do
    Mc.ensure(HalC2.Settings)
    Mc.ensure({Settlement, interval: nil})
    context
  end

  defp write_settings(context, patch) do
    {settings, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(deep_merge(settings, patch), version)
    context
  end

  defp deep_merge(a, b),
    do:
      Map.merge(a, b, fn _, x, y -> if is_map(x) and is_map(y), do: deep_merge(x, y), else: y end)

  defp link(context, thread, number) do
    id = World.thread_id(context, thread)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.pull-request.link",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/shop",
        "number" => number,
        "url" => "https://github.com/acme/shop/pull/#{number}",
        "source" => "manual"
      })

    World.await_row(id, &(&1["pullRequests"] != nil and &1["pullRequests"] != []))
    context
  end

  defp sync(context, thread, number, snapshot) do
    id = World.thread_id(context, thread)

    snapshot =
      Map.merge(%{"title" => "PR #{number}", "syncedAt" => World.iso_from_now(0)}, snapshot)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.pull-request-link.sync",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/shop",
        "number" => number,
        "snapshot" => snapshot,
        "stack" => nil
      })

    World.await_row(id, fn row ->
      Enum.any?(row["pullRequests"] || [], &(&1["snapshot"]["state"] == snapshot["state"]))
    end)

    context
  end
end
