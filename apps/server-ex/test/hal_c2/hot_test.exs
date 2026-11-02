defmodule HalC2.HotTest do
  # Reloads a module shared by the whole VM, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias HalC2.JsonRpc.Connection

  @peer Path.expand("../support/echo_rpc.py", __DIR__)
  @source Path.expand("../../lib/hal_c2/json_rpc/connection.ex", __DIR__)

  @tag :tmp_dir
  test "upgrades a live connection in place without restarting its subprocess", %{tmp_dir: dir} do
    conn = start_supervised!({Connection, cmd: ["python3", "-u", @peer], handler: self()})
    assert {:ok, _} = Connection.call(conn, "echo", 1)
    os_pid = Connection.os_pid(conn)
    assert %{v: 1} = :sys.get_state(conn)

    # A call in flight across the upgrade must still be answered afterwards.
    in_flight = Task.async(fn -> Connection.call(conn, "ask", "mid-upgrade") end)
    assert_receive {:json_rpc, ^conn, {:request, srv_id, "approve", "mid-upgrade"}}

    v2 =
      compile_variant(dir, fn src ->
        String.replace(src, "@state_version 1", "@state_version 2")
      end)

    assert {:ok, report} = HalC2.Hot.reload(v2)
    assert report.changed == [Connection]
    assert conn in report.migrated

    assert %{v: 2} = :sys.get_state(conn)
    assert Connection.os_pid(conn) == os_pid
    Connection.respond(conn, srv_id, {:ok, "yes"})
    assert {:ok, %{"answer" => "yes"}} = Task.await(in_flight)
    assert {:ok, %{"params" => 2}} = Connection.call(conn, "echo", 2)

    # Reloading identical code is a no-op.
    assert {:ok, %{changed: []}} = HalC2.Hot.reload(v2)
  after
    # Put the original module back for any later test in this VM.
    HalC2.Hot.reload(HalC2.Hot.beams_from_dir(Application.app_dir(:hal_c2, "ebin")))
  end

  # A plain loop that recursed locally stayed on its first version, so the store
  # reloaded once and then never again: `{:previous_version_still_running, [HalC2.Store]}`.
  @tag :tmp_dir
  test "the store's checkpointer moves to new code", %{tmp_dir: dir} do
    store =
      start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite"), name: :hot_store})

    %{checkpointer: checkpointer} = :sys.get_state(store)
    {HalC2.Store, bin, file} = :code.get_object_code(HalC2.Store)
    assert :code.soft_purge(HalC2.Store)
    {:module, HalC2.Store} = :code.load_binary(HalC2.Store, file, bin)

    # The first is answered from the old loop, which then calls the new one by name.
    HalC2.Store.checkpoint(store)
    HalC2.Store.checkpoint(store)
    refute :erlang.check_process_code(checkpointer, HalC2.Store)
  after
    :code.soft_purge(HalC2.Store)
  end

  defp compile_variant(dir, edit) do
    src = Path.join(dir, "connection.ex")
    File.write!(src, edit.(File.read!(@source)))
    # Compile in a separate VM so the new version is not loaded until reload/1.
    {_, 0} =
      System.cmd("elixirc", ["--ignore-module-conflict", "-o", dir, src], stderr_to_stdout: true)

    dir |> HalC2.Hot.beams_from_dir() |> Enum.filter(fn {mod, _} -> mod == Connection end)
  end
end
