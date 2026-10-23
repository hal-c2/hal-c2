defmodule HalC2.WebSocketWatchPropTest do
  @moduledoc """
  Shapes that watch an MC-wide service (`HalC2.Watchers`) on one client socket, against
  a model of what they promise: every subscription the socket holds to one (a page in
  each window of one client) is told every change of the service under its own id,
  from its sub until its own unsub, whatever the others, on that shape or another, do.
  Two shapes stand for them all: `slack` (`HalC2.Test.FakeSlack`), whose change is a
  sequence of states, and `pullRequestRefreshes`, whose change is one revision. A third,
  `old`, is `pullRequestRefreshes` on a cluster member from before refs
  (`HalC2.Test.OldMc`), which the socket watches without one: its subscriptions share
  one watch, and the member must be told to let go of it with the last of them, never
  before.

  Commands subscribe and unsubscribe ids from a small pool per shape, unsubscribe an id
  and subscribe it again with the unsubscribe reaching the service only after the new
  subscribe (as an `:erpc.cast` may), the same while the service changes before the new
  subscribe is answered (the changes sent for the old subscription still waiting in the
  socket's mailbox), and change a service. After every step, the frames of both shapes
  the socket sent before the pong answering a ping must be exactly the model's: a
  snapshot for a sub, nothing for an unsub, each step of a change for each subscription
  to that shape, and only where it ended for one made during it.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.PullRequests.Refreshes
  alias HalC2.Test.{FakeSlack, LateUnsubscribe, OldMc, WsClient}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @kinds [:slack, :refreshes, :old]
  @ids %{slack: [1, 2, 3], refreshes: [4, 5, 6], old: [7, 8]}
  # The kinds the socket watches under refs; an old member's late unsubscribe is its own.
  @late [:slack, :refreshes]
  @services %{slack: HalC2.Slack, refreshes: Refreshes}

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

  property "each subscription to a watched service follows it until its own unsub",
    numtests: HalC2.Prop.numtests(60),
    max_size: 30 do
    {_peer, old} = OldMc.start(self())
    :persistent_term.put({__MODULE__, :old}, old)

    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            stop()
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    Application.put_env(:hal_c2, :port, 0)
    HalC2.Prop.scratch_home("web-socket-watch")
    :persistent_term.erase({HalC2.Web, :token})
    Process.put({__MODULE__, :fake}, FakeSlack.start_unsupervised())
    :ok = OldMc.reset(old(), self())

    sup =
      HalC2.Prop.start_services([
        HalC2.Slack,
        Refreshes,
        Supervisor.child_spec(HalC2.Web, id: HalC2.Web)
      ])

    [port] =
      for {HalC2.Web, pid, _, _} <- Supervisor.which_children(sup) do
        {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
        port
      end

    gates = Map.new(@services, fn {kind, name} -> {kind, LateUnsubscribe.install(name)} end)
    Process.put({__MODULE__, :gates}, gates)
    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 5_000)
    Process.put({__MODULE__, :client}, client)
  end

  defp stop do
    Process.delete({__MODULE__, :client})

    for {_, gate} <- Process.delete({__MODULE__, :gates}) || %{},
        do: LateUnsubscribe.uninstall(gate)

    HalC2.Prop.stop_services()
    if stop = Process.delete({__MODULE__, :fake}), do: stop.()
  end

  # --- model ------------------------------------------------------------------------

  # subs: the ids subscribed to each shape. values: each service's state, the Slack
  # status's or the refresh revision.
  def initial_state,
    do: %{
      subs: %{slack: [], refreshes: [], old: []},
      values: %{slack: "off", refreshes: 0, old: 0}
    }

  def command(state) do
    held = for kind <- @late, id <- state.subs[kind], do: {kind, id}

    free =
      for kind <- @kinds, id <- @ids[kind], id not in state.subs[kind], do: {kind, id}

    frequency(
      [
        {3,
         let(kind <- oneof(@kinds), do: {:call, __MODULE__, :change, [kind, state.values[kind]]})}
      ] ++
        if(free != [],
          do: [{3, let({kind, id} <- oneof(free), do: {:call, __MODULE__, :sub, [kind, id]})}],
          else: []
        ) ++
        if(held != [],
          do: [
            {2, let({kind, id} <- oneof(held), do: {:call, __MODULE__, :unsub, [kind, id]})},
            {2, let({kind, id} <- oneof(held), do: {:call, __MODULE__, :resub, [kind, id]})},
            {2,
             let(
               {kind, id} <- oneof(held),
               do: {:call, __MODULE__, :resub_changing, [kind, id, state.values[kind]]}
             )}
          ],
          else: []
        ) ++
        if(state.subs.old != [],
          do: [
            {2,
             let(
               id <- oneof(state.subs.old),
               do: {:call, __MODULE__, :unsub_old, [id, length(state.subs.old) == 1]}
             )}
          ],
          else: []
        )
    )
  end

  def precondition(state, {:call, _, :sub, [kind, id]}), do: id not in state.subs[kind]

  def precondition(state, {:call, _, :unsub, [kind, id]}),
    do: kind in @late and id in state.subs[kind]

  def precondition(state, {:call, _, :unsub_old, [id, last]}),
    do: id in state.subs.old and last == (length(state.subs.old) == 1)

  def precondition(state, {:call, _, :resub, [kind, id]}), do: id in state.subs[kind]

  def precondition(state, {:call, _, :resub_changing, [kind, id, value]}),
    do: id in state.subs[kind] and value == state.values[kind]

  def precondition(state, {:call, _, :change, [kind, value]}), do: value == state.values[kind]

  def next_state(state, _result, {:call, _, :sub, [kind, id]}),
    do: update_in(state.subs[kind], &[id | &1])

  def next_state(state, _result, {:call, _, :unsub, [kind, id]}),
    do: update_in(state.subs[kind], &List.delete(&1, id))

  def next_state(state, _result, {:call, _, :unsub_old, [id, _last]}),
    do: update_in(state.subs.old, &List.delete(&1, id))

  def next_state(state, _result, {:call, _, :resub, _}), do: state

  def next_state(state, _result, {:call, _, :resub_changing, [kind, _, value]}),
    do: put_in(state.values[kind], List.last(steps(kind, value)))

  def next_state(state, _result, {:call, _, :change, [kind, value]}),
    do: put_in(state.values[kind], List.last(steps(kind, value)))

  def postcondition(state, {:call, _, :sub, [kind, id]}, frames),
    do: frames == [{kind, id, state.values[kind]}]

  def postcondition(_state, {:call, _, :unsub, _}, frames), do: frames == []

  # The old member lets go of the socket with its last subscription, and not before.
  def postcondition(_state, {:call, _, :unsub_old, [_id, last]}, result),
    do: result == {[], last}

  def postcondition(state, {:call, _, :resub, [kind, id]}, frames),
    do: frames == [{kind, id, state.values[kind]}]

  def postcondition(state, {:call, _, :change, [kind, value]}, frames),
    do:
      frames ==
        Enum.sort(for id <- state.subs[kind], step <- steps(kind, value), do: {kind, id, step})

  # The resubscribed id sees only where the change ended; the others, each step of it.
  def postcondition(state, {:call, _, :resub_changing, [kind, id, value]}, frames) do
    others =
      for other <- state.subs[kind],
          other != id,
          step <- steps(kind, value),
          do: {kind, other, step}

    frames == Enum.sort([{kind, id, List.last(steps(kind, value))} | others])
  end

  defp steps(:slack, "off"), do: ["connecting", "connected"]
  defp steps(:slack, _connected), do: ["off"]
  defp steps(kind, revision) when kind in [:refreshes, :old], do: [revision + 1]

  # --- commands ---------------------------------------------------------------------

  def sub(kind, id), do: send_frame(%{"t" => "sub", "id" => id, "shape" => shape(kind)})

  def unsub(_kind, id), do: send_frame(%{"t" => "unsub", "id" => id})

  # The unsub's frames, then the sub's, the unsubscribe held back until the sub is in.
  def resub(kind, id) do
    LateUnsubscribe.arm(gate(kind))
    client = WsClient.send_json(Process.get({__MODULE__, :client}), %{"t" => "unsub", "id" => id})
    Process.put({__MODULE__, :client}, client)
    await(:unsubscribe_held)
    unsubbed = frames()
    unsubbed ++ sub(kind, id)
  end

  # Unsubs `id`, then subs it again with the subscribe held at the service until it has
  # changed, as if the change landed while the socket waited on its answer.
  def resub_changing(kind, id, value) do
    gate = gate(kind)
    LateUnsubscribe.arm(gate, hold: true)
    unsubbed = unsub(kind, id)

    client = Process.get({__MODULE__, :client})

    Process.put(
      {__MODULE__, :client},
      WsClient.send_json(client, %{"t" => "sub", "id" => id, "shape" => shape(kind)})
    )

    await(:subscribe_held)
    change!(kind, value)
    LateUnsubscribe.release(gate)
    unsubbed ++ frames()
  end

  # The unsub's frames, and whether the old member was told to let go of the socket:
  # waited for when it is the last, else taken if it came already.
  def unsub_old(id, last) do
    frames = unsub(:old, id)
    wait = if last, do: 10_000, else: 0

    told =
      receive do
        {:old_mc_unsubscribed, _socket} -> true
      after
        wait -> false
      end

    {frames, told}
  end

  def change(kind, value) do
    change!(kind, value)
    frames()
  end

  defp change!(:slack, "off") do
    {:ok, _} =
      HalC2.Slack.connect(%{
        "botToken" => FakeSlack.bot_token(),
        "appToken" => FakeSlack.app_token()
      })
  end

  defp change!(:slack, _connected), do: {:ok, _} = HalC2.Slack.disconnect()
  defp change!(:refreshes, _revision), do: Refreshes.bump()
  defp change!(:old, _revision), do: OldMc.bump(old())

  defp shape(:slack), do: %{"type" => "slack", "mc" => mc()}
  defp shape(:refreshes), do: %{"type" => "pullRequestRefreshes", "mc" => mc()}
  defp shape(:old), do: %{"type" => "pullRequestRefreshes", "mc" => Atom.to_string(old())}

  defp old, do: :persistent_term.get({__MODULE__, :old})

  defp gate(kind), do: Map.fetch!(Process.get({__MODULE__, :gates}), kind)

  defp await(message) do
    receive do
      ^message -> :ok
    after
      10_000 -> exit({:never, message})
    end
  end

  defp mc, do: Atom.to_string(node())

  defp send_frame(frame) do
    Process.put(
      {__MODULE__, :client},
      WsClient.send_json(Process.get({__MODULE__, :client}), frame)
    )

    frames()
  end

  # Both shapes' frames sent before the pong answering a ping sent now, sorted, as
  # {kind, id, value}. A service may answer a change before it tells the socket (a
  # bump is a cast), so the ping waits for both to finish what they were sent first;
  # the socket reads its frames in order, so everything a step caused is in.
  defp frames do
    HalC2.Slack.status()
    :sys.get_state(Refreshes)
    client = WsClient.send_json(Process.get({__MODULE__, :client}), %{"t" => "ping"})
    {_pong, frames, client} = WsClient.recv_until(client, &(&1["t"] == "pong"), 10_000)
    Process.put({__MODULE__, :client}, client)

    Enum.sort(for frame <- frames, value = value(frame), value != nil, do: value)
  end

  defp value(%{"t" => "slack", "id" => id, "status" => status}), do: {:slack, id, status["state"]}

  defp value(%{"t" => "pullRequestRefreshes", "id" => id, "revision" => revision}),
    do: {if(id in @ids.old, do: :old, else: :refreshes), id, revision}

  defp value(_frame), do: nil
end
