defmodule HalC2.LocalVersionTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # A repository laid out as this one, holding a copy of the script and one commit.
  setup %{tmp_dir: root} do
    scripts = Path.join(root, "apps/server-ex/scripts")
    File.mkdir_p!(scripts)
    File.mkdir_p!(Path.join(root, "apps/server"))
    File.write!(Path.join(root, "apps/server/package.json"), ~s({"version":"1.2.3"}))
    File.cp!("scripts/local-version", Path.join(scripts, "local-version"))

    git(root, ~w(init --quiet))
    git(root, ~w(add -A))
    git(root, ~w(-c user.name=t -c user.email=t@example.com commit --quiet -m first))
    {commit, 0} = System.cmd("git", ~w(rev-parse HEAD), cd: root)

    %{root: root, script: Path.join(scripts, "local-version"), commit: String.trim(commit)}
  end

  defp git(root, args), do: {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)

  defp version(script, env \\ []) do
    {out, 0} = System.cmd(script, [], env: env)
    String.trim(out)
  end

  test "a clean checkout is versioned by its commit, wherever it is built", context do
    %{script: script, commit: commit} = context
    version = version(script)

    assert version =~ ~r/^1\.2\.3-local\.\d{14}\.g#{String.slice(commit, 0, 12)}$/
    assert {:ok, _} = Version.parse(version)
    assert version(script, [{"TZ", "Pacific/Auckland"}]) == version
    assert version(script, [{"TZ", "America/Los_Angeles"}]) == version
  end

  test "a checkout with changes gets a version no commit has", %{root: root, script: script} do
    File.write!(Path.join(root, "apps/server/package.json"), ~s({"version": "1.2.3"}))
    assert version(script) =~ ~r/^1\.2\.3-local\.\d{14}$/
  end

  test "an untracked file is a change, also when git is told not to list them", context do
    %{root: root, script: script} = context
    git(root, ~w(config status.showUntrackedFiles no))
    File.write!(Path.join(root, "apps/server-ex/new.ex"), "")
    assert version(script) =~ ~r/^1\.2\.3-local\.\d{14}$/
  end
end
