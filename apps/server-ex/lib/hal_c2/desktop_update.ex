defmodule HalC2.DesktopUpdate do
  @moduledoc """
  Updates the HAL-C2 desktop app that started this MC (`HAL_C2_DESKTOP_HOST=1`), for
  clients that ask this MC to update itself (`serverSelfUpdate` "desktop-managed").

  The desktop app's socket subscribes to `desktopUpdateControl` (`attach/1`) and is
  sent `requestDesktopUpdate`, `commitDesktopUpdate` and `cancelDesktopUpdate`
  messages as `{:hal_c2_desktop_update_control, mc, message}`. It answers with
  `server.reportDesktopUpdateStatus` reports (`report/1`): one when it connects, and
  one on every change of its updater, carrying the `requestId` of the run it is in.

  One run at a time. Its stages ("downloading", then "installing") go to the
  requester's progress pid once each, as `HalC2.Upgrade` sends its own; the run ends
  when the desktop app has the update ready to install, is already current, fails,
  stops reporting, or takes longer than `:desktop_update_timeout`. A ready update is
  committed from here, and an install that fails, or says nothing within
  `:desktop_install_timeout`, is recorded as the update's outcome
  (`HalC2.Upgrade.desktop_failed/1`). A requester that goes away cancels its run.

  The latest report is held in memory only: after a restart the desktop app's
  connect report says where it is.

  Ported from upstream `apps/server/src/desktopUpdate/DesktopAppUpdate.ts`.
  """

  use GenServer

  @update_timeout :timer.minutes(20)
  @install_timeout :timer.minutes(2)
  @unavailable "This server was not started by the HAL-C2 desktop app, so it cannot drive a desktop update."

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Whether the desktop app started this MC and so drives its updates."
  def available?, do: System.get_env("HAL_C2_DESKTOP_HOST") == "1"

  @doc "How long a run may take before it times out (`:desktop_update_timeout`)."
  def update_timeout, do: Application.get_env(:hal_c2, :desktop_update_timeout, @update_timeout)

  @doc "How long a committed update may go without a result (`:desktop_install_timeout`)."
  def install_timeout,
    do: Application.get_env(:hal_c2, :desktop_install_timeout, @install_timeout)

  @doc """
  Asks the desktop app to update. `progress` gets the run's stages; the run is
  cancelled when `owner` (the caller when nil) exits or `abandon/1`s it.
  `{:ok, ServerSelfUpdateResult}` once the update is ready to install.
  """
  def update(progress \\ nil, owner \\ nil) do
    if available?(),
      do: GenServer.call(__MODULE__, {:update, progress, owner || self()}, :infinity),
      else: failure(@unavailable)
  catch
    :exit, {:noproc, _} -> failure("Could not reach the HAL-C2 desktop app on this machine.")
  end

  @doc "Makes `pid`, the desktop app's socket, the one control messages go to."
  def attach(pid), do: GenServer.call(__MODULE__, {:attach, pid})

  @doc "The desktop app's socket `pid` stopped listening for control messages."
  def detach(pid), do: GenServer.cast(__MODULE__, {:detach, pid})

  @doc "`server.reportDesktopUpdateStatus` from the desktop app."
  def report(report), do: GenServer.cast(__MODULE__, {:report, report})

  @doc "`owner`'s client went away: its run, if one is in flight, is cancelled."
  def abandon(owner), do: GenServer.cast(__MODULE__, {:abandon, owner})

  @doc "The desktop app's latest report, nil before its first."
  def latest, do: GenServer.call(__MODULE__, :latest)

  @impl true
  def init(nil), do: {:ok, %{host: nil, latest: nil, run: nil, install: nil}}

  @impl true
  def handle_call({:update, progress, owner}, from, state) do
    cond do
      not available?() ->
        {:reply, failure(@unavailable), state}

      state.run ->
        {:reply, failure("A desktop app update is already in progress."), state}

      state.host == nil ->
        {:reply, failure("Could not reach the HAL-C2 desktop app on this machine."), state}

      true ->
        id = "desktop-update-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

        run = %{
          id: id,
          from: from,
          owner: owner,
          owner_ref: Process.monitor(owner),
          progress: progress,
          stage: nil,
          timer: deadline(update_timeout(), id, :update)
        }

        control(state, "requestDesktopUpdate", id)
        {:noreply, %{state | run: run}}
    end
  end

  def handle_call({:attach, pid}, _from, state) do
    if state.host, do: Process.demonitor(elem(state.host, 1), [:flush])
    {:reply, :ok, %{state | host: {pid, Process.monitor(pid)}}}
  end

  def handle_call(:latest, _from, state), do: {:reply, state.latest, state}

  @impl true
  def handle_cast({:detach, pid}, %{host: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, host_gone(state)}
  end

  def handle_cast({:detach, _pid}, state), do: {:noreply, state}

  def handle_cast({:report, report}, state) do
    state = %{state | latest: report}
    id = report["requestId"]

    cond do
      state.run && id == state.run.id -> {:noreply, run_report(state, report)}
      state.install && id == state.install.id -> {:noreply, install_report(state, report)}
      # The connect report, or one of a run that already ended.
      true -> {:noreply, state}
    end
  end

  def handle_cast({:abandon, owner}, %{run: %{owner: owner}} = state),
    do: {:noreply, cancel(state)}

  def handle_cast({:abandon, _owner}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, _, _, _}, %{host: {_, ref}} = state),
    do: {:noreply, host_gone(state)}

  def handle_info({:DOWN, ref, _, _, _}, %{run: %{owner_ref: ref}} = state),
    do: {:noreply, cancel(state)}

  def handle_info({:deadline, id, :update}, %{run: %{id: id}} = state) do
    control(state, "cancelDesktopUpdate", id)
    {:noreply, finish(state, failure("The desktop app did not finish the update in time."))}
  end

  def handle_info({:deadline, id, :install}, %{install: %{id: id}} = state),
    do:
      {:noreply,
       install_failed(state, "The desktop app did not report an install result in time.")}

  def handle_info(_message, state), do: {:noreply, state}

  # --- a run -------------------------------------------------------------------------

  defp run_report(state, %{"state" => desktop} = report) do
    case report["outcome"] do
      "ready-to-install" ->
        state = stage(state, "installing")
        run = state.run

        target =
          desktop["downloadedVersion"] || desktop["availableVersion"] ||
            desktop["currentVersion"]

        result = %{
          "targetVersion" => target,
          "method" => "desktop-app",
          "desktopUpdateToken" => run.id
        }

        state = finish(state, {:ok, result})
        control(state, "commitDesktopUpdate", run.id)

        install = %{
          id: run.id,
          from: desktop["currentVersion"],
          target: target,
          timer: deadline(install_timeout(), run.id, :install)
        }

        %{state | install: install}

      "up-to-date" ->
        finish(
          state,
          failure(
            "The HAL-C2 desktop app on this machine is already up to date on #{desktop["currentVersion"]}."
          )
        )

      "failed" ->
        finish(
          state,
          failure(report["reason"] || desktop["message"] || "The desktop app update failed.")
        )

      _ ->
        stage(state, stage_of(desktop["status"]))
    end
  end

  defp run_report(state, _report), do: state

  defp stage_of(status) when status in ~w(checking available downloading), do: "downloading"
  defp stage_of("downloaded"), do: "installing"
  defp stage_of(_status), do: nil

  # Each stage is told once, when it changes.
  defp stage(state, nil), do: state
  defp stage(%{run: %{stage: stage}} = state, stage), do: state

  defp stage(%{run: run} = state, stage) do
    if run.progress,
      do:
        send(
          run.progress,
          {:hal_c2_server_update, node(), %{"type" => "progress", "stage" => stage}}
        )

    %{state | run: %{run | stage: stage}}
  end

  defp host_gone(state) do
    state = %{state | host: nil}

    if state.run,
      do: finish(state, failure("The desktop app stopped reporting its update.")),
      else: state
  end

  defp cancel(state) do
    control(state, "cancelDesktopUpdate", state.run.id)
    finish(state, failure("The desktop app update was cancelled."))
  end

  defp finish(%{run: run} = state, reply) do
    Process.demonitor(run.owner_ref, [:flush])
    cancel_deadline(run.timer)
    GenServer.reply(run.from, reply)
    %{state | run: nil}
  end

  # --- after the commit --------------------------------------------------------------

  defp install_report(state, %{"outcome" => "failed"} = report) do
    reason =
      report["reason"] || report["state"]["message"] ||
        "The desktop app failed to install the update."

    install_failed(state, reason)
  end

  defp install_report(state, _report), do: state

  defp install_failed(%{install: install} = state, reason) do
    cancel_deadline(install.timer)

    HalC2.Upgrade.desktop_failed(%{
      "id" => install.id,
      "fromVersion" => install.from,
      "targetVersion" => install.target,
      "status" => "failed",
      "reason" => reason
    })

    %{state | install: nil}
  end

  # --- helpers -----------------------------------------------------------------------

  defp control(%{host: {pid, _}}, type, id),
    do:
      send(
        pid,
        {:hal_c2_desktop_update_control, node(),
         %{"version" => 1, "type" => type, "requestId" => id}}
      )

  defp control(_state, _type, _id), do: :ok

  defp deadline(:infinity, _id, _phase), do: nil
  defp deadline(ms, id, phase), do: Process.send_after(self(), {:deadline, id, phase}, ms)

  defp cancel_deadline(nil), do: :ok
  defp cancel_deadline(timer), do: Process.cancel_timer(timer)

  defp failure(reason), do: {:error, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}}
end
