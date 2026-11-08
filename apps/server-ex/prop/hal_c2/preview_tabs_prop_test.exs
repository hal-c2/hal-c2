defmodule HalC2.PreviewTabsPropTest do
  @moduledoc """
  `HalC2.Preview`'s tabs against a model of what they promise: a thread's tabs
  are listed exactly while open, closing a thread closes all of its tabs and
  no one else's, and a late success report for the page a failed navigation
  left never turns the failure back into a success, unless a new navigation has
  started since (a `Loading` report for another page than the failed one, or the MC's own navigate).

  Commands open tabs, report navigation outcomes (`Loading`, `Success` or
  `LoadFailed` at one of two pages), navigate from the MC, close one tab, close a whole thread, and restart the
  service.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Preview

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @threads ["th-a", "th-b"]
  @pages ["http://localhost:3000/", "http://localhost:3001/"]

  property "closing a thread closes its tabs, and a late report never undoes a failure",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("preview-tabs")
        HalC2.Prop.start_services([Preview])
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # tabs: slot => %{thread, status: {:loading | :ok | :failed, url}, left: url | nil}.
  # A slot numbers a tab so a command names it without its real id.
  def initial_state, do: %{next: 0, tabs: %{}}

  def command(state) do
    frequency(
      [
        {3, {:call, __MODULE__, :open_tab, [state.next, oneof(@threads), oneof(@pages)]}},
        {2, {:call, __MODULE__, :close_thread, [oneof(@threads)]}},
        {1, {:call, __MODULE__, :restart, []}}
      ] ++
        if(state.tabs == %{},
          do: [],
          else: [
            {6,
             {:call, __MODULE__, :report,
              [oneof(Map.keys(state.tabs)), oneof([:ok, :failed, :loading]), oneof(@pages)]}},
            {1, {:call, __MODULE__, :navigate, [oneof(Map.keys(state.tabs)), oneof(@pages)]}},
            {2, {:call, __MODULE__, :close_tab, [oneof(Map.keys(state.tabs))]}}
          ]
        )
    )
  end

  def precondition(state, {:call, _, :open_tab, [slot, _, _]}), do: slot == state.next
  def precondition(state, {:call, _, :report, [slot, _, _]}), do: is_map_key(state.tabs, slot)
  def precondition(state, {:call, _, :navigate, [slot, _]}), do: is_map_key(state.tabs, slot)
  def precondition(state, {:call, _, :close_tab, [slot]}), do: is_map_key(state.tabs, slot)
  def precondition(_, _), do: true

  def next_state(state, _, {:call, _, :open_tab, [slot, thread, page]}) do
    tab = %{thread: thread, status: {:loading, page}, left: nil}
    %{state | next: state.next + 1, tabs: Map.put(state.tabs, slot, tab)}
  end

  def next_state(state, _, {:call, _, :report, [slot, kind, page]}) do
    tab = state.tabs[slot]
    {_, current} = tab.status

    cond do
      # The failure's own page reporting in again.
      kind == :ok and elem(tab.status, 0) in [:failed, :loading] and tab.left == page ->
        state

      true ->
        left =
          cond do
            kind == :loading and elem(tab.status, 0) == :failed and current != page -> nil
            current != page -> current
            true -> tab.left
          end

        put_in(state.tabs[slot], %{tab | status: {kind, page}, left: left})
    end
  end

  def next_state(state, _, {:call, _, :navigate, [slot, page]}),
    do: put_in(state.tabs[slot], %{state.tabs[slot] | status: {:ok, page}, left: nil})

  def next_state(state, _, {:call, _, :close_tab, [slot]}),
    do: %{state | tabs: Map.delete(state.tabs, slot)}

  def next_state(state, _, {:call, _, :close_thread, [thread]}),
    do: %{state | tabs: Map.reject(state.tabs, fn {_, tab} -> tab.thread == thread end)}

  # The tabs live in memory: a restart forgets them all.
  def next_state(state, _, {:call, _, :restart, []}), do: %{state | tabs: %{}}

  # Checked against the state the command leads to.
  def postcondition(before, {:call, _, _, _} = call, result) do
    state = next_state(before, result, call)

    Enum.all?(@threads, fn thread ->
      expected =
        for({slot, tab} <- state.tabs, tab.thread == thread, do: {slot, tab.status})
        |> Enum.sort()

      listed(thread) == expected
    end)
  end

  # --- wrappers ---------------------------------------------------------------

  def open_tab(slot, thread, page) do
    {:ok, snapshot} = Preview.open(%{"threadId" => thread, "url" => page})
    Process.put({:tab, slot}, snapshot["tabId"])
    :ok
  end

  def report(slot, kind, page) do
    {thread, tab} = Process.get({:tab, slot}) |> then(&{thread_of(&1), &1})

    status =
      case kind do
        :ok -> %{"_tag" => "Success", "url" => page, "title" => ""}
        :failed -> %{"_tag" => "LoadFailed", "url" => page, "title" => "", "code" => -1}
        :loading -> %{"_tag" => "Loading", "url" => page, "title" => ""}
      end

    {:ok, _} =
      Preview.report_status(%{
        "threadId" => thread,
        "tabId" => tab,
        "navStatus" => status,
        "canGoBack" => false,
        "canGoForward" => false
      })

    :ok
  end

  def navigate(slot, page) do
    tab = Process.get({:tab, slot})
    {:ok, _} = Preview.navigate(%{"threadId" => thread_of(tab), "tabId" => tab, "url" => page})
    :ok
  end

  def close_tab(slot) do
    tab = Process.get({:tab, slot})
    {:ok, nil} = Preview.close(%{"threadId" => thread_of(tab), "tabId" => tab})
    :ok
  end

  def close_thread(thread), do: Preview.close_thread(thread)

  def restart, do: HalC2.Prop.restart_service(Preview)

  # The slots and statuses of a thread's tabs, as the model shows them.
  defp listed(thread) do
    {:ok, %{"sessions" => sessions}} = Preview.list(%{"threadId" => thread})

    for session <- sessions do
      slot = Enum.find_value(Process.get_keys(), &slot_of(&1, session["tabId"]))
      {slot, status(session["navStatus"])}
    end
    |> Enum.sort()
  end

  defp slot_of({:tab, slot} = key, id), do: if(Process.get(key) == id, do: slot)
  defp slot_of(_, _), do: nil

  defp status(%{"_tag" => "Loading", "url" => url}), do: {:loading, url}
  defp status(%{"_tag" => "Success", "url" => url}), do: {:ok, url}
  defp status(%{"_tag" => "LoadFailed", "url" => url}), do: {:failed, url}

  defp thread_of(tab) do
    Enum.find(@threads, fn thread ->
      {:ok, %{"sessions" => sessions}} = Preview.list(%{"threadId" => thread})
      Enum.any?(sessions, &(&1["tabId"] == tab))
    end)
  end
end
