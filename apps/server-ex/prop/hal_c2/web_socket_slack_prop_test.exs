defmodule HalC2.WebSocketSlackPropTest do
  @moduledoc """
  The `slack` shape on one client socket, against a model of what it promises: every
  subscription the socket holds to it (a Settings page in each window of one client)
  is told every change of the MC's Slack status under its own id, from its sub until
  its own unsub, whatever the others do. Slack is `HalC2.Test.FakeSlack`.

  Commands subscribe and unsubscribe ids from a small pool, unsubscribe an id and
  subscribe it again with the unsubscribe reaching HalC2.Slack only after the new
  subscribe (as an `:erpc.cast` may), the same while the status changes before the new
  subscribe is answered (the changes sent for the old subscription still waiting in the
  socket's mailbox), and change the status (connect, or disconnect when connected).
  After every step, the Slack frames the socket sent before the pong answering a ping
  must be exactly the model's: a snapshot for a sub, nothing for an unsub, each step of
  a change for each subscription held, and only where it ended for one made during it.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Test.{FakeSlack, LateUnsubscribe, WsClient}

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

    Process.put({__MODULE__, :gate}, LateUnsubscribe.install(HalC2.Slack))
    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 5_000)
    Process.put({__MODULE__, :client}, client)
  end

  defp stop do
    Process.delete({__MODULE__, :client})
    if gate = Process.delete({__MODULE__, :gate}), do: LateUnsubscribe.uninstall(gate)
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
          do: [
            {2, {:call, __MODULE__, :unsub, [oneof(state.subs)]}},
            {2,
             let(
               id <- oneof(state.subs),
               do: {:call, __MODULE__, :resub, [id, state.subs == [id]]}
             )},
            {2, {:call, __MODULE__, :resub_changing, [oneof(state.subs), state.phase]}}
          ],
          else: []
        )
    )
  end

  def precondition(state, {:call, _, :sub, [id]}), do: id not in state.subs
  def precondition(state, {:call, _, :unsub, [id]}), do: id in state.subs

  def precondition(state, {:call, _, :resub, [id, alone]}),
    do: id in state.subs and alone == (state.subs == [id])

  def precondition(state, {:call, _, :resub_changing, [id, phase]}),
    do: id in state.subs and phase == state.phase

  def precondition(state, {:call, _, :change, [phase]}), do: phase == state.phase

  def next_state(state, _result, {:call, _, :sub, [id]}), do: %{state | subs: [id | state.subs]}

  def next_state(state, _result, {:call, _, :unsub, [id]}),
    do: %{state | subs: List.delete(state.subs, id)}

  def next_state(state, _result, {:call, _, :resub, _}), do: state

  def next_state(state, _result, {:call, _, :resub_changing, [_, "off"]}),
    do: %{state | phase: "connected"}

  def next_state(state, _result, {:call, _, :resub_changing, _}), do: %{state | phase: "off"}
  def next_state(state, _result, {:call, _, :change, ["off"]}), do: %{state | phase: "connected"}
  def next_state(state, _result, {:call, _, :change, [_]}), do: %{state | phase: "off"}

  def postcondition(state, {:call, _, :sub, [id]}, frames), do: frames == [{id, state.phase}]
  def postcondition(_state, {:call, _, :unsub, _}, frames), do: frames == []
  def postcondition(state, {:call, _, :resub, [id, _]}, frames), do: frames == [{id, state.phase}]

  def postcondition(state, {:call, _, :change, [phase]}, frames),
    do: frames == Enum.sort(for id <- state.subs, step <- steps(phase), do: {id, step})

  # The resubscribed id sees only where the change ended; the others, each step of it.
  def postcondition(state, {:call, _, :resub_changing, [id, phase]}, frames) do
    others = for other <- state.subs, other != id, step <- steps(phase), do: {other, step}
    frames == Enum.sort([{id, List.last(steps(phase))} | others])
  end

  defp steps("off"), do: ["connecting", "connected"]
  defp steps(_connected), do: ["off"]

  # --- commands ---------------------------------------------------------------------

  def sub(id),
    do: send_frame(%{"t" => "sub", "id" => id, "shape" => %{"type" => "slack", "mc" => mc()}})

  def unsub(id), do: send_frame(%{"t" => "unsub", "id" => id})

  # The unsub's frames, then the sub's, the unsubscribe held back until the sub is in.
  # The socket's last unsub on the MC must tell HalC2.Slack, so that one is waited for.
  def resub(id, alone) do
    LateUnsubscribe.arm(Process.get({__MODULE__, :gate}))
    unsubbed = unsub(id)

    if alone do
      receive do
        :unsubscribe_held -> :ok
      after
        10_000 -> exit(:last_unsubscribe_never_sent)
      end
    end

    unsubbed ++ sub(id)
  end

  # Unsubs `id`, then subs it again with the subscribe held at HalC2.Slack until the
  # status has changed, as if the change landed while the socket waited on its answer.
  def resub_changing(id, phase) do
    gate = Process.get({__MODULE__, :gate})
    LateUnsubscribe.arm(gate, hold: true)
    unsubbed = unsub(id)

    client = Process.get({__MODULE__, :client})
    shape = %{"type" => "slack", "mc" => mc()}

    Process.put(
      {__MODULE__, :client},
      WsClient.send_json(client, %{"t" => "sub", "id" => id, "shape" => shape})
    )

    receive do
      :subscribe_held -> :ok
    after
      10_000 -> exit(:subscribe_never_sent)
    end

    change!(phase)
    LateUnsubscribe.release(gate)
    unsubbed ++ slack_frames()
  end

  def change(phase) do
    change!(phase)
    slack_frames()
  end

  defp change!("off") do
    {:ok, _} =
      HalC2.Slack.connect(%{
        "botToken" => FakeSlack.bot_token(),
        "appToken" => FakeSlack.app_token()
      })
  end

  defp change!(_connected), do: {:ok, _} = HalC2.Slack.disconnect()

  defp mc, do: Atom.to_string(node())

  defp send_frame(frame) do
    Process.put(
      {__MODULE__, :client},
      WsClient.send_json(Process.get({__MODULE__, :client}), frame)
    )

    slack_frames()
  end

  # The Slack frames sent before the pong answering a ping sent now, sorted, as
  # {id, state}. HalC2.Slack may answer a change before it tells the socket, so the
  # ping waits for it to finish the change first; the socket reads its frames in order,
  # so everything a step caused is in.
  defp slack_frames do
    HalC2.Slack.status()
    client = WsClient.send_json(Process.get({__MODULE__, :client}), %{"t" => "ping"})
    {_pong, frames, client} = WsClient.recv_until(client, &(&1["t"] == "pong"), 10_000)
    Process.put({__MODULE__, :client}, client)
    Enum.sort(for %{"t" => "slack", "id" => id, "status" => s} <- frames, do: {id, s["state"]})
  end
end
