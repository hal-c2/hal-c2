defmodule HalC2.Steps.Providers.Antigravity do
  @moduledoc """
  Steps for `features/providers/antigravity.feature`. Google's runtime is played by
  the scripted fake (`HalC2.Test.FakeAcp` with `googleAuth`, see
  `test/support/fake_google_auth.py`): the release the node downloads is a zip of
  the fake's wrapper and a helper script, fetched from disk through the
  `:antigravity_fetch` seam, and Google's sign-in page is the fake's loopback
  listener. Nothing reaches the network.

  An older runtime (`@old`) is active when a scenario starts; the release on offer
  is `@version`.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Acp.Antigravity
  alias HalC2.Acp.Antigravity.Installation
  alias HalC2.Test.{FakeAcp, Node}
  alias HalC2.Test.Node.World

  @version "agy_acp_server_1.1.1"
  @old "agy_acp_server_1.1.0"
  @instance "antigravity"
  @models [
    %{
      "id" => "model",
      "name" => "Model",
      "type" => "select",
      "currentValue" => "fake/one",
      "options" => [%{"value" => "fake/one", "name" => "Fake/One"}]
    }
  ]

  # --- the environment ------------------------------------------------------------

  step "Antigravity is enabled on that environment", context do
    agent = %{
      "agentName" => "antigravity-acp",
      "version" => @version,
      "capabilities" => %{"auth" => %{"logout" => %{}}},
      "authMethods" => [
        %{"id" => "oauth-personal", "name" => "Google account"},
        %{"id" => "oauth-business", "name" => "Gemini Enterprise"},
        %{"id" => "gemini-api-key", "name" => "Gemini API key"},
        %{"id" => "agent-platform", "name" => "Agent Platform"}
      ],
      "googleAuth" => true,
      "turns" => FakeAcp.turns()
    }

    context =
      FakeAcp.install(context, @instance, agent, binary: "agy_acp_server.par", enabled: true)

    # The managed runtime, not the fake's wrapper, is what the instance runs.
    FakeAcp.settings(&put_in(&1, ["providers", @instance], %{"enabled" => true}))

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.ProviderAuth.Registry},
        id: :provider_auth_registry
      )
    )

    Node.ensure(
      Supervisor.child_spec(
        {DynamicSupervisor, name: HalC2.ProviderAuth.Supervisor, strategy: :one_for_one},
        id: :provider_auth_supervisor
      )
    )

    keys = [
      :antigravity_platform,
      :antigravity_release,
      :antigravity_fetch,
      :antigravity_free_space
    ]

    ExUnit.Callbacks.on_exit(fn ->
      for key <- keys, do: Application.delete_env(:hal_c2, key)
      :persistent_term.erase({HalC2.Acp, @instance, :workspaces})
    end)

    Application.put_env(:hal_c2, :antigravity_platform, {"linux", "x64"})
    {release, archive} = build_release(context, @version)
    Application.put_env(:hal_c2, :antigravity_release, release)
    context = Map.merge(context, %{release: release, archive: archive, instance: @instance})
    fetch(context, :copy)
    Map.put(context, :old_release, place(context, @old))
  end

  # --- installing -------------------------------------------------------------------

  step "the Antigravity runtime is not installed", context do
    File.rm_rf!(Antigravity.managed_dir())
    assert {:error, "Antigravity is not installed" <> _} = Antigravity.resolve(nil)
    context
  end

  step "the user installs the Antigravity runtime", context do
    context = context |> installer() |> watch_install()
    {_, context} = World.call!(context, "provider.install.start", %{"instanceId" => @instance})
    {states, context} = collect_install(context, &(&1["phase"] in ~w(succeeded failed)))
    Map.put(context, :install_states, states)
  end

  step "the user sees the download progress in megabytes", context do
    total = context.release.archive_bytes
    downloading = Enum.filter(context.install_states, &(&1["phase"] == "downloading"))
    assert [_ | _] = downloading

    # The client shows `downloadedBytes` of `totalBytes` in megabytes.
    assert Enum.all?(downloading, &(&1["totalBytes"] == total))
    assert Enum.any?(downloading, &(&1["downloadedBytes"] == total))

    assert Enum.map(downloading, & &1["downloadedBytes"]) |> Enum.sort() ==
             Enum.map(downloading, & &1["downloadedBytes"])

    context
  end

  step "then that it is extracting and then checking the runtime", context do
    phases = context.install_states |> Enum.map(& &1["phase"]) |> Enum.dedup()

    assert ["downloading", "extracting", "verifying", "succeeded"] =
             Enum.drop_while(phases, &(&1 == "idle"))

    assert Enum.find(context.install_states, &(&1["phase"] == "extracting"))["message"] =~
             "Extracting"

    assert Enum.find(context.install_states, &(&1["phase"] == "verifying"))["message"] =~
             "Checking"

    context
  end

  step "finally that Antigravity is installed", context do
    assert %{"phase" => "succeeded", "installedVersion" => @version, "canRemove" => true} =
             List.last(context.install_states)

    assert {:ok, %{source: "managed", version: @version}} = Antigravity.resolve(nil)
    context
  end

  step "the Antigravity runtime is downloading", context do
    downloading(context)
  end

  step "the client disconnects and reconnects", context do
    Mint.HTTP.close(World.client(context).conn)
    client = Node.connect(context.node)
    context = context |> World.put_client(client) |> Map.delete(:install_sub) |> watch_install()
    Map.put(context, :install_snapshot, context.install_first)
  end

  step "the download progress is still shown", context do
    before = context.install_state

    assert %{"phase" => "downloading", "operationId" => op, "downloadedBytes" => bytes} =
             context.install_snapshot

    assert op == before["operationId"]
    assert bytes > 0 and bytes == before["downloadedBytes"]

    # The download goes on and finishes for the client that came back.
    send(context.fetch_worker, :go)
    {states, context} = collect_install(context, &(&1["phase"] in ~w(succeeded failed)))
    assert %{"phase" => "succeeded", "installedVersion" => @version} = List.last(states)
    context
  end

  step "an older Antigravity runtime is installed and a new one is downloading", context do
    assert {:ok, %{version: @old}} = Antigravity.resolve(nil)
    downloading(context)
  end

  step "the user is told the previous runtime is unchanged", context do
    assert {:ok, %{"phase" => "cancelled", "message" => message}} = context.reply
    assert message == "Installation cancelled. The previous runtime is unchanged."
    previous_unchanged(context)
  end

  step "the downloaded runtime does not match the published checksum", context do
    fetch(context, :corrupt)
    context
  end

  step "the installation checks the download", context do
    context = context |> installer() |> watch_install()
    {_, context} = World.call!(context, "provider.install.start", %{"instanceId" => @instance})
    {states, context} = collect_install(context, &(&1["phase"] in ~w(succeeded failed)))
    Map.put(context, :install_states, states)
  end

  step "the installation fails", context do
    assert %{"phase" => "failed", "message" => message} = List.last(context.install_states)

    assert message ==
             "The Antigravity download failed its size or SHA-256 check. Nothing was installed."

    context
  end

  step "the previous runtime is unchanged", context do
    previous_unchanged(context)
  end

  step "the Antigravity installation failed for lack of disk space", context do
    Application.put_env(:hal_c2, :antigravity_free_space, fn _dir -> 1024 * 1024 end)
    context = context |> installer() |> watch_install()
    {_, context} = World.call!(context, "provider.install.start", %{"instanceId" => @instance})
    {states, context} = collect_install(context, &(&1["phase"] in ~w(succeeded failed)))
    assert %{"phase" => "failed", "message" => message} = List.last(states)
    assert message =~ ~r/^Antigravity needs at least \d+ MiB of free space to install\.$/
    context
  end

  step "the user frees space and retries the installation", context do
    Application.put_env(:hal_c2, :antigravity_free_space, fn _dir -> 64 * 1024 * 1024 * 1024 end)
    {_, context} = World.call!(context, "provider.install.start", %{"instanceId" => @instance})
    {states, context} = collect_install(context, &(&1["phase"] in ~w(succeeded failed)))
    Map.put(context, :install_states, states)
  end

  step "the runtime is installed", context do
    assert %{"phase" => "succeeded", "installedVersion" => @version} =
             List.last(context.install_states)

    assert {:ok, %{source: "managed", version: @version}} = Antigravity.resolve(nil)
    context
  end

  # --- removing ---------------------------------------------------------------------

  step "the Antigravity runtime is installed and the user is signed in", context do
    assert {:ok, %{source: "managed"}} = Antigravity.resolve(nil)

    context
    |> installer()
    |> signed_in()
    |> FakeAcp.thread("Work")
    |> World.add_message("Work", "user", "Fix the checkout")
  end

  step "no Antigravity session is running", context do
    assert Antigravity.sessions(@instance) == []
    context
  end

  step "the user removes the downloaded runtime and confirms", context do
    context = watch_install(context)

    {reply, context} =
      World.call(context, "provider.install.remove", %{"instanceId" => @instance})

    Map.put(context, :reply, reply)
  end

  step "the runtime is removed", context do
    assert {:ok, %{"installedVersion" => nil, "canRemove" => false}} = context.reply
    refute File.exists?(Antigravity.managed_dir())
    {providers, context} = FakeAcp.open_config(context)

    assert %{"installed" => false, "message" => "Antigravity is not installed" <> _} =
             FakeAcp.find(providers, @instance)

    context
  end

  step "the Google sign-in and thread history are kept", context do
    assert File.exists?(Antigravity.token_path(@instance))
    assert %{"type" => "oauth-personal"} = Antigravity.account(@instance)
    assert_history(context)
  end

  step "an Antigravity session is running", context do
    running_session(context)
  end

  step "the user tries to remove the downloaded runtime", context do
    {reply, context} =
      World.call(context, "provider.install.remove", %{"instanceId" => @instance})

    Map.put(context, :reply, reply)
  end

  step "the removal is refused until the sessions and sign-ins stop", context do
    assert {:error, message, %{"operation" => "remove-install"}} = context.reply

    assert message ==
             "Stop Antigravity sessions and sign-in flows before removing its managed runtime."

    assert {:ok, %{version: @old}} = Antigravity.resolve(nil)
    context
  end

  # --- platforms and manual installations ------------------------------------------

  step "the environment runs on an Intel Mac", context do
    Application.put_env(:hal_c2, :antigravity_platform, {"darwin", "x64"})
    Application.delete_env(:hal_c2, :antigravity_release)
    HalC2.Acp.forget(@instance)
    context
  end

  step "the user opens Antigravity setup", context do
    {providers, context} = FakeAcp.open_config(context)
    context = installer(context)
    {reply, context} = World.call(context, "provider.install.start", %{"instanceId" => @instance})
    context |> Map.put(:entry, FakeAcp.find(providers, @instance)) |> Map.put(:reply, reply)
  end

  step "the user is told Google does not publish a runtime for this platform", context do
    assert %{"installed" => false, "status" => "error", "message" => message} = context.entry
    assert message =~ "Google does not publish an Antigravity runtime for darwin-x64."
    assert {:error, install, _} = context.reply
    assert install =~ "Google does not publish an Antigravity runtime for darwin-x64."
    context
  end

  step "is offered to set a binary path or use another environment", context do
    assert context.entry["message"] =~ "Use a supported environment or a custom executable."
    assert {:error, install, _} = context.reply
    assert install =~ "Use a supported remote environment or a custom executable."
    context
  end

  step "the user extracted the Antigravity executable and its helper into one folder", context do
    Map.put(context, :manual, manual_folder(context, true))
  end

  step "the user sets the binary path to that executable", context do
    exe = Path.join(context.manual, "agy_acp_server.par")

    write_settings(context, fn settings ->
      put_in(settings, ["providers", @instance, "binaryPath"], exe)
    end)
  end

  step "Antigravity uses that installation", context do
    {result, context} =
      World.call!(context, "server.refreshProviders", %{
        "instanceId" => @instance,
        "refreshModels" => true
      })

    entry = FakeAcp.find(result["providers"], @instance)
    assert entry["installed"] != false and entry["status"] != "error"

    assert %{"env" => %{"ANTIGRAVITY_HARNESS_PATH" => harness}} =
             List.last(FakeAcp.starts(context))

    assert harness == Path.join(context.manual, "localharness_external")
    context
  end

  step "the managed installer leaves it alone", context do
    context = installer(context)

    for method <- ["provider.install.start", "provider.install.remove"] do
      {reply, _} = World.call(context, method, %{"instanceId" => @instance})
      assert {:error, message, _} = reply
      assert message =~ "This instance uses a custom executable."
    end

    assert File.exists?(Path.join(context.manual, "agy_acp_server.par"))
    assert {:ok, %{"releaseId" => _}} = File.read!(Antigravity.active_path()) |> JSON.decode()
    context
  end

  step "the binary path points to an Antigravity executable without its helper", context do
    folder = manual_folder(context, false)
    exe = Path.join(folder, "agy_acp_server.par")
    FakeAcp.settings(&put_in(&1, ["providers", @instance, "binaryPath"], exe))
    context
  end

  step "the user is told the executable or its helper is missing", context do
    assert %{"installed" => false, "message" => message} =
             FakeAcp.find(context.providers, @instance)

    assert message ==
             "The custom Antigravity executable or its localharness_external sibling is missing or not executable."

    context
  end

  # --- signing in -----------------------------------------------------------------

  step "the Antigravity runtime is installed", context do
    assert {:ok, %{source: "managed"}} = Antigravity.resolve(nil)
    context
  end

  step "the Antigravity runtime is installed on the environment", context do
    assert {:ok, %{source: "managed"}} = Antigravity.resolve(nil)
    context
  end

  step "the user signs in with a Google account and finishes in the browser", context do
    context = start_sign_in(context)
    assert browser(context.flow, %{"code" => "google-code"}) =~ "Sign-in succeeded"
    await_auth(context, "succeeded")
  end

  step "Antigravity confirms access and loads the account's models", context do
    assert %{"message" => "Signed in with Google."} = context.auth
    entry = await_signed_in(context, @instance)
    assert [%{"slug" => "fake/one"}] = entry["models"]
    context
  end

  step "the user started sign-in from a phone connected to a remote environment", context do
    context
    |> World.put_client("phone", Node.connect(context.node))
    |> start_sign_in(@instance, "phone")
  end

  step "the final Google page failed to load", context do
    # Google redirected to the phone's own loopback address, which reaches nothing.
    assert %{"phase" => "waiting", "interaction" => %{"acceptsCallback" => true}} = context.auth
    refute File.exists?(Antigravity.token_path(@instance))
    context
  end

  step "the user pastes the full return address into the sign-in", context do
    paste(context, callback(context.flow, %{"code" => "google-code", "scope" => "openid"}))
  end

  step "Antigravity confirms access", context do
    assert {:ok, %{"phase" => "verifying"}} = context.reply
    context = await_auth(context, "succeeded")
    assert context.auth["message"] == "Signed in with Google."
    await_signed_in(context, @instance)
    context
  end

  step "the user started sign-in on one client", context do
    start_sign_in(context)
  end

  step "a return address from a different sign-in attempt is pasted", context do
    %URI{port: port} = URI.parse(context.flow.redirect)

    other =
      "http://127.0.0.1:#{port}/oauth2callback?" <>
        URI.encode_query(%{"state" => "another-attempt", "code" => "google-code"})

    paste(context, other)
  end

  step "the user is told the address does not belong to the current sign-in", context do
    assert {:error, "This redirect URL does not belong to the current sign-in.",
            %{"operation" => "complete"}} = context.reply

    # The sign-in still waits for its own address.
    assert %{"phase" => "waiting"} = current_auth(context)
    refute File.exists?(Antigravity.token_path(@instance))
    context
  end

  step "the Google page says sign-in succeeded", context do
    # Google lets the account in, but the account cannot open a session.
    FakeAcp.configure(context, fn config ->
      Map.put(config, "sessionError", %{
        "code" => -32603,
        "message" => "No models for this account"
      })
    end)

    context = start_sign_in(context)
    Map.put(context, :page, browser(context.flow, %{"code" => "google-code"}))
  end

  step "Antigravity cannot confirm account access", context do
    assert context.page =~ "Sign-in succeeded"
    await_auth(context, "failed")
  end

  step "Antigravity is not shown as signed in", context do
    assert Antigravity.account(@instance) == nil
    {providers, context} = FakeAcp.open_config(context)
    entry = FakeAcp.find(providers, @instance)
    refute entry["auth"]["status"] == "authenticated"
    refute entry["status"] == "ready"
    context
  end

  step "the user is told why", context do
    assert context.auth["message"] ==
             "Antigravity authenticated, but could not initialize a session or load models."

    context
  end

  step "the user started Google sign-in", context do
    start_sign_in(context)
  end

  step "five minutes pass without finishing", context do
    # The flow's five-minute timer firing now.
    [{server, _}] = Registry.lookup(HalC2.ProviderAuth.Registry, @instance)
    send(server, {:expire, context.flow.id})
    await_auth(context, "failed")
  end

  step "the user is told Google sign-in expired", context do
    assert context.auth["message"] == "Google sign-in expired. Start sign-in again."
    refute File.exists?(Antigravity.token_path(@instance))
    context
  end

  step ~r/^the user chooses the sign-in method (?<method>.+) and provides (?<credentials>.+)$/,
       %{args: [method, credentials]} = context do
    {method_id, variants} =
      case {method, credentials} do
        {"Google account", "a browser sign-in"} ->
          {"oauth-personal", [%{}]}

        {"Gemini Enterprise", "a browser sign-in, GCP project and location"} ->
          {"oauth-business", [%{"gcpProject" => "shop-project", "gcpLocation" => "us-central1"}]}

        {"Gemini API key", "an API key"} ->
          {"gemini-api-key", [%{"apiKey" => "gemini-key"}]}

        {"Agent Platform", "an API key, or a GCP project and location"} ->
          {"agent-platform",
           [
             %{"apiKey" => "platform-key"},
             %{"gcpProject" => "shop-project", "gcpLocation" => "us-central1"}
           ]}
      end

    flows =
      for fields <- variants do
        FakeAcp.settings(
          &put_in(
            &1,
            ["providers", @instance],
            Map.merge(%{"enabled" => true, "authMethod" => method_id}, fields)
          )
        )

        # Each variant signs in from scratch.
        File.rm(Antigravity.token_path(@instance))

        flow =
          if Antigravity.browser?(method_id),
            do: start_sign_in(context),
            else: start_flow(context)

        if Antigravity.browser?(method_id),
          do: assert(browser(flow.flow, %{"code" => "google-code"}) =~ "Sign-in succeeded")

        flow = await_auth(flow, ~w(succeeded failed))
        {fields, flow.auth, Antigravity.account(@instance)}
      end

    context
    |> Map.put(:method_id, method_id)
    |> Map.put(:flows, flows)
  end

  step "Antigravity connects with that method", context do
    method = context.method_id

    for {fields, auth, account} <- context.flows do
      assert %{"phase" => "succeeded"} = auth
      assert %{"type" => ^method, "label" => label} = account
      assert label == Antigravity.label(method)
      settings = Path.join([Antigravity.profile(@instance), "antigravity-acp", "settings.json"])
      written = settings |> File.read!() |> JSON.decode!()
      assert written["auth"] == %{"type" => method}
      refute File.read!(settings) =~ ~r/gemini-key|platform-key|ambient-key/

      if fields["gcpProject"],
        do: assert(written["gcp"] == %{"project" => "shop-project", "location" => "us-central1"})
    end

    envs = for %{"env" => env} <- FakeAcp.starts(context), do: env

    case method do
      "gemini-api-key" ->
        assert Enum.any?(envs, &(&1["GEMINI_API_KEY"] == "gemini-key"))

      "agent-platform" ->
        assert Enum.any?(envs, &(&1["GOOGLE_API_KEY"] == "platform-key"))
        assert Enum.any?(envs, &(not Map.has_key?(&1, "GOOGLE_API_KEY")))

      _ ->
        refute Enum.any?(envs, &Map.has_key?(&1, "GEMINI_API_KEY"))
    end

    await_signed_in(context, @instance)
    context
  end

  step "the environment has a Gemini API key in its variables", context do
    HalC2.Test.Node.Terminal.put_env("GEMINI_API_KEY", "ambient-key")
    HalC2.Test.Node.Terminal.put_env("GOOGLE_CLOUD_PROJECT", "ambient-project")
    context
  end

  step "the Antigravity instance uses a Google account", context do
    assert Antigravity.config(@instance)["authMethod"] == "oauth-personal"
    signed_in(context)
  end

  step "a thread runs on Antigravity", context do
    context = context |> FakeAcp.thread("Work") |> FakeAcp.send_message("hello")
    FakeAcp.await_run(context, "completed")
    context
  end

  step "the Google account is used", context do
    assert [%{"env" => env} | _] =
             Enum.filter(FakeAcp.starts(context), &(&1["cwd"] == World.project(context).root))

    refute Map.has_key?(env, "GEMINI_API_KEY")
    refute Map.has_key?(env, "GOOGLE_CLOUD_PROJECT")
    assert env["GEMINI_HOME"] == Antigravity.profile(@instance)

    assert [%{"params" => %{"methodId" => "oauth-personal"}} | _] =
             FakeAcp.received(context, "authenticate")

    context
  end

  step "the user changes the sign-in method", context do
    {_, context} = FakeAcp.open_config(context)

    write_settings(context, fn settings ->
      put_in(settings, ["providers", @instance, "authMethod"], "gemini-api-key")
      |> put_in(["providers", @instance, "apiKey"], "gemini-key")
    end)
  end

  step "the instance's sessions stop", context do
    sessions_stopped(context)
  end

  step "its sessions stop", context do
    sessions_stopped(context)
  end

  step "the user is signed in to Antigravity", context do
    running_session(context)
  end

  step "the instance's sessions stop and its saved Google login is removed", context do
    assert {:ok, %{"phase" => "idle", "message" => "Signed out of Google."}} = context.reply
    assert Antigravity.sessions(@instance) == []
    assert %{conn: nil} = :sys.get_state(runtime(context))
    refute File.exists?(Antigravity.token_path(@instance))
    assert Antigravity.account(@instance) == nil
    assert [_] = FakeAcp.received(context, "logout")
    context
  end

  step ~r/^the user sends "\/logout" by itself in an Antigravity thread$/, context do
    context = context |> signed_in() |> FakeAcp.thread("Work") |> FakeAcp.send_message("/logout")
    Map.put(context, :run_state, FakeAcp.await_run(context, "completed"))
  end

  step "that instance is signed out", context do
    assert [%{"type" => "command_execution"} = item] =
             Enum.filter(
               HalC2.StreamState.list(context.run_state, "turn-item"),
               &(&1["type"] == "command_execution")
             )

    assert item["output"] == "Provider signed out" or item["status"] == "completed"
    assert inspect(item) =~ "Provider signed out"
    refute File.exists?(Antigravity.token_path(@instance))
    assert Antigravity.account(@instance) == nil
    # The message never reached the agent as a prompt.
    assert FakeAcp.received(context, "session/prompt") == []
    context
  end

  step "the Antigravity runtime does not support sign-out", context do
    FakeAcp.configure(context, &Map.put(&1, "capabilities", %{}))
    context
  end

  step "the user is told to update the provider", context do
    assert {:error, "This Antigravity version does not support sign-out. Update the provider.",
            %{"operation" => "logout"}} = context.reply

    context
  end

  step "the user disables Antigravity", context do
    {_, context} = FakeAcp.open_config(context)
    FakeAcp.enable(context, @instance, false)
  end

  step "the Google sign-in is kept for when it is enabled again", context do
    assert File.exists?(Antigravity.token_path(@instance))
    context = FakeAcp.enable(context, @instance, true)
    await_signed_in(context, @instance)
    context
  end

  step "two Antigravity instances {string} and {string}", %{args: [first, second]} = context do
    FakeAcp.settings(fn settings ->
      Map.put(
        settings,
        "providerInstances",
        Map.new([first, second], fn id ->
          {id,
           %{
             "driver" => "antigravity",
             "enabled" => true,
             "config" => %{"authMethod" => "oauth-personal"}
           }}
        end)
      )
    end)

    Map.put(context, :pair, [first, second])
  end

  step "the user signs in to each with a different Google account", context do
    for id <- context.pair do
      FakeAcp.configure(context, &Map.put(&1, "account", "#{id}@example.com"))
      flow = start_sign_in(context, id, id)
      assert browser(flow.flow, %{"code" => "code-#{id}"}) =~ "Sign-in succeeded"
      assert %{auth: %{"phase" => "succeeded"}} = await_auth(flow, "succeeded", id)
    end

    context
  end

  step "each instance uses its own account and the downloaded runtime is shared", context do
    [first, second] = context.pair
    refute Antigravity.profile(first) == Antigravity.profile(second)

    for id <- context.pair do
      assert %{"account" => account} =
               Antigravity.token_path(id) |> File.read!() |> JSON.decode!()

      assert account == "#{id}@example.com"
      await_signed_in(context, id)
    end

    assert {:ok, %{executable: exe, source: "managed"}} = Antigravity.resolve(nil)
    assert [_one] = File.ls!(Antigravity.versions_dir())

    homes =
      for %{"argv" => _, "env" => env} <- FakeAcp.starts(context),
          env["ANTIGRAVITY_HARNESS_PATH"] == Path.join(Path.dirname(exe), "localharness_external"),
          uniq: true,
          do: env["GEMINI_HOME"]

    assert Enum.sort(homes) == Enum.sort(Enum.map(context.pair, &Antigravity.profile/1))
    context
  end

  step "Antigravity still shows the saved account", context do
    # A restarted node has read nothing from the agent yet.
    HalC2.Acp.forget(@instance)
    :persistent_term.erase({HalC2.Acp, @instance, :unauthenticated})
    await_signed_in(context, @instance)
    context
  end

  # --- threads --------------------------------------------------------------------

  step "an Antigravity thread with two turns", context do
    context = context |> signed_in() |> FakeAcp.thread("Work") |> FakeAcp.send_message("first")
    FakeAcp.await_runs(context, 1)
    context = FakeAcp.send_message(context, "second")
    FakeAcp.await_runs(context, 2)
    # Work the user did after the second turn.
    notes = Path.join(World.project(context).root, "notes.txt")
    File.write!(notes, "after the second turn\n")
    Map.put(context, :notes, notes)
  end

  step "the user tries to revert to the first turn", context do
    thread_id = World.thread_id(context, "Work")
    scope = HalC2.Checkpoint.scope_id(thread_id)

    reply =
      HalC2.Orchestration.dispatch(%{
        "type" => "checkpoint.rollback",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "scopeId" => scope,
        "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope, 1)
      })

    Map.put(context, :reply, reply)
  end

  step "the revert is refused before any file is touched", context do
    assert {:error, message} = context.reply
    assert message =~ "Antigravity cannot rewind its conversation"
    assert File.read!(context.notes) == "after the second turn\n"
    state = FakeAcp.await_runs(context, 2)
    assert Enum.all?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "completed"))
    context
  end

  step "the user opens the mode picker in an Antigravity thread", context do
    context = FakeAcp.thread(context, "Work")
    {providers, context} = FakeAcp.open_config(context)
    Map.put(context, :entry, FakeAcp.find(providers, @instance))
  end

  step "plan mode is not offered", context do
    assert %{"showInteractionModeToggle" => false} = context.entry
    context
  end

  step ~r/^the user attaches (?<attachment>.+) to an Antigravity message$/,
       %{args: [attachment]} = context do
    files =
      case attachment do
        "a 900 KiB text file" ->
          [{"notes.txt", "text/plain", 900 * 1024, :text}]

        "a 2 MiB text file" ->
          [{"notes.txt", "text/plain", 2 * 1024 * 1024, :text}]

        "a 12 MiB image" ->
          [{"photo.png", "image/png", 12 * 1024 * 1024, :sparse}]

        "a 15 MiB audio clip" ->
          [{"clip.mp3", "audio/mpeg", 15 * 1024 * 1024, :sparse}]

        "files totalling 60 MiB" ->
          for n <- 1..4, do: {"clip-#{n}.mp3", "audio/mpeg", 15 * 1024 * 1024, :sparse}

        "an unsupported file format" ->
          [{"archive.zip", "application/zip", 1024, :sparse}]
      end

    context = context |> signed_in() |> FakeAcp.thread("Work")
    dir = Path.join(context.node.home, "attachments")
    File.mkdir_p!(dir)

    attachments =
      for {name, mime, size, fill} <- files do
        id = "att-#{System.unique_integer([:positive])}"
        path = Path.join(dir, id <> Path.extname(name))

        case fill do
          :text ->
            File.write!(path, :binary.copy("a", size))

          :sparse ->
            {:ok, file} = :file.open(path, [:write, :binary])
            {:ok, _} = :file.position(file, size)
            :ok = :file.truncate(file)
            :ok = :file.close(file)
        end

        type = if String.starts_with?(mime, "image/"), do: "image", else: "file"
        %{"type" => type, "id" => id, "name" => name, "mimeType" => mime, "sizeBytes" => size}
      end

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, "Work"),
        "messageId" => "msg-#{System.unique_integer([:positive])}",
        "text" => "Look at this",
        "attachments" => attachments
      })

    Map.put(context, :attachments, attachments)
  end

  step "the attachment is accepted", context do
    FakeAcp.await_run(context, "completed")
    [%{"params" => %{"prompt" => prompt}}] = FakeAcp.received(context, "session/prompt")
    assert Enum.any?(prompt, &(&1["type"] in ["resource", "audio"]))
    context
  end

  step "the attachment is rejected", context do
    state = FakeAcp.await_run(context, "failed")
    assert last_error(state) =~ ~r/^Attachment '.+' is too large\.|does not support/
    assert FakeAcp.received(context, "session/prompt") == []
    context
  end

  step ~r/^the project has the skill "(?<name>[^"]+)" in both \.gemini\/skills and \.agents\/skills$/,
       %{args: [name]} = context do
    # The user's own skill folders are empty.
    HalC2.Test.Node.Host.home(context)
    root = World.project(context).root

    for {dir, from} <- [{".gemini/skills", "gemini"}, {".agents/skills", "agents"}] do
      skill = Path.join([root, dir, name])
      File.mkdir_p!(skill)

      File.write!(Path.join(skill, "SKILL.md"), """
      ---
      name: #{name}
      description: Deploy from #{from}
      ---
      Ship it.
      """)
    end

    context
  end

  step "the user opens the skill list in an Antigravity thread", context do
    context = FakeAcp.thread(context, "Work")

    {result, context} =
      World.call!(context, "server.refreshProviders", %{
        "instanceId" => @instance,
        "cwd" => World.project(context).root
      })

    Map.put(context, :providers, result["providers"])
  end

  step ~r/^"(?<name>[^"]+)" is offered once, from (?<dir>\S+)$/, %{args: [name, dir]} = context do
    root = World.project(context).root
    entry = FakeAcp.find(context.providers, @instance)

    assert [%{"skills" => skills}] =
             Enum.filter(entry["workspaceSnapshots"], &(&1["cwd"] == root))

    assert [skill] = Enum.filter(skills, &(&1["name"] == name))
    assert skill["path"] == Path.join([root, dir, name, "SKILL.md"])
    assert skill["description"] == "Deploy from gemini"
    context
  end

  step "Antigravity starts subagents", context do
    turn = %{
      "match" => "split the work",
      "steps" => [
        %{
          "update" => %{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "subagents-1",
            "title" => "Running start_subagent",
            "kind" => "other",
            "status" => "in_progress",
            "rawInput" => %{"subagents" => [%{"task" => "Check the tests"}]},
            "content" => [
              %{
                "type" => "content",
                "content" => %{"type" => "text", "text" => "Check the tests"}
              }
            ]
          }
        },
        %{
          "update" => %{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => "subagents-1",
            "status" => "completed"
          }
        },
        %{"text" => "The subagents finished."}
      ]
    }

    FakeAcp.configure(context, &Map.update!(&1, "turns", fn turns -> [turn | turns] end))

    context =
      context |> signed_in() |> FakeAcp.thread("Work") |> FakeAcp.send_message("split the work")

    Map.put(context, :run_state, FakeAcp.await_run(context, "completed"))
  end

  step "their activity is shown as a subagent batch", context do
    items = HalC2.StreamState.list(context.run_state, "turn-item")
    assert [item] = Enum.filter(items, &(&1["type"] == "subagent"))
    assert inspect(item) =~ "Antigravity subagent batch"
    assert inspect(item) =~ "provider_native"
    assert inspect(item) =~ "Check the tests"
    refute Enum.any?(items, &(&1["type"] == "dynamic_tool"))
    context
  end

  step "an Antigravity thread uses a model the account can no longer use", context do
    context
    |> signed_in()
    |> FakeAcp.thread("Work", "full-access", %{
      "modelSelection" => %{"instanceId" => @instance, "model" => "gemini-retired"}
    })
  end

  step "the user is asked to pick another available model", context do
    state = FakeAcp.await_run(context, "failed")

    assert last_error(state) =~
             "Antigravity model 'gemini-retired' is unavailable for this Google account. Select an available model."

    assert FakeAcp.received(context, "session/prompt") == []
    context
  end

  step "Google reports that a subscription is required", context do
    message =
      "SUBSCRIPTION_REQUIRED: This account needs a Google AI plan to use Antigravity. Retry after 2026-09-27T09:00:00Z."

    turn = %{
      "match" => "keep going",
      "steps" => [%{"error" => %{"code" => -32603, "message" => message}}]
    }

    FakeAcp.configure(context, &Map.update!(&1, "turns", fn turns -> [turn | turns] end))

    context =
      context |> signed_in() |> FakeAcp.thread("Work") |> FakeAcp.send_message("keep going")

    Map.put(context, :google_message, message)
  end

  step "the thread shows Google's message and any retry time", context do
    state = FakeAcp.await_run(context, "failed")
    assert last_error(state) == context.google_message
    assert last_error(state) =~ "Retry after 2026-09-27T09:00:00Z"
    context
  end

  step "the user signs in from the mobile app's provider accounts", context do
    context =
      context
      |> World.put_client("mobile", Node.connect(context.node))
      |> start_sign_in(@instance, "mobile")

    # The phone cannot reach the environment's loopback address: it pastes the return.
    paste(context, callback(context.flow, %{"code" => "google-code"}))
  end

  # --- helpers --------------------------------------------------------------------

  # A release zip of the fake's wrapper and a helper, as Google publishes it.
  defp build_release(context, version) do
    dir = Node.tmp_dir(context.node, "agy-release")
    File.cp!(FakeAcp.fake(context, @instance).bin, Path.join(dir, "agy_acp_server.par"))
    File.write!(Path.join(dir, "localharness_external"), "#!/bin/sh\nexit 0\n")
    archive = Path.join(Node.tmp_dir(context.node, "agy-archive"), "runtime.zip")

    {:ok, _} =
      :zip.create(
        String.to_charlist(archive),
        [~c"agy_acp_server.par", ~c"localharness_external"],
        cwd: String.to_charlist(dir)
      )

    data = File.read!(archive)

    release = %{
      version: version,
      url: "https://dl.google.com/agy-extensions/releases/test/runtime.zip",
      sha256: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower),
      archive_bytes: byte_size(data),
      executable: {"agy_acp_server.par", File.stat!(Path.join(dir, "agy_acp_server.par")).size},
      harness: {"localharness_external", File.stat!(Path.join(dir, "localharness_external")).size}
    }

    {release, archive}
  end

  # An installed, active runtime of `version`, as a finished install leaves it.
  defp place(context, version) do
    id = :crypto.hash(:sha256, version) |> Base.encode16(case: :lower)
    dir = Path.join(Antigravity.versions_dir(), id)
    File.mkdir_p!(dir)
    exe = Path.join(dir, "agy_acp_server.par")
    harness = Path.join(dir, "localharness_external")
    File.cp!(FakeAcp.fake(context, @instance).bin, exe)
    File.write!(harness, "#!/bin/sh\nexit 0\n")
    for file <- [exe, harness], do: File.chmod!(file, 0o755)

    File.write!(
      Path.join(dir, ".install-complete.json"),
      JSON.encode!(%{
        "releaseId" => id,
        "version" => version,
        "executable" => %{"name" => "agy_acp_server.par", "bytes" => File.stat!(exe).size},
        "harness" => %{"name" => "localharness_external", "bytes" => File.stat!(harness).size}
      })
    )

    File.write!(Antigravity.active_path(), JSON.encode!(%{"releaseId" => id}))
    id
  end

  # How the download behaves: `:copy` at once, `:gate` halfway until the test sends
  # `:go` to the worker, `:corrupt` with a changed byte.
  defp fetch(context, mode) do
    test = self()
    data = File.read!(context.archive)

    Application.put_env(:hal_c2, :antigravity_fetch, fn _url, dest, progress ->
      case mode do
        :copy ->
          :ok

        :corrupt ->
          :ok

        :gate ->
          progress.(div(byte_size(data), 2))
          send(test, {:antigravity_fetch, self()})

          receive do
            :go -> :ok
          end
      end

      bytes =
        if mode == :corrupt,
          do: corrupt(data),
          else: data

      File.write!(dest, bytes)
      progress.(byte_size(bytes))
      :ok
    end)
  end

  # The same bytes with one flipped in the middle.
  defp corrupt(data) do
    at = div(byte_size(data), 2)
    byte = :binary.at(data, at)

    binary_part(data, 0, at) <>
      <<Bitwise.bxor(byte, 0xFF)>> <> binary_part(data, at + 1, byte_size(data) - at - 1)
  end

  defp installer(context) do
    Node.ensure(Installation)
    context
  end

  # An install started and halfway through its download.
  defp downloading(context) do
    fetch(context, :gate)
    context = context |> installer() |> watch_install()
    {_, context} = World.call!(context, "provider.install.start", %{"instanceId" => @instance})

    worker =
      receive do
        {:antigravity_fetch, pid} -> pid
      after
        5_000 -> flunk("the download never started")
      end

    {states, context} =
      collect_install(context, &(is_integer(&1["downloadedBytes"]) and &1["downloadedBytes"] > 0))

    context |> Map.put(:fetch_worker, worker) |> Map.put(:install_state, List.last(states))
  end

  defp previous_unchanged(context) do
    old = context.old_release
    assert %{"releaseId" => ^old} = Antigravity.active_path() |> File.read!() |> JSON.decode!()
    assert {:ok, %{version: @old}} = Antigravity.resolve(nil)
    refute File.exists?(Path.join(Antigravity.versions_dir(), context.release.sha256))
    assert %{"installedVersion" => @old} = Installation.state()

    assert Enum.filter(File.ls!(Antigravity.managed_dir()), &String.starts_with?(&1, ".staging")) ==
             []

    context
  end

  # Subscribes the scenario's socket to the install state; keeps the first snapshot.
  defp watch_install(%{install_sub: _} = context), do: context

  defp watch_install(context) do
    id = System.unique_integer([:positive])

    client =
      World.client(context)
      |> Node.sub(id, %{
        "type" => "providerInstall",
        "node" => Atom.to_string(node()),
        "instanceId" => @instance
      })

    {frame, client} = Node.await(client, &(&1["t"] == "providerInstall" and &1["id"] == id))

    context
    |> World.put_client(client)
    |> Map.merge(%{install_sub: id, install_first: frame["state"]})
  end

  # Install states pushed until one satisfies `done?`; returns `{states, context}`.
  defp collect_install(context, done?, acc \\ []) do
    id = context.install_sub

    {frame, client} =
      Node.await(
        World.client(context),
        &(&1["t"] == "providerInstall" and &1["id"] == id),
        15_000
      )

    context = World.put_client(context, client)
    acc = [frame["state"] | acc]

    if done?.(frame["state"]),
      do: {Enum.reverse(acc), context},
      else: collect_install(context, done?, acc)
  end

  defp manual_folder(context, helper?) do
    folder = Node.tmp_dir(context.node, "antigravity-manual")
    exe = Path.join(folder, "agy_acp_server.par")
    File.cp!(FakeAcp.fake(context, @instance).bin, exe)
    File.chmod!(exe, 0o755)

    if helper? do
      harness = Path.join(folder, "localharness_external")
      File.write!(harness, "#!/bin/sh\nexit 0\n")
      File.chmod!(harness, 0o755)
    end

    folder
  end

  # Rewrites the settings over the socket, as a client's settings page does.
  defp write_settings(context, fun) do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "halc2.readSettings")

    {_, context} =
      World.call!(context, "halc2.writeSettings", %{
        "settings" => fun.(settings),
        "version" => version
      })

    context
  end

  # A saved Google login and the account a session showed, as a finished sign-in leaves them.
  defp signed_in(context, instance \\ @instance) do
    token = Antigravity.token_path(instance)
    File.mkdir_p!(Path.dirname(token))
    File.write!(token, JSON.encode!(%{"account" => "user@example.com"}))
    Antigravity.put_account(instance, HalC2.Acp.session_models(%{"configOptions" => @models}))
    context
  end

  # Signed in, with a thread whose session is open.
  defp running_session(context) do
    context = context |> installer() |> signed_in() |> FakeAcp.thread("Work")
    context = FakeAcp.send_message(context, "hello")
    FakeAcp.await_run(context, "completed")
    assert [_] = Antigravity.sessions(@instance)
    context
  end

  defp runtime(context) do
    [{pid, _}] = Registry.lookup(HalC2.Acp.Registry, World.thread_id(context, "Work"))
    pid
  end

  defp sessions_stopped(context) do
    {_, context} =
      FakeAcp.await_providers(context, fn _ -> Antigravity.sessions(@instance) == [] end)

    assert %{conn: nil, session_id: nil} = :sys.get_state(runtime(context))
    context
  end

  defp assert_history(context) do
    for {_title, id} <- context.threads do
      state = HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
      assert %{"id" => ^id} = HalC2.StreamState.get(state, "thread")[id]
      assert [_ | _] = HalC2.StreamState.list(state, "message")
    end

    context
  end

  defp last_error(state) do
    state
    |> HalC2.StreamState.list("provider-session")
    |> Enum.find_value(& &1["lastError"])
  end

  # --- sign-in flows ---------------------------------------------------------------

  defp auth_sub(context, instance, name) do
    key = {name, instance}

    case context[:auth_subs][key] do
      nil ->
        id = System.unique_integer([:positive])

        client =
          World.client(context, name)
          |> Node.sub(id, %{
            "type" => "providerAuth",
            "node" => Atom.to_string(node()),
            "instanceId" => instance
          })

        {_frame, client} = Node.await(client, &(&1["t"] == "providerAuth" and &1["id"] == id))

        context =
          context
          |> World.put_client(name, client)
          |> Map.update(:auth_subs, %{key => id}, &Map.put(&1, key, id))

        {id, context}

      id ->
        {id, context}
    end
  end

  # Starts a sign-in; returns the context with its sign-in state.
  defp start_flow(context, instance \\ @instance, name \\ "default") do
    {id, context} = auth_sub(context, instance, name)

    {state, context} =
      World.call!(context, "provider.auth.start", %{"instanceId" => instance}, name)

    Map.merge(context, %{auth: state, auth_at: {name, instance, id}})
  end

  # Starts a browser sign-in and waits for Google's link.
  defp start_sign_in(context, instance \\ @instance, name \\ "default") do
    context = context |> start_flow(instance, name) |> await_auth("waiting", name)
    %{"interaction" => %{"url" => url, "id" => flow_id}} = context.auth
    assert url =~ "https://accounts.google.com/o/oauth2/v2/auth?"
    assert {:ok, %{redirect_uri: redirect, state: state}} = Antigravity.Auth.authorization(url)
    Map.put(context, :flow, %{id: flow_id, url: url, redirect: redirect, state: state})
  end

  # The sign-in state once its phase is one of `phases`.
  defp await_auth(context, phases, _name \\ nil) do
    phases = List.wrap(phases)
    {name, _instance, id} = context.auth_at

    if context.auth["phase"] in phases and context.auth["phase"] != "starting" and
         Map.get(context, :auth_seen) != context.auth do
      Map.put(context, :auth_seen, context.auth)
    else
      {frame, client} =
        Node.await(
          World.client(context, name),
          &(&1["t"] == "providerAuth" and &1["id"] == id and &1["state"]["phase"] in phases),
          15_000
        )

      context
      |> World.put_client(name, client)
      |> Map.merge(%{auth: frame["state"], auth_seen: frame["state"]})
    end
  end

  defp current_auth(context) do
    {_name, instance, _id} = context.auth_at
    [{server, _}] = Registry.lookup(HalC2.ProviderAuth.Registry, instance)
    :sys.get_state(server).auth
  end

  # Google's final redirect for this sign-in, with `params`.
  defp callback(flow, params),
    do: flow.redirect <> "?" <> URI.encode_query(Map.put(params, "state", flow.state))

  # The browser following Google's redirect to the agent's loopback listener.
  defp browser(flow, params) do
    {:ok, {{_, 200, _}, _headers, body}} =
      :httpc.request(
        :get,
        {String.to_charlist(callback(flow, params)), []},
        [timeout: 10_000],
        []
      )

    to_string(body)
  end

  # Pastes Google's return address in the client that started the sign-in.
  defp paste(context, url) do
    {name, instance, _} = context.auth_at

    {reply, context} =
      World.call(
        context,
        "provider.auth.complete",
        %{"instanceId" => instance, "flowId" => context.flow.id, "callbackUrl" => url},
        name
      )

    Map.put(context, :reply, reply)
  end

  # The provider list, once it shows `instance` signed in.
  defp await_signed_in(context, instance) do
    {providers, _} =
      FakeAcp.await_providers(
        Map.drop(context, [:config_sub]),
        &match?(
          %{"auth" => %{"status" => "authenticated"}, "status" => "ready"},
          FakeAcp.find(&1, instance)
        )
      )

    FakeAcp.find(providers, instance)
  end
end
