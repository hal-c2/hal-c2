defmodule HalC2.PullRequestWakesPropTest do
  @moduledoc """
  A state machine over one thread and the two pull requests it may link: links and
  unlinks, host snapshots synced onto them, the thread settled, unsettled, archived and
  unarchived, a run of its own working, and the MC restarting, with
  `HalC2.PullRequests.Wakes.check/1` asked between any of them. The model keeps what
  the thread was told of each link and checks what the thread is promised:

  - a check wakes it at most once, and only while it is neither settled nor archived
    and has no run working; nothing else wakes it;
  - a wake tells what changed since the thread was last told (`news/2`), all of it,
    and never what it already heard, a link's first snapshot, or a restart;
  - a check that finds news on an idle thread that is present wakes it, unless every
    link is done and the thread settles on its own instead;
  - what a settled or archived thread missed is told once it is back;
  - a review or comment by the signed-in account, the agent's own, is news only when
    no run of the thread was going as it was posted, and never hides one by someone
    else.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.PullRequests.Wakes
  alias HalC2.StreamState

  @moduletag timeout: :infinity

  @thread "t"
  @numbers [1, 2]
  # Host times are fixed: activity numbered `act` is posted `act` seconds after @base,
  # and a run started or finished at `clock` does so half a second after its newest
  # activity, so whether one was posted during a run is never a tie.
  @base ~U[2030-01-01 00:00:00Z]

  property "a thread is woken once for each change of a pull request it owns",
    numtests: HalC2.Prop.numtests(300),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("pull-request-wakes")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch
        ])

        setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # links: `[{number, %{snapshot, told}}]` in the order they were linked, `snapshot`
  # what the host said last (nil before the first sync) and `told` what the thread
  # heard of it (nil before its baseline). A snapshot is %{state, checks, merge, act,
  # own}, `act` numbering the newest trusted review or comment by someone else and
  # `own` the newest by the signed-in account (0 for none); `clock` is the newest so
  # far, and `during` the own ones posted while a run was going. `runs` counts the
  # runs started, the last one going while `busy`.
  def initial_state,
    do: %{
      links: [],
      settled: false,
      archived: false,
      busy: false,
      runs: 0,
      clock: 0,
      during: MapSet.new()
    }

  def command(state) do
    frequency(
      [
        {2, {:call, __MODULE__, :link, [oneof(@numbers)]}},
        {6, {:call, __MODULE__, :check, []}},
        {1, {:call, __MODULE__, :restart, []}},
        {1, {:call, __MODULE__, if(state.settled, do: :unsettle, else: :settle), []}},
        {1, {:call, __MODULE__, if(state.archived, do: :unarchive, else: :archive), []}},
        {3, run_call(state)}
      ] ++
        case linked(state) do
          [] ->
            []

          linked ->
            [{1, {:call, __MODULE__, :unlink, [oneof(linked)]}}, {6, sync_call(state, linked)}]
        end
    )
  end

  defp run_call(%{busy: true} = state),
    do: {:call, __MODULE__, :finish, [state.runs, state.clock]}

  defp run_call(state), do: {:call, __MODULE__, :work, [state.runs + 1, state.clock]}

  # A sync carries the newest review or comment the host has by someone else and by
  # the signed-in account: at most one of them new, the rest as last time.
  defp sync_call(state, linked) do
    let [n, s, checks, merge, posted] <- [
          oneof(linked),
          frequency([{6, "open"}, {1, "merged"}, {1, "closed"}]),
          oneof([nil, "pending", "failing", "passing"]),
          oneof(["mergeable", "conflicting", "unknown"]),
          oneof([nil, :act, :own])
        ] do
      last = snapshot_of(state, n) || %{act: 0, own: 0}
      act = if posted == :act, do: state.clock + 1, else: last.act
      own = if posted == :own, do: state.clock + 1, else: last.own

      {:call, __MODULE__, :sync,
       [n, %{state: s, checks: checks, merge: merge, act: act, own: own}]}
    end
  end

  defp linked(state), do: Enum.map(state.links, &elem(&1, 0))

  defp snapshot_of(state, n) do
    case List.keyfind(state.links, n, 0) do
      {_, link} -> link.snapshot
      nil -> nil
    end
  end

  def precondition(state, {:call, _, :unlink, [n]}), do: n in linked(state)

  # A sync is of a link that is there, and its activity is never older than the last,
  # with at most one of them new.
  def precondition(state, {:call, _, :sync, [n, snapshot]}) do
    last = snapshot_of(state, n) || %{act: 0, own: 0}
    new = state.clock + 1

    n in linked(state) and snapshot.act in [new, last.act] and snapshot.own in [new, last.own] and
      not (snapshot.act == new and snapshot.own == new)
  end

  # The MC refuses to settle a thread with work running, and to settle or unsettle an
  # archived one.
  def precondition(state, {:call, _, :settle, []}),
    do: not state.settled and not state.busy and not state.archived

  def precondition(state, {:call, _, :unsettle, []}), do: state.settled and not state.archived
  def precondition(state, {:call, _, :archive, []}), do: not state.archived
  def precondition(state, {:call, _, :unarchive, []}), do: state.archived

  def precondition(state, {:call, _, :work, [k, clock]}),
    do: not state.busy and k == state.runs + 1 and clock == state.clock

  def precondition(state, {:call, _, :finish, [k, clock]}),
    do: state.busy and k == state.runs and clock == state.clock

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :link, [n]}) do
    if n in linked(state),
      do: state,
      else: %{state | links: state.links ++ [{n, %{snapshot: nil, told: nil}}]}
  end

  def next_state(state, _result, {:call, _, :unlink, [n]}),
    do: %{state | links: List.keydelete(state.links, n, 0)}

  def next_state(state, _result, {:call, _, :sync, [n, snapshot]}) do
    links =
      Enum.map(state.links, fn
        {^n, link} -> {n, %{link | snapshot: snapshot}}
        other -> other
      end)

    own_new? = snapshot.own > state.clock

    %{
      state
      | links: links,
        clock: Enum.max([state.clock, snapshot.act, snapshot.own]),
        during:
          if(own_new? and state.busy,
            do: MapSet.put(state.during, snapshot.own),
            else: state.during
          )
    }
  end

  def next_state(state, _result, {:call, _, :settle, []}), do: %{state | settled: true}
  def next_state(state, _result, {:call, _, :unsettle, []}), do: %{state | settled: false}
  def next_state(state, _result, {:call, _, :archive, []}), do: %{state | archived: true}
  def next_state(state, _result, {:call, _, :unarchive, []}), do: %{state | archived: false}
  def next_state(state, _result, {:call, _, :work, [k, _]}), do: %{state | busy: true, runs: k}
  def next_state(state, _result, {:call, _, :finish, _}), do: %{state | busy: false}
  def next_state(state, _result, {:call, _, :restart, []}), do: state

  # Woken, or yielding to settlement, the thread has heard the news either way.
  def next_state(state, _result, {:call, _, :check, []}),
    do: %{state | links: Enum.map(state.links, fn {n, link} -> {n, hear(state, link)} end)}

  # A first snapshot is a baseline; away the thread hears nothing more; busy, news
  # waits and the rest is heard.
  defp hear(_state, %{snapshot: nil} = link), do: link

  defp hear(_state, %{told: nil, snapshot: snapshot} = link),
    do: %{link | told: advance(%{failed: false, act: 0}, snapshot, [])}

  defp hear(state, link) when state.settled or state.archived, do: link

  defp hear(state, %{told: told, snapshot: snapshot} = link) do
    case news(state, told, snapshot) do
      [] -> %{link | told: advance(told, snapshot, [])}
      _ when state.busy -> link
      news -> %{link | told: advance(told, snapshot, news)}
    end
  end

  defp advance(told, snapshot, news) do
    checks = snapshot.checks || told[:checks]

    failed =
      cond do
        :checks_failing in news -> true
        checks == "passing" -> false
        true -> told.failed
      end

    %{
      state: snapshot.state,
      checks: checks,
      merge: if(snapshot.merge == "unknown", do: told[:merge], else: snapshot.merge),
      failed: failed,
      act: Enum.max([told.act, snapshot.act, snapshot.own])
    }
  end

  # What is worth telling, in the order the message tells it. Activity is told as it is
  # numbered past what was heard; the agent's own only when no run was going.
  defp news(state, told, snapshot) do
    open? = snapshot.state == "open"

    Enum.filter(
      [
        snapshot.state == "merged" and told.state != "merged" and :merged,
        snapshot.state == "closed" and told.state != "closed" and :closed,
        open? and snapshot.checks == "failing" and told.checks != "failing" and :checks_failing,
        open? and snapshot.checks == "passing" and told.failed and :checks_passing,
        open? and snapshot.merge == "conflicting" and told.merge != "conflicting" and
          :conflicting,
        snapshot.act > told.act and :activity,
        snapshot.own > told.act and snapshot.own not in state.during and :activity
      ],
      & &1
    )
  end

  # The news a check finds, as `[{number, news}]` in link order.
  defp pending(state) do
    for {n, %{told: told, snapshot: snapshot}} <- state.links,
        told != nil and snapshot != nil,
        news = news(state, told, snapshot),
        news != [],
        do: {n, news}
  end

  # A thread with nothing open may settle on its own instead of being woken
  # (`HalC2.Orchestration.Settlement.settles_now?/1`), unless the user decided.
  defp may_settle?(state, overridden?) do
    not overridden? and
      Enum.all?(state.links, fn {_, link} -> link.snapshot && link.snapshot.state != "open" end)
  end

  def postcondition(state, {:call, _, :check, []}, {result, wakes, overridden?}) do
    expected = pending(state)

    cond do
      state.settled or state.archived or state.busy or expected == [] ->
        result == :quiet and wakes == []

      result == :quiet ->
        wakes == [] and may_settle?(state, overridden?)

      true ->
        result == :woken and match?([_], wakes) and told?(hd(wakes), expected)
    end
  end

  def postcondition(_state, _call, {_result, wakes, _}), do: wakes == []

  # The wake names each pull request with news, and tells all of it.
  defp told?(wake, expected) do
    notification = wake["notification"]

    notification["source"]["pullRequests"] ==
      Enum.map(expected, fn {n, _} -> "github.com/acme/app##{n}" end) and
      notification["summary"] ==
        Enum.map_join(expected, "; ", fn {n, news} ->
          "acme/app##{n}: " <> Enum.map_join(news, ", ", &label/1)
        end)
  end

  defp label(:checks_failing), do: "checks failing"
  defp label(:checks_passing), do: "checks pass"
  defp label(:conflicting), do: "merge conflict"
  defp label(:merged), do: "merged"
  defp label(:closed), do: "closed"
  defp label(:activity), do: "new comment"

  # --- the real side ----------------------------------------------------------------

  defp setup do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @thread,
        "projectId" => "project-1",
        "title" => "Owner",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })
  end

  def link(n) do
    observe(fn ->
      dispatch(%{
        "type" => "thread.pull-request.link",
        "host" => "github.com",
        "repository" => "acme/app",
        "number" => n,
        "url" => "https://github.com/acme/app/pull/#{n}",
        "source" => "manual"
      })
    end)
  end

  def unlink(n) do
    observe(fn ->
      dispatch(%{
        "type" => "thread.pull-request.unlink",
        "host" => "github.com",
        "repository" => "acme/app",
        "number" => n
      })
    end)
  end

  # What `HalC2.PullRequests.Sync` writes of what the host said; the signed-in account
  # is monalisa.
  def sync(n, snapshot) do
    activity =
      if snapshot.act > 0,
        do: %{"at" => at(snapshot.act), "author" => "owner-1", "kind" => "comment"}

    own =
      if snapshot.own > 0,
        do: %{"at" => at(snapshot.own), "author" => "monalisa", "kind" => "comment"}

    observe(fn ->
      dispatch(%{
        "type" => "thread.pull-request-link.sync",
        "host" => "github.com",
        "repository" => "acme/app",
        "number" => n,
        "snapshot" => %{
          "state" => snapshot.state,
          "title" => "PR #{n}",
          "isDraft" => false,
          "updatedAt" => at(0),
          "mergedAt" => if(snapshot.state == "merged", do: at(0)),
          "closedAt" => if(snapshot.state in ["merged", "closed"], do: at(0)),
          "checksState" => snapshot.checks,
          "mergeability" => snapshot.merge,
          "activity" => activity,
          "ownActivity" => own
        },
        "stack" => nil
      })
    end)
  end

  def settle, do: observe(fn -> dispatch(%{"type" => "thread.settle"}) end)
  def unsettle, do: observe(fn -> dispatch(%{"type" => "thread.unsettle"}) end)
  def archive, do: observe(fn -> dispatch(%{"type" => "thread.archive"}) end)
  def unarchive, do: observe(fn -> dispatch(%{"type" => "thread.unarchive"}) end)

  def work(k, clock) do
    observe(fn ->
      commit([
        {"run", "run-#{k}",
         %{
           "id" => "run-#{k}",
           "ordinal" => k,
           "status" => "running",
           "startedAt" => at(clock, 500)
         }}
      ])
    end)
  end

  def finish(k, clock) do
    observe(fn ->
      commit([{"run", "run-#{k}", %{"status" => "completed", "completedAt" => at(clock, 500)}}])
    end)
  end

  def restart, do: observe(fn -> HalC2.Prop.restart_service(HalC2.Streams) end)

  def check, do: observe(fn -> Wakes.check(@thread) end)

  # The command's result, the wakes it sent, and whether the user decided the thread's
  # settledness by hand, which keeps it from settling on its own.
  defp observe(fun) do
    before = wakes()
    result = fun.()
    thread = StreamState.get(stream(), "thread")[@thread]
    {result, wakes() -- before, thread["settledOverride"] != nil}
  end

  defp wakes do
    for message <- StreamState.list(stream(), "message"),
        get_in(message, ["notification", "source", "kind"]) == "pull_request",
        do: message
  end

  defp dispatch(command) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(
        Map.merge(
          %{"commandId" => "cmd-#{System.unique_integer([:positive])}", "threadId" => @thread},
          command
        )
      )

    :ok
  end

  defp commit(entities) do
    {:ok, _} =
      HalC2.Streams.commit(
        @thread,
        :thread,
        for({kind, id, fields} <- entities, do: {kind, id, %{"s" => fields}})
      )

    :ok
  end

  defp stream, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@thread))

  defp at(second, ms \\ 0),
    do: @base |> DateTime.add(second * 1000 + ms, :millisecond) |> DateTime.to_iso8601()
end
