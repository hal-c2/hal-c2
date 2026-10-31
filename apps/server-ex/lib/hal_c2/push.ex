defmodule HalC2.Push do
  @moduledoc """
  Agent push: tells each registered phone when an agent finishes, fails or needs the
  user, through the UnifiedPush endpoint its distributor gave it, with no HAL-C2-hosted
  service in between (`HalC2.Push.WebPush`).

  A client registers with `register/2` (`hal-c2.registerPush`) under its session; the
  registration is kept in the store's `meta` table, so it survives restarts, and is
  dropped when the client is revoked or its endpoint answers 404 or 410.

  The service follows every thread row of the cluster (`HalC2.Shell`) and works out
  alerts and the activity card (`HalC2.Push.Alerts`). Rows that change together are one
  evaluation, and the alerts due in it go out as one push per phone, grouped when there
  are several. A phone's muted threads get no alert, wherever they move. Alerts due in
  its quiet hours are held, beside the registration so a restart keeps them, and sent at
  their end, except approvals and questions when it lets them through. The MC records
  when it started, and threads that finished before it say nothing; nor do those of an
  MC whose rows arrive for the first time, as when it joins the cluster.

  `drain/0` evaluates what the shell has sent so far and returns once every push has
  been delivered or given up; tests call it instead of waiting. Options: `:clock` (a
  0-arity function returning ms), `:post` (`WebPush.post/3`'s stand-in) and `:sleep`
  (the backoff between retries).
  """

  use GenServer

  require Logger

  alias HalC2.Push.{Alerts, WebPush}

  @prefix "push:"
  @held_prefix "push-held:"
  @backoff [1_000, 2_000, 4_000, 8_000, 16_000]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Registers (or replaces) `session`'s push endpoint: `{:ok, %{}}` or an error map."
  def register(nil, _input), do: {:error, invalid("a paired client session is required")}

  def register(session, input) do
    case validate(input) do
      {:ok, registration} -> GenServer.call(__MODULE__, {:register, session, registration})
      {:error, message} -> {:error, invalid(message)}
    end
  end

  @doc "Drops `session`'s registration, if any."
  def unregister(nil), do: {:ok, %{}}
  def unregister(session), do: GenServer.call(__MODULE__, {:unregister, session})

  @doc "The registrations, by session."
  def registrations, do: GenServer.call(__MODULE__, :registrations)

  @doc "Evaluates what is due now and waits for every delivery in flight."
  def drain, do: GenServer.call(__MODULE__, :drain, :infinity)

  defp invalid(message), do: %{"_tag" => "InvalidPushRegistration", "message" => message}

  # --- validation -------------------------------------------------------------------

  defp validate(
         %{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}} = input
       )
       when is_binary(endpoint) and is_binary(p256dh) and is_binary(auth) do
    with :ok <- check_endpoint(endpoint),
         {:ok, public} <- decode(p256dh, "keys.p256dh"),
         :ok <- check_point(public),
         {:ok, secret} <- decode(auth, "keys.auth"),
         :ok <- if(byte_size(secret) == 16, do: :ok, else: {:error, "keys.auth must be 16 bytes"}),
         {:ok, muted} <- strings(input["mutedThreads"] || []),
         {:ok, quiet} <- quiet_hours(input["quietHours"]) do
      {:ok,
       %{
         "endpoint" => endpoint,
         "keys" => %{"p256dh" => p256dh, "auth" => auth},
         "distributor" => if(is_binary(input["distributor"]), do: input["distributor"]),
         "liveActivity" => input["liveActivity"] == true,
         "mutedThreads" => muted,
         "quietHours" => quiet
       }}
    end
  end

  defp validate(_input), do: {:error, "an endpoint and keys.p256dh and keys.auth are required"}

  defp check_endpoint(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        :ok

      _ ->
        {:error, "endpoint must be an http or https URL"}
    end
  end

  defp decode(value, field) do
    case Base.url_decode64(String.trim_trailing(value, "="), padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, "#{field} must be base64url"}
    end
  end

  defp check_point(<<4, _::binary-64>> = public) do
    {_, private} = :crypto.generate_key(:ecdh, :prime256v1)
    _ = :crypto.compute_key(:ecdh, public, private, :prime256v1)
    :ok
  rescue
    _ -> {:error, "keys.p256dh is not a P-256 point"}
  end

  defp check_point(_), do: {:error, "keys.p256dh must be a 65-byte uncompressed P-256 point"}

  defp strings(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: {:ok, list},
      else: {:error, "mutedThreads must be a list of strings"}
  end

  defp strings(_), do: {:error, "mutedThreads must be a list of strings"}

  defp quiet_hours(nil), do: {:ok, nil}

  defp quiet_hours(%{"start" => start, "end" => stop} = quiet)
       when start in 0..1439 and stop in 0..1439 do
    offset = quiet["utcOffsetMinutes"] || 0

    if is_integer(offset) and offset in -1440..1440,
      do:
        {:ok,
         %{
           "start" => start,
           "end" => stop,
           "allowApprovals" => quiet["allowApprovals"] == true,
           "utcOffsetMinutes" => offset
         }},
      else: {:error, "quietHours.utcOffsetMinutes must be minutes from UTC"}
  end

  defp quiet_hours(_),
    do: {:error, "quietHours needs start and end in minutes after local midnight"}

  # --- server -----------------------------------------------------------------------

  @impl true
  def init(opts) do
    clock = opts[:clock] || fn -> System.os_time(:millisecond) end
    if Process.whereis(HalC2.Shell), do: :ok = HalC2.Shell.subscribe(self())
    if Process.whereis(HalC2.Auth), do: {:ok, _, _} = HalC2.Auth.subscribe(self())

    registrations = load()
    shell = HalC2.Shell.rows()

    state = %{
      clock: clock,
      post: opts[:post] || (&WebPush.post/3),
      sleep: opts[:sleep] || (&Process.sleep/1),
      started_at: clock.(),
      seen: %{},
      # The MCs whose rows were seen: the first rows of another are a baseline.
      known: MapSet.new([node() | for({{mc, _id}, _} <- shell, do: mc)]),
      registrations: registrations,
      # Per session: what of the card it was last sent, and the alerts held for quiet
      # hours.
      sent: %{},
      held: load_held(registrations),
      inflight: %{},
      # Thread rows the shell sent that are not evaluated yet.
      pending: [],
      waiters: [],
      timer: nil,
      scheduled: false
    }

    # Everything the shell holds now is the baseline, as of startup.
    {seen, _due} = Alerts.observe(%{}, threads(shell), state.started_at)
    # Alerts held before a restart go when their quiet hours allow.
    if state.held != %{}, do: send(self(), :tick)
    {:ok, %{state | seen: seen}}
  end

  # Registrations of sessions revoked while the MC was down are deleted, not kept.
  defp load do
    if Process.whereis(HalC2.Store) do
      {valid, revoked} =
        HalC2.Store.metas(HalC2.Store.path(), @prefix)
        |> Enum.map(fn {@prefix <> session, json} -> {session, json} end)
        |> Enum.split_with(fn {session, _} -> valid_session?(session) end)

      for {session, _} <- revoked, do: unpersist(session)
      Map.new(valid, fn {session, json} -> {session, JSON.decode!(json)} end)
    else
      %{}
    end
  end

  # Held alerts of a session no longer registered are deleted.
  defp load_held(registrations) do
    if Process.whereis(HalC2.Store) do
      for {@held_prefix <> session, json} <- HalC2.Store.metas(HalC2.Store.path(), @held_prefix),
          reduce: %{} do
        held ->
          if Map.has_key?(registrations, session) do
            Map.put(held, session, Enum.map(JSON.decode!(json), &held_alert/1))
          else
            persist_held(session, [])
            held
          end
      end
    else
      %{}
    end
  end

  defp held_alert(map),
    do: Map.new(~w(id kind key title environment_id thread_id)a, &{&1, map[to_string(&1)]})

  defp valid_session?(session) do
    if Process.whereis(HalC2.Auth),
      do: match?({:ok, _}, HalC2.Auth.session_scopes(session)),
      else: true
  end

  @impl true
  def handle_call({:register, session, registration}, _from, state) do
    persist(session, registration)

    state = %{
      state
      | registrations: Map.put(state.registrations, session, registration),
        sent: Map.delete(state.sent, session)
    }

    {:reply, {:ok, %{}}, evaluate(state, [])}
  end

  def handle_call({:unregister, session}, _from, state),
    do: {:reply, {:ok, %{}}, drop(state, session)}

  def handle_call(:registrations, _from, state), do: {:reply, state.registrations, state}

  def handle_call(:drain, from, state) do
    # What the shell sent before this call is in the mailbox once its own reply is.
    if Process.whereis(HalC2.Shell), do: HalC2.Shell.sync()
    state = state |> take_rows() |> evaluate_rows()
    {:noreply, reply_when_idle(%{state | waiters: [from | state.waiters]})}
  end

  # Rows that came in so far, gathered from the mailbox so they are one evaluation.
  defp take_rows(state) do
    receive do
      {:hal_c2_shell, {:rows, mc, rows}} -> state |> put_rows(mc, rows) |> take_rows()
    after
      0 -> state
    end
  end

  # An MC's first rows are what it had when it joined: remembered, not news.
  defp put_rows(state, mc, rows) do
    threads = thread_rows(mc, rows)

    state =
      if MapSet.member?(state.known, mc),
        do: state,
        else: %{
          state
          | seen: Alerts.baseline(state.seen, threads),
            known: MapSet.put(state.known, mc)
        }

    %{state | pending: state.pending ++ threads}
  end

  defp evaluate_rows(state) do
    {seen, due} = Alerts.observe(state.seen, state.pending, state.started_at)
    evaluate(%{state | seen: seen, pending: [], scheduled: false}, due)
  end

  @impl true
  def handle_info({:hal_c2_shell, {:rows, mc, rows}}, state) do
    # Rows already in the mailbox join these: one evaluation, so one (grouped) alert.
    state = put_rows(state, mc, rows)
    unless state.scheduled, do: send(self(), :evaluate)
    {:noreply, %{state | scheduled: true}}
  end

  def handle_info(:evaluate, state), do: {:noreply, evaluate_rows(state)}
  def handle_info(:tick, state), do: {:noreply, evaluate(%{state | timer: nil}, [])}

  # A machine removed from the cluster that joins again is new again.
  def handle_info({:hal_c2_shell, {:mc, mc, :removed}}, state),
    do: {:noreply, %{state | known: MapSet.delete(state.known, mc)}}

  def handle_info(
        {:hal_c2_auth_access, %{"type" => "clientRemoved", "payload" => payload}},
        state
      ),
      do: {:noreply, drop(state, payload["sessionId"])}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.inflight, ref) do
      {nil, _} ->
        {:noreply, state}

      {{session, endpoint}, inflight} ->
        state = %{state | inflight: inflight}

        state =
          case {reason, state.registrations[session]} do
            {{:shutdown, :gone}, %{"endpoint" => ^endpoint}} -> drop(state, session)
            _ -> state
          end

        {:noreply, reply_when_idle(state)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp reply_when_idle(%{inflight: inflight} = state) when map_size(inflight) == 0 do
    for from <- state.waiters, do: GenServer.reply(from, :ok)
    %{state | waiters: []}
  end

  defp reply_when_idle(state), do: state

  defp drop(state, session) do
    if Map.has_key?(state.registrations, session), do: unpersist(session)
    if Map.get(state.held, session, []) != [], do: persist_held(session, [])

    %{
      state
      | registrations: Map.delete(state.registrations, session),
        sent: Map.delete(state.sent, session),
        held: Map.delete(state.held, session)
    }
  end

  defp persist(session, registration) do
    if Process.whereis(HalC2.Store),
      do: :ok = HalC2.Store.put_meta(@prefix <> session, JSON.encode!(registration))
  end

  defp unpersist(session) do
    if Process.whereis(HalC2.Store), do: :ok = HalC2.Store.delete_meta(@prefix <> session)
  end

  defp persist_held(session, held) do
    cond do
      Process.whereis(HalC2.Store) == nil -> :ok
      held == [] -> :ok = HalC2.Store.delete_meta(@held_prefix <> session)
      true -> :ok = HalC2.Store.put_meta(@held_prefix <> session, JSON.encode!(held))
    end
  end

  # --- evaluation -------------------------------------------------------------------

  defp thread_rows(mc, rows) do
    environment = environment_id(mc)

    for {_id, {"thread", row}} <- rows,
        thread = Alerts.thread(environment, row, project_title(mc, row["projectId"])),
        do: thread
  end

  defp threads(rows) do
    for {{mc, _id}, {"thread", row}} <- rows,
        thread = Alerts.thread(environment_id(mc), row, project_title(mc, row["projectId"])),
        do: thread
  end

  defp environment_id(mc) do
    environments = if Process.whereis(HalC2.Shell), do: HalC2.Shell.environments(), else: []

    case List.keyfind(environments, mc, 0) do
      {_, %{"environmentId" => id}} when is_binary(id) -> id
      _ when mc == node() -> HalC2.Environment.id()
      _ -> to_string(mc)
    end
  end

  defp project_title(_mc, nil), do: nil

  defp project_title(mc, project_id) do
    case HalC2.Shell.row(mc, project_id) do
      {"project", project} -> project["title"]
      _ -> nil
    end
  end

  defp evaluate(state, due) do
    now = state.clock.()
    live? = Enum.any?(state.registrations, fn {_, r} -> r["liveActivity"] end)
    all = if live?, do: threads(HalC2.Shell.rows()), else: []
    activity = if live?, do: Alerts.activity(all, now)

    state =
      Enum.reduce(state.registrations, state, fn {session, registration}, state ->
        notify(state, session, registration, due, activity, now)
      end)

    schedule(state, all, now)
  end

  defp notify(state, session, registration, due, activity, now) do
    # Mutes name `environment:thread`; the thread keeps its id when it moves.
    muted = MapSet.new(registration["mutedThreads"], &(&1 |> String.split(":") |> List.last()))
    quiet = registration["quietHours"]
    # A thread muted while its alert was held is muted for that alert too.
    mine = Enum.reject(due, &MapSet.member?(muted, &1.thread_id))
    was_held = Map.get(state.held, session, [])
    held = Enum.reject(was_held, &MapSet.member?(muted, &1.thread_id))

    {send_now, held} =
      cond do
        not Alerts.quiet?(quiet, now) ->
          {held ++ mine, []}

        quiet["allowApprovals"] ->
          {urgent, rest} = Enum.split_with(mine, &(&1.kind in ~w(approval input)))
          {urgent, held ++ rest}

        true ->
          {[], held ++ mine}
      end

    if held != was_held, do: persist_held(session, held)
    state = %{state | held: Map.put(state.held, session, held)}
    alert = if send_now != [], do: Alerts.alert(send_now)

    {card, changed?} =
      if registration["liveActivity"],
        do: card(Map.get(state.sent, session), activity, now),
        else: {nil, false}

    if alert != nil or changed? do
      body = Alerts.message(alert, card, now)
      state = %{state | sent: Map.put(state.sent, session, sent(activity))}
      deliver(state, session, registration, body, if(alert, do: "high", else: "normal"))
    else
      state
    end
  end

  # What is kept of a card sent: enough to tell whether the next one changed, and when
  # it must go again regardless.
  defp sent(nil), do: nil

  defp sent(activity),
    do: %{card: Alerts.unstamped(activity), refresh_at: Alerts.refresh_at(activity)}

  # The card to send and whether it must go: changed since the last one sent, or about
  # to expire on the phone while its work goes on; when nothing is left, a cleared card
  # once.
  defp card(last, nil, now), do: {Alerts.cleared(now), last != nil}

  defp card(nil, activity, _now), do: {activity, true}

  defp card(last, activity, now),
    do:
      {activity,
       Alerts.unstamped(activity) != last.card or
         (last.refresh_at != nil and now >= last.refresh_at)}

  defp deliver(state, session, registration, json, urgency) do
    %{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}} = registration
    {:ok, public} = decode(p256dh, "p256dh")
    {:ok, secret} = decode(auth, "auth")
    body = WebPush.encrypt(json, public, secret)
    %{post: post, sleep: sleep} = state

    {_pid, ref} =
      spawn_monitor(fn ->
        exit({:shutdown, attempt(post, sleep, endpoint, body, urgency, @backoff)})
      end)

    %{state | inflight: Map.put(state.inflight, ref, {session, endpoint})}
  end

  # One request, then one after each backoff step while the endpoint asks for a retry.
  defp attempt(post, sleep, endpoint, body, urgency, backoff) do
    case post.(endpoint, body, urgency) do
      :delivered ->
        :delivered

      :gone ->
        :gone

      {:retry, reason} ->
        case backoff do
          [] ->
            Logger.warning("push to #{URI.parse(endpoint).host} gave up: #{inspect(reason)}")
            :failed

          [wait | rest] ->
            sleep.(wait)
            attempt(post, sleep, endpoint, body, urgency, rest)
        end
    end
  end

  defp delay(ms), do: ms |> max(0) |> min(:timer.hours(24))

  # Wakes at the next moment something changes with time alone: held alerts at the end
  # of quiet hours, a finished row leaving the card, a running card due again.
  defp schedule(state, all, now) do
    if state.timer, do: Process.cancel_timer(state.timer)

    quiet_ends =
      for {session, [_ | _]} <- state.held,
          registration = state.registrations[session],
          quiet = registration && registration["quietHours"],
          do: Alerts.quiet_end(quiet, now)

    refreshes = for {_session, %{refresh_at: at}} when at != nil <- state.sent, do: at

    case Enum.reject([Alerts.next_expiry(all, now) | quiet_ends ++ refreshes], &is_nil/1) do
      [] -> %{state | timer: nil}
      # At most a day ahead: it evaluates again then, and a timer cannot wait for ever.
      times -> %{state | timer: Process.send_after(self(), :tick, delay(Enum.min(times) - now))}
    end
  end
end
