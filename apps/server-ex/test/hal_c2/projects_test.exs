defmodule HalC2.ProjectsTest do
  use ExUnit.Case, async: false

  alias HalC2.Projects

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    :ok
  end

  test "a project is created, renamed, and deleted, and its sidebar row follows", %{tmp_dir: dir} do
    :ok = HalC2.Shell.subscribe(self())
    root = Path.join(dir, "app")

    assert {:error, _} =
             Projects.mutate(%{
               "type" => "project.create",
               "projectId" => "p1",
               "workspaceRoot" => root
             })

    assert {:ok, %{"id" => "p1", "title" => "app", "deletedAt" => nil}} =
             Projects.mutate(%{
               "type" => "project.create",
               "projectId" => "p1",
               "workspaceRoot" => root,
               "createWorkspaceRootIfMissing" => true
             })

    assert File.dir?(root)
    assert_receive {:hal_c2_shell, {:rows, _, [{"p1", {"project", %{"title" => "app"}}}]}}, 1_000

    # Results are complete `Project`s, null fields included.
    assert {:ok, %{"title" => "Renamed", "deletedAt" => nil, "scripts" => []}} =
             Projects.mutate(%{
               "type" => "project.update",
               "projectId" => "p1",
               "title" => "Renamed"
             })

    assert_receive {:hal_c2_shell, {:rows, _, [{"p1", {"project", %{"title" => "Renamed"}}}]}},
                   1_000

    assert {:ok, %{"deletedAt" => deleted}} =
             Projects.mutate(%{"type" => "project.delete", "projectId" => "p1"})

    assert deleted

    assert_receive {:hal_c2_shell, {:rows, _, [{"p1", {"project", %{"deletedAt" => ^deleted}}}]}},
                   1_000
  end

  test "browse lists matching folders, hiding dot-folders unless asked", %{tmp_dir: dir} do
    for name <- ~w(alpha alps beta .hidden), do: File.mkdir_p!(Path.join(dir, name))
    File.write!(Path.join(dir, "alpine.txt"), "")

    assert {:ok, %{"entries" => entries}} =
             Projects.browse(%{"partialPath" => Path.join(dir, "al")})

    assert Enum.map(entries, & &1["name"]) == ~w(alpha alps)

    assert {:ok, %{"entries" => all}} = Projects.browse(%{"partialPath" => dir <> "/"})
    assert ".hidden" in Enum.map(all, & &1["name"])
  end

  test "browse refuses Windows paths and relative paths without a project, and names unreadable folders",
       %{tmp_dir: dir} do
    assert {:error, "Windows-style workspace path 'C:\\code' is not supported on" <> _} =
             Projects.browse(%{"partialPath" => "C:\\code"})

    assert {:error, "A current project is required to browse relative workspace path './x'."} =
             Projects.browse(%{"partialPath" => "./x"})

    File.mkdir_p!(Path.join(dir, "proj/shop-api"))

    assert {:ok, %{"entries" => [%{"name" => "shop-api"}]}} =
             Projects.browse(%{"partialPath" => "./sh", "cwd" => Path.join(dir, "proj")})

    missing = Path.join(dir, "nowhere")

    assert {:error, "The folder '" <> _ = message} =
             Projects.browse(%{"partialPath" => missing <> "/"})

    assert message =~ missing
  end
end
