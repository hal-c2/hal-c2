defmodule HalC2.HomeLockTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias HalC2.HomeLock

  @moduletag :tmp_dir

  @sqlite3 System.find_executable("sqlite3")

  @tag skip: is_nil(@sqlite3) && "no sqlite3 on this machine"
  test "a home held by another OS process is refused, and free once it is gone", %{tmp_dir: dir} do
    path = Path.join(dir, "mc.lock")
    other = Port.open({:spawn_executable, @sqlite3}, [:binary, :exit_status, args: [path]])
    Port.command(other, "BEGIN EXCLUSIVE;\nSELECT 'held';\n")
    assert_receive {^other, {:data, "held" <> _}}, 5_000

    assert HomeLock.acquire(path: path) == {:error, :held}

    {:os_pid, os_pid} = Port.info(other, :os_pid)
    System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    assert_receive {^other, {:exit_status, _}}, 5_000
    assert HomeLock.acquire(path: path) == :ok
  end

  test "a home held by another connection is refused", %{tmp_dir: dir} do
    path = Path.join(dir, "mc.lock")
    holder = hold(path)

    assert HomeLock.acquire(path: path) == {:error, :held}
    Sqlite3.close(holder)
  end

  test "a waiting MC takes the home once its holder lets go", %{tmp_dir: dir} do
    path = Path.join(dir, "mc.lock")
    holder = hold(path)
    waiter = Task.async(fn -> HomeLock.acquire(path: path, wait: true) end)

    assert Task.yield(waiter, 1_500) == nil
    Sqlite3.close(holder)
    assert Task.await(waiter, 5_000) == :ok
    {:ok, other} = Sqlite3.open(path)
    assert {:error, _locked} = Sqlite3.execute(other, "BEGIN EXCLUSIVE")
    Sqlite3.close(other)
  end

  test "a lock file that is not a database is made again", %{tmp_dir: dir} do
    path = Path.join(dir, "mc.lock")
    File.write!(path, String.duplicate("not a database ", 100))

    assert HomeLock.acquire(path: path) == :ok
    assert HomeLock.acquire(path: path, wait: true) == :ok
  end

  test "the MC that holds its home takes it again without waiting", %{tmp_dir: dir} do
    path = Path.join(dir, "mc.lock")
    :ok = HomeLock.acquire(path: path)

    assert HomeLock.held?(path)
    assert HomeLock.acquire(path: path, wait: true) == :ok
  end

  test "the lock leaves the database beside it readable", %{tmp_dir: dir} do
    :ok = HomeLock.acquire(path: Path.join(dir, "mc.lock"))
    {:ok, db} = Sqlite3.open(Path.join(dir, "hal-c2.sqlite"))
    assert Sqlite3.execute(db, "CREATE TABLE t (x)") == :ok
    Sqlite3.close(db)
  end

  defp hold(path) do
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "BEGIN EXCLUSIVE")
    db
  end
end
