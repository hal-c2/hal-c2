defmodule HalC2.ScratchTest do
  use ExUnit.Case, async: false

  alias HalC2.Scratch

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    home = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, dir)
    on_exit(fn -> Application.put_env(:hal_c2, :home, home) end)
  end

  test "two paths in one VM differ and name this OS process" do
    one = Scratch.path("x", ".json")
    assert one != Scratch.path("x", ".json")
    assert Path.basename(one) =~ ~r/^x-#{System.pid()}-\d+\.json$/
  end

  test "idle days: seven until chosen, and null keeps folders" do
    assert Scratch.idle_days(%{}) == 7
    assert Scratch.idle_days(%{"storageCleanup" => %{"threadTempAfterDays" => 30}}) == 30
    assert Scratch.idle_days(%{"storageCleanup" => %{"threadTempAfterDays" => nil}}) == nil
  end

  test "an ended process's scratch goes; a running one's stays, a file's too" do
    mine = Scratch.dir("x")
    {out, 0} = System.cmd("sh", ["-c", "echo $$"])
    ended = String.trim(out)
    dir = Path.dirname(mine)
    theirs = Path.join(dir, "x-#{ended}-1")
    file = Path.join(dir, "x-#{ended}-2.sqlite")
    # Another program on this home, such as a thread import from a shell.
    running = Path.join(dir, "x-1-1.sqlite")
    Enum.each([theirs, file, running], &File.write!(&1, ""))

    Scratch.clear_leftovers()

    assert File.dir?(mine)
    assert File.exists?(running)
    refute File.exists?(theirs)
    refute File.exists?(file)
  end

  test "a hand-edited storageCleanup that is no object reads as unset" do
    start_supervised!(HalC2.Settings)
    {:ok, _} = HalC2.Settings.update(&Map.put(&1, "storageCleanup", 5))

    assert [{"TMPDIR", _} | _] = Scratch.thread_env("t")
    assert Scratch.idle_days(HalC2.Settings.settings()) == 7
    assert HalC2.Settings.validate(%{"storageCleanup" => 5}) == :ok
  end

  test "a hand-edited folder that is no path reads as unset" do
    start_supervised!(HalC2.Settings)

    {:ok, _} =
      HalC2.Settings.update(&Map.put(&1, "storageCleanup", %{"temporaryFilesFolder" => 5}))

    assert [{"TMPDIR", dir} | _] = Scratch.thread_env("t")
    assert String.starts_with?(dir, HalC2.Paths.default_scratch_dir())

    assert {:error, %{"message" => message}} =
             HalC2.Settings.validate(%{"storageCleanup" => %{"temporaryFilesFolder" => 6}})

    assert message =~ "must be a path"
  end

  test "a thread's folder leaves room for a socket path in a long home" do
    Application.put_env(:hal_c2, :home, {:mc, "/home/someone/.local/share/hal-c2-dev/elixir"})
    # tmux, nvim and gpg add up to about 30 bytes; a socket path holds 104 on macOS.
    assert byte_size(Scratch.thread_dir(String.duplicate("t", 200))) <= 74
  end

  test "the thread folders that go" do
    day = 86_400_000
    now = 100 * day
    key = fn id -> Path.basename(Scratch.thread_dir(id)) end
    threads = [{"new", now - day, false}, {"old", now - 8 * day, false}, {"busy", 0, true}]
    keys = Enum.map(~w(new old busy gone), key)

    assert Scratch.stale(keys, threads, 7, now) == [key.("old"), key.("gone")]
    assert Scratch.stale(keys, threads, 30, now) == [key.("gone")]
    # Turned off: only a folder no thread claims goes.
    assert Scratch.stale(keys, threads, nil, now) == [key.("gone")]
  end
end
