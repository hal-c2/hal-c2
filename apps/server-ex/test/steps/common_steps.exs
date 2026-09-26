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

  # --- added by W4 (files) ---

  step "a client browses {string}", %{args: [partial]} = context do
    # `~` goes to the node as typed, with the scenario's home as its `$HOME`.
    real = T3.Test.Node.Host.path(context, partial)
    partial = if String.starts_with?(partial, "~"), do: partial, else: real
    {reply, context} = World.call(context, "filesystem.browse", %{"partialPath" => partial})

    listing =
      case reply do
        {:ok, %{"entries" => entries}} -> Enum.map(entries, & &1["name"])
        _ -> []
      end

    Map.merge(context, %{reply: reply, listing: listing})
  end

  step "the folder {string} exists", %{args: [path]} = context do
    real = T3.Test.Node.Host.path(context, path)

    # Before the scenario acts this sets the folder up; once a request was
    # answered it is the outcome to check.
    if Map.has_key?(context, :reply),
      do: assert(File.dir?(real), "#{path} does not exist"),
      else: File.mkdir_p!(real)

    context
  end

  # A step that shows the user a list of names puts them in `context.listing`.
  step "{string} is listed", %{args: [name]} = context do
    assert name in context.listing, "#{name} is not in #{inspect(context.listing)}"
    context
  end

  step "{string} is not listed", %{args: [name]} = context do
    refute name in context.listing, "#{name} is in #{inspect(context.listing)}"
    context
  end

  step "{string} is returned", %{args: [name]} = context do
    assert name in context.listing, "#{name} is not in #{inspect(context.listing)}"
    context
  end

  step "{string} is not returned", %{args: [name]} = context do
    refute name in context.listing, "#{name} is in #{inspect(context.listing)}"
    context
  end

  step "the node answers {string}", %{args: [message]} = context do
    assert {:error, error, _detail} = context.reply,
           "expected an error, got #{inspect(context.reply)}"

    assert error =~ message
    context
  end

  # After a failed worktree setup (`context.setup_thread`, see
  # files/project_scripts_and_actions_steps.exs): the agent stage never ran and the
  # thread's run ended without a turn.
  step "the agent does not start", context do
    thread_id = context.setup_thread
    last = List.last(context.setup_snapshots)
    assert Enum.find(last["stages"], &(&1["id"] == "agent"))["status"] == "pending"

    state = T3.Streams.Server.state(T3.Streams.ensure(thread_id))
    assert [%{"status" => "failed"}] = T3.StreamState.list(state, "run")
    refute Enum.any?(T3.StreamState.list(state, "message"), &(&1["role"] == "assistant"))
    context
  end

  # --- added by W4 (terminal) ---

  step "a cluster of two nodes", context do
    peer = T3.Test.Node.start_peer(context.node)
    assert peer in :erlang.nodes()
    Map.put(context, :peer, peer)
  end

  # --- added by W11 ---

  # Turns and text generation on the scenario's provider (`context.provider`) and
  # thread (`context.thread`), as the provider features set them up.

  step "a new thread needs a title", context do
    Map.put(
      context,
      :title_result,
      T3.TextGeneration.thread_title(World.project(context).root, "Fix the login form")
    )
  end

  step "the user is asked to approve it", context do
    request = T3.Test.FakeAcp.await_request(context)
    assert request["status"] == "pending"
    assert request["kind"] in ~w(command file-change file-read permission)

    for {key, value} <- context[:expected_request] || %{},
        do: assert(request[key] == value, "#{key} was #{inspect(request[key])}")

    Map.put(context, :request, request)
  end

  step "the user stops the turn", context do
    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread)
      })

    context
  end

  step "OpenCode asks to run a command", context do
    T3.Test.FakeAcp.send_message(context, "please run a command")
  end

  step "the user enables Grok", context do
    {_, context} = T3.Test.FakeAcp.open_config(context)
    T3.Test.FakeAcp.enable(context, "grok")
  end

  step "Grok writes it with every tool refused", context do
    assert {:ok, %{"title" => "Fake title"}} = context.title_result
    T3.Test.FakeAcp.assert_tools_refused(context)
    context
  end

  step "OpenCode writes it with every tool refused", context do
    assert {:ok, %{"title" => "Fake title"}} = context.title_result
    T3.Test.FakeAcp.assert_tools_refused(context)
    context
  end

  # Probes the scenario's provider again, as the settings panel's refresh does.
  # The reply is `context.reply`; on success the list is `context.providers`.
  # Config frames pushed before the reply stay in the inbox for later steps.
  step "the user refreshes provider status", context do
    input =
      if context[:provider],
        do: %{"instanceId" => context.provider, "refreshModels" => true},
        else: %{"refreshModels" => true}

    {reply, context} = World.call_keeping(context, "server.refreshProviders", input)
    context = Map.put(context, :reply, reply)

    case reply do
      {:ok, result} -> Map.put(context, :providers, result["providers"])
      _ -> context
    end
  end

  # The provider list a client receives on its config subscription.
  step "the user opens the provider list", context do
    T3.Test.FakeAcp.services()
    {_, context} = T3.Test.FakeAcp.open_config(context)
    context
  end

  step "the plan is shown as a proposed plan", context do
    plan =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        state
        |> T3.StreamState.list("plan")
        |> Enum.find(&(&1["kind"] == "proposed_plan" and &1["status"] == "active"))
      end)

    if expected = context[:expected_plan], do: assert(plan["markdown"] == expected)
    Map.put(context, :plan, plan)
  end

  # Implementing sends a message that names the plan; that completes it.
  step "the user can implement it", context do
    thread_id = World.thread_id(context, context.thread)

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "messageId" => "msg-#{System.unique_integer([:positive])}",
        "text" => "Implement the plan.",
        "attachments" => [],
        "sourcePlanRef" => %{"threadId" => thread_id, "planId" => context.plan["id"]}
      })

    World.await_stream(thread_id, fn state ->
      T3.StreamState.get(state, "plan")[context.plan["id"]]["status"] == "completed"
    end)

    context
  end

  # The tool went ahead: the turn finished without a pending approval, and an
  # agent played by `T3.Test.FakeAcp` was told yes.
  step "it is allowed without asking", context do
    state = T3.Test.FakeAcp.await_run(context, "completed")
    refute Enum.any?(T3.StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))

    if context[:fakes] do
      assert %{"result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option}}} =
               List.last(T3.Test.FakeAcp.answers(context))

      assert option in ~w(once always)
    end

    context
  end

  step ~r/^the user answers (allow once|allow for the session|decline|cancel)$/,
       %{args: [answer]} = context do
    decision =
      %{
        "allow once" => "accept",
        "allow for the session" => "acceptForSession",
        "decline" => "decline",
        "cancel" => "cancel"
      }[answer]

    request = context[:request] || T3.Test.FakeAcp.await_request(context)
    context = T3.Test.FakeAcp.respond(context, request["id"], %{"decision" => decision})
    Map.put(context, :decision, decision)
  end

  # The access modes the scenario's provider offers (`supportedRuntimeModes`).
  step "auto is not offered", context do
    modes = T3.Test.FakeAcp.find(context.providers, context.provider)["supportedRuntimeModes"]
    assert [_ | _] = modes
    refute "auto" in modes
    context
  end

  # What a client reads to show a thread: its provider in the provider list.
  step "the user opens the thread", context do
    {_, context} = T3.Test.FakeAcp.open_config(context)
    context
  end

  step "the user switches the thread to full access", context do
    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "thread.runtime-mode.set",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread),
        "runtimeMode" => "full-access"
      })

    context
  end

  # The agent's tool waits on the user: a pending approval in the thread.
  step "it is asked for approval", context do
    request = T3.Test.FakeAcp.await_request(context)
    assert request["status"] == "pending"
    Map.put(context, :request, request)
  end

  # --- added by W3 ---

  step "two clients are connected to the same environment", context do
    context
    |> World.put_client("first", Node.connect(context.node))
    |> World.put_client("second", Node.connect(context.node))
  end

  # --- added by W3-D ---

  # A follow-up while `context.running` (`%{thread, run}`) has a turn going, sent
  # as the composer sends it; the node steers or queues it by the provider.
  step "the user sends a follow-up message", context do
    message_id = "follow-up-#{System.unique_integer([:positive])}"

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "message.dispatch",
        "threadId" => context.running.thread,
        "messageId" => message_id,
        "text" => "look here instead",
        "attachments" => [],
        "dispatchMode" => %{"type" => "start_immediately"},
        "deliveryIntent" => "auto"
      })

    Map.put(context, :follow_up, message_id)
  end

  step "the message joins the running turn", context do
    %{thread: thread_id, run: run_id} = context.running

    item =
      World.await_stream(thread_id, fn state ->
        Enum.find(
          T3.StreamState.list(state, "turn-item"),
          &(&1["messageId"] == context.follow_up)
        )
      end)

    assert %{"inputIntent" => "steer", "runId" => ^run_id} = item

    assert [%{"id" => ^run_id}] =
             T3.StreamState.list(T3.Streams.Server.state(T3.Streams.ensure(thread_id)), "run")

    context
  end

  # Node plugins (`T3.Plugins`) turned on or off as a client does; other features'
  # "enables"/"disables" steps can extend these by what the name refers to.
  step "the user enables {string}", %{args: [id]} = context do
    {result, context} = World.call!(context, "plugins.enable", %{"id" => id})
    Map.put(context, :reply, {:ok, result})
  end

  step "the user disables {string}", %{args: [id]} = context do
    {result, context} = World.call!(context, "plugins.disable", %{"id" => id})
    Map.put(context, :reply, {:ok, result})
  end

  # --- added by W3-A ---

  # HTTP steps leave `context.response` as `%{status: integer, ...}`.
  step "the node answers not found", context do
    assert %{status: 404} = context.response
    context
  end

  step "the node answers {int}", %{args: [status]} = context do
    assert context.response.status == status
    context
  end

  # --- added by W2 ---

  # A step that performs a user action over RPC stores its reply in `context.reply`
  # (`{:ok, result}` or `{:error, error, detail}`, as `World.call/4` returns it). The
  # message the user sees is the error (with its detail) or a message in the result.
  step "the user is told {string}", %{args: [message]} = context do
    assert Map.has_key?(context, :reply), "no reply was recorded before this step"

    text =
      case context.reply do
        {:error, error, detail} -> "#{error} #{inspect(detail)}"
        {:ok, result} -> inspect(result)
      end

    assert String.contains?(text, message), "expected #{inspect(message)} in #{text}"
    context
  end

  # Opening a settings page is a client connected to a node whose settings are served.
  step "the user has opened the General settings", context do
    Node.ensure(T3.Settings)
    World.put_client(context, World.client(context))
  end

  step "the user is connected to an environment and opens Settings, Source Control", context do
    Node.ensure(T3.Settings)
    World.put_client(context, World.client(context))
  end

  # "The thread" is `context.thread` (a title), or the scenario's only thread.
  step "the thread is settled", context do
    title =
      context[:thread] ||
        case Map.keys(context.threads) do
          [only] -> only
          titles -> flunk("no single thread in this scenario: #{inspect(titles)}")
        end

    World.await_row(World.thread_id(context, title), &(&1["settledOverride"] == "settled"))
    context
  end

  # Settings → Diagnostics opens on the process list (`server.getProcessDiagnostics`).
  step "the user opens diagnostics", context do
    {reply, context} = World.call(context, "server.getProcessDiagnostics")
    Map.put(context, :reply, reply)
  end

  # A file in the scenario's themes folder (`environment-themes.feature`) is removed;
  # otherwise it names a thread: as an action the thread is deleted, as an outcome
  # it is asserted deleted.
  step "{string} is deleted", %{args: [name]} = context do
    theme = Path.join([context.node.home, "themes", name])

    cond do
      File.exists?(theme) ->
        File.rm!(theme)
        context

      outcome_step?(context) ->
        assert World.thread(context, name)["deletedAt"], "#{name} was not deleted"
        context

      true ->
        {:ok, _} =
          T3.Orchestration.dispatch(%{
            "type" => "thread.delete",
            "commandId" => "cmd-#{System.unique_integer([:positive])}",
            "threadId" => World.thread_id(context, name)
          })

        assert World.thread(context, name)["deletedAt"]
        context
    end
  end

  # A choice the user makes in whatever the scenario opened: an earlier step says
  # what choosing means with `context.on_choose` (`fn context, choice -> context end`).
  step "the user chooses {string}", %{args: [choice]} = context do
    case context[:on_choose] do
      nil -> flunk("nothing in this scenario offers a choice of #{inspect(choice)}")
      choose -> choose.(context, choice)
    end
  end

  # The default socket drops and connects again. A scenario that follows the node
  # over the socket says how it resumes with `context.after_reconnect`.
  step "the client reconnects", context do
    context = World.disconnect(context)

    case context[:after_reconnect] do
      nil -> World.put_client(context, Node.connect(context.node))
      reconnect -> reconnect.(context)
    end
  end

  step "the user imports its project", context do
    World.import_agent_sessions(context)
  end

  # Whether the running step is a Then (or an And/But following one).
  defp outcome_step?(context) do
    context
    |> Map.get(:step_history, [])
    |> Enum.reverse()
    |> Enum.map(&String.trim(&1.keyword))
    |> Enum.find(&(&1 not in ["And", "But", "*"]))
    |> Kernel.==("Then")
  end

  # Storage cleanup: settings/storage.feature, and the same texts in
  # node/platform/background-and-cleanup.feature. `context.worktree` is the
  # worktree the scenario is about (`World.worktree_thread/4`).
  step("the node sweeps storage", context, do: World.sweep_storage(context))

  step "the worktree is removed", context do
    path = context.worktree.path
    refute File.exists?(path), "the worktree #{path} is still there"
    refute path in worktrees(context.worktree.root)
    context
  end

  step "the worktree is kept", context do
    path = context.worktree.path
    assert File.dir?(path), "the worktree #{path} was removed"
    assert path in worktrees(context.worktree.root)
    context
  end

  step "a thread's worktree belongs to a deleted thread", context do
    context = World.worktree_thread(context, "deleted work")
    id = World.thread_id(context, "deleted work")
    {:ok, _} = T3.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})
    World.await_row(id, & &1["deletedAt"])
    context
  end

  step "a thread's worktree has been idle for {int} days", %{args: [days]} = context do
    context
    |> World.worktree_thread("idle work")
    |> World.patch_thread("idle work", %{"createdAt" => World.iso_from_now(-World.days(days))})
  end

  # The linked worktrees git knows for a repository.
  defp worktrees(root) do
    root
    |> World.git!(~w(worktree list --porcelain))
    |> String.split("\n")
    |> Enum.flat_map(fn
      "worktree " <> path -> [path]
      _ -> []
    end)
  end

  # The desktop's power report (`server.reportHostPowerState`); `T3.BackgroundPolicy`
  # takes it without replying, so the step waits until the policy has it.
  step ~r/^the host reports it is (?<state>locked|on low power|on battery)$/,
       %{args: [state]} = context do
    policy = Node.ensure(T3.BackgroundPolicy)
    :erlang.trace(policy, true, [:receive])
    flag = &to_string(state == &1)

    snapshot = %{
      "source" => "desktop",
      "idle" => "false",
      "idleSeconds" => 0,
      "locked" => flag.("locked"),
      "suspended" => false,
      "onBattery" => flag.("on battery"),
      "lowPowerMode" => flag.("on low power"),
      "thermalState" => "nominal",
      "stale" => false,
      "updatedAt" => World.iso_from_now(0)
    }

    {nil, context} = World.call!(context, "server.reportHostPowerState", snapshot)
    assert_receive {:trace, ^policy, :receive, {:"$gen_cast", {:power, ^snapshot}}}, 2_000
    assert T3.BackgroundPolicy.snapshot()["hostPower"] == snapshot
    context
  end

  # `server.updateProvider`; the reply is `context.reply`.
  step "the user updates Codex", context do
    {reply, context} = World.call(context, "server.updateProvider", %{"provider" => "codex"})
    Map.put(context, :reply, reply)
  end

  # The node shuts down; `the node starts again` / `the node restarts` bring it back.
  step "the node stops", context do
    %{context | node: Node.stop(context.node), clients: %{}}
  end

  # `server.refreshProviders` for every provider; the reply is `context.reply`, and the
  # `config.providers` the node pushes first stays to be received.
  # `server.prepareAcpRegistryAgent`; the reply is `context.reply`.
  step "the user adds the registry agent {string}", %{args: [agent]} = context do
    {reply, context} =
      World.call(context, "server.prepareAcpRegistryAgent", %{"agentId" => agent})

    Map.put(context, :reply, reply)
  end

  # `server.deleteAcpRegistrySession` for `context.acp_session` (instanceId, projectId,
  # sessionId); the reply is `context.reply`.
  step "the user deletes the native session", context do
    {reply, context} =
      World.call(context, "server.deleteAcpRegistrySession", context.acp_session)

    Map.put(context, :reply, reply)
  end

  # Usage history: an earlier step leaves the latest `server.getUsageSummary` result in
  # `context.summary` and the history it expects in `context.history`
  # (`%{provider: "claude" | "codex" | "grok", output: output_tokens}`).
  step "that history is counted once", context do
    %{provider: provider, output: output} = context.history
    assert World.usage_output(context.summary, provider) == output

    assert [_] =
             for(s <- context.summary["sources"], s["fingerprint"]["provider"] == provider, do: s),
           "expected one #{provider} source in #{inspect(context.summary["sources"])}"

    context
  end

  # A line that changed before the resume point is not read again: only the lines
  # past it add to the counted output.
  step "only the new lines of that transcript are read", context do
    %{provider: provider, output: output} = context.history
    assert World.usage_output(context.summary, provider) == output
    context
  end

  # An rpc answered by the catch-all for methods outside what the node carries.
  step "the node answers that the method is not served", context do
    assert {:error, error, _detail} = context.reply
    assert error =~ "is not served by this node yet"
    context
  end

  step "the node answers with a pong", context do
    {frame, client} = T3.Test.WsClient.recv(World.client(context), 1_000)
    assert frame == %{"t" => "pong"}
    World.put_client(context, client)
  end

  # A frame the node refuses; the refusal frame is `context.refusal`.
  step ~r/^the client sends (?<case>text that is not JSON|a frame of an unknown type|a frame with an unknown or missing type|a subscription to an unknown shape|a subscription to a shape type the node does not know|a subscription naming an unknown node|a subscription naming a node outside the cluster|a config subscription for an unknown environment|an authAccess subscription from a session without access:read|an RPC for an unknown environment|an rpc for an unknown environment|an rpc whose node has gone away)$/,
       %{args: [refused]} = context do
    alias T3.Test.WsClient
    client = World.client(context)

    client =
      case refused do
        "text that is not JSON" ->
          {:ok, ws, data} = Mint.WebSocket.encode(client.ws, {:text, "not json {"})
          {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
          %{client | conn: conn, ws: ws}

        "a frame " <> _ ->
          WsClient.send_json(client, %{"t" => "nope", "id" => 40})

        "a subscription to " <> _ ->
          Node.sub(client, 41, %{"type" => "nope"})

        "a subscription naming " <> _ ->
          Node.sub(client, 42, %{"type" => "stream", "node" => "nobody@nowhere", "stream" => "x"})

        "a config subscription" <> _ ->
          Node.sub(client, 43, %{"type" => "config", "environment" => "env-missing"})

        "an authAccess subscription" <> _ ->
          {:ok, %{"credential" => credential}} =
            T3.Auth.create_pairing_link(%{
              "label" => "Standard",
              "scopes" => T3.Auth.standard_scopes()
            })

          {:ok, access, _expires, _scopes} =
            T3.Auth.exchange(credential, %{"label" => "Standard"})

          {:ok, ticket, _} = T3.Auth.issue_ticket(access)

          Node.sub(Node.connect(context.node, "wsTicket=#{ticket}"), 44, %{"type" => "authAccess"})

        "an rpc whose node has gone away" ->
          # A peer the shell knows by its environment, but no longer reachable.
          gone = :"gone@127.0.0.1"
          GenServer.cast(T3.Shell, {:peer_environment, gone, %{"environmentId" => "env-gone"}})
          assert_receive {:t3_shell, {:environment, ^gone, _}}, 1_000
          Node.rpc(client, "env-gone", 46, "t3.readSettings", %{})

        _unknown_environment ->
          Node.rpc(client, "env-missing", 45, "t3.readSettings", %{})
      end

    {frame, client} = Node.await(client, &(&1["t"] in ["error", "rpc.error"]))
    context |> World.put_client(client) |> Map.put(:refusal, frame)
  end
end
