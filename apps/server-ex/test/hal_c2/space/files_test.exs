defmodule HalC2.Space.FilesTest do
  # `HalC2.Space.Files` on a real store, streams and project folder. The scenarios in
  # `features/space/project-files.feature` cover what the user sees; this pins what is
  # not seen: a page writing its file does not set the server reading the folder again.
  use ExUnit.Case, async: false

  alias HalC2.Space
  alias HalC2.Space.{Blocks, Files}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Settings)
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(Files)

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "demo",
        "title" => "demo",
        "workspaceRoot" => work
      })

    HalC2.Streams.flush_shell("demo")
    :sys.get_state(HalC2.Shell)

    {:ok, space} = Space.create("Research")
    %{space: space["id"], root: Path.expand(work)}
  end

  defp open!(space, root, path, text) do
    File.write!(Path.join(root, path), text)
    {:ok, %{"page" => page}} = Space.open_file(space, "demo", path)
    page["id"]
  end

  defp texts(space, page_id) do
    {:ok, state} = Space.state(space)
    Enum.map(Blocks.of_page(state, page_id), & &1["text"])
  end

  test "an edit written to its file does not make the server follow the folder",
       %{space: space, root: root} do
    a = open!(space, root, "a.md", "# A\n\nalpha\n")
    b = open!(space, root, "b.md", "# B\n\nbeta\n")
    File.write!(Path.join(root, "b.md"), "# B\n\nchanged quietly\n")
    seen = Files.generation(root)

    {:ok, state} = Space.state(space)
    [block] = Blocks.of_page(state, a)
    {:ok, _} = Space.update_block(space, block["id"], "gamma")
    :ok = Files.drain()

    assert File.read!(Path.join(root, "a.md")) == "# A\n\ngamma\n"
    assert Files.generation(root) == seen
    assert texts(space, b) == ["beta"]
  end

  test "a page with no links is still followed after an edit skips looking for its twins",
       %{space: space, root: root} do
    a = open!(space, root, "a.md", "# A\n\nalpha\n")
    {:ok, state} = Space.state(space)
    [block] = Blocks.of_page(state, a)
    {:ok, _} = Space.update_block(space, block["id"], "gamma")
    :ok = Files.drain()

    File.write!(Path.join(root, "a.md"), "# A\n\ndelta\n")
    seen = Files.generation(root)
    Files.changed(root)
    :ok = Files.await(root, seen)

    assert texts(space, a) == ["delta"]
  end

  test "a write through a link the server has not seen yet still reaches the file's page",
       %{space: space, root: root} do
    a = open!(space, root, "a.md", "# A\n\nalpha\n")
    l = open!(space, root, "l.md", "# A\n\nalpha\n")

    # No page went through a link when the server looked; now l.md is one, unsignalled.
    File.rm!(Path.join(root, "l.md"))
    File.ln_s!("a.md", Path.join(root, "l.md"))

    {:ok, state} = Space.state(space)
    [block] = Blocks.of_page(state, l)
    {:ok, _} = Space.update_block(space, block["id"], "gamma")
    :ok = Files.drain()

    assert File.read!(Path.join(root, "a.md")) == "# A\n\ngamma\n"
    assert texts(space, a) == ["gamma"]
  end

  test "a link seen when the server follows the folder keeps its page taking the file's edits",
       %{space: space, root: root} do
    a = open!(space, root, "a.md", "# A\n\nalpha\n")
    File.ln_s!("a.md", Path.join(root, "l.md"))
    {:ok, %{"page" => %{"id" => l}}} = Space.open_file(space, "demo", "l.md")

    seen = Files.generation(root)
    Files.changed(root)
    :ok = Files.await(root, seen)

    # The edit is on a.md itself; only the follow knew a page goes through a link.
    {:ok, state} = Space.state(space)
    [block] = Blocks.of_page(state, a)
    {:ok, _} = Space.update_block(space, block["id"], "gamma")
    :ok = Files.drain()

    assert texts(space, l) == ["gamma"]
  end
end
