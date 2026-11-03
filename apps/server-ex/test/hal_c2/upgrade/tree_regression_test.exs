defmodule HalC2.Upgrade.TreeRegressionTest do
  @moduledoc """
  The tree sync when the MC's code is not loaded as the `:hal_c2` application, as
  `prop/hal_c2/upgrade_release_prop_test.exs` found it: a release whose MC's code is
  another application, and a sync after the install has moved the MC's modules to it.
  """

  use ExUnit.Case, async: false

  alias HalC2.Test.Mc
  alias HalC2.Test.Services
  alias HalC2.Upgrade
  alias HalC2.Upgrade.Tree

  @moduletag :tmp_dir

  # The services' next version: one service added, one dropped, one kept.
  @next """
  defmodule HalC2.Test.Services do
    use Supervisor

    def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

    @impl true
    def init(_), do: Supervisor.init(children(), strategy: :one_for_one)

    def children do
      [
        {Registry, keys: :unique, name: HalC2.Test.NewService},
        Supervisor.child_spec({Agent, &HalC2.Test.Services.state/0}, id: :changed_service)
      ]
    end

    def backfill, do: :ok
    def state, do: 1
    def next, do: nil
  end
  """

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Mc.remember_module(Services)
    {:ok, _} = Supervisor.start_child(HalC2.Supervisor, Services)

    on_exit(fn ->
      Supervisor.terminate_child(HalC2.Supervisor, Services)
      Supervisor.delete_child(HalC2.Supervisor, Services)
      Mc.restore_modules()
      :persistent_term.erase({Tree, :before})
      :persistent_term.erase({Tree, :changes})
    end)

    %{next: HalC2.Test.Compile.beam(Services, @next)}
  end

  # The release keeps the MC's code as `hal_c2_bundle` (`HalC2.Test.Release`), not
  # `hal_c2`: the relup has to end in the tree sync all the same.
  test "a release keeping the MC's code in another application syncs the tree",
       %{tmp_dir: dir, next: next} do
    :persistent_term.put({Upgrade, :version}, "0.0.#{System.unique_integer([:positive])}")
    Mc.release(%{home: dir})
    Mc.ensure(HalC2.Settings)
    Mc.ensure(HalC2.Upgrade)

    target = Upgrade.version() <> "-1"
    {Tree, tree, _} = :code.get_object_code(Tree)
    archive = Mc.bundle(%{home: dir}, target, %{}, [{Tree, tree}, {Services, next}])
    :ok = Upgrade.Source.put(target, Upgrade.platform(), archive)

    assert {:ok, %{"method" => "hot-upgrade"}} = Upgrade.update(%{"targetVersion" => target})
    assert Upgrade.version() == target
    refute_received {:hal_c2_restart, _}
    assert Process.whereis(HalC2.Test.NewService)
    refute Process.whereis(HalC2.Test.OldService)
  end

  # Once installed, the new release's application lists the MC's modules, and
  # `Application.get_application/1` can name it rather than `:hal_c2`. Which of two
  # applications listing a module it names is up to the application controller's
  # table, so the module leaves `:hal_c2` here.
  test "a sync finds the supervisors snapshotted though their application changed",
       %{next: next} do
    old = Process.whereis(HalC2.Test.OldService)
    assert old
    :ok = Tree.snapshot()

    :code.purge(Services)
    {:module, Services} = :code.load_binary(Services, ~c"#{Services}.beam", next)
    app = :tree_regression_release

    :ok =
      :application.load(
        {:application, app,
         [description: ~c"the new release", vsn: ~c"1", modules: [Services], applications: []]}
      )

    {:ok, spec} = :application.get_all_key(:hal_c2)
    put_spec(:hal_c2, Keyword.update!(spec, :modules, &List.delete(&1, Services)))

    on_exit(fn ->
      put_spec(:hal_c2, spec)
      :application.unload(app)
    end)

    assert Application.get_application(Services) == app

    assert {:ok, changes} = Tree.sync()
    assert {:started, HalC2.Test.NewService} in changes
    assert {:stopped, HalC2.Test.OldService} in changes
    assert Process.whereis(HalC2.Test.NewService)
  end

  defp put_spec(app, spec) do
    keys = [:description, :vsn, :modules, :registered, :applications, :mod, :start_phases]
    env = Application.get_all_env(app)

    :ok =
      :application_controller.change_application_data(
        [{:application, app, Keyword.take(spec, keys) ++ [env: env]}],
        [{app, env}]
      )
  end
end
