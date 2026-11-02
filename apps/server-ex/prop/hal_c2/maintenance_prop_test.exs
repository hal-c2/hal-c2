for file <- ~w(schedule report runs),
    do: Code.require_file("../../../../plugins/maintenance/mc/#{file}.ex", __DIR__)

defmodule HalC2.MaintenancePropTest do
  @moduledoc """
  The maintenance plugin's pure parts (`plugins/maintenance/mc`):

  - a state machine model of how one run moves (`HalC2Plugins.Maintenance.Runs`):
    reporting, its turn ending, cancelling, dismissing, claiming it for its pull
    request, publishing or failing to, and the server starting again. After every
    step the run's status is the model's, it holds its repository exactly while it
    runs or waits on the user, it reports only once, while running or after a turn
    ended unreported, a turn stopped at a usage limit leaves it running, a dismissed
    run is never published, and a run has finished exactly when its status says its
    turn is over;
  - the schedule's laws: a slot is at or before now and the next one after it, one
    period apart, a run is due only for a slot later than the one handled, and a
    plan starts no more due repositories than there is room for, keeping the rest
    due for a later plan;
  - redaction: a redacted text keeps no token it was given and redacting again
    changes nothing.

  The plugin process, the agent and GitHub are covered by
  `features/source-control/maintenance.feature`.
  """
  use ExUnit.Case, async: true
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.Maintenance.{Report, Runs, Schedule}

  @finished ~w(done kept waiting failed cancelled skipped published)

  # --- one run, as a state machine -------------------------------------------------------

  property "a run moves as the model says", numtests: HalC2.Prop.numtests(200) do
    forall mode <- elements(~w(fix report)) do
      forall cmds <- commands(__MODULE__, initial_state(mode)) do
        Process.put(:run, start(mode))
        {history, state, result} = run_commands(__MODULE__, cmds)

        (result == :ok)
        |> when_fail(
          IO.puts("""
          History: #{inspect(history, pretty: true)}
          State: #{inspect(state, pretty: true)}
          Result: #{inspect(result, pretty: true)}
          """)
        )
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start(mode),
    do: %{"id" => "r1", "status" => "running", "mode" => mode, "categories" => ["deps"]}

  def initial_state(mode \\ "fix"),
    do: %{status: "running", mode: mode, dismissed: false, url: nil, unreported: false}

  def command(_state) do
    oneof([
      {:call, __MODULE__, :report, [integer(0, 2), elements(~w(local draft automatic))]},
      {:call, __MODULE__, :turn_ends, [elements([nil, "usage_limit", "provider"])]},
      {:call, __MODULE__, :cancel, []},
      {:call, __MODULE__, :dismiss, []},
      {:call, __MODULE__, :claim, []},
      {:call, __MODULE__, :published, []},
      {:call, __MODULE__, :publish_failed, []},
      {:call, __MODULE__, :revive, []}
    ])
  end

  def precondition(_state, _call), do: true

  def report(applied, publishing),
    do: step(&Runs.reported(&1, %{"summary" => "s"}, applied, "body", publishing))

  def turn_ends(class), do: step(&Runs.finished(&1, "stopped", class))
  def cancel, do: step(&Runs.cancel/1)
  def dismiss, do: step(&Runs.dismiss/1)
  def claim, do: step(&Runs.claim/1)
  def published, do: step(&Runs.published(&1, "https://github.com/acme/api/pull/1"))
  def publish_failed, do: step(&Runs.publish_failed(&1, "refused"))
  def revive, do: step(&{:ok, Runs.revive(&1)})

  # Applies a step to the run, keeping the run it was on a refusal, and answers
  # whether it was accepted and the run after it.
  defp step(fun) do
    run = Process.get(:run)

    case fun.(run) do
      {:ok, next} ->
        Process.put(:run, next)
        {:ok, next}

      {:error, message} when is_binary(message) ->
        {:error, run}
    end
  end

  def next_state(state, _result, {:call, _, name, args}) do
    case accepts(state, name, args) do
      {:ok, next} -> next
      :refused -> state
    end
  end

  def postcondition(state, {:call, _, name, args}, {verdict, run}) do
    expected = accepts(state, name, args)

    accepted? =
      case expected do
        {:ok, _} -> verdict == :ok
        :refused -> verdict == :error
      end

    model = if match?({:ok, _}, expected), do: elem(expected, 1), else: state

    accepted? and run["status"] == model.status and
      run["dismissed"] == true == model.dismissed and
      run["prUrl"] == model.url and
      Runs.holding?(run) ==
        (model.status in ~w(running waiting publishing) and not model.dismissed) and
      Runs.working?(run) == (model.status == "running") and
      run["unreported"] == true == model.unreported and
      Runs.reportable(run) == :ok == reportable?(model) and
      Map.has_key?(run, "finishedAt") == (model.status != "running")
  end

  defp reportable?(model),
    do:
      model.status == "running" or
        (model.status == "failed" and model.unreported and not model.dismissed)

  # The model: what each step does to a run in each status, written as a table
  # rather than as `Runs` matches its arguments.
  defp accepts(s, :report, [applied, publishing]) do
    if reportable?(s),
      do: {:ok, %{reported(s, applied, publishing) | unreported: false}},
      else: :refused
  end

  defp accepts(%{status: "running"} = s, :turn_ends, ["usage_limit"]), do: {:ok, s}

  defp accepts(%{status: "running"} = s, :turn_ends, _),
    do: {:ok, %{s | status: "failed", unreported: true}}

  defp accepts(s, :turn_ends, _), do: {:ok, s}
  defp accepts(%{status: "running"} = s, :cancel, _), do: {:ok, %{s | status: "cancelled"}}

  defp accepts(%{status: status} = s, :dismiss, _) when status in @finished,
    do: {:ok, %{s | dismissed: true}}

  defp accepts(%{dismissed: false, status: status} = s, :claim, _)
       when status in ~w(waiting kept),
       do: {:ok, %{s | status: "publishing"}}

  defp accepts(%{status: "publishing"} = s, :published, _),
    do: {:ok, %{s | status: "published", url: "https://github.com/acme/api/pull/1"}}

  defp accepts(%{status: "publishing"} = s, :publish_failed, _),
    do: {:ok, %{s | status: "waiting"}}

  defp accepts(%{status: "publishing"} = s, :revive, _), do: {:ok, %{s | status: "waiting"}}
  defp accepts(s, :revive, _), do: {:ok, s}
  defp accepts(_s, _name, _args), do: :refused

  defp reported(s, applied, publishing) do
    status =
      cond do
        s.mode == "report" or applied == 0 -> "done"
        publishing == "local" -> "kept"
        publishing == "automatic" -> "publishing"
        true -> "waiting"
      end

    %{s | status: status}
  end

  # --- the schedule ----------------------------------------------------------------------

  defp moment do
    let {days, seconds} <- {integer(0, 3_000), integer(0, 86_399)} do
      ~N[2024-01-01 00:00:00] |> NaiveDateTime.add(days * 86_400 + seconds)
    end
  end

  defp schedule do
    let {kind, weekday, hours, minutes} <-
          {elements(~w(daily weekly)), elements(Schedule.weekdays()), integer(0, 23),
           integer(0, 59)} do
      time =
        String.pad_leading("#{hours}", 2, "0") <> ":" <> String.pad_leading("#{minutes}", 2, "0")

      %{"schedule" => kind, "weekday" => weekday, "time" => time}
    end
  end

  property "the last slot is at or before now, and the next one period after it",
    numtests: HalC2.Prop.numtests(200) do
    forall {settings, now} <- {schedule(), moment()} do
      last = Schedule.last_slot(settings, now)
      next = Schedule.next_slot(settings, now)
      days = if settings["schedule"] == "daily", do: 1, else: 7
      {:ok, time} = Time.from_iso8601(settings["time"] <> ":00")

      NaiveDateTime.compare(last, now) != :gt and NaiveDateTime.compare(next, now) == :gt and
        NaiveDateTime.diff(next, last) == days * 86_400 and
        NaiveDateTime.to_time(last) == time and
        (days == 1 or
           Date.day_of_week(last) ==
             Enum.find_index(Schedule.weekdays(), &(&1 == settings["weekday"])) + 1)
    end
  end

  property "a run is due only for a slot later than the one handled",
    numtests: HalC2.Prop.numtests(200) do
    forall {settings, handled, now} <- {schedule(), moment(), moment()} do
      last = Schedule.last_slot(settings, now)
      due = Schedule.due?(settings, NaiveDateTime.to_iso8601(handled), now)

      due == (NaiveDateTime.compare(last, handled) == :gt) and
        not Schedule.due?(settings, nil, now) and
        not Schedule.due?(%{settings | "schedule" => "manual"}, nil, now) and
        not Schedule.due?(settings, NaiveDateTime.to_iso8601(last), now)
    end
  end

  @repositories ~w(acme/a acme/b acme/c acme/d)

  # Repositories with the slot each last handled (or none yet), the ones held by a
  # run, and the room left for runs at once (below zero when the limit was lowered).
  defp plan_input do
    let {settings, now, handled, held, room} <-
          {schedule(), moment(), vector(length(@repositories), oneof([nil, moment()])),
           list(elements(@repositories)), integer(-2, 5)} do
      slots =
        for {repository, moment} <- Enum.zip(@repositories, handled),
            moment != nil,
            into: %{},
            do: {repository, NaiveDateTime.to_iso8601(moment)}

      {settings, now, slots, MapSet.new(held), room}
    end
  end

  property "a plan starts what is due and unheld, as far as there is room, and keeps the rest due",
    numtests: HalC2.Prop.numtests(200) do
    forall {settings, now, slots, held, room} <- plan_input() do
      held? = &MapSet.member?(held, &1)
      {starting, planned} = Schedule.plan(settings, @repositories, slots, now, held?, room)
      stamp = NaiveDateTime.to_iso8601(Schedule.last_slot(settings, now))

      startable =
        Enum.filter(
          @repositories,
          &(Map.has_key?(slots, &1) and Schedule.due?(settings, slots[&1], now) and not held?.(&1))
        )

      waiting = startable -- starting

      # Another plan, as after a refused start gave its slot back, starts the ones
      # kept waiting once there is room.
      {later, _} = Schedule.plan(settings, @repositories, planned, now, held?, length(waiting))

      starting == Enum.take(startable, max(room, 0)) and
        Enum.all?(waiting, &Schedule.due?(settings, planned[&1], now)) and
        Enum.all?(@repositories -- waiting, &(planned[&1] == stamp or planned[&1] == slots[&1])) and
        Enum.all?(starting, &(planned[&1] == stamp)) and
        Map.keys(planned) |> Enum.sort() == @repositories and
        later == waiting
    end
  end

  # --- redaction -------------------------------------------------------------------------

  defp token_char, do: elements(Enum.concat([?a..?z, ?A..?Z, ?0..?9]) |> Enum.map(&<<&1>>))

  defp secret do
    let {kind, chars} <- {integer(0, 4), vector(36, token_char())} do
      tail = Enum.join(chars)

      case kind do
        0 -> "ghp_" <> tail
        1 -> "github_pat_" <> tail
        2 -> "sk-" <> tail
        3 -> "AKIA" <> String.upcase(String.slice(tail, 0, 16))
        4 -> "-----BEGIN PRIVATE KEY-----\n#{tail}\n-----END PRIVATE KEY-----"
      end
    end
  end

  @prose ["The log said", "and then", "failed:", "\n", "", "ok"]
  defp prose, do: elements(@prose)

  # Parts are joined with a space: a token in a log stands apart from its neighbours,
  # and one run into a word is not told from the word.
  property "a redacted text keeps no secret, and redacting again changes nothing",
    numtests: HalC2.Prop.numtests(200) do
    forall parts <- list(oneof([prose(), secret()])) do
      text = Enum.join(parts, " ")
      redacted = Report.redact(text)
      secrets = Enum.reject(parts, &(&1 in @prose))

      Report.redact(redacted) == redacted and
        Enum.all?(secrets, &(not String.contains?(redacted, &1))) and
        (secrets == [] or String.contains?(redacted, "[redacted"))
    end
  end
end
