defmodule HalC2.Steps.Files.ProjectFile do
  @moduledoc """
  Steps for `features/files/project-file.feature`: how deep `vcs.createWorktree`
  fills submodules (the checkout's hal-c2.json against the project's settings), which
  setup script a thread's new worktree runs (`HalC2.WorktreeSetup`, each script writing
  its name to `ran.txt` in the worktree), and the icon hal-c2.json names. The checkout gets a submodule "middle" that has its own
  submodule "inner", each holding a README.md.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  step "the checkout's hal-c2.json asks for {string} submodules", %{args: [mode]} = context do
    context |> submodules() |> commit_hal_c2_json(JSON.encode!(%{"worktreeSubmodules" => mode}))
  end

  step "the checkout's hal-c2.json is not valid JSON", context do
    context |> submodules() |> commit_hal_c2_json("{\"worktreeSubmodules\": ")
  end

  step "the project's settings asks for {string} submodules", %{args: [mode]} = context do
    context |> submodules() |> project_setting(mode)
  end

  step "the project's settings ask for {string} submodules", %{args: [mode]} = context do
    context |> submodules() |> project_setting(mode)
  end

  step "{string} has no hal-c2.json and no submodule setting", %{args: [project]} = context do
    context = submodules(context)
    refute File.exists?(Path.join(World.project(context, project).root, "hal-c2.json"))
    refute HalC2.Settings.for_project(World.project(context, project).id)["worktreeSubmodules"]
    context
  end

  step "a new worktree is created for {string}", %{args: [project]} = context do
    root = World.project(context, project).root
    branch = "hal-c2/worktree-#{System.unique_integer([:positive])}"

    {reply, context} =
      World.call(context, "vcs.createWorktree", %{
        "cwd" => root,
        "refName" => "main",
        "newRefName" => branch
      })

    assert {:ok, %{"worktree" => %{"path" => path}}} = reply
    Map.put(context, :worktree, path)
  end

  step "its submodules are filled one level deep", context do
    assert filled?(context, "middle")
    refute filled?(context, "middle/inner")
    context
  end

  step "its submodules are filled not at all", context do
    refute filled?(context, "middle")
    context
  end

  step "its submodules are filled at every level", context do
    assert filled?(context, "middle")
    assert filled?(context, "middle/inner")
    context
  end

  # --- the setup script -----------------------------------------------------------------

  step "the checkout's hal-c2.json marks {string} to run on new worktrees",
       %{args: [name]} = context do
    commit_hal_c2_json(context, project_file([setup(name)]))
  end

  step "the checkout's hal-c2.json marks {string} and then {string} to run on new worktrees",
       %{args: [first, second]} = context do
    windows = %{
      setup(second)
      | "command" => "New-Item -ItemType File -Path ran.txt -Value '#{second}'"
    }

    commit_hal_c2_json(context, project_file([setup(first), Map.delete(windows, "async")]))
  end

  step "the checkout's hal-c2.json marks {string} to run on new worktrees with an unknown icon",
       %{args: [name]} = context do
    context
    |> World.capture_log()
    |> commit_hal_c2_json(project_file([Map.put(setup(name), "icon", "rocket")]))
  end

  step "the project folder of {string} has an uncommitted hal-c2.json marking {string} to run on new worktrees",
       %{args: [project, name]} = context do
    File.write!(
      Path.join(World.project(context, project).root, "hal-c2.json"),
      project_file([setup(name)])
    )

    context
  end

  step "{string} has no saved actions", %{args: [project]} = context do
    World.await_row(World.project(context, project).id, &(&1["scripts"] in [nil, []]))
    context
  end

  step "{string} has the saved action {string} marked to run on new worktrees",
       %{args: [project, name]} = context do
    id = World.project(context, project).id
    scripts = [Map.put(setup(name), "id", World.slug(name))]

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => id,
        "scripts" => scripts
      })

    World.await_row(id, &(&1["scripts"] == scripts))
    context
  end

  step "a thread starts in a new worktree of {string}", %{args: [project]} = context do
    context |> World.agents() |> World.launch_in_worktree(project)
  end

  step "{string} runs in the new worktree", %{args: [name]} = context do
    {snapshot, context} = setup_done(context)
    assert World.setup_stage(snapshot, "setup-script") == "done"
    assert %{"name" => ^name} = snapshot["setupScript"]
    assert File.read!(Path.join(snapshot["worktreePath"], "ran.txt")) == name <> "\n"
    context
  end

  step "the new worktree runs no setup script", context do
    {snapshot, context} = setup_done(context)
    assert World.setup_stage(snapshot, "setup-script") == "skipped"
    assert World.setup_stage(snapshot, "agent") == "done"
    refute File.exists?(Path.join(snapshot["worktreePath"], "ran.txt"))
    context
  end

  step "a warning is logged that the project file was ignored", context do
    assert World.logged(context) =~ "ignoring the project file in"
    context
  end

  # --- the icon ------------------------------------------------------------------------

  step "the checkout's hal-c2.json names {string} as its icon", %{args: [icon]} = context do
    root = World.project(context).root
    File.write!(Path.join(root, "hal-c2.json"), JSON.encode!(%{"iconPath" => icon}))

    write(
      root,
      icon,
      ~s(<svg xmlns="http://www.w3.org/2000/svg"><rect width="4" height="4"/></svg>\n)
    )

    context
  end

  step "the checkout also has {string}", %{args: [file]} = context do
    write(World.project(context).root, file, <<0, 0, 1, 0, 1, 0>>)
    context
  end

  step "{string} is served", %{args: [file]} = context do
    assert {200, body} = context.icon
    assert body == File.read!(Path.join(World.project(context).root, file))
    context
  end

  # --- helpers -------------------------------------------------------------------------

  defp submodules(%{submodules: true} = context), do: context

  defp submodules(context) do
    Mc.ensure(HalC2.Settings)
    Mc.ensure({Registry, keys: :unique, name: HalC2.Vcs.Registry})
    allow_file_submodules()
    inner = World.git_repo(context, "inner")
    middle = World.git_repo(context, "middle")
    add_submodule(middle, inner, "inner")
    add_submodule(World.project(context).root, middle, "middle")
    Map.put(context, :submodules, true)
  end

  # Local submodules need the file protocol, for the MC's git as much as ours.
  defp allow_file_submodules do
    previous =
      for key <- ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0),
          do: {key, System.get_env(key)}

    System.put_env(%{
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "protocol.file.allow",
      "GIT_CONFIG_VALUE_0" => "always"
    })

    ExUnit.Callbacks.on_exit(fn ->
      for {key, value} <- previous,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))
    end)
  end

  defp add_submodule(root, url, path) do
    World.git!(root, ["submodule", "add", "-q", url, path])
    World.git!(root, ["commit", "-q", "-m", "add #{path}"])
  end

  defp commit_hal_c2_json(context, text) do
    root = World.project(context).root
    File.write!(Path.join(root, "hal-c2.json"), text)
    World.git!(root, ~w(add hal-c2.json))
    World.git!(root, ~w(commit -q -m hal-c2.json))
    context
  end

  defp project_file(scripts), do: JSON.encode!(%{"scripts" => scripts})

  # A script that blocks the agent until it has written its name to ran.txt.
  defp setup(name),
    do: %{
      "name" => name,
      "command" => "echo '#{name}' > ran.txt",
      "icon" => "configure",
      "runOnWorktreeCreate" => true,
      "async" => false
    }

  defp setup_done(context), do: World.await_setup(context, &(&1["phase"] != "running"))

  defp project_setting(context, mode) do
    {settings, version} = HalC2.Settings.get()
    id = World.project(context).id

    overrides =
      Map.put(settings["projectSettingsOverrides"] || %{}, id, %{"worktreeSubmodules" => mode})

    {:ok, _} =
      HalC2.Settings.put(Map.put(settings, "projectSettingsOverrides", overrides), version)

    context
  end

  defp filled?(context, path), do: File.exists?(Path.join([context.worktree, path, "README.md"]))

  defp write(root, file, contents) do
    path = Path.join(root, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
