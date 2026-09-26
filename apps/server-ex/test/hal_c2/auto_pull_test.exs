defmodule HalC2.AutoPullTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(HalC2.Settings)
    start_supervised!({Registry, keys: :unique, name: HalC2.Vcs.Registry})

    origin = Path.join(dir, "origin.git")
    other = Path.join(dir, "other")
    repo = Path.join(dir, "repo")
    git(dir, ~w(init -q --bare -b main) ++ [origin])
    git(dir, ["clone", "-q", origin, other])
    commit(other, "first")
    git(other, ~w(push -q origin main))
    git(dir, ["clone", "-q", origin, repo])
    # Someone else pushes after this checkout was made.
    commit(other, "second")
    git(other, ~w(push -q origin main))

    :ok = HalC2.Shell.subscribe(self())

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "title" => "Repo",
        "workspaceRoot" => repo
      })

    assert_receive {:hal_c2_shell, {:rows, _, [{"p1", _}]}}, 2_000
    %{repo: repo}
  end

  defp git(cwd, args), do: {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)

  defp commit(cwd, message) do
    File.write!(Path.join(cwd, "#{message}.txt"), message)
    git(cwd, ~w(add .))
    git(cwd, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message])
  end

  defp head_message(repo) do
    {out, 0} = System.cmd("git", ~w(log -1 --format=%s), cd: repo)
    String.trim(out)
  end

  test "a project that asks for it is pulled at boot; others are left alone", %{repo: repo} do
    :ok = HalC2.Projects.auto_pull()
    assert head_message(repo) == "first"

    {_, version} = HalC2.Settings.get()

    {:ok, _} =
      HalC2.Settings.put(
        %{"projectSettingsOverrides" => %{"p1" => %{"defaultAutoPull" => true}}},
        version
      )

    # Local changes keep the checkout as it is.
    File.write!(Path.join(repo, "first.txt"), "edited")
    :ok = HalC2.Projects.auto_pull()
    assert head_message(repo) == "first"

    git(repo, ~w(checkout -q -- first.txt))
    :ok = HalC2.Projects.auto_pull()
    assert head_message(repo) == "second"
  end
end
