defmodule HalC2.Claude.SessionTest do
  # Drives the real `claude` CLI with Haiku; each test costs a few cents.
  use ExUnit.Case, async: true

  alias HalC2.Claude.Session

  @moduletag :claude
  @moduletag timeout: 180_000

  defp start_session(dir) do
    start_supervised!(
      {Session,
       handler: self(),
       cd: dir,
       model: "haiku",
       permission_mode: "default",
       persist_session: false}
    )
  end

  @tag :tmp_dir
  test "a denied tool permission reaches the model and nothing is written", %{tmp_dir: dir} do
    session = start_session(dir)

    Session.send_message(
      session,
      "Use the Write tool to create the file probe.txt containing hi. If you cannot, reply BLOCKED."
    )

    assert_receive {:claude, ^session, {:permission, id, "Write", %{"file_path" => path}, _}},
                   60_000

    assert Path.basename(path) == "probe.txt"
    Session.answer_permission(session, id, {:deny, "The user declined this write."})

    result = await_result(session)
    assert result["subtype"] == "success"
    refute File.exists?(Path.join(dir, "probe.txt"))
  end

  @tag :tmp_dir
  test "interrupt ends a running turn", %{tmp_dir: dir} do
    session = start_session(dir)
    Session.send_message(session, "Use the Write tool to create the file slow.txt containing hi.")

    # Hold the permission prompt open, then interrupt while the turn is waiting on us.
    assert_receive {:claude, ^session, {:permission, _id, "Write", _, _}}, 60_000
    assert {:ok, _} = Session.control(session, "interrupt")
    assert %{"type" => "result"} = await_result(session)
  end

  defp await_result(session) do
    receive do
      {:claude, ^session, {:message, %{"type" => "result"} = result}} -> result
      {:claude, ^session, _other} -> await_result(session)
    after
      90_000 -> flunk("no result message")
    end
  end
end

defmodule HalC2.Claude.SessionLaunchTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  alias HalC2.Claude.{McpConfig, Session}
  alias HalC2.Orchestration.Recovery

  @moduletag :tmp_dir
  @fake_claude Path.expand("../support/fake_claude.py", __DIR__)

  setup %{tmp_dir: home} do
    previous_home = Application.get_env(:hal_c2, :home)
    previous_durable = Application.get_env(:hal_c2, :durable_programs)
    Application.put_env(:hal_c2, :home, home)
    Application.put_env(:hal_c2, :durable_programs, false)

    on_exit(fn ->
      Application.put_env(:hal_c2, :home, previous_home)
      Application.put_env(:hal_c2, :durable_programs, previous_durable)
      Recovery.leaving(false)
    end)

    {:ok, home: home, argv_log: Path.join(home, "claude-argv.jsonl")}
  end

  test "an ordinary launch keeps its bearer in a private file until the process stops", %{
    home: home,
    argv_log: log
  } do
    mcp = server("ordinary-secret")
    session = start_session(home, log, mcp: mcp)
    await_initialized(session)

    argv = read_argv(log)
    path = config_path(argv)
    config_dir = Path.dirname(path)

    refute Enum.any?(argv, &String.contains?(&1, mcp.authorization))
    refute Enum.any?(argv, &String.contains?(&1, "ordinary-secret"))
    assert band(File.stat!(path).mode, 0o777) == 0o600
    assert band(File.stat!(config_dir).mode, 0o777) == 0o700

    assert JSON.decode!(File.read!(path)) == %{
             "mcpServers" => %{
               "hal-c2" => %{
                 "type" => "http",
                 "url" => mcp.url,
                 "headers" => %{"Authorization" => mcp.authorization}
               }
             }
           }

    GenServer.stop(session)
    refute File.exists?(config_dir)
  end

  test "a durable launch keeps its config through adoption and removes it on final stop", %{
    home: home,
    argv_log: log
  } do
    Application.put_env(:hal_c2, :durable_programs, true)
    session = start_session(home, log, mcp: server("durable-secret"), durable: "thread-config")
    await_initialized(session)

    path = log |> read_argv() |> config_path()
    durable_dir = :sys.get_state(session).sub.durable.dir
    assert Path.dirname(path) == Path.join(durable_dir, "mcp")

    Recovery.leaving(true)
    GenServer.stop(session)
    Recovery.leaving(false)
    assert File.exists?(path)

    adopted =
      start_session(home, log,
        adopt: %{dir: durable_dir, offset: 0, channel: %{next_id: 1, permissions: %{}}}
      )

    assert File.exists?(path)
    GenServer.stop(adopted)
    refute File.exists?(path)
    refute File.exists?(durable_dir)
  end

  test "startup sweeps abandoned ordinary configs but preserves durable ones", %{home: home} do
    ordinary_dir = McpConfig.new_dir()
    McpConfig.write!(server("stale-secret"), ordinary_dir)

    durable_path =
      McpConfig.write!(server("durable-secret"), Path.join([home, "durable", "saved", "mcp"]))

    assert :ok = HalC2.Application.prepare_files()
    refute File.exists?(ordinary_dir)
    assert File.exists?(durable_path)
  end

  defp start_session(home, log, opts) do
    opts =
      Keyword.merge(
        [
          handler: self(),
          cd: home,
          command: ["python3", "-u", @fake_claude],
          env: [{"FAKE_CLAUDE_ARGV_LOG", log}],
          persist_session: false
        ],
        opts
      )

    start_supervised!(
      Supervisor.child_spec({Session, opts},
        id: {Session, System.unique_integer([:positive])},
        restart: :temporary
      )
    )
  end

  defp await_initialized(session) do
    assert_receive {:claude, ^session, {:initialized, _reply}}, 5_000
  end

  defp read_argv(log) do
    [argv] = log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    argv
  end

  defp config_path(argv) do
    index = Enum.find_index(argv, &(&1 == "--mcp-config"))
    assert index
    path = Enum.at(argv, index + 1)
    assert Path.absname(path) == path
    path
  end

  defp server(token),
    do: %{url: "http://127.0.0.1:3780/mcp", authorization: "Bearer " <> token}
end
