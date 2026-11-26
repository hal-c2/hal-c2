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

  # A plugin's run, linked to the plugin, is stopped with it mid-fetch: it must not go
  # on to the next step once git is gone.
  test "a caller stopped while git runs stops there, and what git started with it",
       %{tmp_dir: dir} do
    git = Path.join(dir, "git")

    File.write!(git, """
    #!/bin/sh
    sleep 60 &
    echo $! > '#{dir}/child'
    wait
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

    test = self()

    {caller, ref} =
      spawn_monitor(fn ->
        HalC2.Git.run(dir, ["fetch"], timeout: 60_000, stop_children: {__MODULE__, dir})
        send(test, :went_on)
      end)

    child = Path.join(dir, "child")

    {_, 0} =
      System.cmd("timeout", ["5", "sh", "-c", "until [ -s '#{child}' ]; do sleep 0.05; done"])

    Process.exit(caller, :shutdown)

    assert_receive {:DOWN, ^ref, :process, ^caller, :shutdown}, 5_000
    refute_received :went_on

    pid = child |> File.read!() |> String.trim()
    assert {_, 1} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
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
end
