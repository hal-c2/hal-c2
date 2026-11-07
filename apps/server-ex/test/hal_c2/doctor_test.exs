defmodule HalC2.DoctorTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias HalC2.{Doctor, Store}

  @moduletag :tmp_dir

  defp store(dir) do
    path = Path.join(dir, "hal-c2.sqlite")
    {:ok, pid} = Store.start_link(path: path, name: nil)
    GenServer.stop(pid)
    path
  end

  test "flags it does not know get its usage", %{tmp_dir: dir} do
    assert {:error, "usage: " <> _} = Doctor.command(["--force"], path: store(dir))
  end

  test "a home with no store has nothing to check", %{tmp_dir: dir} do
    path = Path.join(dir, "hal-c2.sqlite")
    assert Doctor.command(["--fix"], path: path) == {:ok, "No store at #{path}"}
    refute File.exists?(path)
  end

  test "a clean store has nothing to repair", %{tmp_dir: dir} do
    assert Doctor.command(["--fix"], path: store(dir)) == {:ok, "Nothing to repair"}
  end

  test "the few pages a running store frees are not worth a repair", %{tmp_dir: dir} do
    path = Path.join(dir, "hal-c2.sqlite")
    {:ok, pid} = Store.start_link(path: path, name: nil)
    :ok = Store.put_meta(pid, "scratch", String.duplicate("x", 200_000))
    :ok = Store.delete_meta(pid, "scratch")
    {:ok, _} = Store.checkpoint(pid)
    GenServer.stop(pid)

    assert Store.space(path).free > 0
    assert Doctor.command(["--fix"], path: path) == {:ok, "Nothing to repair"}
  end

  test "it changes nothing while another process holds the home", %{tmp_dir: dir} do
    path = store(dir)
    lock = Path.join(dir, "mc.lock")
    {:ok, holder} = Sqlite3.open(lock)
    :ok = Sqlite3.execute(holder, "BEGIN EXCLUSIVE")

    try do
      assert {:error, message} = Doctor.command(["--fix"], path: path, lock: lock)
      assert message =~ "is open" and message =~ "Nothing was changed"
    after
      Sqlite3.close(holder)
    end

    # Let go, the home is the doctor's.
    assert {:ok, _} = Doctor.command(["--fix"], path: path, lock: lock)
  end
end
