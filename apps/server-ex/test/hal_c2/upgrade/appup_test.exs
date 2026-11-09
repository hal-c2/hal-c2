defmodule HalC2.Upgrade.AppupTest do
  use ExUnit.Case, async: true

  alias HalC2.Upgrade.Appup

  # The appup's view of `source` compiled, as `{module, beam info}`; the modules are
  # this test's own, so loading them disturbs nothing.
  defp beams(source) do
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      for {mod, bin} <- Code.compile_string(source), into: %{}, do: {mod, Appup.info(bin)}
    after
      Code.put_compiler_option(:ignore_module_conflict, false)
    end
  end

  @old """
  defmodule AppupT.Plain do def v, do: 1 end
  defmodule AppupT.Sup do
    use Supervisor
    def init(_), do: Supervisor.init([], strategy: :one_for_one)
  end
  defmodule AppupT.Server do
    use GenServer
    def init(n), do: {:ok, n}
  end
  defmodule AppupT.Gone do def v, do: 1 end
  defmodule AppupT.Same do def v, do: 1 end
  """

  @new """
  defmodule AppupT.Plain do def v, do: 2 end
  defmodule AppupT.Sup do
    use Supervisor
    def init(_), do: Supervisor.init([AppupT.Server], strategy: :one_for_one)
  end
  defmodule AppupT.Server do
    use GenServer
    def init(n), do: {:ok, {n, AppupT.Added.v()}}
  end
  defmodule AppupT.Added do def v, do: 1 end
  defmodule AppupT.Same do def v, do: 1 end
  """

  test "a release diff becomes additions, then updates by kind, then deletions" do
    old = beams(@old)
    new = beams(@new)

    assert Appup.instructions(old, new) == [
             {:add_module, AppupT.Added},
             {:load_module, AppupT.Plain, :soft_purge, :soft_purge, []},
             # A changed process module migrates its state; it needs what it now calls.
             {:update, AppupT.Server, {:advanced, []}, :soft_purge, :soft_purge, [AppupT.Added]},
             # A changed supervisor re-reads its specs; naming a child is not calling it.
             {:update, AppupT.Sup, :static, :default, {:advanced, []}, :soft_purge, :soft_purge,
              []},
             {:delete_module, AppupT.Gone}
           ]

    assert Enum.sort(Appup.changed(old, new)) ==
             [AppupT.Added, AppupT.Plain, AppupT.Server, AppupT.Sup]
  end

  test "a module that never ran has nothing to change" do
    new = beams("defmodule AppupT.Lazy do def v, do: 2 end")
    assert Appup.changed(%{AppupT.Lazy => %{md5: :unloaded}}, new) == []
  end

  # Processes wait in a frozen module's code, so a change to it takes a restart.
  test "a frozen module is told apart" do
    new = beams("defmodule AppupT.Frozen do use HalC2.Frozen end")
    assert new[AppupT.Frozen].frozen?
    refute Appup.info(elem(:code.get_object_code(HalC2.Upgrade.Appup), 1)).frozen?
  end

  test "a change to a module that is or was frozen takes a restart" do
    old = %{
      AppupT.F1 => %{md5: "a", frozen?: false},
      AppupT.F2 => %{md5: "a", frozen?: true},
      AppupT.F3 => %{md5: "a", frozen?: false},
      AppupT.F4 => %{md5: "a", frozen?: true}
    }

    new = %{
      AppupT.F1 => %{md5: "b", frozen?: true},
      AppupT.F2 => %{md5: "b", frozen?: false},
      AppupT.F3 => %{md5: "b", frozen?: false},
      AppupT.F4 => %{md5: "a", frozen?: true},
      AppupT.F5 => %{md5: "b", frozen?: true}
    }

    assert Enum.sort(Appup.frozen(old, new)) == [AppupT.F1, AppupT.F2]
  end

  test "a module loading a NIF is told apart" do
    {:ok, mod, bin} =
      :compile.forms(
        [
          {:attribute, 1, :module, :appup_t_nif},
          {:attribute, 1, :export, [init: 0]},
          {:function, 1, :init, 0,
           [
             {:clause, 1, [], [],
              [
                {:call, 1, {:remote, 1, {:atom, 1, :erlang}, {:atom, 1, :load_nif}},
                 [{:string, 1, ~c"x"}, {:integer, 1, 0}]}
              ]}
           ]}
        ],
        [:binary]
      )

    assert mod == :appup_t_nif
    assert Appup.info(bin).nif?
    refute Appup.info(elem(:code.get_object_code(HalC2.Upgrade.Appup), 1)).nif?
  end

  @tag :tmp_dir
  test "an appup is written the way the release tools read it", %{tmp_dir: dir} do
    path = Path.join(dir, "hal_c2.appup")
    term = Appup.appup("2.0.0", "1.0.0", [{:add_module, AppupT.Added}])
    Appup.write_term!(path, term)

    assert {:ok, [{~c"2.0.0", [{~c"1.0.0", [{:add_module, AppupT.Added}]}], []}]} =
             :file.consult(path)
  end
end
