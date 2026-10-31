defmodule HalC2.DesktopUpdatePropTest do
  @moduledoc """
  `HalC2.DesktopUpdate` against a model of the desktop app that started the MC: clients
  ask for updates, the desktop app reports its updater's stages and outcomes (for the
  run in flight, a run that already ended, or none), requesters go away or abandon
  their run, deadlines pass, and the desktop app's socket detaches and attaches again.

  This test is the desktop app's socket and the requesters' progress pid; each
  requester is a process of its own that the service monitors. The test makes the
  requests' calls itself (`$gen_call` with the requester as owner), so the replies, the
  control messages and the stages all reach it before the call that ends each command.
  The promises checked:

    * one run at a time: a request while one is in flight, or with no desktop app
      listening, is refused;
    * each run's stages ("downloading", then "installing") are told once each, and only
      reports carrying its requestId move it;
    * a run ends with the update ready (its result carries the run's token, and the
      update is committed), already current, failed, cancelled when its requester goes
      away or abandons it, timed out, or failed when the desktop app stops listening;
    * after the commit, a failed install or none within the deadline is recorded as the
      update's outcome; reports of other runs change nothing;
    * the latest report is kept.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.DesktopUpdate

  @moduletag timeout: :infinity

  @busy "A desktop app update is already in progress."
  @unreachable "Could not reach the HAL-C2 desktop app on this machine."
  @gone "The desktop app stopped reporting its update."
  @cancelled "The desktop app update was cancelled."
  @late "The desktop app did not finish the update in time."
  @install_late "The desktop app did not report an install result in time."
  @message "The updater stopped."
  @reason "The download failed."

  property "the desktop app runs one update at a time and says how each ended",
    numtests: HalC2.Prop.numtests(200),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("desktop-update")
        previous = System.get_env("HAL_C2_DESKTOP_HOST")
        System.put_env("HAL_C2_DESKTOP_HOST", "1")
        Application.put_env(:hal_c2, :desktop_update_timeout, :infinity)
        Application.put_env(:hal_c2, :desktop_install_timeout, :infinity)
        :persistent_term.erase({HalC2.Upgrade, :outcome})
        Process.put(:ids, %{})
        Process.put(:owners, %{})
        Process.put(:refs, %{})
        drain()

        HalC2.Prop.start_services([DesktopUpdate])
        :ok = DesktopUpdate.attach(self())

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            HalC2.Prop.stop_services()
            Enum.each(Process.get(:owners), fn {_, pid} -> Process.exit(pid, :kill) end)

            if previous,
              do: System.put_env("HAL_C2_DESKTOP_HOST", previous),
              else: System.delete_env("HAL_C2_DESKTOP_HOST")

            Application.delete_env(:hal_c2, :desktop_update_timeout)
            Application.delete_env(:hal_c2, :desktop_install_timeout)
            :persistent_term.erase({HalC2.Upgrade, :outcome})
            File.rm_rf!(home)
            drain()
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # next: the number of the next request; started: the runs the desktop app was asked
  # for; host: whether its socket is attached; run: the run in flight `%{n, stage}`;
  # install: the committed run awaiting its result; outcome: the last recorded
  # `{run, reason}`.
  def initial_state,
    do: %{next: 1, started: [], host: true, run: nil, install: nil, outcome: nil}

  def command(state) do
    frequency(
      [
        {3, {:call, __MODULE__, :request, [state.next]}},
        {6, {:call, __MODULE__, :report, [report_target(state), report()]}},
        {1, {:call, __MODULE__, :abandon_other, []}},
        {1, {:call, __MODULE__, :detach, []}},
        {1, {:call, __MODULE__, :attach, []}}
      ] ++
        if(state.run,
          do: [
            {1, {:call, __MODULE__, :abandon, [state.run.n]}},
            {1, {:call, __MODULE__, :owner_exit, [state.run.n]}}
          ],
          else: []
        ) ++
        if(state.started == [],
          do: [],
          else: [
            {1,
             {:call, __MODULE__, :deadline, [oneof(state.started), oneof([:update, :install])]}}
          ]
        )
    )
  end

  defp report_target(%{started: []}), do: :none
  defp report_target(state), do: oneof([:none | state.started])

  defp report,
    do:
      oneof([
        {oneof(~w(idle checking available downloading downloaded)), nil, false},
        {"downloaded", "ready-to-install", false},
        {"idle", "up-to-date", false},
        {"error", "failed", boolean()}
      ])

  def precondition(state, {:call, _, :request, [n]}), do: n == state.next
  def precondition(state, {:call, _, :report, [n, _]}), do: n == :none or n in state.started
  def precondition(state, {:call, _, :abandon, [n]}), do: state.run != nil and state.run.n == n

  # The requester's exit is seen by the cancel it sends the desktop app.
  def precondition(state, {:call, _, :owner_exit, [n]}),
    do: state.host and state.run != nil and state.run.n == n

  def precondition(state, {:call, _, :deadline, [n, _]}), do: n in state.started
  def precondition(_state, _call), do: true

  def next_state(state, _result, call), do: elem(step(state, call), 0)

  def postcondition(state, call, seen) do
    {_, expected} = step(state, call)

    if seen == expected do
      true
    else
      IO.puts("expected #{inspect(expected)}, got #{inspect(seen)}")
      false
    end
  end

  # The model's next state and what the test sees for one command: the control
  # messages `{type, run}`, the stages, the replies `{run, reply}`, the recorded outcome.
  defp step(state, {:call, _, :request, [n]}) do
    state = %{state | next: n + 1}

    cond do
      state.run ->
        seen(state, replies: [{n, {:error, @busy}}])

      not state.host ->
        seen(state, replies: [{n, {:error, @unreachable}}])

      true ->
        seen(%{state | run: %{n: n, stage: nil}, started: [n | state.started]},
          controls: [{"requestDesktopUpdate", n}]
        )
    end
  end

  defp step(%{run: %{n: n}} = state, {:call, _, :report, [n, report]}),
    do: run_report(state, report)

  defp step(%{install: n} = state, {:call, _, :report, [n, {_, "failed", reason?}]}),
    do: seen(%{state | install: nil, outcome: {n, reason(reason?)}})

  defp step(state, {:call, _, :report, _}), do: seen(state)

  defp step(state, {:call, _, :abandon, [n]}) do
    state
    |> finish({:error, @cancelled})
    |> seen(
      controls: control(state, "cancelDesktopUpdate", n),
      replies: [{n, {:error, @cancelled}}]
    )
  end

  defp step(state, {:call, _, :owner_exit, [n]}),
    do:
      seen(finish(state, nil),
        controls: [{"cancelDesktopUpdate", n}],
        # The test made the call for the requester, so it still hears the reply.
        replies: [{n, {:error, @cancelled}}]
      )

  defp step(state, {:call, _, :abandon_other, []}), do: seen(state)

  defp step(%{run: %{n: n}} = state, {:call, _, :deadline, [n, :update]}),
    do:
      seen(finish(state, nil),
        controls: control(state, "cancelDesktopUpdate", n),
        replies: [{n, {:error, @late}}]
      )

  defp step(%{install: n} = state, {:call, _, :deadline, [n, :install]}),
    do: seen(%{state | install: nil, outcome: {n, @install_late}})

  defp step(state, {:call, _, :deadline, _}), do: seen(state)

  defp step(%{run: %{n: n}} = state, {:call, _, :detach, []}),
    do: seen(%{finish(state, nil) | host: false}, replies: [{n, {:error, @gone}}])

  defp step(state, {:call, _, :detach, []}), do: seen(%{state | host: false})
  defp step(state, {:call, _, :attach, []}), do: seen(%{state | host: true})

  defp run_report(%{run: run} = state, {status, nil, _}) do
    case stage_of(status) do
      stage when stage in [nil, run.stage] -> seen(state)
      stage -> seen(%{state | run: %{run | stage: stage}}, stages: [stage])
    end
  end

  defp run_report(%{run: run} = state, {_, "ready-to-install", _}) do
    stages = if run.stage == "installing", do: [], else: ["installing"]

    seen(%{finish(state, nil) | install: run.n},
      stages: stages,
      replies: [{run.n, {:ok, run.n, "1.1.0"}}],
      controls: control(state, "commitDesktopUpdate", run.n)
    )
  end

  defp run_report(%{run: run} = state, {_, "up-to-date", _}),
    do:
      seen(finish(state, nil),
        replies: [
          {run.n,
           {:error, "The HAL-C2 desktop app on this machine is already up to date on 1.0.0."}}
        ]
      )

  defp run_report(%{run: run} = state, {_, "failed", reason?}),
    do: seen(finish(state, nil), replies: [{run.n, {:error, reason(reason?)}}])

  defp stage_of(status) when status in ~w(checking available downloading), do: "downloading"
  defp stage_of("downloaded"), do: "installing"
  defp stage_of(_status), do: nil

  defp reason(true), do: @reason
  defp reason(false), do: @message

  defp finish(state, _reply), do: %{state | run: nil}

  defp control(%{host: true}, type, n), do: [{type, n}]
  defp control(_state, _type, _n), do: []

  defp seen(state, observed \\ []) do
    {state,
     %{
       controls: Keyword.get(observed, :controls, []),
       stages: Keyword.get(observed, :stages, []),
       replies: Keyword.get(observed, :replies, []),
       outcome: state.outcome
     }}
  end

  # --- system under test ----------------------------------------------------------

  # The call `DesktopUpdate.update/2` makes, made here so its reply comes back to the
  # test, with a requester the service monitors.
  def request(n) do
    owner = spawn(fn -> receive(do: (:stop -> :ok)) end)
    ref = make_ref()
    Process.put(:owners, Map.put(Process.get(:owners), n, owner))
    Process.put(:refs, Map.put(Process.get(:refs), ref, n))
    send(DesktopUpdate, {:"$gen_call", {self(), ref}, {:update, self(), owner}})
    observe(n)
  end

  def report(n, {status, outcome, reason?}) do
    report = %{
      "version" => 1,
      "type" => "desktopUpdateStatus",
      "requestId" => Process.get(:ids)[n],
      "outcome" => outcome,
      "reason" => if(reason?, do: @reason),
      "state" => %{
        "status" => status,
        "currentVersion" => "1.0.0",
        "availableVersion" => "1.1.0",
        "downloadedVersion" => if(status == "downloaded", do: "1.1.0"),
        "message" => @message
      }
    }

    DesktopUpdate.report(report)
    seen = observe()
    true = DesktopUpdate.latest() == report
    seen
  end

  def abandon(n) do
    DesktopUpdate.abandon(Process.get(:owners)[n])
    observe()
  end

  def abandon_other do
    DesktopUpdate.abandon(self())
    observe()
  end

  def owner_exit(n) do
    Process.exit(Process.get(:owners)[n], :kill)
    id = Process.get(:ids)[n]

    receive do
      {:hal_c2_desktop_update_control, _, %{"type" => "cancelDesktopUpdate", "requestId" => ^id}} ->
        send(
          self(),
          {:hal_c2_desktop_update_control, node(),
           %{"type" => "cancelDesktopUpdate", "requestId" => id}}
        )
    after
      5_000 -> :no_cancel
    end

    observe()
  end

  def deadline(n, phase) do
    send(DesktopUpdate, {:deadline, Process.get(:ids)[n], phase})
    observe()
  end

  def detach do
    DesktopUpdate.detach(self())
    observe()
  end

  def attach do
    :ok = DesktopUpdate.attach(self())
    observe()
  end

  # Everything the service sent this command, once a call shows it has handled it.
  defp observe(pending \\ nil) do
    DesktopUpdate.latest()
    gather(pending, %{controls: [], stages: [], replies: []})
  end

  defp gather(pending, seen) do
    refs = Process.get(:refs)

    receive do
      {:hal_c2_desktop_update_control, _, %{"type" => type, "requestId" => id}} ->
        if type == "requestDesktopUpdate",
          do: Process.put(:ids, Map.put(Process.get(:ids), pending, id))

        gather(pending, %{seen | controls: seen.controls ++ [{type, run_of(id)}]})

      {:hal_c2_server_update, _, %{"type" => "progress", "stage" => stage}} ->
        gather(pending, %{seen | stages: seen.stages ++ [stage]})

      {ref, reply} when is_reference(ref) and is_map_key(refs, ref) ->
        n = refs[ref]
        gather(pending, %{seen | replies: seen.replies ++ [{n, summary(reply)}]})
    after
      0 -> Map.put(seen, :outcome, outcome())
    end
  end

  defp summary(
         {:ok,
          %{"desktopUpdateToken" => id, "targetVersion" => target, "method" => "desktop-app"}}
       ),
       do: {:ok, run_of(id), target}

  defp summary({:error, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}}),
    do: {:error, reason}

  defp summary(other), do: other

  defp outcome do
    case HalC2.Upgrade.outcome() do
      nil -> nil
      %{"id" => id, "status" => "failed", "reason" => reason} -> {run_of(id), reason}
    end
  end

  defp run_of(id) do
    Enum.find_value(Process.get(:ids), id, fn {n, run_id} -> if run_id == id, do: n end)
  end

  defp drain do
    receive do
      _ -> drain()
    after
      0 -> :ok
    end
  end
end
