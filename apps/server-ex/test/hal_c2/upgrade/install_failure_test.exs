defmodule HalC2.Upgrade.InstallFailureTest do
  @moduledoc """
  An install in place that fails after the release handler started it, past the
  point of no return (a `code_change/3` that raises). It may not leave `start_erl.data` naming a
  release the MC does not run or the outcome saying otherwise.

  A script that fails past the point of no return has the release handler restart
  the node (`init:restart/0`, the only `error_action` there is besides a reboot), and
  in a test that node is the test VM. So the crash stands in for the release
  handler's install (`:install_release`): it checks the relup this MC generated
  marks the point before the raising `code_change/3`, runs that mark as the release
  handler would, and replies as the release handler does for the crash.
  """

  use ExUnit.Case, async: false

  alias HalC2.Test.Mc
  alias HalC2.Test.Shaped
  alias HalC2.Upgrade
  alias HalC2.Upgrade.Tree

  @moduletag :tmp_dir

  # The next version of `Shaped`, whose migration raises.
  @raising """
  defmodule HalC2.Test.Shaped do
    use GenServer

    def start_link(n), do: GenServer.start_link(__MODULE__, n, name: __MODULE__)
    def state, do: GenServer.call(__MODULE__, :state)

    @impl true
    def init(n), do: {:ok, {:v2, n, []}}

    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}

    @impl true
    def code_change(_old, _state, _extra), do: raise("the migration broke")

    def next, do: nil
  end
  """

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    from = "0.0.#{System.unique_integer([:positive])}"
    :persistent_term.put({Upgrade, :version}, from)
    root = Mc.release(%{home: dir})
    Mc.remember_module(Shaped)
    {:ok, pid} = Supervisor.start_child(HalC2.Supervisor, {Shaped, 1})

    on_exit(fn ->
      Application.delete_env(:hal_c2, :install_release)
      Supervisor.terminate_child(HalC2.Supervisor, Shaped)
      Supervisor.delete_child(HalC2.Supervisor, Shaped)
    end)

    Mc.ensure(HalC2.Settings)
    Mc.ensure(HalC2.Upgrade)
    %{dir: dir, root: root, from: from, target: from <> "-1", shaped: pid}
  end

  test "a code_change/3 that raises past the point of no return leaves the MC set to boot the release it ran",
       %{dir: dir, root: root, from: from, target: target} = context do
    test = self()

    Application.put_env(:hal_c2, :install_release, fn vsn, _opts ->
      script = relup_script(root, to_string(vsn))

      {_, [:point_of_no_return, {:apply, {m, f, a}} = mark | rest]} =
        Enum.split_while(script, &(&1 != :point_of_no_return))

      send(test, {:marked, mark})
      assert Enum.any?(rest, &match?({:code_change, :up, [{Shaped, _}]}, &1))
      apply(m, f, a)

      {:error,
       {:code_change_failed, context.shaped, Shaped, :undefined,
        {:EXIT, {%RuntimeError{message: "the migration broke"}, []}}}}
    end)

    beam = HalC2.Test.Compile.beam(Shaped, @raising)
    bundle(dir, target, [{Tree, tree()}, {Shaped, beam}])

    assert {:error, %{"reason" => reason}} = Upgrade.update(%{"targetVersion" => target})
    assert_received {:marked, {:apply, {:persistent_term, :put, _}}}
    assert reason =~ "the MC restarts on #{from}"
    assert reason =~ "could not migrate"

    # The release handler restarts the node itself, on `from`: nothing here restarts it,
    # and the next boot of the service is `from` too.
    refute_receive {:hal_c2_restart, _}, 700
    assert Upgrade.version() == from
    assert start_version(root) == from
    refute File.exists?(previous(root))
    assert %{"status" => "rolled-back"} = Upgrade.outcome()

    # The node comes back on `from`, and reads the same.
    reboot()
    assert %{"status" => "rolled-back", "reason" => partway} = Upgrade.outcome()
    assert partway =~ "failed partway"
    assert start_version(root) == from
  end

  test "a boot after a rollback the service did not make puts the previous release back",
       %{root: root, from: from, target: target} do
    # A restart into `target` the release handler's own restart of a failed install
    # overtook: `start_erl.data` names `target`, the VM booted `from`.
    start = Path.join([root, "releases", "start_erl.data"])
    File.cp!(start, previous(root))
    [erts, ^from] = start |> File.read!() |> String.split()
    File.write!(start, "#{erts} #{target}\n")

    File.mkdir_p!(Path.dirname(outcome_path()))

    File.write!(
      outcome_path(),
      JSON.encode!(%{
        "id" => "u",
        "fromVersion" => from,
        "targetVersion" => target,
        "status" => "restarting"
      })
    )

    reboot()
    assert %{"status" => "rolled-back"} = Upgrade.outcome()
    assert start_version(root) == from
    refute File.exists?(previous(root))
  end

  # The MC's code carries the tree sync, as `:hal_c2` does in a real release.
  defp tree do
    {Tree, tree, _} = :code.get_object_code(Tree)
    tree
  end

  defp bundle(dir, target, modules) do
    archive = Mc.bundle(%{home: dir}, target, %{}, modules)
    :ok = Upgrade.Source.put(target, Upgrade.platform(), archive)
  end

  defp relup_script(root, vsn) do
    {:ok, [{_to, [{_from, _descr, script}], _down}]} =
      :file.consult(String.to_charlist(Path.join([root, "releases", vsn, "relup"])))

    script
  end

  # The MC starting again: `HalC2.Upgrade` reads how the update went.
  defp reboot do
    :ok = stop_supervised(HalC2.Upgrade)
    :persistent_term.erase({Upgrade, :outcome})
    Mc.ensure(HalC2.Upgrade)
    # Past `handle_continue/2`.
    _ = :sys.get_state(HalC2.Upgrade)
  end

  defp start_version(root) do
    [_erts, vsn] =
      Path.join([root, "releases", "start_erl.data"]) |> File.read!() |> String.split()

    vsn
  end

  defp previous(root), do: Path.join([root, "releases", "start_erl.data.previous"])
  defp outcome_path, do: Path.join([HalC2.Paths.data_dir(), "upgrades", "outcome.json"])
end
