defmodule HalC2.Steps.Parity.Commands do
  @moduledoc """
  Steps for `features/parity/commands.feature`: every aligned command dispatched
  over the socket and seen by a second socket following the thread, and every
  event of the Node server's log imported with `HalC2.Import.V2` into the running
  node's store.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Exqlite.Sqlite3
  alias HalC2.StreamState
  alias HalC2.Test.{Node, WsClient}
  alias HalC2.Test.Node.World

  @support Path.expand("../../support", __DIR__)
  @orchestration Path.expand("../../../lib/hal_c2/orchestration.ex", __DIR__)
  @follow 41
  @url "https://github.com/acme/widgets/pull/"

  # --- background ------------------------------------------------------------------

  step "a paired protocol 3 client with a project and a thread", context do
    fake_providers()

    {:ok, access, _expires, _scopes} =
      HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(context.node.store), %{"label" => "Phone"})

    {:ok, ticket, _} = HalC2.Auth.issue_ticket(access)

    context
    |> World.create_project("Parity")
    |> World.create_thread("Parity thread")
    |> World.put_client("paired", Node.connect(context.node, "wsTicket=#{ticket}"))
  end

  # --- commands --------------------------------------------------------------------

  step "the client dispatches {word}", %{args: [type]} = context do
    # Connect first: the handshake takes any message, and a run's pushes would break it.
    follower = Node.connect(context.node)
    %{command: command, follow: follow, change: change} = prepare(type, context)
    {follower, entities} = subscribe(follower, follow)
    refute change.(entities), "#{type}: the change was there before the command"

    {reply, context} = World.dispatch(context, Map.put(command, "type", type), "paired")

    Map.merge(context, %{
      reply: reply,
      command: Map.put(command, "type", type),
      follower: {follower, entities},
      change: change
    })
  end

  step ~r/^the node accepts it through its (?<kind>dispatch|thread update) path$/,
       %{args: [kind]} = context do
    type = context.command["type"]
    assert {:ok, %{"sequence" => sequence}} = context.reply, "#{type}: #{inspect(context.reply)}"
    assert is_integer(sequence)
    source = File.read!(@orchestration)
    [_, list] = Regex.run(~r/@thread_updates ~w\((.*?)\)/s, source)
    thread_update? = type in String.split(list)

    case kind do
      "thread update" ->
        assert thread_update?, "#{type} is not in @thread_updates"
        missing = Map.put(context.command, "threadId", "th-missing-#{System.unique_integer()}")
        assert {:error, "unknown thread " <> _} = HalC2.Orchestration.dispatch(missing)

      "dispatch" ->
        refute thread_update?, "#{type} is a thread update"

        assert source =~ ~r/def dispatch\(\s*%\{"type" => "#{Regex.escape(type)}"/,
               "#{type} has no dispatch clause of its own"
    end

    context
  end

  step "clients following the thread see the resulting change", context do
    {follower, entities} = context.follower
    deadline = System.monotonic_time(:millisecond) + 10_000
    {_entities, follower} = follow(follower, entities, context.change, deadline)
    World.put_client(context, "follower", follower)
  end

  # --- version 2 events ------------------------------------------------------------

  step "the TypeScript server logged {word} for an entity", %{args: [type]} = context do
    tid = "th-log-#{System.unique_integer([:positive])}"
    {events, expect} = v2_log(type, tid)
    Map.merge(context, %{log: log(events), log_thread: tid, expect: expect})
  end

  step("the node records the same change", context, do: import_log(context))

  step ~r/^it stores (?<what>a .+)$/, %{args: [what]} = context do
    %{kind: kind, id: id} = expect = context.expect
    patches = patches(context.log_thread, kind, id)
    assert patches != [], "no patch on #{kind} #{id}"
    last = List.last(patches)

    case what do
      "a patch that binds the session to the thread" ->
        assert [%{"s" => %{"status" => "ready"}}] = patches

      "a patch that unbinds the session from the thread" ->
        assert last == HalC2.Patch.delete()

      "a patch on the session while the thread is bound to it" ->
        assert %{"s" => %{"status" => "running"}} = last
        assert patches(context.log_thread, kind, "ps-unbound") == []

      "a patch that makes it the active provider thread" ->
        thread = fold(patches(context.log_thread, "thread", context.log_thread))
        assert thread["activeProviderThreadId"] == id

      "a quiet patch on the thread" ->
        assert last["q"] == true

      "a patch on the " <> rest ->
        assert rest == "#{kind} entity"
        refute last["q"]
        assert fold(patches) == expect.entity
    end

    context
  end

  step "streams it to clients following the {word}", %{args: [kind]} = context do
    expect = context.expect
    assert kind == expect.kind
    {_client, entities} = subscribe(Node.connect(context.node), context.log_thread)

    if expect.entity do
      entity = entities[{kind, expect.id}]
      assert entity, "no #{kind} #{expect.id} in the stream snapshot"
      assert entity == HalC2.Web.Wire.entity(kind, expect.entity)
    else
      refute Map.has_key?(entities, {kind, expect.id})
    end

    context
  end

  step "the TypeScript server logged the same message twice with identical content", context do
    tid = "th-log-#{System.unique_integer([:positive])}"
    message = %{"id" => "msg-1", "threadId" => tid, "role" => "user", "text" => "hi"}

    events = [
      {"thread", tid, "thread.created", thread_entity(tid), 2},
      {"thread", tid, "message.updated", message, 2},
      {"thread", tid, "message.updated", message, 2}
    ]

    Map.merge(context, %{log: log(events), log_thread: tid})
  end

  step("the node imports the log", context, do: import_log(context))

  step "it stores one patch", context do
    assert context.import_report.source_events == 3
    assert [%{"s" => _}] = patches(context.log_thread, "message", "msg-1")
    context
  end

  # --- version 1 events ------------------------------------------------------------

  step "the TypeScript server logged {word} for a project", %{args: [type]} = context do
    pid = "proj-log-#{System.unique_integer([:positive])}"
    root = Node.tmp_dir(context.node, "imported")

    created =
      {"project", pid, "project.created",
       %{
         "projectId" => pid,
         "title" => "Imported",
         "workspaceRoot" => root,
         "scripts" => [],
         "createdAt" => iso(0),
         "updatedAt" => iso(0)
       }, 1}

    later =
      case type do
        "project.created" ->
          []

        "project.meta-updated" ->
          [
            {"project", pid, type,
             %{"projectId" => pid, "title" => "Renamed", "updatedAt" => iso(1)}, 1}
          ]

        "project.deleted" ->
          [{"project", pid, type, %{"projectId" => pid, "deletedAt" => iso(1)}, 1}]
      end

    Map.merge(context, %{
      log: log([created | later]),
      log_thread: pid,
      project_event: type,
      project_root: root
    })
  end

  step "it stores the change on the project entity", context do
    pid = context.log_thread
    project = entities(pid)["project"][pid]
    assert project["workspaceRoot"] == context.project_root
    assert project["createdAt"] == iso(0)

    case context.project_event do
      "project.created" ->
        assert %{"title" => "Imported"} = project

      "project.meta-updated" ->
        assert %{"title" => "Renamed", "updatedAt" => "2026-09-01T12:00:01.000Z"} = project

      "project.deleted" ->
        assert %{"title" => "Imported", "deletedAt" => "2026-09-01T12:00:01.000Z"} = project
    end

    context
  end

  step "the TypeScript server logged {word} as a version 1 thread event",
       %{args: [type]} = context do
    tid = "th-v1-#{System.unique_integer([:positive])}"
    {before, event} = v1_log(type, tid)

    rows =
      Enum.with_index(before ++ [event], fn {t, p}, i -> {"thread", tid, t, p, 1, iso(i)} end)

    at = iso(length(before))

    Map.merge(context, %{
      log: log(rows),
      log_without: log(Enum.drop(rows, -1)),
      log_thread: tid,
      v1_event: type,
      v1_at: at
    })
  end

  step "the thread's history includes the change", context do
    tid = context.log_thread
    entities = entities(tid)
    thread = entities["thread"][tid]
    assert thread, "the thread was not imported"
    assert v1_changed?(context.v1_event, thread, entities, context.v1_at), inspect(thread)
    context
  end

  step "the imported thread is the same as without it", context do
    assert context.import_report.source_events == length(context.log_rows)
    store_path = Path.join(Node.tmp_dir(context.node, "without"), "hal-c2.sqlite")

    store =
      ExUnit.Callbacks.start_supervised!({HalC2.Store, path: store_path, name: nil},
        id: :parity_without
      )

    {:ok, _} = HalC2.Import.V2.run(write_log(context, context.log_without), store)
    with_it = entities(context.log_thread)
    assert with_it["thread"][context.log_thread]["title"] == "Imported"
    assert with_it == StreamState.load(HalC2.Store.path(store), context.log_thread).entities
    context
  end

  # --- what each command needs ------------------------------------------------------

  # `%{command, follow, change}`: the command without its type, the stream a
  # follower watches, and the change it should see there.
  defp prepare("thread.create", context) do
    id = "th-created-#{System.unique_integer([:positive])}"

    %{
      command: %{
        "threadId" => id,
        "projectId" => World.project(context).id,
        "title" => "Created",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
      },
      follow: id,
      change: &match?(%{"title" => "Created"}, &1[{"thread", id}])
    }
  end

  defp prepare("thread.archive", context), do: on_thread(context, %{}, &(&1["archivedAt"] != nil))

  defp prepare("thread.unarchive", context) do
    setup!(context, "thread.archive")
    on_thread(context, %{}, &(&1["archivedAt"] == nil))
  end

  defp prepare("thread.delete", context), do: on_thread(context, %{}, &(&1["deletedAt"] != nil))

  defp prepare("thread.settle", context),
    do: on_thread(context, %{}, &(&1["settledOverride"] == "settled"))

  defp prepare("thread.auto-settle", context),
    do:
      on_thread(
        context,
        %{"snapshotAt" => World.iso_from_now(0)},
        &(&1["settledOverride"] == "settled")
      )

  defp prepare("thread.unsettle", context),
    do: on_thread(context, %{}, &(&1["settledOverride"] == "active"))

  defp prepare("thread.snooze", context) do
    until = World.iso_from_now(World.days(1))
    on_thread(context, %{"snoozedUntil" => until}, &(&1["snoozedUntil"] == until))
  end

  defp prepare("thread.unsnooze", context) do
    setup!(context, "thread.snooze", %{"snoozedUntil" => World.iso_from_now(World.days(1))})
    on_thread(context, %{}, &(&1["snoozedUntil"] == nil))
  end

  defp prepare("thread.pin", context),
    do:
      on_thread(
        context,
        %{"orderKey" => "a0"},
        &(&1["pinnedAt"] != nil and &1["pinOrderKey"] == "a0")
      )

  defp prepare("thread.unpin", context) do
    setup!(context, "thread.pin", %{"orderKey" => "a0"})
    on_thread(context, %{}, &(&1["pinnedAt"] == nil))
  end

  defp prepare("thread.pin.reorder", context) do
    setup!(context, "thread.pin", %{"orderKey" => "a0"})
    on_thread(context, %{"orderKey" => "b0"}, &(&1["pinOrderKey"] == "b0"))
  end

  defp prepare("thread.active.reorder", context),
    do: on_thread(context, %{"orderKey" => "c0"}, &(&1["activeOrderKey"] == "c0"))

  defp prepare("thread.visit", context) do
    at = World.iso_from_now(0)
    on_thread(context, %{"visitedAt" => at}, &(&1["lastVisitedAt"] == at))
  end

  defp prepare("thread.mark-unread", context) do
    setup!(context, "thread.visit", %{"visitedAt" => World.iso_from_now(0)})
    on_thread(context, %{}, &(&1["lastVisitedAt"] == nil))
  end

  defp prepare("thread.metadata.update", context),
    do: on_thread(context, %{"title" => "Renamed"}, &(&1["title"] == "Renamed"))

  defp prepare("thread.pull-request.link", context),
    do: on_thread(context, link(7), &(numbers(&1) == [7]))

  defp prepare("thread.pull-request.unlink", context) do
    setup!(context, "thread.pull-request.link", link(7))
    on_thread(context, Map.take(link(7), ~w(host repository number)), &(numbers(&1) == []))
  end

  defp prepare("thread.pull-request-link.sync", context) do
    setup!(context, "thread.pull-request.link", link(7))
    snapshot = %{"state" => "open", "title" => "PR 7", "syncedAt" => World.iso_from_now(0)}

    on_thread(
      context,
      Map.merge(Map.take(link(7), ~w(host repository number)), %{
        "snapshot" => snapshot,
        "stack" => nil
      }),
      &match?([%{"snapshot" => ^snapshot}], HalC2.Projection.PullRequests.of(&1))
    )
  end

  defp prepare("thread.pull-request.sync", context) do
    project = World.project(context)

    found = %{
      "projectId" => project.id,
      "repository" => "acme/widgets",
      "number" => 5,
      "url" => "#{@url}5"
    }

    on_thread(
      context,
      %{
        "projectId" => project.id,
        "expected" => %{
          "workspaceRoot" => project.root,
          "branch" => nil,
          "worktreePath" => nil,
          "linkedPullRequest" => nil,
          "branchPullRequest" => nil
        },
        "branchPullRequest" => found
      },
      &(&1["branchPullRequest"] == found)
    )
  end

  defp prepare("thread.runtime-mode.set", context),
    do:
      on_thread(
        context,
        %{"runtimeMode" => "approval-required"},
        &(&1["runtimeMode"] == "approval-required")
      )

  defp prepare("thread.interaction-mode.set", context),
    do: on_thread(context, %{"interactionMode" => "plan"}, &(&1["interactionMode"] == "plan"))

  defp prepare("thread.model-selection.set", context) do
    selection = %{"instanceId" => "codex", "model" => "gpt-5.5"}
    on_thread(context, %{"modelSelection" => selection}, &(&1["modelSelection"] == selection))
  end

  defp prepare("provider.switch", context) do
    selection = %{"instanceId" => "claudeAgent", "model" => "haiku"}

    on_thread(
      context,
      %{"modelSelection" => selection},
      &(&1["providerInstanceId"] == "claudeAgent")
    )
  end

  defp prepare("provider-session.detach", context) do
    tid = main(context)
    send!(tid, "hello")
    state = await_runs(tid, ["completed"])
    [session] = StreamState.list(state, "provider-session")

    %{
      command: %{"threadId" => tid, "providerSessionId" => session["id"]},
      follow: tid,
      change: &(not Map.has_key?(&1, {"provider-session", session["id"]}))
    }
  end

  defp prepare("message.dispatch", context) do
    tid = main(context)

    %{
      command: %{
        "threadId" => tid,
        "messageId" => "msg-parity",
        "text" => "hello",
        "attachments" => [],
        "dispatchMode" => %{"type" => "queue_after_active"}
      },
      follow: tid,
      change: &match?(%{"text" => "hello", "role" => "user"}, &1[{"message", "msg-parity"}])
    }
  end

  defp prepare("run.interrupt", context) do
    tid = main(context)
    send!(tid, "wait for it")
    [run] = runs(await_runs(tid, ["running"]))
    run_becomes(tid, %{"threadId" => tid}, run["id"], "interrupted")
  end

  defp prepare("queued-message.promote-to-steer", context) do
    {tid, [active, queued]} = queue(context, 1)

    run_becomes(
      tid,
      %{"threadId" => tid, "queuedRunId" => queued["id"], "targetRunId" => active["id"]},
      queued["id"],
      "cancelled"
    )
  end

  defp prepare("queue.resume", context) do
    {tid, [_, queued]} = queue(context, 1)

    {:ok, _} =
      HalC2.Streams.commit(tid, :thread, [{"run", queued["id"], %{"s" => %{"queueHeld" => true}}}])

    %{
      command: %{"threadId" => tid},
      follow: tid,
      change: &match?(%{"queueHeld" => false}, &1[{"run", queued["id"]}])
    }
  end

  defp prepare("queued-run.reorder", context) do
    {tid, [_, second, third]} = queue(context, 2)

    %{
      command: %{"threadId" => tid, "runId" => third["id"], "beforeRunId" => second["id"]},
      follow: tid,
      change: &match?(%{"queuePosition" => 1}, &1[{"run", third["id"]}])
    }
  end

  defp prepare("queued-run.cancel", context) do
    {tid, [_, queued]} = queue(context, 1)
    run_becomes(tid, %{"threadId" => tid, "runId" => queued["id"]}, queued["id"], "cancelled")
  end

  defp prepare("queued-run.edit", context) do
    {tid, [_, queued]} = queue(context, 1)

    %{
      command: %{"threadId" => tid, "runId" => queued["id"], "text" => "edited"},
      follow: tid,
      change: &match?(%{"text" => "edited"}, &1[{"message", queued["userMessageId"]}])
    }
  end

  defp prepare("runtime-request.respond", context) do
    tid = main(context)
    send!(tid, "approve this")
    request = await_request(tid)

    %{
      command: %{"threadId" => tid, "requestId" => request["id"], "decision" => "accept"},
      follow: tid,
      change: &match?(%{"status" => "resolved"}, &1[{"runtime-request", request["id"]}])
    }
  end

  defp prepare("thread.user-input.dismiss", context) do
    selection = %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}}

    tid =
      context
      |> World.create_thread("Claude thread", nil, selection)
      |> World.thread_id("Claude thread")

    send!(tid, "ask me")
    request = await_request(tid)

    %{
      command: %{"threadId" => tid, "requestId" => request["id"]},
      follow: tid,
      change: &match?(%{"status" => "cancelled"}, &1[{"runtime-request", request["id"]}])
    }
  end

  defp prepare("checkpoint.rollback", context) do
    tid = main(context)
    send!(tid, "write a.txt")
    await_runs(tid, ["completed"])
    send!(tid, "write b.txt")
    [_, second] = runs(await_runs(tid, ["completed", "completed"]))
    scope = HalC2.Checkpoint.scope_id(tid)

    run_becomes(
      tid,
      %{
        "threadId" => tid,
        "scopeId" => scope,
        "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope, 1),
        # The thread works in the project root, not a worktree of its own.
        "restoreFiles" => false
      },
      second["id"],
      "rolled_back"
    )
  end

  defp prepare("thread.fork", context) do
    tid = main(context)
    send!(tid, "hello")
    [run] = runs(await_runs(tid, ["completed"]))
    fork = "th-fork-#{System.unique_integer([:positive])}"

    %{
      command: fork_command(tid, fork, run["id"]),
      follow: fork,
      change: &match?(%{"lineage" => %{"parentThreadId" => ^tid}}, &1[{"thread", fork}])
    }
  end

  defp prepare("thread.merge_back", context) do
    tid = main(context)
    send!(tid, "hello")
    [run] = runs(await_runs(tid, ["completed"]))
    fork = "th-fork-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.dispatch(
        Map.put(fork_command(tid, fork, run["id"]), "type", "thread.fork")
      )

    send!(fork, "write fork.txt")
    [_, fork_run] = runs(await_runs(fork, ["completed", "completed"]))

    %{
      command: %{
        "createdBy" => "user",
        "sourceThreadId" => fork,
        "targetThreadId" => tid,
        "sourcePoint" => %{"type" => "run", "runId" => fork_run["id"]}
      },
      follow: tid,
      change: fn entities ->
        Enum.any?(entities, fn {{kind, _}, entity} ->
          kind == "context-transfer" and entity["type"] == "merge_back" and
            entity["sourceThreadId"] == fork
        end)
      end
    }
  end

  defp main(context), do: World.thread_id(context, "Parity thread")

  defp on_thread(context, fields, fun) do
    tid = main(context)

    %{
      command: Map.put(fields, "threadId", tid),
      follow: tid,
      change: &(&1[{"thread", tid}] |> then(fn thread -> thread != nil and fun.(thread) end))
    }
  end

  defp run_becomes(tid, command, run_id, status),
    do: %{
      command: command,
      follow: tid,
      change: &match?(%{"status" => ^status}, &1[{"run", run_id}])
    }

  defp setup!(context, type, fields \\ %{}) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(Map.merge(fields, %{"type" => type, "threadId" => main(context)}))
  end

  defp link(number),
    do: %{
      "host" => "github.com",
      "repository" => "acme/widgets",
      "number" => number,
      "url" => "#{@url}#{number}",
      "source" => "manual"
    }

  defp numbers(thread), do: thread |> HalC2.Projection.PullRequests.of() |> Enum.map(& &1["number"])

  defp fork_command(source, target, run_id),
    do: %{
      "commandId" => "cmd-fork-#{target}",
      "createdBy" => "user",
      "creationSource" => "web",
      "sourceThreadId" => source,
      "targetThreadId" => target,
      "sourcePoint" => %{"type" => "run", "runId" => run_id}
    }

  # A running turn with `count` messages queued behind it; returns the runs in order.
  defp queue(context, count) do
    tid = main(context)
    send!(tid, "wait for it")
    await_runs(tid, ["running"])
    for n <- 1..count, do: send!(tid, "queued #{n}")
    {tid, runs(await_runs(tid, ["running" | List.duplicate("queued", count)]))}
  end

  # --- providers and runs ------------------------------------------------------------

  # The fake Codex, Claude and ACP CLIs of `HalC2.OrchestrationTest`, for runs.
  defp fake_providers do
    for {key, value} <- [
          codex_command: ["python3", "-u", Path.join(@support, "fake_codex.py")],
          claude_command: ["python3", "-u", Path.join(@support, "fake_claude.py")],
          acp_commands: %{"opencode" => ["python3", "-u", Path.join(@support, "fake_acp.py")]}
        ] do
      previous = Application.fetch_env(:hal_c2, key)
      Application.put_env(:hal_c2, key, value)

      ExUnit.Callbacks.on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end)
    end

    for {name, id} <- [
          {HalC2.Codex.Registry, :codex_registry},
          {HalC2.Claude.Registry, :claude_registry},
          {HalC2.Acp.Registry, :acp_registry}
        ],
        do: Node.ensure(Supervisor.child_spec({Registry, keys: :unique, name: name}, id: id))

    Node.ensure({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
  end

  defp send!(tid, text) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => tid,
        "messageId" => "msg-#{System.unique_integer([:positive])}",
        "text" => text,
        "attachments" => [],
        "dispatchMode" => %{"type" => "queue_after_active"}
      })
  end

  defp current(tid), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))
  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  defp await_runs(tid, statuses),
    do: await_state(tid, &(Enum.map(runs(&1), fn run -> run["status"] end) == statuses))

  defp await_request(tid) do
    state =
      await_state(tid, fn state ->
        Enum.any?(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
      end)

    Enum.find(StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
  end

  # Waits on the thread's own stream until its state satisfies `fun`.
  defp await_state(tid, fun) do
    :ok = HalC2.Streams.subscribe(tid, self(), nil)
    await_state(tid, fun, System.monotonic_time(:millisecond) + 10_000)
  end

  defp await_state(tid, fun, deadline) do
    state = current(tid)

    if fun.(state) do
      state
    else
      receive do
        {:halc2_stream, ^tid, _} -> await_state(tid, fun, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("#{tid} never got there: #{inspect(Enum.map(runs(state), & &1["status"]))}")
      end
    end
  end

  # --- following a stream over the socket ----------------------------------------------

  # Subscribes `client` to a stream; returns it with the snapshot's entities by `{kind, id}`.
  defp subscribe(client, stream) do
    client =
      Node.sub(client, @follow, %{
        "type" => "stream",
        "node" => Atom.to_string(node()),
        "stream" => stream
      })

    {_live, skipped, client} =
      WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == @follow), 5_000)

    {client, Enum.reduce(skipped, %{}, &absorb(&2, &1))}
  end

  defp follow(client, entities, change, deadline) do
    if change.(entities) do
      {entities, client}
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 1)

      {frame, client} =
        Node.await(
          client,
          &(&1["t"] in ["snapshot", "events"] and &1["id"] == @follow),
          remaining
        )

      follow(client, absorb(entities, frame), change, deadline)
    end
  end

  defp absorb(entities, %{"t" => "snapshot", "id" => @follow, "rows" => rows}),
    do:
      Enum.reduce(rows, entities, fn [kind, id, entity], acc ->
        Map.put(acc, {kind, id}, entity)
      end)

  defp absorb(entities, %{"t" => "events", "id" => @follow, "events" => events}) do
    Enum.reduce(events, entities, fn [_seq, kind, id, patch, _at], acc ->
      case HalC2.Patch.apply(acc[{kind, id}], patch) do
        nil -> Map.delete(acc, {kind, id})
        entity -> Map.put(acc, {kind, id}, entity)
      end
    end)
  end

  defp absorb(entities, _frame), do: entities

  # --- Node server logs ----------------------------------------------------------------

  defp iso(seconds),
    do:
      ~U[2026-09-01 12:00:00.000Z]
      |> DateTime.add(seconds, :second)
      |> DateTime.to_iso8601()

  # Log rows as `{aggregate, stream, type, payload, version, occurred_at}`.
  defp log(events) do
    events
    |> Enum.with_index()
    |> Enum.map(fn
      {{_, _, _, _, _, _} = row, _} -> row
      {{agg, stream, type, payload, version}, i} -> {agg, stream, type, payload, version, iso(i)}
    end)
  end

  defp import_log(context) do
    {:ok, report} = HalC2.Import.V2.run(write_log(context, context.log), HalC2.Store)
    Map.merge(context, %{import_report: report, log_rows: context.log})
  end

  defp write_log(context, rows) do
    path = Path.join(Node.tmp_dir(context.node, "node-log"), "state.sqlite")
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(db, """
      CREATE TABLE orchestration_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_kind TEXT, stream_id TEXT,
        event_type TEXT, payload_json TEXT, occurred_at TEXT, application_event_version INTEGER)
      """)

    {:ok, stmt} =
      Sqlite3.prepare(db, """
      INSERT INTO orchestration_events (aggregate_kind, stream_id, event_type, payload_json,
        occurred_at, application_event_version) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """)

    for {agg, stream, type, payload, version, at} <- rows do
      :ok = Sqlite3.bind(stmt, [agg, stream, type, JSON.encode!(payload), at, version])
      :done = Sqlite3.step(db, stmt)
    end

    :ok = Sqlite3.release(db, stmt)
    :ok = Sqlite3.close(db)
    path
  end

  defp patches(stream, kind, id) do
    HalC2.Store.path()
    |> HalC2.Store.reduce_stream(stream, 0, [], fn e, acc ->
      if e.kind == kind and e.entity == id, do: [e.patch | acc], else: acc
    end)
    |> Enum.reverse()
  end

  defp fold(patches), do: Enum.reduce(patches, nil, &HalC2.Patch.apply(&2, &1))

  defp entities(stream), do: StreamState.load(HalC2.Store.path(), stream).entities

  defp thread_entity(tid, fields \\ %{}),
    do:
      Map.merge(
        %{
          "id" => tid,
          "projectId" => "parity",
          "title" => "Imported",
          "archivedAt" => nil,
          "settledOverride" => nil,
          "snoozedUntil" => nil,
          "pinnedAt" => nil,
          "pinOrderKey" => nil,
          "activeOrderKey" => nil,
          "lastVisitedAt" => iso(0),
          "deletedAt" => nil,
          "createdAt" => iso(0),
          "updatedAt" => iso(0)
        },
        fields
      )

  # What each thread event changes, from `before` (the thread as created) to `after`.
  @thread_changes %{
    "thread.active-reordered" => {%{}, %{"activeOrderKey" => "a1"}},
    "thread.archived" => {%{}, %{"archivedAt" => "2026-09-01T12:01:00.000Z"}},
    "thread.created" => {%{}, %{}},
    "thread.deleted" => {%{}, %{"deletedAt" => "2026-09-01T12:01:00.000Z"}},
    "thread.interaction-mode-updated" => {%{}, %{"interactionMode" => "plan"}},
    "thread.marked-unread" => {%{}, %{"lastVisitedAt" => nil}},
    "thread.metadata-updated" => {%{}, %{"title" => "Renamed"}},
    "thread.model-selection-updated" =>
      {%{}, %{"modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.5"}}},
    "thread.pinned" => {%{}, %{"pinnedAt" => "2026-09-01T12:01:00.000Z", "pinOrderKey" => "a0"}},
    "thread.pin-reordered" =>
      {%{"pinnedAt" => "2026-09-01T12:00:00.000Z", "pinOrderKey" => "a0"},
       %{"pinOrderKey" => "b0"}},
    "thread.provider-switched" => {%{}, %{"providerInstanceId" => "claudeAgent"}},
    "thread.pull-request-synced" => {%{}, %{"branchPullRequest" => %{"number" => 5}}},
    "thread.runtime-mode-updated" => {%{}, %{"runtimeMode" => "approval-required"}},
    "thread.settled" => {%{}, %{"settledOverride" => "settled"}},
    "thread.snoozed" => {%{}, %{"snoozedUntil" => "2026-09-02T12:00:00.000Z"}},
    "thread.unarchived" =>
      {%{"archivedAt" => "2026-09-01T12:00:00.000Z"}, %{"archivedAt" => nil}},
    "thread.unpinned" =>
      {%{"pinnedAt" => "2026-09-01T12:00:00.000Z", "pinOrderKey" => "a0"},
       %{"pinnedAt" => nil, "pinOrderKey" => nil}},
    "thread.unsettled" => {%{"settledOverride" => "settled"}, %{"settledOverride" => "active"}},
    "thread.unsnoozed" =>
      {%{"snoozedUntil" => "2026-09-02T12:00:00.000Z"}, %{"snoozedUntil" => nil}},
    "thread.visited" => {%{}, %{"lastVisitedAt" => "2026-09-01T12:01:00.000Z"}}
  }

  # The events to log for `type` and what the node should keep: `%{kind, id, entity}`,
  # with `entity: nil` when it should be gone.
  defp v2_log("thread." <> _ = type, tid) do
    {before, change} = Map.fetch!(@thread_changes, type)
    created = thread_entity(tid, before)
    changed = Map.merge(created, change)

    events =
      if type == "thread.created",
        do: [{"thread", tid, type, created, 2}],
        else: [{"thread", tid, "thread.created", created, 2}, {"thread", tid, type, changed, 2}]

    {events, %{kind: "thread", id: tid, entity: changed}}
  end

  defp v2_log("provider-session." <> _ = type, tid) do
    attached = %{"id" => "ps-1", "threadId" => tid, "status" => "ready"}
    base = [created(tid), {"thread", tid, "provider-session.attached", attached, 2}]

    {later, entity} =
      case type do
        "provider-session.attached" ->
          {[], attached}

        "provider-session.detached" ->
          {[{"thread", tid, type, %{"providerSessionId" => "ps-1", "detachedAt" => iso(9)}, 2}],
           nil}

        "provider-session.updated" ->
          running = %{attached | "status" => "running"}
          unbound = %{"id" => "ps-unbound", "threadId" => "th-other", "status" => "running"}
          {[{"thread", tid, type, running, 2}, {"thread", tid, type, unbound, 2}], running}
      end

    {base ++ later, %{kind: "provider-session", id: "ps-1", entity: entity}}
  end

  defp v2_log("provider-thread.updated" = type, tid) do
    entity = %{
      "id" => "pt-1",
      "appThreadId" => tid,
      "status" => "idle",
      "nativeThreadRef" => %{"nativeId" => "native-1"}
    }

    {[created(tid), {"thread", tid, type, entity, 2}],
     %{kind: "provider-thread", id: "pt-1", entity: entity}}
  end

  defp v2_log(type, tid) do
    kind = type |> String.split(".", parts: 2) |> hd()
    id = "#{kind}-1"
    first = %{"id" => id, "threadId" => tid, "status" => "running", "updatedAt" => iso(1)}
    entity = %{first | "status" => "completed", "updatedAt" => iso(2)}

    # An update follows the entity's creation; a creation or capture stands alone.
    events =
      if String.ends_with?(type, ".updated"),
        do: [{"thread", tid, type, first, 2}, {"thread", tid, type, entity, 2}],
        else: [{"thread", tid, type, entity, 2}]

    {[created(tid) | events], %{kind: kind, id: id, entity: entity}}
  end

  defp created(tid), do: {"thread", tid, "thread.created", thread_entity(tid), 2}

  # Version 1 events, as `{type, payload}`: what comes before `type` and `type` itself.
  defp v1_log(type, tid) do
    created =
      {"thread.created",
       %{
         "threadId" => tid,
         "projectId" => "parity",
         "title" => "Imported",
         "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
         "runtimeMode" => "full-access",
         "interactionMode" => "default",
         "branch" => nil,
         "worktreePath" => nil,
         "createdAt" => iso(0),
         "updatedAt" => iso(0)
       }}

    at = &%{"threadId" => tid, "updatedAt" => iso(&1)}
    link = Map.merge(link(7), %{"linkedAt" => iso(1), "snapshot" => nil, "stack" => nil})
    key = Map.take(link, ~w(host repository number))
    user = message(tid, "m1", "user", "hi", "turn-1")

    {before, event} =
      case type do
        "thread.created" ->
          {[], created}

        "thread.deleted" ->
          {[], {type, %{"threadId" => tid, "deletedAt" => iso(1)}}}

        "thread.archived" ->
          {[], {type, Map.put(at.(1), "archivedAt", iso(1))}}

        "thread.unarchived" ->
          {[{"thread.archived", Map.put(at.(1), "archivedAt", iso(1))}], {type, at.(2)}}

        "thread.settled" ->
          {[], {type, Map.put(at.(1), "settledAt", iso(1))}}

        "thread.unsettled" ->
          {[{"thread.settled", Map.put(at.(1), "settledAt", iso(1))}],
           {type, Map.put(at.(2), "reason", "user")}}

        "thread.snoozed" ->
          {[], {type, Map.merge(at.(1), %{"snoozedUntil" => iso(99), "snoozedAt" => iso(1)})}}

        "thread.unsnoozed" ->
          {[
             {"thread.snoozed",
              Map.merge(at.(1), %{"snoozedUntil" => iso(99), "snoozedAt" => iso(1)})}
           ], {type, at.(2)}}

        "thread.pinned" ->
          {[], {type, Map.merge(at.(1), %{"pinnedAt" => iso(1), "pinOrderKey" => "a0"})}}

        "thread.unpinned" ->
          {[{"thread.pinned", Map.merge(at.(1), %{"pinnedAt" => iso(1), "pinOrderKey" => "a0"})}],
           {type, at.(2)}}

        "thread.pin-reordered" ->
          {[{"thread.pinned", Map.merge(at.(1), %{"pinnedAt" => iso(1), "pinOrderKey" => "a0"})}],
           {type, Map.put(at.(2), "orderKey", "b0")}}

        "thread.meta-updated" ->
          {[], {type, Map.merge(at.(1), %{"title" => "Renamed", "branch" => "feature/x"})}}

        "thread.pull-request-linked" ->
          {[], {type, Map.put(at.(1), "link", link)}}

        "thread.pull-request-unlinked" ->
          {[{"thread.pull-request-linked", Map.put(at.(1), "link", link)}],
           {type, Map.merge(at.(2), key)}}

        "thread.pull-request-synced" ->
          {[{"thread.pull-request-linked", Map.put(at.(1), "link", link)}],
           {type,
            at.(2)
            |> Map.merge(key)
            |> Map.merge(%{"snapshot" => %{"state" => "merged"}, "stack" => nil})}}

        "thread.runtime-mode-set" ->
          {[], {type, Map.put(at.(1), "runtimeMode", "approval-required")}}

        "thread.interaction-mode-set" ->
          {[], {type, Map.put(at.(1), "interactionMode", "plan")}}

        "thread.message-sent" ->
          {[], user}

        "thread.reverted" ->
          {[
             user,
             message(tid, "m2", "assistant", "hello", "turn-1"),
             {"thread.turn-diff-completed",
              %{"threadId" => tid, "turnId" => "turn-1", "checkpointTurnCount" => 1}},
             message(tid, "m3", "user", "again", "turn-2"),
             {"thread.turn-diff-completed",
              %{"threadId" => tid, "turnId" => "turn-2", "checkpointTurnCount" => 2}}
           ], {type, %{"threadId" => tid, "turnCount" => 1}}}

        "thread.turn-start-requested" ->
          {[user], {type, %{"threadId" => tid, "messageId" => "m1", "createdAt" => iso(2)}}}

        "thread.turn-interrupt-requested" ->
          {[user], {type, %{"threadId" => tid, "turnId" => "turn-1", "createdAt" => iso(2)}}}

        "thread.checkpoint-revert-requested" ->
          {[user], {type, %{"threadId" => tid, "turnCount" => 0, "createdAt" => iso(2)}}}

        "thread.session-stop-requested" ->
          {[user], {type, %{"threadId" => tid, "createdAt" => iso(2)}}}

        "thread.approval-response-requested" ->
          {[],
           {type,
            %{
              "threadId" => tid,
              "requestId" => "req-1",
              "decision" => "accept",
              "createdAt" => iso(1)
            }}}

        "thread.user-input-response-requested" ->
          {[],
           {type,
            %{"threadId" => tid, "requestId" => "req-1", "answers" => %{}, "createdAt" => iso(1)}}}

        "thread.session-set" ->
          {[],
           {type,
            %{
              "threadId" => tid,
              "session" => %{"threadId" => tid, "status" => "ready", "updatedAt" => iso(1)}
            }}}

        "thread.proposed-plan-upserted" ->
          {[],
           {type,
            %{
              "threadId" => tid,
              "proposedPlan" => %{"id" => "plan-1", "planMarkdown" => "# Plan"}
            }}}

        "thread.turn-diff-completed" ->
          {[], {type, %{"threadId" => tid, "turnId" => "turn-1", "checkpointTurnCount" => 1}}}

        "thread.activity-appended" ->
          {[],
           {type,
            %{"threadId" => tid, "activity" => %{"id" => "act-1", "kind" => "tool.started"}}}}
      end

    {if(type == "thread.created", do: before, else: [created | before]), event}
  end

  defp message(tid, id, role, text, turn),
    do:
      {"thread.message-sent",
       %{
         "threadId" => tid,
         "messageId" => id,
         "role" => role,
         "text" => text,
         "attachments" => [],
         "turnId" => turn,
         "streaming" => false,
         "createdAt" => iso(1),
         "updatedAt" => iso(1)
       }}

  # Whether the imported thread shows what `type` did.
  defp v1_changed?(type, thread, entities, at) do
    case type do
      "thread.created" ->
        thread["title"] == "Imported" and thread["historyOrigin"] == "v1_import"

      "thread.deleted" ->
        thread["deletedAt"] == iso(1)

      "thread.archived" ->
        thread["archivedAt"] == iso(1)

      "thread.unarchived" ->
        thread["archivedAt"] == nil and thread["updatedAt"] == iso(2)

      "thread.settled" ->
        thread["settledOverride"] == "settled" and thread["settledAt"] == iso(1)

      "thread.unsettled" ->
        thread["settledOverride"] == "active" and thread["settledAt"] == nil

      "thread.snoozed" ->
        thread["snoozedUntil"] == iso(99)

      "thread.unsnoozed" ->
        thread["snoozedUntil"] == nil and thread["updatedAt"] == iso(2)

      "thread.pinned" ->
        thread["pinnedAt"] == iso(1) and thread["pinOrderKey"] == "a0"

      "thread.unpinned" ->
        thread["pinnedAt"] == nil and thread["pinOrderKey"] == nil

      "thread.pin-reordered" ->
        thread["pinOrderKey"] == "b0"

      "thread.meta-updated" ->
        thread["title"] == "Renamed" and thread["branch"] == "feature/x"

      "thread.pull-request-linked" ->
        numbers(thread) == [7]

      "thread.pull-request-unlinked" ->
        numbers(thread) == []

      "thread.pull-request-synced" ->
        match?([%{"snapshot" => %{"state" => "merged"}}], HalC2.Projection.PullRequests.of(thread))

      "thread.runtime-mode-set" ->
        thread["runtimeMode"] == "approval-required"

      "thread.interaction-mode-set" ->
        thread["interactionMode"] == "plan"

      "thread.message-sent" ->
        match?(%{"text" => "hi", "role" => "user"}, entities["message"]["m1"]) and
          match?(%{"type" => "user_message"}, entities["turn-item"]["migration:v1:turn-item:m1"])

      "thread.reverted" ->
        Map.keys(entities["message"]) |> Enum.sort() == ["m1", "m2"] and thread["updatedAt"] == at

      # Plans, activities, sessions, diffs and responses are not migrated; they move the thread.
      _ ->
        thread["updatedAt"] == at and at != iso(0)
    end
  end
end
