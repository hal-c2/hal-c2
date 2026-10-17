defmodule HalC2.MachineFiles.ShareTest do
  # Uses the MC-wide named Store and Shell processes.
  use ExUnit.Case, async: false

  alias HalC2.MachineFiles.Share
  alias HalC2.{Shell, Store}

  @moduletag :tmp_dir

  defmodule QuietWire do
    @moduledoc false
    def connected, do: []
    def cast(_peer, _message), do: :ok
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :shell_transport, QuietWire)
    on_exit(fn -> Application.delete_env(:hal_c2, :shell_transport) end)
    start_supervised!({Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(Shell)

    home = Path.join(dir, "home/me")
    shop = Path.join(home, "shop")
    worktree = Path.join(home, ".worktrees/shop-cart")
    gone = Path.join(home, "gone")
    File.mkdir_p!(Path.join(shop, "src"))
    File.mkdir_p!(Path.join(worktree, "src"))
    File.mkdir_p!(Path.join(home, ".ssh"))
    File.mkdir_p!(gone)
    File.write!(Path.join(shop, "src/cart.ts"), "export const cart = [];\n")
    File.write!(Path.join(worktree, "src/cart.ts"), "export const cart = [1];\n")
    File.write!(Path.join(home, ".ssh/id_ed25519"), "secret")
    File.write!(Path.join(home, "notes.txt"), "private")
    File.write!(Path.join(gone, "old.txt"), "deleted project")
    File.ln_s!(Path.join(home, ".ssh/id_ed25519"), Path.join(shop, "key"))
    File.ln_s!("src/cart.ts", Path.join(shop, "cart-link.ts"))

    put("shop", {"project", %{"id" => "shop", "workspaceRoot" => shop, "deletedAt" => nil}})
    put("gone", {"project", %{"id" => "gone", "workspaceRoot" => gone, "deletedAt" => "2026"}})
    put("t1", {"thread", %{"id" => "t1", "projectId" => "shop", "worktreePath" => worktree}})
    put("t2", {"thread", %{"id" => "t2", "projectId" => "shop", "worktreePath" => nil}})
    :ok = Shell.sync()

    %{dir: dir, home: home, shop: shop, worktree: worktree, gone: gone}
  end

  defp put(id, row), do: Shell.put_row(id, row)

  test "shares the live projects' roots and the threads' worktrees", ctx do
    assert Enum.sort(Share.roots()) == Enum.sort([ctx.shop, ctx.worktree])
  end

  test "reads a file under a project and under a worktree", ctx do
    assert Share.read(Path.join(ctx.shop, "src/cart.ts"), 0, 100) ==
             {:ok, "export const cart = [];\n"}

    assert Share.read(Path.join(ctx.worktree, "src/cart.ts"), 7, 5) == {:ok, "const"}
    assert Share.read(Path.join(ctx.worktree, "src/cart.ts"), 1_000, 5) == {:ok, ""}
    assert {:ok, %{type: :regular, size: 24}} = Share.stat(Path.join(ctx.shop, "src/cart.ts"))
  end

  test "anything outside the roots is not found", ctx do
    for path <- [
          Path.join(ctx.home, ".ssh/id_ed25519"),
          Path.join(ctx.home, "notes.txt"),
          "/etc/passwd",
          Path.join(ctx.shop, "../notes.txt"),
          Path.join(ctx.shop, "./src/cart.ts"),
          Path.join(ctx.gone, "old.txt"),
          "relative/path"
        ] do
      assert Share.read(path, 0, 100) == {:error, :enoent}, path
      assert Share.stat(path) == {:error, :enoent}, path
    end

    assert Share.walk(ctx.shop, ["..", "notes.txt"]) == {:error, :enoent}
    assert Share.write(Path.join(ctx.home, "notes.txt"), 0, "x") == {:error, :enoent}
    assert File.read!(Path.join(ctx.home, "notes.txt")) == "private"
  end

  test "a symlink that leaves the root is neither read nor listed", ctx do
    assert Share.read(Path.join(ctx.shop, "key"), 0, 100) == {:error, :enoent}
    # One that stays inside reads as what it points at.
    assert Share.read(Path.join(ctx.shop, "cart-link.ts"), 0, 6) == {:ok, "export"}

    assert {:ok, entries} = Share.list(ctx.shop)
    assert [{"cart-link.ts", :regular, _}, {"src", :directory, _}] = entries
  end

  test "only regular files are opened, so nothing waits on a fifo", ctx do
    fifo = Path.join(ctx.shop, "pipe")
    {_, 0} = System.cmd("mkfifo", [fifo])

    assert Share.read(fifo, 0, 10) == {:error, :eacces}
    assert Share.write(fifo, 0, "x") == {:error, :eacces}
    assert Share.read(Path.join(ctx.shop, "src"), 0, 10) == {:error, :eisdir}
  end

  test "the directories above the roots show only the way to them", ctx do
    assert {:ok, [{first, :directory, _}]} = Share.list("/")
    assert first == ctx.dir |> Path.split() |> Enum.at(1)

    assert {:ok, [{".worktrees", :directory, _}, {"shop", :directory, _}]} =
             Share.list(ctx.home)

    assert {:ok, %{type: :directory, mode: 0o040555}} = Share.stat(ctx.home)

    # They are entered, never changed, and nothing beside the roots is there.
    assert Share.create(Path.join(ctx.home, "new.txt"), 0o644) == {:error, :enoent}
    assert Share.mkdir(Path.join(ctx.home, "new"), 0o755) == {:error, :enoent}
    assert Share.read(ctx.home, 0, 10) == {:error, :eacces}
    assert Share.remove(ctx.shop, :dir) == {:error, :eacces}
    assert Share.rename(ctx.shop, Path.join(ctx.shop <> "-moved", "x")) == {:error, :eacces}
  end

  test "walks name by name as far as it gets", ctx do
    assert {:ok, [a, b, c]} = Share.walk(ctx.home, ["shop", "src", "cart.ts"])
    assert {a.type, b.type, c.type} == {:directory, :directory, :regular}
    assert {:ok, [_shop]} = Share.walk(ctx.home, ["shop", "missing"])
    assert Share.walk(ctx.home, ["notes.txt"]) == {:error, :enoent}
    assert Share.walk(ctx.home, []) == {:ok, []}
  end

  test "writes, creates, renames and removes under a root", ctx do
    cart = Path.join(ctx.shop, "src/cart.ts")
    assert Share.write(cart, 0, "EXPORT") == {:ok, 6}
    assert File.read!(cart) == "EXPORT const cart = [];\n"

    assert {:ok, %{size: 3}} = Share.setattr(cart, %{size: 3, mtime: 1_700_000_000})
    assert File.read!(cart) == "EXP"
    assert File.stat!(cart, time: :posix).mtime == 1_700_000_000

    new = Path.join(ctx.shop, "src/new.ts")
    assert {:ok, %{type: :regular, size: 0}} = Share.create(new, 0o100640)
    assert Share.create(new, 0o644) == {:error, :eexist}
    assert Bitwise.band(File.stat!(new).mode, 0o777) == 0o640

    assert {:ok, %{type: :directory}} = Share.mkdir(Path.join(ctx.shop, "lib"), 0o755)
    assert Share.rename(new, Path.join(ctx.shop, "lib/new.ts")) == :ok
    assert File.exists?(Path.join(ctx.shop, "lib/new.ts"))

    assert Share.rename(Path.join(ctx.shop, "lib/new.ts"), Path.join(ctx.home, "x")) ==
             {:error, :enoent}

    assert Share.remove(Path.join(ctx.shop, "lib/new.ts"), :file) == :ok
    assert Share.remove(Path.join(ctx.shop, "lib"), :dir) == :ok
    refute File.exists?(Path.join(ctx.shop, "lib"))
  end

  test "a file saved over by renaming is stale to whoever opened the old one", ctx do
    cart = Path.join(ctx.shop, "src/cart.ts")
    {:ok, %{id: id}} = Share.stat(cart)
    assert Share.read(cart, 0, 6, id) == {:ok, "export"}
    assert Share.fsync(cart, id) == :ok

    saved = Path.join(ctx.shop, "src/.cart.ts.swp")
    File.write!(saved, "export const cart = [2];\n")
    File.rename!(saved, cart)

    assert Share.read(cart, 0, 6, id) == {:error, :estale}
    assert Share.write(cart, 0, "x", id) == {:error, :estale}
    assert Share.fsync(cart, id) == {:error, :estale}
    assert {:ok, %{id: new}} = Share.stat(cart)
    assert Share.read(cart, 0, 6, new) == {:ok, "export"}
  end

  test "times are set apart, and only regular files are truncated", ctx do
    cart = Path.join(ctx.shop, "src/cart.ts")
    assert {:ok, _} = Share.setattr(cart, %{atime: 1_600_000_000, mtime: 1_700_000_000})
    assert %{atime: 1_600_000_000, mtime: 1_700_000_000} = File.stat!(cart, time: :posix)

    assert {:ok, _} = Share.setattr(cart, %{atime: 1_650_000_000})
    assert %{atime: 1_650_000_000, mtime: 1_700_000_000} = File.stat!(cart, time: :posix)

    fifo = Path.join(ctx.shop, "pipe")
    {_, 0} = System.cmd("mkfifo", [fifo])
    assert Share.setattr(fifo, %{size: 0}) == {:error, :eacces}
  end

  test "a deleted thread's worktree is no longer shared", ctx do
    cart = Path.join(ctx.worktree, "src/cart.ts")
    assert {:ok, _} = Share.stat(cart)

    put(
      "t1",
      {"thread",
       %{"id" => "t1", "projectId" => "shop", "worktreePath" => ctx.worktree, "deletedAt" => "x"}}
    )

    :ok = Shell.sync()

    assert Share.stat(cart) == {:error, :enoent}
  end

  test "a project that is deleted is no longer shared", ctx do
    cart = Path.join(ctx.shop, "src/cart.ts")
    assert {:ok, _} = Share.stat(cart)

    put("shop", {"project", %{"id" => "shop", "workspaceRoot" => ctx.shop, "deletedAt" => "x"}})
    :ok = Shell.sync()

    assert Share.stat(cart) == {:error, :enoent}
  end
end
