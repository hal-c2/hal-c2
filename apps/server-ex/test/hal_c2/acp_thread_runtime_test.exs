defmodule HalC2.Acp.ThreadRuntimeTest do
  # Regressions from the review of hal-c2/hal-c2#1265: a prompt error whose JSON-RPC
  # `data` is not a map crashed the runtime in the OpenCode usage-limit check, and
  # the workers-only OpenCode config dropped the user's own config when it came
  # from the instance's environment or the project's.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.TurnWatch

  @moduletag :tmp_dir
  @fake_acp Path.expand("../support/fake_acp.py", __DIR__)
  @instances ~w(opencode grok)

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :home, dir)

    # OpenCode runs through a wrapper that records, per process it starts, the
    # `OPENCODE_CONFIG_CONTENT` it was started with.
    config_log = Path.join(dir, "config.log")
    trace = Path.join(dir, "opencode.log")
    wrapper = Path.join(dir, "fake-opencode")

    File.write!(wrapper, """
    #!/bin/sh
    printf '%s %s\n' "$$" "$OPENCODE_CONFIG_CONTENT" >> '#{config_log}'
    FAKE_ACP_TRACE='#{trace}' exec python3 -u '#{@fake_acp}' "$@"
    """)

    File.chmod!(wrapper, 0o755)

    Application.put_env(:hal_c2, :acp_commands, %{
      "opencode" => [wrapper],
      "grok" => [
        "env",
        "FAKE_ACP_TRACE=#{Path.join(dir, "grok.log")}",
        "python3",
        "-u",
        @fake_acp
      ]
    })

    File.write!(Path.join(dir, "config.json"), "{}")
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    start_supervised!(HalC2.Settings)
    for id <- @instances, do: HalC2.Acp.forget(id)

    # The workers-only config merge must not read this test machine's own value.
    had = System.get_env("OPENCODE_CONFIG_CONTENT")
    System.delete_env("OPENCODE_CONFIG_CONTENT")

    on_exit(fn ->
      Application.delete_env(:hal_c2, :acp_commands)
      Application.delete_env(:hal_c2, :settings_check_ms)
      for id <- @instances, do: HalC2.Acp.forget(id)
      if had, do: System.put_env("OPENCODE_CONFIG_CONTENT", had)
    end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(TurnWatch)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})

    for registry <- [HalC2.Claude.Registry, HalC2.Acp.Registry, HalC2.Pi.Registry],
        do: start_supervised!({Registry, keys: :unique, name: registry}, id: registry)

    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})

    %{work: work, dir: dir, config_log: config_log, trace: trace}
  end

  for {instance, model} <- [{"grok", "grok-4"}, {"opencode", "gpt-5.4"}] do
    test "a #{instance} prompt error with a string `data` fails the turn with its message",
         %{work: work, dir: dir} do
      thread_id = create_thread(work, unquote(instance), unquote(model))
      trace = Path.join(dir, "#{unquote(instance)}.log")

      {:ok, _} = send_message(thread_id, "m1", "wait for me")
      await_statuses(thread_id, ["running"])
      [{runtime, _}] = Registry.lookup(HalC2.Acp.Registry, thread_id)

      fail_waiting(thread_id, trace, %{
        "code" => -32603,
        "message" => "Internal error",
        "data" => "the step blew up"
      })

      await_statuses(thread_id, ["failed"])

      # Grok's failures name their JSON-RPC code; other agents' do not.
      expected =
        if unquote(instance) == "grok", do: "Internal error (-32603)", else: "Internal error"

      sessions = StreamState.list(current(thread_id), "provider-session")
      assert Enum.any?(sessions, &(&1["lastError"] == expected))
      refute Enum.any?(sessions, &(&1["lastErrorClass"] == "usage_limit"))

      # The runtime survived the error and runs the next turn.
      assert [{^runtime, _}] = Registry.lookup(HalC2.Acp.Registry, thread_id)
      {:ok, _} = send_message(thread_id, "m2", "say done")
      await_statuses(thread_id, ["failed", "completed"])
    end
  end

  # A Grok command the agent reports completed with only a non-zero exit in
  # its raw output failed: the plain-`exitCode`-is-not-a-failure reading is
  # Antigravity's and Cursor's alone (their features assert it).
  test "a Grok command with a non-zero exit code and no failed status is shown as failed",
       %{work: work} do
    thread_id = create_thread(work, "grok", "grok-4")
    {:ok, _} = send_message(thread_id, "m1", "run a failing command")
    await_statuses(thread_id, ["completed"])

    items = StreamState.list(current(thread_id), "turn-item")

    assert [%{"status" => "failed", "exitCode" => 1, "output" => output}] =
             Enum.filter(
               items,
               &(&1["type"] == "command_execution" and &1["input"] == "make test")
             )

    assert output =~ "boom"
  end

  test "an OpenCode config from the instance keeps its settings when its task tool is denied",
       %{work: work, dir: dir, config_log: config_log} do
    start_supervised!(HalC2.Mcp)

    update_settings(%{
      "nativeSubagents" => "hal-c2",
      "providerInstances" => %{
        "opencode" => %{
          "driver" => "opencode",
          "enabled" => true,
          "environment" => [
            %{
              "name" => "OPENCODE_CONFIG_CONTENT",
              "value" =>
                JSON.encode!(%{"theme" => "from-instance", "permission" => %{"edit" => "allow"}})
            }
          ]
        }
      }
    })

    thread_id = create_thread(work, "opencode", "gpt-5.4")
    {:ok, _} = send_message(thread_id, "m1", "say done")
    await_statuses(thread_id, ["completed"])

    assert session_config(thread_id, dir, config_log) == %{
             "theme" => "from-instance",
             "permission" => %{"edit" => "allow", "task" => "deny"}
           }
  end

  test "an OpenCode config from the project keeps its settings when its task tool is denied",
       %{work: work, dir: dir, config_log: config_log} do
    start_supervised!(HalC2.Mcp)

    config = JSON.encode!(%{"theme" => "from-project", "permission" => %{"edit" => "allow"}})
    File.write!(Path.join(work, ".env"), "OPENCODE_CONFIG_CONTENT=#{config}\n")

    update_settings(%{
      "nativeSubagents" => "hal-c2",
      "projectSettingsOverrides" => %{"project-1" => %{"projectEnvironment" => "dotenv"}}
    })

    thread_id = create_thread(work, "opencode", "gpt-5.4")
    {:ok, _} = send_message(thread_id, "m1", "say done")
    await_statuses(thread_id, ["completed"])

    assert session_config(thread_id, dir, config_log) == %{
             "theme" => "from-project",
             "permission" => %{"edit" => "allow", "task" => "deny"}
           }
  end

  # The config the thread's own OpenCode process (its connection's pid) started with.
  defp session_config(thread_id, _dir, config_log) do
    [{runtime, _}] = Registry.lookup(HalC2.Acp.Registry, thread_id)
    pid = HalC2.JsonRpc.Connection.os_pid(:sys.get_state(runtime).conn)

    recorded =
      config_log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [os_pid, json] = String.split(line, " ", parts: 2)
        {String.to_integer(os_pid), json}
      end)

    recorded[pid] && JSON.decode!(recorded[pid])
  end

  # Fails the fake's waiting prompt with `error`, as the provider features do
  # (`fail_waiting/2` in `opencode_steps.exs`).
  defp fail_waiting(thread_id, trace, error) do
    await_waiting_file(thread_id, trace <> ".waiting")
    File.write!(trace <> ".stop", JSON.encode!(error))
    {_, 0} = System.cmd("kill", ["-USR1", File.read!(trace <> ".waiting")])
  end

  defp await_waiting_file(thread_id, path) do
    if File.exists?(path) do
      :ok
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_waiting_file(thread_id, path)
      after
        5_000 -> flunk("the fake never noted its waiting prompt in #{path}")
      end
    end
  end

  defp update_settings(changes) do
    {settings, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(Map.merge(settings, changes), version)
  end

  defp create_thread(work, instance, model) do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Turns",
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

  defp current(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  defp statuses(thread_id) do
    thread_id
    |> current()
    |> StreamState.list("run")
    |> Enum.sort_by(& &1["ordinal"])
    |> Enum.map(& &1["status"])
  end

  # Waits until the thread's runs, in order, have these statuses; returns the runs.
  defp await_statuses(thread_id, expected) do
    runs =
      thread_id
      |> current()
      |> StreamState.list("run")
      |> Enum.sort_by(& &1["ordinal"])

    if Enum.map(runs, & &1["status"]) == expected do
      runs
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_statuses(thread_id, expected)
      after
        10_000 ->
          flunk("runs never reached #{inspect(expected)}, at #{inspect(statuses(thread_id))}")
      end
    end
  end
end
