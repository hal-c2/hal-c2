defmodule HalC2.Steps.Space.AgentInPage do
  @moduledoc """
  Steps for `features/space/agent-in-page.feature`. The agent is the fake Codex in a real
  thread; a text with "wait" keeps its turn open until a step ends it. The thread of the
  agent asked on a page goes by the title `agent of <page>` in the scenario's threads, so
  the thread helpers of `HalC2.Test.Mc.World` take it like any other.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.{Space, StreamState, Streams}
  alias HalC2.Test.Mc.World

  step "the user asks {string} on the page {string}", %{args: [request, title]} = context do
    context = World.providers(context)
    id = page_id(context, title)

    payload = %{"spaceId" => context.space, "pageId" => id, "request" => request}
    {reply, context} = World.call(context, "space.page.askAgent", payload)
    context = Map.put(context, :space_reply, reply)

    case reply do
      {:ok, %{"agent" => %{"threadId" => thread_id}}} ->
        context = remember(context, title, id, thread_id)

        if String.contains?(request, "wait") and launches?() do
          World.await_latest_run(context, thread(title), "running")
          World.await_row(thread_id, &is_binary(&1["title"]))
        end

        context

      _ ->
        context
    end
  end

  step "the user stops the agent of {string}", %{args: [title]} = context do
    request(context, "space.page.stopAgent", title)
  end

  step "the user dismisses the agent of {string}", %{args: [title]} = context do
    request(context, "space.page.dismissAgent", title)
  end

  step "the agent of {string} adds the block {string}", %{args: [title, text]} = context do
    arguments = %{
      "spaceId" => context.space,
      "pageId" => page_id(context, title),
      "kind" => "paragraph",
      "text" => text
    }

    assert {:ok, _} =
             World.mcp_tool(context, thread(title), "hal_c2_page_block_insert", arguments)

    context
  end

  step "the agent of {string} tries to add a block", %{args: [title]} = context do
    arguments = %{
      "spaceId" => context.space,
      "pageId" => page_id(context, title),
      "kind" => "paragraph",
      "text" => "Too late"
    }

    Map.put(
      context,
      :page_tool,
      World.mcp_tool(context, thread(title), "hal_c2_page_block_insert", arguments)
    )
  end

  step "the agent of {string} finishes", %{args: [title]} = context do
    context = complete(context, thread(title), "completed", nil)
    await_agent(context, title, &(&1["status"] == "completed"))
    context
  end

  step "the agent of {string} finishes its turn", %{args: [title]} = context do
    context = complete(context, thread(title), "completed", nil)
    World.await_runs(context, thread(title), ["completed", "running"])
    context
  end

  step "the agent of {string} leaves a command running in the background",
       %{args: [title]} = context do
    name = thread(title)
    [run | _] = World.state(context, name) |> StreamState.list("run")

    World.put_entity(context, name, "turn-item", "background-command", %{
      "s" => %{
        "id" => "background-command",
        "threadId" => World.thread_id(context, name),
        "runId" => run["id"],
        "ordinal" => 1_000,
        "type" => "command_execution",
        "status" => "running",
        "input" => "npm run dev"
      }
    })
  end

  step "the run of the agent of {string} ends", %{args: [title]} = context do
    context = complete(context, thread(title), "completed", nil)
    World.await_runs(context, thread(title), ["completed"])
    context
  end

  step "the agent of {string} fails with {string}", %{args: [title, message]} = context do
    complete(context, thread(title), "failed", %{"message" => message})
  end

  step "the user sends {string} to the agent of {string} behind its run",
       %{args: [text, title]} = context do
    World.queue_message(context, thread(title), text)
  end

  step "the user cancels the message behind the run of the agent of {string}",
       %{args: [title]} = context do
    [queued] =
      for run <- World.state(context, thread(title)) |> StreamState.list("run"),
          run["status"] == "queued",
          do: run

    context =
      World.command(context, %{
        "type" => "queued-run.cancel",
        "threadId" => World.thread_id(context, thread(title)),
        "runId" => queued["id"]
      })

    assert {:ok, _} = context.reply
    context
  end

  step "the user sends {string} to the agent of {string}", %{args: [text, title]} = context do
    World.run_turn(context, thread(title), text)
  end

  step "the thread of the agent of {string} is deleted", %{args: [title]} = context do
    id = World.thread_id(context, thread(title))
    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})
    context
  end

  step "the agent's thread of {string} does not continue after a restart",
       %{args: [_title]} = context do
    World.update_settings(context, %{"continueThreadsAfterServerUpdate" => false})
    context
  end

  step "the agent's thread of {string} continues after a restart",
       %{args: [_title]} = context do
    World.update_settings(context, %{"continueThreadsAfterServerUpdate" => true})
    context
  end

  # The stop is marked and the crash takes the interrupt with it.
  step "the MC goes down as the user stops the agent of {string}", %{args: [title]} = context do
    id = page_id(context, title)

    {:ok, _} =
      Space.transact(context.space, fn state ->
        agent = StreamState.get(state, "pageAgent")[id]
        stopping = Map.put(agent, "status", "stopping")
        {[{"pageAgent", id, HalC2.Patch.diff(agent, stopping)}], {:ok, stopping}}
      end)

    context
  end

  # So the restart puts it back in the queue (`HalC2.Orchestration.Recovery`).
  step "the provider never got the run of the agent of {string}", %{args: [title]} = context do
    id = World.thread_id(context, thread(title))

    Streams.transact(id, :thread, fn state ->
      run = HalC2.Projection.Shell.latest_run(StreamState.list(state, "run"))

      unstarted =
        Map.merge(run, %{"status" => "starting", "startedAt" => nil, "activeAttemptId" => nil})

      {[{"run", run["id"], HalC2.Patch.diff(run, unstarted)}], :ok}
    end)

    context
  end

  step "the agent's thread of {string} did not go on", %{args: [title]} = context do
    :ok = HalC2.Orchestration.Effects.drain(World.thread_id(context, thread(title)))

    assert [%{"status" => status}] =
             World.state(context, thread(title)) |> StreamState.list("run")

    assert status in ~w(interrupted cancelled)
    context
  end

  # The continuation asks for the provider the run was on, so it is refused.
  step "the provider the agent's thread of {string} ran on is gone",
       %{args: [title]} = context do
    id = World.thread_id(context, thread(title))

    Streams.transact(id, :thread, fn state ->
      run = HalC2.Projection.Shell.latest_run(StreamState.list(state, "run"))
      gone = Map.put(run, "modelSelection", %{"instanceId" => "gone", "model" => "gone"})
      {[{"run", run["id"], HalC2.Patch.diff(run, gone)}], :ok}
    end)

    context
  end

  step "the agent's thread of {string} continues its work", %{args: [title]} = context do
    World.await_runs(context, thread(title), ["interrupted", "running"])
    context
  end

  step "the user keeps the agent's thread of {string}", %{args: [title]} = context do
    Map.put(context, :kept_thread, thread(title))
  end

  step "the kept agent's thread finishes", context do
    context = complete(context, context.kept_thread, "completed", nil)
    World.await_runs(context, context.kept_thread, ["completed"])
    context
  end

  step "no project is left on this MC", context do
    id = World.thread_id(context, "Work")
    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})
    {:ok, _} = HalC2.Projects.mutate(%{"type" => "project.delete", "projectId" => "shop"})
    World.await_row("shop", &(&1["deletedAt"] != nil))
    context
  end

  step "the project {string} keeps agents away from the HAL-C2 tools",
       %{args: [project]} = context do
    World.update_settings(context, %{
      "projectSettingsOverrides" => %{project => %{"enableAgentBrowserAccess" => false}}
    })

    context
  end

  step "a plugin started a newer thread in the project {string}",
       %{args: [project]} = context do
    background_thread(context, project, "system", plugin: %{"id" => "p", "kind" => "k"})
  end

  step "an agent started a newer thread in the project {string}",
       %{args: [project]} = context do
    background_thread(context, project, "agent", [])
  end

  step "the project {string} overrides its model with one on a turned off provider",
       %{args: [project]} = context do
    off = %{"instanceId" => "off", "model" => "gpt-off"}

    World.update_settings(context, %{
      "providerInstances" => %{"off" => %{"driver" => "codex", "enabled" => false}},
      "projectSettingsOverrides" => %{project => %{"defaultModelSelection" => off}}
    })
  end

  step "the MC goes down before an agent's thread can start", context do
    World.put_app_env(:page_agent_launch, fn _ -> {:ok, %{}} end)
    context
  end

  # The run is over but nothing reported it, as when the MC goes down at that moment.
  step "the page is never told how its agent's run ended", context do
    World.put_app_env(:page_agent_launch, &ended_untold/1)
    context
  end

  step "no provider can start a thread", context do
    World.put_app_env(:page_agent_launch, fn _ -> {:error, "No provider can start."} end)
    context
  end

  step "the page request is refused with {string}", %{args: [text]} = context do
    assert {:error, message, %{"_tag" => "SpaceError"}} = context.space_reply
    assert message =~ text
    context
  end

  step "an agent asked on {string} whose page was not told its run ended",
       %{args: [title]} = context do
    World.put_app_env(:page_agent_launch, &ended_untold/1)
    id = page_id(context, title)
    payload = %{"spaceId" => context.space, "pageId" => id, "request" => "tidy this"}

    {{:ok, %{"agent" => %{"threadId" => thread_id}}}, context} =
      World.call(context, "space.page.askAgent", payload)

    World.await_row(thread_id, &is_binary(&1["title"]))
    remember(context, title, id, thread_id)
  end

  # --- what the page says -------------------------------------------------------------

  step "{string} says its agent is working on {string}", %{args: [title, request]} = context do
    await_agent(
      context,
      title,
      &(&1["status"] == "running" and &1["request"] == request and &1["endedAt"] == nil)
    )

    context
  end

  step "{string} links to its agent's thread", %{args: [title]} = context do
    %{"threadId" => id} = await_agent(context, title, &is_binary(&1["threadId"]))
    assert %{"title" => thread_title} = World.await_row(id, &is_binary(&1["title"]))
    assert thread_title =~ title
    context
  end

  step "{string} says its agent finished and changed the page", %{args: [title]} = context do
    await_agent(context, title, &(&1["status"] == "completed" and &1["edited"] == true))
    context
  end

  step "{string} says its agent finished without changing the page",
       %{args: [title]} = context do
    await_agent(context, title, &(&1["status"] == "completed" and &1["edited"] == false))
    context
  end

  step "{string} says its agent was stopped", %{args: [title]} = context do
    await_agent(
      context,
      title,
      &(&1["status"] == "stopped" and &1["endedAt"] != nil and &1["error"] == nil)
    )

    context
  end

  step "{string} says its agent stopped because {string}", %{args: [title, reason]} = context do
    await_agent(
      context,
      title,
      &(&1["status"] == "stopped" and is_binary(&1["error"]) and &1["error"] =~ reason)
    )

    context
  end

  step "{string} says its agent failed with {string}", %{args: [title, message]} = context do
    await_agent(context, title, &(&1["status"] == "failed" and &1["error"] =~ message))
    context
  end

  step "{string} says its agent failed", %{args: [title]} = context do
    await_agent(context, title, &(&1["status"] == "failed" and is_binary(&1["error"])))
    context
  end

  step "{string} says nothing about an agent", %{args: [title]} = context do
    assert agent(context, title) == nil
    context
  end

  step "no Space entity speaks of an agent", context do
    assert StreamState.list(state(context), "pageAgent") == []
    context
  end

  step "the block {string} was written by the agent of {string}",
       %{args: [text, title]} = context do
    author = Space.agent(World.thread_id(context, thread(title)))
    block = Enum.find(StreamState.list(state(context), "block"), &(&1["text"] == text))
    assert %{"createdBy" => ^author} = block
    context
  end

  # --- the agent's thread -------------------------------------------------------------

  step "the agent's thread of {string} is in the project {string}",
       %{args: [title, project]} = context do
    assert World.thread(context, thread(title))["projectId"] == project
    context
  end

  step "the agent's thread of {string} uses the model of {string}",
       %{args: [title, other]} = context do
    model = World.thread(context, other)["modelSelection"]
    assert model != nil
    assert World.thread(context, thread(title))["modelSelection"] == model
    context
  end

  step "the agent's thread of {string} has a message naming {string}, {string} and the page tools",
       %{args: [title, page, space]} = context do
    [%{"text" => text} | _] = World.entities(context, thread(title), "message")
    assert text =~ page
    assert text =~ space
    for tool <- ~w(hal_c2_page_read hal_c2_page_block_insert), do: assert(text =~ tool)
    context
  end

  step "the agent's thread of {string} has no run left to do", %{args: [title]} = context do
    World.await_state(context, thread(title), fn state ->
      state
      |> StreamState.list("run")
      |> Enum.all?(&(&1["status"] in ~w(completed failed interrupted cancelled)))
    end)

    context
  end

  step "the agent's thread of {string} can call the page tools", %{args: [title]} = context do
    arguments = %{"spaceId" => context.space, "pageId" => page_id(context, title)}
    assert {:ok, _} = World.mcp_tool(context, thread(title), "hal_c2_page_read", arguments)
    context
  end

  # --- helpers ------------------------------------------------------------------------

  defp thread(title), do: "agent of #{title}"

  # Newer than "Work", and on a model of its own for the ask to leave alone.
  defp background_thread(context, project, created_by, opts) do
    context = World.create_project(context, project)
    id = "background-#{project}"

    {:ok, _} =
      HalC2.Orchestration.launch_thread(
        %{
          "commandId" => "launch-#{id}",
          "threadId" => id,
          "projectId" => project,
          "title" => "In the background",
          "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-background"},
          "runtimeMode" => "full-access",
          "interactionMode" => "default",
          "workspaceStrategy" => %{"type" => "root"},
          "createdBy" => created_by,
          "creationSource" => "server"
        },
        opts
      )

    World.await_row(id, &(&1["createdBy"] == created_by))
    context
  end

  defp launches?, do: Application.get_env(:hal_c2, :page_agent_launch) == nil

  # A launch that writes the thread with its run over, in place of a provider.
  defp ended_untold(input) do
    thread_id = input["threadId"]
    at = HalC2.Orchestration.Entities.now()

    thread =
      input
      |> HalC2.Orchestration.Entities.thread(at)
      |> Map.put("spacePage", input["spacePage"])

    run = %{
      "id" => "run-" <> thread_id,
      "threadId" => thread_id,
      "ordinal" => 1,
      "status" => "completed",
      "createdAt" => at
    }

    Streams.transact(thread_id, :thread, fn _ ->
      {[
         {"thread", thread_id, HalC2.Patch.diff(nil, thread)},
         {"run", run["id"], HalC2.Patch.diff(nil, run)}
       ], {:ok, %{}}}
    end)
  end

  # A page keeps its id in the scenario once asked, so it can be named after it is gone.
  defp remember(context, title, id, thread_id) do
    context
    |> Map.update(:threads, %{thread(title) => thread_id}, &Map.put(&1, thread(title), thread_id))
    |> Map.update(:agent_pages, %{title => id}, &Map.put(&1, title, id))
  end

  defp request(context, method, title) do
    payload = %{"spaceId" => context.space, "pageId" => page_id(context, title)}
    {reply, context} = World.call(context, method, payload)
    Map.put(context, :space_reply, reply)
  end

  defp complete(context, title, status, error) do
    {_, state} = World.codex_runtime(context, title)

    World.codex_notify(context, title, "turn/completed", %{
      "turn" =>
        Map.merge(
          %{"id" => state.turn.native_turn_id, "status" => status},
          if(error, do: %{"error" => error}, else: %{})
        )
    })
  end

  defp state(context), do: Streams.state(Space.stream_id(context.space))

  defp page_id(context, title) do
    (context[:agent_pages] || %{})[title] ||
      Enum.find(StreamState.list(state(context), "page"), &(&1["title"] == title))["id"]
  end

  defp agent(context, title),
    do: StreamState.get(state(context), "pageAgent")[page_id(context, title)]

  defp await_agent(context, title, fun) do
    id = page_id(context, title)

    World.await_stream(Space.stream_id(context.space), fn state ->
      agent = StreamState.get(state, "pageAgent")[id]
      if agent && fun.(agent), do: agent
    end)
  end
end
