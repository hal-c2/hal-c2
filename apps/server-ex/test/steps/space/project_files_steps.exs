defmodule HalC2.Steps.Space.ProjectFiles do
  @moduledoc """
  Steps for `features/space/project-files.feature`. The project's files live in its git
  repository and are committed as a step writes them, so a branch can be switched.
  An agent's turn is played by `test/support/fake_codex.py` ("put", "rename",
  "remove"); a step that changes files waits for `HalC2.Space.Files` to have followed
  the project folder since (`Files.await/2`), never for a time. A `\\n` in a step's
  text is a line end. The last open is `context.opened`, the one before it
  `context.first_opened`; the last refusal is `context.space_reply`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.{ProjectFile, Space, StreamState, Streams}
  alias HalC2.Space.{Blocks, Files}
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @fixtures Path.expand("../../fixtures/space", __DIR__)

  # --- the project's files -----------------------------------------------------------

  step "{string} has the files {string}", %{args: [project, paths]} = context do
    context = files(context)
    root = root(context, project)

    for path <- String.split(World.git!(root, ["ls-files"]), "\n", trim: true),
        path not in names(paths),
        do: File.rm!(Path.join(root, path))

    for path <- names(paths),
        do: put(root, path, "# #{String.capitalize(Path.basename(path, ".md"))}\n")

    commit(root)
    context
  end

  step "{string} has the file {string} reading {string}",
       %{args: [project, path, text]} = context do
    put_file(context, project, path, unescape(text))
  end

  step "{string} has the file {string} reading:", %{args: [project, path]} = context do
    put_file(context, project, path, context.docstring)
  end

  step "{string} has the file {string} copied from the fixture {string}",
       %{args: [project, path, fixture]} = context do
    put_file(context, project, path, File.read!(Path.join(@fixtures, fixture)))
  end

  step "{string} of {string} reads {string}", %{args: [path, project, text]} = context do
    assert File.read!(Path.join(root(context, project), path)) == unescape(text)
    context
  end

  step "{string} of {string} reads:", %{args: [path, project]} = context do
    assert File.read!(Path.join(root(context, project), path)) == context.docstring
    context
  end

  step "{string} of {string} starts with {string}", %{args: [path, project, text]} = context do
    assert String.starts_with?(File.read!(Path.join(root(context, project), path)), text)
    context
  end

  step "{string} of {string} does not exist", %{args: [path, project]} = context do
    refute File.exists?(Path.join(root(context, project), path))
    context
  end

  step "{string} of {string} is the fixture {string}",
       %{args: [path, project, fixture]} = context do
    assert File.read!(Path.join(root(context, project), path)) ==
             File.read!(Path.join(@fixtures, fixture))

    context
  end

  step "{string} of {string} is the fixture {string} with that paragraph changed to {string}",
       %{args: [path, project, fixture, after_text]} = context do
    fixture = File.read!(Path.join(@fixtures, fixture))
    [before, rest] = :binary.split(fixture, context.changed_paragraph)
    assert File.read!(Path.join(root(context, project), path)) == before <> after_text <> rest
    context
  end

  step "{string} of {string} was rewritten outside HAL-C2 to {string}",
       %{args: [path, project, text]} = context do
    File.write!(Path.join(root(context, project), path), unescape(text))
    context
  end

  step "{string} of {string} is read-only", %{args: [path, project]} = context do
    File.chmod!(Path.join(root(context, project), path), 0o444)
    context
  end

  step "{string} of {string} was replaced by a folder outside HAL-C2",
       %{args: [path, project]} = context do
    file = Path.join(root(context, project), path)
    File.rm!(file)
    File.mkdir_p!(file)
    context
  end

  step "{string} of {string} links to {string}", %{args: [path, project, target]} = context do
    link(Path.join(root(context, project), path), target)
    context
  end

  step "{string} of {string} links to a file outside the project",
       %{args: [path, project]} = context do
    root = root(context, project)
    outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}.md")
    File.write!(outside, "# Outside\n\nNot the project's.")
    link(Path.join(root, path), outside)
    context
  end

  step "{string} of {string} still links to {string}",
       %{args: [path, project, target]} = context do
    assert File.read_link(Path.join(root(context, project), path)) == {:ok, target}
    context
  end

  # --- the spaces section ------------------------------------------------------------

  step "the spaces section of {string} is set to {string}",
       %{args: [project, entries]} = context do
    put_section(context, project, %{"files" => entries(entries)})
  end

  step "the spaces section of {string} is {string}", %{args: [project, json]} = context do
    put_section(context, project, JSON.decode!(json))
  end

  step "{string} declares the script {string}", %{args: [project, name]} = context do
    edit_project_file(context, project, fn file ->
      Map.update(file, "scripts", [script(name)], &(&1 ++ [script(name)]))
    end)
  end

  step "the scripts of {string} are {string}", %{args: [project, names]} = context do
    assert Enum.map_join(ProjectFile.scripts(root(context, project)), ", ", & &1["name"]) == names
    context
  end

  step "the hal-c2.json of {string} reads:", %{args: [project]} = context do
    File.write!(Path.join(root(context, project), "hal-c2.json"), context.docstring)
    context
  end

  step "the hal-c2.json of {string} still has the comment {string}",
       %{args: [project, comment]} = context do
    assert File.read!(Path.join(root(context, project), "hal-c2.json")) =~ comment
    context
  end

  step "the spaces section of {string} lists {string}", %{args: [project, entries]} = context do
    assert {:ok, :project, listed} = ProjectFile.spaces(root(context, project))
    assert listed == entries(entries)
    context
  end

  step "{string} has no spaces section", %{args: [project]} = context do
    assert {:ok, :default, _} = ProjectFile.spaces(root(context, project))
    context
  end

  # --- listing and scanning ----------------------------------------------------------

  step "the user lists the Space files of {string}", %{args: [project]} = context do
    context = files(context)
    payload = %{"projectId" => World.project(context, project).id}
    {listed, context} = World.call!(context, "space.files.list", payload)
    Map.put(context, :space_files, listed)
  end

  step "the Space files are {string}", %{args: [files]} = context do
    listed =
      Enum.map_join(context.space_files["files"], ", ", &"#{&1["relativePath"]} #{&1["kind"]}")

    assert listed == files
    context
  end

  step "the user is told the spaces section does not match the format", context do
    assert context.space_files["config"] == "invalid"
    context
  end

  step "{string} is listed as the page {string} in {string}",
       %{args: [path, title, space]} = context do
    file = Enum.find(context.space_files["files"], &(&1["relativePath"] == path))
    assert %{"title" => ^title, "spaceId" => id} = file["page"]
    assert id == context.spaces[space]
    context
  end

  step "{string} is listed as not open", %{args: [path]} = context do
    assert %{"page" => nil} =
             Enum.find(context.space_files["files"], &(&1["relativePath"] == path))

    context
  end

  step "the user scans {string} for Space files", %{args: [project]} = context do
    scan(context, project, false)
  end

  step "the user has scanned {string} for Space files", %{args: [project]} = context do
    scan(context, project, false)
  end

  step "the user scans {string} for Space files and replaces the spaces section",
       %{args: [project]} = context do
    scan(context, project, true)
  end

  step "the user is told the scan wrote the spaces section", context do
    assert {:ok, %{"status" => "written"}} = context.scan
    context
  end

  step "the user is told the spaces section was already written and is shown {string}",
       %{args: [entries]} = context do
    assert {:ok, %{"status" => "kept", "entries" => proposal}} = context.scan
    assert proposal == entries(entries)
    context
  end

  step "the user is told the spaces section is already what the scan finds", context do
    assert {:ok, %{"status" => "current"}} = context.scan
    context
  end

  step "the user is told the scan found no Space files", context do
    assert {:ok, %{"status" => "empty"}} = context.scan
    context
  end

  # --- opening -----------------------------------------------------------------------

  step "the user opens {string} of {string} in {string}",
       %{args: [path, project, space]} = context do
    open(context, World.project(context, project).id, path, space)
  end

  step "the user has opened {string} of {string} in {string}",
       %{args: [path, project, space]} = context do
    context = open(context, World.project(context, project).id, path, space)
    assert {:ok, _} = context.space_reply
    context
  end

  step "the user opens {string} of the project {string} in {string}",
       %{args: [path, project, space]} = context do
    open(context, project, path, space)
  end

  step "the user opens {string} from a worktree of {string} in {string}",
       %{args: [path, project, space]} = context do
    root = root(context, project)
    worktree = Path.join(Mc.tmp_dir(context.mc, "worktree"), "copy")
    World.git!(root, ["worktree", "add", "-q", "-b", "copy", worktree])

    # A client opening the worktree's copy names the file by its place in the project.
    context
    |> Map.put(:worktree, worktree)
    |> open(World.project(context, project).id, path, space)
  end

  step "the user was taken to the page they opened before", context do
    assert {:ok, %{"page" => page, "created" => false}} = context.space_reply
    assert {:ok, %{"page" => first}} = context.first_opened
    assert page["id"] == first["id"]
    context
  end

  step "the page {string} follows the project's own folder", %{args: [title]} = context do
    page = page!(context, title)
    copy = Path.join(context.worktree, page["file"]["path"])
    File.write!(copy, "# Guide\n\nOnly in the worktree.")
    changed(context, context.worktree)
    assert page!(context, title)["file"] == page["file"]
    context
  end

  step "the user is told {string} is not one of the project's Space files",
       %{args: [_]} = context do
    refused(context, "notSpaceFile")
  end

  step "the user is told {string} is not in the project", %{args: [_]} = context do
    refused(context, "invalid")
  end

  step "the user is told {string} could not be written", %{args: [path]} = context do
    refused(context, "unavailable")
    assert {:error, message, _} = context.space_reply
    assert message =~ "#{path} could not be written"
    context
  end

  step "the user is told there is no file {string}", %{args: [_]} = context do
    refused(context, "notFound")
  end

  step "the user is told there is no project {string} on this MC", %{args: [_]} = context do
    refused(context, "notFound")
  end

  step "the page {string} is backed by {string} of {string}",
       %{args: [title, path, project]} = context do
    assert %{"path" => ^path, "projectId" => id} = page!(context, title)["file"]
    assert id == World.project(context, project).id
    context
  end

  step "the page {string} is still backed by {string}", %{args: [title, path]} = context do
    assert %{"path" => ^path} = page!(context, title)["file"]
    context
  end

  step "the page {string} is not backed by a file", %{args: [title]} = context do
    assert page!(context, title)["file"] == nil
    context
  end

  step "the second client sees the page {string} backed by {string}",
       %{args: [title, path]} = context do
    match? = fn frame ->
      frame["t"] == "events" and
        Enum.any?(frame["events"], fn [_seq, kind, _id, patch | _] ->
          kind == "page" and is_map(patch["s"]) and patch["s"]["title"] == title and
            get_in(patch, ["s", "file", "path"]) == path
        end)
    end

    {_, client} = Mc.await(World.client(context, "second"), match?, 5_000)
    World.put_client(context, "second", client)
  end

  # --- the page --------------------------------------------------------------------

  step "the page {string} shows {string}", %{args: [title, text]} = context do
    assert Enum.join(texts(context, title), "\n\n") == unescape(text)
    context
  end

  step "the user has moved the page {string} to the trash", %{args: [title]} = context do
    {_, context} = World.call!(context, "space.page.trash", page_ref(context, title))
    context
  end

  step "the user commented {string} on the block {string}", %{args: [body, text]} = context do
    block = block!(context, text)

    payload = %{
      "spaceId" => context.space,
      "pageId" => block["pageId"],
      "blockId" => block["id"],
      "body" => body
    }

    {_, context} = World.call!(context, "space.comment.add", payload)
    context
  end

  step "the user changed the block {string} to {string}", %{args: [text, next]} = context do
    payload = %{
      "spaceId" => context.space,
      "blockId" => block!(context, text)["id"],
      "text" => next
    }

    {_, context} = World.call!(context, "space.block.update", payload)
    context
  end

  step "the user changes the paragraph starting {string} to {string}",
       %{args: [start, next]} = context do
    block =
      Enum.find(StreamState.list(state(context), "block"), fn block ->
        block["kind"] == "paragraph" and String.starts_with?(block["text"], start)
      end) || flunk("no paragraph starting #{inspect(start)}")

    payload = %{"spaceId" => context.space, "blockId" => block["id"], "text" => next}
    {_, context} = World.call!(context, "space.block.update", payload)
    Map.put(context, :changed_paragraph, block["text"])
  end

  step "the user opens the page {string} again", %{args: [title]} = context do
    {_, context} = World.call!(context, "space.page.syncFile", page_ref(context, title))
    context
  end

  step "the user unlinks the page {string} from its file", %{args: [title]} = context do
    {reply, context} = World.call(context, "space.page.unlinkFile", page_ref(context, title))
    Map.put(context, :space_reply, reply)
  end

  step "the user unlinked the page {string} from its file", %{args: [title]} = context do
    {_, context} = World.call!(context, "space.page.unlinkFile", page_ref(context, title))
    context
  end

  step "the page request is accepted", context do
    assert {:ok, _} = context.space_reply
    context
  end

  step "the page {string} says the file changed under the user's edit",
       %{args: [title]} = context do
    assert is_binary(page!(context, title)["file"]["conflictAt"])
    context
  end

  step "the page {string} no longer says the file changed under the user's edit",
       %{args: [title]} = context do
    assert page!(context, title)["file"]["conflictAt"] == nil
    context
  end

  step "the page {string} says its file is gone", %{args: [title]} = context do
    assert page!(context, title)["file"]["missing"] == true
    context
  end

  step "the page {string} no longer says its file is gone", %{args: [title]} = context do
    assert page!(context, title)["file"]["missing"] == false
    context
  end

  step "the user is told a page that is a file does not update itself", context do
    refused(context, "fileBacked")
  end

  step "the user asks for a chart of {string} on {string}", %{args: [request, title]} = context do
    payload = Map.put(page_ref(context, title), "request", request)
    {reply, context} = World.call(context, "space.block.visualize", payload)
    Map.put(context, :space_reply, reply)
  end

  step "the user is told a chart is not drawn on a page that is a file", context do
    refused(context, "fileBacked")
  end

  # --- history -------------------------------------------------------------------------

  step "the newest version of {string} is by the thread {string}",
       %{args: [title, thread]} = context do
    assert %{"author" => %{"threadId" => id}} = hd(versions(context, title))
    assert id == World.thread_id(context, thread)
    context
  end

  step "the newest version of {string} is by the project file", %{args: [title]} = context do
    assert hd(versions(context, title))["author"] == Files.author()
    context
  end

  step "the user restores the version of {string} that read {string}",
       %{args: [title, text]} = context do
    ref = page_ref(context, title)

    version =
      Enum.find_value(versions(context, title), fn %{"version" => version} ->
        {read, _} = World.call!(context, "space.page.version", Map.put(ref, "version", version))
        if Enum.map_join(read["blocks"], "\n\n", & &1["text"]) == text, do: version
      end) || flunk("no version of #{inspect(title)} read #{inspect(text)}")

    {_, context} =
      World.call!(context, "space.page.restoreVersion", Map.put(ref, "version", version))

    context
  end

  # --- agents, git, the file viewer and restarts -----------------------------------------

  step "a thread {string} in {string}", %{args: [thread, project]} = context do
    World.create_thread(context, thread, project)
  end

  step "an agent in {string} rewrites {string} to {string} and its turn ends",
       %{args: [project, path, text]} = context do
    turn(context, project, "put #{path} #{JSON.encode!(unescape(text))}")
  end

  step "an agent in {string} moves {string} to {string} and its turn ends",
       %{args: [project, path, next]} = context do
    turn(context, project, "rename #{path} #{next}")
  end

  step "an agent in {string} deletes {string} and its turn ends",
       %{args: [project, path]} = context do
    turn(context, project, "remove #{path}")
  end

  step "an agent in {string} deleted {string}", %{args: [project, path]} = context do
    turn(context, project, "remove #{path}")
  end

  step "the agent in {string} scans {string} for Space files",
       %{args: [thread, _project]} = context do
    context = files(context)
    reply = World.mcp_tool(context, thread, "hal_c2_space_files_scan", %{})
    assert {:ok, %{"status" => "written"}} = reply
    context
  end

  step "the agent in {string} opens {string} of {string} in {string}",
       %{args: [thread, path, _project, space]} = context do
    arguments = %{"spaceId" => context.spaces[space], "relativePath" => path}

    assert {:ok, %{"page" => _}} =
             World.mcp_tool(context, thread, "hal_c2_page_open_file", arguments)

    context
  end

  step "the agent sees the page is backed by {string} of {string}",
       %{args: [path, project]} = context do
    assert {:ok, %{"page" => %{"file" => file}}} = context.page_tool
    assert %{"path" => ^path, "projectId" => id} = file
    assert id == World.project(context, project).id
    context
  end

  step "the user saves {string} of {string} in the file viewer as {string}",
       %{args: [path, project, text]} = context do
    root = root(context, project)
    seen = Files.generation(root)
    payload = %{"cwd" => root, "relativePath" => path, "contents" => unescape(text)}
    {_, context} = World.call!(context, "projects.writeFile", payload)
    :ok = Files.await(root, seen)
    context
  end

  step "{string} reads {string} on the branch {string} of {string}",
       %{args: [path, text, branch, project]} = context do
    root = root(context, project)
    World.git!(root, ["checkout", "-q", "-b", branch])
    put(root, path, unescape(text))
    commit(root)
    World.git!(root, ["checkout", "-q", "main"])
    context
  end

  step "the branch {string} of {string} has no {string}",
       %{args: [branch, project, path]} = context do
    root = root(context, project)
    World.git!(root, ["checkout", "-q", "-b", branch])
    World.git!(root, ["rm", "-q", path])
    commit(root)
    World.git!(root, ["checkout", "-q", "main"])
    context
  end

  step "the user switches {string} to the branch {string}",
       %{args: [project, branch]} = context do
    root = root(context, project)
    seen = Files.generation(root)
    {_, context} = World.call!(context, "vcs.switchRef", %{"cwd" => root, "refName" => branch})
    :ok = Files.await(root, seen)
    context
  end

  step "the MC restarts after {string} of {string} was rewritten to {string}",
       %{args: [path, project, text]} = context do
    file = Path.join(root(context, project), path)
    mc = Mc.restart(context.mc, fn -> File.write!(file, unescape(text)) end)
    :ok = Files.drain()
    %{context | mc: mc, clients: %{}}
  end

  # --- helpers ---------------------------------------------------------------------------

  # The server that follows the files, for the scenario.
  defp files(context) do
    Mc.ensure(Files)
    context
  end

  defp root(context, project), do: World.project(context, project).root

  defp put_file(context, project, path, text) do
    context = files(context)
    root = root(context, project)
    put(root, path, text)
    commit(root)
    context
  end

  defp put(root, path, text) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
  end

  defp link(path, target) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
    File.ln_s!(target, path)
  end

  defp commit(root) do
    World.git!(root, ["add", "-A"])
    World.git!(root, ["commit", "-q", "--allow-empty", "-m", "files"])
  end

  defp put_section(context, project, section) do
    context = files(context)
    edit_project_file(context, project, &Map.put(&1, "spaces", section))
  end

  # hal-c2.json as JSON, changed by `fun`.
  defp edit_project_file(context, project, fun) do
    path = Path.join(root(context, project), "hal-c2.json")

    file =
      case File.read(path) do
        {:ok, text} -> JSON.decode!(text)
        {:error, :enoent} -> %{}
      end

    File.write!(path, JSON.encode!(fun.(file)))
    context
  end

  defp script(name),
    do: %{"id" => String.downcase(name), "name" => name, "command" => "true", "icon" => "test"}

  # `docs/*.md page, notes/*.md page` as entries.
  defp entries(text) do
    for entry <- names(text) do
      [path, kind] = String.split(entry, " ")
      %{"path" => path, "kind" => kind}
    end
  end

  defp names(""), do: []
  defp names(text), do: String.split(text, ", ")

  defp unescape(text), do: String.replace(text, "\\n", "\n")

  defp scan(context, project, replace) do
    context = files(context)
    payload = %{"projectId" => World.project(context, project).id, "replace" => replace}
    {reply, context} = World.call(context, "space.files.scan", payload)
    Map.put(context, :scan, reply)
  end

  defp open(context, project_id, path, space) do
    context = files(context)

    payload = %{
      "spaceId" => context.spaces[space],
      "projectId" => project_id,
      "relativePath" => path
    }

    {reply, context} = World.call(context, "space.page.openFile", payload)

    context = Map.put(context, :space_reply, reply)

    case reply do
      {:ok, %{"spaceId" => space_id}} ->
        context
        |> Map.put(:first_opened, context[:opened] || reply)
        |> Map.put(:opened, reply)
        |> Map.put(:space, space_id)

      _ ->
        context
    end
  end

  defp refused(context, reason) do
    assert {:error, _, %{"_tag" => "SpaceError", "reason" => ^reason}} = context.space_reply
    context
  end

  # A turn of the agent in `project`, the files it changed followed once it ends.
  defp turn(context, project, text) do
    context =
      if context[:threads]["Agent"],
        do: context,
        else: World.create_thread(context, "Agent", project)

    root = root(context, project)
    seen = Files.generation(root)
    context = World.run_turn(context, "Agent", text)
    :ok = Files.await(root, seen)
    context
  end

  defp changed(context, root) do
    seen = Files.generation(root)
    Files.changed(root)
    :ok = Files.await(root, seen)
    context
  end

  defp state(context), do: Streams.state(Space.stream_id(context.space))

  defp page!(context, title) do
    Enum.find(StreamState.list(state(context), "page"), &(&1["title"] == title)) ||
      flunk("no page #{inspect(title)}")
  end

  defp page_ref(context, title),
    do: %{"spaceId" => context.space, "pageId" => page!(context, title)["id"]}

  defp block!(context, text) do
    Enum.find(StreamState.list(state(context), "block"), &(&1["text"] == text)) ||
      flunk("no block #{inspect(text)}")
  end

  defp texts(context, title),
    do: Enum.map(Blocks.of_page(state(context), page!(context, title)["id"]), & &1["text"])

  defp versions(context, title) do
    {%{"versions" => versions}, _} =
      World.call!(context, "space.page.history", page_ref(context, title))

    versions
  end
end
