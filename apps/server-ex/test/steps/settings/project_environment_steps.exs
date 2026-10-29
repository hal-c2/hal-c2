defmodule HalC2.Steps.Settings.ProjectEnvironment do
  @moduledoc """
  Steps for `features/settings/project-environment.feature`. The fake providers
  (`HalC2.Test.Mc.World.fake_providers/2`) write a trace to the file their
  `FAKE_*_TRACE` variable names, which the MC's environment points at the fakes'
  logs. The project's `.env` points those variables at a file of its own instead,
  so the file appearing is the session having had the project's variables, over
  the MC's own.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc.World

  @thread "Work"
  @instances %{
    "Codex" => "codex",
    "Claude" => "claudeAgent",
    "OpenCode" => "opencode",
    "Grok" => "grok",
    "Cursor" => "cursor",
    "Pi" => "pi",
    "Muse Code" => "muse"
  }

  defp choose(context, title, settings) do
    %{id: id} = World.project(context, title)
    World.update_settings(context, %{"projectSettingsOverrides" => %{id => settings}})
  end

  defp trace(context), do: Path.join(context.mc.home, "project-env-trace.jsonl")

  step "{string} loads its environment from {string}", %{args: [title, file]} = context do
    choose(context, title, %{"projectEnvironment" => "dotenv", "projectEnvironmentFile" => file})
  end

  step "{string} loads its environment from mise and direnv", %{args: [title]} = context do
    choose(context, title, %{"projectEnvironment" => "auto"})
  end

  step "the user turns off loading the environment of {string}", %{args: [title]} = context do
    choose(context, title, %{"projectEnvironment" => "off"})
  end

  step "the checkout of {string} declares the session's variables in {string}",
       %{args: [title, file]} = context do
    %{root: root} = World.project(context, title)

    vars =
      for name <- ~w(FAKE_CODEX_TRACE FAKE_CLAUDE_TRACE FAKE_ACP_TRACE),
          do: "#{name}=#{trace(context)}\n"

    # Pi's and Muse's fakes log their FAKE_ variables when they start.
    File.write!(Path.join(root, file), [
      "# the session's variables\n",
      "FAKE_PROJECT_ENV=shop\n" | vars
    ])

    context
  end

  step "the checkout of {string} has no {string}", %{args: [title, file]} = context do
    %{root: root} = World.project(context, title)
    refute File.exists?(Path.join(root, file))
    context
  end

  # direnv's refusal, played by a stand-in: the real one may not be installed, and
  # allowing a file would write to the user's direnv data.
  step "the checkout of {string} has an .envrc direnv has not allowed",
       %{args: [title]} = context do
    %{root: root} = World.project(context, title)
    File.write!(Path.join(root, ".envrc"), "export SOME_URL=https://example.test/mcp\n")
    direnv = Path.join(context.mc.home, "fake-direnv")

    File.write!(direnv, """
    #!/bin/sh
    echo "direnv: error #{root}/.envrc is blocked. Run \\`direnv allow\\` to approve its content" >&2
    exit 1
    """)

    File.chmod!(direnv, 0o755)
    World.put_app_env(:project_environment_commands, %{"direnv" => direnv})
    context
  end

  step ~r/^a (?<provider>Codex|Claude|OpenCode|Grok|Cursor|Pi|Muse Code) thread in "(?<project>[^"]+)" runs a turn$/,
       %{args: [provider, _project]} = context do
    context
    |> fakes(provider)
    |> World.run_turns(@thread, @instances[provider], ["hello"])
  end

  defp fakes(context, "Pi"), do: HalC2.Test.FakeAcp.install_pi(context, %{}, enabled: true)

  defp fakes(context, "Muse Code"),
    do: HalC2.Test.FakeAcp.install_muse(context, %{}, enabled: true)

  defp fakes(context, _provider), do: World.fake_providers(context)

  step ~r/^the (?<provider>Codex|Claude|OpenCode|Grok|Cursor|Pi|Muse Code) session had the project's variables$/,
       %{args: [provider]} = context do
    assert had?(context, provider), "the session did not get the project's variables"
    context
  end

  step ~r/^the (?<provider>Codex|Claude|OpenCode|Grok|Cursor|Pi|Muse Code) session did not have the project's variables$/,
       %{args: [provider]} = context do
    refute had?(context, provider)
    context
  end

  # The scripted fakes log the variables they started with in their log's `start` line.
  defp had?(context, provider) when provider in ["Pi", "Muse Code"] do
    %{dir: dir} = context.fakes[@instances[provider]]

    Path.join(dir, "log.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
    |> Enum.any?(&(get_in(&1, ["start", "env", "FAKE_PROJECT_ENV"]) == "shop"))
  end

  defp had?(context, _provider), do: File.exists?(trace(context))

  step "{string} shows its environment is not loaded", %{args: [title]} = context do
    %{id: id} = World.project(context, title)
    assert HalC2.ProjectEnvironment.source(HalC2.Settings.for_project(id)) == "off"
    context
  end

  step "the session starts anyway and the turn completes", context do
    assert [%{"status" => "completed"}] = World.runs(context, @thread)
    context
  end

  step "the thread shows the project environment was not loaded because {string} was not found",
       %{args: [file]} = context do
    assert notice(context) =~ "#{file} was not found"
    context
  end

  step "the thread shows the project environment was not loaded and to run {string}",
       %{args: [command]} = context do
    assert notice(context) =~ command
    context
  end

  defp notice(context) do
    items = context |> World.stream(@thread) |> StreamState.list("turn-item")

    assert %{"message" => message, "status" => "completed"} =
             Enum.find(
               items,
               &(&1["type"] == "system_notice" and &1["title"] == "Project environment not loaded")
             ),
           "no notice in #{inspect(Enum.map(items, & &1["type"]))}"

    message
  end

  step "the checkout of {string} declares {string} and the provider instance's {string} in {string}",
       %{args: [title, hal_c2, instance, file]} = context do
    %{root: root} = World.project(context, title)

    File.write!(
      Path.join(root, file),
      "#{hal_c2}=http://project.invalid\n#{instance}=/project\nSOME_URL=https://example.test\n"
    )

    Map.put(context, :protected, {hal_c2, instance})
  end

  # The launch environment an adapter builds: the instance's variables and HAL-C2's.
  step "the MC builds the environment of a session in {string}", %{args: [title]} = context do
    %{id: id, root: root} = World.project(context, title)
    {hal_c2, instance} = context.protected
    launch = [{instance, "/instance"}, {hal_c2, "http://mc"}]
    env = HalC2.ProjectEnvironment.for_turn(%{cwd: root, project_id: id}, launch)
    Map.put(context, :session_env, env)
  end

  step "the session keeps HAL-C2's {string} and the instance's {string}",
       %{args: [hal_c2, instance]} = context do
    env = context.session_env
    assert Enum.filter(env, &(elem(&1, 0) == hal_c2)) == [{hal_c2, "http://mc"}]
    assert Enum.filter(env, &(elem(&1, 0) == instance)) == [{instance, "/instance"}]
    assert {"SOME_URL", "https://example.test"} in env
    context
  end
end
