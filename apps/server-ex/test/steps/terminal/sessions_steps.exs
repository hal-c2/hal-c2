defmodule HalC2.Steps.Terminal.Sessions do
  @moduledoc """
  Steps for `features/terminal/sessions.feature`, plus the terminal steps the
  other `features/terminal/` files share (opening, a shell starting somewhere).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.{Terminal, World}

  # --- shared by features/terminal/ ------------------------------------------------------

  step "a shell starts in {string}", %{args: [path]} = context do
    assert_shell_in(context, path)
  end

  step "a terminal opens", context do
    {snapshot, context} = Terminal.open!(context)
    {_, context} = Terminal.attach!(context, "default")
    Map.put(context, :snapshot, snapshot)
  end

  step "a client opens a terminal", context do
    context = Terminal.ensure(context)
    input = Terminal.input(context)
    {_, context} = Terminal.attach(context, "default", input)
    Terminal.put_input(context, input)
  end

  # --- the node starts a shell where the thread works --------------------------------------

  step "a thread whose project lives in {string}", %{args: [path]} = context do
    root = Terminal.mkdir(context, path)

    context =
      context
      |> Terminal.ensure()
      |> World.create_project("app", %{"workspaceRoot" => root})
      |> World.create_thread("Build", "app")

    Terminal.put_input(context, %{
      "threadId" => World.thread_id(context, "Build"),
      "terminalId" => "term-1",
      "cwd" => root
    })
  end

  step "a client opens the thread's default terminal in {string}", %{args: [path]} = context do
    {snapshot, context} = Terminal.open!(context, %{"cwd" => Terminal.folder(context, path)})
    Map.put(context, :snapshot, snapshot)
  end

  step "a shell is running in {string}", %{args: [path]} = context do
    assert_shell_in(context, path)
  end

  step "the terminal reports that it started", context do
    assert %{"status" => "running", "pid" => pid} = context.snapshot
    assert is_integer(pid)
    %{"threadId" => thread, "terminalId" => terminal} = context.terminal

    assert Enum.any?(
             HalC2.Terminal.Hub.summaries(),
             &match?(
               %{"threadId" => ^thread, "terminalId" => ^terminal, "status" => "running"},
               &1
             )
           )

    context
  end

  step "a thread working in the worktree {string}", %{args: [path]} = context do
    worktree = Terminal.mkdir(context, path)

    context
    |> Terminal.ensure()
    |> World.create_project("app")
    |> World.create_thread("Feature", "app", %{
      "branch" => "feature",
      "worktreePath" => worktree
    })
  end

  # A client opens a thread's terminal in the thread's worktree, and says so.
  step "a client opens a terminal for that thread", context do
    thread = World.thread(context, "Feature")

    input = %{
      "threadId" => thread["id"],
      "terminalId" => "term-1",
      "cwd" => thread["worktreePath"],
      "worktreePath" => thread["worktreePath"]
    }

    {snapshot, context} = Terminal.open!(Terminal.put_input(context, input))
    Map.put(context, :snapshot, snapshot)
  end

  step "the shell starts in {string}", %{args: [path]} = context do
    assert_shell_in(context, path)
  end

  step "the terminal remembers which worktree it belongs to", context do
    worktree = context.terminal["worktreePath"]
    assert context.snapshot["worktreePath"] == worktree
    # A client attaching later is told too.
    {snapshot, context} = Terminal.attach!(context, "later", Map.delete(context.terminal, "cwd"))
    assert snapshot["worktreePath"] == worktree
    context
  end

  step "a client opens a terminal without a size", context do
    {snapshot, context} = Terminal.open!(context)
    refute Map.has_key?(context.terminal, "cols")
    {_, context} = Terminal.attach!(context, "default", Map.delete(context.terminal, "cwd"))
    Map.put(context, :snapshot, snapshot)
  end

  step "the shell sees a window of {int} columns and {int} rows",
       %{args: [cols, rows]} = context do
    {output, context} = Terminal.run(context, "default", "stty size")
    assert output =~ ~r/(^|[\r\n])#{rows} #{cols}\r?\n/
    context
  end

  step "the user's login shell is {string}", %{args: [path]} = context do
    context = Terminal.ensure(context)

    shell =
      if File.exists?(path) do
        path
      else
        # Not installed here: a shell that answers to that name does.
        fake = Terminal.folder(context, path)
        File.mkdir_p!(Path.dirname(fake))
        File.ln_s!("/bin/sh", fake)
        fake
      end

    Terminal.put_env("SHELL", shell)
    context
  end

  step "the user's login shell is not set", context do
    context = Terminal.ensure(context)
    Terminal.put_env("SHELL", nil)
    context
  end

  step "the user's login shell is not set, no zsh", context do
    context = Terminal.ensure(context)
    Terminal.put_env("SHELL", nil)
    fallback_shells(context, ["/bin/zsh"])
  end

  step "the user's login shell is not set, no bash", context do
    context = Terminal.ensure(context)
    Terminal.put_env("SHELL", nil)
    fallback_shells(context, ["/bin/zsh", "/bin/bash"])
  end

  step "the shell that runs is {string}", %{args: [shell]} = context do
    # Once the shell answers, it is the program running under the PTY.
    {_, context} = Terminal.run(context, "default", "true")
    assert Terminal.comm(context.snapshot["pid"]) == shell
    context
  end

  step "the shell sees TERM {string} and COLORTERM {string}",
       %{args: [term, colorterm]} = context do
    {output, context} = Terminal.run(context, "default", ~s(echo "[$TERM|$COLORTERM]"))
    assert output =~ "[#{term}|#{colorterm}]"
    context
  end

  step ~r/^the node runs with (?:any variable starting with )?(\w+) set$/,
       %{args: [variable]} = context do
    name = if String.ends_with?(variable, "_"), do: variable <> "W4_PROBE", else: variable
    Terminal.put_env(name, "from-the-node")
    Map.put(context, :node_variable, name)
  end

  step ~r/^the shell does not see (?:any variable starting with )?(\w+)$/, context do
    name = context.node_variable
    {output, context} = Terminal.run(context, "default", "env | cut -d= -f1 | sort")
    names = output |> String.split(~r/\r?\n/) |> Enum.map(&String.trim/1)
    # The shell does see the rest of the node's environment.
    assert "HOME" in names
    refute name in names
    context
  end

  step "a client opens a terminal with the variable {string} set to {string}",
       %{args: [key, value]} = context do
    {snapshot, context} = Terminal.open!(context, %{"env" => %{key => value}})
    {_, context} = Terminal.attach!(context, "default", Map.delete(context.terminal, "cwd"))
    Map.put(context, :snapshot, snapshot)
  end

  step "the shell sees {string} as {string}", %{args: [key, value]} = context do
    {output, context} = Terminal.run(context, "default", ~s(echo "<$#{key}>"))
    assert output =~ "<#{value}>"
    context
  end

  step "the thread's default terminal is running in {string}", %{args: [path]} = context do
    context = Terminal.put_input(context, Terminal.input(Terminal.ensure(context)))
    {snapshot, context} = Terminal.open!(context, %{"cwd" => Terminal.mkdir(context, path)})
    {_, context} = Terminal.attach!(context, "default", Map.delete(context.terminal, "cwd"))
    # Something in the scrollback, to tell a fresh shell from this one.
    {_, context} = Terminal.run(context, "default", "echo first-shell")
    Map.merge(context, %{snapshot: snapshot, first: snapshot})
  end

  step "a client opens it again in {string} at {int} columns and {int} rows",
       %{args: [path, cols, rows]} = context do
    {snapshot, context} =
      Terminal.open!(
        context,
        %{"cwd" => Terminal.folder(context, path), "cols" => cols, "rows" => rows},
        "second"
      )

    Map.put(context, :snapshot, snapshot)
  end

  step "the same shell keeps running", context do
    assert context.snapshot["pid"] == context.first["pid"]
    assert context.snapshot["status"] == "running"
    assert context.snapshot["history"] =~ "first-shell"
    context
  end

  step "its window becomes {int} columns and {int} rows", %{args: [cols, rows]} = context do
    {output, context} = Terminal.run(context, "default", "stty size")
    assert output =~ ~r/(^|[\r\n])#{rows} #{cols}\r?\n/
    context
  end

  step "a client opens it again with the folder {string}", %{args: [path]} = context do
    reopen(context, %{"cwd" => Terminal.mkdir(context, path)})
  end

  step "a client opens it again with a different worktree", context do
    reopen(context, %{"worktreePath" => Terminal.mkdir(context, "/work/app-other")})
  end

  step "a client opens it again with different extra variables", context do
    reopen(context, %{"env" => %{"APP_ENV" => "other"}})
  end

  step "the old shell is replaced by a new one", context do
    old = context.first["pid"]
    assert context.snapshot["status"] == "running"
    assert is_integer(context.snapshot["pid"]) and context.snapshot["pid"] != old
    # Attached clients are handed the new shell, and the old one ends.
    {event, context} = Terminal.await_event(context, "default", &(&1["type"] == "snapshot"))
    assert event["snapshot"]["pid"] == context.snapshot["pid"]
    Terminal.await_exit(old)
    context
  end

  step "the scrollback starts empty", context do
    refute context.snapshot["history"] =~ "first-shell"
    context
  end

  # "default" is the thread's default terminal, `term-1` on the wire.
  step "a client opens the terminal {string}", %{args: [id]} = context do
    id = if id == "default", do: "term-1", else: id
    {snapshot, context} = Terminal.open!(context, %{"terminalId" => id})
    Map.put(context, :snapshot, snapshot)
  end

  step "the terminal is labelled {string}", %{args: [label]} = context do
    assert context.snapshot["label"] == label
    context
  end

  step "a finished thread's worktree has a running terminal", context do
    context = Terminal.ensure(context)
    Node.ensure(HalC2.Settings)

    for registry <- [
          HalC2.Codex.Registry,
          HalC2.Claude.Registry,
          HalC2.Acp.Registry,
          HalC2.Vcs.Registry
        ],
        do: Node.ensure({Registry, keys: :unique, name: registry})

    Application.put_env(:hal_c2, :storage_cleanup_first_ms, nil)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :storage_cleanup_first_ms) end)
    Node.ensure(HalC2.StorageCleanup)

    # Worktrees go after a day idle; this thread has been idle since January.
    {_, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(%{"storageCleanup" => %{"worktreeAfterDays" => 1}}, version)

    context = World.create_project(context, "app")
    repo = World.project(context, "app").root

    {:ok, %{"worktree" => %{"path" => path}}} =
      HalC2.Vcs.create_worktree(%{
        "cwd" => repo,
        "refName" => "main",
        "newRefName" => "hal-c2/done"
      })

    context =
      World.create_thread(context, "Done", "app", %{
        "branch" => "hal-c2/done",
        "worktreePath" => path
      })

    context = World.patch_thread(context, "Done", %{"createdAt" => "2026-01-01T00:00:00.000Z"})

    input = %{
      "threadId" => World.thread_id(context, "Done"),
      "terminalId" => "term-1",
      "cwd" => path,
      "worktreePath" => path
    }

    {%{"status" => "running"}, context} = Terminal.open!(Terminal.put_input(context, input))
    Map.put(context, :worktree, path)
  end

  step "storage cleanup looks for worktrees to remove", context do
    :ok = HalC2.StorageCleanup.sweep()
    context
  end

  step "that worktree is kept", context do
    assert File.dir?(context.worktree)
    # It was the terminal that kept it: with the terminal closed, it goes.
    {{:ok, _}, context} = World.call(context, "terminal.close", context.terminal)
    :ok = HalC2.StorageCleanup.sweep()
    refute File.exists?(context.worktree)
    context
  end

  # --- helpers ------------------------------------------------------------------------------

  defp assert_shell_in(context, path) do
    dir = Terminal.folder(context, path)
    assert %{"status" => "running", "pid" => pid, "cwd" => ^dir} = context.snapshot
    assert File.read_link!("/proc/#{pid}/cwd") == dir
    context
  end

  # The machine's common shells, with `missing` ones absent.
  defp fallback_shells(context, missing) do
    shells =
      for shell <- ~w(/bin/zsh /bin/bash /bin/sh),
          do: if(shell in missing, do: Terminal.folder(context, shell), else: shell)

    Application.put_env(:hal_c2, :terminal_shells, shells)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :terminal_shells) end)
    context
  end

  defp reopen(context, change) do
    {snapshot, context} = Terminal.open!(context, change, "second")
    Map.put(context, :snapshot, snapshot)
  end
end
