defmodule HalC2.Upgrade.PruneTest do
  use ExUnit.Case, async: false

  alias HalC2.Upgrade.Prune
  alias HalC2.Upgrade.Source

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :upgrade_processes, fn -> {:ok, []} end)

    on_exit(fn ->
      Application.delete_env(:hal_c2, :home)
      Application.delete_env(:hal_c2, :upgrade_processes)
    end)

    root = Path.join(dir, "release")
    File.mkdir_p!(Path.join(root, "releases"))
    %{root: root}
  end

  # Release `version` under `root` with `apps` (`{app, vsn}`) and runtime `erts`, each
  # directory two hours old unless `age` says otherwise.
  defp release(root, version, apps, erts, age \\ 7200) do
    rel = Path.join([root, "releases", version])
    File.mkdir_p!(rel)

    HalC2.Upgrade.Appup.write_term!(
      Path.join(rel, "hal_c2.rel"),
      {:release, {~c"hal_c2", String.to_charlist(version)}, {:erts, String.to_charlist(erts)},
       for({app, vsn} <- apps, do: {app, String.to_charlist(vsn)})}
    )

    dirs =
      for {app, vsn} <- apps do
        dir = Path.join([root, "lib", "#{app}-#{vsn}", "ebin"])
        File.mkdir_p!(dir)
        Path.dirname(dir)
      end

    erts_dir = Path.join(root, "erts-#{erts}")
    File.mkdir_p!(Path.join(erts_dir, "bin"))
    cache = Source.cache_dir(version)
    File.mkdir_p!(cache)
    File.write!(Path.join(cache, "bundle.tar.gz"), "")

    for path <- [rel, erts_dir, cache | dirs],
        do: File.touch!(path, System.os_time(:second) - age)
  end

  defp starts(root, version),
    do: File.write!(Path.join([root, "releases", "start_erl.data"]), "16.0 #{version}\n")

  test "removes a version nothing uses, keeping what the kept ones share", %{root: root} do
    release(root, "1.1.0", [hal_c2: "1.1.0", exqlite: "0.40.0"], "15.0")
    release(root, "1.2.0", [hal_c2: "1.2.0", exqlite: "0.40.0"], "16.0")
    starts(root, "1.2.0")

    assert {:ok, ["1.1.0"]} = Prune.run(root, "1.2.0")

    refute File.exists?(Path.join([root, "releases", "1.1.0"]))
    refute File.exists?(Path.join([root, "lib", "hal_c2-1.1.0"]))
    refute File.exists?(Path.join(root, "erts-15.0"))
    refute File.exists?(Source.cache_dir("1.1.0"))
    # 1.2.0 runs on the library 1.1.0 had too.
    assert File.dir?(Path.join([root, "lib", "exqlite-0.40.0"]))
    assert File.dir?(Path.join([root, "lib", "hal_c2-1.2.0"]))
    assert File.dir?(Path.join(root, "erts-16.0"))
    assert File.dir?(Source.cache_dir("1.2.0"))
  end

  test "keeps the version the next start runs and the one the service goes back to",
       %{root: root} do
    for v <- ~w(1.1.0 1.2.0 1.3.0), do: release(root, v, [hal_c2: v], "16.0")
    starts(root, "1.3.0")
    File.write!(Path.join([root, "releases", "start_erl.data.previous"]), "16.0 1.1.0\n")

    assert {:ok, ["1.2.0"]} = Prune.run(root, "1.2.5")
    assert File.dir?(Path.join([root, "releases", "1.1.0"]))
    assert File.dir?(Path.join([root, "releases", "1.3.0"]))
  end

  test "keeps a version a process runs, and one installed within the hour", %{root: root} do
    release(root, "1.1.0", [hal_c2: "1.1.0"], "16.0")
    release(root, "1.2.0", [hal_c2: "1.2.0"], "16.0", 60)
    release(root, "1.3.0", [hal_c2: "1.3.0"], "16.0")
    starts(root, "1.3.0")
    boot = Path.join([root, "releases", "1.1.0", "start"])

    Application.put_env(:hal_c2, :upgrade_processes, fn ->
      {:ok, ["beam.smp -- -boot #{boot}"]}
    end)

    assert {:ok, []} = Prune.run(root, "1.3.0")
  end

  test "removes nothing when it cannot tell what is in use", %{root: root} do
    release(root, "1.1.0", [hal_c2: "1.1.0"], "16.0")
    release(root, "1.2.0", [hal_c2: "1.2.0"], "16.0")
    starts(root, "1.2.0")
    Application.put_env(:hal_c2, :upgrade_processes, fn -> {:error, "no ps"} end)
    assert {:error, "no ps"} = Prune.run(root, "1.2.0")

    Application.put_env(:hal_c2, :upgrade_processes, fn -> {:ok, []} end)
    File.write!(Path.join([root, "releases", "start_erl.data.previous"]), "garbled")
    assert {:error, _} = Prune.run(root, "1.2.0")

    File.rm!(Path.join([root, "releases", "start_erl.data.previous"]))
    File.mkdir_p!(Path.join(Source.cache_dir("x"), ".."))
    File.write!(Path.join([Source.cache_dir("x"), "..", "outcome.json"]), "{")
    assert {:error, _} = Prune.run(root, "1.2.0")

    assert File.dir?(Path.join([root, "releases", "1.1.0"]))
  end

  test "finishes a removal that was cut off", %{root: root} do
    release(root, "1.2.0", [hal_c2: "1.2.0"], "16.0")
    starts(root, "1.2.0")
    left = Path.join([root, "releases", "1.1.0.removing"])
    File.mkdir_p!(left)
    File.write!(Path.join(left, "hal_c2.rel"), "")

    assert {:ok, []} = Prune.run(root, "1.2.0")
    refute File.exists?(left)
  end

  test "the running VM's own runtime and code are never removed", %{root: root} do
    erts = to_string(:erlang.system_info(:version))
    release(root, "1.1.0", [hal_c2: "1.1.0"], erts)
    release(root, "1.2.0", [hal_c2: "1.2.0"], "16.0")
    starts(root, "1.2.0")

    assert {:ok, ["1.1.0"]} = Prune.run(root, "1.2.0")
    assert File.dir?(Path.join(root, "erts-#{erts}"))
  end
end
