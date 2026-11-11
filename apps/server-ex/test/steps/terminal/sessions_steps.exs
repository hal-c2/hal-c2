defmodule HalC2.Steps.Terminal.Sessions do
  @moduledoc """
  Steps for `features/terminal/sessions.feature`, plus the terminal steps the
  other `features/terminal/` files share (opening, a shell starting somewhere).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.{Terminal, World}

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

  # --- the MC starts a shell where the thread works --------------------------------------

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

    # A real shell reads the user's rc files, and fish writes its history.
    Terminal.put_env("HOME", context.mc.home)
    Terminal.put_env("SHELL", shell)
    context
  end

  step "the user's login shell is not set", context do
    context = Terminal.ensure(context)
    Terminal.put_env("SHELL", nil)
    if File.exists?("/bin/zsh"), do: context, else: stand_in_zsh(context)
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
    # Once something has printed, the shell is the program running under the PTY. Not
    # by typing at it: fish throws away what is typed while it starts.
    {seen, context} =
      Terminal.attach!(context, "seen", Map.take(context.terminal, ["threadId", "terminalId"]))

    context =
      if seen["history"] == "" do
        {_, _, context} = Terminal.await_output(context, "default", &(&1 != ""))
        context
      else
        context
      end

    assert Terminal.comm(context.snapshot["pid"]) == shell
    context
  end

  step "the shell sees TERM {string} and COLORTERM {string}",
       %{args: [term, colorterm]} = context do
    {output, context} = Terminal.run(context, "default", ~s(echo "[$TERM|$COLORTERM]"))
    assert output =~ "[#{term}|#{colorterm}]"
    context
  end

  step ~r/^the MC runs with (?:any variable starting with )?(\w+) set$/,
       %{args: [variable]} = context do
    name = if String.ends_with?(variable, "_"), do: variable <> "W4_PROBE", else: variable
    Terminal.put_env(name, "from-the-mc")
    Map.put(context, :mc_variable, name)
  end

  step ~r/^the shell does not see (?:any variable starting with )?(\w+)$/, context do
    name = context.mc_variable
    {output, context} = Terminal.run(context, "default", "env | cut -d= -f1 | sort")
    names = output |> String.split(~r/\r?\n/) |> Enum.map(&String.trim/1)
    # The shell does see the rest of the MC's environment.
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
    refute context.snapshot["history"] =~ (context[:old_output] || "first-shell")
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
    Mc.ensure(HalC2.Settings)

    for registry <- [
          HalC2.Codex.Registry,
          HalC2.Claude.Registry,
          HalC2.Acp.Registry,
          HalC2.Vcs.Registry
        ],
        do: Mc.ensure({Registry, keys: :unique, name: registry})

    Application.put_env(:hal_c2, :storage_cleanup_first_ms, nil)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :storage_cleanup_first_ms) end)
    Mc.ensure(HalC2.StorageCleanup)

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

    # A real bash reads the user's rc files, which can do anything to what is typed.
    Terminal.put_env("HOME", context.mc.home)
    Application.put_env(:hal_c2, :terminal_shells, shells)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :terminal_shells) end)
    context
  end

  # Not installed here (the CI runners lack it): a zsh in the common shells' place that
  # answers to the name. A script, since the MC hands zsh options sh would reject.
  defp stand_in_zsh(context) do
    context = fallback_shells(context, ["/bin/zsh"])
    path = Terminal.folder(context, "/bin/zsh")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s(#!/bin/sh\necho stand-in-zsh\nread _\n))
    File.chmod!(path, 0o755)
    context
  end

  defp reopen(context, change) do
    {snapshot, context} = Terminal.open!(context, change, "second")
    Map.put(context, :snapshot, snapshot)
  end

  # --- zsh ------------------------------------------------------------------------------------

  step "the user's shell is zsh", context do
    context = Terminal.ensure(context)
    path = Path.join(context.mc.home, "zsh")
    File.write!(path, ~s(#!/bin/sh\nprintf 'zsh-args:%s\\n' "$*"\nread _\n))
    File.chmod!(path, 0o755)
    Terminal.put_env("SHELL", path)
    context
  end

  step "the shell is started with zsh's partial-line marker turned off", context do
    {snapshot, context} =
      Terminal.attach!(context, "later", Map.take(context.terminal, ["threadId", "terminalId"]))

    if snapshot["history"] =~ "-o nopromptsp" do
      context
    else
      {_, _, context} = Terminal.await_output(context, "later", "-o nopromptsp")
      context
    end
  end

  # --- started from an AppImage ---------------------------------------------------------------

  step "the MC was started from an AppImage with APPIMAGE, APPDIR, ARGV0 and OWD set", context do
    context = Terminal.ensure(context)
    Terminal.put_env("APPIMAGE", "/home/me/HAL-C2.AppImage")
    Terminal.put_env("APPDIR", "/tmp/.mount_hal-c2/")
    Terminal.put_env("ARGV0", "HAL-C2.AppImage")
    Terminal.put_env("OWD", "/home/me")
    context
  end

  step "PATH holds {string} and {string}", %{args: [mount, kept]} = context do
    Terminal.put_env("PATH", "#{mount}:#{kept}")
    context
  end

  step "the shell sees none of APPIMAGE, APPDIR, ARGV0 or OWD", context do
    {output, context} =
      Terminal.run(context, "default", ~s(echo "<$APPIMAGE$APPDIR$ARGV0$OWD>"))

    assert output =~ "<>"
    context
  end

  step ~r/^the shell sees PATH as "(?<path>[^"]+)"$/, %{args: [path]} = context do
    {output, context} = Terminal.run(context, "default", ~s(echo "<$PATH>"))
    assert output =~ "<#{path}>"
    context
  end

  step "the MC was started from an AppImage mounted at {string}", %{args: [mount]} = context do
    context = Terminal.ensure(context)
    Terminal.put_env("APPIMAGE", "/home/me/HAL-C2.AppImage")
    Terminal.put_env("APPDIR", mount)
    context
  end

  step ~r/^(?<variable>\w+) holds only entries under "(?<mount>[^"]+)"$/,
       %{args: [variable, mount]} = context do
    Terminal.put_env(variable, "#{mount}/usr/one:#{mount}/usr/two")
    Map.put(context, :mc_variable, variable)
  end

  step "the MC was not started from an AppImage", context do
    context = Terminal.ensure(context)
    Terminal.put_env("APPIMAGE", nil)
    Terminal.put_env("APPDIR", nil)
    context
  end

  step "a variable named {string} is set", %{args: [name]} = context do
    Terminal.put_env(name, "/kept/as/it/is")
    Map.put(context, :mc_variable, name)
  end

  step "the shell sees {string} unchanged", %{args: [name]} = context do
    {output, context} = Terminal.run(context, "default", ~s(echo "<$#{name}>"))
    assert output =~ "</kept/as/it/is>"
    context
  end

  # --- provider instances ---------------------------------------------------------------------

  step "the Codex instance {string} sets the variable {string} to {string}",
       %{args: [id, key, value]} = context do
    context = Terminal.ensure(context)
    put_instance(id, %{"driver" => "codex", "environment" => [variable(key, value)]})
    Map.put(context, :instance_value, value)
  end

  step "the terminal's snapshot does not carry the instance's variables", context do
    refute inspect(context.snapshot) =~ context.instance_value
    context
  end

  step ~r/^the (?<driver>Codex|Claude) instance "(?<id>[^"]+)" has the home folder "(?<home>[^"]+)"$/,
       %{args: [driver, id, home]} = context do
    context = Terminal.ensure(context)
    driver = if driver == "Codex", do: "codex", else: "claudeAgent"
    put_instance(id, %{"driver" => driver, "config" => %{"homePath" => home}})
    Map.put(context, :instance, id)
  end

  step ~r/^the instance also sets (?<key>\w+) to "(?<value>[^"]+)"$/,
       %{args: [key, value]} = context do
    put_instance(context.instance, %{"environment" => [variable(key, value)]})
    context
  end

  step ~r/^the shell sees (?<key>\w+) as the expanded "(?<path>[^"]+)"$/,
       %{args: [key, path]} = context do
    {output, context} = Terminal.run(context, "default", ~s(echo "<$#{key}>"))
    assert output =~ "<#{Path.expand(path)}>"
    context
  end

  step "no provider instance named {string} is configured", %{args: [id]} = context do
    context = Terminal.ensure(context)
    assert get_in(HalC2.Settings.settings(), ["providerInstances", id]) == nil
    Terminal.put_env("CODEX_HOME", nil)
    Terminal.put_env("OWN_TO_THE_MC", "own")
    context
  end

  step "the shell starts with the MC's own environment", context do
    assert context.snapshot["status"] == "running"
    {output, context} = Terminal.run(context, "default", ~s(echo "<$OWN_TO_THE_MC|$CODEX_HOME>"))
    assert output =~ "<own|>"
    context
  end

  step "a terminal running for the provider instance {string} with {string} set to {string}",
       %{args: [id, key, value]} = context do
    context = Terminal.ensure(context)
    put_instance(id, %{"driver" => "codex", "environment" => [variable(key, value)]})
    {snapshot, context} = Terminal.open!(context, %{"providerInstanceId" => id})

    {_, context} =
      Terminal.attach!(context, "default", Map.take(context.terminal, ["threadId", "terminalId"]))

    Map.merge(context, %{snapshot: snapshot, first: snapshot, instance: id})
  end

  step "the instance now sets {string} to {string}", %{args: [key, value]} = context do
    put_instance(context.instance, %{"environment" => [variable(key, value)]})
    context
  end

  step "a client opens the terminal again", context do
    reopen(context, %{})
  end

  step "the new shell sees {string} as {string}", %{args: [key, value]} = context do
    {output, context} = Terminal.run(context, "default", ~s(echo "<$#{key}>"))
    assert output =~ "<#{value}>"
    context
  end

  # --- opening an ended shell -----------------------------------------------------------------

  step "the thread's default terminal printed {string} and its shell has exited",
       %{args: [text]} = context do
    context = Terminal.exited(context, text)
    Map.put(context, :old_output, text)
  end

  step "a client opens it again in the same folder", context do
    reopen(context, %{})
  end

  step "a new shell is running", context do
    assert %{"status" => "running", "pid" => pid, "exitCode" => nil} = context.snapshot
    assert File.exists?("/proc/#{pid}")
    context
  end

  step "the terminal reports that it restarted", context do
    {event, context} = Terminal.await_event(context, "default", &(&1["type"] == "restarted"))
    assert event["snapshot"]["pid"] == context.snapshot["pid"]
    context
  end

  step "the thread's default terminal runs on the worktree {string} and its shell has exited",
       %{args: [path]} = context do
    context = Terminal.ensure(context)
    worktree = Terminal.mkdir(context, path)

    context =
      Terminal.put_input(
        context,
        Terminal.input(context, %{"cwd" => worktree, "worktreePath" => worktree})
      )

    context |> Terminal.exited("on the worktree") |> Map.put(:worktree, worktree)
  end

  step "a client opens it again on that worktree", context do
    reopen(context, %{"cwd" => context.worktree, "worktreePath" => context.worktree})
  end

  step "the new shell's snapshot and its started event name the worktree {string}", context do
    assert context.snapshot["worktreePath"] == context.worktree
    {event, context} = Terminal.await_event(context, "default", &(&1["type"] == "restarted"))
    assert event["snapshot"]["worktreePath"] == context.worktree
    context
  end

  # --- two opens at once ----------------------------------------------------------------------

  step "the thread has no terminal {string} yet", %{args: [terminal]} = context do
    context = Terminal.ensure(context)
    input = Terminal.input(context, %{"terminalId" => terminal})
    assert Registry.lookup(HalC2.Terminal.Registry, {input["threadId"], terminal}) == []
    context
  end

  step "two clients open {string} at the same moment", %{args: [terminal]} = context do
    context = Terminal.ensure(context)
    input = Terminal.input(context, %{"terminalId" => terminal})

    # Both are connected before either sends.
    context =
      for name <- ~w(first second), reduce: context do
        context -> World.put_client(context, name, World.client(context, name))
      end

    {context, ids} =
      for name <- ~w(first second), reduce: {context, %{}} do
        {context, ids} ->
          id = System.unique_integer([:positive])

          client =
            Mc.rpc(
              World.client(context, name),
              context.mc.environment,
              id,
              "terminal.open",
              input
            )

          {World.put_client(context, name, client), Map.put(ids, name, id)}
      end

    {context, replies} =
      for {name, id} <- ids, reduce: {context, []} do
        {context, replies} ->
          {frame, client} = Mc.await(World.client(context, name), Mc.reply?(id), 5_000)
          {World.put_client(context, name, client), [frame["result"] | replies]}
      end

    context |> Terminal.put_input(input) |> Map.put(:open_replies, replies)
  end

  step "exactly one shell is started", context do
    assert [one] = context.open_replies |> Enum.map(& &1["pid"]) |> Enum.uniq()
    assert is_integer(one)
    %{"threadId" => thread, "terminalId" => terminal} = context.terminal
    assert [{_, _}] = Registry.lookup(HalC2.Terminal.Registry, {thread, terminal})
    Map.put(context, :one_shell, one)
  end

  step "both clients are told about that shell", context do
    assert [%{"status" => "running"}, %{"status" => "running"}] = context.open_replies
    assert File.exists?("/proc/#{context.one_shell}")
    context
  end

  # --- a long label ---------------------------------------------------------------------------

  step "a client opens a terminal whose id is {int} characters long",
       %{args: [length]} = context do
    {snapshot, context} =
      Terminal.open!(context, %{"terminalId" => String.duplicate("x", length)})

    Map.put(context, :snapshot, snapshot)
  end

  step "the terminal is labelled with the first {int} characters of its id",
       %{args: [length]} = context do
    assert context.snapshot["label"] == String.slice(context.terminal["terminalId"], 0, length)
    context
  end

  defp put_instance(id, instance),
    do: World.merge_settings(%{"providerInstances" => %{id => instance}})

  defp variable(key, value), do: %{"name" => key, "value" => value}
end
