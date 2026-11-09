defmodule HalC2.ThreadArchive do
  @moduledoc """
  A thread as one file (`.hal-c2-thread`, JSON): what `mix hal_c2.thread.export`
  writes, `mix hal_c2.thread.import` reads, and a move between cluster members
  (`HalC2.ThreadMove`) sends.

  Version 2 carries the thread's stream as entities (`HalC2.StreamState.rows/1`), the
  project it lived in (its root and repository), attachments and terminal scrollback,
  a `git bundle` of its checkpoint refs, a bundle of the branch of its own worktree
  and, when its provider can carry one, the agent's native session
  (`HalC2.PortableSessions`). Version 1 is the archive an earlier install wrote; it imports
  through `HalC2.Import.V2` without a session.

  Every carried file has a name and a sha256. A built archive leaves the large ones
  where they are on this machine's disk (`"path"`, with their `"size"`), so a thread
  with a large session or repository is never held in memory: `export_file/3` writes
  them into the file a piece at a time, as base64 (`"dataBase64"`), and a move copies
  them to the destination's disk beside the rest (`HalC2.ThreadMove.accept/3`). Only
  reading a `.hal-c2-thread` file holds it whole, its files' bytes under `"data"`.

  An import checks the whole file before it writes anything. The thread lands in a
  named project or the one project here that is a checkout of the same repository;
  every recorded path under the old project root is rewritten to the new one.
  Checkpoints only land in a checkout of the same repository, and so does a worktree:
  its branch is fetched there, checked out in a new worktree and put back to the last
  checkpoint, so it holds the files as they were at the end of the last run.
  """

  alias HalC2.{Attachments, Patch, PortableSessions, Store, StreamState, Streams, Terminal}
  alias HalC2.Checkpoint

  @format "hal-c2-thread-export"
  @version 2
  @extension ".hal-c2-thread"
  # How much of a file is read at a time; whole base64 groups, so the pieces join.
  @piece 3 * 256 * 1024
  @base64_key ~s("dataBase64":")

  @type archive :: map

  def extension, do: @extension

  # --- export --------------------------------------------------------------------

  @doc """
  The archive of a thread on this MC, by id or title. `opts[:session]` false
  leaves the agent's session out, and `opts[:terminal_logs]` false its terminals'
  scrollback. `discard/1` it once it is written or sent: the bundles it carries are
  files made for it.
  """
  @spec build(String.t(), keyword) :: {:ok, archive} | {:error, String.t()}
  def build(ref, opts \\ []) do
    with {:ok, id} <- find_thread(ref),
         {:ok, state, thread, archive} <- read(id, &pinned(&1, id, ref)) do
      root = archive["thread"]["projectRoot"]
      cwd = thread["worktreePath"] || root
      have = Keyword.get(opts, :have, [])

      # The checkpoints, worktree, session and scrollback do git and file work and
      # read only what memory holds, so they run once the read has let go of the disk.
      {:ok,
       Map.merge(archive, %{
         "terminalLogs" =>
           if(Keyword.get(opts, :terminal_logs, true),
             do: for({terminal, data} <- Terminal.saved_scrollback(id), do: file(terminal, data)),
             else: []
           ),
         "checkpoints" => checkpoints(state, root, have),
         "worktree" => worktree(thread, have),
         "session" => if(Keyword.get(opts, :session, true), do: session(state, thread, cwd))
       })}
    end
  end

  # The part of an archive that reads the thread's older runs from disk, inside the
  # read that pins them.
  defp pinned(state, id, ref) do
    with %{} = thread <- StreamState.get(state, "thread")[id] || {:error, "No thread #{ref}."},
         {:ok, meta} <- describe(thread) do
      {:ok, state, thread,
       %{
         "format" => @format,
         "version" => @version,
         "exportedAt" => now(),
         "thread" => meta,
         "updatedAt" => state.updated_at,
         "entities" => entities_file(state),
         "attachments" => attachments(state)
       }}
    end
  end

  @doc """
  What an archive says of a thread itself (its `"thread"`), from the thread's entity.
  A thread that has moved away has none, nor has one whose plugin keeps it on this
  machine (`stays/1`), so no way of taking a thread off the machine (a move, an
  export) gets as far as reading it.
  """
  def describe(%{"movedTo" => %{}} = thread), do: {:error, moved_message(thread)}

  def describe(%{"id" => id} = thread) do
    with :ok <- stays(thread) do
      project = project(thread["projectId"]) || %{}
      root = project["workspaceRoot"]

      {:ok,
       %{
         "id" => id,
         "title" => thread["title"],
         "projectId" => thread["projectId"],
         "projectTitle" => project["title"],
         "projectRoot" => root,
         "repository" => repository(root),
         "worktreePath" => thread["worktreePath"],
         "branch" => thread["branch"],
         "instanceId" =>
           get_in(thread, ["modelSelection", "instanceId"]) || thread["providerInstanceId"],
         "machine" => label()
       }}
    end
  end

  @doc """
  The refusal for a thread its plugin keeps on this machine, which no client moves,
  exports or is offered a destination for: what such a plugin keeps around the thread
  (a sandbox, a credential, a checkout) does not travel, so the thread would arrive
  unprotected. A thread is kept when its mark says so (`"stays"`, set by
  `HalC2.Plugins.Host.launch_thread/4` for a plugin whose manifest has `threadsStay`;
  a fork copies it), or when its plugin's manifest has `threadsStay`
  (`HalC2.Plugins.threads_stay?/1`: the version loaded, or the package on disk, so with
  no MC running too), which covers a thread started before the manifest said so, and
  its forks, whether or not the plugin runs. A thread run in a review sandbox
  (`"sandboxed"`, #1412) is kept too: its sandbox is this machine's.
  """
  def stays(%{"plugin" => %{"id" => owner} = mark} = thread) do
    if kept?(owner, mark),
      do: {:error, "#{thread["title"]} was started by #{owner}, which keeps it on this machine."},
      else: :ok
  end

  def stays(_thread), do: :ok

  defp kept?(owner, mark),
    do: mark["stays"] == true or mark["sandboxed"] == true or HalC2.Plugins.threads_stay?(owner)

  @doc """
  Writes a thread's archive to a new file at `path`, readable only by the user; a file
  that is already there is refused. Terminal scrollback, which may hold secrets, goes
  only with `opts[:terminal_logs]` true. Returns `summary/1` with the file's `:path`.
  """
  @spec export_file(String.t(), Path.t(), keyword) :: {:ok, map} | {:error, String.t()}
  def export_file(ref, path, opts \\ []) do
    path = Path.expand(path)
    opts = Keyword.put_new(opts, :terminal_logs, false)

    with :ok <- new_file(path),
         {:ok, archive} <- build(ref, opts) do
      File.mkdir_p!(Path.dirname(path))

      try do
        case write_file(path, archive) do
          :ok -> {:ok, archive |> summary() |> Map.put(:path, path)}
          {:error, :eexist} -> exists(path)
          {:error, reason} -> {:error, "Could not write #{path}: #{:file.format_error(reason)}."}
        end
      after
        discard(archive)
      end
    end
  end

  defp new_file(path) do
    case File.lstat(path) do
      {:ok, _} -> exists(path)
      _ -> :ok
    end
  end

  defp exists(path), do: {:error, "The output file #{path} already exists. Nothing was exported."}

  @doc "Removes the files `build/2` made for an archive."
  def discard(archive) do
    for %{"temporary" => true, "path" => path} <- files(archive), do: File.rm(path)
    with {:entities, path, _kinds} <- archive["entities"], do: File.rm(path)
    :ok
  end

  @doc "The kinds of entity an archive holds."
  def kinds(%{"entities" => {:entities, _path, kinds}}), do: kinds
  def kinds(%{"entities" => entities}), do: MapSet.new(entities, &hd/1)

  # A built archive's entities: a JSON array in a file made for it, written a row at
  # a time as the thread's older runs are read from disk, so a long thread is never
  # held whole. `encode/1` and `write_file/2` put it in the archive's JSON.
  defp entities_file(state) do
    path = scratch()

    kinds =
      File.open!(path, [:write, :raw, :binary, :delayed_write], fn out ->
        {_, kinds} =
          state
          |> StreamState.rows()
          |> Enum.reduce({"[", MapSet.new()}, fn {kind, eid, entity}, {comma, kinds} ->
            :ok = :file.write(out, [comma, JSON.encode_to_iodata!([kind, eid, entity])])
            {",", MapSet.put(kinds, kind)}
          end)

        :ok = :file.write(out, "]")
        kinds
      end)

    File.chmod(path, 0o600)
    {:entities, path, kinds}
  end

  @doc "Every file an archive carries."
  def files(archive) do
    List.wrap(archive["attachments"]) ++
      List.wrap(archive["terminalLogs"]) ++
      for(key <- ~w(checkpoints worktree), %{"bundle" => bundle} <- [archive[key]], do: bundle) ++
      case archive["session"] do
        %{"files" => files} when is_list(files) -> files
        _ -> []
      end
  end

  @doc "The archive with `fun` applied to every file it carries."
  def map_files(archive, fun) do
    each = fn files -> files && Enum.map(files, fun) end
    bundle = fn value -> value && Map.update!(value, "bundle", fun) end

    Enum.reduce(
      [
        {"attachments", each},
        {"terminalLogs", each},
        {"checkpoints", bundle},
        {"worktree", bundle},
        {"session", fn session -> session && Map.update!(session, "files", each) end}
      ],
      archive,
      fn {key, update}, archive ->
        if is_map_key(archive, key), do: Map.update!(archive, key, update), else: archive
      end
    )
  end

  @doc """
  An archive as JSON. Its entities are encoded one at a time: encoding a long thread's
  all at once takes many times their size in memory.
  """
  def encode(%{"entities" => entities} = archive) when is_list(entities) do
    marker = "hal-c2-entities-#{Base.encode16(:crypto.strong_rand_bytes(12))}"

    [before, rest] =
      %{archive | "entities" => marker} |> JSON.encode!() |> String.split(JSON.encode!(marker))

    Enum.reduce(entities, {before <> "[", ""}, fn entity, {json, comma} ->
      {json <> comma <> JSON.encode!(entity), ","}
    end)
    |> elem(0)
    |> Kernel.<>("]" <> rest)
  end

  def encode(%{"entities" => {:entities, path, _kinds}} = archive) do
    {marker, archive} = entities_marker(archive)
    [before, rest] = archive |> JSON.encode!() |> String.split(marker)
    before <> File.read!(path) <> rest
  end

  def encode(archive), do: JSON.encode!(archive)

  # The archive with a marker standing in for its entities file, and the marker as it
  # is in the JSON.
  defp entities_marker(archive) do
    marker = "hal-c2-entities-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
    {JSON.encode!(marker), %{archive | "entities" => marker}}
  end

  # The archive's JSON with the files on disk in it as base64, written a piece at a
  # time to a new file only the user can read: each stands in the JSON as a marker and
  # its sha256, which is cut there for its bytes. A file that is already at `path` is
  # left as it is (`{:error, :eexist}`); one this left part written is removed.
  defp write_file(path, archive) do
    marker = "hal-c2-file-#{Base.encode16(:crypto.strong_rand_bytes(12))}-"

    on_disk =
      for %{"path" => source, "sha256" => sha} <- files(archive), into: %{}, do: {sha, source}

    {entities, archive} =
      case archive["entities"] do
        {:entities, source, _kinds} ->
          {marker, archive} = entities_marker(archive)
          {{marker, source}, archive}

        _ ->
          {nil, archive}
      end

    [first | pieces] =
      archive
      |> map_files(fn
        %{"path" => _, "sha256" => sha} = file ->
          file |> Map.drop(~w(path temporary)) |> Map.put("dataBase64", marker <> sha)

        file ->
          file
      end)
      |> encode()
      |> String.split(marker)

    with {:ok, out} <- :file.open(path, [:write, :exclusive, :raw, :binary]) do
      try do
        :ok = File.chmod(path, 0o600)
        write_json(out, first, entities)

        for <<sha::binary-size(64), rest::binary>> <- pieces do
          on_disk[sha]
          |> File.stream!(@piece)
          |> Enum.each(&(:ok = :file.write(out, Base.encode64(&1))))

          write_json(out, rest, entities)
        end

        :ok = :file.close(out)
      rescue
        error ->
          :file.close(out)
          File.rm(path)
          reraise error, __STACKTRACE__
      end
    end
  end

  # A piece of the archive's JSON, with the entities file copied in where its marker is.
  defp write_json(out, json, nil), do: :ok = :file.write(out, json)

  defp write_json(out, json, {marker, source}) do
    case String.split(json, marker, parts: 2) do
      [json] ->
        :ok = :file.write(out, json)

      [before, rest] ->
        :ok = :file.write(out, before)
        source |> File.stream!(@piece) |> Enum.each(&(:ok = :file.write(out, &1)))
        :ok = :file.write(out, rest)
    end
  end

  # --- import --------------------------------------------------------------------

  @doc """
  Imports the archive at `path`; see `import_archive/2`. The files it carries are
  written to this machine's disk a piece at a time as the file is read, so a large
  thread file is not held in memory.
  """
  @spec import_file(Path.t(), keyword) :: {:ok, map} | {:error, String.t()}
  def import_file(path, opts \\ []) do
    path = Path.expand(path)
    dir = scratch()

    try do
      with {:ok, json, held} <- unpack(path, dir),
           {:ok, %{} = archive} <- JSON.decode(json),
           ^held <- Enum.sort(for %{"path" => path} <- files(archive), do: path) do
        import_archive(archive, opts)
      else
        {:unreadable, reason} ->
          {:error, "Could not read #{path}: #{:file.format_error(reason)}. Nothing was imported."}

        # Not a thread file, or one that names a file on this machine or keeps base64
        # somewhere other than a file it carries: read whole, it is told apart there.
        _ ->
          import_archive(File.read!(path), opts)
      end
    after
      File.rm_rf(dir)
    end
  end

  # A thread file's JSON without the files it carries: the bytes of each are written
  # into `dir`, and the JSON names that path where the file's base64 was. Returns the
  # JSON and the paths, sorted.
  defp unpack(path, dir) do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        File.mkdir_p!(dir)

        try do
          unpack(io, dir, "", [], [])
        after
          File.close(io)
        end

      {:error, reason} ->
        {:unreadable, reason}
    end
  end

  defp unpack(io, dir, buffer, json, held) do
    case :binary.match(buffer, @base64_key) do
      {at, length} when at > 0 ->
        {before, rest} = :erlang.split_binary(buffer, at)
        rest = binary_part(rest, length, byte_size(rest) - length)

        # Only as an object's key: quoted inside a longer string, a backslash precedes it.
        if :binary.last(before) in ~c"{," do
          to = Path.join(dir, Integer.to_string(length(held)))
          rest = File.open!(to, [:write, :raw, :binary], &unpack_file(io, &1, to, rest, true))
          unpack(io, dir, rest, [json, before, ~s("path":), JSON.encode!(to)], [to | held])
        else
          unpack(io, dir, rest, [json, before, @base64_key], held)
        end

      _ ->
        # The end of what was read may be the start of a key.
        keep = min(byte_size(buffer), byte_size(@base64_key))
        {done, tail} = :erlang.split_binary(buffer, byte_size(buffer) - keep)

        case :file.read(io, @piece) do
          {:ok, more} -> unpack(io, dir, tail <> more, [json, done], held)
          :eof -> {:ok, IO.iodata_to_binary([json, buffer]), Enum.sort(held)}
          {:error, reason} -> {:unreadable, reason}
        end
    end
  end

  # Writes the bytes of the base64 string `buffer` is inside of to `out`, and returns
  # what follows the string. Base64 that does not decode leaves no file, which fails
  # the file's checksum.
  defp unpack_file(io, out, to, buffer, ok) do
    case :binary.match(buffer, "\"") do
      {at, 1} ->
        {last, <<?", rest::binary>>} = :erlang.split_binary(buffer, at)
        unless ok and unpack_bytes(out, last), do: File.rm(to)
        rest

      :nomatch ->
        {now, carry} =
          :erlang.split_binary(buffer, byte_size(buffer) - rem(byte_size(buffer), 4))

        # Padding only ends base64.
        ok = ok and :binary.match(now, "=") == :nomatch and unpack_bytes(out, now)

        case :file.read(io, @piece) do
          {:ok, more} -> unpack_file(io, out, to, carry <> more, ok)
          _ -> ""
        end
    end
  end

  defp unpack_bytes(out, base64) do
    with {:ok, bytes} <- Base.decode64(base64),
         do: :file.write(out, bytes) == :ok,
         else: (_ -> false)
  end

  @doc """
  Imports an archive (its JSON or decoded map) onto this MC. `opts[:project]` names
  the project (title or id); without it the thread goes into the one project that is a
  checkout of the same repository. Returns `%{thread, title, project, notes}`, where
  `notes` are what the user should be told (checkpoints left behind, say).

  `opts[:replace]` true lets the archive replace this MC's copy of the thread,
  which a move back uses; otherwise a thread that is already here is refused.
  `opts[:move]` is the move that brought it from the MC `opts[:from]` (`HalC2.ThreadMove`).
  """
  @spec import_archive(binary | map, keyword) :: {:ok, map} | {:error, String.t()}
  def import_archive(data, opts \\ []) do
    with {:ok, archive} <- decode(data),
         :ok <- not_kept(archive),
         :ok <- not_here(archive, opts),
         :ok <- no_clash(archive),
         {:ok, project} <- resolve_project(archive, opts[:project]) do
      write(archive, project, opts)
    end
  end

  # A thread its plugin keeps on its machine (`stays/1`) is not taken in either, for an
  # MC from before plugins kept their threads sends it on: by its mark, or by the
  # plugin's manifest here for a mark from before the mark said so. What is read is
  # every thread entity the import would write: a version 2 archive's entities here, what
  # a version 1 archive's events fold into in `write_v1/2`, so the format's version
  # decides nothing. A mark in a form no MC writes names no plugin that could be asked,
  # so the file is taken as damaged rather than as an ordinary thread.
  defp not_kept(%{"version" => 1}), do: :ok

  defp not_kept(%{"thread" => meta} = archive),
    do:
      not_kept(
        for([kind, eid, entity] <- archive["entities"], do: {kind, eid, entity}),
        meta
      )

  defp not_kept(rows, meta) do
    title = meta["title"]

    Enum.find_value(rows, :ok, fn
      {"thread", _, %{"plugin" => %{"id" => owner} = mark}} when is_binary(owner) ->
        if kept?(owner, mark),
          do:
            {:error,
             "#{title} was started by #{owner}, which keeps it on the machine it started on. #{title} was not imported."}

      {"thread", _, %{"plugin" => mark}} when mark != nil ->
        {:error,
         "The file is damaged: #{title} names the plugin that started it in a form HAL-C2 does not write. Nothing was imported."}

      _ ->
        nil
    end)
  end

  # An attachment lands under its own name, so a different file this machine already
  # has there is never replaced; an identical one is kept as it is.
  defp no_clash(%{"thread" => meta} = archive) do
    Enum.find_value(archive["attachments"], :ok, fn %{"fileName" => name} = file ->
      path = Path.join(Attachments.dir(), name)

      if File.exists?(path) and not same_file?(file, path),
        do:
          {:error,
           "The attachment #{name} already exists on #{label()} with different contents. #{meta["title"]} was not imported."}
    end)
  end

  defp same_file?(%{"sha256" => sha}, path),
    do: File.regular?(path) and file_sha256(path) == String.downcase(to_string(sha))

  @doc """
  Checks an archive: its format, version and every checksum. Returns it decoded:
  the bytes of each file it carried as base64 under `"data"`, the files on disk as
  they were.
  """
  @spec decode(binary | map) :: {:ok, archive} | {:error, String.t()}
  def decode(data) when is_binary(data) do
    # A thread file holds the bytes of the files it carries: one that names a file on
    # this machine instead is not one.
    with {:ok, %{} = map} <- JSON.decode(data),
         false <- Enum.any?(files(map), &match?(%{"path" => _}, &1)) do
      decode(map)
    else
      _ -> {:error, "The file is damaged: it is not a HAL-C2 thread file. Nothing was imported."}
    end
  end

  def decode(%{"format" => @format, "version" => version})
      when is_integer(version) and version > @version,
      do:
        {:error,
         "This file needs a newer HAL-C2: it was written in version #{version} of the thread file format and this machine reads up to version #{@version}. Nothing was imported."}

  def decode(%{"format" => @format, "version" => version} = archive) when version in [1, 2] do
    with :ok <- holds_thread(archive),
         :ok <- safe_names(archive),
         {:ok, attachments} <- verify(archive["attachments"], "the attachment"),
         {:ok, logs} <- verify(archive["terminalLogs"] || [], "the terminal log"),
         {:ok, checkpoints} <- verify_bundle(archive["checkpoints"], "the checkpoints"),
         {:ok, worktree} <- verify_bundle(archive["worktree"], "the worktree's branch"),
         {:ok, session} <- verify_session(archive["session"]) do
      {:ok,
       %{
         archive
         | "attachments" => attachments
       }
       |> Map.put("terminalLogs", logs)
       |> Map.put("checkpoints", checkpoints)
       |> Map.put("worktree", worktree)
       |> Map.put("session", session)}
    end
  end

  def decode(_),
    do: {:error, "The file is damaged: it is not a HAL-C2 thread file. Nothing was imported."}

  # A version 2 archive's thread is its entities (a version 1 archive's, its events): one
  # without a list of them names no thread to write or to check (`not_kept/1`).
  defp holds_thread(%{"version" => 2, "entities" => entities}) when is_list(entities), do: :ok
  defp holds_thread(%{"version" => 1}), do: :ok
  defp holds_thread(_archive), do: decode(nil)

  # The attachments and terminal logs an archive carries land under the names it gives
  # them: a name that is a path, or one that is another thread's, would write over
  # what is not the thread's.
  defp safe_names(%{"thread" => %{"id" => id} = meta} = archive) when is_binary(id) do
    title = meta["title"] || id
    ours = attachment_ids(archive)

    problem =
      Enum.find_value(List.wrap(archive["attachments"]), fn file ->
        name = file["fileName"]

        cond do
          not plain_name?(name) -> "the attachment #{inspect(name)} is named with a folder path"
          not ours.(Path.rootname(name)) -> "the attachment #{name} is not one of #{title}'s"
          true -> nil
        end
      end) ||
        Enum.find_value(List.wrap(archive["terminalLogs"]), fn file ->
          name = file["fileName"]

          cond do
            not plain_name?(name) ->
              "the terminal log #{inspect(name)} is named with a folder path"

            archive["version"] == 1 and v1_terminal(name, id) == nil ->
              "the terminal log #{name} is not one of #{title}'s"

            true ->
              nil
          end
        end)

    if problem,
      do: {:error, "The file is not safe to import: #{problem}. Nothing was imported."},
      else: :ok
  end

  defp safe_names(_archive), do: :ok

  defp plain_name?(name),
    do:
      is_binary(name) and name not in ["", ".", ".."] and
        not String.contains?(name, ["/", "\\", <<0>>])

  # Whether an attachment id is the thread's: one its messages show (version 2), or one
  # named for it, as an earlier install named them (version 1).
  defp attachment_ids(%{"version" => 1, "thread" => %{"id" => id}}) do
    prefix = String.downcase(Attachments.thread_segment(id)) <> "-"
    &(Attachments.valid_id?(&1) and String.starts_with?(String.downcase(&1), prefix))
  end

  defp attachment_ids(archive) do
    ids =
      for [kind, _, entity] <- List.wrap(archive["entities"]),
          %{"id" => id} <- entity_attachments(kind, entity),
          into: MapSet.new(),
          do: id

    &(Attachments.valid_id?(&1) and MapSet.member?(ids, &1))
  end

  defp entity_attachments("message", entity), do: List.wrap(entity["attachments"])
  defp entity_attachments("turn-item", entity), do: item_attachment_refs(entity)
  defp entity_attachments(_kind, _entity), do: []

  defp verify(nil, _what), do: {:ok, []}

  defp verify(files, what) when is_list(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case verified(file) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        :error -> {:halt, damaged("#{what} #{file["fileName"]}")}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp verify(_files, what), do: damaged(what)

  defp verify_bundle(nil, _what), do: {:ok, nil}

  defp verify_bundle(%{"bundle" => bundle} = value, what) do
    case verified(bundle) do
      {:ok, bundle} -> {:ok, Map.put(value, "bundle", bundle)}
      :error -> damaged(what)
    end
  end

  defp verify_bundle(_value, what), do: damaged(what)

  defp verify_session(nil), do: {:ok, nil}

  defp verify_session(%{"files" => files} = session) do
    with {:ok, files} <- verify(files, "the agent's session file"),
         do: {:ok, %{session | "files" => files}}
  end

  defp verified(%{"sha256" => sha, "dataBase64" => b64} = file) when is_binary(b64) do
    with {:ok, data} <- Base.decode64(b64),
         true <- sha256(data) == String.downcase(to_string(sha)) do
      {:ok, file |> Map.delete("dataBase64") |> Map.put("data", data)}
    else
      _ -> :error
    end
  end

  defp verified(%{"sha256" => sha, "path" => path} = file) when is_binary(path) do
    if File.regular?(path) and file_sha256(path) == String.downcase(to_string(sha)),
      do: {:ok, file},
      else: :error
  end

  defp verified(_), do: :error

  defp damaged(what),
    do:
      {:error, "The file is damaged: #{what} does not match its checksum. Nothing was imported."}

  # A thread that is already here is refused, unless this MC only keeps a forwarding
  # record for it (it moved away and is coming back) or the caller replaces it.
  defp not_here(%{"thread" => %{"id" => id} = meta}, opts) do
    replace? = opts[:replace] == true

    case local_thread(id) do
      nil -> :ok
      %{"movedTo" => %{}} -> :ok
      _ when replace? -> :ok
      _ -> {:error, "#{meta["title"]} is already on #{label()}."}
    end
  end

  @doc """
  The project an archive lands in: `name` (a title or id), or the one project here
  that is a checkout of the archive's repository.
  """
  @spec resolve_project(archive, String.t() | nil) :: {:ok, map} | {:error, String.t()}
  def resolve_project(archive, name) do
    projects = local_projects()
    title = archive["thread"]["title"]

    if name do
      case Enum.find(projects, &(&1["id"] == name)) ||
             Enum.find(projects, &(&1["title"] == name)) do
        nil -> {:error, "There is no project #{name} on #{label()}. #{title} was not imported."}
        project -> {:ok, project}
      end
    else
      case candidates(projects, archive) do
        [project] ->
          {:ok, project}

        [] ->
          {:error,
           "No project on #{label()} is a checkout of the repository of #{title}. Name a project to import it into."}

        several ->
          {:error,
           "Several projects on #{label()} are checkouts of the repository of #{title} (#{Enum.map_join(several, ", ", & &1["title"])}). Name the one to import it into."}
      end
    end
  end

  # Version 1 files name only the project's root: the project at that root,
  # else a checkout of the same repository, else the only project.
  defp candidates(projects, %{"version" => 1, "thread" => meta} = archive) do
    root = meta["sourceWorkspaceRoot"]

    with [] <- Enum.filter(projects, &(root != nil and &1["workspaceRoot"] == root)),
         [] <- same_repository(projects, put_in(archive, ["thread", "projectRoot"], root)) do
      if length(projects) == 1, do: projects, else: []
    end
  end

  defp candidates(projects, archive), do: same_repository(projects, archive)

  @doc "This MC's projects that are checkouts of the archive's repository."
  def same_repository(projects \\ local_projects(), archive) do
    case archive["thread"]["repository"] || repository(archive["thread"]["projectRoot"]) do
      nil -> []
      key -> Enum.filter(projects, &(repository(&1["workspaceRoot"]) == key))
    end
  end

  @doc "This MC's projects that are not deleted, as their project rows."
  def local_projects do
    for {"project", row} <- local_rows(), row["deletedAt"] == nil, do: row
  end

  defp write(%{"version" => 1} = archive, project, _opts), do: write_v1(archive, project)

  defp write(archive, project, opts) do
    meta = archive["thread"]
    id = meta["id"]
    dest_root = project["workspaceRoot"]
    same_repo? = repository(dest_root) != nil and repository(dest_root) == meta["repository"]
    refs = refs_before(archive, dest_root, same_repo?)

    {checkpoint_notes, checkpoints_ok?} = place_checkpoints(archive, project, same_repo?)
    {worktree, worktree_notes} = place_worktree(archive, project, same_repo?)
    {carried_session, session_notes} = place_session(archive, worktree || dest_root, opts)

    to_root = rewriter(meta["projectRoot"], dest_root, meta["projectId"], project["id"])
    to_worktree = rewriter(meta["worktreePath"], worktree, nil, nil)
    rewrite = &to_root.(to_worktree.(&1))

    entities =
      for [kind, eid, entity] <- archive["entities"] do
        entity = rewrite.(entity)

        entity =
          if kind == "checkpoint" and not checkpoints_ok? and entity["status"] == "ready",
            do: Map.merge(entity, %{"status" => "missing", "files" => []}),
            else: entity

        {kind, eid, entity}
      end

    entities =
      entities
      |> Enum.map(&carried(&1, id, worktree, meta, dest_root))
      |> Enum.map(&with_session(&1, carried_session))
      |> Enum.map(&with_move(&1, id, opts[:from], opts[:move]))

    terminals =
      for %{"fileName" => terminal} = file <- archive["terminalLogs"], do: {terminal, file}

    placing_files(archive, id, terminals, fn ->
      at = archive["updatedAt"] || System.os_time(:millisecond)
      commit(id, changes(id, entities, at))

      {:ok,
       %{
         thread: id,
         title: meta["title"],
         project: project["id"],
         session: carried_session != nil,
         notes: checkpoint_notes ++ worktree_notes ++ session_notes
       }}
    end)
    |> case do
      {:error, _} = failed ->
        if worktree,
          do:
            HalC2.Vcs.remove_worktree(%{"cwd" => dest_root, "path" => worktree, "force" => true})

        PortableSessions.unplace(carried_session)
        restore_refs(dest_root, refs)
        failed

      done ->
        done
    end
  end

  # Writes the archive's attachments and the scrollback of `terminals` (`[{terminal,
  # file}]`), then runs `fun`, which records the thread. When that fails part way the
  # files are taken back: an attachment that was not here goes and every terminal's
  # scrollback is as it was, so the import leaves nothing behind.
  defp placing_files(archive, id, terminals, fun) do
    title = archive["thread"]["title"]
    had = Map.new(Terminal.saved_scrollback(id))

    new =
      for %{"fileName" => name} = file <- archive["attachments"],
          path = Path.join(Attachments.dir(), Path.basename(name)),
          not File.exists?(path),
          do: {file, path}

    try do
      for {file, path} <- new do
        File.mkdir_p!(Path.dirname(path))
        put(file, path)
      end

      for {terminal, file} <- terminals, do: Terminal.put_scrollback(id, terminal, bytes(file))
      fun.()
    rescue
      error ->
        for {_file, path} <- new, do: File.rm(path)

        for {terminal, _file} <- terminals do
          case had do
            %{^terminal => text} -> Terminal.put_scrollback(id, terminal, text)
            _ -> Terminal.delete_scrollback(id, terminal)
          end
        end

        {:error,
         "The import of #{title} failed: #{Exception.message(error)}. Nothing was imported."}
    end
  end

  # The thread's entity knows where it came from, so the agent can be told the project
  # moved; it works in its new worktree here, if it got one (the old one stays behind
  # on the machine it left). A plugin's mark stays behind too: a thread only moves once
  # its plugin stopped running, and the same plugin here holds nothing of it.
  defp carried({"thread", eid, entity}, id, worktree, meta, dest_root) when eid == id do
    arrived =
      if meta["projectRoot"] && meta["projectRoot"] != dest_root,
        do: %{"from" => meta["projectRoot"], "to" => dest_root, "machine" => meta["machine"]}

    entity =
      entity
      |> Map.drop(["movedTo", "moving", "plugin", "spacePage"])
      |> Map.put("worktreePath", worktree)
      |> then(&if(arrived, do: Map.put(&1, "arrived", arrived), else: &1))

    {"thread", eid, entity}
  end

  # A provider thread's own session stays on the machine it left unless it is carried
  # (`place_session/3`); without it the next message is a handoff.
  defp carried({"provider-thread", eid, entity}, _id, _worktree, _meta, _root) do
    ref = entity["nativeThreadRef"]
    entity = if is_map(ref), do: Map.put(entity, "nativeThreadRef", nil), else: entity
    {"provider-thread", eid, Map.delete(entity, "carriedSession")}
  end

  defp carried(row, _id, _worktree, _meta, _root), do: row

  # The thread keeps, wherever it goes next, the last move from each MC that brought it
  # here, so the MC a move left can ask whether that move arrived
  # (`ThreadMove.arrived?/2`). The last is enough: an MC moves the thread again only
  # once it came back, by which time its earlier move had settled.
  defp with_move({"thread", id, entity}, id, from, move) when is_binary(move),
    do: {"thread", id, Map.put(entity, "moves", Map.put(entity["moves"] || %{}, from, move))}

  defp with_move(row, _id, _from, _move), do: row

  # The provider thread whose session came along continues from the copy.
  defp with_session(
         {"provider-thread", eid, entity},
         %{"providerThreadId" => eid, "carriedSession" => session}
       ),
       do: {"provider-thread", eid, Map.put(entity, "carriedSession", session)}

  defp with_session(row, _carried), do: row

  # Every entity as a patch from what this MC has (nothing, or a forwarding record
  # and the copy it left behind), so a thread coming back does not repeat anything.
  defp changes(id, entities, at) do
    incoming = for {kind, eid, _} <- entities, into: MapSet.new(), do: {kind, eid}

    {have, existing} =
      read(id, fn current ->
        {for({kind, eid, _} <- StreamState.rows(current), into: MapSet.new(), do: {kind, eid}),
         StreamState.lookup(current, incoming)}
      end)

    deletes =
      for {kind, eid} <- have,
          not MapSet.member?(incoming, {kind, eid}),
          do: {kind, eid, Patch.delete(), at}

    upserts =
      for {kind, eid, entity} <- entities,
          patch = Patch.diff(existing[{kind, eid}], entity),
          patch != :unchanged,
          do: {kind, eid, patch, at}

    deletes ++ upserts
  end

  defp commit(_id, []), do: :ok

  defp commit(id, changes) do
    if Process.whereis(HalC2.Streams) do
      {:ok, _} = Streams.commit(id, :thread, changes)
      Streams.flush_shell(id)
    else
      HalC2.Search.storing_thread(id, fn ->
        {:ok, _} = Store.append([{:thread, id, changes}])
      end)

      HalC2.Projection.rebuild(id)
    end

    :ok
  end

  # --- version 1 (an earlier install's archive) ----------------------------------------

  # The thread's events are folded into its entities in a store of their own first, so
  # they reach this MC's store in the one commit a version 2 archive makes: an import
  # that fails leaves no event of it behind.
  defp write_v1(%{"thread" => %{"id" => id} = meta} = archive, project) do
    terminals =
      for %{"fileName" => name} = file <- archive["terminalLogs"],
          terminal = v1_terminal(name, id),
          do: {terminal, file}

    with {:ok, rows} <- fold_v1(archive, project, meta),
         :ok <- not_kept(rows, meta) do
      # A plugin's mark stays behind, as a version 2 archive's does (`carried/5`).
      rows =
        Enum.map(rows, fn
          {"thread", eid, entity} -> {"thread", eid, Map.delete(entity, "plugin")}
          row -> row
        end)

      placing_files(archive, id, terminals, fn ->
        commit(id, changes(id, rows, System.os_time(:millisecond)))

        {:ok,
         %{thread: id, title: meta["title"], project: project["id"], session: false, notes: []}}
      end)
    end
  end

  # The fold reads nothing of this machine's but the archive, so it runs before any file is
  # placed and a thread it shows is not to be taken in leaves nothing behind.
  defp fold_v1(archive, project, meta) do
    {:ok, v1_entities(archive, project, meta)}
  rescue
    error ->
      {:error,
       "The import of #{meta["title"]} failed: #{Exception.message(error)}. Nothing was imported."}
  end

  # The thread's entities, as `Import.V2` stores an earlier install's events. Provider
  # sessions from an earlier install do not come along: the next message hands the
  # conversation over. The files it removes are its own scratch files.
  # sobelow_skip ["Traversal.FileModule"]
  defp v1_entities(archive, project, %{"id" => id} = meta) do
    source = HalC2.Scratch.path("hal-c2-thread", ".sqlite")
    folded = HalC2.Scratch.path("hal-c2-thread-store", ".sqlite")

    rewrite =
      rewriter(
        meta["sourceWorkspaceRoot"],
        project["workspaceRoot"],
        meta["sourceProjectId"],
        project["id"]
      )

    try do
      events =
        for event <- archive["events"] || [], event["streamId"] == id do
          payload = event["payloadJson"] |> JSON.decode!() |> rewrite.()

          {event["aggregateKind"], event["streamId"], event["eventType"], payload,
           event["occurredAt"], event["applicationEventVersion"]}
        end

      node_log(source, events)
      {:ok, store} = Store.start_link(path: folded, name: nil)

      try do
        {:ok, _} = HalC2.Import.V2.run(source, store, only: [id])

        for {kind, eid, entity} <- StreamState.rows(StreamState.load(folded, id)) do
          if kind == "provider-thread" and is_map(entity["nativeThreadRef"]),
            do: {kind, eid, Map.put(entity, "nativeThreadRef", nil)},
            else: {kind, eid, entity}
        end
      after
        GenServer.stop(store)
      end
    after
      for path <- [source, folded, folded <> "-wal", folded <> "-shm"], do: File.rm(path)
    end
  end

  @doc "The terminal an earlier install's scrollback file `name` belongs to in `thread_id`, or `nil`."
  def v1_terminal(name, thread_id) do
    prefix = "terminal_#{Base.url_encode64(thread_id, padding: false)}"

    cond do
      name == prefix <> ".log" ->
        "term-1"

      String.starts_with?(name, prefix <> "_") and String.ends_with?(name, ".log") ->
        case name
             |> String.replace_prefix(prefix <> "_", "")
             |> String.replace_suffix(".log", "")
             |> Base.url_decode64(padding: false) do
          {:ok, terminal} -> terminal
          :error -> nil
        end

      true ->
        nil
    end
  end

  defp node_log(path, events) do
    alias Exqlite.Sqlite3
    {:ok, db} = Sqlite3.open(path)

    try do
      :ok =
        Sqlite3.execute(db, """
        CREATE TABLE orchestration_events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_kind TEXT, stream_id TEXT,
          event_type TEXT, payload_json TEXT, occurred_at TEXT, application_event_version INTEGER)
        """)

      {:ok, stmt} =
        Sqlite3.prepare(db, """
        INSERT INTO orchestration_events (aggregate_kind, stream_id, event_type, payload_json,
          occurred_at, application_event_version) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """)

      :ok = Sqlite3.execute(db, "BEGIN")

      for {aggregate, stream, type, payload, at, version} <- events do
        :ok = Sqlite3.bind(stmt, [aggregate, stream, type, JSON.encode!(payload), at, version])
        :done = Sqlite3.step(db, stmt)
      end

      :ok = Sqlite3.execute(db, "COMMIT")
      :ok = Sqlite3.release(db, stmt)
    after
      Sqlite3.close(db)
    end
  end

  # --- pieces ---------------------------------------------------------------------

  @doc "A short account of an archive: `%{thread, title, attachments, terminalLogs, checkpoints, session}`."
  def summary(archive) do
    %{
      thread: archive["thread"]["id"],
      title: archive["thread"]["title"],
      attachments: length(archive["attachments"] || []),
      terminal_logs: length(archive["terminalLogs"] || []),
      checkpoints: length((archive["checkpoints"] || %{})["refs"] || []),
      session: archive["session"] != nil
    }
  end

  defp attachments(state) do
    # What the messages carry, and what the turn items reference: an MCP app's
    # document and the images a tool call returned.
    for attachment <- message_attachments(state) ++ item_attachments(state),
        path = Attachments.path(attachment),
        path != nil,
        uniq: true,
        do: carried(Path.basename(path), path)
  end

  defp message_attachments(state) do
    for message <- StreamState.all(state, "message"),
        %{"id" => _} = attachment <- List.wrap(message["attachments"]),
        do: attachment
  end

  defp item_attachments(state) do
    for item <- StreamState.all(state, "turn-item"),
        attachment <- item_attachment_refs(item),
        do: attachment
  end

  @doc false
  # The attachments a turn item references: its MCP app document (`mcpApp`) and the
  # saved images of a tool call's `output` and `images`.
  def item_attachment_refs(item) do
    app =
      case item["mcpApp"] do
        %{"attachmentId" => id} when is_binary(id) -> [%{"id" => id}]
        _ -> []
      end

    images =
      for key <- ["output", "images"],
          %{"type" => "image", "id" => id} <- List.wrap(item[key]),
          is_binary(id),
          do: %{"id" => id}

    app ++ images
  end

  # The thread's checkpoint refs (and the workspace before its first run) as one
  # bundle, so diffs and rewinds work in another checkout of the repository.
  defp checkpoints(_state, nil, _have), do: nil

  defp checkpoints(state, root, have) do
    scopes = StreamState.list(state, "checkpoint-scope")

    refs =
      (for(c <- StreamState.list(state, "checkpoint"), is_binary(c["ref"]), do: c["ref"]) ++
         for(s <- scopes, do: Checkpoint.ref(s["id"], 0)))
      |> Enum.uniq()
      |> Enum.filter(&(is_binary(&1) and Checkpoint.exists?(scope_cwd(scopes, root), &1)))

    cwd = scope_cwd(scopes, root)

    with [_ | _] <- refs,
         {:ok, bundle} <- bundle(cwd, refs, known(cwd, have)) do
      %{"refs" => refs, "bundle" => made("checkpoints.bundle", bundle)}
    else
      _ -> nil
    end
  end

  # The branch of the thread's own worktree. When the destination has the branch's
  # commit already, the bundle is that one commit.
  defp worktree(%{"worktreePath" => path, "branch" => branch}, have)
       when is_binary(path) and is_binary(branch) do
    ref = "refs/heads/#{branch}"

    with true <- File.dir?(path),
         have = known(path, have),
         {:ok, reached} <- HalC2.Git.ok(path, ["rev-list", "-n", "1", ref, "--not" | have]),
         have = if(have != [] and reached == "", do: parents(path, ref), else: have),
         {:ok, bundle} <- bundle(path, [ref], have) do
      %{"branch" => branch, "path" => path, "bundle" => made("worktree.bundle", bundle)}
    else
      _ -> nil
    end
  end

  defp worktree(_thread, _have), do: nil

  # A bundle of `refs` without what the commits `have` reach, which the destination
  # has. Git leaves a commit's files out only when told of its tree, which is what
  # keeps a checkpoint (a commit with no parents) from carrying the whole checkout. A
  # ref those commits reach whole is left out of such a bundle, so then the refs are
  # bundled with everything they reach.
  defp bundle(cwd, refs, have) do
    path = scratch()
    without = have ++ Enum.map(have, &(&1 <> "^{tree}"))

    with [_ | _] <- have,
         {:ok, _} <- HalC2.Git.ok(cwd, ["bundle", "create", path] ++ refs ++ ["--not" | without]),
         {:ok, heads} <- HalC2.Git.ok(cwd, ["bundle", "list-heads", path]),
         true <- length(String.split(heads, "\n", trim: true)) == length(refs) do
      {:ok, path}
    else
      _ ->
        File.rm(path)
        with {:ok, _} <- HalC2.Git.ok(cwd, ["bundle", "create", path | refs]), do: {:ok, path}
    end
  end

  # The commits of `have` this checkout has too.
  defp known(_cwd, []), do: []

  defp known(cwd, have) do
    case HalC2.Git.ok(cwd, ["rev-list", "--no-walk=unsorted", "--ignore-missing" | have]) do
      {:ok, out} -> String.split(out, "\n", trim: true)
      _ -> []
    end
  end

  defp parents(cwd, ref) do
    case HalC2.Git.ok(cwd, ["rev-parse", ref <> "^@"]) do
      {:ok, out} -> String.split(out, "\n", trim: true)
      _ -> []
    end
  end

  defp scope_cwd(scopes, root) do
    Enum.find_value(scopes, root, fn scope ->
      if is_binary(scope["cwd"]) and File.dir?(scope["cwd"]), do: scope["cwd"]
    end)
  end

  # Fetches the carried checkpoint refs into the destination checkout. A different
  # repository keeps none, and says so.
  defp place_checkpoints(%{"checkpoints" => nil}, _root, _same), do: {[], true}

  defp place_checkpoints(%{"checkpoints" => checkpoints, "thread" => meta}, project, true) do
    root = project["workspaceRoot"]
    specs = for ref <- checkpoints["refs"], do: "+#{ref}:#{ref}"

    on_disk(checkpoints["bundle"], fn bundle ->
      case HalC2.Git.ok(root, ["fetch", "--no-tags", "-q", bundle | specs]) do
        {:ok, _} -> {[], true}
        {:error, _} -> {[checkpoints_note(meta, project, :failed)], false}
      end
    end)
  end

  defp place_checkpoints(%{"thread" => meta}, project, false),
    do: {[checkpoints_note(meta, project, :different)], false}

  # What the refs an import may write (the carried checkpoints and the worktree's
  # branch) point at in `root` before it: `[{ref, object | nil}]`.
  defp refs_before(_archive, _root, false), do: []

  defp refs_before(archive, root, true) do
    checkpoints = (archive["checkpoints"] || %{})["refs"] || []
    branch = (archive["worktree"] || %{})["branch"]
    refs = Enum.filter(checkpoints ++ List.wrap(branch && "refs/heads/#{branch}"), &plain_ref?/1)
    now = refs_now(root, refs)
    for ref <- refs, do: {ref, now[ref]}
  end

  defp plain_ref?(ref),
    do: is_binary(ref) and String.starts_with?(ref, "refs/") and not (ref =~ ~r/[\s\x00]/)

  defp refs_now(_root, []), do: %{}

  defp refs_now(root, refs) do
    case HalC2.Git.ok(root, ["for-each-ref", "--format=%(refname) %(objectname)" | refs]) do
      {:ok, out} ->
        for line <- String.split(out, "\n", trim: true),
            [ref, object] = String.split(line, " ", parts: 2),
            into: %{},
            do: {ref, object}

      {:error, _} ->
        %{}
    end
  end

  # Puts `refs` (`refs_before/3`) back: a ref the import made goes, one it moved points
  # where it did, and one nobody touched is left alone.
  defp restore_refs(_root, []), do: :ok

  defp restore_refs(root, refs) do
    now = refs_now(root, Enum.map(refs, &elem(&1, 0)))

    commands =
      for {ref, before} <- refs, now[ref] != before do
        if before,
          do: "update #{ref} #{before}\n",
          else: "delete #{ref} #{now[ref]}\n"
      end

    if commands != [],
      do: HalC2.Git.ok(root, ["update-ref", "--stdin"], input: Enum.join(commands))

    :ok
  end

  # A new worktree of `project` on the carried branch, put back to the thread's last
  # checkpoint. A branch of that name that has other commits here is left alone.
  defp place_worktree(%{"worktree" => nil}, _project, _same), do: {nil, []}
  defp place_worktree(%{"worktree" => _}, _project, false), do: {nil, []}

  defp place_worktree(%{"worktree" => worktree, "thread" => meta} = archive, project, true) do
    root = project["workspaceRoot"]
    branch = worktree["branch"]

    fetched =
      on_disk(worktree["bundle"], fn bundle ->
        HalC2.Git.ok(root, [
          "fetch",
          "--no-tags",
          "-q",
          bundle,
          "refs/heads/#{branch}:refs/heads/#{branch}"
        ])
      end)

    with {:ok, _} <- fetched,
         {:ok, %{"worktree" => %{"path" => path}}} <-
           HalC2.Vcs.create_worktree(%{"cwd" => root, "refName" => branch}) do
      if ref = last_checkpoint(archive), do: Checkpoint.restore(path, ref)
      {path, []}
    else
      _ ->
        {nil,
         [
           "#{meta["title"]} could not get its own worktree on the branch #{branch} in #{project["title"]} on #{label()}; it works in the project's checkout."
         ]}
    end
  end

  defp last_checkpoint(%{"checkpoints" => %{"refs" => refs}, "entities" => entities}) do
    entities
    |> Enum.filter(fn [kind, _, c] ->
      kind == "checkpoint" and c["status"] == "ready" and c["ref"] in refs
    end)
    |> Enum.max_by(fn [_, _, c] -> c["appRunOrdinal"] || 0 end, fn -> nil end)
    |> case do
      [_, _, c] -> c["ref"]
      nil -> nil
    end
  end

  defp last_checkpoint(_archive), do: nil

  @doc "What the user is told when a thread's checkpoints do not land in `project` here."
  def checkpoints_note(meta, project, :different),
    do:
      "Checkpoints of #{meta["title"]} stay behind: #{project["title"]} on #{label()} is a different repository, so runs from before the move have no diff and cannot be rewound to."

  def checkpoints_note(meta, project, :failed),
    do:
      "Checkpoints of #{meta["title"]} could not be copied into #{project["title"]} on #{label()}, so runs from before the move have no diff and cannot be rewound to."

  defp session(state, thread, cwd) do
    with %{"files" => files} = session <- PortableSessions.export(state, thread, cwd),
         do: %{session | "files" => for({name, source} <- files, do: session_file(name, source))}
  end

  # What a provider's own export printed goes to disk like the rest an archive makes.
  defp session_file(name, {:data, data}) do
    path = scratch()
    File.write!(path, data)
    File.chmod(path, 0o600)
    made(name, path)
  end

  defp session_file(name, path), do: carried(name, path)

  defp place_session(%{"session" => nil}, _root, _opts), do: {nil, []}

  defp place_session(%{"session" => session} = archive, root, opts) do
    if Keyword.get(opts, :session, true),
      do: PortableSessions.place(session, root, archive),
      else: {nil, []}
  end

  @doc """
  A function rewriting every string under `from` (a project root) to `to`, and the
  project id `from_id` to `to_id`, anywhere in a JSON-shaped value.
  """
  def rewriter(from, to, from_id, to_id) do
    fn value -> rewrite(value, from, to, from_id, to_id) end
  end

  defp rewrite(%{} = map, from, to, from_id, to_id) do
    Map.new(map, fn
      {"projectId", ^from_id} when from_id != nil -> {"projectId", to_id}
      {key, value} -> {key, rewrite(value, from, to, from_id, to_id)}
    end)
  end

  defp rewrite(list, from, to, from_id, to_id) when is_list(list),
    do: Enum.map(list, &rewrite(&1, from, to, from_id, to_id))

  defp rewrite(string, from, to, _from_id, _to_id)
       when is_binary(string) and is_binary(from) and is_binary(to) and from != "" and
              from != to,
       do: replace_root(string, from, to)

  defp rewrite(value, _from, _to, _from_id, _to_id), do: value

  # Only whole path segments: "/code/shop" does not match "/code/shop-app".
  defp replace_root(string, from, to) do
    if String.contains?(string, from),
      do: Regex.replace(~r/#{Regex.escape(from)}(?=$|[\/\\"'\s:;,)\]}])/, string, to),
      else: string
  end

  @doc "The repository a checkout belongs to, as `host/owner/repo`, from its origin."
  def repository(nil), do: nil

  def repository(root) do
    with true <- File.dir?(root),
         {:ok, url} <- HalC2.Git.ok(root, ~w(config --get remote.origin.url)),
         url when url != "" <- String.trim(url) do
      HalC2.AgentSessions.remote_key(url)
    else
      _ -> nil
    end
  end

  defp file(name, data),
    do: %{"fileName" => name, "sha256" => sha256(data), "dataBase64" => Base.encode64(data)}

  # A file carried from where it is on this machine's disk.
  defp carried(name, path) do
    %{
      "fileName" => name,
      "sha256" => file_sha256(path),
      "size" => File.stat!(path).size,
      "path" => path
    }
  end

  # A carried file that was made for the archive (`discard/1`).
  defp made(name, path), do: name |> carried(path) |> Map.put("temporary", true)

  @doc """
  Runs `fun` with carried files as `[{name, path}]` on this machine's disk, so what
  places them copies from disk to disk instead of holding a file in memory.
  """
  def files_on_disk(files, fun), do: files_on_disk(files, [], fun)

  defp files_on_disk([], paths, fun), do: fun.(Enum.reverse(paths))

  defp files_on_disk([%{"fileName" => name} = file | files], paths, fun),
    do: on_disk(file, &files_on_disk(files, [{name, &1} | paths], fun))

  # A carried file's bytes: only for what is kept small (a terminal's scrollback).
  defp bytes(%{"data" => data}), do: data
  defp bytes(%{"path" => path}), do: File.read!(path)

  # Writes a carried file to `path`.
  defp put(%{"data" => data}, path), do: File.write!(path, data)
  defp put(%{"path" => source}, path), do: File.cp!(source, path)

  # Runs `fun` with a carried file's path on this machine's disk.
  defp on_disk(%{"path" => path}, fun), do: fun.(path)

  defp on_disk(%{"data" => data}, fun) do
    path = scratch()
    File.write!(path, data)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  # Where a bundle made for an archive is written: the MC's own disk, since a system's
  # temporary directory is often kept in memory.
  defp scratch do
    File.mkdir_p!(scratch_dir())
    Path.join(scratch_dir(), Integer.to_string(System.unique_integer([:positive])))
  end

  defp scratch_dir, do: Path.join(HalC2.Paths.cache_dir(), "thread-bundles")

  @doc "Removes the bundles an MC that stopped part way through an archive left behind."
  def clear_scratch, do: File.rm_rf(scratch_dir())

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp file_sha256(path) do
    path
    |> File.stream!(@piece)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "A thread on this MC by id, or by title when only one has it."
  def find_thread(ref) do
    threads = for {"thread", row} <- local_rows(), do: row

    case Enum.find(threads, &(&1["id"] == ref)) ||
           Enum.filter(threads, &(&1["title"] == ref and &1["movedTo"] == nil)) do
      %{"id" => id} -> {:ok, id}
      [%{"id" => id}] -> {:ok, id}
      [] -> {:error, "There is no thread #{ref} on #{label()}."}
      _ -> {:error, "Several threads on #{label()} are called #{ref}. Name it by its id."}
    end
  end

  @doc """
  The threads the store at `path` holds that can be exported, most recently updated
  first, as `%{"id", "title", "project", "updatedAt"}` with the project's folder. Only
  reads the file, so it works while the MC is stopped.
  """
  def exportable(path) do
    rows = for {_id, kind, row} <- Store.list_shell(path), do: {kind, row}

    folders =
      for {"project", %{"id" => id} = row} <- rows, into: %{}, do: {id, row["workspaceRoot"]}

    for({"thread", row} <- rows, row["deletedAt"] == nil, row["movedTo"] == nil, do: row)
    |> Enum.sort_by(&(&1["updatedAt"] || ""), :desc)
    |> Enum.map(fn row ->
      %{
        "id" => row["id"],
        "title" => row["title"],
        "project" => folders[row["projectId"]],
        "updatedAt" => row["updatedAt"]
      }
    end)
  end

  # This MC's sidebar rows as stored, which a stream writes before it tells the shell.
  defp local_rows, do: for({_id, kind, row} <- Store.list_shell(Store.path()), do: {kind, row})

  @doc "This MC's thread entity for `id`, or `nil` when it has none."
  def local_thread(id) do
    if id in Enum.map(Store.list_streams(Store.path()), & &1.id),
      do: StreamState.get(state(id), "thread")[id]
  end

  defp state(id) do
    if Process.whereis(HalC2.Streams),
      do: HalC2.Streams.state(id),
      else: StreamState.load(Store.path(), id)
  end

  # `fun` of the thread's state, its older runs read from disk as they were when it was
  # taken (`HalC2.Streams.read/2`).
  defp read(id, fun) do
    if Process.whereis(HalC2.Streams),
      do: HalC2.Streams.read(id, fun),
      else: fun.(StreamState.load(Store.path(), id))
  end

  defp project(nil), do: nil

  defp project(id) do
    Enum.find_value(local_rows(), fn
      {"project", %{"id" => ^id} = row} -> row
      _ -> nil
    end)
  end

  defp moved_message(thread),
    do: "#{thread["title"]} has moved to #{thread["movedTo"]["label"] || "another machine"}."

  @doc "This machine's name, as clients show it."
  def label, do: HalC2.Environment.descriptor()["label"]

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
