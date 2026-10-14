defmodule HalC2.WebSocketSlackPropTest do
  @moduledoc """
  The `slack` shape on one client socket, against a model of what it promises: every
  subscription the socket holds to it (a Settings page in each window of one client)
  is told every change of the MC's Slack status under its own id, from its sub until
  its own unsub, whatever the others do. Slack is `HalC2.Test.FakeSlack`.

  Commands subscribe and unsubscribe ids from a small pool, and change the status
  (connect, or disconnect when connected). After every step, the Slack frames the
  socket sent before the pong answering a ping must be exactly the model's: a snapshot
  for a sub, nothing for an unsub, and each step of a change for each subscription held.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Test.{FakeSlack, WsClient}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @ids [1, 2, 3]

  setup do
    saved = for key <- [:port, :home], do: {key, Application.fetch_env(:hal_c2, key)}

    on_exit(fn ->
      :persistent_term.erase({HalC2.Web, :token})

      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end)
  end

  property "each Slack subscription on a socket follows the status until its own unsub",
    numtests: HalC2.Prop.numtests(60),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        stop()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    Application.put_env(:hal_c2, :port, 0)
    HalC2.Prop.scratch_home("web-socket-slack")
    :persistent_term.erase({HalC2.Web, :token})
    Process.put({__MODULE__, :fake}, FakeSlack.start_unsupervised())

    sup =
      HalC2.Prop.start_services([
        HalC2.Slack,
        Supervisor.child_spec(HalC2.Web, id: HalC2.Web)
      ])

    [port] =
      for {HalC2.Web, pid, _, _} <- Supervisor.which_children(sup) do
        {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
        port
      end

    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 5_000)
    Process.put({__MODULE__, :client}, client)
  end

  defp stop do
    Process.delete({__MODULE__, :client})
    HalC2.Prop.stop_services()
    if stop = Process.delete({__MODULE__, :fake}), do: stop.()
  end

  # --- model ------------------------------------------------------------------------

  # subs: the ids subscribed to the shape. phase: the Slack status's state.
  def initial_state, do: %{subs: [], phase: "off"}

  def command(state) do
    free = @ids -- state.subs

    frequency(
      [{3, {:call, __MODULE__, :change, [state.phase]}}] ++
        if(free != [], do: [{3, {:call, __MODULE__, :sub, [oneof(free)]}}], else: []) ++
        if(state.subs != [],
          do: [{2, {:call, __MODULE__, :unsub, [oneof(state.subs)]}}],
          else: []
        )
    )
  end

  def precondition(state, {:call, _, :sub, [id]}), do: id not in state.subs
  def precondition(state, {:call, _, :unsub, [id]}), do: id in state.subs
  def precondition(state, {:call, _, :change, [phase]}), do: phase == state.phase

  def next_state(state, _result, {:call, _, :sub, [id]}), do: %{state | subs: [id | state.subs]}

  def next_state(state, _result, {:call, _, :unsub, [id]}),
    do: %{state | subs: List.delete(state.subs, id)}

  def next_state(state, _result, {:call, _, :change, ["off"]}), do: %{state | phase: "connected"}
  def next_state(state, _result, {:call, _, :change, [_]}), do: %{state | phase: "off"}

  def postcondition(state, {:call, _, :sub, [id]}, frames), do: frames == [{id, state.phase}]
  def postcondition(_state, {:call, _, :unsub, _}, frames), do: frames == []

  def postcondition(state, {:call, _, :change, [phase]}, frames) do
    steps = if phase == "off", do: ["connecting", "connected"], else: ["off"]
    frames == Enum.sort(for id <- state.subs, step <- steps, do: {id, step})
  end

  # --- commands ---------------------------------------------------------------------

  def sub(id),
    do: send_frame(%{"t" => "sub", "id" => id, "shape" => %{"type" => "slack", "mc" => mc()}})

  def unsub(id), do: send_frame(%{"t" => "unsub", "id" => id})

  def change("off") do
    {:ok, _} =
      HalC2.Slack.connect(%{
        "botToken" => FakeSlack.bot_token(),
        "appToken" => FakeSlack.app_token()
      })

    slack_frames()
  end

  def change(_connected) do
    {:ok, _} = HalC2.Slack.disconnect()
    slack_frames()
  end

  defp mc, do: Atom.to_string(node())

  defp send_frame(frame) do
    Process.put(
      {__MODULE__, :client},
      WsClient.send_json(Process.get({__MODULE__, :client}), frame)
    )

    slack_frames()
  end

  # The Slack frames sent before the pong answering a ping sent now, sorted, as
  # {id, state}. HalC2.Slack tells the socket of a change before it answers it, and the
  # socket reads its frames in order, so everything a step caused is in.
  defp slack_frames do
    client = WsClient.send_json(Process.get({__MODULE__, :client}), %{"t" => "ping"})
    {_pong, frames, client} = WsClient.recv_until(client, &(&1["t"] == "pong"), 10_000)
    Process.put({__MODULE__, :client}, client)
    Enum.sort(for %{"t" => "slack", "id" => id, "status" => s} <- frames, do: {id, s["state"]})
  end
end
