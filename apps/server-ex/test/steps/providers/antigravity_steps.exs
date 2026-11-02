defmodule HalC2.Steps.Providers.Antigravity do
  @moduledoc """
  Steps for `features/providers/antigravity.feature`. Google's runtime is played by
  the scripted fake (`HalC2.Test.FakeAcp` with `googleAuth`, see
  `test/support/fake_google_auth.py`): the release the MC downloads is a zip of
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
  alias HalC2.Test.{FakeAcp, Mc}
  alias HalC2.Test.Mc.World

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

    Mc.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.ProviderAuth.Registry},
        id: :provider_auth_registry
      )
    )

    Mc.ensure(
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
    client = Mc.connect(context.mc)
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
             (context[:install_error] ||
                "The Antigravity download failed its size or SHA-256 check. Nothing was installed.")

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

  step "an Antigravity instance's binary path is inside the downloaded runtime", context do
    {:ok, %{executable: exe}} = Antigravity.resolve(nil)
    FakeAcp.settings(&put_in(&1, ["providers", @instance, "binaryPath"], exe))
    context
  end

  step "the removal is refused asking the user to clear that path first", context do
    assert {:error, message, %{"operation" => "remove-install"}} = context.reply
    assert message =~ "Clear"
    assert {:ok, %{version: @old}} = Antigravity.resolve(nil)
    context
  end

  step "the environment has less free disk space than the Antigravity runtime needs",
       context do
    Application.put_env(:hal_c2, :antigravity_free_space, fn _dir -> 1024 end)
    test = self()

    Application.put_env(:hal_c2, :antigravity_fetch, fn _url, _dest, _progress ->
      send(test, :antigravity_downloaded)
      {:error, "should not download"}
    end)

    context
  end

  step "the installation fails naming the free space it needs in megabytes", context do
    assert %{"phase" => "failed", "message" => message} = List.last(context.install_states)
    assert message =~ ~r/^Antigravity needs at least \d+ MiB of free space to install\.$/
    context
  end

  step "nothing is downloaded", context do
    refute_received :antigravity_downloaded
    previous_unchanged(context)
  end

  step "the downloaded runtime matches its checksum but holds more than the executable and its helper",
       context do
    dir = Mc.tmp_dir(context.mc, "agy-extra")
    File.cp!(FakeAcp.fake(context, @instance).bin, Path.join(dir, "agy_acp_server.par"))
    File.write!(Path.join(dir, "localharness_external"), "#!/bin/sh\nexit 0\n")
    File.write!(Path.join(dir, "README.txt"), "extra\n")
    archive = Path.join(Mc.tmp_dir(context.mc, "agy-extra-archive"), "runtime.zip")

    {:ok, _} =
      :zip.create(
        String.to_charlist(archive),
        [~c"agy_acp_server.par", ~c"localharness_external", ~c"README.txt"],
        cwd: String.to_charlist(dir)
      )

    data = File.read!(archive)

    release = %{
      context.release
      | sha256: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower),
        archive_bytes: byte_size(data)
    }

    Application.put_env(:hal_c2, :antigravity_release, release)
    context = context |> Map.put(:release, release) |> Map.put(:archive, archive)
    fetch(context, :copy)

    Map.put(
      context,
      :install_error,
      "The archive must contain exactly the Antigravity executable and its harness."
    )
  end

  step "the installation extracts the download", context do
    context = context |> installer() |> watch_install()
    {_, context} = World.call!(context, "provider.install.start", %{"instanceId" => @instance})
    {states, context} = collect_install(context, &(&1["phase"] in ~w(succeeded failed)))
    Map.put(context, :install_states, states)
  end

  step "the downloaded runtime of this release is already stored on the environment",
       context do
    id = context.release.sha256
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
        "version" => @version,
        "executable" => %{"name" => "agy_acp_server.par", "bytes" => File.stat!(exe).size},
        "harness" => %{"name" => "localharness_external", "bytes" => File.stat!(harness).size}
      })
    )

    test = self()

    Application.put_env(:hal_c2, :antigravity_fetch, fn _url, _dest, _progress ->
      send(test, :antigravity_downloaded)
      {:error, "should not download"}
    end)

    context
  end

  step "the stored runtime is checked and activated without downloading it again", context do
    refute_received :antigravity_downloaded
    phases = context.install_states |> Enum.map(& &1["phase"]) |> Enum.dedup()
    assert "verifying" in phases

    assert %{"phase" => "succeeded", "installedVersion" => @version} =
             List.last(context.install_states)

    assert {:ok, %{source: "managed", version: @version}} = Antigravity.resolve(nil)
    context
  end

  step "the downloaded Antigravity runtime is missing files the MC recorded", context do
    {:ok, %{harness: harness}} = Antigravity.resolve(nil)
    File.rm!(harness)
    context
  end

  step "the user is told the managed runtime is incomplete", context do
    # A starting MC reads its install state from disk (`Installation.init/1`).
    if pid = GenServer.whereis(Installation), do: GenServer.stop(pid)
    context = installer(context)
    assert %{"phase" => "failed", "message" => message} = Installation.state()
    Map.put(context, :install_message, message)
  end

  step "is told to remove it and install again", context do
    assert context.install_message ==
             "The managed Antigravity runtime is incomplete. Remove it and reinstall."

    context
  end

  step "an Antigravity installation finished after the client last refreshed", context do
    context = context |> installer() |> watch_install()
    {_, context} = World.call!(context, "provider.install.start", %{"instanceId" => @instance})
    {states, context} = collect_install(context, &(&1["phase"] in ~w(succeeded failed)))
    assert %{"phase" => "succeeded", "operationId" => op} = List.last(states)
    Map.put(context, :finished_op, op)
  end

  step "the client cancels that earlier installation", context do
    {reply, context} =
      World.call(context, "provider.install.cancel", %{
        "instanceId" => @instance,
        "operationId" => context.finished_op
      })

    Map.put(context, :reply, reply)
  end

  step "the user is told to refresh the installation status before cancelling", context do
    assert {:error, message, %{"operation" => "cancel-install"}} = context.reply

    assert message ==
             "This installation is no longer current. Refresh its status before cancelling."

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

  # --- health ---------------------------------------------------------------------

  step "Antigravity is turned off in the provider settings", context do
    FakeAcp.settings(&put_in(&1, ["providers", @instance], %{"enabled" => false}))
    context
  end

  step "the MC is still checking Antigravity", context do
    :persistent_term.erase({HalC2.Acp, @instance, :models})
    :persistent_term.erase({HalC2.Acp, @instance, :error})
    :persistent_term.put({HalC2.Acp, @instance, :loading}, true)
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({HalC2.Acp, @instance, :loading}) end)
    context
  end

  step "no Antigravity runtime is installed", context do
    File.rm_rf!(Antigravity.managed_dir())
    context
  end

  step "the runtime starts but fails its local health check", context do
    FakeAcp.configure(
      context,
      &Map.put(&1, "initError", %{"code" => -32603, "message" => "boom"})
    )

    FakeAcp.probe(@instance)
    context
  end

  step "the runtime does not answer its health check within 90 seconds", context do
    Application.put_env(:hal_c2, :antigravity_health_timeout_ms, 200)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:hal_c2, :antigravity_health_timeout_ms)
    end)

    FakeAcp.configure(context, &Map.put(&1, "hangMethods", ["initialize"]))
    FakeAcp.probe(@instance)
    context
  end

  step "the runtime is installed and the user has not signed in", context do
    assert {:ok, %{source: "managed"}} = Antigravity.resolve(nil)
    Antigravity.drop_account(@instance)
    context
  end

  step "the runtime is installed and the sign-in has not been checked", context do
    assert {:ok, %{source: "managed"}} = Antigravity.resolve(nil)
    FakeAcp.probe(@instance)
    context
  end

  step "Antigravity is shown with the message {string}", %{args: [message]} = context do
    entry = FakeAcp.find(context.providers, @instance)
    assert entry["message"] == message, "got #{inspect(entry["message"])}"
    context
  end

  step "the MC checks provider status at startup", context do
    HalC2.Acp.forget(@instance)
    context = Map.put(context, :starts_before, length(FakeAcp.starts(context)))
    HalC2.Acp.load()
    context
  end

  step "the runtime is not launched and no Google request is made", context do
    assert length(FakeAcp.starts(context)) == context.starts_before
    context
  end

  step "account access is reported as not checked yet", context do
    entry = FakeAcp.entry(@instance)

    assert entry["message"] ==
             "Antigravity is installed. Google account access is not checked yet."

    assert entry["auth"]["status"] == "unknown"
    context
  end

  # --- model refresh, setup and temporary files -------------------------------------

  step "Antigravity lists the models it loaded earlier", context do
    context = signed_in(context)
    assert [%{"slug" => "fake/one"}] = Antigravity.account(@instance)["models"]
    context
  end

  step ~r/^the user refreshes the Antigravity models and (?<problem>.+)$/,
       %{args: [problem]} = context do
    case problem do
      "the runtime does not answer in 90 seconds" ->
        Application.put_env(:hal_c2, :antigravity_model_refresh_timeout_ms, 300)

        ExUnit.Callbacks.on_exit(fn ->
          Application.delete_env(:hal_c2, :antigravity_model_refresh_timeout_ms)
        end)

        FakeAcp.configure(context, &Map.put(&1, "hangMethods", ["session/new"]))

      "the instance is not signed in" ->
        File.rm!(Antigravity.token_path(@instance))

      "the refresh fails for another reason" ->
        FakeAcp.configure(
          context,
          &Map.put(&1, "sessionError", %{"code" => -32603, "message" => "no session"})
        )
    end

    {reply, context} =
      World.call(context, "server.refreshProviders", %{
        "instanceId" => @instance,
        "refreshModels" => true
      })

    Map.put(context, :reply, reply)
  end

  step "the earlier models are still listed", context do
    assert [%{"slug" => "fake/one"}] = Antigravity.account(@instance)["models"]
    entry = FakeAcp.entry(@instance)
    assert [%{"slug" => "fake/one"}] = entry["models"]
    context
  end

  step "Node.js cannot be found on the machine running the MC", context do
    Application.put_env(:hal_c2, :antigravity_node, false)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :antigravity_node) end)
    Map.put(context, :setup_via, :turn)
  end

  step "an Antigravity session is prepared", context do
    prepare_runtime(context)
  end

  step "the instance's temporary folder cannot be created", context do
    tmp = HalC2.Acp.Antigravity.SessionFiles.temp_dir(Antigravity.profile(@instance))
    File.mkdir_p!(Path.dirname(tmp))
    File.write!(tmp, "not a folder\n")
    Map.put(context, :setup_via, :turn)
  end

  step "the folder used to check the instance cannot be created", context do
    context = signed_in(context)
    blocker = Path.join(Mc.tmp_dir(context.mc, "setup-blocker"), "file")
    File.write!(blocker, "not a folder\n")
    Application.put_env(:hal_c2, :antigravity_setup_dir, Path.join(blocker, "setup"))
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :antigravity_setup_dir) end)
    Map.put(context, :setup_via, :refresh)
  end

  step "the instance's status cannot be prepared for another reason", context do
    settings = Path.join([Antigravity.profile(@instance), "antigravity-acp", "settings.json"])
    File.mkdir_p!(settings)
    Map.put(context, :setup_via, :turn)
  end

  step "the MC prepares an Antigravity runtime for the instance", context do
    prepare_runtime(context)
  end

  step "the Antigravity runtime cannot be set up for the instance", context do
    context = signed_in(context)
    settings = Path.join([Antigravity.profile(@instance), "antigravity-acp", "settings.json"])
    File.mkdir_p!(settings)
    context
  end

  step "the turn fails with the setup problem's own explanation", context do
    state = FakeAcp.await_run(context, "failed")
    assert last_error(state) =~ "Could not prepare the Antigravity provider status."
    context
  end

  @session_uuid "123e4567-e89b-42d3-a456-426614174000"

  step "an Antigravity session created temporary runtime and session files", context do
    FakeAcp.configure(context, &Map.put(&1, "sessionId", @session_uuid))
    context = start_sign_in(context)

    %{"env" => %{"TMPDIR" => tmp}} = List.last(FakeAcp.starts(context))
    assert File.dir?(tmp)
    File.write!(Path.join(tmp, "unpacked.bin"), "runtime\n")

    profile = Antigravity.profile(@instance)
    conversations = Path.join([profile, "antigravity-acp", "conversations"])
    File.mkdir_p!(conversations)
    File.write!(Path.join(conversations, @session_uuid <> ".db"), "db\n")
    cwd = Path.join(profile, "sign-in")
    File.write!(Path.join(conversations, @session_uuid <> ".meta"), JSON.encode!(%{"cwd" => cwd}))
    brain = Path.join([profile, "antigravity-acp", "brain", @session_uuid])
    File.mkdir_p!(brain)
    File.write!(Path.join(brain, "note.txt"), "note\n")

    stale = Path.join(HalC2.Acp.Antigravity.SessionFiles.temp_dir(profile), "run-stale")
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "left.bin"), "left\n")

    Map.merge(context, %{session_tmp: tmp, stale_tmp: stale, conversations: conversations})
  end

  step "the session ends", context do
    assert browser(context.flow, %{"code" => "google-code"}) =~ "Sign-in succeeded"
    await_auth(context, "succeeded")
  end

  step "those files are removed", context do
    refute File.exists?(Path.join(context.conversations, @session_uuid <> ".db"))
    refute File.exists?(Path.join(context.conversations, @session_uuid <> ".meta"))
    refute File.exists?(context.session_tmp)
    context
  end

  step "files left behind by an MC that was killed are removed the next time Antigravity starts",
       context do
    assert File.exists?(context.stale_tmp)
    context = context |> FakeAcp.thread("Work") |> FakeAcp.send_message("hello")
    FakeAcp.await_run(context, "completed")
    refute File.exists?(context.stale_tmp)
    context
  end

  step "a temporary Antigravity session ended", context do
    FakeAcp.configure(context, &Map.put(&1, "sessionId", @session_uuid))
    context = start_sign_in(context)

    profile = Antigravity.profile(@instance)
    conversations = Path.join([profile, "antigravity-acp", "conversations"])
    File.mkdir_p!(conversations)
    File.write!(Path.join(conversations, @session_uuid <> ".db"), "db\n")
    brain = Path.join([profile, "antigravity-acp", "brain", @session_uuid])
    File.mkdir_p!(brain)
    File.write!(Path.join(brain, "note.txt"), "note\n")

    Map.merge(context, %{conversations: conversations, brain: brain, profile_dir: profile})
  end

  step "the conversation stored under its id was recorded for a different folder than the temporary one",
       context do
    File.write!(
      Path.join(context.conversations, @session_uuid <> ".meta"),
      JSON.encode!(%{"cwd" => "/someone/elses/project"})
    )

    assert browser(context.flow, %{"code" => "google-code"}) =~ "Sign-in succeeded"
    await_auth(context, "succeeded")
  end

  step "that conversation's files are not removed", context do
    assert File.exists?(Path.join(context.conversations, @session_uuid <> ".db"))
    assert File.exists?(Path.join(context.brain, "note.txt"))
    context
  end

  step "a failure to remove temporary files is logged without failing the session", context do
    # An owned conversation whose database cannot be removed (a folder where
    # the file should be): removal is logged and still returns fine.
    db = Path.join(context.conversations, @session_uuid <> ".db")
    File.rm!(db)
    File.mkdir_p!(Path.join(db, "inner"))

    File.write!(
      Path.join(context.conversations, @session_uuid <> ".meta"),
      JSON.encode!(%{"cwd" => Path.join(context.profile_dir, "sign-in")})
    )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 HalC2.Acp.Antigravity.SessionFiles.remove_session_files(
                   context.profile_dir,
                   @session_uuid,
                   Path.join(context.profile_dir, "sign-in")
                 )
      end)

    assert log =~ "Could not remove temporary Antigravity session files."
    assert context.auth["phase"] == "succeeded"
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

  step "the Antigravity runtime is an older release that prints its sign-in link on standard output",
       context do
    assert {:ok, %{source: "managed"}} = Antigravity.resolve(nil)
    FakeAcp.configure(context, &Map.put(&1, "authOnStdout", true))
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
    |> World.put_client("phone", Mc.connect(context.mc))
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
    HalC2.Test.Mc.Terminal.put_env("GEMINI_API_KEY", "ambient-key")
    HalC2.Test.Mc.Terminal.put_env("GOOGLE_CLOUD_PROJECT", "ambient-project")
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

    # The Background's own instance is enabled too, and may have started.
    homes =
      for %{"argv" => _, "env" => env} <- FakeAcp.starts(context),
          env["ANTIGRAVITY_HARNESS_PATH"] == Path.join(Path.dirname(exe), "localharness_external"),
          env["GEMINI_HOME"] != Antigravity.profile(@instance),
          uniq: true,
          do: env["GEMINI_HOME"]

    assert Enum.sort(homes) == Enum.sort(Enum.map(context.pair, &Antigravity.profile/1))
    context
  end

  step "Antigravity still shows the saved account", context do
    # A restarted MC has read nothing from the agent yet.
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
    dir = Path.join(context.mc.home, "attachments")
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
    HalC2.Test.Mc.Host.home(context)
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
    open_skills(context)
  end

  step "the MC reads the Antigravity skills", context do
    open_skills(context)
  end

  defp open_skills(context) do
    context = FakeAcp.thread(context, "Work")

    {reply, context} =
      World.call(context, "server.refreshProviders", %{
        "instanceId" => @instance,
        "cwd" => World.project(context).root
      })

    context = Map.put(context, :reply, reply)

    case reply do
      {:ok, result} -> Map.put(context, :providers, result["providers"])
      _ -> context
    end
  end

  defp listed_skills(context) do
    root = World.project(context).root

    entry =
      FakeAcp.find(context[:providers] || [], @instance) || FakeAcp.entry(@instance) || %{}

    case Enum.filter(entry["workspaceSnapshots"] || [], &(&1["cwd"] == root)) do
      [%{"skills" => skills}] -> skills
      _ -> []
    end
  end

  # A skill folder as a scenario names it.
  defp skill_folder(context, folder) do
    home = HalC2.Test.Mc.Host.home(context)
    root = World.project(context).root

    case folder do
      "the user's .gemini/config/skills" ->
        Path.join([home, ".gemini", "config", "skills"])

      "the user's .gemini/antigravity-cli/skills" ->
        Path.join([home, ".gemini", "antigravity-cli", "skills"])

      "the user's .agents/skills" ->
        Path.join([home, ".agents", "skills"])

      "the project's .gemini/skills" ->
        Path.join([root, ".gemini", "skills"])

      "the project's .agents/skills" ->
        Path.join([root, ".agents", "skills"])

      "the project's .agent/skills" ->
        Path.join([root, ".agent", "skills"])

      other ->
        flunk("unknown skill folder #{inspect(other)}")
    end
  end

  defp write_skill(dir, name, body \\ nil) do
    skill = Path.join(dir, name)
    File.mkdir_p!(skill)

    File.write!(
      Path.join(skill, "SKILL.md"),
      body ||
        """
        ---
        name: #{name}
        description: Deploy from #{dir}
        ---
        Ship it.
        """
    )

    skill
  end

  step ~r/^a skill "(?<name>[^"]+)" in (?<folder>.+)$/, %{args: [name, folder]} = context do
    write_skill(skill_folder(context, folder), name)
    context
  end

  step ~r/^a skill "(?<name>[^"]+)" exists in (?<first>.+) and in (?<second>.+)$/,
       %{args: [name, first, second]} = context do
    write_skill(skill_folder(context, first), name)
    write_skill(skill_folder(context, second), name)
    context
  end

  step ~r/^"(?<name>[a-z0-9_-]+)" is offered$/, %{args: [name]} = context do
    assert Enum.any?(listed_skills(context), &(&1["name"] == name)),
           "#{name} not in #{inspect(Enum.map(listed_skills(context), & &1["name"]))}"

    context
  end

  step ~r/^"(?<name>[a-z0-9_-]+)" is not offered$/, %{args: [name]} = context do
    refute Enum.any?(listed_skills(context), &(&1["name"] == name))
    context
  end

  step "the skill is offered as {string}", %{args: [name]} = context do
    assert [%{"name" => ^name}] = listed_skills(context)
    context
  end

  step "the skill of that folder is offered", context do
    assert [%{"name" => "deploy"}] = listed_skills(context)
    context
  end

  step "only the skill of the skill folder itself is offered", context do
    assert [%{"name" => "rootskill"}] = listed_skills(context)
    context
  end

  step "that skill is not offered", context do
    refute Enum.any?(listed_skills(context), &String.contains?(&1["path"], "broken"))
    context
  end

  step "the other skills are still offered", context do
    assert Enum.any?(listed_skills(context), &(&1["name"] == "deploy"))
    context
  end

  step "no partial skill list is offered", context do
    assert listed_skills(context) == []
    context
  end

  step "reading fails naming the path where the scan limit was exceeded", context do
    assert {:error, _message, %{"cause" => cause}} = context.reply
    assert cause =~ "Antigravity skill discovery exceeded its scan limit at '"
    assert cause =~ World.project(context).root
    context
  end

  step "reading fails with {string}", %{args: [message]} = context do
    assert {:error, _message, %{"cause" => cause}} = context.reply
    assert cause == wtext(context, message)
    context
  end

  step "the list fails with {string}", %{args: [message]} = context do
    assert {:error, error, _detail} = context.reply
    assert error == message
    context
  end

  step "the reason names {string}", %{args: [message]} = context do
    assert {:error, _message, %{"cause" => cause}} = context.reply
    assert cause == wtext(context, message)
    context
  end

  step "a skill folder that does not exist is simply skipped", context do
    folder = Path.join(World.project(context).root, ".agents/skills")
    File.chmod!(folder, 0o755)
    File.rm_rf!(folder)
    context = open_skills(context)
    assert {:ok, _} = context.reply
    context
  end

  step "the project has a skill folder {string} whose skill file states no name",
       %{args: [name]} = context do
    HalC2.Test.Mc.Host.home(context)
    dir = Path.join([World.project(context).root, ".agents/skills"])

    write_skill(dir, name, """
    ---
    description: Deploy things
    ---
    Ship it.
    """)

    context
  end

  step "the project has a skill folder {string} whose skill file is named {string}",
       %{args: [name, file]} = context do
    HalC2.Test.Mc.Host.home(context)
    skill = Path.join([World.project(context).root, ".agents/skills", name])
    File.mkdir_p!(skill)

    File.write!(
      Path.join(skill, file),
      "---\nname: #{name}\ndescription: Deploy\n---\nShip it.\n"
    )

    context
  end

  step ~r/^the project has a skill folder whose skill file (?<problem>.+)$/,
       %{args: [problem]} = context do
    HalC2.Test.Mc.Host.home(context)
    dir = Path.join([World.project(context).root, ".agents/skills"])
    write_skill(dir, "deploy")

    body =
      case problem do
        "has no header block" ->
          "Just text, no header.\n"

        "has a header that is not valid" ->
          "---\nname: [broken]\n---\nShip it.\n"

        "gives a name with a space before or after it" ->
          "---\nname: \" broken\"\n---\nShip it.\n"
      end

    write_skill(dir, "broken", body)
    context
  end

  step "the project's {string} holds the skill {string} in {string} and the skill {string} in {string}",
       %{args: [folder, first, first_at, second, second_at]} = context do
    HalC2.Test.Mc.Host.home(context)
    base = Path.join(World.project(context).root, folder)

    for {name, at} <- [{first, first_at}, {second, second_at}] do
      skill = Path.join(base, at)
      File.mkdir_p!(skill)

      File.write!(
        Path.join(skill, "SKILL.md"),
        "---\nname: #{name}\ndescription: Deploy\n---\nShip it.\n"
      )
    end

    context
  end

  step "the project's {string} holds a skill file of its own and further skills in folders below it",
       %{args: [folder]} = context do
    HalC2.Test.Mc.Host.home(context)
    base = Path.join(World.project(context).root, folder)
    File.mkdir_p!(base)

    File.write!(
      Path.join(base, "SKILL.md"),
      "---\nname: rootskill\ndescription: Root\n---\nShip it.\n"
    )

    write_skill(base, "deploy")
    context
  end

  step "the project's skill folders hold more than 10,000 entries, or more than 8 MB of skill files",
       context do
    HalC2.Test.Mc.Host.home(context)
    dir = Path.join([World.project(context).root, ".agents/skills"])
    File.mkdir_p!(dir)
    for n <- 1..10_001, do: File.touch!(Path.join(dir, "entry-#{n}"))
    context
  end

  step "the project has a skill file larger than 1 MB at {string}", %{args: [path]} = context do
    HalC2.Test.Mc.Host.home(context)
    real = wpath(context, path)
    File.mkdir_p!(Path.dirname(real))
    File.write!(real, :binary.copy("a", 1_000_001))
    context
  end

  step "the MC is not allowed to read the project's skill folder {string}",
       %{args: [path]} = context do
    HalC2.Test.Mc.Host.home(context)
    real = wpath(context, path)
    File.mkdir_p!(real)
    File.chmod!(real, 0o000)
    ExUnit.Callbacks.on_exit(fn -> File.chmod(real, 0o755) end)
    context
  end

  step ~r/^"(?<name>[^"]+)" is offered once, from (?<dir>.+)$/, %{args: [name, dir]} = context do
    root = World.project(context).root
    skills = listed_skills(context)
    assert [skill] = Enum.filter(skills, &(&1["name"] == name))

    {expected_path, expected_description} =
      if String.starts_with?(dir, ".") do
        {Path.join([root, dir, name, "SKILL.md"]), "Deploy from gemini"}
      else
        folder = skill_folder(context, dir)
        {Path.join([folder, name, "SKILL.md"]), "Deploy from #{folder}"}
      end

    assert skill["path"] == expected_path
    assert skill["description"] == expected_description
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

  step "Antigravity ends a turn with a command still running", context do
    turn = %{
      "match" => "leave a command running",
      "steps" => [
        %{
          "update" => %{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "cmd-bg",
            "title" => "npm run dev",
            "kind" => "execute",
            "status" => "in_progress",
            "rawInput" => %{"command" => "npm run dev"}
          }
        },
        %{"text" => "Started it."}
      ]
    }

    FakeAcp.configure(context, &Map.update!(&1, "turns", fn turns -> [turn | turns] end))

    context =
      context
      |> signed_in()
      |> FakeAcp.thread("Work")
      |> FakeAcp.send_message("leave a command running")

    FakeAcp.await_run(context, "completed")
    context
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

  step "the saved Google login of the Antigravity instance expired", context do
    context = signed_in(context)
    File.rm!(Antigravity.token_path(@instance))
    context
  end

  step "the user sends a message in an Antigravity thread", context do
    context |> FakeAcp.thread("Work") |> FakeAcp.send_message("hello")
  end

  step "the turn fails asking the user to sign in from Settings", context do
    state = FakeAcp.await_run(context, "failed")
    assert last_error(state) =~ Antigravity.sign_in_required()
    assert FakeAcp.received(context, "session/prompt") == []
    context
  end

  step "the thread's Antigravity agent is stopped and the instance shows as signed out",
       context do
    assert %{conn: nil, session_id: nil} = :sys.get_state(runtime(context))
    assert Antigravity.sessions(@instance) == []
    assert Antigravity.account(@instance) == nil
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

  step "Antigravity answers that the quota resets in 4 hours, 26 minutes", context do
    quota_reply(
      context,
      "Usage Limit Reached\n\nYou have reached your current quota for this period. " <>
        "Your limit will reset in 4 hours, 26 minutes."
    )
  end

  step "Antigravity's answer talks about a usage limit among other text", context do
    quota_reply(
      context,
      "The error page says Usage Limit Reached. You have reached your current quota " <>
        "for this period, so the client should back off."
    )
  end

  step "the thread is limited until 4 hours and 26 minutes after the answer", context do
    state = FakeAcp.await_run(context, "failed")
    assert last_error(state) =~ "You have reached your current quota for this period."

    row =
      World.await_row(World.thread_id(context, "Work"), &(&1["lastErrorClass"] == "usage_limit"))

    {:ok, reset, _} = DateTime.from_iso8601(row["usageLimitResetAt"])
    expected = context.sent_at + (4 * 60 + 26) * 60_000
    assert_in_delta DateTime.to_unix(reset, :millisecond), expected, 60_000
    context
  end

  step "the turn completes", context do
    # A subagent batch held by its scenario is let finish first.
    if context[:batch_pending], do: release_file(context, "release-batch")
    Map.put(context, :run_state, FakeAcp.await_run(context, "completed"))
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
      |> World.put_client("mobile", Mc.connect(context.mc))
      |> start_sign_in(@instance, "mobile")

    # The phone cannot reach the environment's loopback address: it pastes the return.
    paste(context, callback(context.flow, %{"code" => "google-code"}))
  end

  # --- files ----------------------------------------------------------------------

  step "the project has a file whose kind Antigravity does not recognise", context do
    path = Path.join(World.project(context).root, "schema.xyzzy")
    File.write!(path, "table users\n")
    Map.put(context, :asked_path, path)
  end

  step "Antigravity asks for that file by its path", context do
    read_turn(context, context.asked_path)
  end

  step "Antigravity receives the file's contents", context do
    if context[:attached_path] do
      FakeAcp.await_run(context, "completed")
      assert [%{"result" => %{"content" => "attached text\n"}} | _] = FakeAcp.answers(context)
    else
      assert [%{"result" => %{"content" => "table users\n"}}] = FakeAcp.answers(context)
    end

    context
  end

  # A readable file beside the project's folder, so only its place refuses it.
  step "an Antigravity thread works in the project's folder", context do
    path = Path.join(Mc.tmp_dir(context.mc, "outside"), "secret.txt")
    File.write!(path, "secret\n")
    Map.put(context, :asked_path, path)
  end

  step "Antigravity asks for a path outside that folder", context do
    context = read_turn(context, context.asked_path)

    # A link inside the folder to that file leaves the folder just the same.
    link = Path.join(World.project(context).root, "link.txt")
    File.ln_s!(context.asked_path, link)
    turn = read_step("read the link", link)
    FakeAcp.configure(context, &Map.update!(&1, "turns", fn turns -> [turn | turns] end))
    context = FakeAcp.send_message(context, "read the link")
    FakeAcp.await_runs(context, 2)
    context
  end

  @doc false
  # `the request is refused` (common steps) for Antigravity's file request.
  def refused(context) do
    assert [%{"error" => %{"code" => -32002}}, %{"error" => %{"code" => -32002}}] =
             answers = FakeAcp.answers(context)

    refute inspect(answers) =~ "secret\\n"
    context
  end

  # --- workspace files --------------------------------------------------------------

  # A turn in which the agent makes the given client requests, in order.
  defp request_turn(context, requests, text \\ "work on files") do
    steps = Enum.map(requests, &%{"request" => &1})

    context
    |> script_turn(%{"match" => text, "steps" => steps})
    |> run_turn(text)
  end

  defp last_answer(context) do
    FakeAcp.await_run(context, "completed")
    List.last(FakeAcp.answers(context))
  end

  # The agent's refusal, in the scenario's own `/w` spelling of the workspace.
  defp refused_reply(context) do
    %{"error" => %{"message" => message}} = last_answer(context)
    {:error, String.replace(message, World.project(context).root, "/w"), %{}}
  end

  step ~r/^Antigravity asks for the workspace file "(?<name>[^"]+)" and (?<problem>.+)$/,
       %{args: [name, problem]} = context do
    root = World.project(context).root

    case problem do
      "the file does not exist" ->
        :ok

      "the file is not text or is larger than 8 MiB" ->
        path = Path.join(root, name)
        {:ok, file} = File.open(path, [:write, :binary])
        :file.pwrite(file, 9 * 1024 * 1024, "x")
        File.close(file)
    end

    context =
      request_turn(context, [%{"method" => "fs/read_text_file", "params" => %{"path" => name}}])

    Map.put(context, :reply, refused_reply(context))
  end

  step ~r/^Antigravity asks to (?<request>.+) and (?<problem>.+)$/,
       %{args: [request, problem]} = context do
    root = World.project(context).root
    [verb, quoted] = String.split(request, " ", parts: 2)
    wanted = quoted |> String.trim("\"") |> then(&wpath(context, &1))

    case {verb, problem} do
      {"read", "the file cannot be read"} ->
        File.write!(wanted, "secret\n")
        File.chmod!(wanted, 0o000)
        ExUnit.Callbacks.on_exit(fn -> File.chmod(wanted, 0o644) end)

      {"write", "the file cannot be written"} ->
        File.mkdir_p!(wanted)

      _ ->
        :ok
    end

    params =
      if verb == "read",
        do: %{"path" => wanted},
        else: %{"path" => wanted, "content" => "new\n"}

    context =
      request_turn(context, [%{"method" => "fs/#{verb}_text_file", "params" => params}])

    _ = root
    Map.put(context, :reply, refused_reply(context))
  end

  step "the workspace holds a link to a folder outside it", context do
    outside = Mc.tmp_dir(context.mc, "outside")
    File.write!(Path.join(outside, "secret.txt"), "outside\n")
    File.ln_s!(outside, Path.join(World.project(context).root, "link"))
    Map.put(context, :outside, outside)
  end

  step "Antigravity asks for a file through that link", context do
    root = World.project(context).root

    # Reading through the link, and writing two levels below it into folders
    # that do not exist yet: both leave the workspace.
    request_turn(context, [
      %{
        "method" => "fs/read_text_file",
        "params" => %{"path" => Path.join([root, "link", "secret.txt"])}
      },
      %{
        "method" => "fs/write_text_file",
        "params" => %{
          "path" => Path.join([root, "link", "newdir", "planted.txt"]),
          "content" => "planted\n"
        }
      }
    ])
  end

  step "the request is refused as outside the session workspace", context do
    for %{"error" => %{"message" => message}} <- answers(context) do
      assert message =~ "outside the session workspace."
    end

    assert length(FakeAcp.answers(context)) == 2
    refute File.exists?(Path.join([context.outside, "newdir", "planted.txt"]))
    context
  end

  step "the user attached a file to an Antigravity message", context do
    dir = HalC2.Attachments.dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, "att-note.txt")
    File.write!(path, "attached text\n")

    attachment = %{
      "type" => "file",
      "id" => "att-note",
      "name" => "note.txt",
      "mimeType" => "text/plain"
    }

    Map.merge(context, %{attached: attachment, attached_path: path})
  end

  step "Antigravity asks for that file at the path the message names", context do
    steps = [
      %{
        "request" => %{
          "method" => "fs/read_text_file",
          "params" => %{"path" => context.attached_path}
        }
      },
      %{
        "request" => %{
          "method" => "fs/read_text_file",
          "params" => %{"path" => "/etc/hosts"}
        }
      }
    ]

    context = script_turn(context, %{"match" => "read the note", "steps" => steps})
    context = signed_in(context) |> FakeAcp.thread("Work")
    dispatch_attachment(context, context.attached, "read the note")
  end

  step "a path outside both the workspace and HAL-C2's attachments is still refused", context do
    assert %{"error" => %{"message" => message}} = List.last(FakeAcp.answers(context))
    assert message == "Path '/etc/hosts' is outside the session workspace."
    context
  end

  step "Antigravity asks for a range of lines of a workspace file", context do
    root = World.project(context).root
    File.write!(Path.join(root, "lines.txt"), "one\ntwo\nthree\nfour\n")

    request_turn(context, [
      %{
        "method" => "fs/read_text_file",
        "params" => %{"path" => Path.join(root, "lines.txt"), "line" => 2, "limit" => 2}
      },
      %{
        "method" => "fs/write_text_file",
        "params" => %{
          "path" => Path.join([root, "new", "deep", "out.txt"]),
          "content" => "made\n"
        }
      }
    ])
  end

  step "it receives only those lines", context do
    assert [%{"result" => %{"content" => "two\nthree"}} | _] = answers(context)
    context
  end

  defp answers(context) do
    FakeAcp.await_run(context, "completed")
    FakeAcp.answers(context)
  end

  step "a workspace file it writes in a folder that does not exist yet is created with its folders",
       context do
    path = Path.join([World.project(context).root, "new", "deep", "out.txt"])
    assert File.read!(path) == "made\n"
    context
  end

  step "Antigravity is started for a chat thread", context do
    context = run_turn(context, "hello caps")
    FakeAcp.await_run(context, "completed")
    context
  end

  defp initialize_caps(context) do
    for %{"params" => %{"clientCapabilities" => caps}} <- FakeAcp.received(context, "initialize"),
        do: caps
  end

  step "it is told HAL-C2 reads and writes workspace files for it, and that HAL-C2 runs no terminals for it",
       context do
    assert Enum.any?(
             initialize_caps(context),
             &(&1["fs"] == %{"readTextFile" => true, "writeTextFile" => true} and
                 &1["terminal"] == false)
           )

    context
  end

  step "an Antigravity started for sign-in, a status check or text generation is told HAL-C2 does neither",
       context do
    before = length(FakeAcp.received(context, "initialize"))
    FakeAcp.probe(@instance)

    context =
      World.update_settings(context, %{
        "textGenerationModelSelection" => %{
          "instanceId" => @instance,
          "model" => "antigravity-default"
        }
      })

    HalC2.TextGeneration.thread_title(World.project(context).root, "Fix the parser")
    File.rm!(Antigravity.token_path(@instance))
    context = start_sign_in(context)

    started =
      FakeAcp.received(context, "initialize")
      |> Enum.drop(before)
      |> Enum.map(& &1["params"]["clientCapabilities"])

    assert length(started) >= 3

    assert Enum.all?(
             started,
             &(&1["fs"] == %{"readTextFile" => false, "writeTextFile" => false} and
                 &1["terminal"] == false)
           )

    context
  end

  # --- stopping ---------------------------------------------------------------------

  defp hang_turn(context) do
    context
    |> script_turn(%{"match" => "long task", "steps" => [%{"hang" => true}]})
    |> run_turn("long task")
  end

  # Waits until `fun` returns a truthy value, and returns it.
  defp wait_for(fun, attempts \\ 1_000) do
    case fun.() do
      nil -> retry_wait(fun, attempts)
      false -> retry_wait(fun, attempts)
      [] -> retry_wait(fun, attempts)
      value -> value
    end
  end

  defp retry_wait(_fun, 0), do: flunk("timed out waiting")

  defp retry_wait(fun, attempts) do
    Process.sleep(10)
    wait_for(fun, attempts - 1)
  end

  defp await_prompt(context) do
    assert [_ | _] = wait_for(fn -> FakeAcp.received(context, "session/prompt") end)
    context
  end

  defp prompts(context) do
    for %{"params" => params} <- FakeAcp.received(context, "session/prompt"), do: params
  end

  defp process_stopped?(context) do
    %{conn: nil} = :sys.get_state(runtime(context))
    %{"pid" => pid} = List.last(FakeAcp.starts(context))
    {_out, code} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    code != 0
  end

  step "the user interrupted an Antigravity turn", context do
    Application.put_env(:hal_c2, :antigravity_cancel_timeout_ms, 300)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:hal_c2, :antigravity_cancel_timeout_ms)
    end)

    context = context |> hang_turn() |> await_prompt()

    run =
      context
      |> World.runs(context.thread)
      |> Enum.find(&(&1["status"] in ~w(starting running waiting)))

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, context.thread),
        "runId" => run["id"]
      })

    context
  end

  step "Antigravity has not confirmed the stop after 15 seconds", context do
    state = FakeAcp.await_run(context, "failed")
    Map.put(context, :told, last_error(state))
  end

  step "its process is stopped", context do
    assert process_stopped?(context)
    context
  end

  step "an Antigravity turn is running", context do
    context |> hang_turn() |> await_prompt()
  end

  step "the turn is broken off without Antigravity confirming that it ended", context do
    Antigravity.stop_sessions(@instance)
    context
  end

  step "the Antigravity process is stopped", context do
    assert process_stopped?(context)
    context
  end

  step "the session reports {string}", %{args: [message]} = context do
    state = FakeAcp.await_run(context, "failed")
    assert last_error(state) == message
    context
  end

  # --- /compact and workers -----------------------------------------------------------

  step "an Antigravity thread with earlier turns", context do
    context = run_turn(context, "hello")
    FakeAcp.await_run(context, "completed")
    context
  end

  step ~r{^the user sends "/compact" with no attachments and the turn completes$}, context do
    context = FakeAcp.send_message(context, "/compact")
    FakeAcp.await_runs(context, 2)
    context
  end

  step "the work log shows \"Context compacted\" once", context do
    state = FakeAcp.await_run(context, "completed")

    compacted =
      Enum.filter(
        turn_items(state),
        &(&1["type"] == "compaction" and &1["title"] == "Context compacted")
      )

    assert length(compacted) == 1, inspect(turn_items(state))
    context
  end

  step "an Antigravity session is started", context do
    context = run_turn(context, "hello")
    FakeAcp.await_run(context, "completed")
    context
  end

  step "Antigravity starts as usual, because it has no switch for its subagents", context do
    assert [_ | _] = FakeAcp.received(context, "session/new")
    assert [%{"prompt" => [%{"type" => "text", "text" => text}]}] = prompts(context)
    refute text =~ "worker"
    context
  end

  # --- questions and approvals --------------------------------------------------------

  defp permission_params(call_id, title, options) do
    call = %{"toolCallId" => call_id, "status" => "pending"}
    call = if title, do: Map.put(call, "title", title), else: call
    %{"toolCall" => call, "options" => options}
  end

  defp question_turn(context, params, text \\ "choose please") do
    steps = [%{"request" => %{"method" => "session/request_permission", "params" => params}}]

    context
    |> script_turn(%{"match" => text, "steps" => steps})
    |> run_turn(text)
  end

  defp pending_item(context, kind) do
    request = FakeAcp.await_request(context)

    state =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        case Enum.find(turn_items(state), &(&1["type"] == kind)) do
          nil -> nil
          item -> {state, item}
        end
      end)

    {request, elem(state, 1)}
  end

  defp answer_question(context, request_id, answers) do
    HalC2.Orchestration.dispatch(%{
      "type" => "runtime-request.respond",
      "threadId" => World.thread_id(context, context.thread),
      "requestId" => request_id,
      "answers" => answers
    })
  end

  defp dismiss_question(context, request_id) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.user-input.dismiss",
        "threadId" => World.thread_id(context, context.thread),
        "requestId" => request_id
      })

    context
  end

  step "Antigravity asks the user to choose between options", context do
    options = [
      %{"optionId" => "opt-red", "name" => "Red", "kind" => "allow_once"},
      %{"optionId" => "opt-blue", "name" => "Blue", "kind" => "allow_once"}
    ]

    context = question_turn(context, permission_params("interaction_1", "Pick a color?", options))
    {request, item} = pending_item(context, "user_input_request")
    assert [%{"question" => "Pick a color?"}] = item["questions"]
    context = dismiss_question(context, request["id"])
    FakeAcp.await_run(context, "completed")

    context =
      question_turn(context, permission_params("interaction_2", nil, options), "choose again")

    {request, item} = pending_item(context, "user_input_request")
    Map.merge(context, %{question_request: request, question_item: item})
  end

  step "the user is shown the question, or \"Choose an option.\" when Antigravity gave none",
       context do
    assert [%{"question" => "Choose an option.", "id" => "interaction_2"}] =
             context.question_item["questions"]

    context
  end

  step "can pick exactly one of the options and cannot type a different answer", context do
    assert [%{"multiSelect" => false, "allowCustomAnswer" => false, "options" => options}] =
             context.question_item["questions"]

    assert Enum.map(options, & &1["label"]) == ["Red", "Blue"]
    context
  end

  step "an answer that matches no single option leaves the question open", context do
    request = context.question_request
    assert {:error, _} = answer_question(context, request["id"], %{"interaction_2" => "Green"})
    assert FakeAcp.await_request(context)["id"] == request["id"]
    context = dismiss_question(context, request["id"])
    FakeAcp.await_run(context, "completed")
    context
  end

  step "Antigravity asks for approval and offers only to allow once or to reject", context do
    options = [
      %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
      %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
    ]

    context = question_turn(context, permission_params("call-1", "Run this command?", options))
    {request, item} = pending_item(context, "approval_request")
    Map.merge(context, %{approval_request: request, approval_item: item})
  end

  step "Antigravity asks for approval and marks its allow-always choice with a security warning",
       context do
    warning = String.duplicate("Careful with this lasting approval. ", 20)

    options = [
      %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
      %{
        "optionId" => "always",
        "name" => "Always allow",
        "kind" => "allow_always",
        "_meta" => %{"agy.security.warning" => %{"title" => "Warning", "message" => warning}}
      },
      %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
    ]

    context = question_turn(context, permission_params("call-1", "Run this command?", options))
    {request, item} = pending_item(context, "approval_request")
    Map.merge(context, %{approval_request: request, approval_item: item, warning: warning})
  end

  step "the user sees the request", context do
    assert context.approval_item["type"] == "approval_request"
    context
  end

  step "\"Allow once\", \"Deny\" and \"Cancel\" are offered", context do
    labels = Enum.map(context.approval_item["options"], & &1["label"])
    assert labels == ["Allow once", "Deny", "Cancel"]
    context
  end

  step "\"Allow for this thread\" is not", context do
    labels = Enum.map(context.approval_item["options"], & &1["label"])
    refute "Allow for this thread" in labels
    FakeAcp.respond(context, context.approval_request["id"], %{"decision" => "cancel"})
    FakeAcp.await_run(context, "completed")
    context
  end

  step "\"Allow for this thread\" carries that warning", context do
    choice =
      Enum.find(context.approval_item["options"], &(&1["label"] == "Allow for this thread"))

    assert choice["warning"] =~ "Careful with this lasting approval."
    Map.put(context, :shown_warning, choice["warning"])
  end

  step "a warning longer than 512 characters is cut and ends with \"...\"", context do
    assert String.length(context.warning) > 512
    assert String.length(context.shown_warning) == 512
    assert String.ends_with?(context.shown_warning, "...")
    FakeAcp.respond(context, context.approval_request["id"], %{"decision" => "cancel"})
    FakeAcp.await_run(context, "completed")
    context
  end

  step ~r/^Antigravity asks a question with the options (?<options>.+)$/,
       %{args: [described]} = context do
    options =
      case described do
        ~s("Yes" and "No") ->
          [
            %{"optionId" => "opt-yes", "name" => "Yes", "kind" => "allow_once"},
            %{"optionId" => "opt-no", "name" => "No", "kind" => "allow_once"}
          ]

        ~s(two options both labelled "Continue") ->
          [
            %{"optionId" => "opt-a", "name" => "Continue", "kind" => "allow_once"},
            %{"optionId" => "opt-b", "name" => "Continue", "kind" => "allow_once"}
          ]
      end

    context = question_turn(context, permission_params("interaction_q", "Shall we?", options))
    {request, _item} = pending_item(context, "user_input_request")
    Map.put(context, :question_request, request)
  end

  step "a client answers {string}", %{args: [answer]} = context do
    result =
      answer_question(context, context.question_request["id"], %{"interaction_q" => answer})

    Map.put(context, :answer_result, result)
  end

  step "Antigravity is told \"Yes\"", context do
    assert {:ok, _} = context.answer_result
    FakeAcp.await_run(context, "completed")

    assert %{"result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "opt-yes"}}} =
             List.last(FakeAcp.answers(context))

    context
  end

  step "the question stays open", context do
    assert {:error, _} = context.answer_result
    assert FakeAcp.await_request(context)["id"] == context.question_request["id"]
    context = dismiss_question(context, context.question_request["id"])
    FakeAcp.await_run(context, "completed")
    context
  end

  step "Antigravity asks a question and one of its options declines", context do
    options = [
      %{"optionId" => "opt-go", "name" => "Proceed", "kind" => "allow_once"},
      %{"optionId" => "opt-decline", "name" => "No thanks", "kind" => "reject_once"}
    ]

    context = question_turn(context, permission_params("interaction_d", "Proceed?", options))
    {request, _item} = pending_item(context, "user_input_request")
    Map.put(context, :question_request, request)
  end

  step "the user picks that option", context do
    assert {:ok, _} =
             answer_question(context, context.question_request["id"], %{
               "interaction_d" => "opt-decline"
             })

    FakeAcp.await_run(context, "completed")
    context
  end

  step "Antigravity is told which option was picked", context do
    assert %{"result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "opt-decline"}}} =
             List.last(FakeAcp.answers(context))

    context
  end

  step "only cancelling the question tells Antigravity it was cancelled", context do
    options = [%{"optionId" => "opt-go", "name" => "Proceed", "kind" => "allow_once"}]

    context =
      question_turn(
        context,
        permission_params("interaction_e", "Proceed?", options),
        "choose more"
      )

    {request, _item} = pending_item(context, "user_input_request")
    context = dismiss_question(context, request["id"])
    FakeAcp.await_run(context, "completed")

    assert %{"result" => %{"outcome" => %{"outcome" => "cancelled"}}} =
             List.last(FakeAcp.answers(context))

    context
  end

  step "Antigravity asks a question whose options share an id or have none", context do
    options = [
      %{"optionId" => "same", "name" => "One", "kind" => "allow_once"},
      %{"optionId" => "same", "name" => "Two", "kind" => "allow_once"}
    ]

    context = question_turn(context, permission_params("interaction_x", "Which?", options))
    Map.put(context, :run_state, FakeAcp.await_run(context, "completed"))
  end

  step "the user is not shown a question to pick from", context do
    refute Enum.any?(turn_items(context.run_state), &(&1["type"] == "user_input_request"))
    assert HalC2.StreamState.list(context.run_state, "runtime-request") == []

    assert %{"result" => %{"outcome" => %{"outcome" => "cancelled"}}} =
             List.last(FakeAcp.answers(context))

    context
  end

  step "Antigravity asks a question longer than 8,000 characters with an option label longer than 512",
       context do
    options = [
      %{
        "optionId" => "opt-long",
        "name" => String.duplicate("L", 600),
        "kind" => "allow_once"
      }
    ]

    context =
      question_turn(
        context,
        permission_params("interaction_long", String.duplicate("q", 9_000), options)
      )

    {request, item} = pending_item(context, "user_input_request")
    Map.merge(context, %{question_request: request, question_item: item})
  end

  step "the question and the label are cut and end with \"...\"", context do
    assert [%{"question" => question, "options" => [%{"label" => label}]}] =
             context.question_item["questions"]

    assert String.length(question) == 8_000 and String.ends_with?(question, "...")
    assert String.length(label) == 512 and String.ends_with?(label, "...")
    Map.put(context, :shown_label, label)
  end

  step "picking the option still tells Antigravity the option's own id", context do
    assert {:ok, _} =
             answer_question(context, context.question_request["id"], %{
               "interaction_long" => context.shown_label
             })

    FakeAcp.await_run(context, "completed")

    assert %{"result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "opt-long"}}} =
             List.last(FakeAcp.answers(context))

    context
  end

  # --- tools and subagent batches -------------------------------------------------------

  defp update_step(kind, fields), do: %{"update" => Map.put(fields, "sessionUpdate", kind)}

  step "a command Antigravity ran exits with code 2", context do
    root = World.project(context).root

    steps = [
      update_step("tool_call", %{
        "toolCallId" => "cmd1",
        "title" => "make test",
        "kind" => "execute",
        "status" => "completed",
        "rawInput" => %{"command" => "make test", "cwd" => root},
        "rawOutput" => %{"combinedOutput" => "boom output", "exitCode" => 2},
        "content" => []
      })
    ]

    context = script_turn(context, %{"match" => "run it", "steps" => steps}) |> run_turn("run it")
    Map.put(context, :run_state, FakeAcp.await_run(context, "completed"))
  end

  step "the command is shown with its output, its working folder and the exit code 2", context do
    assert [item] =
             Enum.filter(turn_items(context.run_state), &(&1["type"] == "command_execution"))

    assert item["input"] == "make test"
    assert item["output"] == "boom output"
    assert item["cwd"] == World.project(context).root
    assert item["exitCode"] == 2
    assert item["status"] == "completed"
    context
  end

  step "Antigravity reports a tool with a command line and no kind", context do
    root = World.project(context).root

    steps = [
      update_step("tool_call_update", %{
        "toolCallId" => "cmd2",
        "title" => "run_command",
        "status" => "completed",
        "rawInput" => %{"CommandLine" => "ls -la", "Cwd" => root},
        "rawOutput" => %{"combinedOutput" => "done", "exitCode" => 1},
        "content" => []
      })
    ]

    context =
      script_turn(context, %{"match" => "list files", "steps" => steps}) |> run_turn("list files")

    Map.put(context, :run_state, FakeAcp.await_run(context, "completed"))
  end

  step "the tool is shown as a command with that command line and its working folder", context do
    assert [item] =
             Enum.filter(turn_items(context.run_state), &(&1["type"] == "command_execution"))

    assert item["input"] == "ls -la"
    assert item["cwd"] == World.project(context).root
    Map.put(context, :tool_item, item)
  end

  step "a command that exited with an error code is not shown as a failed tool for that reason alone",
       context do
    assert context.tool_item["exitCode"] == 1
    assert context.tool_item["status"] == "completed"
    context
  end

  step "an Antigravity tool result carries an inline image and names a local image file",
       context do
    root = World.project(context).root
    local = Path.join(root, "shot.png")
    File.write!(local, "PNG")

    call = fn id, image_path, secret ->
      update_step("tool_call_update", %{
        "toolCallId" => id,
        "title" => "screenshot",
        "kind" => "other",
        "status" => "completed",
        "rawInput" => %{"path" => "shot.png"},
        "rawOutput" => %{"imagePath" => image_path, "data" => "data:image/png;base64,#{secret}"},
        "content" => [
          %{"type" => "image", "data" => secret, "mimeType" => "image/png"},
          %{"type" => "content", "content" => %{"type" => "text", "text" => "look"}}
        ]
      })
    end

    steps = [
      call.("img1", local, "INLINESECRET1"),
      call.("img2", "https://example.com/shot.png", "INLINESECRET2"),
      call.("img3", "file://othermachine/share/shot.png", "INLINESECRET3")
    ]

    context =
      script_turn(context, %{"match" => "show images", "steps" => steps})
      |> run_turn("show images")

    Map.merge(context, %{
      run_state: FakeAcp.await_run(context, "completed"),
      local_image: local
    })
  end

  defp tool_items(state),
    do: Enum.filter(turn_items(state), &(&1["type"] == "dynamic_tool"))

  step "the inline image is not stored with the thread", context do
    for item <- tool_items(context.run_state),
        secret <- ["INLINESECRET1", "INLINESECRET2", "INLINESECRET3"],
        do: refute(inspect(item) =~ secret)

    context
  end

  step "the local image file is offered as a preview", context do
    assert Enum.any?(tool_items(context.run_state), &(&1["imagePath"] == context.local_image))
    context
  end

  step "an image named by a web address or a file on another machine is not", context do
    previews =
      tool_items(context.run_state) |> Enum.map(& &1["imagePath"]) |> Enum.reject(&is_nil/1)

    assert previews == [context.local_image]
    context
  end

  step "an Antigravity tool reports very large or deeply nested data", context do
    deep = Enum.reduce(1..20, %{"leaf" => "x"}, fn _, acc -> %{"level" => acc} end)
    many = Map.new(1..600, &{"key-#{&1}", "v"})

    steps = [
      update_step("tool_call_update", %{
        "toolCallId" => "big1",
        "title" => "big_tool",
        "kind" => "other",
        "status" => "completed",
        "rawInput" => %{
          "blob" => String.duplicate("x", 9_000),
          "tail" => String.duplicate("0123456789", 1_000),
          "deep" => deep
        },
        "content" => []
      }),
      update_step("tool_call_update", %{
        "toolCallId" => "big2",
        "title" => "wide_tool",
        "kind" => "other",
        "status" => "completed",
        "rawInput" => %{"many" => many},
        "content" => []
      }),
      %{"text" => String.duplicate("A", 9_000)}
    ]

    context =
      script_turn(context, %{"match" => "big data", "steps" => steps}) |> run_turn("big data")

    Map.put(context, :run_state, FakeAcp.await_run(context, "completed"))
  end

  step "each piece of text keeps its last 8,000 characters under \"[Earlier output truncated]\"",
       context do
    item = Enum.find(tool_items(context.run_state), &(&1["input"]["blob"] != nil))
    blob = item["input"]["blob"]
    assert String.starts_with?(blob, "[Earlier output truncated]")

    assert String.length(blob) <=
             8_000 + String.length("[Earlier output truncated]\n\n")

    assert String.ends_with?(item["input"]["tail"], "0123456789")
    Map.put(context, :tool_item, item)
  end

  step "at most 512 entries and 64,000 characters of one tool report are kept", context do
    wide = Enum.find(tool_items(context.run_state), &(&1["input"]["many"] != nil))
    assert map_size(wide["input"]["many"]) < 600

    for item <- tool_items(context.run_state) do
      assert inspect(item["input"]) |> String.length() |> Kernel.<(70_000)
    end

    depth =
      Stream.unfold(context.tool_item["input"]["deep"], fn
        %{"level" => next} -> {1, next}
        _ -> nil
      end)
      |> Enum.count()

    assert depth <= 12
    context
  end

  step "what Antigravity writes as its answer is not shortened", context do
    texts =
      turn_items(context.run_state)
      |> Enum.filter(&(&1["type"] == "assistant_message"))
      |> Enum.map_join("", &(&1["text"] || ""))

    assert String.length(texts) >= 9_000
    context
  end

  step "an MCP server offers a tool called \"start_subagent\"", context do
    steps = [
      update_step("tool_call", %{
        "toolCallId" => "mcp1",
        "title" => "Running start_subagent",
        "kind" => "other",
        "status" => "completed",
        "_meta" => %{"is_mcp_tool_call" => true},
        "content" => [
          %{"type" => "content", "content" => %{"type" => "text", "text" => "mcp ran"}}
        ]
      })
    ]

    script_turn(context, %{"match" => "use the mcp tool", "steps" => steps})
  end

  step "Antigravity calls that tool", context do
    context = run_turn(context, "use the mcp tool")
    Map.put(context, :run_state, FakeAcp.await_run(context, "completed"))
  end

  step "it is shown as a tool call, not as a subagent batch", context do
    items = turn_items(context.run_state)
    assert Enum.any?(items, &(&1["type"] == "dynamic_tool"))
    refute Enum.any?(items, &(&1["type"] == "subagent"))
    context
  end

  step "Antigravity starts a subagent batch", context do
    steps = [
      update_step("tool_call", %{
        "toolCallId" => "batch1",
        "title" => "Running start_subagent",
        "kind" => "other",
        "status" => "in_progress",
        "rawOutput" => "Batch output: two subagents on it",
        "content" => []
      })
    ]

    context =
      script_turn(context, %{"match" => "delegate this", "steps" => steps})
      |> run_turn("delegate this")

    Map.put(context, :run_state, FakeAcp.await_run(context, "completed"))
  end

  step "the batch is titled \"Antigravity subagent batch\"", context do
    assert [item] = Enum.filter(turn_items(context.run_state), &(&1["type"] == "subagent"))
    assert item["title"] == "Antigravity subagent batch"
    Map.put(context, :batch_item, item)
  end

  step "it shows the batch's own output, or else its detail, or else its title", context do
    assert context.batch_item["prompt"] == "Batch output: two subagents on it"
    context
  end

  step "Antigravity reported that a subagent batch started successfully", context do
    steps = [
      update_step("tool_call", %{
        "toolCallId" => "batch2",
        "title" => "Running start_subagent",
        "kind" => "other",
        "status" => "completed",
        "content" => [
          %{"type" => "content", "content" => %{"type" => "text", "text" => "Check the tests"}}
        ]
      }),
      %{"waitFile" => "release-batch"}
    ]

    context =
      script_turn(context, %{"match" => "delegate more", "steps" => steps})
      |> run_turn("delegate more")

    state =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        if Enum.any?(turn_items(state), &(&1["type"] == "subagent")), do: state
      end)

    Map.merge(context, %{run_state: state, batch_pending: true})
  end

  step ~r/^the turn (?<ending>is still running|is stopped by the user)$/,
       %{args: [ending]} = context do
    case ending do
      "is still running" ->
        state =
          World.await_stream(World.thread_id(context, context.thread), fn state ->
            if Enum.any?(turn_items(state), &(&1["type"] == "subagent")), do: state
          end)

        context = Map.put(context, :run_state, state)
        release_file(context, "release-batch")
        context

      "is stopped by the user" ->
        run =
          context
          |> World.runs(context.thread)
          |> Enum.find(&(&1["status"] in ~w(starting running waiting)))

        {:ok, _} =
          HalC2.Orchestration.dispatch(%{
            "type" => "run.interrupt",
            "threadId" => World.thread_id(context, context.thread),
            "runId" => run["id"]
          })

        release_file(context, "release-batch")
        Map.put(context, :run_state, FakeAcp.await_run(context, "interrupted"))
    end
  end

  step ~r/^the batch is shown as (?<state>.+)$/, %{args: [shown]} = context do
    assert [item] = Enum.filter(turn_items(context.run_state), &(&1["type"] == "subagent"))
    assert item["status"] == shown, "got #{inspect(item["status"])}"
    Map.put(context, :batch_item, item)
  end

  step "an Antigravity subagent batch fails", context do
    steps = [
      update_step("tool_call_update", %{
        "toolCallId" => "batch3",
        "title" => "Running start_subagent",
        "kind" => "other",
        "status" => "failed",
        "rawOutput" => "the batch blew up",
        "content" => []
      })
    ]

    context =
      script_turn(context, %{"match" => "delegate and fail", "steps" => steps})
      |> run_turn("delegate and fail")

    Map.put(context, :run_state, FakeAcp.await_run(context, "completed"))
  end

  step "its output is shown as its result", context do
    assert context.batch_item["result"] == "the batch blew up"
    context
  end

  # --- models ---------------------------------------------------------------------------

  defp model_options(ids, current) do
    %{
      "configOptions" => [
        %{
          "id" => "model",
          "name" => "Model",
          "type" => "select",
          "category" => "model",
          "currentValue" => current,
          "options" =>
            [%{"value" => hd(ids), "name" => hd(ids)}] ++
              for(id <- tl(ids), do: %{"value" => id, "name" => id})
        }
      ]
    }
  end

  defp account_with_models(context, ids, current) do
    options = model_options(ids, current)
    FakeAcp.configure(context, &Map.merge(&1, options))
    context = signed_in(context)
    Antigravity.put_account(@instance, HalC2.Acp.session_models(options))
    context
  end

  defp set_model_calls(context) do
    for %{"params" => %{"value" => value}} <-
          FakeAcp.received(context, "session/set_config_option"),
        do: value
  end

  step "an Antigravity thread uses the default model", context do
    Map.put(context, :preferred, Antigravity.preferred_model())
  end

  step ~r/^a turn starts and (?<situation>.+)$/, %{args: [situation]} = context do
    preferred = context.preferred
    assert is_binary(preferred)

    {ids, current} =
      case situation do
        "the account offers the model HAL-C2 ships as its default" ->
          {[preferred, "fake/other"], "fake/other"}

        "the account does not offer that model" ->
          {["fake/one"], "fake/one"}

        "Antigravity already has that model selected" ->
          {[preferred, "fake/other"], preferred}
      end

    context = account_with_models(context, ids, current)

    context =
      FakeAcp.thread(context, "Work", "full-access", %{
        "modelSelection" => %{"instanceId" => @instance, "model" => "antigravity-default"}
      })

    context = FakeAcp.send_message(context, "hello model")
    FakeAcp.await_run(context, "completed")
    Map.merge(context, %{ids: ids, current: current})
  end

  step "the turn runs on that model", context do
    assert set_model_calls(context) == [context.preferred]
    context
  end

  step "the turn runs on the model Antigravity has selected", context do
    assert set_model_calls(context) == []
    context
  end

  step "Antigravity is not asked to change its model", context do
    assert set_model_calls(context) == []
    context
  end

  step "an Antigravity thread uses a model the user picked", context do
    context = account_with_models(context, ["fake/one", "fake/two"], "fake/one")

    context =
      FakeAcp.thread(context, "Work", "full-access", %{
        "modelSelection" => %{"instanceId" => @instance, "model" => "fake/two"}
      })

    context = FakeAcp.send_message(context, "first message")
    FakeAcp.await_run(context, "completed")
    assert set_model_calls(context) == ["fake/two"]
    context
  end

  step "the Antigravity runtime restarts and the thread continues", context do
    Antigravity.stop_sessions(@instance)
    context = FakeAcp.send_message(context, "second message")
    FakeAcp.await_run(context, "completed")
    context
  end

  step "the thread still uses that model", context do
    assert set_model_calls(context) == ["fake/two", "fake/two"]
    context
  end

  # One attachment as a scenario names it, sent with a typed message.
  step ~r/^the user sends an Antigravity message with (?<what>.+)$/,
       %{args: [what]} = context do
    send_with_attachment(context, what)
  end

  @mib_bytes 1024 * 1024

  defp dispatch_attachment(context, attachment, text) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread),
        "messageId" => "msg-#{System.unique_integer([:positive])}",
        "text" => text,
        "attachments" => [attachment]
      })

    context
  end

  defp send_with_attachment(context, what) do
    dir = HalC2.Attachments.dir()
    File.mkdir_p!(dir)

    put = fn id, name, mime, content, extra ->
      path = Path.join(dir, id <> Path.extname(name))
      File.write!(path, content)

      attachment =
        Map.merge(
          %{
            "type" => if(String.starts_with?(mime, "image/"), do: "image", else: "file"),
            "id" => id,
            "name" => name,
            "mimeType" => mime
          },
          extra
        )

      {attachment, %{path: path, bytes: content, name: name}}
    end

    spec =
      case what do
        "a PNG image" ->
          put.("att-png", "pic.png", "image/png", "PNGDATA", %{})

        "an audio clip" ->
          put.("att-audio", "clip.mp3", "audio/mpeg", "AUDIODATA", %{})

        "a PDF" ->
          put.("att-pdf", "doc.pdf", "application/pdf", "%PDF-1.4 bytes", %{})

        "a text file" ->
          put.("att-text", "notes.md", "text/plain", "hello text\n", %{})

        "a long pasted text" ->
          put.("att-pasted", "pasted.txt", "text/plain", "PASTED-CONTENT kept apart\n", %{
            "source" => %{"_tag" => "pasted-text"}
          })

        ~s(the spreadsheet "q3.xlsx") ->
          put.(
            "att-xlsx",
            "q3.xlsx",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "xlsx",
            %{}
          )

        ~s("notes.txt" that is not valid UTF-8) ->
          put.("att-utf8", "notes.txt", "text/plain", <<0xFF, 0xFE, "abc">>, %{})

        ~s("notes.txt" that holds binary data) ->
          put.("att-bin", "notes.txt", "text/plain", "abc" <> <<0>> <> "def", %{})

        ~s(the 2 MiB text file "big.txt") ->
          put.("att-big", "big.txt", "text/plain", :binary.copy("a", 2 * @mib_bytes), %{})

        ~s("log.txt" that grew past the limit while read) ->
          {put.("att-grow", "log.txt", "text/plain", :binary.copy("a", 900 * 1024), %{}), :grow}

        ~s("notes.txt" whose upload is no longer stored) ->
          {%{
             "type" => "file",
             "id" => "att-gone",
             "name" => "notes.txt",
             "mimeType" => "text/plain"
           }, %{}}

        ~s(the pasted text "pasted.txt" whose upload is no longer stored) ->
          {%{
             "type" => "file",
             "id" => "att-pasted-gone",
             "name" => "pasted.txt",
             "mimeType" => "text/plain",
             "source" => %{"_tag" => "pasted-text"}
           }, %{}}

        ~s("notes.txt" whose stored id is not valid) ->
          {%{
             "type" => "file",
             "id" => "../not valid!",
             "name" => "notes.txt",
             "mimeType" => "text/plain"
           }, %{}}

        "nothing but blank text" ->
          :blank
      end

    case spec do
      :blank ->
        Map.put(run_turn(context, "   "), :sent_attachment, %{})

      {{attachment, info}, :grow} ->
        FakeAcp.configure(
          context,
          &Map.put(&1, "waitForFileOn", %{"session/new" => "release-session"})
        )

        context = signed_in(context) |> FakeAcp.thread("Work")
        # Dispatch opens the session before it returns, and the fake holds
        # that session open: grow the file while it waits, from here.
        task = Task.async(fn -> dispatch_attachment(context, attachment, "please read this") end)
        assert [_ | _] = wait_for(fn -> FakeAcp.received(context, "session/new") end)
        File.write!(info.path, :binary.copy("b", 2 * @mib_bytes))
        release_file(context, "release-session")
        Task.await(task)
        Map.put(context, :sent_attachment, info)

      {attachment, info} ->
        context = signed_in(context) |> FakeAcp.thread("Work")
        context = dispatch_attachment(context, attachment, "please read this")
        Map.put(context, :sent_attachment, info)
    end
  end

  step ~r/^Antigravity receives (?<form>the image itself|the audio itself|a link to the file, without its bytes|the file's text|the text, kept apart from the typed message)$/,
       %{args: [form]} = context do
    FakeAcp.await_run(context, "completed")
    [%{"prompt" => blocks} | _] = Enum.reverse(prompts(context))
    info = context.sent_attachment

    case form do
      "the image itself" ->
        assert %{"type" => "image", "mimeType" => "image/png", "data" => data} =
                 Enum.find(blocks, &(&1["type"] == "image"))

        assert data == Base.encode64(info.bytes)

      "the audio itself" ->
        assert %{"type" => "audio", "mimeType" => "audio/mpeg", "data" => data} =
                 Enum.find(blocks, &(&1["type"] == "audio"))

        assert data == Base.encode64(info.bytes)

      "a link to the file, without its bytes" ->
        assert %{
                 "type" => "resource_link",
                 "uri" => uri,
                 "name" => "doc.pdf",
                 "mimeType" => "application/pdf"
               } = Enum.find(blocks, &(&1["type"] == "resource_link"))

        assert uri == "file://" <> info.path
        refute inspect(blocks) =~ Base.encode64(info.bytes)

      "the file's text" ->
        assert %{"type" => "resource", "resource" => %{"text" => "hello text\n"}} =
                 Enum.find(blocks, &(&1["type"] == "resource"))

      "the text, kept apart from the typed message" ->
        assert [%{"type" => "text", "text" => text}] = blocks
        assert text =~ "please read this"
        assert text =~ info.path
        refute text =~ "PASTED-CONTENT"
    end

    context
  end

  step "the message is refused with {string}", %{args: [message]} = context do
    state = FakeAcp.await_run(context, "failed")
    assert last_error(state) == message, "got #{inspect(last_error(state))}"
    context
  end

  step "the typed text is not sent without the attachment", context do
    assert FakeAcp.received(context, "session/prompt") == []
    context
  end

  # Prepares a runtime the way the scenario's Given arranged to fail: by
  # starting a thread turn, or by the model refresh's checking session.
  defp prepare_runtime(context) do
    case context[:setup_via] do
      :refresh ->
        {reply, context} =
          World.call(context, "server.refreshProviders", %{
            "instanceId" => @instance,
            "refreshModels" => true
          })

        Map.put(context, :reply, reply)

      _ ->
        context =
          context |> signed_in() |> FakeAcp.thread("Work") |> FakeAcp.send_message("hello")

        state = FakeAcp.await_run(context, "failed")
        Map.put(context, :reply, {:error, last_error(state), %{}})
    end
  end

  # The scenario's `/w` is the project's folder.
  defp wpath(context, "/w" <> rest),
    do: Path.join(World.project(context).root, String.trim_leading(rest, "/"))

  defp wpath(_context, path), do: path

  defp wtext(context, text), do: String.replace(text, "/w", World.project(context).root)

  # Adds a scripted turn to the fake, ahead of its defaults.
  defp script_turn(context, turn) do
    FakeAcp.configure(context, &Map.update!(&1, "turns", fn turns -> [turn | turns] end))
    context
  end

  # A signed-in thread that has sent `text`.
  defp run_turn(context, text) do
    context |> signed_in() |> FakeAcp.thread("Work") |> FakeAcp.send_message(text)
  end

  defp turn_items(state), do: HalC2.StreamState.list(state, "turn-item")

  defp release_file(context, name) do
    File.write!(Path.join(FakeAcp.fake(context, @instance).dir, name), "go\n")
    context
  end

  # --- helpers --------------------------------------------------------------------

  defp read_step(match, path) do
    %{
      "match" => match,
      "steps" => [
        %{"request" => %{"method" => "fs/read_text_file", "params" => %{"path" => path}}},
        %{"text" => "Done."}
      ]
    }
  end

  # A turn in which Antigravity asks HAL-C2 for the text file at `path`.
  defp read_turn(context, path) do
    turn = read_step("read it", path)
    FakeAcp.configure(context, &Map.update!(&1, "turns", fn turns -> [turn | turns] end))
    context = context |> signed_in() |> FakeAcp.thread("Work") |> FakeAcp.send_message("read it")
    FakeAcp.await_run(context, "completed")
    context
  end

  # A release zip of the fake's wrapper and a helper, as Google publishes it.
  defp build_release(context, version) do
    dir = Mc.tmp_dir(context.mc, "agy-release")
    File.cp!(FakeAcp.fake(context, @instance).bin, Path.join(dir, "agy_acp_server.par"))
    File.write!(Path.join(dir, "localharness_external"), "#!/bin/sh\nexit 0\n")
    archive = Path.join(Mc.tmp_dir(context.mc, "agy-archive"), "runtime.zip")

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

  # The install helpers below are public for provider-setup.feature, whose managed
  # runtime is this one.
  @doc false
  def installer(context) do
    Mc.ensure(Installation)
    context
  end

  # An install started and halfway through its download.
  def downloading(context) do
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

  def previous_unchanged(context) do
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
  def watch_install(%{install_sub: _} = context), do: context

  def watch_install(context) do
    id = System.unique_integer([:positive])

    client =
      World.client(context)
      |> Mc.sub(id, %{
        "type" => "providerInstall",
        "mc" => Atom.to_string(node()),
        "instanceId" => @instance
      })

    {frame, client} = Mc.await(client, &(&1["t"] == "providerInstall" and &1["id"] == id))

    context
    |> World.put_client(client)
    |> Map.merge(%{install_sub: id, install_first: frame["state"]})
  end

  # Install states pushed until one satisfies `done?`; returns `{states, context}`.
  def collect_install(context, done?, acc \\ []) do
    id = context.install_sub

    {frame, client} =
      Mc.await(
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
    folder = Mc.tmp_dir(context.mc, "antigravity-manual")
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
      World.call!(context, "hal-c2.readSettings")

    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{
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

  defp quota_reply(context, text) do
    turn = %{"match" => "keep going", "steps" => [%{"text" => text}]}
    FakeAcp.configure(context, &Map.update!(&1, "turns", fn turns -> [turn | turns] end))
    sent_at = System.system_time(:millisecond)

    context
    |> signed_in()
    |> FakeAcp.thread("Work")
    |> FakeAcp.send_message("keep going")
    |> Map.put(:sent_at, sent_at)
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
          |> Mc.sub(id, %{
            "type" => "providerAuth",
            "mc" => Atom.to_string(node()),
            "instanceId" => instance
          })

        {_frame, client} = Mc.await(client, &(&1["t"] == "providerAuth" and &1["id"] == id))

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
        Mc.await(
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
