defmodule HalC2.Steps.Files.FilesOnAnotherMachine do
  @moduledoc """
  Steps for `features/files/files-on-another-machine.feature`.

  This VM is the user's machine ("laptop"); "devbox" is a peer running the whole MC
  (`HalC2.Test.Machines`). "/home/me" in the feature is devbox's user home. This MC
  runs `HalC2.MachineFiles` with the real helper and mounts devbox's folder under its
  state directory; `HalC2.Test.Features` skips the feature, saying why, on a machine
  without FUSE or the helper.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions
  import ExUnit.CaptureLog

  alias HalC2.MachineFiles
  alias HalC2.MachineFiles.Helper
  alias HalC2.Test.{Machines, Mc}
  alias HalC2.Test.Mc.World

  @cart "export const cart = [];\n"

  # --- background ----------------------------------------------------------------------

  # The client connects with its first call, to the MC as the cluster restarted it.
  step("the client is connected to the MC on the user's machine", context, do: context)

  step "that MC is in a cluster with {string}", %{args: [label]} = context do
    context = Machines.cluster(context, "laptop", [label])
    root = MachineFiles.root()
    # Before the scenario's directory is removed: what is under a live mount is devbox's.
    ExUnit.Callbacks.on_exit(fn -> Helper.unmount(root) end)
    # A member that stops answering fails a request in a second, not ten.
    Mc.ensure({MachineFiles, enabled: true, ttl_ms: 0, timeout: 1_000})
    :ok = MachineFiles.await_ready()
    Map.put(context, :machine_files, root)
  end

  step "{string} has the project {string} at {string}",
       %{args: [label, title, path]} = context do
    root = on_machine(context, label, path)
    File.mkdir_p!(Path.join(root, "src"))
    File.write!(Path.join(root, "src/cart.ts"), @cart)

    # What is beside the project, which nothing shares.
    home = Machines.user_home(context, label)
    File.mkdir_p!(Path.join(home, ".ssh"))
    File.write!(Path.join(home, ".ssh/id_ed25519"), "-----BEGIN OPENSSH PRIVATE KEY-----\n")
    File.write!(Path.join(home, "notes.txt"), "private\n")

    id = "project-#{World.slug(title)}"
    Machines.on(context, label, Machines, :create_project, [id, title, root])

    context
    |> put_in([Access.key(:remote_projects, %{}), title], %{machine: label, id: id, root: root})
  end

  # --- where a file is -----------------------------------------------------------------

  step "the client asks its MC where {string} on {string} is on this machine",
       %{args: [path, label]} = context do
    environment = Machines.machine(context, label).environment
    payload = %{"environmentId" => environment, "path" => on_machine(context, label, path)}
    {answer, context} = World.call!(context, "files.localPath", payload)
    Map.merge(context, %{answer: answer, asked: {label, path}})
  end

  step "the answer is a path inside the folder this machine keeps for {string}",
       %{args: [label]} = context do
    {^label, path} = context.asked
    assert %{"path" => local} = context.answer
    assert local == through(context, label, on_machine(context, label, path))
    assert String.starts_with?(local, folder(context, label) <> "/")
    context
  end

  step "reading that path gives the contents of {string} on {string}",
       %{args: [file, label]} = context do
    assert File.read!(context.answer["path"]) == read_on(context, label, "shop", file)
    context
  end

  # --- reading and saving through the folder -------------------------------------------

  step "the user saves {string} of {string} through the folder kept for {string}",
       %{args: [file, project, label]} = context do
    saved = "export const cart = [\"saved here\"];\n"
    File.write!(through(context, label, project_path(context, project, file)), saved)
    Map.put(context, :saved, saved)
  end

  step "{string} on {string} has the saved contents", %{args: [file, label]} = context do
    assert read_on(context, label, "shop", file) == context.saved
    context
  end

  step "the user's editor read {string} of {string} through the folder kept for {string}",
       %{args: [file, project, label]} = context do
    local = through(context, label, project_path(context, project, file))
    assert File.read!(local) == @cart
    Map.put(context, :read_through, {label, local})
  end

  step "the agent on {string} changes {string}", %{args: [label, file]} = context do
    changed = "export const cart = [\"the agent's\"];\n"
    path = project_path(context, "shop", file)
    :ok = Machines.on(context, label, File, :write!, [path, changed])
    Map.put(context, :changed, changed)
  end

  step "reading {string} through the folder again gives the agent's change",
       %{args: [_file]} = context do
    {_label, local} = context.read_through
    assert File.read!(local) == context.changed
    context
  end

  step "the user reads {string} through the folder kept for {string}",
       %{args: [path, label]} = context do
    local = through(context, label, on_machine(context, label, path))
    log = capture_log(fn -> send(self(), {:read, File.read(local)}) end)
    assert_received {:read, read}
    Map.merge(context, %{read: read, log: log})
  end

  step "it is not found", context do
    assert context.read == {:error, :enoent}
    context
  end

  step "a thread of {string} works in the worktree {string}",
       %{args: [project, path]} = context do
    %{machine: label, id: project_id} = context.remote_projects[project]
    worktree = on_machine(context, label, path)
    File.mkdir_p!(Path.join(worktree, "src"))
    File.write!(Path.join(worktree, "src/cart.ts"), "export const cart = [\"worktree\"];\n")
    id = "th-cart-#{System.unique_integer([:positive])}"

    command = %{
      "type" => "thread.create",
      "threadId" => id,
      "projectId" => project_id,
      "title" => "Cart",
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "worktreePath" => worktree,
      "branch" => "cart"
    }

    {:ok, _} = Machines.on(context, label, HalC2.Orchestration, :dispatch, [command])
    Machines.on(context, label, HalC2.Streams, :flush_shell, [id])
    Map.put(context, :worktree, worktree)
  end

  step "it gives the contents of {string} in that worktree", %{args: [file]} = context do
    assert context.read == {:ok, File.read!(Path.join(context.worktree, file))}
    context
  end

  # --- who can open it -----------------------------------------------------------------

  # A test cannot become another user, so this reads what the kernel enforces: FUSE
  # turns away every other user of a mount made without allow_other, and the folder's
  # parent lets only its owner in.
  step "another user of this machine reads the folder kept for {string}",
       %{args: [label]} = context do
    assert File.dir?(folder(context, label))
    Map.put(context, :options, Helper.mount_options(context.machine_files))
  end

  step "it is refused", context do
    {uid, 0} = System.cmd("id", ["-u"])
    assert context.options =~ "user_id=#{String.trim(uid)}"
    refute context.options =~ "allow_other"
    parent = Path.dirname(context.machine_files)
    assert Bitwise.band(File.stat!(parent).mode, 0o077) == 0
    context
  end

  # --- a machine that stops answering or leaves ----------------------------------------

  step "{string} has stopped answering", %{args: [label]} = context do
    os_pid = Machines.on(context, label, :os, :getpid, []) |> List.to_string()
    {_, 0} = System.cmd("kill", ["-STOP", os_pid])
    # Before its peer is stopped, which waits on it.
    ExUnit.Callbacks.on_exit(fn -> System.cmd("kill", ["-CONT", os_pid]) end)
    context
  end

  step "the read fails saying {string} is unavailable", %{args: [label]} = context do
    assert context.read == {:error, :ehostdown}
    assert context.log =~ "#{label} is unavailable"
    context
  end

  step "{string} is removed from the cluster", %{args: [label]} = context do
    assert File.dir?(folder(context, label))
    HalC2.Shell.forget(Machines.machine(context, label).environment)
    :ok = HalC2.Shell.sync()
    :ok = MachineFiles.sync()
    context
  end

  step "this machine no longer keeps a folder for {string}", %{args: [label]} = context do
    refute File.exists?(folder(context, label))
    refute label in File.ls!(context.machine_files)
    environment = Machines.machine(context, label).environment

    assert {:ok, %{"reason" => "not_a_member"}} =
             MachineFiles.handle_rpc(%{"environmentId" => environment, "path" => "/a"})

    context
  end

  # --- helpers -------------------------------------------------------------------------

  # A feature's path as it is on `label`: "/home/me" is that machine's user home.
  defp on_machine(context, label, "/home/me" <> rest),
    do: Machines.user_home(context, label) <> rest

  defp on_machine(_context, _label, path), do: path

  defp folder(context, label), do: Path.join(context.machine_files, label)

  # Where `path` on `label` is on this machine, `..` and all left to the kernel.
  defp through(context, label, path),
    do: Path.join([folder(context, label) | tl(Path.split(path))])

  defp project_path(context, project, file),
    do: Path.join(context.remote_projects[project].root, file)

  defp read_on(context, label, project, file),
    do: Machines.on(context, label, File, :read!, [project_path(context, project, file)])
end
