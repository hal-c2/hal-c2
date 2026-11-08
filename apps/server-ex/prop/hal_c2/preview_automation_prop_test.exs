defmodule HalC2.PreviewAutomationPropTest do
  @moduledoc """
  `HalC2.PreviewAutomation` against a model of two promises: a new agent
  session goes to the host that is showing the tab it asks about, failing that
  to one holding a live page for it, then the focused and most recently
  focused one, and never to a host with only a snapshot of its browser; and a
  tab belongs to the agent session whose `open` created it, whatever happens
  to the host's connection, until that session forgets it. An open that reuses
  a tab (the one asked for, or the session's current tab) claims nothing.

  Commands change what the two desktops report (focus, shown tabs, live tabs,
  snapshot-only), start a fresh agent session on a tab (or none), open again
  in a session (reusing its current tab, or making a new one once its host
  was dropped), drop a session's host by a timed-out action, re-register a
  host, and ask whose a tab is or forget it. The test process is both
  desktops: it answers each request, making a new `HalC2.Preview` tab for an
  open that names none, as the desktop does.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.PreviewAutomation

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @hosts ["desk-1", "desk-2"]
  @tabs ["tab-a", "tab-b"]

  property "new sessions route by tab, focus and snapshot, and tabs stay with the session that made them",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("preview-automation")
        HalC2.Prop.start_services([HalC2.Preview, PreviewAutomation])
        Process.put(:connections, %{})
        Process.put(:made, %{})
        Enum.each(@hosts, &register/1)
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        flush()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # hosts: id => what it reports and when it last focused (or connected);
  # sessions: slot => the host it is assigned to and its current tab, both nil
  # once that host's connection went; owners: tab => the session whose open
  # created it; made: how many tabs opens have created, `{:made, n}` naming
  # the nth. Hosts connect in order, so desk-2 starts as the more recently focused.
  def initial_state do
    %{
      next: 0,
      order: 2,
      made: 0,
      hosts: %{
        "desk-1" => host(1),
        "desk-2" => host(2)
      },
      sessions: %{},
      owners: %{}
    }
  end

  defp host(order),
    do: %{focused: false, order: order, visible: [], live: [], snapshot: false}

  def command(state) do
    frequency(
      [
        {4, {:call, __MODULE__, :report, [oneof(@hosts), bool(), tabs(), tabs(), snapshot()]}},
        {4, {:call, __MODULE__, :session, [state.next, maybe_tab(), state.made]}},
        {1, {:call, __MODULE__, :reconnect, [oneof(@hosts)]}},
        {2, {:call, __MODULE__, :ownership, [session_slot(state), any_tab(state)]}}
      ] ++
        if(state.next == 0,
          do: [],
          else: [
            {3, {:call, __MODULE__, :reopen, [started(state), state.made]}},
            {2, {:call, __MODULE__, :forget, [session_slot(state), any_tab(state)]}}
          ]
        ) ++
        case for {slot, %{host: h}} <- state.sessions, h != nil, do: slot do
          [] -> []
          hosted -> [{1, {:call, __MODULE__, :evict, [oneof(hosted)]}}]
        end
    )
  end

  defp tabs, do: list(oneof(@tabs))
  defp snapshot, do: frequency([{4, false}, {1, true}])
  defp maybe_tab, do: frequency([{4, oneof(@tabs)}, {1, nil}])
  defp session_slot(state), do: integer(0, max(state.next, 1))
  defp started(state), do: integer(0, state.next - 1)

  defp any_tab(%{made: 0}), do: oneof(@tabs)
  defp any_tab(state), do: oneof(@tabs ++ for(n <- 0..(state.made - 1), do: {:made, n}))

  def precondition(state, {:call, _, :session, [slot, _, made]}),
    do: slot == state.next and made == state.made

  def precondition(state, {:call, _, :reopen, [slot, made]}),
    do: slot < state.next and made == state.made

  def precondition(state, {:call, _, :evict, [slot]}),
    do: state.sessions[slot][:host] != nil

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :report, [id, focused, visible, live, snapshot]}) do
    order = if focused, do: state.order + 1, else: state.order
    old = state.hosts[id]

    updated = %{
      old
      | focused: focused,
        order: if(focused, do: order, else: old.order),
        visible: Enum.uniq(visible),
        live: Enum.uniq(live),
        snapshot: snapshot
    }

    %{state | order: order, hosts: Map.put(state.hosts, id, updated)}
  end

  def next_state(state, _result, {:call, _, :session, [slot, tab, _made]}),
    do: state |> Map.put(:next, slot + 1) |> opened(slot, expected_host(state, tab), tab)

  # With a live host, its current tab is reused; without one it routes afresh.
  def next_state(state, _result, {:call, _, :reopen, [slot, _made]}) do
    case state.sessions[slot] do
      %{host: id, current: current} when id != nil -> opened(state, slot, id, current)
      _ -> opened(state, slot, expected_host(state, nil), nil)
    end
  end

  def next_state(state, _result, {:call, _, :evict, [slot]}),
    do: reregistered(state, state.sessions[slot].host)

  def next_state(state, _result, {:call, _, :reconnect, [id]}), do: reregistered(state, id)

  def next_state(state, _result, {:call, _, :forget, [slot, tab]}) do
    if state.owners[tab] == slot,
      do: %{state | owners: Map.delete(state.owners, tab)},
      else: state
  end

  def next_state(state, _result, _call), do: state

  # An open by `slot` reaching host `id` (or none): with no tab it makes one,
  # the session's own; a tab it names is only reused.
  defp opened(state, slot, nil, _tab),
    do: %{state | sessions: Map.put(state.sessions, slot, %{host: nil, current: nil})}

  defp opened(state, slot, id, nil) do
    tab = {:made, state.made}

    %{
      state
      | made: state.made + 1,
        owners: Map.put(state.owners, tab, slot),
        sessions: Map.put(state.sessions, slot, %{host: id, current: tab})
    }
  end

  defp opened(state, slot, id, tab),
    do: %{state | sessions: Map.put(state.sessions, slot, %{host: id, current: tab})}

  # A host's new connection: its sessions lose their assignment (never their
  # tabs), and it starts unfocused, reporting nothing, as the latest to connect.
  defp reregistered(state, id) do
    sessions =
      Map.new(state.sessions, fn
        {slot, %{host: ^id}} -> {slot, %{host: nil, current: nil}}
        other -> other
      end)

    order = state.order + 1
    %{state | order: order, sessions: sessions, hosts: Map.put(state.hosts, id, host(order))}
  end

  # The host a fresh session asking about `tab` should reach.
  defp expected_host(state, tab) do
    state.hosts
    |> Enum.reject(fn {_id, h} -> h.snapshot end)
    |> Enum.max_by(
      fn {_id, h} -> {tier(h, tab), h.focused, h.order} end,
      fn -> nil end
    )
    |> case do
      nil -> nil
      {id, _} -> id
    end
  end

  defp tier(_host, nil), do: 0

  defp tier(host, tab) do
    cond do
      tab in host.visible -> 2
      tab in host.live -> 1
      true -> 0
    end
  end

  def postcondition(state, {:call, _, :session, [_slot, tab, _made]}, result),
    do: result == expected_host(state, tab)

  def postcondition(state, {:call, _, :reopen, [slot, _made]}, result),
    do: result == (state.sessions[slot][:host] || expected_host(state, nil))

  def postcondition(state, {:call, _, :evict, [slot]}, result),
    do: result == state.sessions[slot].host

  def postcondition(state, {:call, _, :ownership, [slot, tab]}, result) do
    expected =
      case state.owners[tab] do
        nil -> :not_agent
        ^slot -> :own
        _ -> :other_agent
      end

    result == expected
  end

  def postcondition(_state, _call, _result), do: true

  # --- calls -----------------------------------------------------------------

  def report(id, focused, visible, live, snapshot) do
    PreviewAutomation.focus_host(%{
      "clientId" => id,
      "environmentId" => "env",
      "connectionId" => Process.get(:connections)[id],
      "focused" => focused,
      "visibleTabIds" => Enum.uniq(visible),
      "liveTabIds" => Enum.uniq(live),
      "snapshotOnly" => snapshot
    })

    :ok
  end

  # A fresh agent session's first action, an open of `tab` (or none); the
  # host's id, or nil when none would take it.
  def session(slot, tab, made), do: open(slot, if(tab, do: [tab_id: tab], else: []), made)

  # An open in a session that already acted, naming no tab.
  def reopen(slot, made), do: open(slot, [], made)

  # Answered by whichever desktop got it as the desktop does: the tab the
  # request names, else a new tab of the thread, recorded as `{:made, made}`.
  defp open(slot, opts, made) do
    task = Task.async(fn -> PreviewAutomation.invoke(scope(slot), "open", %{}, opts) end)

    receive do
      {:hal_c2_preview_automation, _, id,
       %{"type" => "request", "connectionId" => connection, "request" => request}} ->
        tab =
          request["tabId"] ||
            then(HalC2.Preview.open(%{"threadId" => scope(slot).thread_id}), fn {:ok, s} ->
              Process.put(:made, Map.put(Process.get(:made), made, s["tabId"]))
              s["tabId"]
            end)

        PreviewAutomation.respond(%{
          "clientId" => id,
          "connectionId" => connection,
          "requestId" => request["requestId"],
          "ok" => true,
          "result" => %{"tabId" => tab}
        })

        {:ok, _} = Task.await(task)
        id

      {ref, {:error, _}} when ref == task.ref ->
        # No request was sent: the call answered at once with no host.
        Process.demonitor(ref, [:flush])
        nil
    end
  end

  # A session's action its host never answers: the broker's timer fires now,
  # the host is dropped and its stream ends, and it registers again. Its id.
  def evict(slot) do
    task = Task.async(fn -> PreviewAutomation.invoke(scope(slot), "click", %{}) end)

    assert_receive {:hal_c2_preview_automation, _, id,
                    %{"type" => "request", "request" => request}}

    send(Process.whereis(PreviewAutomation), {:timeout, request["requestId"]})
    {:error, %{"_tag" => "PreviewAutomationTimeoutError"}} = Task.await(task)
    assert_receive {:hal_c2_preview_automation, _, ^id, :end}
    register(id)
    id
  end

  # The same desktop registering again, which replaces its connection.
  def reconnect(id), do: register(id)

  def ownership(slot, tab), do: PreviewAutomation.tab_ownership(scope(slot), real(tab))

  def forget(slot, tab) do
    PreviewAutomation.forget_tab(scope(slot), real(tab))
    # A call after the cast is served after it.
    PreviewAutomation.tab_ownership(scope(slot), tab)
    :ok
  end

  defp register(id) do
    {:ok, connection} =
      PreviewAutomation.connect(%{"clientId" => id, "environmentId" => "env"}, self())

    Process.put(:connections, Map.put(Process.get(:connections), id, connection))
    :ok
  end

  defp scope(slot), do: %{thread_id: "th-#{slot}", instance: "codex"}
  defp real({:made, n}), do: Process.get(:made)[n]
  defp real(tab), do: tab

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
