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

    assert Scratch.stale(keys, threads, now) == [key.("old"), key.("gone")]
  end
end
