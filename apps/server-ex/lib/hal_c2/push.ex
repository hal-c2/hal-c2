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
  are several. A phone's muted threads get no alert. Alerts due in its quiet hours are
  held and sent at their end, except approvals and questions when it lets them through.
  The MC records when it started, and threads that finished before it say nothing.

  `drain/0` evaluates what the shell has sent so far and returns once every push has
  been delivered or given up; tests call it instead of waiting. Options: `:clock` (a
  0-arity function returning ms), `:post` (`WebPush.post/3`'s stand-in) and `:sleep`
  (the backoff between retries).
  """

  use GenServer

  require Logger

  alias HalC2.Push.{Alerts, WebPush}

  @prefix "push:"
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

    state = %{
      clock: clock,
      post: opts[:post] || (&WebPush.post/3),
      sleep: opts[:sleep] || (&Process.sleep/1),
      started_at: clock.(),
      seen: %{},
      registrations: load(),
      # Per session: the card it was last sent, and the alerts held for quiet hours.
      sent: %{},
      held: %{},
      inflight: %{},
      # Thread rows the shell sent that are not evaluated yet.
      pending: [],
      waiters: [],
      timer: nil,
      scheduled: false
    }

    # Everything the shell holds now is the baseline, as of startup.
    {seen, _due} = Alerts.observe(%{}, threads(HalC2.Shell.rows()), state.started_at)
    {:ok, %{state | seen: seen}}
  end

  defp load do
    if Process.whereis(HalC2.Store) do
      for {@prefix <> session, json} <- HalC2.Store.metas(HalC2.Store.path(), @prefix),
          valid_session?(session),
          into: %{},
          do: {session, JSON.decode!(json)}
    else
      %{}
    end
  end

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
    state = state |> take_rows([]) |> evaluate_rows()
    {:noreply, reply_when_idle(%{state | waiters: [from | state.waiters]})}
  end

  # Rows that came in so far, gathered from the mailbox so they are one evaluation.
  defp take_rows(state, changed) do
    receive do
      {:hal_c2_shell, {:rows, mc, rows}} -> take_rows(state, changed ++ thread_rows(mc, rows))
    after
      0 -> %{state | pending: state.pending ++ changed}
    end
  end

  defp evaluate_rows(state) do
    {seen, due} = Alerts.observe(state.seen, state.pending, state.started_at)
    evaluate(%{state | seen: seen, pending: [], scheduled: false}, due)
  end

  @impl true
  def handle_info({:hal_c2_shell, {:rows, mc, rows}}, state) do
    # Rows already in the mailbox join these: one evaluation, so one (grouped) alert.
    state = %{state | pending: state.pending ++ thread_rows(mc, rows)}
    unless state.scheduled, do: send(self(), :evaluate)
    {:noreply, %{state | scheduled: true}}
  end

  def handle_info(:evaluate, state), do: {:noreply, evaluate_rows(state)}
  def handle_info(:tick, state), do: {:noreply, evaluate(%{state | timer: nil}, [])}

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
    muted = MapSet.new(registration["mutedThreads"])
    quiet = registration["quietHours"]
    # A thread muted while its alert was held is muted for that alert too.
    mine = Enum.reject(due, &MapSet.member?(muted, &1.key))
    held = state.held |> Map.get(session, []) |> Enum.reject(&MapSet.member?(muted, &1.key))

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

    state = %{state | held: Map.put(state.held, session, held)}
    alert = if send_now != [], do: Alerts.alert(send_now)

    {card, changed?} =
      if registration["liveActivity"],
        do: card(Map.get(state.sent, session), activity, now),
        else: {nil, false}

    if alert != nil or changed? do
      body = Alerts.message(alert, card, now)
      state = %{state | sent: Map.put(state.sent, session, Alerts.unstamped(activity))}
      deliver(state, session, registration, body, if(alert, do: "high", else: "normal"))
    else
      state
    end
  end

  # The card to send and whether it changed since the last one sent: when nothing is
  # left, a cleared card once.
  defp card(last, nil, now), do: {Alerts.cleared(now), last != nil}
  defp card(last, activity, _now), do: {activity, Alerts.unstamped(activity) != last}

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
  # of quiet hours, a finished row leaving the card.
  defp schedule(state, all, now) do
    if state.timer, do: Process.cancel_timer(state.timer)

    quiet_ends =
      for {session, [_ | _]} <- state.held,
          registration = state.registrations[session],
          quiet = registration && registration["quietHours"],
          do: Alerts.quiet_end(quiet, now)

    case Enum.reject([Alerts.next_expiry(all, now) | quiet_ends], &is_nil/1) do
      [] -> %{state | timer: nil}
      # At most a day ahead: it evaluates again then, and a timer cannot wait for ever.
      times -> %{state | timer: Process.send_after(self(), :tick, delay(Enum.min(times) - now))}
    end
  end
end
