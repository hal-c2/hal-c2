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

    assert_receive {:hal_c2_project_clones, _, [%{"phase" => "done", "percent" => 100}]}, 10_000
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

    assert_receive {:hal_c2_project_clones, _, [%{"phase" => "failed", "error" => error}]}, 10_000
    assert error =~ "nowhere"
    assert {:ok, %{"applied" => true}} = HalC2.ProjectClones.retry(%{"projectId" => "project-10"})
  end

  test "a local remote is spelled out against the clone's parent folder", %{dir: dir} do
    dest = Path.join(dir, "shop")
    assert HalC2.ProjectClones.address("origin", dest) == Path.join(dir, "origin")
    assert HalC2.ProjectClones.address("./up/../origin/", dest) == Path.join(dir, "origin")
    assert HalC2.ProjectClones.address("/srv/origin", dest) == "/srv/origin"

    assert HalC2.ProjectClones.address("../origin", dest) ==
             Path.join(Path.dirname(dir), "origin")

    for url <- ["https://example.com/a.git", "git@example.com:a.git", "ext::cmd %S"],
        do: assert(HalC2.ProjectClones.address(url, dest) == url)
  end

  test "a clone from a relative local path is cancelled and its files taken away",
       %{origin: origin, dir: dir} do
    # The checkout waits at a gate (a smudge filter) until the cancel is in.
    File.write!(Path.join(origin, ".gitattributes"), "README.md filter=gate\n")
    {_, 0} = System.cmd("git", ~w(add .gitattributes), cd: origin)
    {_, 0} = System.cmd("git", ~w(-c user.name=t -c user.email=t@t commit -q -m gate), cd: origin)
    port = HalC2.Test.CloneGate.listen()

    on_exit(
      HalC2.Test.CloneGate.git_config(%{
        "filter.gate.smudge" => HalC2.Test.CloneGate.smudge(port, "@cwd"),
        "filter.gate.required" => "true"
      })
    )

    dest = Path.join(dir, "shop")
    File.mkdir_p!(dest)
    {:ok, []} = HalC2.ProjectClones.subscribe(self())

    assert {:ok, _} =
             HalC2.ProjectClones.start(%{
               "projectId" => "project-11",
               "title" => "Relative",
               "createdAt" => "2026-09-23T00:00:00.000Z",
               "remoteUrl" => "./origin/",
               "destinationPath" => dest
             })

    gate = HalC2.Test.CloneGate.await("shop")
    assert File.exists?(Path.join(dest, ".git/config"))

    assert {:ok, %{"applied" => true}} =
             HalC2.ProjectClones.cancel(%{"projectId" => "project-11"})

    assert File.ls!(dest) == []
    assert File.exists?(Path.join(origin, ".git/config"))
    :gen_tcp.close(gate)

    assert {:ok, %{"applied" => true}} = HalC2.ProjectClones.retry(%{"projectId" => "project-11"})
  end

  describe "taking a clone's files away" do
    setup %{origin: origin, dir: dir} do
      File.mkdir_p!(Path.join(origin, "src/lib"))
      File.write!(Path.join(origin, "src/lib/util.txt"), "util\n")
      {_, 0} = System.cmd("git", ~w(add -A), cd: origin)

      {_, 0} =
        System.cmd("git", ~w(-c user.name=t -c user.email=t@t commit -q -m second), cd: origin)

      dest = Path.join(dir, "shop")
      {_, 0} = System.cmd("git", ["clone", "-q", "--", origin, dest], stderr_to_stdout: true)
      File.write!(Path.join(dest, "mine.txt"), "the user's")
      File.mkdir_p!(Path.join(dest, "src/notes"))
      File.write!(Path.join(dest, "src/notes/todo.txt"), "the user's")
      %{dest: dest, run: %{dest: dest, real: HalC2.ProjectClones.canonical(dest), url: origin}}
    end

    test "takes only what git wrote", %{dest: dest, run: run} do
      assert HalC2.ProjectClones.remove_checkout(run) == :ok
      assert File.ls!(dest) |> Enum.sort() == ["mine.txt", "src"]
      assert File.ls!(Path.join(dest, "src")) == ["notes"]
      assert File.read!(Path.join(dest, "src/notes/todo.txt")) == "the user's"
    end

    test "leaves a repository that is not the clone's", %{dest: dest, run: run} do
      assert HalC2.ProjectClones.remove_checkout(%{run | url: "https://example.com/other.git"}) ==
               :refused

      assert File.exists?(Path.join(dest, ".git/config"))
      assert File.exists?(Path.join(dest, "README.md"))
    end

    test "leaves a folder that holds another project", %{dest: dest, run: run} do
      inner = Path.join(dest, "src/notes")

      {:ok, _} =
        HalC2.Projects.mutate(%{
          "type" => "project.create",
          "projectId" => "notes",
          "title" => "Notes",
          "workspaceRoot" => inner
        })

      assert HalC2.ProjectClones.remove_checkout(run) == :refused
      assert File.exists?(Path.join(dest, "README.md"))
    end

    test "leaves a folder that became a link to somewhere else", %{dir: dir, dest: dest, run: run} do
      moved = Path.join(dir, "moved")
      File.rename!(dest, moved)
      File.ln_s!(moved, dest)

      assert HalC2.ProjectClones.remove_checkout(run) == :refused
      assert File.exists?(Path.join(moved, ".git/config"))
    end

    test "leaves the root, the home folder and paths not spelled out", %{run: run} do
      for dest <- ["/", System.user_home!(), Path.dirname(System.user_home!()), "shop", "/a/../b"] do
        assert HalC2.ProjectClones.remove_checkout(%{run | dest: dest, real: dest}) == :refused
      end
    end
  end
end
