defmodule T3.Steps.Connections.T3Connect do
  @moduledoc "Steps for `features/connections/t3-connect.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Connect.Secrets
  alias T3.Test.FakeRelay
  alias T3.Test.Node
  alias T3.Test.Node.World

  @fake_cloudflared Path.expand("../../support/fake_cloudflared.sh", __DIR__)
  @target {"linux", "x64"}

  # The account's relay, a relay client for linking to put on the PATH, and T3
  # Connect running on the node.
  step "a user signed in to T3 Connect", context do
    relay = FakeRelay.start()
    bin = Node.tmp_dir(context.node, "bin")
    install_fake(Path.join(bin, "cloudflared"))
    Application.put_env(:t3, :connect_relay_url, relay.url)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :connect_relay_url) end)
    Node.ensure(T3.Connect.Supervisor)

    context
    |> Map.put(:relay, relay)
    |> Map.put(:relay_bin, bin)
    |> Map.put(:admin, Node.pair(Node.admin_scopes(), "Web"))
  end

  # --- relay client ------------------------------------------------------------------

  step ~r/^the relay client is (?<state>installed by the node|found on the PATH|given by an override path|not installed|not built for this platform|missing)$/,
       %{args: [state]} = context do
    relay_host(context, %{"PATH" => ""})

    case state do
      "installed by the node" ->
        install_fake(managed_path(context))
        Map.put(context, :relay_source, "managed")

      "found on the PATH" ->
        dir = Node.tmp_dir(context.node, "bin")
        install_fake(Path.join(dir, "cloudflared"))
        relay_host(context, %{"PATH" => dir})
        Map.put(context, :relay_source, "path")

      "given by an override path" ->
        path = Path.join(Node.tmp_dir(context.node, "override"), "my-cloudflared")
        install_fake(path)
        relay_host(context, %{"PATH" => "", "T3CODE_CLOUDFLARED_PATH" => path})
        Map.put(context, :relay_source, "override")

      "not built for this platform" ->
        Application.put_env(:t3, :relay_client_target, {"sunos", "sparc"})
        context

      _missing ->
        context
    end
  end

  step "a client asks for the relay client status", context do
    {reply, context} = World.call(context, "cloud.getRelayClientStatus")
    Map.put(context, :reply, reply)
  end

  step "the node answers {string}", %{args: [status]} = context do
    assert {:ok, %{"status" => ^status, "version" => "2026.5.2"} = answer} = context.reply

    case context[:relay_source] do
      nil ->
        refute Map.has_key?(answer, "executablePath")

      source ->
        assert %{"source" => ^source, "executablePath" => path} = answer
        assert File.exists?(path)
    end

    context
  end

  step("a client installs it", context, do: install(context, "default"))
  step("a client installs the relay client", context, do: install(context, "default"))

  step "the node reports checking, downloading, verifying, installing, validating and activating",
       context do
    stages = for %{"type" => "progress", "stage" => stage} <- context.install_events, do: stage

    assert stages ==
             ~w(checking waiting_for_lock downloading verifying installing validating activating)

    context
  end

  step "finishes with the client available", context do
    assert %{"type" => "complete", "status" => %{"status" => "available", "source" => "managed"}} =
             List.last(context.install_events)

    {status, context} = World.call!(context, "cloud.getRelayClientStatus")
    assert %{"status" => "available", "source" => "managed", "executablePath" => path} = status
    assert {_, 0} = System.cmd(path, ["version"])
    context
  end

  step "a relay client install in progress", context do
    context = serve_download(context, File.read!(@fake_cloudflared))
    FakeRelay.set(context.relay, block: true)
    client = World.client(context, "first")
    client = Node.sub(client, 71, install_shape())
    assert_receive {:fake_relay, :download_held, _}, 5_000
    World.put_client(context, "first", client)
  end

  step "another client installs it", context do
    client = Node.sub(World.client(context, "second"), 72, install_shape())
    {_, client} = Node.await(client, &(&1["event"]["stage"] == "waiting_for_lock"))
    World.put_client(context, "second", client)
  end

  step "the second install waits for the lock", context do
    FakeRelay.release(context.relay)
    {first, _} = collect(World.client(context, "first"), 71)
    {second, _} = collect(World.client(context, "second"), 72)
    assert %{"type" => "complete", "status" => %{"status" => "available"}} = List.last(first)
    assert %{"type" => "complete", "status" => %{"status" => "available"}} = List.last(second)
    # The second found the first's install once it had the lock.
    refute Enum.any?(second, &(&1["stage"] == "downloading"))
    assert_receive {:fake_relay, "GET", _, _}
    refute_received {:fake_relay, "GET", _, _}
    context
  end

  step "the download fails", context do
    relay_host(context, %{"PATH" => ""})
    assets(context, "/download/missing", "0")
  end

  step "the download's checksum does not match", context do
    context = serve_download(context, File.read!(@fake_cloudflared))
    assets(context, "/download/cloudflared", String.duplicate("0", 64))
  end

  step "another install holds the lock too long", context do
    context = serve_download(context, File.read!(@fake_cloudflared))
    path = managed_path(context)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path <> ".lock", "")
    Application.put_env(:t3, :relay_client_lock, retries: 3, delay: 10)
    context
  end

  step "the override path does not exist", context do
    relay_host(context, %{"PATH" => "", "T3CODE_CLOUDFLARED_PATH" => "/nonexistent/cloudflared"})
  end

  step "the platform has no relay client", context do
    relay_host(context, %{"PATH" => ""})
    Application.put_env(:t3, :relay_client_target, {"sunos", "sparc"})
    context
  end

  step "the installed client does not run", context do
    serve_download(context, "#!/bin/sh\nexit 1\n")
  end

  step "the install folder cannot be written", context do
    context = serve_download(context, File.read!(@fake_cloudflared))
    # A file where the tools folder should be.
    File.write!(Path.join(context.node.home, "tools"), "")
    context
  end

  step "the install fails with {string}", %{args: [reason]} = context do
    assert %{"t" => "error", "reason" => ^reason, "detail" => %{"message" => message}} =
             context.install_error

    assert is_binary(message) and message != ""
    assert %{"status" => status} = T3.Connect.RelayClient.resolve()
    assert status != "available"
    context
  end

  defp install(context, name) do
    context = if context[:relay_download], do: context, else: default_download(context)
    client = Node.sub(World.client(context, name), 70, install_shape())
    {events, client} = collect(client, 70)
    context = World.put_client(context, name, client)

    case List.last(events) do
      %{"t" => "error"} = error ->
        Map.merge(context, %{install_error: error, install_events: events})

      _ ->
        Map.put(context, :install_events, events)
    end
  end

  # The events of an install subscription up to its end or error frame.
  defp collect(client, id, acc \\ []) do
    {frame, client} = Node.await(client, &(&1["id"] == id), 10_000)

    case frame do
      %{"t" => "end"} -> {Enum.reverse(acc), client}
      %{"t" => "error"} -> {Enum.reverse([frame | acc]), client}
      %{"t" => "relayClientInstall", "event" => event} -> collect(client, id, [event | acc])
    end
  end

  defp default_download(context), do: serve_download(context, File.read!(@fake_cloudflared))

  defp install_shape, do: %{"type" => "relayClientInstall", "node" => Atom.to_string(node())}

  # The relay serves `bytes` as the release for this host, which has no relay client yet.
  defp serve_download(context, bytes) do
    unless Application.get_env(:t3, :relay_client_env), do: relay_host(context, %{"PATH" => ""})
    FakeRelay.set(context.relay, downloads: %{"/download/cloudflared" => bytes})
    context = assets(context, "/download/cloudflared", sha256(bytes))
    Map.put(context, :relay_download, true)
  end

  defp assets(context, path, sha) do
    Application.put_env(:t3, :relay_client_assets, %{
      "linux-x64" => %{"url" => context.relay.url <> path, "sha256" => sha, "archive" => "binary"}
    })

    Map.put(context, :relay_download, true)
  end

  # Stands in for the host: its environment and platform, restored after the scenario.
  defp relay_host(context, env) do
    Application.put_env(:t3, :relay_client_env, env)
    Application.put_env(:t3, :relay_client_target, @target)

    ExUnit.Callbacks.on_exit({__MODULE__, :relay_host}, fn ->
      for key <- ~w(relay_client_env relay_client_target relay_client_assets relay_client_lock)a,
          do: Application.delete_env(:t3, key)
    end)

    context
  end

  defp managed_path(context) do
    {platform, arch} = @target

    Path.join([
      context.node.home,
      "tools",
      "cloudflared",
      "2026.5.2",
      "#{platform}-#{arch}",
      "cloudflared"
    ])
  end

  defp install_fake(path) do
    File.mkdir_p!(Path.dirname(path))
    File.cp!(@fake_cloudflared, path)
    File.chmod!(path, 0o755)
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # --- linking -----------------------------------------------------------------------

  step "the user links the node to their account", context do
    link(context)
  end

  step "a linked node", context do
    link(context)
  end

  step "the node proves its identity to the relay", context do
    env = context.node.environment
    {public, _} = T3.Connect.Jwt.key_pair()
    %{"claims" => claims} = FakeRelay.get(context.relay, :links)[env]

    # The relay accepted the proof only after checking its signature and challenge.
    assert claims["iss"] == "t3-env:" <> env
    assert claims["environmentId"] == env
    assert claims["environmentPublicKey"] == T3.Connect.Jwt.public_pem(public)
    assert "managed_tunnels" in claims["scopes"]

    assert %{"ok" => true, "endpointRuntimeStatus" => %{"status" => "running"}} =
             context.relay_config

    context
  end

  step "the node joins the account's environment list", context do
    assert %{"user" => "user-1"} = FakeRelay.get(context.relay, :links)[context.node.environment]

    assert %{"linked" => true, "cloudUserId" => "user-1", "managedTunnelActive" => true} =
             link_state(context)

    context
  end

  # --- brokered credentials ------------------------------------------------------------

  step "a signed-in device asks the relay for access", context do
    device = device_key()

    {status, body, claims} =
      FakeRelay.ask(context.relay, base(context), {:mint, device.jkt}, context.node.environment)

    Map.merge(context, %{device: device, minted: {status, body, claims}})
  end

  step "the node mints a one-time credential bound to that device's key", context do
    {200, %{"credential" => credential, "proof" => proof}, claims} = context.minted
    {public, _} = T3.Connect.Jwt.key_pair()
    env = context.node.environment

    assert {:ok, signed} =
             T3.Connect.Jwt.verify(
               proof,
               "t3-env-mint+jwt",
               public,
               "t3-env:" <> env,
               context.relay.url
             )

    assert signed["credential"] == credential
    assert signed["clientProofKeyThumbprint"] == context.device.jkt
    assert signed["requestNonce"] == claims["nonce"]
    # Two minutes to redeem it.
    assert signed["exp"] - signed["iat"] <= 120
    context
  end

  step "the device exchanges it with the node for a session", context do
    {200, %{"credential" => credential}, _} = context.minted
    assert {200, %{"access_token" => access}} = exchange(context, credential, context.device)

    assert {200, %{"authenticated" => true}} =
             Node.http(context.node, :get, "/api/auth/session", bearer: access)

    # One use only.
    assert {400, _} = exchange(context, credential, context.device)
    Map.put(context, :access_token, access)
  end

  step "the relay never sees the session", context do
    seen = relay_requests([])
    assert seen != []
    refute Enum.any?(seen, &(inspect(&1) =~ context.access_token))
    context
  end

  step "a credential minted for one device", context do
    context = link(context)
    device = device_key()

    {200, %{"credential" => credential}, _} =
      FakeRelay.ask(context.relay, base(context), {:mint, device.jkt}, context.node.environment)

    Map.merge(context, %{device: device, credential: credential})
  end

  step "another process presents it without that device's key", context do
    attempts = [
      exchange(context, context.credential, nil),
      exchange(context, context.credential, device_key())
    ]

    Map.put(context, :refusals, attempts)
  end

  step "the node refuses it", context do
    for {status, _body} <- context.refusals, do: assert(status in 400..499)

    # Refusing a stranger leaves the credential to the device it was minted for.
    if context[:credential],
      do:
        assert(
          {200, %{"access_token" => _}} = exchange(context, context.credential, context.device)
        )

    context
  end

  # --- health and relay requests ---------------------------------------------------------

  step "T3 Connect checks its health with a nonce", context do
    Map.put(
      context,
      :health,
      FakeRelay.ask(context.relay, base(context), :health, context.node.environment)
    )
  end

  step "the node answers with a response bound to that nonce", context do
    {200, %{"status" => "online", "proof" => proof} = body, claims} = context.health
    {public, _} = T3.Connect.Jwt.key_pair()
    env = context.node.environment
    assert body["environmentId"] == env

    assert {:ok, signed} =
             T3.Connect.Jwt.verify(
               proof,
               "t3-env-health+jwt",
               public,
               "t3-env:" <> env,
               context.relay.url
             )

    assert signed["requestNonce"] == claims["nonce"]
    assert signed["status"] == "online"
    context
  end

  step "the same request is replayed", context do
    {_, _, claims} = context.health
    {status, body} = FakeRelay.replay(context.relay, base(context), :health, claims)
    assert body["message"] == "Cloud health request was already consumed."
    Map.put(context, :refusals, [{status, body}])
  end

  step "a relay request arrives for another environment or another account", context do
    env = context.node.environment
    other = "env-other"
    jkt = device_key().jkt

    attempts =
      for kind <- [:health, {:mint, jkt}],
          claims <- [
            %{"environmentId" => other, "aud" => "t3-env:" <> other},
            %{"environmentId" => other},
            %{"sub" => "user-2"}
          ] do
        {status, body, _} = FakeRelay.ask(context.relay, base(context), kind, env, claims)
        {status, body}
      end

    assert Enum.all?(attempts, fn {status, _} -> status == 401 end)
    Map.put(context, :refusals, attempts)
  end

  step "a request through the tunnel carries forwarded authority headers", context do
    %{"challenge" => challenge} =
      relay_post(context, "/v1/client/environment-link-challenges", %{})

    reply =
      request(
        context,
        :post,
        "/api/connect/link-proof",
        admin(context),
        link_proof_body(context, challenge),
        [{~c"x-forwarded-host", ~c"attacker.example"}, {~c"x-forwarded-proto", ~c"https"}]
      )

    Map.put(context, :forwarded, reply)
  end

  step "the node's link proof rejects it", context do
    assert {400, %{"message" => "Invalid managed endpoint origin."}} = context.forwarded
    context
  end

  # --- unlinking -------------------------------------------------------------------------

  step "the user unlinks it", context do
    pid = tunnel_pid()

    assert {200, %{"ok" => true, "endpointRuntimeStatus" => %{"status" => "disabled"}}} =
             request(context, :post, "/api/connect/unlink", admin(context), %{})

    Map.put(context, :tunnel_pid, pid)
  end

  step "the relay no longer reaches it", context do
    env = context.node.environment
    assert {401, _, _} = FakeRelay.ask(context.relay, base(context), :health, env)

    assert {401, _, _} =
             FakeRelay.ask(context.relay, base(context), {:mint, device_key().jkt}, env)

    refute os_alive?(context.tunnel_pid)
    context
  end

  step "its link state reads unlinked", context do
    assert %{"linked" => false, "managedTunnelActive" => false, "cloudUserId" => nil} =
             link_state(context)

    context
  end

  # --- links made from the command line ----------------------------------------------------

  step "the user linked the node while it was stopped", context do
    cli_link(context)
  end

  step "it brings up its tunnel", context do
    assert %{"state" => "linked"} = T3.Connect.Link.status()
    env = context.node.environment

    assert %{"status" => "running", "tunnelId" => tunnel, "pid" => pid} =
             T3.Connect.Tunnel.status()

    assert tunnel == FakeRelay.get(context.relay, :links)[env]["tunnelId"]
    assert os_alive?(pid)
    # The connector runs with the token the relay issued for this node.
    assert File.read!("/proc/#{pid}/environ") =~ "TUNNEL_TOKEN=connector-" <> env
    context
  end

  step "a node linked from the command line", context do
    context = cli_link(context)
    context = %{context | node: Node.restart(context.node), clients: %{}}
    assert %{"state" => "linked"} = T3.Connect.Link.status()
    context
  end

  step "the node shuts down", context do
    %{"pid" => pid, "tunnelId" => tunnel} = T3.Connect.Tunnel.status()
    :ok = ExUnit.Callbacks.stop_supervised(T3.Connect.Supervisor)
    Map.merge(context, %{tunnel_pid: pid, tunnel_id: tunnel})
  end

  step "its tunnel is released", context do
    env = context.node.environment
    path = "/v1/client/environment-links/#{env}/tunnel"
    assert_receive {:fake_relay, "DELETE", ^path, _}, 1_000
    refute os_alive?(context.tunnel_pid)
    assert T3.Connect.Secrets.get("cloud-endpoint-runtime-config") == nil
    context
  end

  step "the account shows it offline rather than unauthorized", context do
    assert %{"online" => false, "user" => "user-1"} =
             FakeRelay.get(context.relay, :links)[context.node.environment]

    # The node keeps its link, so the relay can still vouch for it.
    assert T3.Connect.Secrets.get("cloud-linked-user-id") == "user-1"
    context
  end

  step "the next start reuses its address", context do
    Node.ensure(T3.Connect.Supervisor)
    assert %{"state" => "linked"} = T3.Connect.Link.status()
    assert %{"status" => "running", "tunnelId" => tunnel} = T3.Connect.Tunnel.status()
    assert tunnel == context.tunnel_id

    assert %{"online" => true, "tunnelId" => ^tunnel} =
             FakeRelay.get(context.relay, :links)[context.node.environment]

    context
  end

  step "the node upgrades itself", context do
    context = if context[:relay_config], do: context, else: link(context)
    %{"pid" => pid} = T3.Connect.Tunnel.status()
    dir = Node.tmp_dir(context.node, "upgrade")
    src = Path.join(dir, "tunnel.ex")
    source = File.read!(Path.expand("../../../lib/t3/connect/tunnel.ex", __DIR__))
    File.write!(src, String.replace(source, "@state_version 1", "@state_version 2"))

    {_, 0} =
      System.cmd("elixirc", ["--ignore-module-conflict", "-o", dir, src], stderr_to_stdout: true)

    ExUnit.Callbacks.on_exit(fn ->
      T3.Hot.reload(T3.Hot.beams_from_dir(Application.app_dir(:t3, "ebin")))
    end)

    tunnel = Process.whereis(T3.Connect.Tunnel)
    assert {:ok, %{migrated: migrated}} = T3.Hot.reload(T3.Hot.beams_from_dir(dir))
    assert tunnel in migrated
    Map.put(context, :tunnel_pid, pid)
  end

  step "its tunnel stays up throughout", context do
    assert %{v: 2} = :sys.get_state(T3.Connect.Tunnel)
    assert %{"status" => "running", "pid" => pid} = T3.Connect.Tunnel.status()
    assert pid == context.tunnel_pid
    # The same connector process, never restarted.
    assert os_alive?(pid)
    context
  end

  step "an operator signed in without starting the node", context do
    :ok = ExUnit.Callbacks.stop_supervised(T3.Connect.Supervisor)
    :ok = ExUnit.Callbacks.stop_supervised(T3.Web)
    cli_link(context)
  end

  step "no device can reach the node until it runs", context do
    env = context.node.environment
    assert {:error, _} = :httpc.request(~c"#{base(context)}/.well-known/t3/environment")
    assert FakeRelay.get(context.relay, :links)[env] == nil
    refute File.exists?(runs_log(context))

    context = %{context | node: Node.restart(context.node), clients: %{}}
    Node.ensure(T3.Connect.Supervisor)
    assert %{"state" => "linked"} = T3.Connect.Link.status()
    assert %{"user" => "user-1"} = FakeRelay.get(context.relay, :links)[env]
    assert {200, _, _} = FakeRelay.ask(context.relay, base(context), :health, env)
    context
  end

  step "the operator asks for the connect status", context do
    context = cli_link(context)
    Map.put(context, :printed, Node.run_task(Mix.Tasks.T3.Connect, ["status"]))
  end

  step "it prints the saved authorization and link settings", context do
    text = Enum.join(context.printed, "\n")
    assert text =~ "T3 Connect"
    assert text =~ "  Exposure: enabled"
    assert text =~ "  Authorization: stored credential"
    assert text =~ "  Environment link: pending server startup"
    assert text =~ "  Relay client: available via PATH"
    context
  end

  step "does not test reachability", context do
    assert Enum.join(context.printed, "\n") =~ "This is saved setup, not a live connection check."
    # Nothing was asked of the relay.
    assert relay_requests([]) == []
    context
  end

  step "the operator unlinks from the command line", context do
    Secrets.put(
      "cloud-cli-oauth-token",
      JSON.encode!(%{
        "accessToken" => "cli-token",
        "refreshToken" => "r",
        "expiresAtEpochMs" => 0
      })
    )

    pid = tunnel_pid()
    printed = Node.run_task(Mix.Tasks.T3.Connect, ["unlink"])
    Map.merge(context, %{printed: printed, tunnel_pid: pid})
  end

  step "the node stops being exposed", context do
    env = context.node.environment
    assert "T3 Connect is disabled locally." in context.printed
    assert "Revoked the relay-side environment record." in context.printed
    refute os_alive?(context.tunnel_pid)
    assert FakeRelay.get(context.relay, :links)[env] == nil
    assert %{"linked" => false} = link_state(context)
    assert T3.Connect.desired_link() == nil
    context
  end

  step "the operator stays signed in", context do
    assert T3.Connect.cli_token() == "cli-token"
    context
  end

  # --- startup failures --------------------------------------------------------------------

  step ~r/^the relay answers the node with (?<failure>.+)$/, %{args: [failure]} = context do
    {suffix, status, body} =
      case failure do
        "the environment link limit" ->
          {"environment-link-challenges", 409,
           relay_error("RelayEnvironmentLinkLimitExceededError", "Environment link limit reached")}

        "an invalid or revoked bearer" ->
          {"environment-link-challenges", 401,
           relay_error("RelayAuthInvalidError", "Authorization is invalid")}

        "an expired or invalid link proof" ->
          {"environment-links", 400,
           relay_error("RelayEnvironmentLinkProofExpiredError", "Link proof expired")}

        "a 403 without a recognised error" ->
          {"environment-link-challenges", 403, "Forbidden"}
      end

    FakeRelay.set(context.relay, fail: [{suffix, status, body}])
    cli_link(context)
  end

  step ~r/^it reports (?<recovery>.+)$/, %{args: [recovery]} = context do
    hint =
      case recovery do
        "deregister an unused environment, then restart" ->
          "Unlink an unused environment in T3 Connect, then restart T3 Code on this machine."

        "sign in again, then restart" ->
          "sign out with `t3 connect logout`, then run `t3 connect` again. Restart T3 Code after signing in."

        "check the host's clock and update" ->
          "Check this machine's date and time, update T3 Code, then restart it."

        "check relay access, proxies and firewall rules" ->
          "Check relay access and any proxy or firewall restrictions, then restart T3 Code."
      end

    status = T3.Connect.Link.status()
    # Not worth retrying: the operator has to act.
    assert %{"state" => "failed", "attempts" => 1, "message" => message} = status
    assert message =~ hint

    if recovery =~ "clock" or recovery =~ "deregister" or recovery =~ "sign in",
      do: assert(message =~ "Trace ID: trace-1.")

    context
  end

  step "the relay answers 408, 429 or a server error", context do
    Application.put_env(:t3, :connect_retry_delays, [5, 20])
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :connect_retry_delays) end)

    FakeRelay.set(context.relay,
      fail_once:
        for(
          status <- [408, 429, 500, 503],
          do:
            {"environment-link-challenges", status,
             relay_error("RelayUnavailableError", "Relay unavailable")}
        )
    )

    cli_link(context)
  end

  step "it keeps retrying for up to ten minutes", context do
    path = "/v1/client/environment-link-challenges"
    for _ <- 1..5, do: assert_receive({:fake_relay, "POST", ^path, _}, 2_000)
    path = "/v1/client/environment-links"
    assert_receive {:fake_relay, "POST", ^path, _}, 2_000

    status = T3.Connect.Link.status()
    assert %{"state" => "linked", "attempts" => 5} = status
    assert status["giveUpAt"] - status["startedAt"] == :timer.minutes(10)
    context
  end

  # --- link helpers ------------------------------------------------------------------------

  # Links the node as the web client does (`linkEnvironment.ts`): a relay challenge,
  # the node's proof for it, the relay's link, and the relay's answer back to the node.
  defp link(context) do
    relay_host(context, %{"PATH" => context.relay_bin})

    %{"challenge" => challenge} =
      relay_post(context, "/v1/client/environment-link-challenges", %{
        "managedTunnelsEnabled" => true
      })

    {200, proof} =
      request(
        context,
        :post,
        "/api/connect/link-proof",
        admin(context),
        link_proof_body(context, challenge)
      )

    link =
      relay_post(context, "/v1/client/environment-links", %{
        "proof" => proof,
        "notificationsEnabled" => true,
        "liveActivitiesEnabled" => true,
        "managedTunnelsEnabled" => true
      })

    {200, config} =
      request(context, :post, "/api/connect/relay-config", admin(context), %{
        "relayUrl" => context.relay.url,
        "relayIssuer" => link["relayIssuer"],
        "cloudUserId" => link["cloudUserId"],
        "environmentCredential" => link["environmentCredential"],
        "cloudMintPublicKey" => link["cloudMintPublicKey"],
        "endpointRuntime" => link["endpointRuntime"]
      })

    Map.put(context, :relay_config, config)
  end

  defp link_proof_body(context, challenge) do
    origin = base(context)

    %{
      "challenge" => challenge,
      "relayIssuer" => context.relay.url,
      "endpoint" => %{
        "httpBaseUrl" => origin,
        "wsBaseUrl" => String.replace_prefix(origin, "http", "ws"),
        "providerKind" => "cloudflare_tunnel"
      },
      "origin" => %{"localHttpHost" => "127.0.0.1", "localHttpPort" => context.node.port}
    }
  end

  # What `t3 connect link` saves on the host: the wish for a managed link and the
  # operator's sign-in. The node acts on it when it starts.
  defp cli_link(context) do
    relay_host(context, %{"PATH" => context.relay_bin})
    Secrets.put("cloud-cli-desired-link", "managed")

    Secrets.put(
      "cloud-cli-oauth-token",
      JSON.encode!(%{
        "accessToken" => "cli-token",
        "refreshToken" => "r",
        "expiresAtEpochMs" => 0
      })
    )

    context
  end

  defp link_state(context) do
    {200, state} = request(context, :get, "/api/connect/link-state", admin(context), nil)
    state
  end

  defp admin(context), do: context[:admin] || Node.pair(Node.admin_scopes(), "Web")

  defp base(context), do: "http://127.0.0.1:#{context.node.port}"

  defp relay_post(context, path, body) do
    {:ok, reply} = T3.Connect.relay(:post, context.relay.url <> path, "clerk-token", body)
    reply
  end

  defp relay_error(tag, message),
    do: %{"_tag" => tag, "message" => message, "traceId" => "trace-1"}

  defp request(context, method, path, bearer, body, headers \\ []) do
    url = String.to_charlist(base(context) <> path)
    headers = [{~c"authorization", ~c"Bearer " ++ String.to_charlist(bearer)} | headers]

    req =
      if body == nil,
        do: {url, headers},
        else: {url, headers, ~c"application/json", JSON.encode!(body)}

    {:ok, {{_, status, _}, _, reply}} =
      :httpc.request(method, req, [timeout: 5_000], body_format: :binary)

    {status, JSON.decode!(reply)}
  end

  # A device's DPoP key (P-256), as the mobile app keeps one.
  defp device_key do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    <<4, x::binary-32, y::binary-32>> = public
    b64 = &Base.url_encode64(&1, padding: false)
    jwk = %{"kty" => "EC", "crv" => "P-256", "x" => b64.(x), "y" => b64.(y)}
    %{jwk: jwk, private: private, jkt: T3.Connect.Jwt.thumbprint(jwk)}
  end

  defp dpop(device, method, url) do
    b64 = &Base.url_encode64(&1, padding: false)
    header = b64.(JSON.encode!(%{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => device.jwk}))

    payload =
      b64.(
        JSON.encode!(%{
          "htm" => method,
          "htu" => url,
          "jti" => "dpop-#{System.unique_integer([:positive])}",
          "iat" => System.os_time(:second)
        })
      )

    der = :crypto.sign(:ecdsa, :sha256, header <> "." <> payload, [device.private, :prime256v1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    header <> "." <> payload <> "." <> b64.(<<r::256, s::256>>)
  end

  # `/oauth/token` as a device redeems a credential, with a DPoP proof when it has a key.
  defp exchange(context, credential, device) do
    url = base(context) <> "/oauth/token"
    headers = if device, do: [{~c"dpop", String.to_charlist(dpop(device, "POST", url))}], else: []

    form =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token_type" => "urn:t3:params:oauth:token-type:environment-bootstrap",
        "subject_token" => credential
      })

    {:ok, {{_, status, _}, _, reply}} =
      :httpc.request(
        :post,
        {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", form},
        [],
        body_format: :binary
      )

    {status, JSON.decode!(reply)}
  end

  defp relay_requests(acc) do
    receive do
      {:fake_relay, _, _, _} = request -> relay_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp tunnel_pid do
    %{"status" => "running", "pid" => pid} = T3.Connect.Tunnel.status()
    pid
  end

  defp os_alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))

  defp runs_log(context), do: Path.join(context.relay_bin, "runs.log")
end
