defmodule HalC2.PreviewAutomation do
  @moduledoc """
  Routes agents' browser actions (`preview_*` MCP tools) to a desktop client's
  browser panel.

  A desktop registers as a host with the `previewAutomation` shape (`connect/2`),
  which streams it requests; it answers each with `previewAutomation.respond`
  (`respond/1`) and says when its window has focus and which tabs it is showing
  or has live pages for (`focus_host/1`). An agent's call (`invoke/4`) goes to
  the host its provider session last used, so a multi-step interaction stays in
  one browser, or else to the host showing — failing that, with a live page
  for — the tab asked about, then the most capable, focused, most recently
  focused host. A host that holds only a browser snapshot is never offered to
  a new session. The tab a session last touched is its current tab; a status
  or snapshot with neither reads the thread's tab its host is showing.

  Hosts also report the tabs a person is using and their browser profiles. A
  session changes a tab only if it opened it, or no agent did and no person is
  using it; reads always go ahead. An open naming no tab reuses the session's
  current tab, or opens a new one when it has none or may not change it; any
  other change naming no tab needs a current tab, since a desktop would fill
  the gap with its own current tab of the thread, which may be another
  session's or the person's. An open names a profile by name or id,
  matched across every host's profiles and sent to a host that has it; without
  one the new tab opens in the host's default profile.

  A tab an agent session's `open` created is that session's to close
  (`tab_ownership/2`): one that was not in `HalC2.Preview` before the open and
  is there after it, since a desktop makes new tabs with `preview.open`. An open
  that reused a tab (the one asked for, or the session's current tab) claims
  nothing. Ownership is keyed by tab, so it outlives the host reconnecting or
  being dropped, and lives in memory like the tabs themselves: an MC restart
  forgets both.

  An agent session keeps at most 8 tabs of its own open, and agents 32 across
  the MC, counting opens on their way. At the MC's limit an open closes the
  agent tab idle longest, if one has gone 30 minutes without an action and no
  host shows it or reports a person using it; otherwise the open is refused.
  The limits are `config :hal_c2, :preview_tab_limits` (`session`, `mc`,
  `idle_ms`).

  A request unanswered within its timeout drops that host's connection, whose
  stream then ends so the desktop registers again; actions are never replayed.
  A host that registers again under the same client id replaces its old
  connection, which just stops getting requests.
  """

  use GenServer

  @v1_operations ~w(status open navigate snapshot click type press scroll evaluate waitFor recordingStart recordingStop)
  @default_timeout 15_000
  @tab_limits %{session: 8, mc: 32, idle_ms: 30 * 60_000}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Registers `pid` (a socket) as the host `host` (`PreviewAutomationHost`). It gets
  `{:hal_c2_preview_automation, mc, client_id, event | :end}`, the first event being
  `connected`.
  """
  def connect(host, pid), do: GenServer.call(__MODULE__, {:connect, host, pid})

  @doc "Drops `pid`'s registration as `client_id`, as when its stream closes."
  def disconnect(client_id, pid), do: GenServer.cast(__MODULE__, {:disconnect, client_id, pid})

  def focus_host(host), do: GenServer.cast(__MODULE__, {:focus, host})
  def respond(response), do: GenServer.cast(__MODULE__, {:respond, response})

  @doc """
  Who opened `tab_id` through an agent's `open`: `:own` (this scope),
  `:other_agent` (another scope), or `:not_agent` (no agent did — the user's
  tab, or one no host ever reported opening).
  """
  def tab_ownership(scope, tab_id) do
    GenServer.call(__MODULE__, {:tab_ownership, scope, tab_id})
  catch
    :exit, {:noproc, _} -> :not_agent
  end

  @doc """
  For each of `tabs`, as `scope` sees it: `owner` (as `tab_ownership/2`),
  `in_use` (`"person"` when a host reports a person using it, `"agent"` while
  an agent's action on it runs, else nil) and `shown` (a host shows it).
  """
  def tab_states(scope, tabs) do
    GenServer.call(__MODULE__, {:tab_states, scope, tabs})
  catch
    :exit, {:noproc, _} -> Map.new(tabs, &{&1, %{owner: :not_agent, in_use: nil, shown: false}})
  end

  @doc "Forgets that `scope` opened `tab_id`, as when it closed the tab."
  def forget_tab(scope, tab_id), do: GenServer.cast(__MODULE__, {:forget_tab, scope, tab_id})

  @doc """
  Runs `operation` for the agent of `scope` (`%{thread_id, instance}`) on a host:
  `{:ok, result}` or `{:error, %{"_tag" => tag, ...}}`. Options: `:tab_id` (an
  explicit tab), `:timeout_ms`, and `update_current_tab: false` for background
  reads that must not move the session's current tab.
  """
  def invoke(scope, operation, input, opts \\ []) do
    timeout = opts[:timeout_ms] || @default_timeout
    GenServer.call(__MODULE__, {:invoke, scope, operation, input, opts}, timeout + 5_000)
  catch
    :exit, {:noproc, _} -> {:error, no_host(scope, operation)}
  end

  @doc "An error's message for an agent."
  def message(%{"_tag" => tag} = error) do
    op = error["operation"]
    client = error["clientId"]

    case tag do
      "PreviewAutomationNoAvailableHostError" ->
        "No preview automation host is available for #{op}. Open HAL-C2's desktop app with this thread's browser panel available."

      "PreviewAutomationUnsupportedClientError" ->
        "Preview automation client #{client} does not support #{op}."

      "PreviewAutomationTabOtherAgentError" ->
        "Preview tab #{error["tabId"]} belongs to another agent session; open your own tab with preview_open."

      "PreviewAutomationTabInUseError" ->
        "A person is in control of preview tab #{error["tabId"]}; wait until they stop, or open your own tab with preview_open."

      "PreviewAutomationUnknownProfileError" ->
        case error["profiles"] do
          [] ->
            "There is no browser profile named \"#{error["profile"]}\": no desktop reports its browser profiles."

          names ->
            "There is no browser profile named \"#{error["profile"]}\". Use one of: #{Enum.join(names, ", ")}."
        end

      "PreviewAutomationTabLimitError" ->
        if error["within"] == "session",
          do:
            "This agent session already has #{error["limit"]} preview tabs open; close one with preview_close before opening another.",
          else:
            "#{error["limit"]} agent preview tabs are open across HAL-C2; close one with preview_close before opening another."

      "PreviewAutomationTabNotFoundError" ->
        if error["tabId"],
          do: "Preview tab #{error["tabId"]} was not found for #{op}.",
          else: "No active preview tab was found for #{op}."

      "PreviewAutomationTimeoutError" ->
        "Preview automation #{op} timed out after #{error["timeoutMs"]}ms."

      "PreviewAutomationNavigationTimeoutError" ->
        "Preview automation navigation timed out after #{error["timeoutMs"]}ms."

      "PreviewAutomationClientDisconnectedError" ->
        "Preview automation client #{client} disconnected during #{op}."

      "PreviewAutomationMalformedResponseError" ->
        "Preview automation client #{client} returned a malformed response for #{op}."

      "PreviewAutomationRecordingTooLargeError" ->
        "The recording exceeds 50 MiB. The saved copy remains on the desktop."

      "PreviewAutomationRecordingDeadlineExpiredError" ->
        "The recording transfer deadline expired. The saved copy remains on the desktop."

      _ ->
        error["remoteMessage"] || "Preview automation #{op} failed on client #{client}."
    end
  end

  # --- server --------------------------------------------------------------------

  @impl true
  def init(nil) do
    {:ok,
     %{
       clients: %{},
       assignments: %{},
       owners: %{},
       used: %{},
       pending: %{},
       seq: 0,
       focus_seq: 0
     }}
  end

  # An older broker kept the tabs a session opened on its assignment.
  @impl true
  def code_change(_old_vsn, state, _extra) do
    owners =
      for {key, %{opened: opened}} <- state.assignments, tab <- opened, into: %{}, do: {tab, key}

    assignments = Map.new(state.assignments, fn {key, a} -> {key, Map.delete(a, :opened)} end)

    {:ok,
     %{state | assignments: assignments}
     |> Map.update(:owners, owners, &Map.merge(owners, &1))
     |> Map.put_new(:used, %{})}
  end

  @impl true
  def handle_call({:connect, host, pid}, _from, state) do
    client_id = host["clientId"]
    state = drop_connection(state, client_id, :replaced)
    connection_id = HalC2.Environment.uuid4()
    focus_seq = state.focus_seq + 1

    client = %{
      connection_id: connection_id,
      pid: pid,
      monitor: Process.monitor(pid),
      operations: MapSet.new(host["supportedOperations"] || @v1_operations),
      focused: false,
      focus_order: focus_seq,
      visible_tabs: MapSet.new(host["visibleTabIds"] || []),
      live_tabs: MapSet.new(host["liveTabIds"] || []),
      snapshot_only: host["snapshotOnly"] == true,
      controlled_tabs: MapSet.new(host["controlledTabIds"] || []),
      profiles: profiles(host["browserProfiles"]) || [],
      default_profile: host["defaultBrowserProfileId"]
    }

    send(pid, {:hal_c2_preview_automation, node(), client_id, connected(connection_id)})

    {:reply, {:ok, connection_id},
     %{state | clients: Map.put(state.clients, client_id, client), focus_seq: focus_seq}}
  end

  def handle_call({:invoke, scope, operation, input, opts}, from, state) do
    key = {scope.thread_id, scope.instance}
    assigned = live_assignment(state, key)

    current =
      case assigned do
        {_, _, %{tab_id: tab}} -> tab
        _ -> nil
      end

    input = own_open(state, key, operation, opts[:tab_id], current, input)
    acts_on = if makes_tab?(operation, input), do: nil, else: opts[:tab_id] || current

    with :ok <- may_act(state, key, operation, acts_on),
         {:ok, input, profile} <- named_profile(state, scope, operation, input) do
      dispatch(state, scope, {key, assigned, current}, operation, input, profile, opts, from)
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:tab_states, scope, tabs}, _from, state) do
    key = {scope.thread_id, scope.instance}
    clients = Map.values(state.clients)
    running = MapSet.new(Map.values(state.pending), &pending_tab(state, &1))
    running = MapSet.delete(running, nil)

    states =
      Map.new(tabs, fn tab ->
        in_use =
          cond do
            Enum.any?(clients, &MapSet.member?(tab_set(&1, :controlled_tabs), tab)) -> "person"
            MapSet.member?(running, tab) -> "agent"
            true -> nil
          end

        {tab,
         %{
           owner: ownership(state, key, tab),
           in_use: in_use,
           shown: Enum.any?(clients, &MapSet.member?(tab_set(&1, :visible_tabs), tab))
         }}
      end)

    {:reply, states, state}
  end

  def handle_call({:tab_ownership, scope, tab_id}, _from, state),
    do: {:reply, ownership(state, {scope.thread_id, scope.instance}, tab_id), state}

  defp dispatch(state, scope, {key, assigned, tab}, operation, input, profile, opts, from) do
    host =
      case assigned do
        {client_id, client, _tab} ->
          cond do
            not MapSet.member?(client.operations, operation) -> nil
            offers?(client, profile) -> {client_id, client}
            true -> route(state, operation, profile, opts)
          end

        nil ->
          route(state, operation, profile, opts)
      end

    makes_tab = makes_tab?(operation, input)

    room =
      cond do
        host == nil ->
          nil

        tabless_change?(operation, opts[:tab_id] || tab) ->
          {:error, tab_not_found(scope, operation)}

        true ->
          tab_room(state, key, operation, makes_tab)
      end

    case room do
      nil ->
        {:reply, {:error, no_host(scope, operation)},
         %{
           state
           | assignments:
               if(assigned, do: state.assignments, else: Map.delete(state.assignments, key))
         }}

      {:error, error} ->
        {:reply, {:error, error}, state}

      {:ok, state} ->
        {client_id, client} = host
        timeout = opts[:timeout_ms] || @default_timeout
        request_id = "preview-#{state.seq}"
        # An open making a tab names none, so nothing reads it as on another tab.
        tab_id =
          if makes_tab,
            do: nil,
            else: opts[:tab_id] || tab || shown_tab(client, scope.thread_id, operation)

        input = with_default_profile(input, client, operation, profile)

        context =
          %{
            "operation" => operation,
            "threadId" => scope.thread_id,
            "providerInstanceId" => scope.instance,
            "clientId" => client_id,
            "connectionId" => client.connection_id,
            "requestId" => request_id,
            "timeoutMs" => timeout
          }
          |> put_present("tabId", tab_id)

        request =
          %{
            "requestId" => request_id,
            "threadId" => scope.thread_id,
            "tabIdExplicit" => opts[:tab_id] != nil,
            "operation" => operation,
            "input" => input,
            "timeoutMs" => timeout
          }
          |> put_present("tabId", tab_id)

        # Read before the request goes, so "before" cannot include the tab it makes.
        tabs_before = if operation == "open", do: thread_tabs(scope.thread_id)

        send(
          client.pid,
          {:hal_c2_preview_automation, node(), client_id,
           %{"type" => "request", "connectionId" => client.connection_id, "request" => request}}
        )

        pending = %{
          from: from,
          client_id: client_id,
          connection_id: client.connection_id,
          context: context,
          key: key,
          seq: state.seq,
          explicit_tab: opts[:tab_id],
          tab: tab_id,
          tabs_before: tabs_before,
          makes_tab: makes_tab,
          update_tab: Keyword.get(opts, :update_current_tab, true),
          timer: Process.send_after(self(), {:timeout, request_id}, timeout)
        }

        assignment = %{
          client_id: client_id,
          connection_id: client.connection_id,
          tab_id: tab,
          tab_seq: (assigned && elem(assigned, 2)[:tab_seq]) || -1
        }

        {:noreply,
         %{
           state
           | pending: Map.put(state.pending, request_id, pending),
             assignments: Map.put(state.assignments, key, assignment),
             seq: state.seq + 1
         }
         |> then(&if(makes_tab, do: &1, else: touch(&1, tab_id)))}
    end
  end

  @impl true
  def handle_cast({:forget_tab, scope, tab_id}, state) do
    if state.owners[tab_id] == {scope.thread_id, scope.instance},
      do: {:noreply, drop_owned(state, [tab_id])},
      else: {:noreply, state}
  end

  def handle_cast({:disconnect, client_id, pid}, state) do
    case state.clients[client_id] do
      %{pid: ^pid} -> {:noreply, drop_connection(state, client_id, :closed)}
      _ -> {:noreply, state}
    end
  end

  def handle_cast({:focus, %{"connectionId" => connection_id} = host}, state) do
    case state.clients[host["clientId"]] do
      %{connection_id: ^connection_id} = client ->
        focused = host["focused"] == true
        focus_seq = if focused, do: state.focus_seq + 1, else: state.focus_seq

        client = %{
          client
          | focused: focused,
            focus_order: if(focused, do: focus_seq, else: client.focus_order),
            visible_tabs: reported(host, "visibleTabIds", Map.get(client, :visible_tabs)),
            live_tabs: reported(host, "liveTabIds", Map.get(client, :live_tabs)),
            controlled_tabs:
              reported(host, "controlledTabIds", Map.get(client, :controlled_tabs)),
            profiles: profiles(host["browserProfiles"]) || Map.get(client, :profiles, []),
            default_profile:
              Map.get(host, "defaultBrowserProfileId", Map.get(client, :default_profile)),
            snapshot_only:
              if(is_boolean(host["snapshotOnly"]),
                do: host["snapshotOnly"],
                else: Map.get(client, :snapshot_only, false)
              )
        }

        {:noreply,
         %{
           state
           | clients: Map.put(state.clients, host["clientId"], client),
             focus_seq: focus_seq
         }}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:respond, response}, state) do
    %{"clientId" => client_id, "connectionId" => connection_id} = response

    case Map.pop(state.pending, response["requestId"]) do
      {%{client_id: ^client_id, connection_id: ^connection_id} = pending, rest} ->
        Process.cancel_timer(pending.timer)
        state = %{state | pending: rest}

        if response["ok"] == true do
          result = response["result"]
          GenServer.reply(pending.from, {:ok, result})
          {:noreply, state |> track_tab(pending, result) |> claim_tab(pending, result)}
        else
          # Closed before the reply, so the caller never sees the tab.
          state = discard_failed_open(state, pending, response["error"])

          GenServer.reply(
            pending.from,
            {:error, remote_error(pending.context, response["error"])}
          )

          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:timeout, request_id}, state) do
    case state.pending[request_id] do
      nil ->
        {:noreply, state}

      pending ->
        GenServer.reply(
          pending.from,
          {:error, tagged("PreviewAutomationTimeoutError", pending.context)}
        )

        state = %{state | pending: Map.delete(state.pending, request_id)}
        # The host may have applied the action before going quiet, so it is not retried.
        {:noreply, drop_connection(state, pending.client_id, :evicted)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.clients, fn {_id, client} -> client.pid == pid end) do
      {client_id, _} -> {:noreply, drop_connection(state, client_id, :closed)}
      nil -> {:noreply, state}
    end
  end

  # --- helpers ---------------------------------------------------------------------

  defp connected(connection_id), do: %{"type" => "connected", "connectionId" => connection_id}

  # Removes a host's connection: its session assignments go, its unanswered requests
  # fail, and an evicted host's stream ends so it registers again.
  defp drop_connection(state, client_id, how) do
    case Map.pop(state.clients, client_id) do
      {nil, _} ->
        state

      {client, clients} ->
        Process.demonitor(client.monitor, [:flush])

        if how == :evicted,
          do: send(client.pid, {:hal_c2_preview_automation, node(), client_id, :end})

        {gone, pending} =
          Enum.split_with(state.pending, fn {_id, p} ->
            p.connection_id == client.connection_id
          end)

        for {_id, p} <- gone do
          Process.cancel_timer(p.timer)

          GenServer.reply(
            p.from,
            {:error, tagged("PreviewAutomationClientDisconnectedError", p.context)}
          )
        end

        assignments =
          Map.reject(state.assignments, fn {_key, a} ->
            a.connection_id == client.connection_id
          end)

        %{state | clients: clients, pending: Map.new(pending), assignments: assignments}
    end
  end

  defp live_assignment(state, key) do
    with %{client_id: client_id, connection_id: connection_id} = assignment <-
           state.assignments[key],
         %{connection_id: ^connection_id} = client <- state.clients[client_id] do
      {client_id, client, assignment}
    else
      _ -> nil
    end
  end

  # The host a session with no live assignment goes to: one that can do
  # `operation` and has the named profile, never a snapshot-only one, best
  # serving the tab asked about, then the most capable, focused, latest.
  defp route(state, operation, profile, opts) do
    state.clients
    |> Enum.filter(fn {_id, client} ->
      MapSet.member?(client.operations, operation) and
        Map.get(client, :snapshot_only) != true and offers?(client, profile)
    end)
    |> Enum.max_by(
      fn {_id, c} ->
        {tab_tier(c, opts[:tab_id]), MapSet.size(c.operations), c.focused, c.focus_order}
      end,
      fn -> nil end
    )
  end

  defp offers?(_client, nil), do: true

  defp offers?(client, profile),
    do: Enum.any?(Map.get(client, :profiles, []), &(&1["id"] == profile))

  # Changing a tab is refused when another agent session opened it, or when it
  # is not this session's and a person is using it. Reads always go ahead.
  @reads ~w(status snapshot waitFor recordingStart recordingStop)

  defp may_act(_state, _key, operation, _tab) when operation in @reads, do: :ok
  defp may_act(_state, _key, _operation, nil), do: :ok

  defp may_act(state, {thread, instance} = key, operation, tab) do
    fields = %{
      "operation" => operation,
      "threadId" => thread,
      "providerInstanceId" => instance,
      "tabId" => tab
    }

    case ownership(state, key, tab) do
      :own ->
        :ok

      :other_agent ->
        {:error, tagged("PreviewAutomationTabOtherAgentError", fields)}

      :not_agent ->
        if Enum.any?(
             Map.values(state.clients),
             &MapSet.member?(tab_set(&1, :controlled_tabs), tab)
           ),
           do: {:error, tagged("PreviewAutomationTabInUseError", fields)},
           else: :ok
    end
  end

  # An open naming no tab reuses the session's current tab. With none, or one
  # it may not change (a read made it current), it opens a new tab rather than
  # letting the desktop reuse its own current tab or being refused.
  defp own_open(state, key, "open", nil, current, input) do
    if is_binary(current) and may_act(state, key, "open", current) == :ok,
      do: input,
      else: Map.put(input, "reuseExistingTab", false)
  end

  defp own_open(_state, _key, _operation, _tab, _current, input), do: input

  # A change other than an open, naming no tab with no current tab: a desktop
  # would fill the gap with its own current tab of the thread, which may be
  # another session's or the person's, so it is refused instead.
  defp tabless_change?(operation, nil), do: operation not in ["open" | @reads]
  defp tabless_change?(_operation, _tab), do: false

  defp tab_not_found(scope, operation),
    do:
      tagged("PreviewAutomationTabNotFoundError", %{
        "operation" => operation,
        "threadId" => scope.thread_id,
        "providerInstanceId" => scope.instance
      })

  defp ownership(state, key, tab) do
    case state.owners[tab] do
      nil -> :not_agent
      ^key -> :own
      _ -> :other_agent
    end
  end

  # An open naming a browser profile, by id or name in any case, among those
  # the hosts report: the input carries its id. Any other is refused.
  defp named_profile(state, scope, "open", %{"profile" => name} = input) when is_binary(name) do
    profiles =
      state.clients
      |> Map.values()
      |> Enum.flat_map(&Map.get(&1, :profiles, []))
      |> Enum.uniq_by(& &1["id"])

    wanted = String.downcase(name)

    case Enum.find(profiles, &(String.downcase(&1["id"]) == wanted)) ||
           Enum.find(profiles, &(String.downcase(&1["name"]) == wanted)) do
      %{"id" => id} ->
        {:ok, input |> Map.delete("profile") |> Map.put("profileId", id), id}

      nil ->
        {:error,
         tagged("PreviewAutomationUnknownProfileError", %{
           "operation" => "open",
           "threadId" => scope.thread_id,
           "providerInstanceId" => scope.instance,
           "profile" => name,
           "profiles" => Enum.map(profiles, & &1["name"])
         })}
    end
  end

  defp named_profile(_state, _scope, _operation, input),
    do: {:ok, Map.delete(input, "profile"), nil}

  # An open naming no profile opens a new tab in the host's default one.
  defp with_default_profile(input, client, "open", nil) do
    case Map.get(client, :default_profile) do
      nil -> input
      id -> Map.put(input, "profileId", id)
    end
  end

  defp with_default_profile(input, _client, _operation, _profile), do: input

  # A read with no tab of its own reads the thread's tab the host is showing.
  defp shown_tab(client, thread, operation) when operation in ~w(status snapshot) do
    visible = tab_set(client, :visible_tabs)

    with false <- MapSet.size(visible) == 0,
         {:ok, tabs} <- thread_tabs(thread) do
      visible |> MapSet.intersection(tabs) |> Enum.min(fn -> nil end)
    else
      _ -> nil
    end
  end

  defp shown_tab(_client, _thread, _operation), do: nil

  # The tab a running request acts on; none for an open making a new tab.
  defp pending_tab(_state, %{makes_tab: true}), do: nil

  defp pending_tab(state, pending),
    do: Map.get(pending, :tab) || get_in(state.assignments, [pending.key, :tab_id])

  # A host's tab set, empty for one registered by older code.
  defp tab_set(client, key), do: Map.get(client, key) || MapSet.new()

  # The tab a result names (or the explicit tab) becomes the session's current tab,
  # unless a later request already moved it.
  defp track_tab(state, %{update_tab: false}, _result), do: state

  defp track_tab(state, pending, result) do
    tab =
      case result do
        %{"tabId" => tab} -> {:ok, tab}
        _ when pending.explicit_tab != nil -> {:ok, pending.explicit_tab}
        _ -> :none
      end

    connection_id = pending.connection_id

    with {:ok, tab} <- tab,
         %{connection_id: ^connection_id, tab_seq: seq} = assignment when seq <= pending.seq <-
           state.assignments[pending.key] do
      assignment = %{assignment | tab_id: tab, tab_seq: pending.seq}
      %{state | assignments: Map.put(state.assignments, pending.key, assignment)}
    else
      _ -> state
    end
  end

  # An `open` claims its tab only when it created it: absent from the thread's
  # tabs before, present after. Reusing a tab someone else opened never makes
  # it the agent's to close. An open naming no tab always names the session's
  # own current tab or asks for a new one, so no second open is served on the
  # tab another made; should one be, the first claim keeps it. The thread's
  # owners of tabs since closed go too. Without a tab list, nothing changes.
  defp claim_tab(state, %{tabs_before: {:ok, before}} = pending, %{"tabId" => tab})
       when is_binary(tab) do
    {thread, _instance} = pending.key

    case thread_tabs(thread) do
      {:ok, now} ->
        owners =
          Map.reject(state.owners, fn {t, {th, _}} ->
            th == thread and not MapSet.member?(now, t)
          end)

        claimed = MapSet.member?(now, tab) and not MapSet.member?(before, tab)
        owners = if claimed, do: Map.put_new(owners, tab, pending.key), else: owners
        state = %{state | owners: owners}
        if claimed and owners[tab] == pending.key, do: touch(state, tab), else: state

      :error ->
        state
    end
  end

  defp claim_tab(state, _pending, _result), do: state

  # An open makes a tab exactly when it asks not to reuse one, as the desktop
  # decides; one naming no tab with no current tab to reuse has asked so
  # (`own_open/6`).
  defp makes_tab?("open", input), do: input["reuseExistingTab"] == false
  defp makes_tab?(_operation, _input), do: false

  # Whether an open that makes a tab fits the limits, counting the agent tabs
  # still open and the opens on their way: `{:ok, state}`, having closed an
  # idle tab to make room at the MC's limit, or the refusal.
  defp tab_room(state, _key, _operation, false), do: {:ok, state}

  defp tab_room(state, {thread, instance} = key, operation, true) do
    limits = tab_limits()
    state = prune_owners(state)
    making = for {_, %{makes_tab: true} = p} <- state.pending, do: p.key
    mine = Enum.count(state.owners, &(elem(&1, 1) == key)) + Enum.count(making, &(&1 == key))

    fields = %{"operation" => operation, "threadId" => thread, "providerInstanceId" => instance}

    cond do
      mine >= limits.session ->
        {:error, tagged("PreviewAutomationTabLimitError", tab_limit(fields, "session", limits))}

      map_size(state.owners) + length(making) < limits.mc ->
        {:ok, state}

      # A tab that would not close still counts, so the open is refused.
      (idle = idle_tab(state, limits.idle_ms)) && closed?(state.owners[idle], idle) ->
        {:ok, drop_owned(state, [idle])}

      true ->
        {:error, tagged("PreviewAutomationTabLimitError", tab_limit(fields, "mc", limits))}
    end
  end

  defp closed?({thread, _instance}, tab) do
    match?({:ok, _}, HalC2.Preview.close(%{"threadId" => thread, "tabId" => tab}))
  catch
    :exit, _ -> false
  end

  defp tab_limit(fields, within, limits),
    do:
      Map.merge(fields, %{
        "within" => within,
        "limit" => Map.fetch!(limits, String.to_atom(within))
      })

  defp tab_limits,
    do: Map.merge(@tab_limits, Map.new(Application.get_env(:hal_c2, :preview_tab_limits, [])))

  # Forgets the agent tabs since closed, a thread at a time.
  defp prune_owners(state) do
    gone =
      state.owners
      |> Enum.group_by(fn {_tab, {thread, _}} -> thread end, &elem(&1, 0))
      |> Enum.flat_map(fn {thread, tabs} ->
        case thread_tabs(thread) do
          {:ok, now} -> Enum.reject(tabs, &MapSet.member?(now, &1))
          :error -> []
        end
      end)

    drop_owned(state, gone)
  end

  # The agent tab idle longest, past `idle_ms`, that no host shows, no person
  # uses and no action is running on; nil if none.
  defp idle_tab(state, idle_ms) do
    now = System.monotonic_time(:millisecond)
    clients = Map.values(state.clients)

    busy =
      for(
        c <- clients,
        set <- [tab_set(c, :visible_tabs), tab_set(c, :controlled_tabs)],
        tab <- set,
        do: tab
      )
      |> Enum.concat(for {_, p} <- state.pending, do: pending_tab(state, p))
      |> MapSet.new()

    used = Map.get(state, :used, %{})

    state.owners
    |> Map.keys()
    |> Enum.filter(fn tab ->
      case used[tab] do
        {at, _} -> now - at > idle_ms and not MapSet.member?(busy, tab)
        _ -> false
      end
    end)
    |> Enum.min_by(&used[&1], fn -> nil end)
  end

  # When an agent tab was last opened or acted on, in order within a millisecond.
  defp touch(state, tab) do
    at = {System.monotonic_time(:millisecond), System.unique_integer([:monotonic])}

    if Map.has_key?(state.owners, tab),
      do: put_in(state, [:used, tab], at),
      else: state
  end

  # Tabs that are no longer an agent's: their owner and idle time go, and a
  # session whose current tab one was has none.
  defp drop_owned(state, []), do: state

  defp drop_owned(state, tabs) do
    assignments =
      Map.new(state.assignments, fn {key, a} ->
        {key, if(a.tab_id in tabs, do: %{a | tab_id: nil}, else: a)}
      end)

    %{
      state
      | owners: Map.drop(state.owners, tabs),
        used: Map.drop(Map.get(state, :used, %{}), tabs),
        assignments: assignments
    }
  end

  # A failed open that made a tab closes it, so the agent is not left a hidden
  # tab it never heard of: the one its error names (the desktop names the tab
  # it opened), if it is new since the open and no agent's. Never any other
  # tab that appeared meanwhile: a person's, or another open's on its way.
  defp discard_failed_open(
         state,
         %{makes_tab: true, tabs_before: {:ok, before}, key: {thread, _}},
         %{"tabId" => tab}
       )
       when is_binary(tab) do
    if not MapSet.member?(before, tab) and not Map.has_key?(state.owners, tab),
      do: HalC2.Preview.close(%{"threadId" => thread, "tabId" => tab})

    state
  catch
    :exit, _ -> state
  end

  defp discard_failed_open(state, _pending, _error), do: state

  # The thread's tab ids in `HalC2.Preview`, which never calls back here, or
  # :error when it cannot say (not running, busy, or an unexpected reply).
  defp thread_tabs(thread) do
    case HalC2.Preview.list(%{"threadId" => thread}) do
      {:ok, %{"sessions" => sessions}} -> {:ok, MapSet.new(sessions, & &1["tabId"])}
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  # How well a host serves the tab a new session asks about: showing it beats
  # holding a live page for it beats neither. Map.get throughout, so a host
  # registered by older code still routes during an upgrade.
  defp tab_tier(_client, nil), do: 0

  defp tab_tier(client, tab) do
    cond do
      MapSet.member?(Map.get(client, :visible_tabs) || MapSet.new(), tab) -> 2
      MapSet.member?(Map.get(client, :live_tabs) || MapSet.new(), tab) -> 1
      true -> 0
    end
  end

  defp reported(host, key, current) do
    if is_list(host[key]), do: MapSet.new(host[key]), else: current || MapSet.new()
  end

  defp profiles(list) when is_list(list),
    do: for(%{"id" => id, "name" => name} = p <- list, is_binary(id) and is_binary(name), do: p)

  defp profiles(_), do: nil

  @passthrough ~w(PreviewAutomationRecordingDesktopUpdateRequiredError PreviewAutomationRecordingTooLargeError PreviewAutomationRecordingDeadlineExpiredError PreviewAutomationRecordingTransferError PreviewAutomationNoAvailableHostError PreviewAutomationUnsupportedClientError PreviewAutomationTabNotFoundError PreviewAutomationTimeoutError PreviewAutomationNavigationTimeoutError PreviewAutomationControlInterruptedError PreviewAutomationInvalidSelectorError PreviewAutomationTargetNotEditableError PreviewAutomationResultTooLargeError)

  defp remote_error(context, %{"_tag" => tag} = error) do
    tag =
      cond do
        tag in @passthrough -> tag
        tag == "PreviewAutomationUnavailableError" -> "PreviewAutomationRemoteUnavailableError"
        true -> "PreviewAutomationExecutionError"
      end

    context
    |> Map.merge(%{"remoteTag" => error["_tag"], "remoteMessage" => error["message"]})
    |> put_present("maximumBytes", get_in(error, ["detail", "maximumBytes"]))
    |> put_present("targetMatched", get_in(error, ["detail", "matched"]))
    |> then(&tagged(tag, &1))
  end

  defp remote_error(context, _missing),
    do: tagged("PreviewAutomationMalformedResponseError", context)

  defp no_host(scope, operation),
    do:
      tagged("PreviewAutomationNoAvailableHostError", %{
        "operation" => operation,
        "threadId" => scope.thread_id,
        "providerInstanceId" => scope.instance
      })

  defp tagged(tag, fields), do: Map.put(fields, "_tag", tag)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
