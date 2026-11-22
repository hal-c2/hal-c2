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
end
