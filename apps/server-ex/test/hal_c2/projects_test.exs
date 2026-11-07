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

  test "no folder is refused, not read as the MC's working directory", %{tmp_dir: dir} do
    assert {:error, "a workspace folder is required"} =
             Projects.mutate(%{
               "type" => "project.create",
               "projectId" => "e",
               "workspaceRoot" => ""
             })

    assert {:ok, _} =
             Projects.mutate(%{
               "type" => "project.create",
               "projectId" => "p1",
               "workspaceRoot" => dir
             })

    assert {:error, "a workspace folder is required"} =
             Projects.mutate(%{
               "type" => "project.update",
               "projectId" => "p1",
               "workspaceRoot" => ""
             })
  end

  test "a folder another project owns is refused with that project's id for a client", %{
    tmp_dir: dir
  } do
    create = %{"type" => "project.create", "projectId" => "p1", "workspaceRoot" => dir}
    assert {:ok, _} = Projects.mutate_for_client(create)

    typed = Path.join([dir, "x", ".."])

    assert {:error, %{"_tag" => "WorkspaceInUse", "projectId" => "p1", "message" => message}} =
             Projects.mutate_for_client(%{create | "projectId" => "p2", "workspaceRoot" => typed})

    assert message =~ "already belongs to project p1"

    assert {:error, ^message} =
             Projects.mutate(%{create | "projectId" => "p3", "workspaceRoot" => typed})
  end

  test "a project folder is expanded and canonical, and a relative one is refused", %{
    tmp_dir: dir
  } do
    home = System.get_env("HOME")
    messy = Path.join([dir, "a", "..", "b", "."])

    assert {:ok, %{"workspaceRoot" => root}} =
             Projects.mutate(%{
               "type" => "project.create",
               "projectId" => "p1",
               "workspaceRoot" => messy,
               "createWorkspaceRootIfMissing" => true
             })

    assert root == Path.join(dir, "b")

    for relative <- ["shop", "./shop", "../shop", "~sam/shop"] do
      assert {:error, "Workspace " <> _ = error} =
               Projects.mutate(%{
                 "type" => "project.create",
                 "projectId" => "r",
                 "workspaceRoot" => relative,
                 "createWorkspaceRootIfMissing" => true
               })

      assert error =~ "is not an absolute path"

      assert {:error, ^error} =
               Projects.mutate(%{
                 "type" => "project.update",
                 "projectId" => "p1",
                 "workspaceRoot" => relative
               })
    end

    assert {:ok, %{"workspaceRoot" => expanded}} =
             Projects.mutate(%{
               "type" => "project.update",
               "projectId" => "p1",
               "workspaceRoot" => "~/../" <> Path.basename(home)
             })

    assert expanded == home
  end
end
