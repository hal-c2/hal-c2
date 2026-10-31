defmodule HalC2.PushPropTest do
  @moduledoc """
  `HalC2.Push` against a model of two phones' registrations and three threads whose
  agents finish turns: phones register (muting some threads, with or without quiet
  hours from 22:00 to 07:00) and unregister, an endpoint starts answering 410, the clock
  moves, and the service restarts, also with a turn finishing while it is down.

  The phones' endpoints are this test: the service's `post` decrypts what it is given
  with the phone's key and notes the alert, or answers `:gone` for a dead endpoint. The
  clock is the model's. After every command the test drains the service, so the model
  can say exactly which alerts each phone got. The promises checked:

    * a phone is alerted only while registered, never about a thread it muted, and
      about each finished turn exactly once;
    * finished turns are sent at once outside quiet hours, held during them, and sent
      together, grouped, when they end; a thread muted meanwhile is left out;
    * an endpoint that answers 410 is dropped and gets nothing more until the phone
      registers again;
    * registrations survive a restart, and a turn that finished before the service
      started is not alerted (pingdotgg/t3code#13340), nor is what another MC had when
      its rows first arrive; alerts held across a restart are kept and sent when the
      quiet hours allow.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Push
  alias HalC2.Push.WebPush

  @moduletag timeout: :infinity

  @sessions ~w(s1 s2)
  @threads ~w(t1 t2 t3)
  # 2030-01-01 12:00 UTC: quiet hours are 22:00 to 07:00 UTC.
  @start 1_893_499_200_000
  @quiet %{
    "start" => 22 * 60,
    "end" => 7 * 60,
    "allowApprovals" => false,
    "utcOffsetMinutes" => 0
  }

  property "phones are alerted once for each finished turn they asked to hear about",
    numtests: HalC2.Prop.numtests(150),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = scratch_home()
        setup_case()

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          {Push, clock: &clock/0, post: &post/3, sleep: fn _ -> :ok end}
        ])

        create_threads()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        File.rm_rf!(home)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # regs: `session => %{muted: [thread], quiet: boolean, endpoint: n}`; held: the
  # threads whose alerts a session's quiet hours hold, in order; dead: endpoints that
  # answer 410; endpoints: how many have been handed out; clock: the service's time.
  # started_at: when the service last started; appeared: threads of another MC shown so
  # far; peer_known: whether the service has had that MC's rows since it started.
  def initial_state,
    do: %{
      regs: %{},
      held: %{},
      dead: MapSet.new(),
      endpoints: 0,
      clock: @start,
      started_at: @start,
      appeared: 0,
      peer_known: false
    }

  def command(state) do
    frequency(
      [
        {3,
         {:call, __MODULE__, :register,
          [oneof(@sessions), sublist(@threads), boolean(), state.endpoints + 1]}},
        {1, {:call, __MODULE__, :unregister, [oneof(@sessions)]}},
        {6, {:call, __MODULE__, :finish, [oneof(@threads), state.clock + 1000]}},
        {2,
         {:call, __MODULE__, :advance,
          [let(h <- choose(1, 12), do: state.clock + :timer.hours(h))]}},
        {1, {:call, __MODULE__, :restart, [state.clock + 1]}},
        {1, {:call, __MODULE__, :finish_while_down, [oneof(@threads), state.clock]}},
        {2,
         {:call, __MODULE__, :appear,
          [state.appeared + 1, oneof([state.started_at - 1, state.started_at, state.clock])]}},
        {1, {:call, __MODULE__, :join_empty, []}}
      ] ++
        case Map.keys(state.regs) do
          [] -> []
          sessions -> [{1, {:call, __MODULE__, :gone, [oneof(sessions)]}}]
        end
    )
  end

  defp sublist(list),
    do:
      let(
        picks <- vector(length(list), boolean()),
        do: for({x, true} <- Enum.zip(list, picks), do: x)
      )

  def precondition(state, {:call, _, :register, [_, _, _, n]}), do: n == state.endpoints + 1
  def precondition(state, {:call, _, :finish, [_, at]}), do: at == state.clock + 1000
  def precondition(state, {:call, _, :advance, [at]}), do: at > state.clock
  def precondition(state, {:call, _, :restart, [at]}), do: at == state.clock + 1
  def precondition(state, {:call, _, :finish_while_down, [_, at]}), do: at == state.clock
  def precondition(state, {:call, _, :gone, [session]}), do: Map.has_key?(state.regs, session)

  def precondition(state, {:call, _, :appear, [k, at]}),
    do: k == state.appeared + 1 and at <= state.clock

  def precondition(_state, _call), do: true

  def next_state(state, _result, call), do: elem(step(state, call), 0)

  def postcondition(state, call, deliveries) do
    {_, expected} = step(state, call)

    if deliveries == expected do
      true
    else
      IO.puts("expected #{inspect(expected)}, got #{inspect(deliveries)}")
      false
    end
  end

  # The model's next state and the alerts each phone gets, `session => [thread]`
  # sorted, for one command.
  defp step(state, {:call, _, :register, [session, muted, quiet, n]}) do
    reg = %{muted: muted, quiet: quiet, endpoint: n}
    state = %{state | regs: Map.put(state.regs, session, reg), endpoints: n}
    evaluate(state, [])
  end

  defp step(state, {:call, _, :unregister, [session]}), do: {drop(state, session), %{}}

  defp step(state, {:call, _, :finish, [thread, at]}),
    do: evaluate(%{state | clock: at}, [thread])

  defp step(state, {:call, _, :advance, [at]}), do: evaluate(%{state | clock: at}, [])

  # Held alerts are kept beside the registrations; a restart forgets the turns finished
  # before it, and which other MCs it has heard from.
  defp step(state, {:call, _, :restart, [at]}),
    do: evaluate(%{state | clock: at, started_at: at, peer_known: false}, [])

  defp step(state, {:call, _, :finish_while_down, [_thread, at]}),
    do: evaluate(%{state | clock: at + 1, started_at: at + 1, peer_known: false}, [])

  # A thread first seen finished is news only if it finished after the service started,
  # and its MC's rows came before.
  defp step(state, {:call, _, :appear, [k, at]}) do
    due = if state.peer_known and at > state.started_at, do: ["n#{k}"], else: []
    evaluate(%{state | appeared: k, peer_known: true}, due)
  end

  # The other MC's rows arrive whole with none among them: its next thread is news.
  defp step(state, {:call, _, :join_empty, []}), do: evaluate(%{state | peer_known: true}, [])

  defp step(state, {:call, _, :gone, [session]}),
    do: {%{state | dead: MapSet.put(state.dead, state.regs[session].endpoint)}, %{}}

  defp evaluate(state, due) do
    Enum.reduce(state.regs, {state, %{}}, fn {session, reg}, {state, sent} ->
      mine = Enum.reject(due, &(&1 in reg.muted))
      held = state.held |> Map.get(session, []) |> Enum.reject(&(&1 in reg.muted))

      {send, held} =
        if reg.quiet and quiet?(state.clock), do: {[], held ++ mine}, else: {held ++ mine, []}

      state = %{state | held: Map.put(state.held, session, held)}

      cond do
        send == [] -> {state, sent}
        MapSet.member?(state.dead, reg.endpoint) -> {drop(state, session), sent}
        true -> {state, Map.put(sent, session, Enum.sort(send))}
      end
    end)
  end

  defp drop(state, session),
    do: %{state | regs: Map.delete(state.regs, session), held: Map.delete(state.held, session)}

  defp quiet?(ms) do
    minute = div(rem(ms, :timer.hours(24)), :timer.minutes(1))
    minute >= @quiet["start"] or minute < @quiet["end"]
  end

  # --- commands -------------------------------------------------------------------

  def register(session, muted, quiet, n) do
    observe(fn ->
      {public, _private, auth} = keys(session)

      input = %{
        "endpoint" => endpoint(session, n),
        "keys" => %{
          "p256dh" => Base.url_encode64(public, padding: false),
          "auth" => Base.url_encode64(auth, padding: false)
        },
        "distributor" => "io.heckel.ntfy",
        "liveActivity" => false,
        "mutedThreads" => Enum.map(muted, &key/1),
        "quietHours" => if(quiet, do: @quiet)
      }

      {:ok, %{}} = Push.register(session, input)
    end)
  end

  def unregister(session), do: observe(fn -> {:ok, %{}} = Push.unregister(session) end)

  def finish(thread, at) do
    observe(fn ->
      set_clock(at)
      complete(thread, at)
    end)
  end

  def advance(at), do: observe(fn -> set_clock(at) end)

  def restart(at) do
    observe(fn ->
      set_clock(at)
      HalC2.Prop.restart_service(Push)
    end)
  end

  # The turn finishes at `at`, while the service is down; it starts again a moment later.
  def finish_while_down(thread, at) do
    observe(fn ->
      sup = Process.get({HalC2.Prop, :services})
      :ok = Supervisor.terminate_child(sup, Push)
      complete(thread, at)
      set_clock(at + 1)
      {:ok, _} = Supervisor.restart_child(sup, Push)
    end)
  end

  def gone(session) do
    observe(fn ->
      n = :persistent_term.get({__MODULE__, :endpoints})[session]
      :ets.insert(__MODULE__, {{:dead, endpoint(session, n)}})
    end)
  end

  # A thread of another MC shows up in the sidebar for the first time, its turn finished
  # at `at`, as a member's rows reach the service through the shell.
  def appear(k, at) do
    observe(fn ->
      iso = at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

      row = %{
        "id" => "n#{k}",
        "projectId" => "project-1",
        "title" => "N#{k}",
        "latestRunId" => "run-n#{k}",
        "status" => "completed",
        "latestRunCompletedAt" => iso,
        "updatedAt" => iso
      }

      send(Push, {:hal_c2_shell, {:rows, :"pa@prop.invalid", [{"n#{k}", {"thread", row}}]}})
    end)
  end

  # The other MC's rows reach the service whole, and there are none: as the shell sends
  # those of a member that joins with no threads.
  def join_empty,
    do: observe(fn -> send(Push, {:hal_c2_shell, {:rows, :"pa@prop.invalid", []}}) end)

  # Runs `fun`, drains the service, and returns the alerts each phone got meanwhile.
  defp observe(fun) do
    fun.()
    :ok = Push.drain()

    for {{:alert, session}, titles} <- :ets.tab2list(__MODULE__),
        into: %{},
        do: {session, Enum.sort(titles)}
  after
    :ets.match_delete(__MODULE__, {{:alert, :_}, :_})
  end

  defp complete(thread, at) do
    run = "run-#{System.unique_integer([:positive])}"
    iso = at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    {:ok, _} =
      HalC2.Streams.commit(thread, :thread, [
        {"run", run,
         %{
           "s" => %{
             "id" => run,
             "threadId" => thread,
             "ordinal" => System.unique_integer([:positive, :monotonic]),
             "status" => "completed",
             "requestedAt" => iso,
             "startedAt" => iso,
             "completedAt" => iso
           }
         }}
      ])

    :ok = HalC2.Streams.flush_shell(thread)
  end

  # --- the phones and the clock ---------------------------------------------------

  defp setup_case do
    if :ets.whereis(__MODULE__) != :undefined, do: :ets.delete(__MODULE__)
    :ets.new(__MODULE__, [:named_table, :public, :set])
    :ets.insert(__MODULE__, {:clock, @start})
    :persistent_term.put({__MODULE__, :endpoints}, %{})

    for session <- @sessions do
      {public, private} = :crypto.generate_key(:ecdh, :prime256v1)

      :ets.insert(
        __MODULE__,
        {{:keys, session}, {public, private, :crypto.strong_rand_bytes(16)}}
      )
    end
  end

  defp create_threads do
    for thread <- @threads do
      {:ok, _} =
        HalC2.Orchestration.dispatch(%{
          "type" => "thread.create",
          "threadId" => thread,
          "projectId" => "project-1",
          "title" => String.upcase(thread),
          "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
          "runtimeMode" => "full-access",
          "interactionMode" => "default"
        })

      :ok = HalC2.Streams.flush_shell(thread)
    end

    :ok = Push.drain()
  end

  defp scratch_home do
    dir = Path.join(System.tmp_dir!(), "hal-c2-push-prop-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    Application.put_env(:hal_c2, :home, dir)
    dir
  end

  defp keys(session), do: :ets.lookup_element(__MODULE__, {:keys, session}, 2)

  defp endpoint(session, n) do
    :persistent_term.put(
      {__MODULE__, :endpoints},
      Map.put(:persistent_term.get({__MODULE__, :endpoints}), session, n)
    )

    "http://phone.invalid/#{session}/#{n}"
  end

  defp key(thread), do: "#{HalC2.Environment.id()}:#{thread}"

  def clock, do: :ets.lookup_element(__MODULE__, :clock, 2)
  defp set_clock(ms), do: :ets.insert(__MODULE__, {:clock, ms})

  # The phone's distributor: a dead endpoint answers 410; a live one takes the message,
  # which the phone decrypts and shows.
  def post(url, body, _urgency) do
    "http://phone.invalid/" <> rest = url
    [session, _n] = String.split(rest, "/")

    if :ets.member(__MODULE__, {:dead, url}) do
      :gone
    else
      {_public, private, auth} = keys(session)
      {:ok, json} = WebPush.decrypt(body, private, auth)
      alert = JSON.decode!(json)["alert"]

      titles =
        if alert["kind"] == "grouped",
          do: String.split(alert["body"], "\n"),
          else: [alert["title"]]

      threads = Enum.map(titles, &String.downcase/1)
      # One alert per phone per command: a second would show as a mismatch.
      unless :ets.insert_new(__MODULE__, {{:alert, session}, threads}),
        do: :ets.insert(__MODULE__, {{:alert, session}, [:twice | threads]})

      :delivered
    end
  end
end
