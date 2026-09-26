defmodule HalC2.Steps.Orchestration.Threads do
  @moduledoc "Steps for `features/node/orchestration/threads.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node.World

  @model %{"instanceId" => "codex", "model" => "gpt-5.4"}

  # Threads the feature names but never created ("missing") keep their name as id.
  defp id(context, thread), do: (context[:threads] || %{})[thread] || thread

  defp create(context, thread, project, fields) do
    context
    |> put_in([:threads, thread], thread)
    |> Map.put(:thread, thread)
    |> World.command(
      Map.merge(
        %{
          "type" => "thread.create",
          "threadId" => thread,
          "projectId" => World.project(context, project).id,
          "title" => thread,
          "modelSelection" => @model
        },
        fields
      )
    )
  end

  defp thread_command(context, type, thread, fields \\ %{}),
    do:
      World.command(
        context,
        Map.merge(%{"type" => type, "threadId" => id(context, thread)}, fields)
      )

  defp ok!(context) do
    assert {:ok, _} = context.reply, "command failed: #{inspect(context.reply)}"
    Map.delete(context, :reply)
  end

  # The last change the thread's log recorded for the thread entity itself.
  defp last_thread_patch(context, thread) do
    id = id(context, thread)

    context
    |> World.events(thread)
    |> Enum.filter(&(&1.kind == "thread" and &1.entity == id))
    |> List.last()
    |> Map.fetch!(:patch)
  end

  defp mark(context), do: World.thread(context, context.thread)["titleRegeneration"]

  defp await_mark_cleared(context) do
    World.await_state(context, context.thread, fn state ->
      HalC2.StreamState.get(state, "thread")[context.thread]["titleRegeneration"] == nil
    end)

    context
  end

  # A thread with a conversation and a title regeneration in flight (as test setup,
  # with no writer running yet).
  defp regenerating(context, thread, request_id) do
    context =
      context
      |> World.named_thread(thread, nil, %{"title" => "Old title"})
      |> World.add_message(thread, "user", "Fix the login redirect loop")
      |> World.add_message(thread, "assistant", "The redirect loop is fixed.")

    World.patch_thread(context, thread, %{
      "titleRegeneration" => %{"requestId" => request_id, "startedAt" => World.iso_from_now(0)}
    })

    Map.put(context, :title_before, "Old title")
  end

  defp regenerate(context, thread),
    do: thread_command(context, "thread.metadata.update", thread, %{"regenerateTitle" => true})

  defp today(time), do: "#{Date.utc_today()}T#{time}:00.000Z"

  # --- creating -------------------------------------------------------------------

  step "a client creates thread {string} in {string} titled {string}",
       %{args: [thread, project, title]} = context do
    create(context, thread, project, %{"title" => title})
  end

  step "a client creates thread {string} in {string} on branch {string} in worktree {string}",
       %{args: [thread, project, branch, worktree]} = context do
    create(context, thread, project, %{"branch" => branch, "worktreePath" => worktree})
  end

  step "a client creates thread {string} in {string} again",
       %{args: [thread, project]} = context do
    context
    |> Map.put(:thread_before, World.thread(context, thread))
    |> create(thread, project, %{"title" => "Another title"})
  end

  step "thread {string} exists with title {string}", %{args: [thread, title]} = context do
    assert {:ok, _} = context.reply
    assert World.thread(context, thread)["title"] == title
    context
  end

  step "a thread-created event is recorded for {string}", %{args: [thread]} = context do
    [first | _] = World.events(context, thread)
    assert first.kind == "thread" and first.entity == thread
    assert %{"s" => %{"id" => ^thread, "createdAt" => created}} = first.patch
    assert is_binary(created)
    context
  end

  step "the thread's runtime mode is {string} and its interaction mode is {string}",
       %{args: [runtime, interaction]} = context do
    thread = World.thread(context, context.thread)
    assert thread["runtimeMode"] == runtime
    assert thread["interactionMode"] == interaction
    context
  end

  step "thread {string} records branch {string} and worktree {string}",
       %{args: [thread, branch, worktree]} = context do
    assert {:ok, _} = context.reply
    assert %{"branch" => ^branch, "worktreePath" => ^worktree} = World.thread(context, thread)
    context
  end

  step "thread {string} is unchanged", %{args: [thread]} = context do
    assert World.thread(context, thread) == context.thread_before
    context
  end

  step "a client archives thread {string}", %{args: [thread]} = context do
    thread_command(context, "thread.archive", thread)
  end

  step "a client dispatches a command of a type the node does not serve", context do
    context
    |> Map.put(:unserved_type, "thread.teleport")
    |> World.command(%{"type" => "thread.teleport", "threadId" => "t1"})
  end

  step "the command fails saying that type {string}", %{args: [message]} = context do
    assert {:error, error, _} = context.reply
    assert error == "#{context.unserved_type} #{message}"
    context
  end

  # --- metadata -------------------------------------------------------------------

  step "thread {string} exists in {string} titled {string}",
       %{args: [thread, project, title]} = context do
    World.named_thread(context, thread, project, %{"title" => title})
  end

  step "a client updates the metadata of {string} with title {string}",
       %{args: [thread, title]} = context do
    thread_command(context, "thread.metadata.update", thread, %{"title" => title})
  end

  step "a thread-metadata-updated event is recorded", context do
    assert {:ok, _} = context.reply
    title = World.thread(context, context.thread)["title"]

    assert %{"s" => %{"title" => ^title, "updatedAt" => _}} =
             last_thread_patch(context, context.thread)

    context
  end

  @fields %{
    "branch" => "branch",
    "worktree path" => "worktreePath",
    "runtime mode" => "runtimeMode",
    "interaction mode" => "interactionMode"
  }

  step ~r/^a client updates the metadata of "(?<thread>[^"]+)" with (?<field>branch|worktree path) set to "(?<value>[^"]*)"$/,
       %{args: [thread, field, value]} = context do
    context
    |> Map.put(:thread_before, World.thread(context, thread))
    |> thread_command("thread.metadata.update", thread, %{
      @fields[field] => value
    })
  end

  step ~r/^thread "(?<thread>[^"]+)" has (?<field>branch|worktree path|runtime mode|interaction mode) "(?<value>[^"]*)"$/,
       %{args: [thread, field, value]} = context do
    assert {:ok, _} = context.reply
    key = @fields[field]
    after_update = World.thread(context, thread)
    assert after_update[key] == value

    # Only the named field (and the update time) moved.
    assert Map.drop(after_update, [key, "updatedAt"]) ==
             Map.drop(context.thread_before, [key, "updatedAt"])

    context
  end

  step "thread {string} is in worktree {string}", %{args: [thread, worktree]} = context do
    World.named_thread(context, thread, nil, %{"branch" => "main", "worktreePath" => worktree})
  end

  step "a client updates the branch of {string} expecting worktree {string}",
       %{args: [thread, worktree]} = context do
    thread_command(context, "thread.metadata.update", thread, %{
      "branch" => "other",
      "expectedWorktreePath" => worktree
    })
  end

  step "the branch of {string} is unchanged", %{args: [thread]} = context do
    assert World.thread(context, thread)["branch"] == "main"
    context
  end

  # --- title regeneration ---------------------------------------------------------

  step "thread {string} has user and assistant messages", %{args: [thread]} = context do
    context
    |> World.named_thread(thread, nil, %{"title" => "Old title"})
    |> World.add_message(thread, "user", "Fix the login redirect loop")
    |> World.add_message(thread, "assistant", "The redirect loop is fixed.")
  end

  step "a client updates the metadata of {string} asking to regenerate the title",
       %{args: [thread]} = context do
    context
    |> World.text_writers([:codex], %{"title" => "Login redirect fix"})
    |> Map.put(:command_id, "cmd-regenerate")
    |> thread_command("thread.metadata.update", thread, %{
      "regenerateTitle" => true,
      "commandId" => "cmd-regenerate"
    })
  end

  step "thread {string} shows title regeneration started by that command",
       %{args: [thread]} = context do
    assert {:ok, _} = context.reply
    id = context.command_id

    # The mark may already be cleared by a fast writer; the log keeps the change.
    assert Enum.any?(World.events(context, thread), fn event ->
             event.kind == "thread" and
               match?(%{"s" => %{"titleRegeneration" => %{"requestId" => ^id}}}, event.patch)
           end)

    context
  end

  step "a new title is generated from the thread's messages and its previous title", context do
    World.await_state(context, context.thread, fn state ->
      HalC2.StreamState.get(state, "thread")[context.thread]["title"] == "Login redirect fix"
    end)

    assert mark(context) == nil
    assert [%{"prompt" => prompt}] = World.text_calls(context)
    assert prompt =~ "Fix the login redirect loop"
    assert prompt =~ "The redirect loop is fixed."
    assert prompt =~ "Old title"
    context
  end

  step "thread {string} is regenerating its title", %{args: [thread]} = context do
    regenerating(context, thread, "cmd-earlier")
  end

  step "thread {string} is regenerating its title for request {string}",
       %{args: [thread, request]} = context do
    regenerating(context, thread, request)
  end

  step "the generated title equals the current title", context do
    context
    |> World.text_writers([:codex], %{"title" => context.title_before})
    |> regenerate(context.thread)
    |> ok!()
    |> await_mark_cleared()
    |> tap(&assert([_] = World.text_calls(&1)))
  end

  step "title generation fails", context do
    System.put_env("FAKE_TEXT_FAIL", "model unavailable")

    context
    |> World.text_writers([:codex])
    |> regenerate(context.thread)
    |> ok!()
    |> await_mark_cleared()
    |> tap(&assert([_] = World.text_calls(&1)))
  end

  step "thread {string} keeps its title", %{args: [thread]} = context do
    assert World.thread(context, thread)["title"] == context.title_before
    context
  end

  step "the title regeneration mark is cleared", context do
    await_mark_cleared(context)
  end

  step "thread {string} has no messages", %{args: [thread]} = context do
    context |> World.named_thread(thread) |> World.text_writers([:codex])
  end

  step "a client asks to regenerate the title of {string}", %{args: [thread]} = context do
    regenerate(context, thread)
  end

  step "the title regeneration mark is cleared without asking a model", context do
    assert {:ok, _} = context.reply
    await_mark_cleared(context)
    assert World.text_calls(context) == []
    context
  end

  step "a client completes title regeneration {string} with title {string}",
       %{args: [request, title]} = context do
    thread_command(context, "thread.title.regeneration.complete", context.thread, %{
      "requestId" => request,
      "title" => title
    })
  end

  step "a completion for a different request id changes nothing", context do
    assert mark(context) == nil
    # A newer regeneration is in flight; a stale completion must not land.
    World.patch_thread(context, context.thread, %{
      "titleRegeneration" => %{"requestId" => "r-new", "startedAt" => World.iso_from_now(0)}
    })

    before = World.thread(context, context.thread)

    context =
      context
      |> thread_command("thread.title.regeneration.complete", context.thread, %{
        "requestId" => "r-stale",
        "title" => "Stale"
      })
      |> ok!()

    assert World.thread(context, context.thread) == before
    context
  end

  # --- archive, delete ------------------------------------------------------------

  step "thread {string} is not archived", %{args: [thread]} = context do
    assert World.thread(context, thread)["archivedAt"] == nil
    context
  end

  step "a client unarchives {string}", %{args: [thread]} = context do
    thread_command(context, "thread.unarchive", thread)
  end

  step "a thread-archived event is recorded", context do
    archived = World.thread(context, context.thread)["archivedAt"]
    assert %{"s" => %{"archivedAt" => ^archived}} = last_thread_patch(context, context.thread)
    context
  end

  step "a thread-unarchived event is recorded", context do
    assert {:ok, _} = context.reply
    assert %{"s" => %{"archivedAt" => nil}} = last_thread_patch(context, context.thread)
    context
  end

  step "thread {string} has a running turn and two queued messages",
       %{args: [thread]} = context do
    context
    |> World.running_turn(thread)
    |> World.queue_message(thread, "first")
    |> World.queue_message(thread, "second")
  end

  step "both queued runs are cancelled", context do
    assert {:ok, _} = context.reply
    runs = World.entities(context, context.thread, "run")
    queued = Enum.filter(runs, &(&1["id"] in context.queued))
    assert length(queued) == 2
    assert Enum.all?(queued, &(&1["status"] == "cancelled" and &1["queuePosition"] == nil))
    context
  end

  step "thread {string} was archived with a queued message", %{args: [thread]} = context do
    context
    |> World.running_turn(thread)
    |> World.queue_message(thread, "later")
    |> thread_command("thread.archive", thread)
    |> ok!()
  end

  step "the queued message stays cancelled", context do
    assert {:ok, _} = context.reply
    [queued] = context.queued
    run = Enum.find(World.entities(context, context.thread, "run"), &(&1["id"] == queued))
    assert run["status"] == "cancelled"
    context
  end

  step "thread {string} records when it was deleted", %{args: [thread]} = context do
    assert {:ok, _} = context.reply
    assert is_binary(World.thread(context, thread)["deletedAt"])
    context
  end

  step "{string} no longer appears among the project's threads", %{args: [thread]} = context do
    project = World.project(context).id
    World.await_row(thread, &(&1["deletedAt"] != nil))

    live =
      for {{_node, id}, {"thread", row}} <- HalC2.Shell.rows(),
          row["projectId"] == project and row["deletedAt"] == nil,
          do: id

    refute thread in live
    context
  end

  step "thread {string} has a live provider session", %{args: [thread]} = context do
    context =
      context
      |> World.providers()
      |> World.named_thread(thread)
      |> World.dispatch_message(thread, "Hi")
      |> ok!()

    World.await_latest_run(context, thread, "completed")
    [pid] = for {pid, _} <- Registry.lookup(HalC2.Codex.Registry, thread), do: pid
    assert [%{"status" => status}] = World.entities(context, thread, "provider-session")
    assert status != "stopped"
    Map.put(context, :runtime, pid)
  end

  step "the provider session of {string} is stopped before {string} is removed",
       %{args: [thread, _]} = context do
    assert {:ok, _} = context.reply

    assert [%{"status" => "stopped", "id" => session}] =
             World.entities(context, thread, "provider-session")

    refute Process.alive?(context.runtime)

    # The session stops in the same commit that deletes the thread, never after it.
    events = World.events(context, thread)
    stopped = Enum.find(events, &(&1.entity == session and &1.patch["s"]["status"] == "stopped"))
    deleted = Enum.find(events, &(&1.kind == "thread" and is_binary(&1.patch["s"]["deletedAt"])))
    assert stopped.seq <= deleted.seq
    context
  end

  step "a client subscribes to the shell", context do
    client = HalC2.Test.Node.sub(World.client(context), 900, %{"type" => "shell"})
    {%{"t" => "shell"}, client} = HalC2.Test.WsClient.recv(client, 1_000)
    World.put_client(context, client)
  end

  step "the subscriber receives a thread-removed event for {string}",
       %{args: [thread]} = context do
    assert {:ok, _} = context.reply

    {frame, client} =
      HalC2.Test.Node.await(World.client(context), fn frame ->
        frame["t"] == "shell.rows" and
          Enum.any?(
            frame["rows"],
            &match?([^thread, "thread", %{"deletedAt" => d}] when is_binary(d), &1)
          )
      end)

    assert frame["id"] == 900
    World.put_client(context, client)
  end

  # --- read state -----------------------------------------------------------------

  step "thread {string} has a completed turn the user has not seen",
       %{args: [thread]} = context do
    context = World.named_thread(context, thread)
    World.add_run(context, thread, "completed", World.iso_from_now(-60_000))
  end

  step "a client records a visit to {string}", %{args: [thread]} = context do
    at = World.iso_from_now(0)

    context
    |> Map.put(:visited_at, at)
    |> thread_command("thread.visit", thread, %{"visitedAt" => at})
  end

  step "thread {string} is read as of that visit", %{args: [thread]} = context do
    assert {:ok, _} = context.reply
    visited = World.thread(context, thread)["lastVisitedAt"]
    assert visited == context.visited_at
    run = World.latest_run(context, thread)
    assert visited >= run["completedAt"]
    assert World.await_row(thread, &(&1["lastVisitedAt"] == visited))
    context
  end

  step ~r/^thread "(?<thread>[^"]+)" was visited at (?<time>\d\d:\d\d)$/,
       %{args: [thread, time]} = context do
    context
    |> World.named_thread(thread)
    |> thread_command("thread.visit", thread, %{"visitedAt" => today(time)})
    |> ok!()
  end

  step ~r/^thread "(?<thread>[^"]+)" is still read as of (?<time>\d\d:\d\d)$/,
       %{args: [thread, time]} = context do
    assert {:ok, _} = context.reply
    assert World.thread(context, thread)["lastVisitedAt"] == today(time)
    context
  end

  step "thread {string} was visited", %{args: [thread]} = context do
    context
    |> World.named_thread(thread)
    |> thread_command("thread.visit", thread, %{"visitedAt" => World.iso_from_now(0)})
    |> ok!()
  end

  step "thread {string} has no last visit", %{args: [thread]} = context do
    assert {:ok, _} = context.reply
    assert World.thread(context, thread)["lastVisitedAt"] == nil
    context
  end

  step "a thread-marked-unread event is recorded", context do
    assert %{"s" => %{"lastVisitedAt" => nil}} = last_thread_patch(context, context.thread)
    context
  end

  step ~r/^thread "(?<thread>[^"]+)" was last updated at (?<time>\d\d:\d\d)$/,
       %{args: [thread, time]} = context do
    context = World.named_thread(context, thread)
    World.patch_thread(context, thread, %{"updatedAt" => today(time)})
    Map.put(context, :updated_at, World.row(context, thread)["updatedAt"])
  end

  step ~r/^the last activity of thread "(?<thread>[^"]+)" is still (?<time>\d\d:\d\d)$/,
       %{args: [thread, time]} = context do
    assert {:ok, _} = context.reply
    assert World.thread(context, thread)["updatedAt"] == today(time)
    visited = World.thread(context, thread)["lastVisitedAt"]
    row = World.await_row(World.thread_id(context, thread), &(&1["lastVisitedAt"] == visited))
    assert row["updatedAt"] == context.updated_at
    context
  end

  # --- modes ----------------------------------------------------------------------

  step ~r/^a client sets the (?<mode>runtime mode|interaction mode) of "(?<thread>[^"]+)" to "(?<value>[^"]+)"$/,
       %{args: [mode, thread, value]} = context do
    {type, key} =
      case mode do
        "runtime mode" -> {"thread.runtime-mode.set", "runtimeMode"}
        "interaction mode" -> {"thread.interaction-mode.set", "interactionMode"}
      end

    context
    |> Map.put(:thread_before, World.thread(context, thread))
    |> thread_command(type, thread, %{key => value})
  end

  @codex_policies %{
    "approval-required" => "untrusted",
    "auto-accept-edits" => "on-request",
    "full-access" => "never"
  }

  step ~r/^the next turn of "(?<thread>[^"]+)" starts with (?<mode>runtime mode|interaction mode) "(?<value>[^"]+)"$/,
       %{args: [thread, mode, value]} = context do
    context = context |> World.providers() |> World.dispatch_message(thread, "Hi") |> ok!()
    World.await_latest_run(context, thread, "completed")
    [turn] = World.codex_requests(context, "turn/start")

    case mode do
      "runtime mode" -> assert turn["approvalPolicy"] == @codex_policies[value]
      "interaction mode" -> assert turn["collaborationMode"]["mode"] == value
    end

    context
  end

  # --- parent runs ----------------------------------------------------------------

  step "a running turn in thread {string} created thread {string}",
       %{args: [parent, child]} = context do
    context
    |> World.running_turn(parent)
    |> World.named_thread(child, nil, %{"title" => "Child work"})
    |> Map.merge(%{parent: parent, child: child})
  end

  step "the creation is recorded on the parent", context do
    run =
      Enum.find(World.entities(context, context.parent, "run"), &(&1["id"] == context.running))

    World.command(context, %{
      "type" => "thread.created.record",
      "parentThreadId" => context.parent,
      "parentRunId" => run["id"],
      "parentNodeId" => run["rootNodeId"],
      "targetThreadId" => context.child,
      "targetRunId" => nil
    })
  end

  step "the parent's timeline links to {string} and the run that created it",
       %{args: [child]} = context do
    assert {:ok, _} = context.reply
    items = HalC2.Projection.Timeline.local_items(World.state(context, context.parent))

    assert %{"runId" => run_id, "title" => "Child work", "targetModel" => "gpt-5.4"} =
             Enum.find(items, &(&1["type"] == "thread_created" and &1["targetThreadId"] == child))

    assert run_id == context.running
    context
  end
end
