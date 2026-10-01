defmodule HalC2.Steps.Files.ProjectScriptsAndActions do
  @moduledoc """
  Steps for `features/files/project-scripts-and-actions.feature`: a project's actions,
  and the setup script a new worktree runs before (or alongside) the agent.

  `bun` is a fake on PATH that records where it ran, exits with `context.bun_exit`,
  and, when `context.bun_holds`, waits for a line on its terminal first. The agent
  is the fake Codex app server. Setup progress arrives as `HalC2.WorktreeSetup`
  snapshots, kept in order under `context.setup_snapshots`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @fake_codex Path.expand("../../support/fake_codex.py", __DIR__)

  # --- actions -----------------------------------------------------------------------

  step "{string} has the action {string} running {string}",
       %{args: [project, name, command]} = context do
    put_script(context, project, script(name, command, %{"runOnWorktreeCreate" => false}))
  end

  step "{string} has the setup action {string} running {string}",
       %{args: [project, name, command]} = context do
    put_script(context, project, script(name, command, %{"runOnWorktreeCreate" => true}))
  end

  step "{string} waits for it to finish", %{args: [name]} = context do
    update_script(context, name, &Map.put(&1, "async", false))
  end

  step "{string} runs alongside the agent", %{args: [name]} = context do
    context
    |> update_script(name, &Map.put(&1, "async", true))
    |> Map.put(:bun_holds, true)
  end

  step "{string} exits with {int}", %{args: ["bun " <> _, code]} = context do
    Map.put(context, :bun_exit, code)
  end

  step "{string} has no setup action", %{args: [project]} = context do
    scripts = Enum.reject(context.scripts, & &1["runOnWorktreeCreate"])
    context |> Map.put(:scripts, scripts) |> save_scripts(project)
  end

  # --- a thread on a new worktree ----------------------------------------------------

  step "a thread in {string} starts on a new worktree", %{args: [project]} = context do
    context = setup_services(context)
    thread_id = "th-setup-#{System.unique_integer([:positive])}"
    HalC2.WorktreeSetup.subscribe(thread_id, self())
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {_result, context} =
      World.call!(context, "orchestration.launchThread", %{
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "projectId" => World.project(context, project).id,
        "title" => "Work",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "worktree", "baseRef" => "main"},
        "initialMessage" => %{
          "messageId" => "m1",
          "text" => "list the files",
          "attachments" => []
        }
      })

    Map.merge(context, %{setup_thread: thread_id, setup_snapshots: []})
  end

  step "{string} runs in the new worktree's setup terminal", %{args: [command]} = context do
    {context, snapshot} = await_snapshot(context, &(stage(&1, "setup-script") in ~w(done failed)))

    assert %{"command" => ^command, "terminalId" => "setup"} = snapshot["setupScript"]
    assert [_] = Registry.lookup(HalC2.Terminal.Registry, {context.setup_thread, "setup"})

    ran_in = context.bun_log |> Path.join("install.cwd") |> File.read!() |> String.trim()
    assert real(ran_in) == real(snapshot["worktreePath"])
    context
  end

  step "the agent starts after {string} exits", %{args: [_command]} = context do
    {context, _} = await_snapshot(context, &(&1["phase"] == "done"))

    first = Enum.find(context.setup_snapshots, &(stage(&1, "agent") != "pending"))

    assert stage(first, "setup-script") == "done",
           "the agent started while setup was #{stage(first, "setup-script")}"

    agent_ran(context)
  end

  step "the agent starts while {string} is still running", %{args: [_command]} = context do
    {context, snapshot} = await_snapshot(context, &(stage(&1, "agent") == "done"))
    assert stage(snapshot, "setup-script") == "running"
    context = agent_ran(context)

    # Lets the held `bun install` finish.
    {:ok, _} =
      HalC2.Terminal.write(%{
        "threadId" => context.setup_thread,
        "terminalId" => "setup",
        "data" => "\r"
      })

    context
  end

  step "the setup reports how the script exited", context do
    {context, snapshot} = await_snapshot(context, &(&1["phase"] == "done"))

    assert %{"status" => "done", "detail" => "exited with 0"} =
             Enum.find(snapshot["stages"], &(&1["id"] == "setup-script"))

    context
  end

  step "the worktree setup fails with {string}", %{args: [message]} = context do
    {context, snapshot} = await_snapshot(context, &(&1["phase"] in ~w(done failed)))
    assert %{"phase" => "failed", "error" => ^message} = snapshot
    context
  end

  step "the setup script step is skipped", context do
    {context, snapshot} = await_snapshot(context, &(&1["phase"] == "done"))
    assert stage(snapshot, "setup-script") == "skipped"
    assert snapshot["setupScript"] == nil
    context
  end

  step "the agent starts", context do
    {context, snapshot} = await_snapshot(context, &(&1["phase"] in ~w(done failed)))
    assert stage(snapshot, "agent") == "done"
    agent_ran(context)
  end

  # --- helpers -----------------------------------------------------------------------

  defp script(name, command, fields) do
    Map.merge(
      %{"id" => World.slug(name), "name" => name, "command" => command, "icon" => "play"},
      fields
    )
  end

  defp put_script(context, project, script) do
    scripts = Enum.reject(context[:scripts] || [], &(&1["id"] == script["id"])) ++ [script]
    context |> Map.merge(%{scripts: scripts, scripts_project: project}) |> save_scripts(project)
  end

  defp update_script(context, name, fun) do
    assert Enum.any?(context.scripts, &(&1["name"] == name)), "no action #{inspect(name)}"
    scripts = Enum.map(context.scripts, &if(&1["name"] == name, do: fun.(&1), else: &1))
    context |> Map.put(:scripts, scripts) |> save_scripts(context.scripts_project)
  end

  defp save_scripts(context, project) do
    id = World.project(context, project).id

    {_, context} =
      World.call!(context, "projects.mutate", %{
        "type" => "project.update",
        "projectId" => id,
        "scripts" => context.scripts
      })

    expected = context.scripts
    World.await_row(id, &(&1["scripts"] == expected))
    context
  end

  # The services a worktree launch needs, a fake agent, and the fake `bun`.
  defp setup_services(context) do
    Mc.ensure(HalC2.Settings)
    Mc.ensure({Registry, keys: :unique, name: HalC2.Vcs.Registry})
    Mc.ensure(HalC2.Workspace)
    Mc.ensure({Registry, keys: :unique, name: HalC2.Codex.Registry})
    Mc.ensure({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
    context = HalC2.Test.Mc.Terminal.ensure(context)
    Mc.ensure(HalC2.WorktreeSetup)

    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :codex_command) end)

    bin = Mc.tmp_dir(context.mc, "bin")
    log = Mc.tmp_dir(context.mc, "bun-log")

    File.write!(Path.join(bin, "bun"), """
    #!/bin/sh
    pwd > '#{log}'/"$1".cwd
    #{if context[:bun_holds], do: "read _", else: ""}
    exit #{context[:bun_exit] || 0}
    """)

    File.chmod!(Path.join(bin, "bun"), 0o755)
    HalC2.Test.Mc.Terminal.put_env("PATH", bin <> ":" <> System.get_env("PATH", ""))
    Map.put(context, :bun_log, log)
  end

  # The next setup snapshot matching `pred`, keeping every snapshot seen on the way.
  defp await_snapshot(context, pred) do
    thread_id = context.setup_thread

    case Enum.find(context.setup_snapshots, pred) do
      nil ->
        receive do
          {:hal_c2_worktree_setup, ^thread_id, snapshot} ->
            context
            |> Map.update!(:setup_snapshots, &(&1 ++ [snapshot]))
            |> await_snapshot(pred)
        after
          15_000 -> flunk("setup never got there: #{inspect(List.last(context.setup_snapshots))}")
        end

      snapshot ->
        {context, snapshot}
    end
  end

  # The agent's run left `preparing` and its turn completed.
  defp agent_ran(context) do
    thread_id = context.setup_thread
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

    if match?([%{"status" => "completed"}], StreamState.list(state, "run")) do
      context
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> agent_ran(context)
      after
        15_000 ->
          flunk("the agent's run never completed: #{inspect(StreamState.list(state, "run"))}")
      end
    end
  end

  defp stage(snapshot, id), do: Enum.find(snapshot["stages"], &(&1["id"] == id))["status"]

  defp real(path) do
    {out, 0} = System.cmd("realpath", [path])
    String.trim(out)
  end
end
