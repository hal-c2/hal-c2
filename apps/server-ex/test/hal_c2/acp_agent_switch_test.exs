defmodule HalC2.AcpAgentSwitchTest do
  # Regressions HalC2.AcpLegacyModesPropTest found in the review of hal-c2/hal-c2#1552:
  # a thread kept running the agent its registry instance named before a settings
  # change, and a mode its session kept went unshown once the instance was dropped.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @tid "agent-switch-thread"
  @instance "acpRegistry_switch"
  @agents ["modes-agent", "other-agent"]
  @fake Path.expand("../support/fake_acme_agent.py", __DIR__)

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    File.write!(
      Path.join(dir, "control.json"),
      JSON.encode!(%{"acme" => %{"legacyModes" => ["ask", "code", "debug"]}})
    )

    Application.put_env(:hal_c2, :home, dir)

    Application.put_env(:hal_c2, :acp_commands, %{
      @instance => ["python3", "-u", @fake, "--control", dir, "--name", "acme"]
    })

    :persistent_term.put(
      {HalC2.Acp.Catalog, :index},
      {System.system_time(:millisecond),
       for id <- @agents do
         %{
           "id" => id,
           "name" => id,
           "version" => "1.0.0",
           "distribution" => %{
             "binary" => %{HalC2.Acp.Catalog.platform() => %{"archive" => "", "cmd" => "./acme"}}
           }
         }
       end}
    )

    File.write!(Path.join(dir, "config.json"), "{}")
    start_supervised!(HalC2.Settings)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!({Registry, keys: :unique, name: HalC2.Acp.Registry})

    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})

    on_exit(fn ->
      HalC2.Acp.drop(@instance)
      Application.delete_env(:hal_c2, :acp_commands)
      :persistent_term.erase({HalC2.Acp.Catalog, :index})
    end)

    point_at("modes-agent")
    HalC2.Acp.drop(@instance)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Agent switch",
        "modelSelection" => %{"instanceId" => @instance, "model" => "acme/fast"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
    :ok
  end

  test "a thread's next turn runs the agent its instance names now" do
    assert turn("m0", "code") == "mode: code"

    point_at("other-agent")

    # The other agent's session starts in its default mode, as the old one's did not.
    assert turn("m1", nil) == "mode: ask"
  end

  test "a mode the session kept shows again once picked, after the instance was dropped" do
    assert turn("m0", "code") == "mode: code"

    point_at("other-agent")
    point_at("modes-agent")
    HalC2.Acp.load()
    assert shown() == "ask"

    assert turn("m1", "code") == "mode: code"
    assert shown() == "code"
  end

  defp point_at(agent) do
    {_, version} = HalC2.Settings.get()

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            @instance => %{
              "driver" => "acpRegistry",
              "enabled" => true,
              "config" => %{"agentId" => agent}
            }
          }
        },
        version
      )
  end

  defp shown do
    {HalC2.Acp, @instance, :config}
    |> :persistent_term.get([])
    |> Enum.find_value(&(&1["id"] == "mode" && &1["currentValue"]))
  end

  # A turn picking `mode` (none: the session's own); returns what the agent said.
  defp turn(id, mode) do
    options = if mode, do: [%{"id" => "mode", "value" => mode}], else: []

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => id,
        "text" => "say your mode",
        "modelSelection" => %{
          "instanceId" => @instance,
          "model" => "acme/fast",
          "options" => options
        }
      })

    await_turn(id)
  end

  defp await_turn(id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
    run = state |> StreamState.list("run") |> Enum.find(&(&1["userMessageId"] == id))

    if run && run["status"] in ~w(completed failed) do
      state
      |> StreamState.list("message")
      |> Enum.filter(&(&1["role"] == "assistant" and &1["runId"] == run["id"]))
      |> Enum.map_join(&(&1["text"] || ""))
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_turn(id)
      after
        10_000 -> flunk("turn #{id} did not finish")
      end
    end
  end
end
