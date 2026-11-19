defmodule HalC2.Steps.Plugins.Office do
  @moduledoc """
  Steps for `features/plugins/office.feature`, run against the real package in the
  repository's `plugins/office`, copied into the MC's plugins directory as a user would
  install it.

  Threads are real threads of the project "api"; what their agents do is set up on
  their streams (runs, requests, items), as the sidebar rows the plugin reads show it,
  and what the agents call is fed to the plugin as the MC's turn feed would
  (`HalC2.Plugins.observe/1`), in Claude's shapes. The `office` topic is watched from
  the start, and every step waits on it: a thread made is waited for until it is in
  the office, so a later step that looks for it gone sees a change, not the start.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @id "office"
  @package Path.expand("../../../../../plugins/office", __DIR__)
  @project "api"

  # --- background ------------------------------------------------------------------------

  step "an MC running the office plugin", context do
    dir = Path.join([context.mc.home, "plugins", @id])
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(@package, dir)

    context =
      context
      |> World.create_project(@project)
      |> Fixtures.ensure()
      |> Fixtures.rescan()

    accepted = Enum.map(Fixtures.entry(@id)["permissions"], & &1["id"])

    {_, context} =
      World.call!(context, "plugins.enable", %{"id" => @id, "acceptPermissions" => accepted})

    assert %{"status" => "running"} = Fixtures.entry(@id)
    watch(context)
  end

  step "the office plugin seats at most {int} people", %{args: [n]} = context do
    save(context, %{"maxPeople" => n})
  end

  step "the office plugin keeps idle threads for {int} hour", %{args: [n]} = context do
    save(context, %{"idleHours" => n})
  end

  # --- threads ---------------------------------------------------------------------------

  step "a thread {string} in the project {string}", %{args: [title, project]} = context do
    thread(context, title, project)
  end

  step "threads {string} and {string} in the project {string}",
       %{args: [a, b, project]} = context do
    Enum.reduce([a, b], context, &thread(&2, &1, project))
  end

  step "threads {string}, {string}, {string} and {string} in the project {string}",
       %{args: [a, b, c, d, project]} = context do
    Enum.reduce([a, b, c, d], context, &thread(&2, &1, project))
  end

  # Waited for until it has left, so the office it comes back to is a change.
  step "a settled thread {string} in the project {string}", %{args: [title, project]} = context do
    context
    |> thread(title, project)
    |> settle(title)
    |> await_people(&(title not in &1))
  end

  step "an idle thread {string}, a working thread {string} and an asking thread {string}",
       %{args: [idle, busy, asks]} = context do
    context
    |> thread(idle)
    |> thread(busy)
    |> start_turn(busy)
    |> thread(asks)
    |> start_turn(asks)
    |> ask(asks)
  end

  step "a thread {string} idle for {int} hours and a thread {string} idle for a minute",
       %{args: [old, hours, recent]} = context do
    context
    |> thread(old)
    |> thread(recent)
    |> quiet(old, hours * 3_600_000)
    |> quiet(recent, 60_000)
  end

  step "a thread {string} moved to another machine", %{args: [title]} = context do
    context
    |> thread(title)
    |> World.patch_thread(title, %{
      "movedTo" => %{"mc" => "hal-c2@elsewhere", "label" => "Elsewhere", "at" => now()}
    })
  end

  # Marked as `HalC2.Plugins.Host.launch_thread/4` marks a thread a plugin started.
  step "a review thread {string} the code-review plugin started", %{args: [title]} = context do
    started(context, title, "code-review", "review")
  end

  step "a thread {string} the issue-tracker plugin started to implement an issue",
       %{args: [title]} = context do
    started(context, title, "issue-tracker", "implement")
  end

  step "a thread {string} with a worker {string}", %{args: [lead, worker]} = context do
    context
    |> thread(lead)
    |> worker(lead, worker)
  end

  step ~r/^"(?<a>[^"]+)" is archived, "(?<b>[^"]+)" is deleted and "(?<c>[^"]+)" is settled$/,
       %{args: [archived, deleted, settled]} = context do
    context
    |> World.patch_thread(archived, %{"archivedAt" => now()})
    |> World.patch_thread(deleted, %{"deletedAt" => now()})
    |> settle(settled)
  end

  # --- what agents do --------------------------------------------------------------------

  step "its agent starts a turn and edits a file", context do
    context
    |> start_turn(context.thread)
    |> item(context.thread, %{
      "itemType" => "file_change",
      "tool" => "Edit",
      "path" => "lib/parser.ex",
      "input" => JSON.encode!(%{"file_path" => "lib/parser.ex"})
    })
  end

  step "its agent starts a turn", context do
    start_turn(context, context.thread)
  end

  step "its agent runs {string}", %{args: [command]} = context do
    item(context, context.thread, %{
      "itemType" => "command_execution",
      "tool" => "Bash",
      "input" => command
    })
  end

  step "its agent starts a turn and calls {string}", %{args: [tool]} = context do
    context
    |> start_turn(context.thread)
    |> item(context.thread, call(tool, %{"pattern" => "parse"}))
  end

  step "its agent starts a turn and calls {string} to {string}",
       %{args: ["Bash", command]} = context do
    context
    |> start_turn(context.thread)
    |> item(context.thread, %{
      "itemType" => "command_execution",
      "tool" => "Bash",
      "input" => command
    })
  end

  step "its agent asks for approval to run a command", context do
    context
    |> start_turn(context.thread)
    |> ask(context.thread)
  end

  step "the user approves it", context do
    title = context.thread

    World.put_entity(context, title, "runtime-request", context.request, %{
      "s" => %{"status" => "resolved", "resolvedAt" => now()}
    })
  end

  # Waited for at work first, so the idle office that follows is the turn's end, not
  # the thread as it was made.
  step "its agent finishes a turn", context do
    title = context.thread

    context
    |> start_turn(title)
    |> await_person(title, &(&1["state"] == "working"))
    |> then(&World.add_run(&1, title, "completed", nil, %{"id" => &1.run}))
  end

  step "its next turn fails", context do
    World.add_run(context, context.thread, "failed")
  end

  step "its agent ends its turn waiting on a worker it delegated to", context do
    title = context.thread
    context = World.add_run(context, title, "completed")
    run = World.row(context, title)["latestRunId"]

    World.add_item(context, title, "item-worker", "subagent", run, %{
      "status" => "running",
      "completedAt" => nil,
      "title" => "Write the tests"
    })
  end

  step "its agent delegates {string} to a worker", %{args: [task]} = context do
    lead = context.thread
    context = start_turn(context, lead)
    context = worker(context, lead, task)
    child = World.thread_id(context, task)

    # The MCP tool's answer, as Claude hands it on: the tool's text content, JSON in it.
    output =
      JSON.encode!(%{
        "content" => [
          %{
            "type" => "text",
            "text" => JSON.encode!(%{"taskId" => "task-1", "childThreadId" => child})
          }
        ]
      })

    item(
      context,
      lead,
      call("mcp__hal-c2__delegate_task", %{"title" => task, "task" => task <> "\n\nDetails."},
        output: output
      )
    )
  end

  step "the agent of {string} sends {string} the message {string}",
       %{args: [from, to, text]} = context do
    context
    |> start_turn(from)
    |> send_message(from, to, text)
  end

  step "its agent sends the worker {int} messages", %{args: [n]} = context do
    context = start_turn(context, context.lead)

    Enum.reduce(1..n, context, fn i, context ->
      send_message(context, context.lead, context.worker, "Message #{i}")
    end)
  end

  step "the worker ends its turn saying {string}", %{args: [text]} = context do
    worker = context.worker
    run = "run-#{System.unique_integer([:positive])}"

    context
    |> start_turn(worker, run)
    |> item(worker, %{"itemType" => "assistant_message", "text" => text <> "\n\nMore below."})
    |> observe(%{
      "type" => "turn.finished",
      "threadId" => World.thread_id(context, worker),
      "runId" => run,
      "status" => "completed"
    })
  end

  # Every talk said ten minutes earlier, and the timer the plugin set for the first
  # to grow too old fired: nothing else happens to make it look again.
  step "ten minutes pass with nothing else said or done", context do
    office = Process.whereis(HalC2Plugins.Office)
    test = self()

    :sys.replace_state(office, fn state ->
      send(test, {:expire_in, state.expire && Process.cancel_timer(state.expire)})
      talks = Enum.map(state.floor.talks, &Map.update!(&1, "at", fn at -> earlier(at) end))
      %{state | floor: %{state.floor | talks: talks}}
    end)

    assert_received {:expire_in, ms} when is_integer(ms) and ms <= 600_001
    send(office, :expire)
    context
  end

  step "the project {string} is renamed {string}", %{args: [project, title]} = context do
    id = World.project(context, project).id

    {:ok, _} =
      HalC2.Projects.mutate(%{"type" => "project.update", "projectId" => id, "title" => title})

    context
  end

  # --- the office --------------------------------------------------------------------------

  step "the office has {string} in the project {string}", %{args: [title, project]} = context do
    await_person(context, title, &(&1["project"] == project))
  end

  step ~r/^the office has "(?<title>[^"]+)" (?<state>[a-z]+), (?<activity>[a-z]+)$/,
       %{args: [title, state, activity]} = context do
    await_person(context, title, &(&1["state"] == state and &1["activity"] == activity))
  end

  step "the office has {string} asking, with the question's kind", %{args: [title]} = context do
    await_person(context, title, fn person ->
      person["state"] == "asking" and
        match?(
          %{"kind" => "approval", "since" => since} when is_binary(since),
          person["question"]
        )
    end)
  end

  step "the office has {string} {word}", %{args: [title, state]} = context do
    await_person(context, title, &(&1["state"] == state))
  end

  step "the office has the worker {string} whose parent is {string}",
       %{args: [worker, lead]} = context do
    parent = World.thread_id(context, lead)
    await_person(context, worker, &(&1["parentId"] == parent))
  end

  step "the office has {string} as a reviewer", %{args: [title]} = context do
    await_person(context, title, &(&1["kind"] == "reviewer"))
  end

  step "the office has {string}, not as a reviewer", %{args: [title]} = context do
    await_person(context, title, &(Map.fetch(&1, "kind") == {:ok, nil}))
  end

  step "the office has {string} and none of the others", %{args: [title]} = context do
    await_people(context, &(&1 == [title]))
  end

  step "the office has {string} and {string} and not {string}",
       %{args: [a, b, gone]} = context do
    await_people(context, &(Enum.sort(&1) == Enum.sort([a, b]) and gone not in &1))
  end

  step "the office has {string} and not {string}", %{args: [kept, gone]} = context do
    await_people(context, &(kept in &1 and gone not in &1))
  end

  step "the office does not have {string}", %{args: [title]} = context do
    await_people(context, &(title not in &1))
  end

  step "the office has a {string} talk from {string} to {string} saying {string}",
       %{args: [kind, from, to, text]} = context do
    from = World.thread_id(context, from)
    to = World.thread_id(context, to)

    {_, context} =
      await_topic(context, fn office ->
        Enum.find(
          office["talks"],
          &match?(%{"kind" => ^kind, "from" => ^from, "to" => ^to, "text" => ^text}, &1)
        )
      end)

    context
  end

  step "the office has no talks", context do
    {_, context} = await_topic(context, &(&1["talks"] == []))
    context
  end

  step "the office has the newest {int} talks", %{args: [n]} = context do
    want = Enum.map((50 - n + 1)..50, &"Message #{&1}")

    {_, context} =
      await_topic(context, &(Enum.map(&1["talks"], fn talk -> talk["text"] end) == want))

    {:ok, office} = plugin(context, "office")
    assert length(office["talks"]) == n
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  # Makes a thread and waits until it is in the office.
  defp thread(context, title, project \\ @project) do
    context = World.create_thread(context, title, project)
    {_, context} = await_topic(context, &person(&1, title))
    Map.put(context, :thread, title)
  end

  # A thread a plugin started. It takes its title with the mark, so the office that has
  # it by that title has heard the mark too.
  defp started(context, title, plugin, kind) do
    context =
      context
      |> World.create_thread(title, @project, %{"title" => "Starting"})
      |> World.patch_thread(title, %{
        "title" => title,
        "plugin" => %{"id" => plugin, "kind" => kind, "listed" => true},
        "createdBy" => "system",
        "creationSource" => "server"
      })

    {_, context} = await_topic(context, &person(&1, title))
    Map.put(context, :thread, title)
  end

  # A worker of `lead`'s, as a delegated task's thread is made: a subagent of it.
  defp worker(context, lead, title) do
    lead_id = World.thread_id(context, lead)

    context =
      context
      |> World.create_thread(title, @project)
      |> World.patch_thread(title, %{
        "lineage" => %{
          "parentThreadId" => lead_id,
          "relationshipToParent" => "subagent",
          "rootThreadId" => lead_id
        }
      })

    {_, context} = await_topic(context, &((person(&1, title) || %{})["parentId"] == lead_id))
    Map.merge(context, %{thread: lead, lead: lead, worker: title})
  end

  defp settle(context, title),
    do:
      World.patch_thread(context, title, %{"settledAt" => now(), "settledOverride" => "settled"})

  # A run under way on the thread, and its start heard.
  defp start_turn(context, title, run \\ nil) do
    run = run || "run-#{System.unique_integer([:positive])}"
    context = World.add_run(context, title, "running", nil, %{"id" => run})

    observe(context, %{
      "type" => "turn.started",
      "threadId" => World.thread_id(context, title),
      "runId" => run,
      "projectId" => @project,
      "instanceId" => "claudeAgent",
      "provider" => "claudeAgent",
      "model" => "claude-opus-5-5",
      "newConversation" => false
    })
    |> Map.put(:run, run)
  end

  defp ask(context, title) do
    request = "request-#{System.unique_integer([:positive])}"

    context
    |> World.put_entity(title, "runtime-request", request, %{
      "s" => %{
        "id" => request,
        "threadId" => World.thread_id(context, title),
        "kind" => "approval",
        "status" => "pending",
        "createdAt" => now()
      }
    })
    |> Map.put(:request, request)
  end

  # Sets a thread's row to have last changed `ms` ago, as a thread quiet that long shows.
  defp quiet(context, title, ms) do
    id = World.thread_id(context, title)
    :ok = HalC2.Streams.flush_shell(id)
    at = World.iso_from_now(-ms)
    row = World.row(context, title)
    HalC2.Shell.put_row(id, {"thread", %{row | "updatedAt" => at, "createdAt" => at}})
    World.await_row(id, &(&1["updatedAt"] == at))
    context
  end

  defp send_message(context, from, to, text) do
    item(
      context,
      from,
      call("mcp__hal-c2__hal_c2_thread_send", %{
        "threadId" => World.thread_id(context, to),
        "message" => text
      })
    )
  end

  # A Claude tool call as the turn feed hands it on: Bash and the web tools have item
  # types of their own; everything else is a dynamic tool.
  defp call(tool, input, opts \\ []) do
    %{
      "itemType" => if(tool in ~w(WebSearch WebFetch), do: "web_search", else: "dynamic_tool"),
      "tool" => tool,
      "input" => JSON.encode!(input),
      "output" => opts[:output]
    }
  end

  defp item(context, title, fields) do
    observe(
      context,
      Map.merge(
        %{
          "type" => "turn.item",
          "threadId" => World.thread_id(context, title),
          "runId" => context[:run],
          "provider" => "claudeAgent",
          "projectId" => @project,
          "itemId" => "item-#{System.unique_integer([:positive])}",
          "status" => "completed",
          "title" => fields["tool"],
          "ordinal" => System.unique_integer([:positive, :monotonic])
        },
        fields
      )
    )
  end

  defp observe(context, event) do
    :ok = HalC2.Plugins.observe(event)
    context
  end

  defp await_person(context, title, fun) do
    {_, context} = await_topic(context, &((person = person(&1, title)) && fun.(person)))
    context
  end

  defp await_people(context, fun) do
    {_, context} = await_topic(context, &fun.(Enum.map(&1["people"], fn p -> p["title"] end)))
    context
  end

  defp person(office, title), do: Enum.find(office["people"], &(&1["title"] == title))

  defp now, do: World.iso_from_now(0)

  defp earlier(iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    at |> DateTime.add(-600_000, :millisecond) |> DateTime.to_iso8601()
  end

  defp save(context, patch) do
    {_, context} =
      World.call!(context, "plugins.saveSettings", %{"id" => @id, "settings" => patch})

    context
  end

  defp plugin(context, method) do
    {reply, _} =
      World.call(context, "plugins.call", %{"id" => @id, "method" => method, "input" => %{}})

    reply
  end

  defp watch(context) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "office"
    }

    client = context |> World.client("office") |> Mc.sub(sub, shape)

    context
    |> World.put_client("office", client)
    |> Map.put(:watched, {sub, nil})
  end

  # Waits until the `office` topic's value satisfies `fun`, the value last seen first.
  defp await_topic(context, fun) do
    {sub, last} = context.watched

    if found = last && fun.(last) do
      {found, context}
    else
      {frame, client} =
        Mc.await(
          World.client(context, "office"),
          &(&1["t"] == "plugin" and &1["id"] == sub and !!fun.(&1["value"])),
          15_000
        )

      context =
        context
        |> World.put_client("office", client)
        |> Map.put(:watched, {sub, frame["value"]})

      {fun.(frame["value"]), context}
    end
  end
end
