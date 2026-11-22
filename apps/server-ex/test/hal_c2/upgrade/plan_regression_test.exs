defmodule HalC2.Upgrade.PlanRegressionTest do
  @moduledoc """
  `mise run mc:reload` from a checkout whose dependencies were compiled by another
  Erlang compiler found Finch's supervisor changed, and the relup updated it as a
  supervisor: `supervisor:code_change/3` runs `Finch.init/1` again, whose named ETS
  table already existed, so the install failed past its point of no return and the
  release handler restarted the node. Only the MC's own supervisors, whose specs
  `HalC2.Upgrade.Tree` reads again anyway, are updated as supervisors; another
  application's supervisor has its new code loaded.
  """

  use ExUnit.Case, async: false

  alias HalC2.Upgrade.Release

  @moduletag :tmp_dir

  # A dependency's supervisor whose `init/1`, like Finch's, may run only once.
  defp source(vsn) do
    """
    defmodule PlanRegressionT.Sup do
      use Supervisor
      def vsn, do: #{vsn}

      @impl true
      def init(name) do
        :ets.new(name, [:named_table, :public])
        Supervisor.init([], strategy: :one_for_one)
      end
    end
    """
  end

  # `app` at `vsn` in `<dir>/<app>-<vsn>`, holding the supervisor compiled from
  # `source`, which stays unloaded so the plan reads it from disk.
  defp lib(dir, app, vsn, source) do
    lib_dir = Path.join(dir, "#{app}-#{vsn}")
    ebin = Path.join(lib_dir, "ebin")
    File.mkdir_p!(ebin)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      for {mod, bin} <- Code.compile_string(source) do
        File.write!(Path.join(ebin, "#{mod}.beam"), bin)
        :code.purge(mod)
        :code.delete(mod)
        :code.purge(mod)
      end
    after
      Code.put_compiler_option(:ignore_module_conflict, false)
    end

    {app, vsn, lib_dir}
  end

  defp plan(dir, app) do
    spec = %{
      rel_dir: Path.join(dir, "releases"),
      from: "1",
      to: "2",
      from_libs: [lib(Path.join(dir, "from"), app, "1", source(1))],
      to_libs: [lib(Path.join(dir, "to"), app, "2", source(2))],
      from_consolidated: nil,
      to_consolidated: nil,
      otp_apps: MapSet.new()
    }

    {:ok, %{apps: [%{instructions: instructions}]}} = Release.plan(spec)
    Enum.find(instructions, &(elem(&1, 1) == PlanRegressionT.Sup))
  end

  test "another application's changed supervisor is loaded, not re-initialised",
       %{tmp_dir: dir} do
    assert plan(dir, :plan_regression_dep) ==
             {:load_module, PlanRegressionT.Sup, :soft_purge, :soft_purge, []}
  end

  test "the MC's own changed supervisor still re-reads its specs", %{tmp_dir: dir} do
    assert {:update, PlanRegressionT.Sup, :static, :default, {:advanced, []}, :soft_purge,
            :soft_purge, []} = plan(dir, :hal_c2)
  end
end
