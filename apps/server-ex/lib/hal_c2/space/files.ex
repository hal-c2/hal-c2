defmodule HalC2.Space.Files do
  @moduledoc """
  Pages that are project files (`features/space/project-files.feature`). Such a page
  has a `file` field naming the project and the file's path in the project's own folder,
  with the hash and size of what it last read or wrote there, whether the file is gone
  (`missing`), whether the page was edited while it was (`unwritten`) and when the file
  last won over an edit (`conflictAt`). A link in the project is followed to the file it
  names, which is read and written in its place; a link out of the project is no file.

  The page and the file are kept the same both ways:

    * In the Space's stream, every command that changes such a page's content writes the
      file in the same step (`follow/2`, from `HalC2.Space.transact/2`). The file is
      written as the page's Markdown (`HalC2.Space.Markdown`), which keeps what the page
      does not model as raw blocks, so a file comes back byte for byte but for what was
      edited. Should the file have changed since it was last read, the file wins: the
      page takes the file and says so, and the edit it lost is a version in its history.
      A file that can't be read or written refuses the edit, so the two never part.
    * This server follows the files: told a project folder changed (`changed/1`, sent
      at a turn's end, by a git action, a checkout and a save from the file viewer), it
      brings every page of a file that changed up to date, moving a page with its file
      when the file is somewhere else as it was, and once when the MC starts, for what
      changed while it was stopped.

  One file is behind at most one page: opening goes through this server, which knows
  every page that is a file. It learns them when it starts and as files are opened;
  what it knows is checked against the Space each time, so a page unlinked or deleted
  is simply passed over.
  """
  use GenServer

  alias HalC2.{Patch, ProjectFile, Space, StreamState, Streams, Workspace}
  alias HalC2.Space.{Blocks, Markdown, Pages}

  @author %{"type" => "file"}

  # Why a page's file is gone: the project or the file is, something else is where it
  # was, or it is a link out of the project.
  @gone [:enoent, :enotdir, :eisdir, :no_project, :outside]

  @doc "The author of what a page takes from its file."
  def author, do: @author

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Tells the server the files under `root` may have changed. Nothing when it is not running."
  def changed(root) when is_binary(root),
    do: GenServer.cast(__MODULE__, {:changed, Path.expand(root)})

  def changed(_root), do: :ok

  # A page wrote `path`, the real file under `root`: the other pages that are that file
  # through a link take it. Nothing when the server is not running.
  defp wrote(root, path), do: GenServer.cast(__MODULE__, {:wrote, root, path})

  @doc """
  The page of the project file `relative` in `space_id`, made when there is none, or the
  page it already is wherever it is (brought back from the trash). Replies with the
  Space, the page and whether it is new.
  """
  def open(space_id, project_id, relative),
    do: GenServer.call(__MODULE__, {:open, space_id, project_id, relative}, 30_000)

  @doc """
  The project's Space files: which entries say so (`"default"`, `"project"` or
  `"invalid"`, which counts none) and each file with its page, if it has one.
  """
  def list(project_id), do: GenServer.call(__MODULE__, {:list, project_id}, 30_000)

  @doc """
  Proposes a `spaces` section from the project's files and writes it, unless someone
  wrote one already (`replace` writes over it). The status is `"written"`, `"current"`
  when the section already is the proposal, `"kept"` or `"empty"` when there is no
  Markdown to propose; the entries are the proposal.
  """
  def scan(project_id, replace \\ false) do
    with {:ok, root} <- project(project_id) do
      proposal = ProjectFile.propose_spaces(Workspace.files(root))

      status =
        case ProjectFile.spaces(root) do
          _ when proposal == [] -> "empty"
          {:ok, :project, ^proposal} -> "current"
          {:ok, :default, _} -> "write"
          _ when replace == true -> "write"
          _ -> "kept"
        end

      with "write" <- status,
           :ok <- ProjectFile.put_spaces(root, proposal) do
        Workspace.invalidate(root)
        {:ok, %{"status" => "written", "entries" => proposal}}
      else
        {:error, reason} ->
          {:error, :invalid, "hal-c2.json could not be written: #{:file.format_error(reason)}"}

        status ->
          {:ok, %{"status" => status, "entries" => proposal}}
      end
    end
  end

  @doc "How many times the files under `root` were followed: what `await/2` waits past."
  def generation(root), do: GenServer.call(__MODULE__, {:generation, Path.expand(root)})

  @doc "Replies once the files under `root` were followed after `generation/1` gave `seen`."
  def await(root, seen),
    do: GenServer.call(__MODULE__, {:await, Path.expand(root), seen}, 30_000)

  @doc "Replies once the server has followed what changed while the MC was stopped."
  def drain, do: GenServer.call(__MODULE__, :drain, 30_000)

  # --- commands, decided in a Space's stream ----------------------------------------

  @doc "Reads the page's file again, taking what changed. Replies with the page."
  def sync(state, page_id, path \\ nil) do
    with {:ok, page} <- Pages.fetch_live(state, page_id),
         {:ok, file} <- file(page) do
      moved = if path, do: put_in(page, ["file", "path"], path), else: page

      case read(moved) do
        {:ok, text} ->
          if path == nil and not file["missing"] and hash(text) == file["hash"],
            do: {[], {:ok, page}},
            else: take(state, page, moved, text, nil)

        {:error, reason} when reason in @gone ->
          gone(page, moved, false)

        {:error, reason} ->
          unavailable(file, "read", reason)
      end
    end
    |> Pages.refused()
  end

  @doc "Makes a file's page an ordinary page: the file stays as it is."
  def unlink(state, page_id) do
    with %{} = page <- Pages.get(state, page_id) || no_page(page_id),
         {:ok, _} <- file(page) do
      next = %{page | "file" => nil, "updatedAt" => HalC2.Orchestration.Entities.now()}
      {[{"page", page_id, Patch.diff(page, next)}], {:ok, next}}
    end
    |> Pages.refused()
  end

  @doc """
  What follows `changes` to file pages in the same step: their files written, or their
  files taken where they changed first. A page whose `file` the changes themselves set
  (opened, synced, moved or unlinked) is left as they have it. Refuses the changes when
  an edited page's file can't be read or written.
  """
  def follow(state, changes) do
    next = Space.with_changes(state, changes)

    changes
    |> Enum.flat_map(&page_of(state, &1))
    |> Enum.uniq()
    |> Enum.reduce_while([], fn id, acc ->
      case follow_page(state, next, id) do
        {:error, _, _} = refused -> {:halt, refused}
        more -> {:cont, acc ++ more}
      end
    end)
  end

  defp page_of(_state, {"page", id, _patch}), do: [id]

  defp page_of(state, {"block", id, patch}) do
    case get_in(patch, ["s", "pageId"]) || (StreamState.get(state, "block")[id] || %{})["pageId"] do
      nil -> []
      page_id -> [page_id]
    end
  end

  defp page_of(_state, _change), do: []

  defp follow_page(state, next, id) do
    before = Pages.get(state, id)
    page = Pages.get(next, id)

    cond do
      page == nil or page["file"] == nil -> []
      before == nil or before["file"] != page["file"] -> []
      not Pages.live?(next, page) -> []
      true -> follow_file(next, page, content(state, before) != content(next, page))
    end
  end

  defp follow_file(state, page, edited) do
    file = page["file"]

    case read(page) do
      {:ok, text} ->
        cond do
          hash(text) != file["hash"] or file["missing"] ->
            {changes, _} = take(state, page, page, text, if(edited, do: now()))
            changes

          edited ->
            write(state, page, text)

          true ->
            []
        end

      {:error, reason} when reason in @gone ->
        {changes, _} = gone(page, page, edited)
        changes

      {:error, reason} when edited ->
        unavailable(file, "read", reason)

      {:error, _} ->
        []
    end
  end

  # What the page holds, as it is compared with the file.
  defp content(state, page),
    do: {page["title"], Enum.map(Blocks.of_page(state, page["id"]), &key/1)}

  # The page written to its file, keeping how the file ends its lines and itself. The
  # folder's listing is as it was and the page has the file's new hash, so the folder is
  # not followed; only another page that is the same file through a link is told.
  defp write(state, page, original) do
    file = page["file"]
    text = markdown(state, page, original)

    with false <- text == original,
         {:ok, root} <- root(file["projectId"]),
         {:ok, path} <- locate(root, file["path"]),
         :ok <- replace(path, text) do
      wrote(root, path)
      next = Map.merge(file, %{"hash" => hash(text), "size" => byte_size(text)})
      [{"page", page["id"], Patch.diff(page, %{page | "file" => %{next | "conflictAt" => nil}})}]
    else
      true -> []
      {:error, reason} -> unavailable(file, "written", reason)
    end
  end

  defp unavailable(file, done, reason) do
    {:error, :unavailable,
     "#{file["path"]} could not be #{done}: #{:file.format_error(reason)}. The page is as it was."}
  end

  defp markdown(state, page, original) do
    title_of = &(Pages.get(state, &1) || %{})["title"]
    blocks = Blocks.of_page(state, page["id"])

    # A file with no title of its own keeps none while the page has the file's name.
    untitled? =
      original == "" or
        (elem(Markdown.parse(original), 0) == nil and
           page["title"] == untitled(page["file"]["path"]))

    text =
      if untitled?,
        do: Markdown.document(blocks, title_of),
        else: Markdown.export(page, blocks, title_of)

    ending(text, original)
  end

  # `text` with the line ends of `original` and as many newlines at its end.
  defp ending(text, original) do
    [last] = Regex.run(~r/(?:\r?\n)*\z/, original)
    body = String.trim_trailing(text, "\n")

    body =
      if String.contains?(original, "\r\n"), do: String.replace(body, "\n", "\r\n"), else: body

    cond do
      body == "" -> ""
      original == "" -> body <> "\n"
      true -> body <> last
    end
  end

  # Written beside the file and renamed over it, so nothing reads half a file. `path` is
  # the file itself, not a link to it, so a link stays one. A read-only file stays as it
  # is, as an editor would leave it.
  defp replace(path, text) do
    temp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}"
      )

    with {:ok, %{access: access}} when access in [:write, :read_write] <- File.stat(path),
         :ok <- File.write(temp, text),
         :ok <- keep_mode(path, temp),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:ok, _stat} ->
        {:error, :eacces}

      error ->
        File.rm(temp)
        error
    end
  end

  defp keep_mode(path, temp) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> File.chmod(temp, mode)
      _ -> :ok
    end
  end

  # The page `before` as its file `page` (the same, or moved) says now: the title and
  # blocks it reads as, the blocks that read the same kept with their comments, and
  # those that changed changed in place. `conflict` is when the file won over an edit.
  defp take(state, before, page, text, conflict) do
    file = page["file"]
    # What the page was edited to while its file was gone, the file wins over as well.
    conflict = conflict || if(file["unwritten"], do: now())
    {heading, specs} = Markdown.parse(text)
    title = nonblank(heading) || untitled(file["path"])

    specs =
      Enum.map(specs, fn spec ->
        spec = Space.links(state, spec)
        Map.put(spec, "text", Blocks.text(state, spec))
      end)

    blocks = Blocks.of_page(state, page["id"])
    diff = List.myers_difference(Enum.map(blocks, &key/1), Enum.map(specs, &key/1))
    block_changes = edits(state, page["id"], diff, blocks, specs)

    fields = %{
      "hash" => hash(text),
      "size" => byte_size(text),
      "missing" => false,
      "unwritten" => false
    }

    fields = if conflict, do: Map.put(fields, "conflictAt", conflict), else: fields
    next = %{page | "title" => title, "file" => Map.merge(file, fields)}

    next =
      if next["title"] != before["title"] or block_changes != [],
        do: %{next | "updatedAt" => now()},
        else: next

    page_changes =
      case Patch.diff(before, next) do
        :unchanged -> []
        patch -> [{"page", page["id"], patch}]
      end

    {page_changes ++ block_changes, {:ok, next}}
  end

  # The file is gone: the page stays as it is and says so, and whether it was `edited`
  # since, which the file wins over should it come back.
  defp gone(before, page, edited) do
    next = put_in(page, ["file", "missing"], true)
    next = if edited, do: put_in(next, ["file", "unwritten"], true), else: next

    case Patch.diff(before, next) do
      :unchanged -> {[], {:ok, before}}
      patch -> {[{"page", page["id"], patch}], {:ok, next}}
    end
  end

  # Each run of differences: blocks paired with what the file has in their place are
  # changed in place, those left over go and what is left of the file comes after.
  defp edits(state, page_id, diff, blocks, specs) do
    {changes, _, _, anchor, pending} =
      Enum.reduce(diff, {[], blocks, specs, nil, {[], []}}, fn
        {:eq, keys}, {acc, blocks, specs, anchor, pending} ->
          acc = acc ++ settle(state, page_id, pending, anchor)
          {kept, blocks} = Enum.split(blocks, length(keys))
          {acc, blocks, Enum.drop(specs, length(keys)), List.last(kept)["id"], {[], []}}

        {:del, keys}, {acc, blocks, specs, anchor, {dels, ins}} ->
          {gone, blocks} = Enum.split(blocks, length(keys))
          {acc, blocks, specs, anchor, {dels ++ gone, ins}}

        {:ins, keys}, {acc, blocks, specs, anchor, {dels, ins}} ->
          {added, specs} = Enum.split(specs, length(keys))
          {acc, blocks, specs, anchor, {dels, ins ++ added}}
      end)

    changes ++ settle(state, page_id, pending, anchor)
  end

  # What a block read from the file holds beyond its kind and text, taken whole into the
  # block it replaces.
  @spec_fields Blocks.extras()

  defp settle(_state, _page_id, {[], []}, _anchor), do: []

  defp settle(state, page_id, {dels, ins}, anchor) do
    paired = Enum.zip(dels, ins)
    at = now()

    updates =
      Enum.flat_map(paired, fn {block, spec} ->
        next =
          block
          |> Map.drop(@spec_fields)
          |> Map.merge(%{
            "kind" => spec["kind"],
            "text" => spec["text"] || "",
            "checked" => spec["kind"] == "checklist" and spec["checked"] == true,
            "linkedPageId" => if(spec["kind"] == "subpage_link", do: spec["linkedPageId"])
          })
          |> Map.merge(Map.take(spec, @spec_fields))

        case Patch.diff(block, next) do
          :unchanged ->
            []

          _ ->
            next = Map.merge(next, %{"updatedBy" => @author, "updatedAt" => at})
            [{"block", block["id"], Patch.diff(block, next)}]
        end
      end)

    # A block the file no longer has goes; its comments stay on the page, as a
    # restore leaves them (`HalC2.Space.History`).
    deletes =
      dels
      |> Enum.drop(length(paired))
      |> Enum.flat_map(fn block ->
        stamp =
          if block["updatedBy"] == @author,
            do: [],
            else: [{"block", block["id"], %{"s" => %{"updatedBy" => @author}}}]

        stamp ++ [{"block", block["id"], Patch.delete()}]
      end)

    inserts =
      case Enum.drop(ins, length(paired)) do
        [] ->
          []

        specs ->
          after_id = with({block, _} <- List.last(paired), do: block["id"]) || anchor
          {changes, _} = Blocks.insert_all(state, page_id, specs, after_id, @author)
          changes
      end

    updates ++ deletes ++ inserts
  end

  # What a block says, which is what a page and its file are compared on.
  defp key(block) do
    kind = block["kind"]

    {kind, block["text"] || "", kind == "checklist" and block["checked"] == true,
     if(kind == "subpage_link", do: block["linkedPageId"]), block["imageId"],
     if(kind == "heading", do: Markdown.level(block)), block["gap"],
     if(kind == "code", do: Map.take(block, ~w(language fence info))),
     Map.take(block, ~w(url depth indent marker start alert label))}
  end

  defp file(%{"file" => %{} = file}), do: {:ok, file}
  defp file(_page), do: {:error, :invalid, "The page is not a file."}

  defp no_page(id), do: {:error, :not_found, "There is no page #{id} in this Space."}

  # What a page's file says.
  defp read(%{"file" => file}) do
    with {:ok, path} <- locate(file), do: File.read(path)
  end

  # Where the page's file is, its links followed, as long as that is in the project.
  defp locate(file) do
    with {:ok, root} <- root(file["projectId"]), do: locate(root, file["path"])
  end

  defp locate(root, relative) do
    with {:ok, top} <- real(root),
         {:ok, path} <- real(Path.join(top, relative)) do
      if String.starts_with?(path, top <> "/"), do: {:ok, path}, else: {:error, :outside}
    end
  end

  # `path` with every link in it followed; what does not exist is taken as written.
  defp real(path), do: real(Path.split(path), "/", 40)

  defp real([], at, _links), do: {:ok, at}
  defp real(_names, _at, 0), do: {:error, :eloop}
  defp real(["/" | rest], _at, links), do: real(rest, "/", links)
  defp real(["." | rest], at, links), do: real(rest, at, links)
  defp real([".." | rest], at, links), do: real(rest, Path.dirname(at), links)

  defp real([name | rest], at, links) do
    path = Path.join(at, name)

    case File.read_link(path) do
      {:ok, target} -> real(Path.split(target) ++ rest, at, links - 1)
      {:error, _} -> real(rest, path, links)
    end
  end

  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp untitled(path), do: Path.basename(path, Path.extname(path))

  defp nonblank(nil), do: nil
  defp nonblank(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  defp now, do: HalC2.Orchestration.Entities.now()

  @doc "The folder of the project `id` on this MC."
  def root(id) when is_binary(id) do
    case HalC2.Shell.row(node(), id) do
      {"project", %{"workspaceRoot" => root}} when is_binary(root) -> {:ok, Path.expand(root)}
      _ -> {:error, :no_project}
    end
  end

  def root(_id), do: {:error, :no_project}

  # --- the server -----------------------------------------------------------------

  @impl true
  def init(nil), do: {:ok, %{pages: %{}, generations: %{}, waiters: []}, {:continue, :start}}

  # Every page that is a file, and what its file did while the MC was stopped.
  @impl true
  def handle_continue(:start, state) do
    pages =
      for space <- StreamState.list(Streams.state(Space.index()), "space"),
          page <- StreamState.list(Streams.state(Space.stream_id(space["id"])), "page"),
          match?(%{"projectId" => _}, page["file"]),
          reduce: %{} do
        acc -> learn(acc, page["file"]["projectId"], space["id"], page["id"])
      end

    state = %{state | pages: pages}
    for {project_id, _} <- pages, do: follow_project(state, project_id)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:changed, root}, state) do
    for {project_id, _} <- state.pages,
        root(project_id) == {:ok, root},
        do: follow_project(state, project_id)

    generation = Map.get(state.generations, root, 0) + 1

    {ready, waiting} =
      Enum.split_with(state.waiters, fn {r, seen, _} -> r == root and seen < generation end)

    for {_, _, from} <- ready, do: GenServer.reply(from, :ok)

    {:noreply,
     %{state | generations: Map.put(state.generations, root, generation), waiters: waiting}}
  end

  def handle_cast({:wrote, root, path}, state) do
    for {project_id, _} <- state.pages,
        root(project_id) == {:ok, root},
        {space_id, space, page} <- linked(state, project_id),
        Pages.live?(space, page),
        locate(root, page["file"]["path"]) == {:ok, path},
        {:ok, text} <- [File.read(path)],
        hash(text) != page["file"]["hash"] or page["file"]["missing"],
        do: Space.transact(space_id, &sync(&1, page["id"]))

    {:noreply, state}
  end

  @impl true
  def handle_call({:open, space_id, project_id, relative}, _from, state) do
    case opened(state, space_id, project_id, relative) do
      {:ok, %{"spaceId" => s, "page" => page}} = reply ->
        {:reply, reply, %{state | pages: learn(state.pages, project_id, s, page["id"])}}

      refused ->
        {:reply, refused, state}
    end
  end

  def handle_call({:list, project_id}, _from, state) do
    reply =
      with {:ok, root} <- project(project_id) do
        {config, entries} =
          case ProjectFile.spaces(root) do
            {:ok, source, entries} -> {Atom.to_string(source), entries}
            {:error, :invalid} -> {"invalid", []}
          end

        pages =
          for {space_id, _space, page} <- linked(state, project_id), into: %{} do
            {page["file"]["path"],
             %{"spaceId" => space_id, "pageId" => page["id"], "title" => page["title"]}}
          end

        files =
          for path <- Enum.sort(Workspace.files(root)),
              kind = ProjectFile.space_kind(entries, path),
              kind != nil,
              do: %{"relativePath" => path, "kind" => kind, "page" => pages[path]}

        {:ok, %{"config" => config, "files" => files}}
      end

    {:reply, reply, state}
  end

  def handle_call({:generation, root}, _from, state),
    do: {:reply, Map.get(state.generations, root, 0), state}

  def handle_call({:await, root, seen}, from, state) do
    if Map.get(state.generations, root, 0) > seen,
      do: {:reply, :ok, state},
      else: {:noreply, %{state | waiters: [{root, seen, from} | state.waiters]}}
  end

  def handle_call(:drain, _from, state), do: {:reply, :ok, state}

  defp learn(pages, project_id, space_id, page_id),
    do:
      Map.update(
        pages,
        project_id,
        MapSet.new([{space_id, page_id}]),
        &MapSet.put(&1, {space_id, page_id})
      )

  # The pages of the project's files, as the Spaces have them now.
  # Each Space's state is read once, however many of its pages are files.
  defp linked(state, project_id) do
    by_space = Enum.group_by(Map.get(state.pages, project_id, []), &elem(&1, 0), &elem(&1, 1))

    for {space_id, page_ids} <- by_space,
        {:ok, space} <- [Space.state(space_id)],
        page_id <- page_ids,
        %{"file" => %{"projectId" => ^project_id}} = page <- [Pages.get(space, page_id)],
        do: {space_id, space, page}
  end

  # Pages in the order of their paths, each moved file claimed as it is found, so a file
  # two vanished files could be is taken by one page only.
  defp follow_project(state, project_id) do
    with {:ok, root} <- root(project_id) do
      linked =
        Enum.sort_by(linked(state, project_id), fn {_, _, page} -> page["file"]["path"] end)

      taken = MapSet.new(linked, fn {_, _, page} -> page["file"]["path"] end)

      for {space_id, space, page} <- linked, Pages.live?(space, page), reduce: taken do
        taken ->
          file = page["file"]

          case read(page) do
            {:ok, text} ->
              if hash(text) != file["hash"] or file["missing"],
                do: Space.transact(space_id, &sync(&1, page["id"]))

              taken

            {:error, reason} when reason in @gone ->
              path = moved(root, file, taken)
              Space.transact(space_id, &sync(&1, page["id"], path))
              if path, do: MapSet.put(taken, path), else: taken

            # Not readable for now: the page stays as it is until it is.
            {:error, _} ->
              taken
          end
      end
    end

    :ok
  end

  # Where the file went, when exactly one Space file no page has is it as it was: of two
  # copies of a template, or two empty files, neither is the page's file.
  defp moved(_root, %{"missing" => true}, _taken), do: nil

  defp moved(root, file, taken) do
    with {:ok, _, entries} <- ProjectFile.spaces(root),
         [path] <-
           Enum.filter(Workspace.files(root), fn path ->
             not MapSet.member?(taken, path) and ProjectFile.space_kind(entries, path) != nil and
               same?(Path.join(root, path), file)
           end) do
      path
    else
      _ -> nil
    end
  end

  defp same?(path, %{"size" => size, "hash" => digest}) do
    with {:ok, %{size: ^size}} <- File.stat(path),
         {:ok, text} <- File.read(path) do
      hash(text) == digest
    else
      _ -> false
    end
  end

  defp opened(state, space_id, project_id, relative) do
    with {:ok, root} <- project(project_id),
         {:ok, relative} <- inside(root, relative),
         :ok <- space_file(root, relative) do
      case Enum.find(linked(state, project_id), fn {_, _, page} ->
             page["file"]["path"] == relative
           end) do
        {s, _space, page} -> reopened(s, page)
        nil -> create(space_id, project_id, root, relative)
      end
    end
  end

  defp project(id) do
    with {:error, :no_project} <- root(id),
         do: {:error, :not_found, "There is no project #{id} on this MC."}
  end

  # The path in the project, where a link it is leads as well.
  defp inside(root, relative) when is_binary(relative) do
    full = Path.expand(relative, root)

    if String.starts_with?(full, root <> "/") and locate(root, relative) != {:error, :outside},
      do: {:ok, Path.relative_to(full, root)},
      else: {:error, :invalid, "#{relative} is not in the project."}
  end

  defp inside(_root, _relative), do: {:error, :invalid, "relativePath is required."}

  defp space_file(root, relative) do
    with {:ok, _, entries} <- ProjectFile.spaces(root),
         kind when kind != nil <- ProjectFile.space_kind(entries, relative) do
      :ok
    else
      _ -> {:error, :not_space_file, "#{relative} is not one of the project's Space files."}
    end
  end

  # The page the file already is, back from the trash and up to date.
  defp reopened(space_id, page) do
    with {:ok, _} <-
           if(page["trashedAt"], do: Space.restore_page(space_id, page["id"]), else: {:ok, page}),
         {:ok, page} <- Space.transact(space_id, &sync(&1, page["id"])),
         do: {:ok, %{"spaceId" => space_id, "page" => page, "created" => false}}
  end

  defp create(space_id, project_id, root, relative) do
    case with({:ok, path} <- locate(root, relative), do: File.read(path)) do
      {:ok, text} ->
        Space.transact(space_id, &created(&1, space_id, project_id, relative, text))
        |> case do
          {:ok, page} -> {:ok, %{"spaceId" => space_id, "page" => page, "created" => true}}
          refused -> refused
        end

      {:error, _} ->
        {:error, :not_found, "There is no file #{relative} in the project."}
    end
  end

  defp created(state, space_id, project_id, relative, text) do
    {heading, specs} = Markdown.parse(text)

    file = %{
      "projectId" => project_id,
      "path" => relative,
      "hash" => hash(text),
      "size" => byte_size(text),
      "missing" => false,
      "unwritten" => false,
      "conflictAt" => nil
    }

    title = nonblank(heading) || untitled(relative)

    with {page_changes, {:ok, page}} <-
           Pages.create(state, space_id, title, nil, %{"file" => file}),
         state = Space.with_changes(state, page_changes),
         {block_changes, {:ok, _}} <-
           Blocks.insert_all(
             state,
             page["id"],
             Enum.map(specs, &Space.links(state, &1)),
             :last,
             @author
           ) do
      {page_changes ++ block_changes, {:ok, page}}
    end
  end
end
