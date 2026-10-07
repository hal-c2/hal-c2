defmodule HalC2.ShellRestartTest do
  # Uses the MC-wide named Store and Shell processes.
  use ExUnit.Case, async: false

  alias HalC2.{Shell, Store}

  @moduletag :tmp_dir

  @peer :"peer@shell-test.invalid"

  defmodule QuietWire do
    @moduledoc false
    # No member is reachable: what the shell sends them goes nowhere.
    def connected, do: []
    def cast(_peer, _message), do: :ok
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :shell_transport, QuietWire)
    on_exit(fn -> Application.delete_env(:hal_c2, :shell_transport) end)
    start_supervised!({Store, path: Path.join(dir, "hal-c2.sqlite")})

    {:ok, _} =
      Store.append([{:thread, "th-1", [{"thread", "th-1", %{"s" => %{"id" => "th-1"}}}]}])

    :ok = Store.put_shell("th-1", 1, row("th-1", "stored"))
    start_supervised!(Shell)
    :ok
  end

  defp row(id, title), do: {"thread", %{"id" => id, "title" => title}}

  defp stop_shell, do: :ok = Supervisor.terminate_child(HalC2.Shell.Supervisor, Shell)

  defp start_shell, do: {:ok, _} = Supervisor.restart_child(HalC2.Shell.Supervisor, Shell)

  test "the sidebar stays readable while the shell starts again" do
    stop_shell()

    assert [{{_, "th-1"}, {"thread", %{"title" => "stored"}}}] = Shell.rows()
    assert {"thread", _} = Shell.row(node(), "th-1")
    assert [{_, %{}}] = Shell.environments()

    start_shell()
    assert {"thread", %{"title" => "stored"}} = Shell.row(node(), "th-1")
  end

  test "subscribers stay subscribed when the shell starts again" do
    :ok = Shell.subscribe(self())
    %{mcs: [%{epoch: before}]} = Shell.subscribe(spawn_client(), %{})

    stop_shell()
    start_shell()
    {epoch, 0} = Shell.version()
    assert epoch != before

    # The client is sent this MC's rows whole, in the new epoch.
    assert_receive {:client, {:rows, _, [{"th-1", _}], %{epoch: ^epoch, rev: 0, reset: true}}}

    Shell.put_row("th-1", row("th-1", "changed"))
    assert_receive {:hal_c2_shell, {:rows, _, [{"th-1", {"thread", %{"title" => "changed"}}}]}}
    assert_receive {:client, {:rows, _, [{"th-1", _}], %{epoch: ^epoch, rev: 1, reset: false}}}
  end

  test "rows a forgotten member sent before it was forgotten do not bring it back" do
    send(Shell, {:nodeup, @peer})
    cast_from_peer([{"r1", row("r1", "a"), 1}])
    Shell.version()
    assert {"thread", _} = Shell.row(@peer, "r1")

    Shell.forget("env-peer")
    # Sent before the member was removed, arriving after.
    cast_from_peer([{"r1", row("r1", "a"), 1}, {"r2", row("r2", "b"), 2}])
    Shell.version()

    assert for({{@peer, _}, _} = row <- Shell.rows(), do: row) == []
    refute List.keymember?(Shell.environments(), @peer, 0)
  end

  defp cast_from_peer(rows) do
    GenServer.cast(Shell, {:peer_environment, @peer, %{"environmentId" => "env-peer"}})
    GenServer.cast(Shell, {:peer_rows, @peer, {"peer-epoch", length(rows)}, 0, rows, true})
  end

  test "a shell that takes this version's code in place keeps its subscribers" do
    test = self()
    :ok = Shell.subscribe(test)
    :ok = :sys.suspend(Shell)

    # Its state as the version before kept it: subscribers and peers' versions in
    # the state, monitored by ref, and no tables for them.
    :sys.replace_state(Shell, fn state ->
      :ets.delete(HalC2.Shell.Subscribers)
      :ets.delete(HalC2.Shell.Versions)
      %{online: state.online, subscribers: %{test => {make_ref(), :plain}}, versions: %{}}
    end)

    :ok = :sys.change_code(Shell, Shell, nil, nil)
    :ok = :sys.resume(Shell)

    {epoch, 0} = Shell.version()
    Shell.put_row("th-1", row("th-1", "new"))
    assert_receive {:hal_c2_shell, {:rows, _, [{"th-1", {"thread", %{"title" => "new"}}}]}}
    assert {^epoch, 1} = Shell.version()
  end

  # A client subscriber that forwards what the shell sends it.
  defp spawn_client do
    parent = self()

    spawn_link(fn ->
      forward = fn forward ->
        receive do
          {:hal_c2_shell, message} ->
            send(parent, {:client, message})
            forward.(forward)
        end
      end

      forward.(forward)
    end)
  end
end
