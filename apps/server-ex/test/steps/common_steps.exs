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

  # A thread search (`context.matches`, the name is a thread) or a file listing.
  step "{string} is not returned", %{args: [name]} = context do
    if Map.has_key?(context[:threads] || %{}, name) do
      assert context.matches != [] or context.query != "", "the search ran"
      id = World.thread_id(context, name)
      assert Enum.filter(context.matches, &(&1["threadId"] == id)) == []
    else
      refute name in context.listing, "#{name} is in #{inspect(context.listing)}"
    end

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

  # Node plugins (`T3.Plugins`) turned on or off as a client does; other features'
  # "enables"/"disables" steps can extend these by what the name refers to.
  step "the user enables {string}", %{args: [id]} = context do
    {result, context} = World.call!(context, "plugins.enable", %{"id" => id})
    Map.put(context, :reply, {:ok, result})
  end

  # --- added by W3-A ---

  # "the node answers not found" and "the node answers {int}": the one HTTP status step below.

  # --- added by W2 ---

  # A step that performs a user action over RPC stores its reply in `context.reply`
  # (`{:ok, result}` or `{:error, error, detail}`, as `World.call/4` returns it). The
  # message the user sees is the error (with its detail) or a message in the result.
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
  # it is asserted deleted. A thread cut off mid-turn (`context.cut_off`) is deleted
  # as stored data, as "{string} is archived" archives it.
  step "{string} is deleted", %{args: [name]} = context do
    theme = Path.join([context.node.home, "themes", name])

    cond do
      File.exists?(theme) ->
        File.rm!(theme)
        context

      context[:cut_off] ->
        World.patch_thread(context, name, %{"deletedAt" => World.iso_from_now(0)})

      outcome_step?(context) ->
        assert World.thread(context, name)["deletedAt"], "#{name} was not deleted"
        context

      true ->
        unless World.thread(context, name)["deletedAt"] do
          {:ok, _} =
            T3.Orchestration.dispatch(%{
              "type" => "thread.delete",
              "commandId" => "cmd-#{System.unique_integer([:positive])}",
              "threadId" => World.thread_id(context, name)
            })
        end

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

  # With `context.control` (a worktree the same sweep had to remove), also that the
  # sweep did run.
  step "the worktree is kept", context do
    path = context.worktree.path
    assert File.dir?(path), "the worktree #{path} was removed"
    assert path in worktrees(context.worktree.root)
    if control = context[:control], do: refute(File.exists?(control), "the sweep did not run")
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
          Node.send_text(client, "not json {")

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

  # --- added by W5 ---

  @git_actions %{
    "Commit" => "commit",
    "Push" => "push",
    "Create PR" => "create_pr",
    "Commit & push" => "commit_push",
    "Commit, push & PR" => "commit_push_pr",
    "Commit, push & create PR" => "commit_push_pr"
  }

  # Runs a git action by its menu label in the checkout under test (`context.cwd`).
  step "the user runs {string}", %{args: [label]} = context do
    action = @git_actions[label] || flunk("no git action is labelled #{inspect(label)}")
    extra = context[:git_action_input] || %{}
    {events, context} = World.git_action(context, context.cwd, action, extra)
    Map.put(context, :git_events, events)
  end

  # What the user was told: `context.told` when a step set it, else the failure of
  # the last git action (`context.git_events`) or RPC (`context.reply`).
  step "the user is told {string}", %{args: [message]} = context do
    said =
      cond do
        context[:told] ->
          List.wrap(context.told)

        match?([_ | _], context[:git_events]) ->
          last = List.last(context.git_events)
          [last["message"], get_in(last, ["result", "toast", "title"])]

        match?({:error, _, _}, context[:reply]) ->
          {:error, error, detail} = context.reply
          [error, (detail || %{})["detail"], (detail || %{})["message"], inspect(detail)]

        match?({:ok, _}, context[:reply]) ->
          {:ok, result} = context.reply
          [inspect(result)]

        true ->
          flunk("nothing was said; last reply: #{inspect(context[:reply])}")
      end

    assert Enum.any?(said, &(is_binary(&1) and &1 =~ message)),
           "expected #{inspect(message)} in #{inspect(said)}"

    context
  end

  # A client shows a thread of the project: it watches the project's checkout status.
  # The branch picker of the checkout under test (`context.cwd`): `vcs.listRefs`.
  step "the user opens the branch list", context do
    {reply, context} = World.call(context, "vcs.listRefs", %{"cwd" => context.cwd})
    Map.put(context, :reply, reply)
  end

  # A second worktree of the checkout under test holds `branch`, made from HEAD when new.
  step "{string} is checked out in another worktree", %{args: [branch]} = context do
    path = T3.Test.Node.tmp_dir(context.node, "worktree")
    File.rmdir!(path)
    exists? = World.git!(context.cwd, ["branch", "--list", branch]) != ""
    args = if exists?, do: [path, branch], else: ["-b", branch, path]
    World.git!(context.cwd, ["worktree", "add", "-q" | args])
    Map.put(context, :other_worktree, path)
  end

  # Expanding a file of the working tree review (`review.getDiffFileContents`).
  step "the user expands {string}", %{args: [path]} = context do
    T3.Steps.SourceControl.Shared.expand_review_file(context, path)
  end

  # The scenario's node is the remote environment `name`; the default client is the
  # user's local one. Starts with no GitHub account believed yet.
  step "the user is connected to the local environment and the remote environment {string}",
       %{args: [name]} = context do
    T3.PullRequests.invalidate(%{})
    context = World.put_client(context, World.client(context))
    assert [{_node, %{"environmentId" => id}}] = T3.Shell.environments()
    assert id == context.node.environment
    Map.put(context, :remote, name)
  end

  # A `gh` that runs but has no account: `gh auth status` fails as it does signed out.
  step "the GitHub CLI is installed but not signed in", context do
    context
    |> World.fake_cli(["gh"])
    |> World.cli_rules([
      %{"cmd" => "gh", "args" => ["--version"], "stdout" => "gh version 2.81.0 (2025-10-01)\n"},
      %{
        "cmd" => "gh",
        "args" => ["auth status"],
        "stderr" => "You are not logged into any GitHub hosts. To log in, run: gh auth login\n",
        "exit" => 1
      },
      %{
        "cmd" => "gh",
        "args" => ["api user"],
        "stderr" => "To get started with GitHub CLI, please run:  gh auth login\n",
        "exit" => 1
      }
    ])
  end

  # Cancels whatever the scenario's Given put in progress: that step leaves a
  # `context.cancel` function (context -> context) saying how.
  # What is cancelled is whatever the scenario started: a step that started something
  # cancellable leaves `context.cancel`; an ACP sign-in leaves its flow.
  step "the user cancels it", context do
    cond do
      is_function(context[:cancel], 1) ->
        context.cancel.(context)

      context[:flow] ->
        {state, ctx} =
          World.call!(
            context,
            "provider.auth.cancel",
            %{"instanceId" => context.auth_instance, "flowId" => context.flow},
            context[:auth_client] || "default"
          )

        assert state["flowId"] == context.flow
        ctx

      true ->
        flunk("nothing in this scenario can be cancelled")
    end
  end

  # A thread's worktree setup, in one of two fixtures: `World.launch_in_worktree/4`
  # leaves `context.setup_thread` and the snapshots seen so far in
  # `context.setup_snapshots` (source-control and files scenarios); the threads
  # scenarios read the current thread's setup after the fact (`World.setup_result/2`).
  step "the user cancels the setup", context do
    if context[:setup_thread] do
      {reply, context} =
        World.call(context, "worktreeSetup.cancel", %{"threadId" => context.setup_thread})

      assert {:ok, %{"cancelled" => cancelled}} = reply
      Map.put(context, :setup_cancelled, cancelled)
    else
      {reply, context} =
        World.call(context, "worktreeSetup.cancel", %{
          "threadId" => World.thread_id(context, World.current(context))
        })

      Map.put(context, :reply, reply)
    end
  end

  step "the setup is not cancelled", context do
    if context[:setup_thread] do
      assert context.setup_cancelled == false
      {snapshot, context} = World.await_setup(context, &(&1["phase"] != "running"))
      assert snapshot["phase"] == "done"
      context
    else
      assert {:ok, %{"cancelled" => false}} = context.reply
      assert World.setup_result(context, World.current(context))["phase"] == "done"
      context
    end
  end

  step "the setup fails with {string}", %{args: [message]} = context do
    {snapshot, context} = setup_outcome(context)
    assert %{"phase" => "failed", "error" => ^message} = snapshot
    context
  end

  step "the setup fails with a message starting {string}", %{args: [message]} = context do
    {snapshot, context} = setup_outcome(context)
    assert %{"phase" => "failed", "error" => error} = snapshot
    assert String.starts_with?(error, message), "the setup failed with #{inspect(error)}"
    context
  end

  # The finished setup snapshot of whichever thread the scenario set up.
  defp setup_outcome(context) do
    if context[:setup_thread],
      do: World.await_setup(context, &(&1["phase"] != "running")),
      else: {World.setup_result(context, World.current(context)), context}
  end

  # After a failed setup: the agent stage never ran and the thread's run ended
  # without a turn.
  step "the agent does not start", context do
    if context[:setup_thread] do
      thread_id = context.setup_thread
      {last, context} = World.await_setup(context, &(&1["phase"] != "running"))
      assert World.setup_stage(last, "agent") == "pending"

      state = T3.Streams.Server.state(T3.Streams.ensure(thread_id))
      assert [%{"status" => "failed"}] = T3.StreamState.list(state, "run")
      refute Enum.any?(T3.StreamState.list(state, "message"), &(&1["role"] == "assistant"))
      context
    else
      title = World.current(context)
      World.setup_result(context, title)
      assert World.codex_requests(context, "turn/start") == []
      assert Enum.all?(World.runs(context, title), &(&1["status"] in ["failed", "cancelled"]))
      context
    end
  end

  # `context.worktree` is `%{path, root}`: the worktree the scenario is about and
  # the checkout it belongs to.
  step "the worktree is removed", context do
    case context[:worktree] do
      %{path: path, root: root} ->
        refute File.exists?(path), "the worktree #{path} is still there"
        refute path in World.worktrees(root), "git still lists #{path}"

      nil ->
        assert is_binary(context.worktree_path)
        refute File.exists?(context.worktree_path)
    end

    context
  end

  # --- added by W10 ---

  # Providers run as the fakes of `T3.Test.AcpFixtures`; no real provider CLI starts.

  step "the user refreshes the status of every provider", context do
    ctx = T3.Test.AcpFixtures.ready(context)
    Node.ensure(T3.ProviderUsageLimits)
    # The boot probe has finished once this returns.
    :ok = T3.ProviderUsageLimits.refresh([])
    before = Map.new(["codex", "claudeAgent"], &{&1, T3.ProviderUsageLimits.get(&1)})
    at = T3.Orchestration.Entities.now()
    {result, ctx} = World.call!(ctx, "server.refreshProviders", %{})
    Map.put(ctx, :refreshed, %{before: before, at: at, providers: result["providers"]})
  end

  step "the user disables Grok", context do
    T3.Test.AcpFixtures.write_settings(context, fn settings ->
      settings
      |> put_in([Access.key("providers", %{}), Access.key("grok", %{}), "enabled"], false)
      |> then(fn settings ->
        if is_map(get_in(settings, ["providerInstances", "grok"])),
          do: put_in(settings, ["providerInstances", "grok", "enabled"], false),
          else: settings
      end)
    end)
  end

  step "Claude was installed in a way the node cannot identify", context do
    # An executable outside every installer's layout, behind the latest release.
    ctx = T3.Test.AcpFixtures.ready(context)
    fake_claude = Path.expand("../support/fake_claude.py", __DIR__)
    path = Path.join(context.node.home, "odd/bin/claude")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "2.0.0 (Claude Code)"; exit 0; fi
    exec python3 -u #{fake_claude} "$@"
    """)

    File.chmod!(path, 0o755)
    Application.put_env(:t3, :claude_command, [path])

    :persistent_term.put(
      {T3.ProviderUpdates, "claudeAgent"},
      {"9.9.9", System.monotonic_time(:millisecond)}
    )

    ctx
  end

  # ACP Registry steps shared with `features/plugins/plugin-catalog.feature` (and, for
  # cancelling, approving and stopping, other provider features). They leave the
  # node's answer in `context.reply`.

  step "the user searches the ACP registry for {string}", %{args: [query]} = context do
    alias T3.Test.AcpFixtures, as: Acp
    ctx = Acp.serve_registry(context)

    other =
      if T3.Acp.Catalog.platform() == "linux-x86_64", do: "darwin-aarch64", else: "linux-x86_64"

    agent = fn id, name, fields ->
      Map.merge(
        %{
          "id" => id,
          "name" => name,
          "version" => "1.0.0",
          "description" => "An ACP agent",
          "distribution" => %{"npx" => %{"package" => "@acme/#{id}"}}
        },
        fields
      )
    end

    # Built only for another platform.
    elsewhere = %{
      "distribution" => %{
        "binary" => %{other => %{"archive" => "https://example.com/a.tar.gz", "cmd" => "./a"}}
      }
    }

    agents =
      [
        agent.("agent", "Agent", %{}),
        agent.("code", "Code", %{"description" => "A test tool"}),
        agent.("agent-0-elsewhere", "Agent 0 Elsewhere", elsewhere),
        agent.("code-elsewhere", "Code Elsewhere", elsewhere)
      ] ++
        for(n <- 1..24, do: agent.("agent-#{n}", "Agent #{n}", %{"description" => "writes code"}))

    ctx = Acp.publish(ctx, agents)
    {reply, ctx} = World.call(ctx, "server.searchAcpRegistry", %{"query" => query})
    Map.merge(ctx, %{reply: reply, query: query})
  end

  step "the user searches the registry", context do
    {reply, ctx} = World.call(context, "server.searchAcpRegistry", %{"query" => "acme"})
    Map.put(ctx, :reply, reply)
  end

  # An ACP sign-in (`context.auth_instance`, `context.flow`), cancelled from the client
  # `context.auth_client` so the others see it end.
  # The pending request of the turn on `context.thread`.
  # A model provider of an ACP Registry agent (`context.model_provider`), or else a
  # node plugin.
  step "the user disables {string}", %{args: [id]} = context do
    if context[:model_provider] == id do
      {result, ctx} =
        World.call!(context, "server.disableAcpRegistryProvider", %{
          "instanceId" => context.auth_instance,
          "projectId" => World.project(context).id,
          "providerId" => id
        })

      Map.put(ctx, :reply, {:ok, result})
    else
      {result, ctx} = World.call!(context, "plugins.disable", %{"id" => id})
      Map.put(ctx, :reply, {:ok, result})
    end
  end

  # The provider list the client "default" watches (`context.config_subs`) comes to offer
  # the model `slug` for the instance `context.model_instance`.
  step "{string} is offered in the model picker", %{args: [slug]} = context do
    sub = context.config_subs["default"]
    instance = context.model_instance

    {_, client} =
      Node.await(
        World.client(context),
        fn frame ->
          frame["t"] == "config.providers" and frame["id"] == sub and
            Enum.any?(frame["providers"], fn entry ->
              entry["instanceId"] == instance and
                Enum.any?(entry["models"] || [], &(&1["slug"] == slug))
            end)
        end,
        5_000
      )

    World.put_client(context, client)
  end

  # The union's W11 section defines the same step; keep one.
  # The provider list a client receives when it subscribes to the node's config.
  # Starts the thread a Given described (`context.pending_launch`: `instance`, and
  # `fields` such as "runtimeMode") with a message, and waits for its turn to end.
  # Without one, sends "Hello" to the scenario's existing FakeAcp thread.
  step "the user sends a message", context do
    case context[:pending_launch] do
      %{instance: instance, fields: fields} ->
        ctx =
          context
          |> Map.delete(:pending_launch)
          |> T3.Test.AcpFixtures.launch("Work", instance, "hello", mode: fields["runtimeMode"])

        T3.Test.AcpFixtures.await_runs(ctx.threads["Work"], 1)
        Map.put(ctx, :thread, "Work")

      nil ->
        T3.Test.FakeAcp.send_message(context, "Hello")
    end
  end

  # --- added by W1 ---
  # The thread a scenario is "looking at" is `context.current` (a title); steps
  # without a thread name act on it.

  # Threads and timeline scenarios open a fresh current thread; files and
  # source-control scenarios watch the existing project's VCS status instead.
  step "the user is looking at a thread in {string}", %{args: [project]} = context do
    if String.contains?(context.feature_file, ["/files/", "/source-control/"]) do
      World.watch_vcs(context, World.project(context, project).root)
    else
      context =
        if Map.has_key?(context.projects, project),
          do: context,
          else: World.create_project(context, project)

      context
      |> World.create_thread("Current thread", project)
      |> Map.put(:current, "Current thread")
      |> then(&World.put_client(&1, World.client(&1)))
    end
  end

  step "a project with an open thread", context do
    context
    |> World.create_project("shop")
    |> World.create_thread("Open thread", "shop")
    |> Map.put(:current, "Open thread")
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "the agent is working", context do
    World.working_thread(context, World.current(context))
  end

  step "the agent is working in {string}", %{args: [thread]} = context do
    World.working_thread(context, thread)
  end

  # Shared by threads/archive-delete, node/orchestration/mcp-thread-tools and
  # projections: the thread is archived (a running turn keeps running), or,
  # after it was archived, still is. A thread cut off mid-turn (`context.cut_off`,
  # recovery-and-idle-sessions.feature) is archived as stored data, leaving its run
  # as the restart finds it.
  step "{string} is archived", %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    cond do
      context[:cut_off] ->
        World.patch_thread(context, thread, %{"archivedAt" => World.iso_from_now(0)})

      # As an outcome ("... is archived" after an archive) it only checks.
      World.row(context, thread)["archivedAt"] == nil ->
        {:ok, _} =
          T3.Orchestration.dispatch(%{
            "type" => "thread.archive",
            "commandId" => "cmd-archive-#{System.unique_integer([:positive])}",
            "threadId" => id
          })

      true ->
        :ok
    end

    World.await_row(id, &(&1["archivedAt"] != nil))
    context
  end

  # Used both to delete a thread and to observe that it was deleted.
  step "the user interrupts the turn", context do
    title = World.current(context)

    run =
      context |> World.runs(title) |> Enum.find(&(&1["status"] in ~w(starting running waiting)))

    assert run, "no running turn in #{title}"

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, title),
        "runId" => run["id"]
      })

    Map.put(context, :interrupted_run, run["id"])
  end

  step "the turn stops", context do
    run_id = context[:interrupted_run]

    World.await_thread(context, World.current(context), fn state ->
      Enum.any?(
        T3.StreamState.list(state, "run"),
        &(&1["status"] == "interrupted" and run_id in [nil, &1["id"]])
      )
    end)

    context
  end

  step "the running turn is interrupted", context do
    World.await_thread(
      context,
      World.current(context),
      &Enum.any?(T3.StreamState.list(&1, "run"), fn run -> run["status"] == "interrupted" end)
    )

    context
  end

  step "the agent asks to run {string}", %{args: [command]} = context do
    World.request_from_agent(context, "approve run: #{command}")
  end

  step "a client archives {string}", %{args: [thread]} = context do
    client_command(context, "thread.archive", thread, &(&1["archivedAt"] != nil))
  end

  # A thread by that name, else a project; the reply is kept as `context.reply`.
  step "a client deletes {string}", %{args: [name]} = context do
    delete(context, name)
  end

  # A file below the T3 home (files/project-identity) or a thread or project.
  step "the user deletes {string}", %{args: [name]} = context do
    path = Path.join(context.node.home, name)

    if File.exists?(path) do
      File.rm!(path)
      context
    else
      delete(context, name)
    end
  end

  step ~r/^a client snoozes "(?<thread>[^"]+)" until (?<until>.+)$/,
       %{args: [thread, until]} = context do
    until =
      if until == "a past time",
        do: World.iso_from_now(-60 * 60 * 1_000),
        else: World.local_time(context, until)

    # node/orchestration/thread-organization.feature compares a refused snooze with this.
    context
    |> Map.put(:snooze_before, World.thread(context, thread))
    |> client_command("thread.snooze", thread, &(&1["snoozedUntil"] == until), %{
      "snoozedUntil" => until
    })
    |> Map.put(:snoozed_until, until)
  end

  step "a client unsnoozes {string}", %{args: [thread]} = context do
    client_command(context, "thread.unsnooze", thread, &(&1["snoozedUntil"] == nil))
  end

  step "a client marks {string} unread", %{args: [thread]} = context do
    client_command(context, "thread.mark-unread", thread, &(&1["lastVisitedAt"] == nil))
  end

  step "{string} is active again", %{args: [thread]} = context do
    row = World.row(context, thread)
    assert row["snoozedUntil"] == nil
    assert row["archivedAt"] == nil
    assert row["settledOverride"] in [nil, "active"]
    context
  end

  # Into a draft ("a new thread titled ...") this launches the thread with a title
  # asked for, as the web client does; otherwise it is sent to the current thread.
  step "the user sends {string}", %{args: [text]} = context do
    case context[:draft] do
      nil ->
        title = World.current(context)
        {{:ok, _}, context} = World.send_message(context, title, text)
        context

      draft ->
        context = if context[:title_generator], do: context, else: World.title_generator(context)

        {{:ok, _}, context} =
          World.launch_thread(context, nil, text, %{"title" => draft, "generateTitle" => true})

        Map.merge(context, %{current: draft, draft: nil})
    end
  end

  # Worktree setup of the thread in `context.current`; `context.worktree_path` is the
  # worktree it made.
  defp delete(context, name) do
    case {(context[:threads] || %{})[name], (context[:projects] || %{})[name]} do
      {id, _} when is_binary(id) ->
        client_command(context, "thread.delete", name, &(&1["deletedAt"] != nil))

      # node/orchestration/projects.feature also deletes projects it never created.
      {nil, project} ->
        mutation = %{
          "type" => "project.delete",
          "projectId" => (project || %{id: name}).id,
          "commandId" => "delete-#{name}"
        }

        {reply, context} = World.call(context, "projects.mutate", mutation)
        Map.put(context, :reply, reply)
    end
  end

  # A client's command on a thread, over the socket. The reply is `context.reply` and
  # the thread `context.thread`, as the orchestration refusal steps read them; on
  # success it waits until the sidebar row shows `done`. A thread the scenario never
  # created keeps its name as id ("missing").
  defp client_command(context, type, thread, done, fields \\ %{}) do
    id = (context[:threads] || %{})[thread] || thread
    command = Map.merge(%{"type" => type, "threadId" => id}, fields)
    {reply, context} = World.dispatch(context, command)
    if match?({:ok, _}, reply), do: World.await_row(id, done)
    context |> Map.put(:reply, reply) |> Map.put(:thread, thread)
  end

  # --- added by W12 ---

  # Cancels the provider's running install (`provider.install.cancel`); keeps the reply.
  step "the user cancels the installation", context do
    %{"operationId" => op} = T3.Acp.Antigravity.Installation.state()
    assert is_binary(op)

    {reply, context} =
      World.call(context, "provider.install.cancel", %{
        "instanceId" => context.provider,
        "operationId" => op
      })

    Map.put(context, :reply, reply)
  end

  # Every thread of the scenario still has its messages.
  step "thread history is kept", context do
    for {_title, id} <- context.threads do
      state = T3.Streams.Server.state(T3.Streams.ensure(id))
      assert %{^id => _} = T3.StreamState.get(state, "thread")
      assert [_ | _] = T3.StreamState.list(state, "message")
    end

    context
  end

  # `provider.auth.logout` for the provider under test; keeps the reply.
  step "the user signs out", context do
    {reply, context} =
      World.call(context, "provider.auth.logout", %{"instanceId" => context.provider})

    Map.put(context, :reply, reply)
  end

  # --- added by W14 ---

  # A node plugin replaced by its newer version, as a client's update does: the
  # plugin file a step staged in `context.plugin_updates` goes into the plugins
  # directory (`T3.Plugins` picks it up on the rescan). Without a staged plugin it
  # is a provider CLI update (`server.updateProvider`); the reply is `context.reply`
  # and the pushes that follow stay to be received.
  step "the user updates {string}", %{args: [id]} = context do
    case context[:plugin_updates][id] do
      nil ->
        provider =
          %{"Codex" => "codex", "Claude" => "claudeAgent"}[id] ||
            flunk("no update of #{inspect(id)} was staged in this scenario")

        {reply, context} =
          World.call_keeping(context, "server.updateProvider", %{"provider" => provider})

        Map.put(context, :reply, reply)

      source ->
        path = Path.join([context.node.home, "plugins", "#{id}.ex"])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, source)
        Node.ensure(T3.Settings)
        Node.ensure(T3.Plugins)
        {:ok, _} = T3.Plugins.handle("rescan", %{})
        context
    end
  end

  # The provider list a client last read (`context.providers`), or the node's.
  step ~r/^(Codex|Claude) is not offered as a provider$/, %{args: [name]} = context do
    driver = %{"Codex" => "codex", "Claude" => "claudeAgent"}[name]
    providers = context[:providers] || T3.Environment.providers()
    refute Enum.any?(providers, &(&1["driver"] == driver or &1["instanceId"] == driver))
    context
  end

  # The scenario's thread (`context.thread_id`, or the thread titled `context.thread`)
  # moves to Claude with its next message.
  step "the user switches the thread to Claude and sends a message", context do
    thread_id = context[:thread_id] || World.thread_id(context, context.thread)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "message.dispatch",
        "threadId" => thread_id,
        "messageId" => "switch-#{System.unique_integer([:positive])}",
        "text" => "where are we",
        "attachments" => [],
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-5"},
        "dispatchMode" => %{"type" => "start_immediately"},
        "deliveryIntent" => "auto"
      })

    Map.put(context, :thread_id, thread_id)
  end

  # --- added by W7 ---

  step "a node with a project {string} rooted at a git repository", %{args: [title]} = context do
    World.create_project(context, title)
  end

  # The orchestration features name threads by id ("t1"): the id is the name.
  step "thread {string} exists in {string}", %{args: [thread, project]} = context do
    World.named_thread(context, thread, project)
  end

  # Shared by node/orchestration/thread-organization.feature (setup: the user settled
  # it) and auto-settle.feature (outcome after a sweep, flagged by `:settle_swept`).
  step "thread {string} is settled", %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    unless context[:settle_swept] do
      {{:ok, _}, _} = World.dispatch(context, %{"type" => "thread.settle", "threadId" => id})
    end

    World.await_row(id, &(&1["settledOverride"] == "settled"))
    context
  end

  step "a client unsettles {string}", %{args: [thread]} = context do
    context
    |> client_command("thread.unsettle", thread, &(&1["settledOverride"] == "active"))
    |> Map.put(:settle_swept, false)
  end

  # Shared with other node/orchestration features; the step before it leaves the
  # RPC reply in `context.reply` as `{:error, message, detail}`. The message is the
  # refusal or a part of it.
  step "it fails with {string}", %{args: [message]} = context do
    assert {:error, error, _detail} = context.reply,
           "expected a refusal, got #{inspect(context.reply)}"

    assert error =~ message
    context
  end

  # Refusals of commands and RPCs alike: the step before it leaves the reply in
  # `context.reply`, `{:error, message, detail}` from a socket or `{:error, message}`
  # from `T3.Orchestration.dispatch/1`.
  # Ids in the refusal are compared by the names the scenario gives them (`World.named/2`);
  # the message is the refusal or a part of it.
  step "the command fails with {string}", %{args: [message]} = context do
    case context.reply do
      {:error, actual, _detail} -> assert World.named(context, actual) =~ message
      {:error, actual} -> assert World.named(context, actual) =~ message
      other -> flunk("expected a refusal, got #{inspect(other)}")
    end

    context
  end

  # As `World.send_turn/4`, keeping the reply (`context.reply`) for the refusal steps.
  step "the user sends {string} to {string}", %{args: [text, thread]} = context do
    context = World.providers(context)
    selection = (World.thread(context, thread) || %{})["modelSelection"]
    fields = if selection, do: %{"modelSelection" => selection}, else: %{}

    context
    |> World.command(World.message_command(context, thread, text, fields))
    |> Map.merge(%{run_title: thread, thread: thread})
  end

  # The transcript a client shows (`T3.Projection.Timeline`), in `context.timeline`.
  step "a client reads the timeline of {string}", %{args: [thread]} = context do
    resolve = fn id -> T3.Streams.Server.state(T3.Streams.ensure(id)) end

    Map.put(
      context,
      :timeline,
      T3.Projection.Timeline.visible_items(World.state(context, thread), resolve)
    )
  end

  # Also used by node/orchestration/threads.feature.
  step "thread {string} is titled {string}", %{args: [thread, title]} = context do
    assert World.thread(context, thread)["title"] == title
    context
  end

  # Shared with node/orchestration/queue-and-steering.feature and runs.feature: some
  # run of the scenario's thread (`context.thread`) for message `text` has started
  # (it may have finished already) and is out of the queue.
  step "a run for {string} starts", %{args: [text]} = context do
    World.await_state(context, context.thread, fn state ->
      messages = T3.StreamState.get(state, "message")

      Enum.any?(T3.StreamState.list(state, "run"), fn run ->
        run["status"] in ~w(starting running waiting completed) and
          run["queuePosition"] == nil and messages[run["userMessageId"]]["text"] == text
      end)
    end)

    context
  end

  # Shared with node/orchestration/runs.feature: the scenario's run (`context.running`),
  # else the latest run of `context.thread`, ends with `status`.
  step ~r/^the run is (?<status>failed|interrupted)$/, %{args: [status]} = context do
    World.await_state(context, context.thread, fn state ->
      runs = T3.StreamState.list(state, "run")

      run =
        if context[:running],
          do: Enum.find(runs, &(&1["id"] == context.running)),
          else: Enum.max_by(runs, & &1["ordinal"], fn -> nil end)

      run["status"] == status
    end)

    context
  end

  # --- added by W6 ---

  # An HTTP answer a previous step stored as `context.response`: `{status, headers,
  # body}` as `T3.Test.Node.request/4` returns it, or a map with a `:status`.
  step ~r/^the node answers (?<status>not found|unauthorized|service unavailable|bad gateway|\d{3})$/,
       %{args: [status]} = context do
    expected =
      case status do
        "not found" -> 404
        "unauthorized" -> 401
        "service unavailable" -> 503
        "bad gateway" -> 502
        code -> String.to_integer(code)
      end

    actual =
      case context.response do
        {status, _headers, _body} -> status
        %{status: status} -> status
      end

    assert actual == expected
    context
  end

  # Stops the server a previous step started as `context.dev_server`.
  step "that server stops", context do
    Process.unlink(context.dev_server)
    :ok = Supervisor.stop(context.dev_server)
    context
  end

  # --- added by W8 ---
  # Orchestration features name threads by id ("t1") and read the latest command
  # reply from `context.reply` (see `World.command/2`).

  # Runs are numbered as the orchestration features name them (`World.numbered_run/5`);
  # "run {int} of {string} is running" is in forks_and_merge_back_steps.exs.
  step "run {int} of {string} is waiting", %{args: [n, thread]} = context do
    context
    |> Map.put(:thread, thread)
    |> World.numbered_run(thread, n, "waiting")
  end

  step "the user answers {string}", %{args: [answer]} = context do
    context = World.answer_questions(context, context.thread, answer)
    assert {:ok, _} = context.reply, "answering failed: #{inspect(context.reply)}"
    context
  end

  # Five minutes on the node's clock: its five-minute timers fire, as their message
  # arrives (the idle session check, `T3.Orchestration.IdleSessions`).
  step "five minutes pass", context do
    pid = Node.ensure(T3.Orchestration.IdleSessions)
    send(pid, :check)
    # The check has run once the server answers the next call.
    _ = :sys.get_state(pid)
    context
  end
end
