defmodule HalC2.CodexHotTest do
  use ExUnit.Case, async: false

  alias HalC2.JsonRpc.Connection

  @moduletag :codex
  @source Path.expand("../../lib/hal_c2/json_rpc/connection.ex", __DIR__)

  @tag :tmp_dir
  test "a real codex app-server survives a hot upgrade of its connection", %{tmp_dir: dir} do
    conn = start_supervised!({Connection, cmd: ["codex", "app-server"], handler: self()})

    assert {:ok, %{"userAgent" => _}} =
             Connection.call(conn, "initialize", %{
               "clientInfo" => %{"name" => "halc2_elixir_spike", "version" => "0.0.0"}
             })

    Connection.notify(conn, "initialized", nil)
    assert {:ok, %{"data" => [_ | _] = models}} = Connection.call(conn, "model/list", %{})
    os_pid = Connection.os_pid(conn)

    src = Path.join(dir, "connection.ex")
    File.write!(src, String.replace(File.read!(@source), "@state_version 1", "@state_version 2"))

    {_, 0} =
      System.cmd("elixirc", ["--ignore-module-conflict", "-o", dir, src], stderr_to_stdout: true)

    assert {:ok, %{migrated: [^conn]}} = HalC2.Hot.reload(HalC2.Hot.beams_from_dir(dir))

    assert %{v: 2} = :sys.get_state(conn)
    assert Connection.os_pid(conn) == os_pid
    assert {:ok, %{"data" => ^models}} = Connection.call(conn, "model/list", %{})
  after
    HalC2.Hot.reload(HalC2.Hot.beams_from_dir(Application.app_dir(:hal_c2, "ebin")))
  end
end
