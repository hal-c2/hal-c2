defmodule HalC2.Upgrade.PreflightTest do
  use ExUnit.Case, async: true

  alias HalC2.Upgrade.Preflight

  @moduletag :tmp_dir

  defp launcher(dir, script) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "hal_c2"), "#!/bin/sh\n" <> script)
    File.chmod!(Path.join(bin, "hal_c2"), 0o755)
    dir
  end

  test "a bundle without a launcher has nothing to ask", %{tmp_dir: dir} do
    assert Preflight.run(dir, "1.2.0") == :ok
  end

  test "the staged version's answer decides", %{tmp_dir: dir} do
    assert Preflight.run(launcher(dir, ~s(test "$1 $RELEASE_VSN" = "eval 1.2.0")), "1.2.0") == :ok

    assert {:error, "the runtime is for arm64"} =
             Preflight.run(launcher(dir, "echo 'the runtime is for arm64'; exit 1"), "1.2.0")

    assert {:error, "it exited with status 3"} = Preflight.run(launcher(dir, "exit 3"), "1.2.0")
  end

  test "the running release's environment does not reach the staged one", %{tmp_dir: dir} do
    System.put_env("RELEASE_NODE", "running@host")
    on_exit(fn -> System.delete_env("RELEASE_NODE") end)
    assert Preflight.run(launcher(dir, ~s(test -z "${RELEASE_NODE:-}")), "1.2.0") == :ok
  end

  test "a staged version that does not answer is stopped", %{tmp_dir: dir} do
    assert {:error, "it did not answer within 200 ms"} =
             Preflight.run(launcher(dir, "exec sleep 30"), "1.2.0", 200)
  end

  test "modules whose native code does not load are named", %{tmp_dir: dir} do
    mod = :"hal_c2_preflight_nif_#{System.unique_integer([:positive])}"
    src = Path.join(dir, "#{mod}.erl")

    File.write!(src, """
    -module(#{mod}).
    -on_load(init/0).
    init() -> erlang:load_nif("#{Path.join(dir, "missing")}", 0).
    """)

    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)
    {:ok, ^mod} = :compile.file(String.to_charlist(src), outdir: String.to_charlist(ebin))
    plain = Path.join(ebin, "Elixir.HalC2.Upgrade.Preflight.beam")
    File.write!(plain, elem(:code.get_object_code(Preflight), 1))
    :code.add_patha(String.to_charlist(ebin))
    on_exit(fn -> :code.del_path(String.to_charlist(ebin)) end)

    assert [{^mod, :on_load_failure}] = Preflight.check([ebin])
  end
end
