defmodule T3.Steps.Settings.ProvidersPanel do
  @moduledoc """
  Steps for features/settings/providers-panel.feature: what the Providers settings
  page asks of a node.

  The page is two sockets subscribed to the node's config ("default", and "other"
  for a second client). The environment has an ACP agent "gemini", an
  `acpRegistry` instance of the registry agent "gemini-cli", run as the fake ACP
  agent (`test/support/fake_acp.py`) with a state file, so separate runs of it
  (probes, session and provider calls) show what it was asked. The ACP Registry is
  served from the node's home: "gemini-cli" ships a binary for this machine.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Steps.Settings.Updates
  alias T3.Test.Node
  alias T3.Test.Node.World

  @fake_acp Path.expand("../../support/fake_acp.py", __DIR__)
  @instance "gemini"

  step "the user has opened the Providers settings for the environment {string}",
       %{args: [_label]} = context do
    # The machine's own Codex and Claude never run here; the Updates rule installs a fake.
    World.put_app_env(:codex_command, ["t3-test-no-codex"])
    World.put_app_env(:claude_command, ["t3-test-no-claude"])

    context = registry(context)
    state = Path.join(context.node.home, "gemini-state.json")
    auth = Path.join(context.node.home, "gemini-signed-in")
    File.write!(auth, "signed in")

    World.put_app_env(:acp_commands, %{@instance => ["python3", "-u", @fake_acp]})
    T3.Acp.forget(@instance)
    ExUnit.Callbacks.on_exit(fn -> T3.Acp.forget(@instance) end)

    context =
      World.update_settings(context, %{
        "providerInstances" => %{
          @instance => %{
            "driver" => "acpRegistry",
            "displayName" => "Gemini",
            "config" => %{"agentId" => "gemini-cli"},
            "environment" => [
              %{"name" => "FAKE_ACP_STATE", "value" => state},
              %{"name" => "FAKE_AUTH_FILE", "value" => auth}
            ]
          }
        }
      })

    # The node read the agent when it was added.
    :ok = T3.Acp.reload(@instance)
    assert %{"models" => [_ | _]} = T3.Acp.entry(@instance)

    context
    |> World.put_client(Node.config(World.client(context)))
    |> World.put_client("other", Node.config(Node.connect(context.node)))
    |> Map.merge(%{acp_state: state, acp_auth: auth, acp_calls: length(calls(state))})
  end

  # --- refreshing ------------------------------------------------------------------------

  step "the node reads each provider's installation, sign-in and models again", context do
    assert {:ok, %{"providers" => providers}} = context.reply
    assert %{"version" => "9.9", "models" => [_ | _]} = gemini(providers)
    assert %{"auth" => %{"status" => "authenticated"}} = gemini(providers)

    # The agent was started again, initialized (installation and version) and
    # asked for a session (sign-in and models).
    assert ["initialize", "session/new" | _] =
             Enum.drop(calls(context.acp_state), context.acp_calls)

    context
  end

  step "every connected client receives the new provider list", context do
    Enum.reduce(["default", "other"], context, fn name, context ->
      {frame, client} = Node.await(World.client(context, name), &providers_frame?/1)
      assert %{"models" => [_ | _]} = gemini(frame["providers"])
      World.put_client(context, name, client)
    end)
  end

  # --- the ACP Registry ------------------------------------------------------------------

  step "the user searches the ACP Registry for {string}", %{args: [query]} = context do
    {reply, context} = World.call(context, "server.searchAcpRegistry", %{"query" => query})
    Map.put(context, :reply, reply)
  end

  # "gemini-mac" has no build for this machine; "atlas" does not match.
  step "the compatible agents matching {string} are listed best first",
       %{args: [_query]} = context do
    assert {:ok, %{"agents" => agents}} = context.reply
    assert Enum.map(agents, & &1["id"]) == ["gemini-cli", "lite-gemini", "helper"]
    assert %{"distribution" => "binary", "integrity" => "sha256"} = hd(agents)
    context
  end

  step "the node prepares the agent's current version for this machine", context do
    assert {:ok,
            %{
              "agentId" => "gemini-cli",
              "version" => "1.2.3",
              "distribution" => "binary",
              "prepared" => true
            }} = context.reply

    exe =
      Path.join([
        context.node.home,
        "tools/gemini-cli/1.2.3",
        T3.Acp.Catalog.platform(),
        "bin/gemini"
      ])

    assert File.regular?(exe)
    context
  end

  step "a provider instance uses the registry agent {string}", %{args: [agent]} = context do
    {_, context} = World.call!(context, "server.prepareAcpRegistryAgent", %{"agentId" => agent})

    assert get_in(T3.Settings.settings(), ["providerInstances", @instance, "config", "agentId"]) ==
             agent

    Map.put(context, :agent, agent)
  end

  step "the node is asked to uninstall {string}", %{args: [agent]} = context do
    {reply, context} =
      World.call(context, "server.uninstallAcpRegistryManagedBinary", %{"agentId" => agent})

    Map.put(context, :reply, reply)
  end

  step "the uninstall is refused", context do
    assert {:ok, %{"agentId" => agent, "removed" => false}} = context.reply
    assert File.dir?(Path.join([context.node.home, "tools", agent]))
    context
  end

  # --- native sessions -------------------------------------------------------------------

  step "the agent {string} has a native session for the project {string}",
       %{args: [@instance, project]} = context do
    native_session(context, project, "old-1")
  end

  step "the agent {string} has a native session that was not imported",
       %{args: [@instance]} = context do
    native_session(context, "t3code", "old/2")
  end

  step "the user imports that session", context do
    import_session(context)
  end

  step "a native session was imported as a thread", context do
    context |> native_session("t3code", "old-1") |> import_session()
  end

  step ~r/^a thread continuing the session is created in "(?<project>[^"]+)"$/,
       %{args: [project]} = context do
    assert {:ok, %{"threadId" => thread_id, "imported" => true}} = context.reply
    project_id = World.project(context, project).id
    World.await_row(thread_id, &(&1["projectId"] == project_id))

    state = T3.Streams.Server.state(T3.Streams.ensure(thread_id))

    assert [%{"providerInstanceId" => @instance, "nativeThreadRef" => %{"nativeId" => "old-1"}}] =
             T3.StreamState.list(state, "provider-thread")

    assert %{"importedThreadId" => ^thread_id} = listed(context, "old-1")
    context
  end

  step "the user is told to delete the imported thread first", context do
    assert {:error, "Delete the imported T3 thread before deleting its native ACP session.",
            %{"_tag" => "AcpRegistryOperationError", "reason" => "session_delete_failed"}} =
             context.reply

    refute "session/delete" in calls(context.acp_state)
    context
  end

  step "the user deletes it and confirms", context do
    {reply, context} = World.call(context, "server.deleteAcpRegistrySession", context.acp_session)
    Map.put(context, :reply, reply)
  end

  step "the session is deleted by the agent", context do
    assert {:ok, %{"deleted" => true}} = context.reply
    assert "old/2" in state(context.acp_state)["deleted"]
    assert listed(context, "old/2") == nil
    context
  end

  # --- model providers and sign-in -------------------------------------------------------

  step "the user sets the agent's model provider to {string} with an authorization header",
       %{args: [url]} = context do
    context = ensure_project(context, "t3code")

    input =
      Map.merge(panel_input(context), %{
        "providerId" => "openai",
        "apiType" => "openai",
        "baseUrl" => url,
        "headers" => %{"Authorization" => "Bearer test-token"}
      })

    {_, context} = World.call!(context, "server.setAcpRegistryProvider", input)
    Map.put(context, :base_url, url)
  end

  step "the agent uses that base URL", context do
    {current, context} = current_provider(context)
    assert current == %{"apiType" => "openai", "baseUrl" => context.base_url}
    assert state(context.acp_state)["headers"] == %{"Authorization" => "Bearer test-token"}
    context
  end

  step "the user disables that model provider", context do
    input = Map.put(panel_input(context), "providerId", "openai")
    {result, context} = World.call!(context, "server.disableAcpRegistryProvider", input)
    assert result == %{"disabled" => true}
    context
  end

  step "the agent no longer uses it", context do
    {current, context} = current_provider(context)
    assert current == nil
    context
  end

  step "the user logs out of the agent {string}", %{args: [@instance]} = context do
    {reply, context} =
      World.call(context, "server.logoutAcpRegistry", %{"instanceId" => @instance})

    Map.put(context, :reply, reply)
  end

  step "the agent is signed out and its status is read again", context do
    assert {:ok, %{"loggedOut" => true}} = context.reply
    refute File.exists?(context.acp_auth)

    {_frame, client} =
      Node.await(
        World.client(context),
        &(providers_frame?(&1) and
            gemini(&1["providers"])["auth"]["status"] == "unauthenticated"),
        5_000
      )

    World.put_client(context, client)
  end

  # --- updates ---------------------------------------------------------------------------

  step ~r/^"Codex" has an update available$/, context do
    context = context |> Updates.install("Codex", "a global npm install") |> Updates.check()
    assert Updates.advisory(context, "Codex")["status"] == "behind_latest"
    context
  end

  step ~r/^the user updates "Codex"$/, context do
    {reply, context} =
      World.call_keeping(context, "server.updateProvider", %{"provider" => "codex"})

    Map.put(context, :reply, reply)
  end

  step "the node runs the Codex updater", context do
    prefix = Path.join(context.node.home, "npm")
    assert {:ok, %{"providers" => providers}} = context.reply

    assert File.read!(Path.join(prefix, "npm.log")) =~
             "install -g --prefix #{prefix} @openai/codex@latest"

    Map.put(context, :providers, providers)
  end

  step "the provider list is reported again", context do
    assert Updates.advisory(context, "Codex")["currentVersion"] == "9.9.9"

    {_frame, client} =
      Node.await(
        World.client(context),
        &(providers_frame?(&1) and codex_version(&1["providers"]) == "9.9.9")
      )

    World.put_client(context, client)
  end

  # --- helpers ---------------------------------------------------------------------------

  # The ACP Registry, served from the node's home: "gemini-cli" with a binary for
  # this machine (a script running the fake agent), agents that match "gemini" less
  # well, one without a build for this machine, and one that does not match.
  defp registry(context) do
    served = Node.tmp_dir(context.node, "registry")
    script = Path.join(served, "gemini")
    File.write!(script, "#!/bin/sh\nexec python3 -u #{@fake_acp} \"$@\"\n")
    File.chmod!(script, 0o755)
    archive = Path.join(served, "gemini.tar.gz")

    :ok =
      :erl_tar.create(to_charlist(archive), [{~c"bin/gemini", to_charlist(script)}], [:compressed])

    sha = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)

    server =
      Node.ensure(
        Supervisor.child_spec(
          {Bandit, plug: {Plug.Static, at: "/", from: served}, port: 0, ip: :loopback},
          id: :acp_registry
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"
    here = T3.Acp.Catalog.platform()
    elsewhere = Enum.find(["windows-aarch64", "darwin-x86_64"], &(&1 != here))

    binary = fn platform ->
      %{
        "binary" => %{
          platform => %{
            "archive" => "#{base}/gemini.tar.gz",
            "cmd" => "./bin/gemini",
            "sha256" => sha
          }
        }
      }
    end

    agent = fn id, name, description, distribution ->
      %{
        "id" => id,
        "name" => name,
        "version" => "1.2.3",
        "description" => description,
        "authors" => ["Tests"],
        "distribution" => distribution
      }
    end

    File.write!(
      Path.join(served, "registry.json"),
      JSON.encode!(%{
        "version" => "1.0.0",
        "agents" => [
          agent.("helper", "Helper", "Works with Gemini models", %{
            "npx" => %{"package" => "helper@1.2.3"}
          }),
          agent.("gemini-mac", "Gemini Mac", "Gemini on another machine", binary.(elsewhere)),
          agent.("lite-gemini", "Lite Gemini", "A smaller agent", %{
            "uvx" => %{"package" => "lite-gemini"}
          }),
          agent.("gemini-cli", "Gemini CLI", "Google's agent", binary.(here)),
          agent.("atlas", "Atlas", "Maps", binary.(here))
        ]
      })
    )

    World.put_app_env(:acp_registry_url, "#{base}/registry.json")
    :persistent_term.erase({T3.Acp.Catalog, :index})
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({T3.Acp.Catalog, :index}) end)
    context
  end

  defp native_session(context, project, session_id) do
    context = ensure_project(context, project)
    context = Map.put(context, :acp_project, project)
    session = listed(context, session_id)
    assert %{"importedThreadId" => nil} = session

    Map.put(
      context,
      :acp_session,
      Map.merge(panel_input(context), %{"sessionId" => session_id, "title" => session["title"]})
    )
  end

  # The thread the import wrote is awaited in the read model, where the node checks
  # for it before deleting a session.
  defp import_session(context) do
    {reply, context} =
      World.call(context, "server.importAcpRegistrySession", context.acp_session)

    with {:ok, %{"threadId" => thread_id}} <- reply, do: World.await_row(thread_id, & &1)
    Map.put(context, :reply, reply)
  end

  # The agent's session `session_id` for the scenario's project, or nil.
  defp listed(context, session_id) do
    {result, _} = World.call!(context, "server.listAcpRegistrySessions", panel_input(context))
    Enum.find(result["sessions"], &(&1["sessionId"] == session_id))
  end

  defp current_provider(context) do
    {result, context} =
      World.call!(context, "server.listAcpRegistryProviders", panel_input(context))

    assert [%{"providerId" => "openai", "current" => current}] = result["providers"]
    {current, context}
  end

  defp ensure_project(context, title) do
    context = Map.put(context, :acp_project, title)
    if context.projects[title], do: context, else: World.create_project(context, title)
  end

  defp panel_input(context),
    do: %{
      "instanceId" => @instance,
      "projectId" => World.project(context, context.acp_project).id
    }

  defp providers_frame?(frame), do: frame["t"] == "config.providers"

  defp gemini(providers), do: Enum.find(providers, &(&1["instanceId"] == @instance))

  defp codex_version(providers),
    do: Enum.find_value(providers, &(&1["instanceId"] == "codex" && &1["version"]))

  defp state(path), do: path |> File.read!() |> JSON.decode!()
  defp calls(path), do: if(File.exists?(path), do: state(path)["calls"], else: [])
end
