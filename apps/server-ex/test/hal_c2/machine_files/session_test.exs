defmodule HalC2.MachineFiles.SessionTest do
  use ExUnit.Case, async: true

  alias HalC2.MachineFiles.Session

  @folders ["devbox"]

  # "devbox" as `HalC2.MachineFiles.Share` there would answer. The shop is directory
  # 12; one that is asked about as 99 has been replaced by it since.
  defp devbox(:walk, ["/", ["home", "me", "shop"], nil]), do: {:ok, [dir(10), dir(11), dir(12)]}
  defp devbox(:walk, ["/", ["home", "missing"], nil]), do: {:ok, [dir(10)]}
  defp devbox(:walk, ["/", ["etc"], nil]), do: {:error, :enoent}
  defp devbox(:walk, ["/home/me/shop", ["cart.ts"], {1, 12}]), do: {:ok, [file(13, 5)]}
  defp devbox(:walk, ["/home/me/shop", _, {1, 99}]), do: {:error, :estale}
  defp devbox(:stat, ["/home/me/shop/cart.ts"]), do: {:ok, file(13, 5)}
  defp devbox(:stat, ["/home/me/shop"]), do: {:ok, dir(12)}
  # cart.ts is file 13 until it is saved over, as an editor there would.
  defp devbox(:read, ["/home/me/shop/cart.ts", 0, _count, {1, 13}]), do: {:ok, "cart\n"}
  defp devbox(:read, ["/home/me/shop/cart.ts", 0, _count, {1, _}]), do: {:error, :estale}
  defp devbox(:write, ["/home/me/shop/cart.ts", 0, data, {1, 13}]), do: {:ok, byte_size(data)}
  defp devbox(:append, [path, data, id]), do: send(self(), {:append, path, data, id}) && {:ok, 3}
  defp devbox(:fsync, [path, id]), do: send(self(), {:fsync, path, id}) && :ok

  defp devbox(:list, ["/home/me/shop", {1, 12}]),
    do: {:ok, [{"cart.ts", :regular, {1, 13}}, {"src", :directory, {1, 14}}]}

  defp devbox(:list, ["/home/me/shop", {1, 99}]), do: {:error, :estale}
  defp devbox(:create, ["/home/me/shop/new.ts", 0o644, {1, 12}]), do: {:ok, file(15, 0)}

  defp devbox(:rename, ["/home/me/shop/cart.ts", "/home/me/shop/basket.ts", {1, 12}, {1, 12}]),
    do: :ok

  defp devbox(:remove, [path, kind, {1, 12}]), do: send(self(), {:remove, path, kind}) && :ok
  defp devbox(:remove, [_path, _kind, {1, 99}]), do: {:error, :estale}

  defp devbox(:setattr, [path, changes, id]),
    do: send(self(), {:setattr, path, changes, id}) && {:ok, file(13, 0)}

  defp dir(inode), do: attr(:directory, inode, 0)
  defp file(inode, size), do: attr(:regular, inode, size)

  defp attr(type, inode, size) do
    %{
      type: type,
      mode: if(type == :directory, do: 0o040755, else: 0o100644),
      size: size,
      nlink: 1,
      uid: 1000,
      gid: 1000,
      atime: 0,
      mtime: 7,
      ctime: 0,
      id: {1, inode}
    }
  end

  # Answers `msg`, running a call on "devbox" (or failing it with `down`) at once.
  defp step(s, msg, down \\ nil) do
    case Session.handle(s, msg, @folders) do
      {:reply, reply, s} ->
        {reply, s}

      {:call, "devbox", fun, args, finish, s} ->
        finish.(s, if(down, do: {:error, down}, else: devbox(fun, args)))
    end
  end

  defp attached do
    {{:version, 8192, "9P2000.L"}, s} = step(Session.new(), {:version, 8192, "9P2000.L"})
    {{:attach, {:dir, 0, 1}}, s} = step(s, {:attach, 0})
    s
  end

  defp at_shop do
    {{:walk, [_, _, _, _]}, s} = step(attached(), {:walk, 0, 1, ["devbox", "home", "me", "shop"]})
    s
  end

  test "an unknown version is refused and a known one resets the session" do
    assert {{:version, 8192, "unknown"}, _} = step(Session.new(), {:version, 8192, "9P2000"})
    s = attached()
    assert {{:version, 4096, "9P2000.L"}, s} = step(s, {:version, 4096, "9P2000.L"})
    assert {{:lerror, 9}, _} = step(s, {:getattr, 0})
  end

  test "the top lists one folder per machine, answered here" do
    s = attached()
    assert {{:lopen, {:dir, 0, 1}, 0}, s} = step(s, {:lopen, 0, 0})

    assert {{:readdir, [{{:dir, 0, folder}, 1, 4, "devbox"}]}, s} =
             step(s, {:readdir, 0, 0, 8192})

    assert {{:readdir, []}, s} = step(s, {:readdir, 0, 1, 8192})

    # The folder is there whether or not its machine answers.
    assert {{:walk, [{:dir, 0, ^folder}]}, s} = step(s, {:walk, 0, 1, ["devbox"]}, :ehostdown)

    assert {{:getattr, {:dir, 0, ^folder}, %{mode: 0o040500}}, _} =
             step(s, {:getattr, 1}, :ehostdown)
  end

  test "a machine that is not a folder is not found" do
    assert {{:lerror, 2}, _} = step(attached(), {:walk, 0, 1, ["laptop"]})
    assert {{:lerror, 2}, _} = step(attached(), {:walk, 0, 1, ["devbox", ".."]})
  end

  test "walks into a folder by the other machine's absolute path" do
    s = attached()
    assert {{:walk, [f, h, m, p]}, s} = step(s, {:walk, 0, 1, ["devbox", "home", "me", "shop"]})
    assert [f, h, m, p] |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> length() == 4

    # The same file keeps its number.
    assert {{:walk, [^f, ^h, ^m, ^p]}, s} =
             step(s, {:walk, 0, 2, ["devbox", "home", "me", "shop"]})

    # A walk that stops short gives no fid, and one that gets nowhere is an error.
    assert {{:walk, [^f, ^h]}, s} = step(s, {:walk, 0, 3, ["devbox", "home", "missing"]})
    assert {{:lerror, 9}, s} = step(s, {:getattr, 3})
    assert {{:walk, [^f]}, _} = step(s, {:walk, 0, 3, ["devbox", "etc"]})
  end

  test "reads and writes a file on the other machine" do
    s = at_shop()
    assert {{:walk, [{:file, 7, _}]}, s} = step(s, {:walk, 1, 2, ["cart.ts"]})
    assert {{:lopen, {:file, 7, _}, 0}, s} = step(s, {:lopen, 2, 2})
    assert {{:read, "cart\n"}, s} = step(s, {:read, 2, 0, 4096})
    assert {{:write, 3}, s} = step(s, {:write, 2, 0, "hey"})
    assert {{:getattr, _, %{size: 5}}, _} = step(s, {:getattr, 2})
  end

  test "an open file stays the file it opened, and is flushed where it is" do
    s = at_shop()
    assert {{:walk, [_]}, s} = step(s, {:walk, 1, 2, ["cart.ts"]})
    assert {{:lopen, _, 0}, s} = step(s, {:lopen, 2, 2})
    assert s.opened[2] == {1, 13}
    assert {{:fsync}, s} = step(s, {:fsync, 2})
    assert_received {:fsync, "/home/me/shop/cart.ts", {1, 13}}

    # Saved over on devbox while still open here.
    s = %{s | opened: %{s.opened | 2 => {1, 99}}}
    assert {{:lerror, 116}, s} = step(s, {:read, 2, 0, 4096})

    # The folder itself has nothing to flush; a clunked fid forgets its file.
    assert {{:walk, [_]}, s} = step(s, {:walk, 0, 3, ["devbox"]})
    assert {{:fsync}, s} = step(s, {:fsync, 3})
    refute_received {:fsync, _, _}
    assert {{:clunk}, s} = step(s, {:clunk, 2})
    refute Map.has_key?(s.opened, 2)
  end

  test "a machine that does not answer fails each call with its reason" do
    s = at_shop()
    assert {{:walk, [_]}, s} = step(s, {:walk, 1, 2, ["cart.ts"]})
    assert {{:lerror, 112}, _} = step(s, {:read, 2, 0, 4096}, :ehostdown)
    assert {{:lerror, 112}, _} = step(s, {:walk, 1, 3, ["cart.ts"]}, :ehostdown)
  end

  test "lists a directory once and pages through that listing" do
    s = at_shop()
    assert {{:lopen, _, 0}, s} = step(s, {:lopen, 1, 0})
    # Room for one entry.
    assert {{:readdir, [{_, 1, 8, "cart.ts"}]}, s} = step(s, {:readdir, 1, 0, 40})
    assert {{:readdir, [{_, 2, 4, "src"}]}, s} = step(s, {:readdir, 1, 1, 40}, :ehostdown)
    assert {{:readdir, []}, _} = step(s, {:readdir, 1, 2, 40}, :ehostdown)
  end

  test "creates and renames, and fids follow a rename" do
    s = at_shop()
    assert {{:walk, []}, s} = step(s, {:walk, 1, 2, []})
    assert {{:lcreate, {:file, 7, _}, 0}, s} = step(s, {:lcreate, 2, "new.ts", 0o102, 0o644})
    assert {{:lerror, 22}, s} = step(s, {:lcreate, 1, "../x", 0, 0o644})

    assert {{:walk, [_]}, s} = step(s, {:walk, 1, 3, ["cart.ts"]})
    assert {{:renameat}, s} = step(s, {:renameat, 1, "cart.ts", 1, "basket.ts"})
    assert s.fids[3] == {"devbox", "/home/me/shop/basket.ts"}
  end

  test "what a directory's fid names or lists is in that directory, or stale" do
    s = at_shop()
    assert {{:unlinkat}, s} = step(s, {:unlinkat, 1, "cart.ts", 0})
    assert_received {:remove, "/home/me/shop/cart.ts", :file}

    # Its path names another directory on devbox now; a clone keeps the old one.
    s = %{s | ids: %{s.ids | 1 => {1, 99}}}
    assert {{:walk, []}, s} = step(s, {:walk, 1, 2, []})

    for fid <- [1, 2] do
      assert {{:lerror, 116}, _} = step(s, {:unlinkat, fid, "cart.ts", 0})
      assert {{:lerror, 116}, _} = step(s, {:walk, fid, 3, ["cart.ts"]})
      assert {{:lerror, 116}, _} = step(s, {:readdir, fid, 0, 4096})
    end
  end

  test "nothing is renamed between machines or changed in a folder itself" do
    s = at_shop()
    assert {{:walk, []}, s} = step(s, {:walk, 0, 5, []})
    assert {{:lerror, 13}, s} = step(s, {:renameat, 1, "cart.ts", 5, "cart.ts"})
    assert {{:walk, [_]}, s} = step(s, {:walk, 0, 6, ["devbox"]})
    assert {{:lerror, 13}, s} = step(s, {:mkdir, 0, "x", 0o755})
    assert {{:lerror, 21}, _} = step(s, {:read, 6, 0, 10})
  end

  test "setattr passes on only what it changes, with an unset time as now" do
    s = at_shop()
    assert {{:walk, [_]}, s} = step(s, {:walk, 1, 2, ["cart.ts"]})
    asked = %{valid: 0, mode: 0, uid: 0, gid: 0, size: 0, atime: 0, mtime: 0}

    assert {{:setattr}, s} = step(s, {:setattr, 2, %{asked | valid: 0x28}})
    assert_received {:setattr, "/home/me/shop/cart.ts", %{size: 0, mtime: :now}, nil}

    # Only an owner change: nothing to pass on.
    assert {{:setattr}, s} = step(s, {:setattr, 2, %{asked | valid: 0x2}})
    refute_received {:setattr, _, _, _}

    # An ftruncate names the open fid: it changes only the file that fid opened.
    assert {{:lopen, _, 0}, s} = step(s, {:lopen, 2, 2})
    assert {{:setattr}, _} = step(s, {:setattr, 2, %{asked | valid: 0x8}})
    assert_received {:setattr, "/home/me/shop/cart.ts", %{size: 0}, {1, 13}}
  end

  test "a file opened or created to append writes at its end there" do
    s = at_shop()
    assert {{:walk, [_]}, s} = step(s, {:walk, 1, 2, ["cart.ts"]})
    # O_WRONLY | O_APPEND
    assert {{:lopen, _, 0}, s} = step(s, {:lopen, 2, 0o2001})
    assert {{:write, 3}, s} = step(s, {:write, 2, 5, "hey"})
    assert_received {:append, "/home/me/shop/cart.ts", "hey", {1, 13}}

    # Opened again without it, the same fid writes where it is asked to.
    assert {{:lopen, _, 0}, s} = step(s, {:lopen, 2, 2})
    assert {{:write, 3}, s} = step(s, {:write, 2, 0, "hey"})
    refute_received {:append, _, _, _}

    assert {{:walk, []}, s} = step(s, {:walk, 1, 3, []})
    assert {{:lcreate, _, 0}, s} = step(s, {:lcreate, 3, "new.ts", 0o2101, 0o644})
    assert {{:write, 3}, _} = step(s, {:write, 3, 0, "new"})
    assert_received {:append, "/home/me/shop/new.ts", "new", {1, 15}}
  end

  test "an unknown fid or message is an error, not a crash" do
    s = attached()
    assert {{:lerror, 9}, _} = step(s, {:read, 99, 0, 1})
    assert {{:lerror, 38}, _} = step(s, {:unknown, 30})
    assert {{:lerror, 22}, _} = step(s, {:bad, 116})
    assert {{:clunk}, s} = step(s, {:clunk, 0})
    assert {{:lerror, 9}, _} = step(s, {:getattr, 0})
  end
end
