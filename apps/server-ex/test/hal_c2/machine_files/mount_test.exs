defmodule HalC2.MachineFiles.MountTest do
  # Mounts a real folder with FUSE and uses the MC-wide named Store and Shell.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HalC2.MachineFiles
  alias HalC2.MachineFiles.Helper
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

  setup do
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
         ttl_ms: 0,
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
