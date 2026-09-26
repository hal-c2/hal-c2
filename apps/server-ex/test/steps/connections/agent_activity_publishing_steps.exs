defmodule HalC2.Steps.Connections.AgentActivityPublishing do
  @moduledoc "Steps for `features/connections/agent-activity-publishing.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Connect.{Jwt, Publisher}
  alias HalC2.Test.FakeRelay
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @fake_cloudflared Path.expand("../../support/fake_cloudflared.sh", __DIR__)
  @thread "Fix login"

  # Linked as the settings page links it: a proof for the relay, then the relay's
  # answer with a managed tunnel. The relay client is a fake on the PATH.
  step "a node linked to HAL-C2 Connect", context do
    relay = FakeRelay.start()
    bin = Node.tmp_dir(context.node, "bin")
    connector = Path.join(bin, "cloudflared")
    File.cp!(@fake_cloudflared, connector)
    File.chmod!(connector, 0o755)
    Application.put_env(:hal_c2, :relay_client_env, %{"PATH" => bin})

    ExUnit.Callbacks.on_exit({__MODULE__, :relay_host}, fn ->
      Application.delete_env(:hal_c2, :relay_client_env)
    end)

    Node.ensure(HalC2.Connect.Supervisor)

    context =
      context |> Map.put(:relay, relay) |> Map.put(:admin, Node.pair(Node.admin_scopes(), "Web"))

    {:ok, %{"challenge" => challenge}} =
      relay_post(relay, "/v1/client/environment-link-challenges", %{
        "managedTunnelsEnabled" => true
      })

    origin = "http://127.0.0.1:#{context.node.port}"

    {200, proof} =
      connect(context, "/api/connect/link-proof", %{
        "challenge" => challenge,
        "relayIssuer" => relay.url,
        "endpoint" => %{
          "httpBaseUrl" => origin,
          "wsBaseUrl" => String.replace_prefix(origin, "http", "ws"),
          "providerKind" => "cloudflare_tunnel"
        },
        "origin" => %{"localHttpHost" => "127.0.0.1", "localHttpPort" => context.node.port}
      })

    {:ok, link} =
      relay_post(relay, "/v1/client/environment-links", %{
        "proof" => proof,
        "managedTunnelsEnabled" => true
      })

    {200, %{"endpointRuntimeStatus" => %{"status" => "running"}}} = relay_config(context, link)

    context
    |> Map.put(:link, link)
    |> World.create_project("Website")
    |> World.create_thread(@thread)
  end

  step ~r/^agent activity publishing is (?<state>on|off)$/, %{args: [state]} = context do
    assert {200, %{"publishAgentActivity" => publish}} = preferences(context, state == "on")
    assert publish == (state == "on")
    context
  end

  step ~r/^an agent (?<event>starts a turn|is working|asks for approval|asks the user a question|completes its turn|fails its turn|finishes a turn)$/,
       %{args: [event]} = context do
    agent(context, event)
  end

  step "the node publishes nothing to the relay", context do
    assert published(context) == []
    context
  end

  step "the node publishes the thread's activity as {string}", %{args: [phase]} = context do
    states = for {state, _proof} <- published(context), do: state
    assert %{"phase" => ^phase} = state = List.last(states), "published #{inspect(states)}"
    Map.put(context, :activity, state)
  end

  step "the update names the project, thread, model and a link to the thread", context do
    env = HalC2.Environment.id()
    thread = World.thread_id(context, @thread)

    assert %{
             "environmentId" => ^env,
             "threadId" => ^thread,
             "projectTitle" => "Website",
             "threadTitle" => @thread,
             "modelTitle" => "gpt-5.4",
             "headline" => headline
           } = context.activity

    assert context.activity["deepLink"] == "/threads/#{env}/#{thread}"
    assert is_binary(headline) and headline != ""
    context
  end

  step "a published thread that was running", context do
    context |> preferences!(true) |> agent("is working") |> assert_published("running")
  end

  # A restart settles the cut-off turn as interrupted before HAL-C2 Connect starts again.
  step "the node restarts without finishing it", context do
    ExUnit.Callbacks.stop_supervised(HalC2.Connect.Supervisor)
    node = Node.restart(context.node)
    World.await_row(World.thread_id(context, @thread), &(&1["status"] == "interrupted"))
    Node.ensure(HalC2.Connect.Supervisor)
    Map.put(context, :node, node)
  end

  step "a published thread", context do
    context |> preferences!(true) |> agent("is working") |> assert_published("running")
  end

  step "the thread is deleted", context do
    thread = World.thread_id(context, @thread)
    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => thread})
    World.await_row(thread, &(&1["deletedAt"] != nil))
    context
  end

  step ~r/^the node (publishes an empty state for it|withdraws the thread's activity)$/,
       context do
    assert [{nil, _proof} | _] = Enum.reverse(published(context))
    context
  end

  step "the node publishes an update", context do
    agent(context, "is working")
  end

  step "the update carries the node's signed proof for that thread and state", context do
    assert [{state, proof}] = published(context)
    {public, _private} = Jwt.key_pair()
    env = HalC2.Environment.id()

    assert {:ok, claims} =
             Jwt.verify(
               proof,
               "hal-c2-env-activity+jwt",
               public,
               "hal-c2-env:" <> env,
               context.relay.url
             )

    assert claims["threadId"] == World.thread_id(context, @thread)
    assert claims["environmentId"] == env
    assert claims["state"] == state and state["phase"] == "running"
    context
  end

  step "an update the relay already accepted", context do
    context = context |> preferences!(true) |> agent("is working")
    assert [{state, proof}] = published(context)
    thread = World.thread_id(context, @thread)
    assert {HalC2.Environment.id(), thread, proof} in FakeRelay.get(context.relay, :accepted)
    Map.put(context, :update, {thread, %{"state" => state, "proof" => proof}})
  end

  step "it is sent again", context do
    {thread, body} = context.update

    reply =
      HalC2.Connect.relay(
        :post,
        activity_url(context, thread),
        context.link["environmentCredential"],
        body
      )

    Map.put(context, :reply, reply)
  end

  step "the relay refuses it as a replay", context do
    assert {:error, 409, message} = context.reply
    assert message =~ "already used"
    context
  end

  step "the user turns it off", context do
    assert {200, %{"publishAgentActivity" => false}} = preferences(context, false)
    context
  end

  step "later agent activity is not published", context do
    context = agent(context, "completes its turn")
    assert published(context) == []
    context
  end

  # What the settings page does when the tunnel is switched off with publishing on:
  # it links again without a managed tunnel.
  step "the managed tunnel is removed", context do
    {200, %{"endpointRuntimeStatus" => %{"status" => "disabled"}}} =
      relay_config(context, Map.put(context.link, "endpointRuntime", nil))

    context
  end

  step "publishing stays on", context do
    {200, state} = Node.http(context.node, :get, "/api/connect/link-state", bearer: context.admin)

    assert %{"linked" => true, "managedTunnelActive" => false, "publishAgentActivity" => true} =
             state

    context |> agent("completes its turn") |> assert_published("completed")
  end

  step "a node paired directly and not linked to HAL-C2 Connect", context do
    {200, %{"ok" => true}} = connect(context, "/api/connect/unlink", %{})
    context
  end

  step "the user cannot turn on agent activity publishing", context do
    assert {409, %{"message" => message}} = preferences(context, true)
    assert message =~ "Link this environment to HAL-C2 Connect"
    {200, state} = Node.http(context.node, :get, "/api/connect/link-state", bearer: context.admin)
    assert state["publishAgentActivity"] == false
    context
  end

  step "the relay cannot be reached", context do
    context = preferences!(context, true)

    unavailable = %{
      "_tag" => "RelayUnavailableError",
      "message" => "unavailable",
      "traceId" => "trace-1"
    }

    FakeRelay.set(context.relay, fail: [{"/agent-activity", 503, unavailable}])
    context
  end

  step "the turn completes as usual", context do
    assert %{"status" => "completed"} = World.row(context, @thread)
    assert [{%{"phase" => "completed"}, _}] = published(context)
    refute {HalC2.Environment.id(), World.thread_id(context, @thread)} in accepted(context)
    context
  end

  step "the node tries the next update when it happens", context do
    FakeRelay.set(context.relay, fail: [])
    context |> agent("starts a turn") |> assert_published("starting")
  end

  # --- helpers -----------------------------------------------------------------------

  # What an agent's turn leaves on the thread, as its provider would write it.
  defp agent(context, event) do
    case event do
      "starts a turn" ->
        World.add_run(context, @thread, "starting")

      "is working" ->
        World.add_run(context, @thread, "running")

      "asks for approval" ->
        context |> World.add_run(@thread, "running") |> request("command_approval")

      "asks the user a question" ->
        context |> World.add_run(@thread, "running") |> request("user_input")

      "fails its turn" ->
        World.add_run(context, @thread, "failed")

      _completes ->
        World.add_run(context, @thread, "completed")
    end
  end

  defp request(context, kind) do
    id = "runtime-request-#{System.unique_integer([:positive])}"

    World.put_entity(context, @thread, "runtime-request", id, %{
      "s" => %{
        "id" => id,
        "kind" => kind,
        "status" => "pending",
        "createdAt" => World.iso_from_now(0),
        "resolvedAt" => nil
      }
    })
  end

  defp assert_published(context, phase) do
    assert [{%{"phase" => ^phase}, _proof} | _] = Enum.reverse(published(context))
    context
  end

  # Every activity update the node sent this thread since the last look, oldest
  # first, as `{state, proof}`.
  defp published(context) do
    Publisher.drain()
    path = activity_path(context, World.thread_id(context, @thread))
    collect(path, [])
  end

  defp collect(path, acc) do
    receive do
      {:fake_relay, "POST", ^path, %{"state" => state, "proof" => proof}} ->
        collect(path, [{state, proof} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp accepted(context),
    do: for({env, thread, _} <- FakeRelay.get(context.relay, :accepted), do: {env, thread})

  defp activity_path(_context, thread),
    do: "/v1/environments/#{HalC2.Environment.id()}/threads/#{thread}/agent-activity"

  defp activity_url(context, thread), do: context.relay.url <> activity_path(context, thread)

  defp preferences(context, publish),
    do: connect(context, "/api/connect/preferences", %{"publishAgentActivity" => publish})

  defp preferences!(context, publish) do
    assert {200, %{"publishAgentActivity" => ^publish}} = preferences(context, publish)
    context
  end

  defp relay_config(context, link) do
    connect(context, "/api/connect/relay-config", %{
      "relayUrl" => context.relay.url,
      "relayIssuer" => link["relayIssuer"],
      "cloudUserId" => link["cloudUserId"],
      "environmentCredential" => link["environmentCredential"],
      "cloudMintPublicKey" => link["cloudMintPublicKey"],
      "endpointRuntime" => link["endpointRuntime"]
    })
  end

  defp connect(context, path, body),
    do: Node.http(context.node, :post, path, bearer: context.admin, json: body)

  defp relay_post(relay, path, body),
    do: HalC2.Connect.relay(:post, relay.url <> path, "clerk-token", body)
end
