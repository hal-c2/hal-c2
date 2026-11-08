defmodule HalC2.PreviewAutomationLimitsPropTest do
  @moduledoc """
  `HalC2.PreviewAutomation`'s tab limits against a model, with the limits
  lowered to 2 tabs a session and 4 across the MC: an open that makes a tab is
  refused once its session has 2 agent tabs (counting its opens still on their
  way), and at the MC's 4 it closes the agent tab idle longest, past 30
  minutes, that no host shows and no person uses, or is refused.

  Commands open a new tab in one of three sessions (each its own thread), open
  one whose load fails, race two opens of one session so the second is decided
  while the first is on its way, race them so the second fails before the
  first succeeds, click a tab (an action on an agent's tab resets its idle
  time), report which tabs the desktop shows and a person uses, make an agent
  tab 31 minutes idle, and close one as the user does. The test process is the
  desktop: it makes a `HalC2.Preview` tab for each open. After every command
  the agent tabs still open are the model's.

  A failed open closes only the tab it made, named in its error: never the
  tab of an open of the same session still on its way, nor one a person
  opened in the thread meanwhile.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.PreviewAutomation

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @slots [0, 1, 2]
  @limits [session: 2, mc: 4]
  @aged_ms 31 * 60_000

  property "agent tabs stay within the session and MC limits, reclaiming only idle hidden ones",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("preview-automation-limits")
        Application.put_env(:hal_c2, :preview_tab_limits, @limits)
        HalC2.Prop.start_services([HalC2.Preview, PreviewAutomation])

        {:ok, connection} =
          PreviewAutomation.connect(%{"clientId" => "desk", "environmentId" => "env"}, self())

        Process.put(:connection, connection)
        Process.put(:made, %{})
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :preview_tab_limits)
        flush()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # owners: the nth tab an open made ({:made, n}) => its session, while open;
  # used: when it was last opened or acted on (a clock); old: those made 31
  # minutes idle since; closed: those the user closed; shown and controlled: what the desktop last reported.
  def initial_state,
    do: %{
      made: 0,
      clock: 0,
      owners: %{},
      used: %{},
      old: MapSet.new(),
      closed: MapSet.new(),
      shown: [],
      controlled: []
    }

  def command(state) do
    frequency(
      [
        {5, {:call, __MODULE__, :open, [oneof(@slots), state.made]}},
        {2, {:call, __MODULE__, :failed, [oneof(@slots)]}},
        {2, {:call, __MODULE__, :race, [oneof(@slots), state.made]}},
        {2, {:call, __MODULE__, :race_fail, [oneof(@slots), state.made]}}
      ] ++
        if(state.made == 0,
          do: [],
          else: [
            {2, {:call, __MODULE__, :act, [oneof(@slots), made_tab(state)]}},
            {2, {:call, __MODULE__, :report, [list(made_tab(state)), list(made_tab(state))]}},
            {3, {:call, __MODULE__, :age, [made_tab(state)]}},
            {1, {:call, __MODULE__, :close, [made_tab(state)]}}
          ]
        )
    )
  end

  defp made_tab(state), do: let(n <- integer(0, state.made - 1), do: {:made, n})

  def precondition(state, {:call, _, :age, [tab]}),
    do: Map.has_key?(state.owners, tab) and not MapSet.member?(state.old, tab)

  def precondition(state, {:call, _, :close, [tab]}), do: Map.has_key?(state.owners, tab)

  # The broker forgets a closed tab's owner at the next open that makes one,
  # so until then a click on it is not modelled.
  def precondition(state, {:call, _, :act, [_slot, tab]}),
    do: not MapSet.member?(state.closed, tab)

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :open, [slot, _made]}),
    do: state |> opening(slot, 0) |> elem(1) |> made_if(room(state, slot, 0), slot)

  def next_state(state, _result, {:call, _, :failed, [slot]}),
    do: state |> opening(slot, 0) |> elem(1)

  def next_state(state, _result, {:call, _, :race, [slot, _made]}) do
    {first, state} = opening(state, slot, 0)
    {second, state} = opening(state, slot, if(sent?(first), do: 1, else: 0))
    state |> made_if(first, slot) |> made_if(second, slot)
  end

  # The second's reclaim (if any) stands although its load fails.
  def next_state(state, _result, {:call, _, :race_fail, [slot, _made]}) do
    {first, state} = opening(state, slot, 0)
    {_second, state} = opening(state, slot, if(sent?(first), do: 1, else: 0))
    made_if(state, first, slot)
  end

  def next_state(state, _result, {:call, _, :act, [slot, tab]}) do
    if expected_act(state, slot, tab) == :done and state.owners[tab] == slot,
      do: touch(state, tab),
      else: state
  end

  def next_state(state, _result, {:call, _, :report, [shown, controlled]}),
    do: %{state | shown: shown, controlled: controlled}

  def next_state(state, _result, {:call, _, :age, [tab]}),
    do: %{state | old: MapSet.put(state.old, tab)}

  def next_state(state, _result, {:call, _, :close, [tab]}),
    do: %{drop(state, tab) | closed: MapSet.put(state.closed, tab)}

  # What an open that makes a tab gets, with `pending` of its session's opens
  # on their way: `:ok`, `{:reclaim, tab}`, or `{:limit, within}`.
  defp room(state, slot, pending) do
    mine = Enum.count(state.owners, &(elem(&1, 1) == slot)) + pending

    cond do
      mine >= @limits[:session] -> {:limit, "session"}
      map_size(state.owners) + pending < @limits[:mc] -> :ok
      tab = idle(state) -> {:reclaim, tab}
      true -> {:limit, "mc"}
    end
  end

  # The open's outcome, and the state once any reclaimed tab is closed.
  defp opening(state, slot, pending) do
    case room(state, slot, pending) do
      {:reclaim, tab} -> {{:reclaim, tab}, drop(state, tab)}
      outcome -> {outcome, state}
    end
  end

  defp sent?({:limit, _}), do: false
  defp sent?(_), do: true

  defp made_if(state, outcome, slot) do
    if sent?(outcome) do
      tab = {:made, state.made}
      %{state | made: state.made + 1, owners: Map.put(state.owners, tab, slot)} |> touch(tab)
    else
      state
    end
  end

  defp idle(state) do
    state.old
    |> Enum.reject(&(&1 in state.shown or &1 in state.controlled))
    |> Enum.min_by(&state.used[&1], fn -> nil end)
  end

  defp touch(state, tab),
    do: %{
      state
      | clock: state.clock + 1,
        used: Map.put(state.used, tab, state.clock),
        old: MapSet.delete(state.old, tab)
    }

  defp drop(state, tab),
    do: %{
      state
      | owners: Map.delete(state.owners, tab),
        used: Map.delete(state.used, tab),
        old: MapSet.delete(state.old, tab)
    }

  # A click goes ahead on the session's own tab, or one no agent has that no
  # person uses.
  defp expected_act(state, slot, tab) do
    case state.owners[tab] do
      ^slot -> :done
      nil -> if tab in state.controlled, do: "PreviewAutomationTabInUseError", else: :done
      _ -> "PreviewAutomationTabOtherAgentError"
    end
  end

  defp outcome({:limit, within}), do: {:limit, within}
  defp outcome(_), do: :sent

  def postcondition(state, {:call, _, :open, [slot, _]}, {result, live}),
    do: result == outcome(room(state, slot, 0)) and live == expected_live(state, :open, slot)

  def postcondition(state, {:call, _, :failed, [slot]}, {result, live}),
    do: result == outcome(room(state, slot, 0)) and live == expected_live(state, :failed, slot)

  def postcondition(state, {:call, _, :race, [slot, _]}, {first, second, live}) do
    {o1, after_first} = opening(state, slot, 0)
    {o2, _} = opening(after_first, slot, if(sent?(o1), do: 1, else: 0))

    {first, second} == {outcome(o1), outcome(o2)} and
      live == expected_live(state, :race, slot)
  end

  def postcondition(state, {:call, _, :race_fail, [slot, _]}, {first, second, live, person}) do
    {o1, after_first} = opening(state, slot, 0)
    {o2, _} = opening(after_first, slot, if(sent?(o1), do: 1, else: 0))

    {first, second} == {outcome(o1), outcome(o2)} and person == :kept and
      live == expected_live(state, :race_fail, slot)
  end

  def postcondition(state, {:call, _, :act, [slot, tab]}, result),
    do: result == expected_act(state, slot, tab)

  def postcondition(state, {:call, _, :close, [tab]}, live),
    do: live == expected_live(state, :close, tab)

  def postcondition(_state, _call, _result), do: true

  defp expected_live(state, :open, slot),
    do: next_state(state, nil, {:call, __MODULE__, :open, [slot, 0]}) |> live_tabs()

  defp expected_live(state, :failed, slot),
    do: next_state(state, nil, {:call, __MODULE__, :failed, [slot]}) |> live_tabs()

  defp expected_live(state, :race, slot),
    do: next_state(state, nil, {:call, __MODULE__, :race, [slot, 0]}) |> live_tabs()

  defp expected_live(state, :race_fail, slot),
    do: next_state(state, nil, {:call, __MODULE__, :race_fail, [slot, 0]}) |> live_tabs()

  defp expected_live(state, :close, tab), do: state |> drop(tab) |> live_tabs()

  defp live_tabs(state), do: state.owners |> Map.keys() |> Enum.sort()

  # --- calls -----------------------------------------------------------------

  # A new-tab open in session `slot`: `:sent` or `{:limit, within}`, and the
  # made tabs still open.
  def open(slot, made) do
    result =
      case send_open(slot) do
        {:sent, task, request} -> answer(slot, task, request, made, :ok)
        refused -> refused
      end

    {result, live()}
  end

  # A new-tab open whose load fails once the desktop made its tab.
  def failed(slot) do
    result =
      case send_open(slot) do
        {:sent, task, request} -> answer(slot, task, request, nil, :error)
        refused -> refused
      end

    {result, live()}
  end

  # Two new-tab opens of session `slot`, the second decided while the first is
  # on its way; then the desktop answers them in order.
  def race(slot, made) do
    first = send_open(slot)
    second = send_open(slot)

    {results, _} =
      Enum.map_reduce([first, second], made, fn
        {:sent, task, request}, n -> {answer(slot, task, request, n, :ok), n + 1}
        refused, n -> {refused, n}
      end)

    [a, b] = results
    {a, b, live()}
  end

  # Two new-tab opens of session `slot`, the second decided while the first
  # is on its way. The desktop makes both tabs, a person opens one in the
  # thread, and the second's load fails before the first is answered. The
  # outcomes, the made tabs still open, and whether the person's tab is.
  def race_fail(slot, made) do
    first = send_open(slot)
    second = send_open(slot)
    thread = scope(slot).thread_id
    mine = if match?({:sent, _, _}, first), do: new_tab(thread)
    theirs = if match?({:sent, _, _}, second), do: new_tab(thread)
    person = new_tab(thread)

    b =
      case second do
        {:sent, task, request} ->
          error = %{"_tag" => "PreviewAutomationNavigationError", "tabId" => theirs}
          respond(request, false, error)
          {:error, _} = Task.await(task)
          :sent

        refused ->
          refused
      end

    a =
      case first do
        {:sent, task, request} ->
          Process.put(:made, Map.put(Process.get(:made), made, {thread, mine}))
          respond(request, true, %{"tabId" => mine})
          {:ok, _} = Task.await(task)
          :sent

        refused ->
          refused
      end

    kept = if(open?(thread, person), do: :kept, else: :closed)
    {:ok, _} = HalC2.Preview.close(%{"threadId" => thread, "tabId" => person})
    {a, b, live(), kept}
  end

  defp new_tab(thread) do
    {:ok, %{"tabId" => tab}} = HalC2.Preview.open(%{"threadId" => thread})
    tab
  end

  def act(slot, tab) do
    # The process dictionary holds the made tabs, so resolve before the task.
    opts = [tab_id: real(tab)]
    task = Task.async(fn -> PreviewAutomation.invoke(scope(slot), "click", %{}, opts) end)

    receive do
      {:hal_c2_preview_automation, _, "desk", %{"type" => "request", "request" => request}} ->
        respond(request, true, %{"tabId" => request["tabId"]})
        {:ok, _} = Task.await(task)
        :done

      {ref, {:error, %{"_tag" => tag}}} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        tag
    end
  end

  def report(shown, controlled) do
    PreviewAutomation.focus_host(%{
      "clientId" => "desk",
      "environmentId" => "env",
      "connectionId" => Process.get(:connection),
      "focused" => true,
      "visibleTabIds" => shown |> Enum.map(&real/1) |> Enum.uniq(),
      "controlledTabIds" => controlled |> Enum.map(&real/1) |> Enum.uniq()
    })

    # A call after the cast is served after it.
    PreviewAutomation.tab_ownership(scope(0), nil)
    :ok
  end

  # The tab, last used 31 minutes and more ago.
  def age(tab) do
    id = real(tab)

    :sys.replace_state(PreviewAutomation, fn state ->
      update_in(state, [:used, id], fn {at, n} -> {at - @aged_ms, n} end)
    end)

    :ok
  end

  def close(tab) do
    {thread, _} = Process.get(:made)[tab_index(tab)]
    {:ok, _} = HalC2.Preview.close(%{"threadId" => thread, "tabId" => real(tab)})
    live()
  end

  defp send_open(slot) do
    input = %{"reuseExistingTab" => false}
    task = Task.async(fn -> PreviewAutomation.invoke(scope(slot), "open", input, []) end)

    receive do
      {:hal_c2_preview_automation, _, "desk", %{"type" => "request", "request" => request}} ->
        {:sent, task, request}

      {ref, {:error, %{"_tag" => "PreviewAutomationTabLimitError", "within" => within}}}
      when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        {:limit, within}
    end
  end

  # The desktop makes the open's tab, as the nth made (unless it fails), and
  # answers.
  defp answer(slot, task, request, made, outcome) do
    thread = scope(slot).thread_id
    {:ok, %{"tabId" => tab}} = HalC2.Preview.open(%{"threadId" => thread})

    case outcome do
      :ok ->
        Process.put(:made, Map.put(Process.get(:made), made, {thread, tab}))
        respond(request, true, %{"tabId" => tab})
        {:ok, _} = Task.await(task)

      :error ->
        respond(request, false, %{"_tag" => "PreviewAutomationNavigationError", "tabId" => tab})
        {:error, _} = Task.await(task)
    end

    :sent
  end

  defp respond(request, ok, payload) do
    PreviewAutomation.respond(
      Map.merge(
        %{
          "clientId" => "desk",
          "connectionId" => Process.get(:connection),
          "requestId" => request["requestId"],
          "ok" => ok
        },
        if(ok, do: %{"result" => payload}, else: %{"error" => payload})
      )
    )
  end

  # The made tabs still open, by their place in the order they were made.
  defp live do
    Enum.sort(for {n, {thread, tab}} <- Process.get(:made), open?(thread, tab), do: {:made, n})
  end

  defp open?(thread, tab) do
    {:ok, %{"sessions" => sessions}} = HalC2.Preview.list(%{"threadId" => thread})
    Enum.any?(sessions, &(&1["tabId"] == tab))
  end

  defp scope(slot), do: %{thread_id: "th-#{slot}", instance: "codex"}
  defp tab_index({:made, n}), do: n
  defp real({:made, n}), do: elem(Process.get(:made)[n], 1)

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
