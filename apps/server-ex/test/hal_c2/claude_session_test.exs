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

    logs = Path.join(home, "logs")
    File.mkdir_p!(logs)

    {:ok,
     home: home,
     argv_log: Path.join(logs, "claude-argv.jsonl"),
     mcp_log: Path.join(logs, "claude-mcp.jsonl")}
  end

  test "Claude is handed HAL-C2's server over stdin, never on its command line or on disk", %{
    home: home,
    argv_log: log,
    mcp_log: mcp_log
  } do
    mcp = server("ordinary-secret")
    session = start_session(home, log, mcp: mcp, env: [{"FAKE_CLAUDE_MCP_LOG", mcp_log}])
    await_initialized(session)
    Session.send_message(session, "which tools")
    assert_receive {:claude, ^session, {:message, %{"type" => "assistant"} = said}}, 5_000
    assert said["message"]["content"] == [%{"type" => "text", "text" => "tools: hal-c2"}]

    assert read_lines(mcp_log) == [
             %{
               "hal-c2" => %{
                 "type" => "http",
                 "url" => mcp.url,
                 "headers" => %{"Authorization" => mcp.authorization}
               }
             }
           ]

    [argv] = read_lines(log)
    refute Enum.any?(argv, &String.contains?(&1, "ordinary-secret"))
    refute "--mcp-config" in argv

    # The fakes' logs aside, nothing the MC keeps holds the credential.
    on_disk =
      for path <- Path.wildcard(Path.join(home, "**"), match_dot: true),
          not String.starts_with?(path, Path.dirname(log)),
          File.regular?(path),
          File.read!(path) =~ "ordinary-secret",
          do: path

    assert on_disk == []
  end

  test "a server Claude refuses leaves the session running without HAL-C2's tools", %{
    home: home,
    argv_log: log
  } do
    session =
      start_session(home, log,
        mcp: server("refused-secret"),
        env: [{"FAKE_CLAUDE_MCP_REFUSE", "1"}]
      )

    Session.send_message(session, "which tools")
    assert_receive {:claude, ^session, {:message, %{"type" => "assistant"} = said}}, 5_000
    assert said["message"]["content"] == [%{"type" => "text", "text" => "tools: none"}]
  end

  test "a message waits for Claude's answer to its servers, and no answer ends the session", %{
    home: home,
    argv_log: log
  } do
    prompts = Path.join(Path.dirname(log), "prompts.log")

    session =
      start_session(home, log,
        mcp: server("held-secret"),
        mcp_deadline: 200,
        env: [{"FAKE_CLAUDE_MCP_HOLD", "1"}, {"FAKE_CLAUDE_PROMPT_LOG", prompts}]
      )

    ref = Process.monitor(session)
    Session.send_message(session, "hello")
    assert_receive {:DOWN, ^ref, :process, ^session, :mcp_servers_unanswered}, 5_000
    refute File.exists?(prompts)
  end

  test "an adopted durable Claude keeps the servers it was handed", %{
    home: home,
    argv_log: log,
    mcp_log: mcp_log
  } do
    Application.put_env(:hal_c2, :durable_programs, true)

    session =
      start_session(home, log,
        mcp: server("durable-secret"),
        durable: "thread-config",
        env: [{"FAKE_CLAUDE_MCP_LOG", mcp_log}]
      )

    await_initialized(session)
    durable_dir = :sys.get_state(session).sub.durable.dir

    Recovery.leaving(true)
    GenServer.stop(session)
    Recovery.leaving(false)

    adopted =
      start_session(home, log,
        adopt: %{dir: durable_dir, offset: 0, channel: %{next_id: 1, permissions: %{}}}
      )

    Session.send_message(adopted, "which tools")
    assert_receive {:claude, ^adopted, {:message, %{"type" => "assistant"} = said}}, 5_000
    assert said["message"]["content"] == [%{"type" => "text", "text" => "tools: hal-c2"}]
    assert length(read_lines(mcp_log)) == 1
    GenServer.stop(adopted)
  end

  test "startup sweeps the MCP configs earlier MCs left behind", %{home: home} do
    stale = Path.join([McpConfig.root(), "abandoned", "mcp.json"])
    File.mkdir_p!(Path.dirname(stale))
    File.write!(stale, "{}")
    durable = Path.join([home, "durable", "saved", "mcp", "mcp.json"])
    File.mkdir_p!(Path.dirname(durable))
    File.write!(durable, "{}")

    assert :ok = HalC2.Application.prepare_files()
    refute File.exists?(stale)
    assert File.exists?(durable)
  end

  defp start_session(home, log, opts) do
    opts =
      Keyword.merge(
        [
          handler: self(),
          cd: home,
          command: ["python3", "-u", @fake_claude],
          persist_session: false
        ],
        opts
      )
      |> Keyword.update(
        :env,
        [{"FAKE_CLAUDE_ARGV_LOG", log}],
        &[{"FAKE_CLAUDE_ARGV_LOG", log} | &1]
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

  defp read_lines(log),
    do: log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

  defp server(token),
    do: %{url: "http://127.0.0.1:3780/mcp", authorization: "Bearer " <> token}
end
