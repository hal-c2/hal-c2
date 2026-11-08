defmodule HalC2.PluginsTurnHooksTest do
  # The plugin hooks on turns (features/plugins/turn-hooks.feature): an extension that
  # hears turns (`observe/2`), one that shapes a new conversation (`shape_run/2`), and
  # the host calls that act on a turn (`Host.steer/4`, `notice/5`, `history/3`), on a
  # fake Claude. The extensions' feeds run as the plugin host runs them, without the
  # rest of the host: their permissions are the settings document's, as the host's are.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.TurnWatch
  alias HalC2.Plugins.{Feed, Host}

  @moduletag :tmp_dir
  @fake_claude Path.expand("../support/fake_claude.py", __DIR__)
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)

  defmodule Listener do
    @moduledoc false
    def observe(event, %{settings: %{"test" => test, "tag" => nil}}),
      do: send(test, {:observed, event})

    def observe(event, %{settings: %{"test" => test, "tag" => tag}}),
      do: send(test, {:observed_by, tag, event})

    def shape_run(run, %{settings: %{"test" => test} = settings}) do
      send(test, {:shaping, run})

      case settings["shape"] do
        :raise -> raise "no shape"
        shape -> shape
      end
    end
  end

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :home, dir)

    Application.put_env(:hal_c2, :claude_command, [
      "env",
      "FAKE_CLAUDE_PROMPT_LOG=#{Path.join(dir, "provider.log")}",
      "FAKE_CLAUDE_TRACE=#{Path.join(dir, "trace.log")}",
      "python3",
      "-u",
      @fake_claude
    ])

    Application.put_env(:hal_c2, :codex_command, [
      "env",
      "FAKE_CODEX_TRACE=#{Path.join(dir, "codex.log")}",
      "python3",
      "-u",
      @fake_codex
    ])

    File.write!(Path.join(dir, "config.json"), "{}")
    Application.put_env(:hal_c2, :settings_check_ms, nil)

    on_exit(fn ->
      for key <- ~w(claude_command codex_command settings_check_ms)a,
          do: Application.delete_env(:hal_c2, key)
    end)

    start_supervised!(HalC2.Settings)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(TurnWatch)
    start_supervised!({Registry, keys: :unique, name: HalC2.Plugins.Hooks})
    start_supervised!({Registry, keys: :unique, name: HalC2.Claude.Registry}, id: :claude)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry}, id: :codex)
    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})

    %{thread_id: create_thread(work), work: work, dir: dir}
  end

  test "a plugin that hears turns gets a turn's start, its tool call by Claude's name, and its end, in order",
       %{thread_id: thread_id} do
    grant(%{"listener" => ["turns:observe"]})
    feed("listener")

    {:ok, _} = send_message(thread_id, "m1", "hello")

    assert_receive {:observed, %{"type" => "turn.started"} = started}, 5_000

    assert %{"threadId" => ^thread_id, "provider" => "claudeAgent", "newConversation" => true} =
             started

    run_id = started["runId"]

    assert_receive {:observed, %{"type" => "turn.item", "tool" => "Bash"} = item}, 5_000
    assert %{"runId" => ^run_id, "itemType" => "command_execution"} = item

    assert_receive {:observed, %{"type" => "turn.finished", "runId" => ^run_id} = finished}, 5_000
    assert finished["status"] == "completed"
  end

  test "a plugin hears which file a file change wrote, and a long output's end" do
    item = %{
      "id" => "i1",
      "type" => "file_change",
      "providerToolName" => "Edit",
      "status" => "completed",
      "fileName" => "/r/lib/a.ex",
      "output" => String.duplicate("x", 5_000) <> "tail"
    }

    observed = Orchestration.TurnWriter.observed_item(item)
    assert %{"tool" => "Edit", "path" => "/r/lib/a.ex", "itemType" => "file_change"} = observed
    assert String.length(observed["output"]) == 4_000
    assert String.ends_with?(observed["output"], "tail")
  end

  test "a plugin not granted turns:observe hears nothing of a turn", %{thread_id: thread_id} do
    grant(%{"listener" => ["turns:observe"], "deaf" => []})
    feed("listener")
    deaf = feed("deaf", "deaf")

    {:ok, _} = send_message(thread_id, "m1", "hello")
    assert_receive {:observed, %{"type" => "turn.finished"}}, 5_000

    # Both feeds were sent every event at once; the second has handled them all once
    # it answers.
    :sys.get_state(deaf)
    refute_received {:observed_by, "deaf", _}
  end

  test "a plugin shaping runs puts its context ahead of a new conversation's first message and turns a Claude tool off for the conversation",
       %{thread_id: thread_id, dir: dir} do
    grant(%{"shaper" => ["runs:shape"]})
    feed("shaper", nil, %{"context" => "Keep answers short.", "deniedTools" => ["WebFetch"]})

    {:ok, _} = send_message(thread_id, "m1", "first")

    assert_receive {:shaping,
                    %{"message" => "first", "toolUnit" => "tool", "provider" => "claudeAgent"}},
                   5_000

    await_statuses(thread_id, ["completed"])

    {:ok, _} = send_message(thread_id, "m2", "second")
    await_statuses(thread_id, ["completed", "completed"])
    # Asked once, as the conversation started.
    refute_received {:shaping, _}

    [first, second] = prompts(dir)
    assert first =~ ~r/^Keep answers short\.\s+.*first/s
    refute second =~ "Keep answers short."

    for argv <- launches(dir), do: assert(denied(argv) =~ "WebFetch")
  end

  test "a Claude tool a plugin turned off does not tell Claude to keep to HAL-C2's workers" do
    mcp = %{url: "http://127.0.0.1:1/mcp", authorization: "Bearer t"}
    note = String.trim(HalC2.Mcp.workers_only_note())
    told? = &(HalC2.Claude.Protocol.cli_args(&1) |> Enum.any?(fn arg -> arg =~ note end))

    refute told?.(mcp: mcp, disallowed_tools: ["WebFetch"], workers_only: false)
    assert told?.(mcp: mcp, disallowed_tools: ["Agent", "WebFetch"], workers_only: true)
  end

  test "a plugin turning Codex's collaboration off starts the native thread without it",
       %{work: work, dir: dir} do
    grant(%{"shaper" => ["runs:shape"]})
    feed("shaper", nil, %{"deniedTools" => ["collaboration", "no-such-capability"]})
    thread_id = create_thread(work, "codex", "gpt-5.4")

    {:ok, _} = send_message(thread_id, "m1", "first")
    assert_receive {:shaping, %{"toolUnit" => "capability", "provider" => "codex"}}, 5_000
    await_statuses(thread_id, ["completed"])

    [start] =
      for line <- File.read!(Path.join(dir, "codex.log")) |> String.split("\n", trim: true),
          %{"in" => %{"method" => "thread/start", "params" => params}} <- [JSON.decode!(line)],
          do: params

    assert %{
             "features" => %{"multi_agent" => false, "multi_agent_v2" => false},
             "include_collaboration_mode_instructions" => false
           } = start["config"]
  end

  test "a plugin that fails while shaping leaves the conversation as it was",
       %{thread_id: thread_id, dir: dir} do
    grant(%{"shaper" => ["runs:shape"]})
    feed("shaper", nil, :raise)

    {:ok, _} = send_message(thread_id, "m1", "first")
    await_statuses(thread_id, ["completed"])

    assert [prompt] = prompts(dir)
    assert prompt =~ "first"
    for argv <- launches(dir), do: refute(denied(argv) =~ "WebFetch")
  end

  test "a plugin steers the run it names while it works, and a steer to an ended run is refused and kept nowhere",
       %{thread_id: thread_id, dir: dir} do
    grant(%{"steerer" => ["threads:steer"]})

    {:ok, _} = send_message(thread_id, "m1", "wait m1")
    [running] = await_statuses(thread_id, ["running"])

    assert {:ok, _} = Host.steer("steerer", thread_id, running["id"], "use the cache")
    # The fake answers a steer in the turn it cut short, which then ends.
    [ended] = await_statuses(thread_id, ["completed"])
    assert Enum.any?(prompts(dir), &(&1 =~ "use the cache"))

    assert {:error, _} = Host.steer("steerer", thread_id, ended["id"], "too late")
    # Neither queued for a later turn nor kept as a message.
    assert ["completed"] = statuses(thread_id)
    refute Enum.any?(messages(thread_id), &(&1["text"] == "too late"))
  end

  test "steering a thread without threads:steer is refused", %{thread_id: thread_id} do
    grant(%{"steerer" => []})
    assert {:error, message} = Host.steer("steerer", thread_id, "run:any", "hi")
    assert message =~ "threads:steer"
  end

  test "a plugin's notice sits in the run it names, offering to stop it; a run the thread lacks is refused",
       %{thread_id: thread_id} do
    grant(%{"noticer" => ["threads:notice"]})
    {:ok, _} = send_message(thread_id, "m1", "wait m1")
    [running] = await_statuses(thread_id, ["running"])

    assert {:ok, item_id} =
             Host.notice("noticer", thread_id, running["id"], "The agent is repeating itself.",
               title: "Loop",
               interrupt: true
             )

    item = state(thread_id) |> StreamState.get("turn-item") |> Map.fetch!(item_id)

    assert %{
             "type" => "system_notice",
             "runId" => run_id,
             "title" => "Loop",
             "message" => "The agent is repeating itself.",
             "pluginId" => "noticer",
             "actions" => ["interrupt"]
           } = item

    assert run_id == running["id"]
    assert {:error, _} = Host.notice("noticer", thread_id, "run:none", "hi")
    :ok = HalC2.Claude.ThreadRuntime.interrupt(thread_id, running["id"])
    await_statuses(thread_id, ["interrupted"])
  end

  test "a plugin reads the turns a thread ran, oldest first, each with its calls",
       %{thread_id: thread_id} do
    grant(%{"reader" => ["turns:observe"]})

    {:ok, _} = send_message(thread_id, "m1", "one")
    await_statuses(thread_id, ["completed"])
    {:ok, _} = send_message(thread_id, "m2", "two")
    [first, second] = await_statuses(thread_id, ["completed", "completed"])

    assert {:ok, [one, two]} = Host.history("reader", thread_id)
    assert one["runId"] == first["id"] and two["runId"] == second["id"]
    assert Enum.any?(one["items"], &(&1["tool"] == "Bash"))

    assert {:ok, [^two]} = Host.history("reader", thread_id, limit: 1)
    assert {:error, _} = Host.history("reader", "thread-none")
  end

  test "text generation for a plugin reports what the provider said it used, or an estimate" do
    selection = %{"instanceId" => "claudeAgent", "model" => "claude-haiku-5-5"}

    reported = %{
      "inputTokens" => 120,
      "cachedInputTokens" => 100,
      "outputTokens" => 8,
      "costUsd" => 0.001
    }

    assert %{"estimated" => false, "inputTokens" => 120, "model" => "claude-haiku-5-5"} =
             HalC2.TextGeneration.usage(selection, "prompt", %{"a" => "b"}, reported)

    assert %{"estimated" => true, "inputTokens" => 2, "costUsd" => nil} =
             HalC2.TextGeneration.usage(selection, "12345678", %{"a" => "b"}, nil)
  end

  # --- helpers ------------------------------------------------------------------------

  defp grant(grants) do
    {settings, version} = HalC2.Settings.get()

    plugins =
      Map.new(grants, fn {id, granted} -> {id, %{"enabled" => true, "granted" => granted}} end)

    {:ok, _} = HalC2.Settings.put(Map.put(settings, "plugins", plugins), version)
  end

  # A feed for the extension `id`, as the plugin host starts one; it tells the test
  # process what it heard, by its `tag` when it has one, and shapes runs with `shape`.
  defp feed(id, tag \\ nil, shape \\ nil) do
    settings = %{"test" => self(), "tag" => tag, "shape" => shape}
    start_supervised!({Feed, {id, Listener, settings}}, id: {:feed, id})
  end

  defp create_thread(work, instance \\ "claudeAgent", model \\ "claude-sonnet-5-5") do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Hooks",
        "modelSelection" => %{"instanceId" => instance, "model" => model},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    thread_id
  end

  defp send_message(thread_id, message_id, text) do
    Orchestration.dispatch(%{
      "type" => "message.dispatch",
      "threadId" => thread_id,
      "messageId" => message_id,
      "text" => text,
      "attachments" => [],
      "dispatchMode" => %{"type" => "queue_after_active"}
    })
  end

  # The text of each message the fake Claude was sent, steers included.
  defp prompts(dir) do
    for line <- File.read!(Path.join(dir, "provider.log")) |> String.split("\n", trim: true),
        do: JSON.decode!(line)
  end

  # The argv of each launch of the fake Claude.
  defp launches(dir) do
    for line <- File.read!(Path.join(dir, "trace.log")) |> String.split("\n", trim: true),
        %{"argv" => argv} <- [JSON.decode!(line)],
        do: argv
  end

  defp denied(argv) do
    case Enum.drop_while(argv, &(&1 != "--disallowedTools")) do
      [_, tools | _] -> tools
      _ -> ""
    end
  end

  defp state(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  defp messages(thread_id), do: thread_id |> state() |> StreamState.list("message")

  defp statuses(thread_id) do
    thread_id
    |> state()
    |> StreamState.list("run")
    |> Enum.sort_by(& &1["ordinal"])
    |> Enum.map(& &1["status"])
  end

  defp await_statuses(thread_id, statuses) do
    runs = thread_id |> state() |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

    if Enum.map(runs, & &1["status"]) == statuses do
      runs
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_statuses(thread_id, statuses)
      after
        5_000 ->
          flunk("runs never reached #{inspect(statuses)}, at #{inspect(statuses(thread_id))}")
      end
    end
  end
end
