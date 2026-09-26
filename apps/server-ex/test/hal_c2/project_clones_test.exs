defmodule HalC2.ProjectClonesTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(HalC2.ProjectClones)

    # A repository to clone, as a plain path remote.
    origin = Path.join(dir, "origin")
    File.mkdir_p!(origin)
    git = &System.cmd("git", &1, cd: origin, stderr_to_stdout: true)
    {_, 0} = git.(~w(init -q -b main))
    File.write!(Path.join(origin, "README.md"), "hello\n")
    {_, 0} = git.(~w(add README.md))
    {_, 0} = git.(~w(-c user.name=t -c user.email=t@t commit -q -m first))
    %{origin: origin, dir: dir}
  end

  test "git's progress lines become clone stages" do
    assert %{"stage" => "receiving", "percent" => 45, "detail" => "1.20 MiB | 2.00 MiB/s"} =
             HalC2.ProjectClones.progress(
               "Receiving objects:  45% (450/1000), 1.20 MiB | 2.00 MiB/s"
             )

    assert %{"stage" => "counting", "percent" => 100} =
             HalC2.ProjectClones.progress("remote: Counting objects: 100% (5/5), done.")

    assert %{"stage" => "checkout"} = HalC2.ProjectClones.progress("Updating files:  50% (1/2)")
    assert HalC2.ProjectClones.progress("Cloning into 'x'...") == nil
  end

  test "a project is added and its repository cloned into it", %{origin: origin, dir: dir} do
    {:ok, []} = HalC2.ProjectClones.subscribe(self())
    dest = Path.join(dir, "checkout")

    assert {:ok, %{"projectId" => "project-9", "cwd" => ^dest, "remoteUrl" => ^origin}} =
             HalC2.ProjectClones.start(%{
               "projectId" => "project-9",
               "title" => "Cloned",
               "createdAt" => "2026-09-23T00:00:00.000Z",
               "remoteUrl" => origin,
               "destinationPath" => dest
             })

    assert_receive {:halc2_project_clones, _, [%{"phase" => "done", "percent" => 100}]}, 10_000
    assert File.read!(Path.join(dest, "README.md")) == "hello\n"

    project = HalC2.Streams.Server.state(HalC2.Streams.ensure("project-9"))
    assert %{"workspaceRoot" => ^dest} = HalC2.StreamState.get(project, "project")["project-9"]
  end

  test "a failed clone says why and can be retried", %{dir: dir} do
    {:ok, []} = HalC2.ProjectClones.subscribe(self())

    {:ok, _} =
      HalC2.ProjectClones.start(%{
        "projectId" => "project-10",
        "title" => "Missing",
        "createdAt" => "2026-09-23T00:00:00.000Z",
        "remoteUrl" => Path.join(dir, "nowhere"),
        "destinationPath" => Path.join(dir, "missing")
      })

    assert_receive {:halc2_project_clones, _, [%{"phase" => "failed", "error" => error}]}, 10_000
    assert error =~ "nowhere"
    assert {:ok, %{"applied" => true}} = HalC2.ProjectClones.retry(%{"projectId" => "project-10"})
  end
end
