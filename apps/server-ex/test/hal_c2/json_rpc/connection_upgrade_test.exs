defmodule HalC2.JsonRpc.ConnectionUpgradeTest do
  # Loads other versions of modules the whole VM shares, so it runs alone.
  use ExUnit.Case, async: false

  alias HalC2.JsonRpc.Connection

  @peer Path.expand("../../support/echo_rpc.py", __DIR__)
  @source Path.expand("../../../lib/hal_c2/json_rpc/connection.ex", __DIR__)

  # What a release upgrade's `{update, Connection, {advanced, []}}` does to a process
  # running it: suspend, load the new code, `code_change/3`, resume.
  defp upgrade(pid, mod, beam) do
    :ok = :sys.suspend(pid)
    {^mod, _, file} = :code.get_object_code(mod)
    true = :code.soft_purge(mod)
    {:module, ^mod} = :code.load_binary(mod, file, beam)
    :ok = :sys.change_code(pid, mod, :old, [])
    :ok = :sys.resume(pid)
  end

  defp restore(mod) do
    {^mod, beam, file} = :code.get_object_code(mod)
    :code.soft_purge(mod)
    :code.load_binary(mod, file, beam)
    :code.soft_purge(mod)
  end

  test "a connection migrates its state in place without restarting its subprocess" do
    conn = start_supervised!({Connection, cmd: ["python3", "-u", @peer], handler: self()})
    assert {:ok, _} = Connection.call(conn, "echo", 1)
    os_pid = Connection.os_pid(conn)
    assert %{v: 1} = :sys.get_state(conn)

    # A call in flight across the upgrade must still be answered afterwards.
    in_flight = Task.async(fn -> Connection.call(conn, "ask", "mid-upgrade") end)
    assert_receive {:json_rpc, ^conn, {:request, srv_id, "approve", "mid-upgrade"}}

    v2 =
      HalC2.Test.Compile.beam(
        Connection,
        String.replace(File.read!(@source), "@state_version 1", "@state_version 2")
      )

    upgrade(conn, Connection, v2)

    assert %{v: 2} = :sys.get_state(conn)
    assert Connection.os_pid(conn) == os_pid
    Connection.respond(conn, srv_id, {:ok, "yes"})
    assert {:ok, %{"answer" => "yes"}} = Task.await(in_flight)
    assert {:ok, %{"params" => 2}} = Connection.call(conn, "echo", 2)
    refute :erlang.check_process_code(conn, Connection)
  after
    restore(Connection)
  end

  @tag :codex
  test "a real codex app-server survives an upgrade of its connection" do
    conn = start_supervised!({Connection, cmd: ["codex", "app-server"], handler: self()})

    assert {:ok, %{"userAgent" => _}} =
             Connection.call(conn, "initialize", %{
               "clientInfo" => %{"name" => "hal_c2_elixir_spike", "version" => "0.0.0"}
             })

    Connection.notify(conn, "initialized", nil)
    assert {:ok, %{"data" => [_ | _] = models}} = Connection.call(conn, "model/list", %{})
    os_pid = Connection.os_pid(conn)

    v2 =
      HalC2.Test.Compile.beam(
        Connection,
        String.replace(File.read!(@source), "@state_version 1", "@state_version 2")
      )

    upgrade(conn, Connection, v2)

    assert %{v: 2} = :sys.get_state(conn)
    assert Connection.os_pid(conn) == os_pid
    assert {:ok, %{"data" => ^models}} = Connection.call(conn, "model/list", %{})
  after
    restore(Connection)
  end

  # A plain loop that recursed locally stayed on its first version, so the store
  # took one upgrade and then never another: its old code was never free to purge.
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
end
