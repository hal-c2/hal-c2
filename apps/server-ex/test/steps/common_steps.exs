defmodule T3.Steps.Common do
  @moduledoc """
  Steps shared by more than one feature directory: the environment a scenario
  starts from, its projects and threads, and the node's lifecycle. A step that
  appears in several directories belongs here; one directory's steps live in
  its own file.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World

  # --- environments, projects and threads ---------------------------------------

  step "a connected environment", context do
    World.put_client(context, World.client(context))
  end

  step "a connected environment {string}", %{args: [label]} = context do
    context |> Map.put(:environment_label, label) |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the project {string}", %{args: [title]} = context do
    context |> World.create_project(title) |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment {string} with the project {string}",
       %{args: [label, title]} = context do
    context
    |> Map.put(:environment_label, label)
    |> World.create_project(title)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the projects {string} and {string}",
       %{args: [first, second]} = context do
    context
    |> World.create_project(first)
    |> World.create_project(second)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the idle thread {string} in the project {string}",
       %{args: [thread, project]} = context do
    context
    |> World.create_project(project)
    |> World.create_thread(thread, project)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the thread {string} in the project {string}",
       %{args: [thread, project]} = context do
    context
    |> World.create_project(project)
    |> World.create_thread(thread, project)
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "a connected environment with the idle thread {string}", %{args: [thread]} = context do
    context
    |> World.create_project("shop")
    |> World.create_thread(thread, "shop")
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step("a node", context, do: context)
  step("a running node", context, do: context)

  step "a node with a project {string}", %{args: [title]} = context do
    World.create_project(context, title)
  end

  step "two clients are connected to the node", context do
    context
    |> World.put_client("first", Node.connect(context.node))
    |> World.put_client("second", Node.connect(context.node))
  end

  step "a paired client", context do
    {:ok, access, _expires, _scopes} =
      T3.Auth.exchange(T3.Auth.create_pairing_token(context.node.store), %{"label" => "Phone"})

    {:ok, ticket, _} = T3.Auth.issue_ticket(access)
    client = Node.connect(context.node, "wsTicket=#{ticket}")
    context |> Map.put(:access_token, access) |> World.put_client("paired", client)
  end

  # --- the node's lifecycle ----------------------------------------------------------

  step "the node restarts", context do
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  step "the node starts again", context do
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  step "the node starts", context do
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  # --- shared outcomes -----------------------------------------------------------------

  step "the request is refused with {string}", %{args: [message]} = context do
    assert {:error, error, _detail} = context.reply,
           "expected a refusal, got #{inspect(context.reply)}"

    assert error =~ message
    context
  end

  step "the socket stays open", context do
    client = T3.Test.WsClient.send_json(World.client(context), %{"t" => "ping"})
    {%{"t" => "pong"}, client} = T3.Test.WsClient.recv(client, 1_000)
    World.put_client(context, client)
  end

  # --- added by W9 ---
  # Providers run on the test fakes (`World.fake_providers/2`); the thread a step
  # means is the one the scenario last started (`World.current_thread/1`).

  step "the user opens the provider list", context do
    {providers, context} = World.providers(context)
    Map.put(context, :providers, providers)
  end

  step "the user opens the limits view", context do
    context = World.fake_providers(context)
    Node.ensure(T3.ProviderUsageLimits)
    :ok = T3.ProviderUsageLimits.refresh()
    # Accounts arrive as casts the probes sent; this call lands after them.
    :sys.get_state(T3.ProviderUsageLimits)
    {providers, context} = World.providers(context)
    Map.put(context, :providers, providers)
  end

  step "Claude was installed in a way the node cannot identify", context do
    # A plain executable no installer's layout matches, behind the latest release.
    context = World.fake_providers(context)

    :persistent_term.put(
      {T3.ProviderUpdates, "claudeAgent"},
      {"9.9.9", System.monotonic_time(:millisecond)}
    )

    context
  end

  step "Codex is not offered as a provider", context do
    refute Enum.find(context.providers, &(&1["instanceId"] == "codex"))
    context
  end

  step "the user sends a follow-up message", context do
    title = World.current_thread(context)

    context
    |> World.send_message(title, "one more thing", %{"dispatchMode" => nil})
    |> Map.put(:follow_up, "one more thing")
  end

  step "the plan is shown as a proposed plan", context do
    title = World.current_thread(context)

    plan =
      World.await_stream(context, title, fn state ->
        Enum.find(
          T3.StreamState.list(state, "plan"),
          &(&1["kind"] == "proposed_plan" and &1["status"] == "active")
        )
      end)

    assert plan["markdown"] =~ "Plan"
    Map.put(context, :plan, plan)
  end

  step "the user can implement it", context do
    title = World.current_thread(context)
    # The plan shows before its turn ends; the user implements it once the turn is over.
    World.await_idle(context, title)
    count = length(World.runs(context, title))
    ref = %{"threadId" => World.thread_id(context, title), "planId" => context.plan["id"]}

    context =
      World.send_message(context, title, "Go ahead.", %{
        "sourcePlanRef" => ref,
        "dispatchMode" => nil
      })

    World.await_stream(context, title, fn state ->
      length(T3.StreamState.list(state, "run")) > count and
        T3.StreamState.get(state, "plan")[ref["planId"]]["status"] == "completed"
    end)

    World.await_idle(context, title)
    context
  end

  step "the user reverts to the end of the first turn", context do
    # The thread works in the project root, which only an isolated worktree may reset:
    # this rewinds the conversation, as the node offers for a shared checkout.
    World.rollback(context, World.current_thread(context), 1, %{"restoreFiles" => false})
  end

  step "the user forks from the second turn", context do
    World.fork(context, World.current_thread(context), 2, "fork")
  end

  step "a new thread needs a title", context do
    root =
      if context[:projects] not in [nil, %{}], do: World.project(context).root, else: File.cwd!()

    Map.put(context, :title_result, T3.TextGeneration.thread_title(root, "Fix the login bug"))
  end

  step "the user is asked to approve it", context do
    request = World.await_request(context, World.current_thread(context))
    assert request["kind"] in ~w(command file-change file-read permission)
    Map.put(context, :request, request)
  end

  # The approval decisions a client offers (`ProviderApprovalDecision`).
  step ~r/^the user answers (?<decision>allow once|allow for the session|decline|cancel)$/,
       %{args: [decision]} = context do
    title = World.current_thread(context)
    request = context[:request] || World.await_request(context, title)

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, title),
        "requestId" => request["id"],
        "decision" =>
          %{
            "allow once" => "accept",
            "allow for the session" => "acceptForSession",
            "decline" => "decline",
            "cancel" => "cancel"
          }[decision]
      })

    Map.put(context, :request, request)
  end

  step "the user dismisses the question", context do
    title = World.current_thread(context)
    request = context[:request] || World.await_request(context, title)

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "thread.user-input.dismiss",
        "threadId" => World.thread_id(context, title),
        "requestId" => request["id"]
      })

    Map.put(context, :request, request)
  end

  step "the user updates Codex", context do
    {reply, context} = World.call(context, "server.updateProvider", %{"provider" => "codex"})
    Map.put(context, :reply, reply)
  end

  step "the message joins the running turn", context do
    title = World.current_thread(context)

    World.await_stream(context, title, fn state ->
      Enum.any?(
        T3.StreamState.list(state, "message"),
        &(&1["role"] == "assistant" and &1["text"] == "steered: one more thing")
      )
    end)

    # No second turn was queued for it.
    assert [_] = World.runs(context, title)
    context
  end

  step "the user switches the thread to Claude and sends a message", context do
    title = World.current_thread(context)
    count = length(World.runs(context, title))

    context =
      World.send_message(context, title, "where are we", %{
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "sonnet"}
      })

    World.await_stream(context, title, &(length(T3.StreamState.list(&1, "run")) > count))
    World.await_idle(context, title)
    context
  end

  step "Claude receives a transcript of the history ahead of the message", context do
    title = World.current_thread(context)

    sent =
      for entry <- World.provider_log(context, "claude"),
          content = get_in(entry, ["in", "message", "content"]),
          content != nil,
          # A message with attachments comes as content blocks.
          do:
            if(is_binary(content), do: content, else: Enum.map_join(content, &(&1["text"] || "")))

    text =
      Enum.find(sent, &String.ends_with?(&1, "where are we")) ||
        flunk("Claude got #{inspect(sent)}")

    assert [_, rest] = String.split(text, "<conversation_history>", parts: 2)
    assert rest =~ "User: hello"
    assert Enum.any?(World.replies(context, title), &(&1 =~ "history True"))
    context
  end

  step "the user is told {string}", %{args: [message]} = context do
    text =
      case context.reply do
        {:error, text} when is_binary(text) -> text
        {:error, tag, detail} -> "#{tag} #{inspect(detail)}"
        other -> flunk("expected a refusal, got #{inspect(other)}")
      end

    assert text =~ message
    context
  end

  step "the user disables Grok", context do
    World.merge_settings(%{"providers" => %{"grok" => %{"enabled" => false}}})
    context
  end

  step "the user starts a new thread in {string}", %{args: [project]} = context do
    # The client fills a new thread from the project's settings over the
    # environment's (`resolveProjectSettings`), which `T3.Settings.for_project/1` mirrors.
    settings = T3.Settings.for_project(World.project(context, project).id)

    fields =
      %{
        "modelSelection" => settings["defaultModelSelection"],
        "runtimeMode" => settings["defaultRuntimeMode"]
      }
      |> Map.reject(fn {_key, value} -> value == nil end)

    context
    |> World.create_thread("New thread", project, fields)
    |> Map.put(:current_thread, "New thread")
  end

  step "the user starts a new thread", context do
    # As in a project: the environment's defaults, over the client's full access.
    project = if context[:projects] not in [nil, %{}], do: World.project(context).id
    settings = T3.Settings.for_project(project)

    fields =
      %{
        "modelSelection" => settings["defaultModelSelection"],
        "runtimeMode" => settings["defaultRuntimeMode"] || "full-access"
      }
      |> Map.reject(fn {_key, value} -> value == nil end)

    context
    |> World.create_thread("New thread", nil, fields)
    |> Map.put(:current_thread, "New thread")
  end

  step "the user sends a message", context do
    # A thread the scenario described but has not started yet starts with this message.
    context =
      case context[:pending_launch] do
        %{instance: instance, fields: fields} ->
          context
          |> Map.delete(:pending_launch)
          |> World.launch_thread("Work", instance, "hello", fields)

        nil ->
          title = World.current_thread(context)
          World.send_message(context, title, "hello")
      end

    World.await_idle(context, World.current_thread(context))
    context
  end

  step "OpenCode asks to run a command", context do
    %{instance: "opencode", fields: fields} = context.pending_launch

    context
    |> Map.delete(:pending_launch)
    |> World.launch_thread("Work", "opencode", "approve", fields)
  end

  step "the user interrupts the turn", context do
    title = World.current_thread(context)

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, title)
      })

    context
  end

  step "the user switches the thread to full access", context do
    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "thread.runtime-mode.set",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, World.current_thread(context)),
        "runtimeMode" => "full-access"
      })

    context
  end

  # The approval choices a client shows (`ProviderApprovalDecision`).
  step ~r/^the user chooses "(?<choice>Allow once|Always allow this session|Decline)"$/,
       %{args: [choice]} = context do
    title = World.current_thread(context)
    request = context[:request] || World.await_request(context, title)

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "runtime-request.respond",
        "threadId" => World.thread_id(context, title),
        "requestId" => request["id"],
        "decision" =>
          %{
            "Allow once" => "accept",
            "Always allow this session" => "acceptForSession",
            "Decline" => "decline"
          }[choice]
      })

    Map.put(context, :request, request)
  end

  # After a step that put the offered modes (runtime mode ids) in :permission_modes.
  step "auto is not offered", context do
    assert context.permission_modes != []
    refute "auto" in context.permission_modes
    context
  end

  step "the user imports its project", context do
    input = %{"projectId" => World.project(context).id}
    {reply, context} = World.call(context, "agentSessions.import", input)
    Map.put(context, :reply, reply)
  end

  # `:acp_session` (`%{instance, project, session}`) is the ACP session the scenario
  # imported or listed.
  step "the user deletes the native session", context do
    %{instance: instance, project: project, session: session} =
      context[:acp_session] || flunk("no ACP session in this scenario")

    input = %{"instanceId" => instance, "projectId" => project, "sessionId" => session}
    {reply, context} = World.call(context, "server.deleteAcpRegistrySession", input)
    Map.put(context, :reply, reply)
  end

  # Usage: `:shared_history` (`%{provider, model, output_tokens}`) is history that
  # several accounts or environments read; the summaries are `:usage_summaries`, or
  # the one in `:usage`. Clients keep one source per fingerprint, as
  # packages/shared/src/usageMerge.ts does, so the history counts once.
  step "that history is counted once", context do
    %{provider: provider, model: model, output_tokens: tokens} = context.shared_history
    summaries = context[:usage_summaries] || [context.usage]

    {owners, _claimed} =
      Enum.reduce(summaries, {[], MapSet.new()}, fn summary, {owners, claimed} ->
        keys =
          for source <- summary["sources"],
              source["status"] != "missing",
              source["fingerprint"]["provider"] == provider,
              do: source["fingerprint"]

        assert keys == Enum.uniq(keys), "one summary lists a directory twice"
        new = Enum.reject(keys, &MapSet.member?(claimed, &1))
        owners = if new == [], do: owners, else: [summary | owners]
        {owners, Enum.into(new, claimed)}
      end)

    counted =
      for summary <- owners,
          bucket <- summary["buckets"],
          bucket["provider"] == provider and bucket["model"] == model,
          do: bucket["totals"]["outputTokens"]

    assert Enum.sum(counted) == tokens
    context
  end

  # `:grown_transcript` (`%{path, provider}`) was appended to after
  # `World.trace_usage_reads/1` started recording.
  step "only the new lines of that transcript are read", context do
    %{path: path, provider: provider} = context.grown_transcript
    assert [{^path, ^provider, resume}] = World.usage_reads()
    assert {offset, _, _, _} = resume
    assert offset > 0
    context
  end

  # Periodic work (idle session release, usage-limit checks) runs now instead of on
  # its timer; each service still decides whether it has anything to do.
  step "five minutes pass", context do
    World.run_periodic_checks()
    context
  end
end
