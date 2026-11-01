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

  step "the agent of {string} fails with {string}", %{args: [title, message]} = context do
    complete(context, thread(title), "failed", %{"message" => message})
  end

  step "the user sends {string} to the agent of {string} behind its run",
       %{args: [text, title]} = context do
    World.queue_message(context, thread(title), text)
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

  step "no provider can start a thread", context do
    World.put_app_env(:page_agent_launch, fn _ -> {:error, "No provider can start."} end)
    context
  end

  step "the page request is refused with {string}", %{args: [text]} = context do
    assert {:error, message, %{"_tag" => "SpaceError"}} = context.space_reply
    assert message =~ text
    context
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
    await_agent(context, title, &(&1["status"] == "stopped" and &1["endedAt"] != nil))
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

  defp launches?, do: Application.get_env(:hal_c2, :page_agent_launch) == nil

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
