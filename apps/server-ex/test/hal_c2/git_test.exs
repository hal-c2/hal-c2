defmodule HalC2.GitTest do
  # `:git_command` is application-wide.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "stderr past max_bytes keeps its tail, where a push's refusal is", %{tmp_dir: dir} do
    # A chatty git: 300 KB of progress on stderr, then the line callers act on.
    git = Path.join(dir, "git")

    File.write!(git, """
    #!/bin/sh
    head -c 307200 /dev/zero | tr '\\0' 'x' >&2
    echo >&2
    echo 'refusing to allow an OAuth App to create or update workflow without `workflow` scope' >&2
    exit 1
    """)

    File.chmod!(git, 0o755)
    previous = Application.fetch_env(:hal_c2, :git_command)
    Application.put_env(:hal_c2, :git_command, git)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:hal_c2, :git_command, value)
        :error -> Application.delete_env(:hal_c2, :git_command)
      end
    end)

    max = 64 * 1024

    assert {:ok, %{status: 1, err: err, truncated: true}} =
             HalC2.Git.run(dir, ["push"], max_bytes: max)

    assert byte_size(err) <= max
    assert String.ends_with?(err, "without `workflow` scope\n")
  end

  test "a variable named in unset is not in git's environment", %{tmp_dir: dir} do
    vars = ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0)
    previous = Map.new(vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {var, value} <- previous,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))
    end)

    System.put_env(%{
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "hal.probe",
      "GIT_CONFIG_VALUE_0" => "seen"
    })

    args = ["config", "--get", "hal.probe"]
    assert {:ok, %{status: 0, out: "seen\n"}} = HalC2.Git.run(dir, args)
    assert {:ok, %{status: 1}} = HalC2.Git.run(dir, args, unset: ["GIT_CONFIG_COUNT"])
  end

  # #1774: a port leaves out a variable set to "", and git refuses the key without it.
  test "a variable set to an empty value reaches git, and the last value of a name wins",
       %{tmp_dir: dir} do
    env = [
      {"GIT_CONFIG_COUNT", "2"},
      {"GIT_CONFIG_KEY_0", "hal.probe"},
      {"GIT_CONFIG_VALUE_0", ""},
      {"GIT_CONFIG_KEY_1", "hal.probe"},
      {"GIT_CONFIG_VALUE_1", ""},
      {"GIT_CONFIG_VALUE_1", "seen"}
    ]

    assert {:ok, %{status: 0, out: "\nseen\n"}} =
             HalC2.Git.run(dir, ["config", "--get-all", "hal.probe"], env: env)
  end

  test "a variable both unset and set to an empty value stays unset", %{tmp_dir: dir} do
    env = [
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "hal.probe"},
      {"GIT_CONFIG_VALUE_0", ""}
    ]

    args = ["config", "--get", "hal.probe"]
    assert {:ok, %{status: 0, out: "\n"}} = HalC2.Git.run(dir, args, env: env)

    # Unset, the value is missing and git refuses the key.
    assert {:ok, %{status: 128}} =
             HalC2.Git.run(dir, args, env: env, unset: ["GIT_CONFIG_VALUE_0"])
  end

  # Review of #1837: a branch named after its upstream under a remote's prefix is that
  # branch, so it is based on the default branch, not on its own remote counterpart
  # (a pull request from it would have the same head and base).
  test "an alias of its upstream is based on the default branch", %{tmp_dir: dir} do
    git = fn cwd, args ->
      {out, 0} =
        System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args],
          cd: cwd,
          stderr_to_stdout: true,
          env: [{"GIT_CONFIG_COUNT", nil}, {"GIT_CONFIG_GLOBAL", "/dev/null"}]
        )

      out
    end

    bare = Path.join(dir, "origin.git")
    work = Path.join(dir, "work")
    File.mkdir_p!(bare)
    File.mkdir_p!(work)
    git.(bare, ~w(init -q --bare -b main))
    git.(work, ~w(init -q -b main))
    git.(work, ~w(commit -q --allow-empty -m init))
    git.(work, ["remote", "add", "origin", bare])
    git.(work, ["remote", "add", "upstream", bare])
    git.(work, ~w(push -q -u origin main))
    git.(work, ~w(push -q origin main:effect-atom))
    git.(work, ~w(fetch -q origin))
    git.(work, ~w(remote set-head origin main))
    git.(work, ~w(checkout -q -b upstream/effect-atom origin/effect-atom))

    assert HalC2.Git.base_branch(work, "upstream/effect-atom") == "origin/main"

    # A prefix that is not a remote names a branch of its own, cut from its upstream.
    git.(work, ~w(checkout -q -b fix/effect-atom origin/effect-atom))
    assert HalC2.Git.base_branch(work, "fix/effect-atom") == "origin/effect-atom"
  end
end
