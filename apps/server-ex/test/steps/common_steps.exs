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
  step "the user refreshes provider status", context do
    {reply, context} = World.call_keeping(context, "server.refreshProviders", %{})
    Map.put(context, :reply, reply)
  end

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
