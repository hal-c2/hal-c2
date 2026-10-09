defmodule HalC2.ThreadOrganizationPropTest do
  @moduledoc """
  A state machine over three threads driven through the commands that organize them
  (`features/mc/orchestration/thread-organization.feature`): settle, the automatic
  settle `HalC2.Orchestration.Settlement` sends, unsettle, snooze, unsnooze, pin, unpin
  and the two reorders; with archive, unarchive and delete, a message that starts a turn
  (which brings a settled or snoozed thread back), an interrupt that ends it, and a
  restart of the streams.

  The model keeps each thread's organization at the level of what the engine promises:
  its settled override, wake time, pin and its two order keys, and whether each time
  stamp is set. After every command the test compares the thread entity with the
  model, checks that every time stamp the command does not set anew kept its value
  (re-settling keeps when it settled, re-snoozing until the same time keeps when it
  snoozed, a re-pin and a reorder keep when it was pinned), that a refused command
  and the other threads changed nothing, and that the sidebar row shows the same
  organization as the thread.

  Turns run on the fake Codex app-server in `test/support/fake_codex.py`; every message
  says "wait", so its turn runs until it is interrupted or the thread is deleted.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Projection.JS

  @moduletag timeout: :infinity

  @threads ~w(t1 t2 t3)
  # Order keys a client writes, and ones it never would (empty, not a-z, ending in "a",
  # past the longest), which the engine refuses.
  @keys ~w(b n zz)
  @bad_keys ["", "na", "B0", String.duplicate("z", 65)]
  @bad_key "order key is not 1 to 64 letters a-z ending in b-z."
  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @active ~w(preparing starting running waiting)
  @wait_ms 10_000
  # The settled time an automatic settle carries: the thread's last activity.
  @auto_settled_at "2026-01-01T00:00:00.000Z"
  @organization ~w(settledOverride settledAt unsettledAt snoozedUntil snoozedAt pinnedAt
                   pinOrderKey activeOrderKey archivedAt deletedAt)
  @stamps ~w(settledAt unsettledAt snoozedAt pinnedAt archivedAt deletedAt)

  property "organizing threads keeps the fields and times the model expects",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("thread-organization")
        work = Path.join(home, "work")
        File.mkdir_p!(work)
        {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
        Process.put(:work, work)
        Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch,
          {Registry, keys: :unique, name: HalC2.Codex.Registry},
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
            id: :claude_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
            id: :acp_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Pi.Registry},
            id: :pi_registry
          ),
          {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one}
        ])

        subscribe()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :codex_command)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # threads: id -> %{status: :live | :archived | :deleted, running, override: nil |
  #   "settled" | "active", unsettled (whether unsettledAt is set), until: nil | :tomorrow
  #   | :next_week, pinned, pin_key, active_key}
  # next: numbers the messages sent.
  def initial_state, do: %{threads: %{}, next: 1}

  def command(%{threads: threads, next: next}) do
    tid = oneof(@threads)
    key = frequency([{3, oneof(@keys)}, {1, oneof(@bad_keys)}])

    always = [
      {3, {:call, __MODULE__, :create, [tid]}},
      {4, {:call, __MODULE__, :settle, [tid]}},
      {3, {:call, __MODULE__, :unsettle, [tid]}},
      {4, {:call, __MODULE__, :snooze, [tid, oneof([:tomorrow, :next_week])]}},
      {3, {:call, __MODULE__, :unsnooze, [tid]}},
      {4, {:call, __MODULE__, :pin, [tid, oneof([nil, key])]}},
      {3, {:call, __MODULE__, :unpin, [tid]}},
      {2, {:call, __MODULE__, :pin_reorder, [tid, key]}},
      {2, {:call, __MODULE__, :active_reorder, [tid, key]}},
      {1, {:call, __MODULE__, :archive, [tid]}},
      {1, {:call, __MODULE__, :unarchive, [tid]}},
      {1, {:call, __MODULE__, :delete, [tid]}}
    ]

    live = for {t, %{status: s}} <- threads, s != :deleted, do: t
    idle = for {t, %{running: false}} <- threads, t in live, do: t
    running = for {t, %{running: true}} <- threads, do: t
    candidates = for t <- idle, threads[t].status == :live, not threads[t].pinned, do: t

    frequency(
      always ++
        if(idle == [], do: [], else: [{3, {:call, __MODULE__, :send, [oneof(idle), "m#{next}"]}}]) ++
        if(running == [], do: [], else: [{3, {:call, __MODULE__, :interrupt, [oneof(running)]}}]) ++
        if(candidates == [],
          do: [],
          else: [{3, {:call, __MODULE__, :auto_settle, [oneof(candidates)]}}]
        ) ++
        if(threads == %{} or running != [],
          do: [],
          else: [{2, {:call, __MODULE__, :restart, []}}]
        )
    )
  end

  # A turn starts only on an idle thread, so its message never queues; the automatic
  # settle is only sent for a thread `Settlement` finds a candidate; the streams restart
  # with no turn running, which boot recovery would end.
  def precondition(%{threads: threads}, {:call, _, :send, [tid, _]}),
    do: match?(%{running: false, status: s} when s != :deleted, threads[tid])

  def precondition(%{threads: threads}, {:call, _, :interrupt, [tid]}),
    do: match?(%{running: true}, threads[tid])

  def precondition(%{threads: threads}, {:call, _, :auto_settle, [tid]}),
    do: match?(%{status: :live, running: false, pinned: false}, threads[tid])

  def precondition(%{threads: threads}, {:call, _, :restart, []}),
    do: threads != %{} and not Enum.any?(threads, fn {_, t} -> t.running end)

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :create, [tid]}) do
    if Map.has_key?(state.threads, tid),
      do: state,
      else:
        put_in(state.threads[tid], %{
          status: :live,
          running: false,
          override: nil,
          unsettled: false,
          until: nil,
          pinned: false,
          pin_key: nil,
          active_key: nil
        })
  end

  def next_state(state, _result, {:call, _, :send, _} = call),
    do: %{apply_command(state, call) | next: state.next + 1}

  def next_state(state, _result, {:call, _, :restart, []}), do: state
  def next_state(state, _result, call), do: apply_command(state, call)

  defp apply_command(state, {:call, _, fun, args} = call) do
    tid = List.first(args)

    case expected_reply(state, call) do
      :ok -> update_in(state.threads[tid], &organized(&1, fun, args))
      _ -> state
    end
  end

  # What a command the thread accepts does to it.
  defp organized(thread, fun, _) when fun in [:settle, :auto_settle],
    do: %{thread | override: "settled", unsettled: false, until: nil, pinned: false} |> unplace()

  defp organized(thread, :unsettle, _),
    do: %{thread | override: "active", unsettled: true}

  defp organized(thread, :snooze, [_, until]), do: %{thread | until: until}
  defp organized(thread, :unsnooze, _), do: %{thread | until: nil}

  defp organized(thread, :pin, [_, key]) do
    thread = if thread.pinned, do: thread, else: %{thread | pin_key: key}

    %{
      thread
      | pinned: true,
        until: nil,
        override: if(thread.override == "settled", do: "active", else: thread.override)
    }
  end

  defp organized(thread, :unpin, _), do: %{thread | pinned: false, pin_key: nil}
  defp organized(thread, :pin_reorder, [_, key]), do: %{thread | pin_key: key}
  defp organized(thread, :active_reorder, [_, key]), do: %{thread | active_key: key}
  defp organized(thread, :archive, _), do: %{thread | status: :archived}
  defp organized(thread, :unarchive, _), do: %{thread | status: :live}
  defp organized(thread, :delete, _), do: %{thread | status: :deleted, running: false}

  # A message brings the thread back: no override, no snooze, and when it was settled,
  # a record of when it was unsettled.
  defp organized(thread, :send, _) do
    %{
      thread
      | running: true,
        override: nil,
        until: nil,
        unsettled: thread.unsettled or thread.override == "settled"
    }
  end

  defp organized(thread, :interrupt, _), do: %{thread | running: false}

  defp unplace(thread), do: %{thread | pin_key: nil, active_key: nil}

  # The command's reply, as the engine decides it from the model.
  defp expected_reply(_state, {:call, _, :restart, []}), do: :ok

  defp expected_reply(state, {:call, _, :create, [tid]}),
    do: if(state.threads[tid], do: {:error, "Thread #{tid} already exists."}, else: :ok)

  defp expected_reply(state, {:call, _, :auto_settle, [tid]}) do
    if state.threads[tid].override == nil,
      do: :ok,
      else: {:error, "Thread #{tid} changed before automatic settlement."}
  end

  defp expected_reply(state, {:call, _, fun, [tid | rest]}) do
    thread = state.threads[tid]

    cond do
      thread == nil and fun == :interrupt -> {:error, "no running turn"}
      thread == nil -> {:error, "unknown thread #{tid}"}
      thread.status == :deleted and fun == :delete -> :ok
      thread.status == :deleted -> {:error, "Thread #{tid} is deleted."}
      true -> with :ok <- refusal(thread, fun, tid), do: key_refusal(fun, [tid | rest])
    end
  end

  defp refusal(%{status: :archived}, :archive, tid),
    do: {:error, "Thread #{tid} is already archived."}

  defp refusal(%{status: status}, :unarchive, tid) when status != :archived,
    do: {:error, "Thread #{tid} is not archived."}

  defp refusal(%{status: :archived}, fun, tid)
       when fun in [
              :settle,
              :unsettle,
              :snooze,
              :unsnooze,
              :pin,
              :unpin,
              :pin_reorder,
              :active_reorder
            ],
       do: {:error, "Thread #{tid} is archived."}

  defp refusal(%{running: true}, :settle, tid),
    do: {:error, "Thread #{tid} has active or blocked work and cannot be settled."}

  defp refusal(%{pinned: false}, :pin_reorder, tid),
    do: {:error, "Thread #{tid} is not pinned and cannot be reordered."}

  defp refusal(thread, :active_reorder, tid) when thread.pinned or thread.override == "settled",
    do: {:error, "Thread #{tid} is not active and cannot be reordered."}

  defp refusal(_thread, _fun, _tid), do: :ok

  # A command the thread's state allows is still refused for a key no client writes; a
  # pin need not carry one.
  defp key_refusal(fun, [tid, key])
       when fun in [:pin, :pin_reorder, :active_reorder] and key not in [nil | @keys],
       do: {:error, "Thread #{tid} #{@bad_key}"}

  defp key_refusal(_fun, _args), do: :ok

  # The stamps an accepted command sets anew; every other stamp keeps its value or is
  # cleared as the model says.
  defp fresh(thread, :settle, _),
    do: if(thread.override == "settled" and not thread.pinned, do: [], else: ["settledAt"])

  defp fresh(_thread, :auto_settle, _), do: ["settledAt"]

  defp fresh(thread, :unsettle, _),
    do: if(thread.override == "active", do: [], else: ["unsettledAt"])

  defp fresh(thread, :snooze, [_, until]),
    do: if(thread.until == until, do: [], else: ["snoozedAt"])

  defp fresh(thread, :pin, _), do: if(thread.pinned, do: [], else: ["pinnedAt"])
  defp fresh(_thread, :archive, _), do: ["archivedAt"]
  defp fresh(%{status: :deleted}, :delete, _), do: []
  defp fresh(_thread, :delete, _), do: ["deletedAt"]

  defp fresh(thread, :send, _),
    do: if(thread.override == "settled", do: ["unsettledAt"], else: [])

  defp fresh(_thread, _fun, _), do: []

  def postcondition(state, {:call, _, fun, args} = call, {reply, before, now}) do
    expected = expected_reply(state, call)
    next = next_state(state, nil, call)
    tid = List.first(args)

    checks =
      for t <- @threads do
        thread = next.threads[t]

        cond do
          thread == nil ->
            {t, now[t] == nil}

          t == tid and expected == :ok and fun not in [:create, :restart] ->
            {t, matches?(thread, now[t], before[t], fresh(state.threads[t], fun, args), fun)}

          fun == :create and t == tid and expected == :ok ->
            {t, matches?(thread, now[t], %{}, [], fun)}

          true ->
            # Untouched: the same organization, and the model still describes it.
            {t, now[t] == before[t] and matches?(thread, now[t], before[t], [], nil)}
        end
      end

    reply_ok? = reply == expected

    unless reply_ok?,
      do: IO.puts("#{fun} #{inspect(args)}: expected #{inspect(expected)}, got #{inspect(reply)}")

    for {t, false} <- checks,
        do:
          IO.puts(
            "#{fun} #{inspect(args)}: thread #{t}\n  before #{inspect(before[t])}\n  now    " <>
              "#{inspect(now[t])}\n  model  #{inspect(next.threads[t])}"
          )

    reply_ok? and Enum.all?(checks, fn {_, ok} -> ok end)
  end

  # The real thread's organization against the model: its values, which stamps are
  # set, the stamps the command did not set anew kept from before, and a sidebar row
  # that shows the same.
  defp matches?(_model, nil, _before, _fresh, _fun), do: false

  defp matches?(model, %{fields: real, row: row, running: running}, before, fresh, fun) do
    stamps_set =
      %{
        "settledAt" => model.override == "settled",
        "unsettledAt" => model.unsettled,
        "snoozedAt" => model.until != nil,
        "pinnedAt" => model.pinned,
        "archivedAt" => model.status in [:archived],
        "deletedAt" => model.status == :deleted
      }

    values? =
      real["settledOverride"] == model.override and
        real["snoozedUntil"] == wake_time(model.until) and
        real["pinOrderKey"] == model.pin_key and real["activeOrderKey"] == model.active_key and
        running == model.running

    stamps? =
      Enum.all?(@stamps, fn stamp ->
        cond do
          # A deleted thread keeps whether it was archived.
          stamp == "archivedAt" and model.status == :deleted ->
            real[stamp] == before.fields[stamp]

          not stamps_set[stamp] ->
            real[stamp] == nil

          stamp in fresh or before == %{} ->
            is_binary(real[stamp])

          true ->
            real[stamp] == before.fields[stamp]
        end
      end)

    auto? = fun != :auto_settle or real["settledAt"] == @auto_settled_at

    values? and stamps? and auto? and row == Map.delete(real, "activeOrderKey")
  end

  # --- commands ---------------------------------------------------------------------

  def create(tid) do
    observe(fn ->
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => tid,
        "projectId" => "project-1",
        "title" => "Thread #{tid}",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => Process.get(:work)
      })
    end)
  end

  def settle(tid), do: organize(tid, "thread.settle")
  def unsettle(tid), do: organize(tid, "thread.unsettle")

  def snooze(tid, until),
    do: organize(tid, "thread.snooze", %{"snoozedUntil" => wake_time(until)})

  def unsnooze(tid), do: organize(tid, "thread.unsnooze")

  def pin(tid, nil), do: organize(tid, "thread.pin")
  def pin(tid, key), do: organize(tid, "thread.pin", %{"orderKey" => key})

  def unpin(tid), do: organize(tid, "thread.unpin")
  def pin_reorder(tid, key), do: organize(tid, "thread.pin.reorder", %{"orderKey" => key})
  def active_reorder(tid, key), do: organize(tid, "thread.active.reorder", %{"orderKey" => key})
  def archive(tid), do: organize(tid, "thread.archive")
  def unarchive(tid), do: organize(tid, "thread.unarchive")
  def delete(tid), do: organize(tid, "thread.delete")

  # Sent as `Settlement` sends it: judged on the row as it is now.
  def auto_settle(tid) do
    snapshot_at = JS.iso(current(tid).updated_at)

    organize(tid, "thread.auto-settle", %{
      "snapshotAt" => snapshot_at,
      "settledAt" => @auto_settled_at
    })
  end

  def send(tid, msg) do
    observe(fn ->
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => tid,
        "messageId" => msg,
        "text" => "wait #{msg}",
        "attachments" => [],
        "dispatchMode" => %{"type" => "start_immediately"}
      })
    end)
  end

  def interrupt(tid) do
    observe(
      fn -> Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => tid}) end,
      tid
    )
  end

  # The streams stop and come back from the store.
  def restart do
    observe(fn ->
      HalC2.Prop.restart_service(HalC2.Streams)
      subscribe()
      {:ok, %{}}
    end)
  end

  defp organize(tid, type, fields \\ %{}),
    do:
      observe(fn ->
        Orchestration.dispatch(Map.merge(%{"type" => type, "threadId" => tid}, fields))
      end)

  # --- the real side ----------------------------------------------------------------

  # Every thread before and after `dispatch`, once no run is starting, and none is
  # running on `ending`, the thread whose turn the command ends.
  defp observe(dispatch, ending \\ nil) do
    before = organizations(nil)

    reply =
      case dispatch.() do
        {:ok, %{}} -> :ok
        {:error, message} -> {:error, message}
        other -> {:unexpected, other}
      end

    {reply, before, organizations(ending)}
  end

  defp organizations(ending) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    Map.new(@threads, &{&1, organization(&1, &1 == ending, deadline)})
  end

  defp subscribe, do: for(tid <- @threads, do: :ok = HalC2.Streams.subscribe(tid, self(), nil))

  defp current(tid), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))

  # Waits on the thread's stream until no run is on its way in or out, then reads the
  # thread's organization and the sidebar row the stream would write for it.
  defp organization(tid, ending?, deadline) do
    flush(tid)
    state = current(tid)
    statuses = for run <- StreamState.list(state, "run"), do: run["status"]
    moving = if ending?, do: @active, else: ~w(preparing starting)

    if Enum.any?(statuses, &(&1 in moving)) do
      receive do
        {:hal_c2_stream, ^tid, _} -> organization(tid, ending?, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> {:timeout, statuses}
      end
    else
      case StreamState.get(state, "thread")[tid] do
        nil ->
          nil

        thread ->
          {"thread", row} = HalC2.Projection.row(HalC2.Store.path(), tid, state)

          %{
            fields: Map.new(@organization, &{&1, JS.get(thread, &1)}),
            row: Map.new(@organization -- ["activeOrderKey"], &{&1, row[&1]}),
            running: Enum.any?(statuses, &(&1 in @active))
          }
      end
    end
  end

  defp flush(tid) do
    receive do
      {:hal_c2_stream, ^tid, _} -> flush(tid)
    after
      0 -> :ok
    end
  end

  # Wake times a case can always snooze until: 09:00 UTC tomorrow or a week later.
  defp wake_time(nil), do: nil
  defp wake_time(:tomorrow), do: "#{Date.add(Date.utc_today(), 1)}T09:00:00.000Z"
  defp wake_time(:next_week), do: "#{Date.add(Date.utc_today(), 8)}T09:00:00.000Z"
end
