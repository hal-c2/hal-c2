defmodule HalC2.MachineFiles.Share do
  @moduledoc """
  This machine's files, as the other MCs of its cluster see them
  (`HalC2.MachineFiles` on theirs calls these over the cluster link with `:erpc`).

  Only paths under this MC's live projects' roots and its threads' worktrees are
  answered, by the rules a client's reads follow (`HalC2.Workspace.real/1`): a path
  that resolves outside every root once symlinks resolve, a `.` or `..` component,
  or anything else reads as `:enoent`, as if it were not there. The directories
  above a root are shown with only the names that lead to roots, so a member's
  folder mirrors this machine's absolute paths and nothing beside them.

  Symlinks are followed and never shown as links: one that stays inside a root
  reads as what it points at, one that leaves every root is not listed.

  Nothing here keeps state or starts anything: each call opens, reads or writes,
  and closes. Every function takes an absolute path and answers `{:ok, value}` or
  `{:error, posix}`.
  """

  alias HalC2.Workspace

  # A read never returns more than this, whatever it asks for.
  @max_read 1_048_576
  # The directories above the roots: listed and entered, never changed.
  @synthetic_mode 0o040555

  @typedoc """
  A file's attributes. `id` tells files apart across calls: `{device, inode}`, or
  `{:dir, path}` for a directory above the roots.
  """
  @type attr :: %{
          type: :directory | :regular | :other,
          mode: non_neg_integer,
          size: non_neg_integer,
          nlink: non_neg_integer,
          uid: non_neg_integer,
          gid: non_neg_integer,
          atime: integer,
          mtime: integer,
          ctime: integer,
          id: term
        }

  @doc "The roots this MC shares: its live projects' and its threads' worktrees, expanded."
  @spec roots() :: [String.t()]
  def roots do
    if :ets.whereis(HalC2.Shell) == :undefined do
      []
    else
      mc = node()

      # Only the roots are copied out of the sidebar, not its rows.
      live_project = [
        {:is_binary, {:map_get, "workspaceRoot", :"$1"}},
        {:orelse, {:not, {:is_map_key, "deletedAt", :"$1"}},
         {:==, {:map_get, "deletedAt", :"$1"}, nil}}
      ]

      worktree = [
        {:is_map_key, "worktreePath", :"$1"},
        {:is_binary, {:map_get, "worktreePath", :"$1"}}
      ]

      :ets.select(HalC2.Shell, [
        {{{mc, :_}, {"project", :"$1"}}, live_project, [{:map_get, "workspaceRoot", :"$1"}]},
        {{{mc, :_}, {"thread", :"$1"}}, worktree, [{:map_get, "worktreePath", :"$1"}]}
      ])
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
    end
  end

  @doc """
  Walks from `path` through `names`: the attributes of each step as far as it got,
  or the error of the first when it got nowhere.
  """
  @spec walk(String.t(), [String.t()]) :: {:ok, [attr]} | {:error, atom}
  def walk(path, names) when is_binary(path) and is_list(names) do
    case walk(path, names, roots(), []) do
      {[], reason} when reason != nil -> {:error, reason}
      {attrs, _} -> {:ok, attrs}
    end
  end

  defp walk(_at, [], _roots, acc), do: {Enum.reverse(acc), nil}

  defp walk(at, [name | rest], roots, acc) do
    next = child(at, name)

    case stat(next, roots) do
      {:ok, attr} -> walk(next, rest, roots, [attr | acc])
      {:error, reason} -> {Enum.reverse(acc), reason}
    end
  end

  @doc "The attributes of `path`."
  @spec stat(String.t()) :: {:ok, attr} | {:error, atom}
  def stat(path) when is_binary(path), do: stat(path, roots())

  @doc "The entries of the directory `path` as `{name, type, id}`."
  @spec list(String.t()) :: {:ok, [{String.t(), atom, term}]} | {:error, atom}
  def list(path) when is_binary(path) do
    roots = roots()

    case classify(path, roots) do
      {:synthetic, names} ->
        entries =
          for name <- Enum.sort(names),
              {:ok, attr} <- [stat(child(path, name), roots)],
              do: {name, attr.type, attr.id}

        {:ok, entries}

      {:real, real_root} ->
        with {:ok, names} <- File.ls(path) do
          {:ok, for(name <- Enum.sort(names), entry = entry(path, name, real_root), do: entry)}
        end

      :none ->
        {:error, :enoent}
    end
  end

  @doc "Up to `count` bytes of the file `path` from `offset`; empty at its end."
  @spec read(String.t(), non_neg_integer, non_neg_integer) :: {:ok, binary} | {:error, atom}
  def read(path, offset, count) when is_binary(path) and offset >= 0 and count >= 0 do
    with {:ok, _} <- real(path, roots()),
         {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        case :file.pread(fd, offset, min(count, @max_read)) do
          {:ok, data} -> {:ok, data}
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, reason}
        end
      after
        :file.close(fd)
      end
    end
  end

  @doc "Writes `data` into the existing file `path` at `offset`; the bytes written."
  @spec write(String.t(), non_neg_integer, binary) :: {:ok, non_neg_integer} | {:error, atom}
  def write(path, offset, data) when is_binary(path) and offset >= 0 and is_binary(data) do
    with {:ok, _} <- real(path, roots()),
         {:ok, fd} <- :file.open(path, [:read, :write, :binary, :raw]) do
      try do
        with :ok <- :file.pwrite(fd, offset, data), do: {:ok, byte_size(data)}
      after
        :file.close(fd)
      end
    end
  end

  @doc "Creates the file `path`, which must not exist yet, with `mode`."
  @spec create(String.t(), non_neg_integer) :: {:ok, attr} | {:error, atom}
  def create(path, mode) when is_binary(path) and is_integer(mode) do
    roots = roots()

    with {:ok, _} <- under_root(path, roots),
         {:ok, fd} <- :file.open(path, [:write, :exclusive, :raw]) do
      :file.close(fd)
      _ = File.chmod(path, Bitwise.band(mode, 0o7777))
      stat(path, roots)
    end
  end

  @doc "Creates the directory `path` with `mode`."
  @spec mkdir(String.t(), non_neg_integer) :: {:ok, attr} | {:error, atom}
  def mkdir(path, mode) when is_binary(path) and is_integer(mode) do
    roots = roots()

    with {:ok, _} <- under_root(path, roots),
         :ok <- File.mkdir(path) do
      _ = File.chmod(path, Bitwise.band(mode, 0o7777))
      stat(path, roots)
    end
  end

  @doc "Removes the file (`:file`) or empty directory (`:dir`) `path`; never a root."
  @spec remove(String.t(), :file | :dir) :: :ok | {:error, atom}
  def remove(path, kind) when is_binary(path) and kind in [:file, :dir] do
    with {:ok, _} <- under_root(path, roots()) do
      if kind == :dir, do: File.rmdir(path), else: File.rm(path)
    end
  end

  @doc "Renames `from` to `to`, both under a root and neither one."
  @spec rename(String.t(), String.t()) :: :ok | {:error, atom}
  def rename(from, to) when is_binary(from) and is_binary(to) do
    roots = roots()

    with {:ok, _} <- under_root(from, roots),
         {:ok, _} <- under_root(to, roots),
         do: File.rename(from, to)
  end

  @doc """
  Changes what `changes` names of `path`: `:size` truncates or extends it, `:mode`
  sets its permissions, `:mtime` (or `:atime` alone) sets its times. The new
  attributes.
  """
  @spec setattr(String.t(), map) :: {:ok, attr} | {:error, atom}
  def setattr(path, changes) when is_binary(path) and is_map(changes) do
    roots = roots()

    with {:ok, _} <- real(path, roots),
         :ok <- truncate(path, changes[:size]),
         :ok <- chmod(path, changes[:mode]),
         :ok <- touch(path, changes[:mtime] || changes[:atime]),
         do: stat(path, roots)
  end

  # --- the rules ---------------------------------------------------------------------

  # Where a path stands: under a root (with that root's real path), above some roots
  # (with the names leading on to them), or nowhere the share answers for.
  defp classify(path, roots) do
    if clean?(path) do
      under = for root <- roots, Workspace.within?(root, path), do: Workspace.real(root)

      cond do
        under != [] ->
          real = Workspace.real(path)

          case Enum.find(under, &Workspace.within?(&1, real)) do
            nil -> :none
            real_root -> {:real, real_root}
          end

        (names = toward(path, roots)) != [] ->
          {:synthetic, names}

        true ->
          :none
      end
    else
      :none
    end
  end

  # An absolute path with no empty, `.` or `..` component: what a member asks for.
  defp clean?("/"), do: true

  defp clean?("/" <> rest) do
    not String.contains?(rest, <<0>>) and
      Enum.all?(String.split(rest, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp clean?(_path), do: false

  # The names under `path` that lead to roots below it.
  defp toward(path, roots) do
    prefix = if path == "/", do: "/", else: path <> "/"

    for root <- roots,
        root != path,
        String.starts_with?(root, prefix),
        uniq: true,
        do: root |> binary_part(byte_size(prefix), byte_size(root) - byte_size(prefix)) |> first()
  end

  defp first(relative), do: relative |> String.split("/", parts: 2) |> hd()

  defp child("/", name), do: "/" <> name
  defp child(path, name), do: path <> "/" <> name

  defp stat(path, roots) do
    case classify(path, roots) do
      {:real, _} -> real_stat(path)
      {:synthetic, _} -> {:ok, synthetic(path)}
      :none -> {:error, :enoent}
    end
  end

  # Under a root: its real path. The directories above the roots are not changed.
  defp real(path, roots) do
    case classify(path, roots) do
      {:real, real_root} -> {:ok, real_root}
      {:synthetic, _} -> {:error, :eacces}
      :none -> {:error, :enoent}
    end
  end

  # A path under a root that may not exist yet, and is not a root itself.
  defp under_root(path, roots) do
    if path in roots, do: {:error, :eacces}, else: real(path, roots)
  end

  # A directory entry, unless it is a symlink that leaves the root or leads nowhere.
  defp entry(dir, name, real_root) do
    path = child(dir, name)

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :symlink}} ->
        with true <- Workspace.within?(real_root, Workspace.real(path)),
             {:ok, attr} <- real_stat(path),
             do: {name, attr.type, attr.id},
             else: (_ -> nil)

      {:ok, stat} ->
        attr = attr(stat)
        {name, attr.type, attr.id}

      {:error, _} ->
        nil
    end
  end

  defp real_stat(path) do
    with {:ok, stat} <- File.stat(path, time: :posix), do: {:ok, attr(stat)}
  end

  defp attr(%File.Stat{} = stat) do
    %{
      type: if(stat.type in [:directory, :regular], do: stat.type, else: :other),
      mode: stat.mode,
      size: stat.size,
      nlink: stat.links,
      uid: stat.uid,
      gid: stat.gid,
      atime: stat.atime,
      mtime: stat.mtime,
      ctime: stat.ctime,
      id: {stat.major_device, stat.inode}
    }
  end

  defp synthetic(path) do
    %{
      type: :directory,
      mode: @synthetic_mode,
      size: 0,
      nlink: 2,
      uid: 0,
      gid: 0,
      atime: 0,
      mtime: 0,
      ctime: 0,
      id: {:dir, path}
    }
  end

  defp truncate(_path, nil), do: :ok

  defp truncate(path, size) when is_integer(size) and size >= 0 do
    with {:ok, fd} <- :file.open(path, [:read, :write, :raw]) do
      try do
        with {:ok, _} <- :file.position(fd, size), do: :file.truncate(fd)
      after
        :file.close(fd)
      end
    end
  end

  defp chmod(_path, nil), do: :ok
  defp chmod(path, mode) when is_integer(mode), do: File.chmod(path, Bitwise.band(mode, 0o7777))

  defp touch(_path, nil), do: :ok
  defp touch(path, time) when is_integer(time), do: File.touch(path, time)
end
