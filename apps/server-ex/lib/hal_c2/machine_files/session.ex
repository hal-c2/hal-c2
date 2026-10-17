defmodule HalC2.MachineFiles.Session do
  @moduledoc """
  What the machine-files helper's 9P connection holds, and how each of its
  T-messages is answered: a pure state, so its owner (`HalC2.MachineFiles`) only
  moves bytes and runs calls on the other machines.

  The tree it serves has one folder per other machine of the cluster at its top,
  each mirroring that machine's absolute paths. A fid stands at `:top` or at
  `{folder, path}`. `handle/3` answers what it can here (the top, the folders
  themselves, statfs) and names the `HalC2.MachineFiles.Share` call on the
  folder's machine that answers the rest, with how its answer becomes the reply.

  A qid's path is the helper's inode number: the top is 1, and each file of a
  folder keeps one number for the connection, by the id its machine gives it.

  A fid opened on a file keeps that file's id (`opened`), and its reads, writes
  and fsyncs fail as stale once the path names another file, as when an editor
  there saves by renaming a new file over it. One opened to append (`appends`)
  writes at the file's end as it is on its machine, not where the kernel here
  last saw it.
  """

  import Bitwise

  alias HalC2.MachineFiles.NineP

  # The helper reads and writes 128 KiB at a time; a megabyte leaves room.
  @max_msize 1_048_576 + 4096
  @top_qid {:dir, 0, 1}
  # The top and each machine's folder: changed only by the cluster.
  @folder_attr %{
    type: :directory,
    mode: 0o040500,
    size: 0,
    nlink: 2,
    uid: 0,
    gid: 0,
    atime: 0,
    mtime: 0,
    ctime: 0
  }

  @setattr_mode 0x1
  @setattr_size 0x8
  @setattr_atime 0x10
  @setattr_mtime 0x20
  @setattr_atime_set 0x80
  @setattr_mtime_set 0x100
  @at_removedir 0x200
  # Linux's O_APPEND, as lopen and lcreate pass it.
  @o_append 0o2000

  defstruct msize: 8192,
            fids: %{},
            dirs: %{},
            opened: %{},
            appends: MapSet.new(),
            qids: %{},
            next: 2

  @type t :: %__MODULE__{}
  @typedoc """
  `{:reply, r, session}`, or `{:call, folder, fun, args, finish, session}`: run
  `Share.fun(args)` on `folder`'s machine and pass the session then and its answer
  (`{:error, posix}` when there is none) to `finish`, which gives the reply and
  the session after it.
  """
  @type step ::
          {:reply, tuple, t}
          | {:call, String.t(), atom, list, (t, term -> {tuple, t}), t}

  def new, do: %__MODULE__{}

  @doc "Answers the T-message `msg` (from `NineP.decode/2`); `folders` are the machines' folders now."
  @spec handle(t, tuple, [String.t()]) :: step
  def handle(s, msg, folders)

  def handle(_s, {:version, msize, version}, _folders) do
    msize = min(msize, @max_msize)
    spoken = if version == NineP.version(), do: version, else: "unknown"
    {:reply, {:version, msize, spoken}, %__MODULE__{msize: msize}}
  end

  def handle(s, {:attach, fid}, _folders),
    do: {:reply, {:attach, @top_qid}, put_fid(s, fid, :top)}

  def handle(s, {:flush, _oldtag}, _folders), do: {:reply, {:flush}, s}

  def handle(s, {:clunk, fid}, _folders) do
    {:reply, {:clunk}, forget(s, fid)}
  end

  def handle(s, {:statfs, _fid}, _folders) do
    statfs = %{
      # V9FS_MAGIC
      type: 0x01021997,
      bsize: 4096,
      blocks: 1 <<< 30,
      bfree: 1 <<< 29,
      bavail: 1 <<< 29,
      files: 1 <<< 24,
      ffree: 1 <<< 23,
      fsid: 0,
      namelen: 255
    }

    {:reply, {:statfs, statfs}, s}
  end

  def handle(s, {:unknown, _type}, _folders), do: error(s, :enosys)
  def handle(s, {:bad, _type}, _folders), do: error(s, :einval)

  def handle(s, msg, folders) do
    case Map.fetch(s.fids, elem(msg, 1)) do
      {:ok, at} -> on(s, msg, at, folders)
      :error -> error(s, :ebadf)
    end
  end

  # --- walking ---------------------------------------------------------------------

  defp on(s, {:walk, _, newfid, []}, at, _folders),
    do: {:reply, {:walk, []}, put_fid(s, newfid, at)}

  defp on(s, {:walk, _, newfid, names}, at, folders) do
    cond do
      not Enum.all?(names, &name?/1) ->
        error(s, :enoent)

      at != :top ->
        {folder, path} = at
        walk(s, folder, path, names, newfid, [])

      hd(names) not in folders ->
        error(s, :enoent)

      true ->
        [folder | rest] = names
        {qid, s} = folder_qid(s, folder)

        if rest == [],
          do: {:reply, {:walk, [qid]}, put_fid(s, newfid, {folder, "/"})},
          else: walk(s, folder, "/", rest, newfid, [qid])
    end
  end

  # --- what a fid is -----------------------------------------------------------------

  defp on(s, {:getattr, _}, :top, _folders), do: {:reply, {:getattr, @top_qid, @folder_attr}, s}

  defp on(s, {:getattr, _}, {folder, "/"}, _folders) do
    {qid, s} = folder_qid(s, folder)
    {:reply, {:getattr, qid, @folder_attr}, s}
  end

  defp on(s, {:getattr, _}, {folder, path}, _folders) do
    call(s, folder, :stat, [path], fn s, {:ok, attr} ->
      {qid, s} = qid(s, folder, attr)
      {{:getattr, qid, attr}, s}
    end)
  end

  defp on(s, {:lopen, fid, _flags}, :top, _folders),
    do: {:reply, {:lopen, @top_qid, 0}, put_fid(s, fid, :top)}

  defp on(s, {:lopen, fid, _flags}, {folder, "/"} = at, _folders) do
    {qid, s} = folder_qid(s, folder)
    {:reply, {:lopen, qid, 0}, put_fid(s, fid, at)}
  end

  defp on(s, {:lopen, fid, flags}, {folder, path} = at, _folders) do
    call(s, folder, :stat, [path], fn s, {:ok, attr} ->
      {qid, s} = qid(s, folder, attr)
      {{:lopen, qid, 0}, s |> put_fid(fid, at) |> open(fid, attr, flags)}
    end)
  end

  # The helper names the open fid for an ftruncate, so it changes only that file.
  defp on(s, {:setattr, fid, asked}, {folder, path}, _folders) when path != "/" do
    case changes(asked) do
      none when none == %{} ->
        {:reply, {:setattr}, s}

      changes ->
        call(s, folder, :setattr, [path, changes, s.opened[fid]], fn s, {:ok, _} ->
          {{:setattr}, s}
        end)
    end
  end

  # --- reading and writing -----------------------------------------------------------

  defp on(s, {:read, fid, offset, count}, {folder, path}, _folders) when path != "/" do
    count = min(count, s.msize - NineP.read_header())

    call(s, folder, :read, [path, offset, count, s.opened[fid]], fn s, {:ok, data} ->
      {{:read, data}, s}
    end)
  end

  defp on(s, {:write, fid, offset, data}, {folder, path}, _folders) when path != "/" do
    {name, args} =
      if MapSet.member?(s.appends, fid),
        do: {:append, [path, data, s.opened[fid]]},
        else: {:write, [path, offset, data, s.opened[fid]]}

    call(s, folder, name, args, fn s, {:ok, n} -> {{:write, n}, s} end)
  end

  # On the machine that has the file, if it is one; the top and folders hold none.
  defp on(s, {:fsync, fid}, at, _folders) do
    case {at, s.opened} do
      {{folder, path}, %{^fid => id}} ->
        call(s, folder, :fsync, [path, id], fn s, :ok -> {{:fsync}, s} end)

      _ ->
        {:reply, {:fsync}, s}
    end
  end

  defp on(s, {:readdir, fid, offset, count}, :top, folders) do
    {entries, s} =
      Enum.map_reduce(folders, s, fn folder, s ->
        {qid, s} = folder_qid(s, folder)
        {{qid, 4, folder}, s}
      end)

    {:reply, {:readdir, page(entries, offset, count)}, %{s | dirs: Map.put(s.dirs, fid, entries)}}
  end

  # A directory is listed once, when it is read from the start; later pages come
  # from that listing so the offsets stay the same.
  defp on(s, {:readdir, fid, offset, count}, {folder, path}, _folders) do
    case s.dirs do
      %{^fid => entries} when offset > 0 ->
        {:reply, {:readdir, page(entries, offset, count)}, s}

      _ ->
        call(s, folder, :list, [path], fn s, {:ok, listed} ->
          {entries, s} =
            Enum.map_reduce(listed, s, fn {name, type, id}, s ->
              {qid, s} = qid(s, folder, %{type: type, id: id, mtime: 0})
              {{qid, dirent_type(type), name}, s}
            end)

          {{:readdir, page(entries, offset, count)}, %{s | dirs: Map.put(s.dirs, fid, entries)}}
        end)
    end
  end

  # --- changing the tree -------------------------------------------------------------

  defp on(s, {:lcreate, fid, name, flags, mode}, {folder, dir}, _folders) do
    named(s, [name], fn ->
      path = join(dir, name)

      call(s, folder, :create, [path, mode], fn s, {:ok, attr} ->
        {qid, s} = qid(s, folder, attr)
        {{:lcreate, qid, 0}, s |> put_fid(fid, {folder, path}) |> open(fid, attr, flags)}
      end)
    end)
  end

  defp on(s, {:mkdir, _, name, mode}, {folder, dir}, _folders) do
    named(s, [name], fn ->
      call(s, folder, :mkdir, [join(dir, name), mode], fn s, {:ok, attr} ->
        {qid, s} = qid(s, folder, attr)
        {{:mkdir, qid}, s}
      end)
    end)
  end

  defp on(s, {:unlinkat, _, name, flags}, {folder, dir}, _folders) do
    kind = if band(flags, @at_removedir) != 0, do: :dir, else: :file

    named(s, [name], fn ->
      call(s, folder, :remove, [join(dir, name), kind], fn s, :ok -> {{:unlinkat}, s} end)
    end)
  end

  defp on(s, {:renameat, _, old_name, new_fid, new_name}, {folder, old_dir}, _folders) do
    case s.fids[new_fid] do
      {^folder, new_dir} ->
        named(s, [old_name, new_name], fn ->
          from = join(old_dir, old_name)
          to = join(new_dir, new_name)

          call(s, folder, :rename, [from, to], fn s, :ok ->
            {{:renameat}, renamed(s, folder, from, to)}
          end)
        end)

      {_other_folder, _} ->
        error(s, :exdev)

      _ ->
        error(s, :eacces)
    end
  end

  # The top and the folders hold no files and are changed only by the cluster.
  defp on(s, msg, _at, _folders) when elem(msg, 0) in [:read, :write], do: error(s, :eisdir)
  defp on(s, _msg, _at, _folders), do: error(s, :eacces)

  # --- helpers -----------------------------------------------------------------------

  # As far as the walk gets: a fid for its end only if it got there.
  defp walk(s, folder, path, names, newfid, before) do
    finish = fn
      s, {:ok, attrs} ->
        {qids, s} = Enum.map_reduce(attrs, s, &qid(&2, folder, &1))

        s =
          if length(attrs) == length(names),
            do: put_fid(s, newfid, {folder, Enum.reduce(names, path, &join(&2, &1))}),
            else: s

        {{:walk, before ++ qids}, s}

      s, {:error, _} when before != [] ->
        {{:walk, before}, s}

      s, {:error, reason} ->
        {{:lerror, NineP.errno(reason)}, s}
    end

    {:call, folder, :walk, [path, names], finish, s}
  end

  # A call whose errors are the reply; `finish` sees only an answer.
  defp call(s, folder, fun, args, finish) do
    finish = fn
      s, {:error, reason} -> {{:lerror, NineP.errno(reason)}, s}
      s, answer -> finish.(s, answer)
    end

    {:call, folder, fun, args, finish, s}
  end

  defp error(s, reason), do: {:reply, {:lerror, NineP.errno(reason)}, s}

  defp named(s, names, fun),
    do: if(Enum.all?(names, &name?/1), do: fun.(), else: error(s, :einval))

  defp name?(name), do: name not in ["", ".", ".."] and not String.contains?(name, ["/", <<0>>])

  defp join("/", name), do: "/" <> name
  defp join(dir, name), do: dir <> "/" <> name

  defp put_fid(s, fid, at), do: %{forget(s, fid) | fids: Map.put(s.fids, fid, at)}

  defp forget(s, fid) do
    %{
      s
      | fids: Map.delete(s.fids, fid),
        dirs: Map.delete(s.dirs, fid),
        opened: Map.delete(s.opened, fid),
        appends: MapSet.delete(s.appends, fid)
    }
  end

  # A directory's listing is taken when it is read, so only a file keeps its id.
  defp open(s, _fid, %{type: :directory}, _flags), do: s

  defp open(s, fid, %{id: id}, flags) do
    s = %{s | opened: Map.put(s.opened, fid, id)}
    if band(flags, @o_append) != 0, do: %{s | appends: MapSet.put(s.appends, fid)}, else: s
  end

  defp folder_qid(s, folder), do: qid(s, folder, %{type: :directory, id: {:dir, "/"}, mtime: 0})

  defp qid(s, folder, %{type: type, id: id, mtime: mtime}) do
    key = {folder, id}
    type = if type == :directory, do: :dir, else: :file

    case s.qids do
      %{^key => path} -> {{type, mtime, path}, s}
      _ -> {{type, mtime, s.next}, %{s | qids: Map.put(s.qids, key, s.next), next: s.next + 1}}
    end
  end

  defp dirent_type(:directory), do: 4
  defp dirent_type(:regular), do: 8
  defp dirent_type(_), do: 0

  # The entries after `offset` (the offset of the last one read) that fit `count` bytes.
  defp page(entries, offset, count) do
    entries
    |> Enum.with_index(1)
    |> Enum.drop(offset)
    |> Enum.reduce_while({[], 0}, fn {{qid, type, name}, index}, {acc, used} ->
      entry = {qid, index, type, name}
      used = used + NineP.dirent_size(entry)
      if used > count, do: {:halt, {acc, used}}, else: {:cont, {[entry | acc], used}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp changes(asked) do
    %{}
    |> put_if(asked.valid, @setattr_mode, :mode, asked.mode)
    |> put_if(asked.valid, @setattr_size, :size, asked.size)
    |> put_time(asked.valid, @setattr_atime, @setattr_atime_set, :atime, asked.atime)
    |> put_time(asked.valid, @setattr_mtime, @setattr_mtime_set, :mtime, asked.mtime)
  end

  defp put_if(changes, valid, bit, key, value),
    do: if(band(valid, bit) != 0, do: Map.put(changes, key, value), else: changes)

  # Without its _SET bit a time is "now", on the machine that has the file.
  defp put_time(changes, valid, bit, set_bit, key, value) do
    cond do
      band(valid, bit) == 0 -> changes
      band(valid, set_bit) != 0 -> Map.put(changes, key, value)
      true -> Map.put(changes, key, :now)
    end
  end

  # Fids at or under a renamed path follow it.
  defp renamed(s, folder, from, to) do
    fids =
      Map.new(s.fids, fn
        {fid, {^folder, ^from}} ->
          {fid, {folder, to}}

        {fid, {^folder, path}} = entry ->
          if String.starts_with?(path, from <> "/"),
            do:
              {fid,
               {folder,
                to <> binary_part(path, byte_size(from), byte_size(path) - byte_size(from))}},
            else: entry

        entry ->
          entry
      end)

    %{s | fids: fids}
  end
end
