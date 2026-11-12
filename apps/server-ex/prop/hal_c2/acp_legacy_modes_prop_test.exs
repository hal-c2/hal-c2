defmodule HalC2.AcpLegacyModesPropTest do
  @moduledoc """
  A registry agent's older ACP session modes (`modes`, set through `session/set_mode`),
  against a model of the mode the agent is in. The user picks a mode for a turn, and
  the agent changes mode by itself in a turn (`current_mode_update`, as one leaving
  plan mode does). Whatever order they come in, the agent ends each turn in the mode
  last picked or taken, and the instance's "mode" option shows that mode, so picking
  the mode the agent left switches it back. A probe of the agent (as a settings change
  or a listing starts) reads its options from a fresh session in the default mode, and
  must not make the option show that mode instead, nor may a reload that forgets what
  was read before it probes. An instance pointed at another agent is that agent's: it
  shows the new agent's default until a session of its own sets another.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity
  @tid "legacy-modes-thread"
  @instance "acpRegistry_modes"
  @agents ["modes-agent", "other-agent"]
  @fake Path.expand("../../test/support/fake_acme_agent.py", __DIR__)
  @modes ["ask", "code", "debug"]

  property "the agent ends each turn in the mode last picked or taken, and the option shows it",
    numtests: HalC2.Prop.numtests(40),
    max_size: 10 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start_case()

        try do
          {history, state, result} = run_commands(__MODULE__, cmds)

          (result == :ok)
          |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
          |> aggregate(command_names(cmds))
        after
          end_case()
        end
      end
    end
  end

  def initial_state, do: %{sends: 0, mode: hd(@modes), agent: hd(@agents)}

  def command(state) do
    frequency([
      {3, {:call, __MODULE__, :pick, [state.sends, oneof(@modes)]}},
      {2, {:call, __MODULE__, :drift, [state.sends, oneof(@modes)]}},
      {1, {:call, __MODULE__, :probe, []}},
      {1, {:call, __MODULE__, :reload, []}},
      {1, {:call, __MODULE__, :switch, [oneof(@agents)]}}
    ])
  end

  def precondition(state, {:call, _, _, [n, _]}), do: n == state.sends
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, _, [_, mode]}),
    do: %{state | sends: state.sends + 1, mode: mode}

  def next_state(%{agent: agent} = state, _result, {:call, _, :switch, [agent]}), do: state

  def next_state(state, _result, {:call, _, :switch, [agent]}),
    do: %{state | agent: agent, mode: hd(@modes)}

  def next_state(state, _result, {:call, _, _, []}), do: state

  def postcondition(_state, {:call, _, _, [_, mode]}, result),
    do: result == {{"completed", "mode: " <> mode}, mode}

  def postcondition(state, {:call, _, _, []}, result), do: result == state.mode

  def postcondition(%{agent: agent} = state, {:call, _, :switch, [agent]}, result),
    do: result == state.mode

  def postcondition(_state, {:call, _, :switch, [_]}, result), do: result == hd(@modes)

  # A turn the user sends in `mode`; the agent says the mode it is in.
  def pick(n, mode), do: turn(n, "say your mode", [%{"id" => "mode", "value" => mode}])

  # A turn in which the agent changes to `mode` by itself.
  def drift(n, mode), do: turn(n, "switch yourself to #{mode}", [])

  # The MC reads the agent again from a session of its own, and publishes what it read;
  # returns the mode the option shows then.
  def probe do
    HalC2.Acp.load()
    shown()
  end

  # A reload, as a settings change or a sign-in makes: the MC forgets what it read from
  # the agent and probes it again; returns the mode the option shows then.
  def reload do
    HalC2.Acp.forget(@instance)
    probe()
  end

  # The user points the instance at `agent` in settings (the same or another catalog
  # agent); returns the mode the option shows once the MC has read it.
  def switch(agent) do
    put_agent(agent)
    probe()
  end

  defp put_agent(agent) do
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

  defp turn(n, text, options) do
    id = "m#{n}"

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => id,
        "text" => text,
        "modelSelection" => %{
          "instanceId" => @instance,
          "model" => "acme/fast",
          "options" => options
        }
      })

    {await_turn(id), shown()}
  end

  # The mode the instance's "mode" option shows.
  defp shown do
    {HalC2.Acp, @instance, :config}
    |> :persistent_term.get([])
    |> Enum.find_value(&(&1["id"] == "mode" && &1["currentValue"]))
  end

  defp await_turn(id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
    run = state |> StreamState.list("run") |> Enum.find(&(&1["userMessageId"] == id))

    if run && run["status"] in ~w(completed failed) do
      messages =
        state
        |> StreamState.list("message")
        |> Enum.filter(&(&1["role"] == "assistant" and &1["runId"] == run["id"]))

      {run["status"], Enum.map_join(messages, &(&1["text"] || ""))}
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_turn(id)
      after
        10_000 -> raise "mode turn did not finish"
      end
    end
  end

  defp start_case do
    home = HalC2.Prop.scratch_home("acp-legacy-modes")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    File.write!(
      Path.join(home, "control.json"),
      JSON.encode!(%{"acme" => %{"legacyModes" => @modes}})
    )

    Application.put_env(:hal_c2, :acp_commands, %{
      @instance => ["python3", "-u", @fake, "--control", home, "--name", "acme"]
    })

    # A registry instance, as only those take a model's session options; the catalog
    # is in memory, so nothing reaches the network.
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

    HalC2.Prop.start_services([
      HalC2.Settings,
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      {Registry, keys: :unique, name: HalC2.Acp.Registry},
      {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one}
    ])

    put_agent(hd(@agents))
    HalC2.Acp.drop(@instance)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Legacy modes",
        "modelSelection" => %{"instanceId" => @instance, "model" => "acme/fast"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
  end

  defp end_case do
    HalC2.Prop.stop_services()
    HalC2.Acp.drop(@instance)
    Application.delete_env(:hal_c2, :acp_commands)
    :persistent_term.erase({HalC2.Acp.Catalog, :index})
  end
end
