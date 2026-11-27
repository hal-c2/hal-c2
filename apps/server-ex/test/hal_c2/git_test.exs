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

  # Review of #1837: a branch cut from a non-primary remote's branch keeps that
  # remote as its base, even when the primary remote has a branch of the same name.
  test "a branch cut from a non-primary remote keeps that remote as its base", %{tmp_dir: dir} do
    git = fn cwd, args ->
      {out, 0} =
        System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args],
          cd: cwd,
          stderr_to_stdout: true,
          env: [{"GIT_CONFIG_COUNT", nil}, {"GIT_CONFIG_GLOBAL", "/dev/null"}]
        )

      out
    end

    origin = Path.join(dir, "origin.git")
    upstream = Path.join(dir, "upstream.git")
    work = Path.join(dir, "work")
    File.mkdir_p!(origin)
    File.mkdir_p!(upstream)
    File.mkdir_p!(work)
    git.(origin, ~w(init -q --bare -b main))
    git.(upstream, ~w(init -q --bare -b main))
    git.(work, ~w(init -q -b main))
    git.(work, ~w(commit -q --allow-empty -m init))
    git.(work, ["remote", "add", "origin", origin])
    git.(work, ["remote", "add", "upstream", upstream])
    git.(work, ~w(push -q -u origin main))
    # Both remotes have a "develop"; the branch tracks upstream's.
    git.(work, ~w(push -q origin main:develop))
    git.(work, ~w(push -q upstream main:develop))
    git.(work, ~w(fetch -q --all))
    git.(work, ~w(remote set-head origin main))
    git.(work, ~w(checkout -q -b feature/tax upstream/develop))

    assert HalC2.Git.base_branch(work, "feature/tax") == "upstream/develop"
  end

  # Review of #1837: `color.ui=false` does not win over a checkout's
  # per-command colour settings, so their output reached the MC coloured.
  test "per-command colour settings never colour git's output", %{tmp_dir: dir} do
    git = fn args ->
      {out, 0} =
        System.cmd("git", args,
          cd: dir,
          stderr_to_stdout: true,
          env: [{"GIT_CONFIG_COUNT", nil}, {"GIT_CONFIG_GLOBAL", "/dev/null"}]
        )

      out
    end

    git.(~w(init -q -b main))
    git.(~w(config user.name t))
    git.(~w(config user.email t@t))

    for key <- ~w(color.diff color.status color.branch color.grep),
        do: git.(["config", key, "always"])

    File.write!(Path.join(dir, "a.txt"), "one\n")
    git.(~w(add a.txt))
    git.(~w(commit -q -m init))
    File.write!(Path.join(dir, "a.txt"), "two\n")

    for args <- [
          ["diff"],
          ["status", "--short", "--branch"],
          ["branch"],
          ["grep", "-n", "one", "HEAD"]
        ] do
      assert {:ok, %{status: 0, out: out}} = HalC2.Git.run(dir, args)
      refute out =~ "\e[", "git #{hd(args)} output holds colour codes: #{inspect(out)}"
    end
  end
end
