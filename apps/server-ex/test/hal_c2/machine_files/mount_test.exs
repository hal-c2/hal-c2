defmodule HalC2.MachineFiles.MountTest do
  # Mounts a real folder with FUSE and uses the MC-wide named Store and Shell.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HalC2.MachineFiles
  alias HalC2.MachineFiles.{Helper, Session}
  alias HalC2.{Shell, Store}

  case Helper.available() do
    :ok ->
      :ok

    {:error, reason} ->
      @moduletag skip:
                   "needs /dev/fuse, fusermount3 and the helper " <>
                     "(vp run build:machine-files): #{reason}"
  end

  defmodule QuietWire do
    @moduledoc false
    def connected, do: []
    def cast(_peer, _message), do: :ok
  end

  @devbox %{"environmentId" => "env-devbox", "label" => "devbox"}

  setup ctx do
    dir =
      Path.join(System.tmp_dir!(), "hal-c2-machine-files-#{System.unique_integer([:positive])}")

    root = Path.join(dir, "state/machines")
    shop = Path.join(dir, "home/me/shop")
    File.mkdir_p!(Path.join(shop, "src"))
    File.write!(Path.join(shop, "src/cart.ts"), "export const cart = [];\n")
    File.write!(Path.join(dir, "home/me/notes.txt"), "private")

    # Never removed through a live mount: what is there is the member's.
    on_exit(fn ->
      Helper.unmount(root)
      unless Helper.mounted?(root), do: File.rm_rf(dir)
    end)

    Application.put_env(:hal_c2, :shell_transport, QuietWire)
    on_exit(fn -> Application.delete_env(:hal_c2, :shell_transport) end)
    start_supervised!({Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(Shell)

    Shell.put_row(
      "shop",
      {"project", %{"id" => "shop", "workspaceRoot" => shop, "deletedAt" => nil}}
    )

    :ok = Shell.sync()

    # This MC plays "devbox" too: its folder shows its own projects.
    {:ok, cluster} = Agent.start_link(fn -> [{node(), @devbox}] end)

    server =
      start_supervised!(
        {MachineFiles,
         enabled: true,
         subscribe: false,
         name: nil,
         root: root,
         ttl_ms: Map.get(ctx, :ttl_ms, 0),
         environments: fn -> Agent.get(cluster, & &1) end}
      )

    :ok = MachineFiles.await_ready(server)
    %{server: server, root: root, shop: shop, dir: dir, cluster: cluster}
  end

  defp through(ctx, path), do: Path.join([ctx.root, "devbox" | tl(Path.split(path))])

  test "a member's files read, list and save through its folder", ctx do
    cart = Path.join(ctx.shop, "src/cart.ts")

    assert MachineFiles.local_path("env-devbox", cart, ctx.server) == {:ok, through(ctx, cart)}
    assert File.read!(through(ctx, cart)) == "export const cart = [];\n"
    assert File.ls!(through(ctx, Path.join(ctx.shop, "src"))) == ["cart.ts"]
    assert File.ls!(ctx.root) == ["devbox"]

    File.write!(through(ctx, cart), "export const cart = [1];\n")
    assert File.read!(cart) == "export const cart = [1];\n"

    # A change made on the member is what is read next.
    File.write!(cart, "export const cart = [2];\n")
    assert File.read!(through(ctx, cart)) == "export const cart = [2];\n"

    File.write!(through(ctx, Path.join(ctx.shop, "src/new.ts")), "new")
    assert File.read!(Path.join(ctx.shop, "src/new.ts")) == "new"
    File.rm!(through(ctx, Path.join(ctx.shop, "src/new.ts")))
    refute File.exists?(Path.join(ctx.shop, "src/new.ts"))
  end

  test "nothing outside the member's projects is there", ctx do
    for path <- [Path.join(ctx.dir, "home/me/notes.txt"), "/etc/passwd"] do
      assert File.read(through(ctx, path)) == {:error, :enoent}, path
    end

    # The folder is this user's alone: no allow_other, in a parent only it can enter.
    options = Helper.mount_options(ctx.root)
    {uid, 0} = System.cmd("id", ["-u"])
    assert options =~ "user_id=#{String.trim(uid)}"
    refute options =~ "allow_other"
    assert Bitwise.band(File.stat!(Path.dirname(ctx.root)).mode, 0o777) == 0o700
  end

  # A symlink inside the project and the file it names are one inode to the kernel:
  # what is opened by the file's name stays that file whatever the link names later.
  test "a file also reached through a symlink stays itself when the link changes", ctx do
    alias_changes(ctx)
  end

  # The kernel then reaches the inode without a lookup, and is told it is stale.
  @tag ttl_ms: 60_000
  test "so does one the kernel still has cached", ctx do
    alias_changes(ctx)
  end

  defp alias_changes(ctx) do
    src = Path.join(ctx.shop, "src")
    File.write!(Path.join(src, "a.ts"), "a")
    File.write!(Path.join(src, "b.ts"), "b")
    File.ln_s!("a.ts", Path.join(src, "alias.ts"))

    # Open through the link first, so the kernel keeps the inode it shares with a.ts.
    {:ok, held} = File.open(through(ctx, Path.join(src, "alias.ts")), [:read])
    assert File.read!(through(ctx, Path.join(src, "a.ts"))) == "a"

    File.rm!(Path.join(src, "alias.ts"))
    File.ln_s!("b.ts", Path.join(src, "alias.ts"))
    assert File.read!(through(ctx, Path.join(src, "a.ts"))) == "a"
    File.write!(through(ctx, Path.join(src, "a.ts")), "a2")
    assert File.read!(Path.join(src, "b.ts")) == "b"

    File.rm!(Path.join(src, "alias.ts"))
    assert File.read!(through(ctx, Path.join(src, "a.ts"))) == "a2"
    File.close(held)
  end

  # A shell standing in a directory stays in that directory: what it removes there
  # is never in another that took the directory's path on the member since.
  test "a directory a shell stands in stays itself when its path names another", ctx do
    for dir <- ~w(a b d), do: File.mkdir_p!(Path.join(ctx.shop, dir))
    for dir <- ~w(a b d), do: File.write!(Path.join([ctx.shop, dir, "x"]), dir)
    File.ln_s!("a", Path.join(ctx.shop, "current"))

    in_shop = fn script ->
      System.cmd("sh", ["-c", script, "sh", through(ctx, ctx.shop), ctx.shop],
        stderr_to_stdout: true
      )
    end

    # The link is pointed at b while the shell stands in a through it.
    in_shop.(~s(cd "$1/current" && ln -sfn b "$2/current" && rm x))
    assert File.read!(Path.join(ctx.shop, "b/x")) == "b"

    # d is renamed away and made again while the shell stands in the old one.
    in_shop.(~s(cd "$1/d" && mv "$2/d" "$2/d-old" && mkdir "$2/d" && echo new > "$2/d/x" && rm x))
    assert File.read!(Path.join(ctx.shop, "d/x")) == "new\n"
  end

  # Held open there, the file's inode number is never another's while it is open here.
  test "a file open through the folder is held open on its machine until it closes", ctx do
    cart = through(ctx, Path.join(ctx.shop, "src/cart.ts"))
    {:ok, file} = File.open(cart, [:read])
    assert [pin] = Session.pins(:sys.get_state(ctx.server).session)
    ref = Process.monitor(pin)
    File.close(file)
    assert_receive {:DOWN, ^ref, :process, ^pin, _}, 5_000

    # A helper that is gone has nothing open.
    {:ok, file} = File.open(cart, [:read])
    assert [pin] = Session.pins(:sys.get_state(ctx.server).session)
    ref = Process.monitor(pin)
    %{port: port, os_pid: os_pid} = :sys.get_state(ctx.server)
    port_ref = Port.monitor(port)

    capture_log(fn ->
      {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
      assert_receive {:DOWN, ^port_ref, :port, ^port, _}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pin, _}, 5_000
      :ok = MachineFiles.await_ready(ctx.server)
    end)

    File.close(file)
  end

  # What makes a file read-only writes it through the handle it made it with.
  test "a file created read-only through the folder is written there", ctx do
    copy = Path.join(ctx.shop, "src/copy.ts")

    assert {"", 0} =
             System.cmd("sh", ["-c", ~s(umask 222 && printf hi > "$1"), "sh", through(ctx, copy)],
               stderr_to_stdout: true
             )

    assert File.read!(copy) == "hi"
  end

  test "a member removed from the cluster has no folder", ctx do
    assert File.dir?(Path.join(ctx.root, "devbox"))
    Agent.update(ctx.cluster, fn _ -> [] end)
    send(ctx.server, {:hal_c2_shell, {:mc, node(), :removed}})
    :ok = MachineFiles.sync(ctx.server)

    refute File.exists?(Path.join(ctx.root, "devbox"))
    assert File.ls!(ctx.root) == []
  end

  test "the folder is unmounted when the MC stops", ctx do
    assert Helper.mounted?(ctx.root)
    :ok = stop_supervised(MachineFiles)
    refute Helper.mounted?(ctx.root)
  end

  test "a helper killed outright is replaced, and its stale mount cleared", ctx do
    %{port: port, os_pid: os_pid} = :sys.get_state(ctx.server)
    ref = Port.monitor(port)

    capture_log(fn ->
      {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
      assert_receive {:DOWN, ^ref, :port, ^port, _}, 5_000
      :ok = MachineFiles.sync(ctx.server)
      :ok = MachineFiles.await_ready(ctx.server)
    end)

    assert %{os_pid: new_pid} = :sys.get_state(ctx.server)
    assert new_pid != os_pid
    assert File.read!(through(ctx, Path.join(ctx.shop, "src/cart.ts"))) =~ "cart"
  end
end
