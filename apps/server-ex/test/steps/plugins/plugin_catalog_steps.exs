defmodule T3.Steps.Plugins.PluginCatalog do
  @moduledoc "Steps for `features/plugins/plugin-catalog.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Steps.Plugins.AcpRegistry
  alias T3.Test.Node.World

  # --- searching the registry ------------------------------------------------------

  step "at most {int} matching agents are listed, best match first",
       %{args: [limit]} = context do
    assert {:ok, %{"agents" => agents}} = context.reply
    assert length(agents) == limit
    assert hd(agents)["id"] == "code"
    context
  end

  step "agents that cannot run on this platform are left out", context do
    {:ok, %{"agents" => agents}} = context.reply
    refute Enum.any?(agents, &(&1["id"] == "code-elsewhere"))
    context
  end

  # --- installing ------------------------------------------------------------------

  step "the registry lists a checksum for the agent {string}", %{args: [id]} = context do
    context = AcpRegistry.ensure(context)
    AcpRegistry.publish(context, [AcpRegistry.agent(context, id)])
  end

  step "the user adds {string} and the download does not match the checksum",
       %{args: [id]} = context do
    # The archive changes after the registry listed its checksum.
    File.write!(Path.join(context.registry.served, "fake.tar.gz"), "tampered")
    add(context, id)
  end

  step "the install fails saying the checksum did not match", context do
    assert {:error, _, %{"_tag" => "AcpRegistryOperationError", "reason" => "checksum_mismatch"}} =
             context.reply

    context
  end

  step "no instance of {string} is created", %{args: [id]} = context do
    # Nothing was installed (a failed download leaves at most empty directories).
    assert installed_files(context, id) == []

    refute Enum.any?(
             T3.Settings.settings()["providerInstances"] || %{},
             fn {_, i} -> get_in(i, ["config", "agentId"]) == id end
           )

    context
  end

  step "the registry points the agent {string} at a plain HTTP address on another machine",
       %{args: [id]} = context do
    context = AcpRegistry.ensure(context)

    AcpRegistry.publish(context, [
      AcpRegistry.agent(context, id, %{
        "distribution" => %{
          "binary" => %{
            T3.Acp.Catalog.platform() => %{
              "archive" => "http://192.0.2.10/acme.tar.gz",
              "cmd" => "./bin/fake"
            }
          }
        }
      })
    ])
  end

  # The registry in play is the plugin fixture's (`context.registry`) or, in
  # `providers/acp-registry.feature`, the one `T3.Test.AcpFixtures` serves.
  step "the user adds {string}", %{args: [id]} = context do
    if context[:registry] do
      add(context, id)
    else
      {reply, ctx} = World.call(context, "server.prepareAcpRegistryAgent", %{"agentId" => id})
      # A client creates the instance only once the agent is prepared.
      if match?({:ok, _}, reply), do: T3.Test.AcpFixtures.add_registry_instance(id, id)
      Map.put(ctx, :reply, reply)
    end
  end

  step "the install is refused", context do
    assert {:error, _, %{"_tag" => "AcpRegistryOperationError"}} = context.reply
    assert installed_files(context, "acme") == []
    context
  end

  # --- uninstalling ----------------------------------------------------------------

  step "the instance {string} uses the registry agent {string}",
       %{args: [instance, id]} = context do
    context = AcpRegistry.ensure(context)
    context = AcpRegistry.publish(context, [AcpRegistry.agent(context, id)])

    {{:ok, _}, context} =
      World.call(context, "server.prepareAcpRegistryAgent", %{"agentId" => id})

    AcpRegistry.add_instance(context, instance, id)
  end

  step "the user tries to uninstall {string}", %{args: [id]} = context do
    {reply, context} =
      World.call(context, "server.uninstallAcpRegistryManagedBinary", %{"agentId" => id})

    Map.merge(context, %{reply: reply, agent_id: id})
  end

  step "the agent's files are kept", context do
    assert [_ | _] =
             Path.wildcard(
               Path.join(AcpRegistry.tools_dir(context, context.agent_id), "**/bin/fake")
             )

    context
  end

  step "the node reports that nothing was removed", context do
    assert {:ok, %{"removed" => false}} = context.reply
    context
  end

  # --- offline ---------------------------------------------------------------------

  step "the node fetched the registry earlier", context do
    context = AcpRegistry.ensure(context)
    context = AcpRegistry.publish(context, [AcpRegistry.agent(context, "acme")])

    {{:ok, %{"agents" => [_]}}, context} =
      World.call(context, "server.searchAcpRegistry", %{"query" => ""})

    context
  end

  step "the registry cannot be reached now", context do
    File.rm!(Path.join(context.registry.served, "registry.json"))
    # A fresh process has only what the node wrote to disk.
    :persistent_term.erase({T3.Acp.Catalog, :index})
    context
  end

  step "results come from the last fetched copy", context do
    assert {:ok, %{"agents" => [%{"id" => "acme"}]}} = context.reply
    context
  end

  defp installed_files(context, id) do
    Path.join(AcpRegistry.tools_dir(context, id), "**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  defp add(context, id) do
    {reply, context} = World.call(context, "server.prepareAcpRegistryAgent", %{"agentId" => id})
    # A client creates the instance only once the agent is prepared.
    context =
      if match?({:ok, _}, reply), do: AcpRegistry.add_instance(context, id, id), else: context

    Map.put(context, :reply, reply)
  end
end
