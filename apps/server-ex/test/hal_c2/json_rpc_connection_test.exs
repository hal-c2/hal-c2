defmodule HalC2.JsonRpc.ConnectionTest do
  use ExUnit.Case, async: true

  alias HalC2.JsonRpc.Connection

  @peer Path.expand("../support/echo_rpc.py", __DIR__)

  setup do
    conn = start_supervised!({Connection, cmd: ["python3", "-u", @peer], handler: self()})
    %{conn: conn}
  end

  test "correlates responses with calls", %{conn: conn} do
    tasks = for i <- 1..20, do: Task.async(fn -> Connection.call(conn, "echo", %{"n" => i}) end)

    for {task, i} <- Enum.with_index(tasks, 1) do
      assert {:ok, %{"method" => "echo", "params" => %{"n" => ^i}}} = Task.await(task)
    end
  end

  test "forwards notifications to the handler", %{conn: conn} do
    assert {:ok, _} = Connection.call(conn, "notify_me", %{"step" => 1})
    assert_received {:json_rpc, ^conn, {:notification, "progress", %{"step" => 1}}}
  end

  test "server-to-client requests are answered by the handler", %{conn: conn} do
    call = Task.async(fn -> Connection.call(conn, "ask", %{"q" => "run ls?"}) end)

    assert_receive {:json_rpc, ^conn, {:request, id, "approve", %{"q" => "run ls?"}}},
                   5_000

    Connection.respond(conn, id, {:ok, "allow"})
    assert {:ok, %{"answer" => "allow"}} = Task.await(call)
  end

  test "stops and fails pending calls when the subprocess exits", %{conn: conn} do
    ref = Process.monitor(conn)
    System.cmd("kill", [to_string(Connection.os_pid(conn))])
    assert_receive {:DOWN, ^ref, :process, ^conn, _}, 2_000
  end

  test "passes on only the stderr lines that start with the prefix" do
    conn =
      start_supervised!(
        {Connection, cmd: ["python3", "-u", @peer], handler: self(), stderr_prefix: "Open: "},
        id: :stderr
      )

    lines = ["token=secret", "Open: https://one\r", "Open:no-space", "Open: https://two"]
    assert {:ok, _} = Connection.call(conn, "stderr", %{"lines" => lines})
    assert_receive {:json_rpc, ^conn, {:invalid, "Open: https://one"}}, 2_000
    assert_receive {:json_rpc, ^conn, {:invalid, "Open: https://two"}}, 2_000
    refute_received {:json_rpc, ^conn, {:invalid, _}}
  end

  # Reads the call, says why on stderr (in colour, as Rust's tracing does), and dies.
  @dies [
    "sh",
    "-c",
    ~S(read l; printf 'noise\n\n\033[31mERROR\033[0m config is not trusted\n' >&2; exit 1)
  ]

  test "a program's exit carries the end of its stderr, when kept" do
    conn =
      start_supervised!(
        {Connection, cmd: @dies, handler: self(), program: "Peer", stderr_tail: true},
        id: :tail,
        restart: :temporary
      )

    assert {:error, %{"message" => "Peer process exited with code 1", "stderr" => said}} =
             Connection.call(conn, "start", %{})

    assert said == "noise\nERROR config is not trusted"
  end

  test "stopping a connection whose program already exited is not an error" do
    conn =
      start_supervised!({Connection, cmd: @dies, handler: self(), program: "Peer"},
        id: :gone,
        restart: :temporary
      )

    ref = Process.monitor(conn)
    assert {:error, %{"exitCode" => 1}} = Connection.call(conn, "start", %{})
    assert_receive {:DOWN, ^ref, :process, ^conn, _}
    assert Connection.stop(conn) == :ok
  end

  test "a program's exit carries no stderr unless asked" do
    conn =
      start_supervised!({Connection, cmd: @dies, handler: self(), program: "Peer"},
        id: :no_tail,
        restart: :temporary
      )

    assert {:error, error} = Connection.call(conn, "start", %{})

    assert error == %{
             "message" => "Peer process exited with code 1",
             "exitCode" => 1,
             "ended" => true
           }
  end

  # Reads the call, closes its output and sleeps on without answering.
  @closes ["sh", "-c", ~S(read l; exec 1>&-; sleep 30)]

  test "a program that closes its output and keeps running fails its calls at once" do
    conn =
      start_supervised!(
        {Connection, cmd: @closes, handler: self(), program: "Peer", eof_grace: 100},
        id: :eof,
        restart: :temporary
      )

    started = System.monotonic_time(:millisecond)

    assert {:error, %{"message" => "Peer input stream ended."}} =
             Connection.call(conn, "start", %{})

    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "a program that exits within the grace fails its calls with its exit" do
    conn =
      start_supervised!(
        {Connection,
         cmd: @dies, handler: self(), program: "Peer", eof_grace: 1_000, stderr_tail: :whole},
        id: :eof_exit,
        restart: :temporary
      )

    assert {:error, %{"message" => "Peer process exited with code 1", "stderr" => said}} =
             Connection.call(conn, "start", %{})

    assert said == "noise\nERROR config is not trusted"
  end

  # Upstream #23938 (a flake of features/providers/codex.feature): a Codex that dies as it
  # starts can stop its connection before the first call reaches it. The call then exits
  # (`:noproc`) and only the connection's exit reason still says why; this waits for the
  # stop before calling, the order that once showed the generic "could not start".
  test "a call that finds the connection already stopped fails with the program's exit" do
    Process.flag(:trap_exit, true)
    said = "Error: Missing optional dependency @openai/codex-darwin-arm64"
    script = "printf '%s\\n' '#{said}' >&2; exit 1"

    {:ok, conn} =
      Connection.start_link(
        cmd: ["sh", "-c", script],
        handler: self(),
        program: "Peer",
        stderr_tail: true
      )

    error = %{
      "message" => "Peer process exited with code 1",
      "exitCode" => 1,
      "stderr" => said,
      "ended" => true
    }

    ref = Process.monitor(conn)
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:ended, ^error}}}, 5_000

    reply =
      try do
        Connection.call(conn, "initialize", %{})
      catch
        :exit, reason -> Connection.gone(conn, reason)
      end

    assert reply == {:error, error}
    # The owner still gets the exit, for its own handling of the program's end.
    assert_received {:EXIT, ^conn, {:shutdown, {:ended, ^error}}}
  end

  # A refused OpenCode (macOS quarantine) dies before its first call; the read stops
  # its connection afterwards all the same.
  test "stopping a connection whose subprocess already closed it is a no-op" do
    {:ok, conn} = GenServer.start(Connection, cmd: ["sh", "-c", "exit 137"], handler: self())
    ref = Process.monitor(conn)
    # The subprocess can exit and the connection stop before the monitor is set, in
    # which case the DOWN reason is :noproc rather than :normal.
    assert_receive {:DOWN, ^ref, :process, ^conn, reason}, 5_000
    assert reason in [:normal, :noproc]

    assert Connection.stop(conn) == :ok
  end

  # One that is still dying has closed its stdin, so the call's write fails with
  # `:epipe`; that read showed ":epipe" as OpenCode's message.
  test "a call written after the subprocess closed its stdin fails as closed" do
    conn =
      start_supervised!(
        {Connection, cmd: ["sh", "-c", "exec 0<&-; echo ready; exec sleep 30"], handler: self()},
        id: :closed_stdin,
        restart: :temporary
      )

    assert_receive {:json_rpc, ^conn, {:invalid, "ready"}}, 5_000
    assert Connection.call(conn, "initialize", %{}) == {:error, :closed}
  end

  # Upstream #27924: a program that stops reading but keeps its output open would leave
  # every call waiting. The write that fails ends the connection, and the call already
  # out fails with the same error rather than waiting on an answer that cannot come.
  test "a write a program no longer takes fails the open calls with it" do
    deaf = ~S(read l; exec 0<&-; echo '{"method":"deaf"}'; exec sleep 30)

    {:ok, conn} =
      GenServer.start(Connection, cmd: ["sh", "-c", deaf], handler: self(), program: "Peer")

    ref = Process.monitor(conn)
    open = Task.async(fn -> Connection.call(conn, "start", %{}) end)
    assert_receive {:json_rpc, ^conn, {:notification, "deaf", _}}, 5_000

    # Marked `"ended"`, as an exit is: the ACP runtime drops the connection on it
    # (`HalC2.Acp.ThreadRuntime.ended?/1`) and starts the agent afresh.
    assert {:error, error} = Connection.call(conn, "next", %{})

    assert error == %{
             "message" => "Peer stopped taking input (write failed: epipe)",
             "ended" => true
           }

    assert Task.await(open) == {:error, error}
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:write_failed, ^error}}}, 5_000
  end
end
