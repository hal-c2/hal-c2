defmodule HalC2.Steps.Files.RemovingAndListingProjects do
  @moduledoc """
  Steps for `features/files/removing-and-listing-projects.feature`: project updates
  and deletes over `projects.mutate`, and the automatic pull a node runs at boot.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.{Host, World}

  @sonnet %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-5"}

  step "a connected environment {string} with the project {string} at {string}",
       %{args: [label, title, path]} = context do
    root = Host.path(context, path)
    File.mkdir_p!(root)
    World.git!(root, ~w(init -q -b main))
    World.git!(root, ~w(config user.email hal-c2@example.com))
    World.git!(root, ~w(config user.name HAL-C2))
    File.write!(Path.join(root, "README.md"), "# #{title}\n")
    World.git!(root, ~w(add README.md))
    World.git!(root, ~w(commit -q -m init))

    context
    |> Map.put(:environment_label, label)
    |> World.create_project(title, %{"workspaceRoot" => root})
    |> then(&World.put_client(&1, World.client(&1)))
  end

  step "{string} has the default model \"Sonnet\"", %{args: [project]} = context do
    {:ok, _} = mutate(context, project, %{"defaultModelSelection" => @sonnet})
    context
  end

  step "a client renames {string} to {string}", %{args: [project, title]} = context do
    {reply, context} =
      call(context, %{
        "type" => "project.update",
        "projectId" => World.project(context, project).id,
        "title" => title
      })

    Map.put(context, :reply, reply)
  end

  step "its default model is still \"Sonnet\"", context do
    assert {:ok, %{"defaultModelSelection" => @sonnet, "title" => title}} = context.reply
    row = World.await_row(World.project(context).id, &(&1["title"] == title))
    assert row["defaultModelSelection"] == @sonnet
    context
  end

  step "a client deletes the project {string}", %{args: [project]} = context do
    {reply, context} =
      call(context, %{
        "type" => "project.delete",
        "projectId" => World.project(context, project).id
      })

    assert {:ok, _} = reply
    Map.put(context, :reply, reply)
  end

  step "{string} is no longer listed for {string}", %{args: [project, _environment]} = context do
    id = World.project(context, project).id
    World.await_row(id, &(&1["deletedAt"] != nil))

    refute Enum.any?(HalC2.Shell.rows(), fn
             {{_node, ^id}, {"project", row}} -> row["deletedAt"] == nil
             _ -> false
           end)

    context
  end

  step "{string} still exists on disk", %{args: [path]} = context do
    assert File.exists?(Path.join(Host.path(context, path), "README.md"))
    context
  end

  step "a client renames an unknown project", context do
    {reply, context} =
      call(context, %{"type" => "project.update", "projectId" => "missing", "title" => "Missing"})

    Map.put(context, :reply, reply)
  end

  # --- automatic pull ----------------------------------------------------------------

  step "{string} has automatic pull on", %{args: [project]} = context do
    auto_pull(context, project, true)
  end

  step "automatic pull was never turned on for {string}", %{args: [project]} = context do
    Node.ensure(HalC2.Settings)
    refute HalC2.Settings.for_project(World.project(context, project).id)["defaultAutoPull"]
    context
  end

  step "{string} is a clean checkout of its default branch that is behind its upstream",
       %{args: [project]} = context do
    behind(context, project)
  end

  step "{string} is a clean checkout behind its upstream", %{args: [project]} = context do
    behind(context, project)
  end

  step "{string} has uncommitted changes", %{args: [project]} = context do
    context = behind(context, project)
    File.write!(Path.join(World.project(context, project).root, "README.md"), "edited\n")
    context
  end

  step "{string} is on a branch other than its default", %{args: [project]} = context do
    context = behind(context, project)

    World.git!(
      World.project(context, project).root,
      ~w(checkout -q -b feature --track origin/main)
    )

    context
  end

  step "{string} has no upstream", %{args: [project]} = context do
    context = behind(context, project)
    World.git!(World.project(context, project).root, ~w(branch --unset-upstream))
    context
  end

  step "{string} has commits its upstream does not have", %{args: [project]} = context do
    context = behind(context, project)
    commit(World.project(context, project).root, "local")
    context
  end

  step "{string} is fast-forwarded to its upstream", %{args: [project]} = context do
    assert head(World.project(context, project).root) == context.upstream_head
    context
  end

  step "{string} is not pulled", %{args: [project]} = context do
    root = World.project(context, project).root
    refute head(root) == context.upstream_head
    # 1 when HEAD does not contain it, 128 when the commit was never even fetched.
    assert {_, status} =
             System.cmd("git", ["merge-base", "--is-ancestor", context.upstream_head, "HEAD"],
               cd: root
             )

    assert status in [1, 128]
    context
  end

  step "the node starts normally", context do
    client = World.client(context)
    client = HalC2.Test.WsClient.send_json(client, %{"t" => "ping"})
    {%{"t" => "pong"}, client} = HalC2.Test.WsClient.recv(client, 1_000)
    assert World.await_row(World.project(context).id, & &1)
    World.put_client(context, client)
  end

  defp auto_pull(context, project, on) do
    Node.ensure(HalC2.Settings)
    Node.ensure({Registry, keys: :unique, name: HalC2.Vcs.Registry})
    {settings, version} = HalC2.Settings.get()
    id = World.project(context, project).id

    overrides =
      Map.put(settings["projectSettingsOverrides"] || %{}, id, %{"defaultAutoPull" => on})

    {:ok, _} = HalC2.Settings.put(Map.put(settings, "projectSettingsOverrides", overrides), version)
    context
  end

  # The checkout becomes a clone of a new origin that someone else pushed to since.
  defp behind(context, project) do
    Node.ensure(HalC2.Settings)
    Node.ensure({Registry, keys: :unique, name: HalC2.Vcs.Registry})
    root = World.project(context, project).root
    origin = Node.tmp_dir(context.node, "origin.git")
    other = Node.tmp_dir(context.node, "other")
    File.rm_rf!(origin)
    World.git!(Path.dirname(origin), ["clone", "-q", "--bare", root, origin])
    File.rm_rf!(root)
    World.git!(Path.dirname(root), ["clone", "-q", origin, root])
    File.rm_rf!(other)
    World.git!(Path.dirname(other), ["clone", "-q", origin, other])
    commit(other, "upstream")
    World.git!(other, ~w(push -q origin main))
    Map.put(context, :upstream_head, head(other))
  end

  defp commit(root, message) do
    File.write!(Path.join(root, "#{message}.txt"), message)
    World.git!(root, ~w(add .))

    World.git!(root, [
      "-c",
      "user.name=HAL-C2",
      "-c",
      "user.email=hal-c2@example.com",
      "commit",
      "-q",
      "-m",
      message
    ])
  end

  defp head(root), do: World.git!(root, ~w(rev-parse HEAD))

  defp mutate(context, project, fields) do
    HalC2.Projects.mutate(
      Map.merge(
        %{"type" => "project.update", "projectId" => World.project(context, project).id},
        fields
      )
    )
  end

  defp call(context, mutation), do: World.call(context, "projects.mutate", mutation)
end
