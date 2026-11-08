defmodule HalC2.PreviewAutomationPropTest do
  @moduledoc """
  `HalC2.PreviewAutomation` against a model of two promises: a new agent
  session goes to the host that is showing the tab it asks about, failing that
  to one holding a live page for it, then the focused and most recently
  focused one, and never to a host with only a snapshot of its browser; and a
  tab belongs to the agent sessions whose `open` landed on it, until one
  forgets it.

  Commands change what the two desktops report (focus, shown tabs, live tabs,
  snapshot-only), start a fresh agent session on a tab (or none), and ask whose
  a tab is or forget it. The test process is both desktops; it answers the one
  request a session's first action produces.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.PreviewAutomation

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @hosts ["desk-1", "desk-2"]
  @tabs ["tab-a", "tab-b"]

  property "new sessions route by tab, focus and snapshot, and tabs stay with who opened them",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("preview-automation")
        HalC2.Prop.start_services([PreviewAutomation])

        connections =
          for id <- @hosts, into: %{} do
            {:ok, connection} =
              PreviewAutomation.connect(%{"clientId" => id, "environmentId" => "env"}, self())

            {id, connection}
          end

        Process.put(:connections, connections)
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

  # hosts: id => what it reports and when it last focused; owners: tab => the
  # sessions whose open landed on it. Hosts connect in order, so desk-2 starts
  # as the more recently focused.
  def initial_state do
    %{
      next: 0,
      order: 2,
      hosts: %{
        "desk-1" => host(1),
        "desk-2" => host(2)
      },
      owners: %{}
    }
  end

  defp host(order),
    do: %{focused: false, order: order, visible: [], live: [], snapshot: false}

  def command(state) do
    frequency(
      [
        {4, {:call, __MODULE__, :report, [oneof(@hosts), bool(), tabs(), tabs(), snapshot()]}},
        {4, {:call, __MODULE__, :session, [state.next, maybe_tab()]}},
        {2, {:call, __MODULE__, :ownership, [session_slot(state), oneof(@tabs)]}}
      ] ++
        if(state.next == 0,
          do: [],
          else: [{2, {:call, __MODULE__, :forget, [session_slot(state), oneof(@tabs)]}}]
        )
    )
  end

  defp tabs, do: list(oneof(@tabs))
  defp snapshot, do: frequency([{4, false}, {1, true}])
  defp maybe_tab, do: frequency([{4, oneof(@tabs)}, {1, nil}])
  defp session_slot(state), do: integer(0, max(state.next, 1))

  def precondition(state, {:call, _, :session, [slot, _]}), do: slot == state.next
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

  def next_state(state, _result, {:call, _, :session, [slot, tab]}) do
    case expected_host(state, tab) do
      nil ->
        %{state | next: slot + 1}

      _id ->
        owned = tab || fresh_tab(slot)
        owners = Map.update(state.owners, owned, [slot], &Enum.uniq([slot | &1]))
        %{state | next: slot + 1, owners: owners}
    end
  end

  def next_state(state, _result, {:call, _, :forget, [slot, tab]}),
    do: %{state | owners: Map.update(state.owners, tab, [], &List.delete(&1, slot))}

  def next_state(state, _result, _call), do: state

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

  def postcondition(state, {:call, _, :session, [_slot, tab]}, result),
    do: result == expected_host(state, tab)

  def postcondition(state, {:call, _, :ownership, [slot, tab]}, result) do
    owners = Map.get(state.owners, tab, [])

    expected =
      cond do
        slot in owners -> :own
        owners != [] -> :other_agent
        true -> :not_agent
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

  # A fresh agent session's first action, answered by whichever desktop got
  # it; the host's id, or nil when none would take it.
  def session(slot, tab) do
    task =
      Task.async(fn ->
        opts = if tab, do: [tab_id: tab], else: []
        PreviewAutomation.invoke(scope(slot), "open", %{}, opts)
      end)

    receive do
      {:hal_c2_preview_automation, _, id,
       %{"type" => "request", "connectionId" => connection, "request" => request}} ->
        PreviewAutomation.respond(%{
          "clientId" => id,
          "connectionId" => connection,
          "requestId" => request["requestId"],
          "ok" => true,
          "result" => %{"tabId" => tab || fresh_tab(slot)}
        })

        {:ok, _} = Task.await(task)
        id

      {ref, {:error, _}} when ref == task.ref ->
        # No request was sent: the call answered at once with no host.
        Process.demonitor(ref, [:flush])
        nil
    end
  end

  def ownership(slot, tab), do: PreviewAutomation.tab_ownership(scope(slot), tab)

  def forget(slot, tab) do
    PreviewAutomation.forget_tab(scope(slot), tab)
    # A call after the cast is served after it.
    PreviewAutomation.tab_ownership(scope(slot), tab)
    :ok
  end

  defp scope(slot), do: %{thread_id: "th-#{slot}", instance: "codex"}
  defp fresh_tab(slot), do: "tab-new-#{slot}"

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
