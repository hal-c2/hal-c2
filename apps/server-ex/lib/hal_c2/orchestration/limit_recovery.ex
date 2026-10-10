defmodule HalC2.Orchestration.LimitRecovery do
  @moduledoc """
  Resumes threads a provider stopped on a usage limit. A thread whose latest run failed on a limit with a
  known reset is armed (`limitRecovery` on the thread) when the user asks for it or
  `autoResumeLimitedThreads` / `snoozeLimitedThreads` is on; once the reset passes an
  armed auto-resume sends "Continue where you left off.".

  The due work is derived from the threads' persisted failures and recovery choices,
  so a restart needs no timers restored: the sweep after it finds what became due
  while the MC was down. Archived, settled and waiting-on-you threads are left
  alone, and a newer run (the user sent a message) ends the opportunity.
  """

  use GenServer

  require Logger

  import HalC2.Projection.JS, only: [epoch_ms: 1]

  @interval 30_000

  @doc "Options: `interval`, the sweep period in ms, or nil for no timer."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    if interval, do: send(self(), :tick)
    {:ok, interval}
  end

  @impl true
  def handle_info(:tick, interval) do
    # An MC too slow to answer (a machine deep in swap) skips a sweep; the next finds the same work.
    try do
      sweep()
    catch
      :exit, {:timeout, _} = reason ->
        Logger.warning("limit recovery skipped: #{inspect(reason)}")
    end

    Process.send_after(self(), :tick, interval)
    {:noreply, interval}
  end

  @doc """
  Arms and resumes every limited thread on this MC as of `now_ms` (the clock by
  default); returns the commands dispatched. An MC without automatic actions
  (`HAL_C2_MC_NO_AUTO_ACTIONS`) dispatches none.
  """
  def sweep(now_ms \\ System.system_time(:millisecond)) do
    settings = HalC2.Settings.settings()
    auto_resume = settings["autoResumeLimitedThreads"] == true
    snooze = settings["snoozeLimitedThreads"] == true

    for {{mc, thread_id}, {"thread", row}} <- HalC2.Shell.rows(),
        Application.get_env(:hal_c2, :auto_actions, true),
        mc == node(),
        row["lastErrorClass"] == "usage_limit" or row["limitRecovery"] != nil,
        # Rows trail their streams; decide on the thread as it is now.
        shell =
          HalC2.Projection.Shell.thread_shell(HalC2.Streams.state(thread_id)),
        command = command(shell, auto_resume, now_ms, snooze),
        command != nil do
      case HalC2.Orchestration.dispatch(command) do
        {:ok, _} -> :ok
        error -> Logger.warning("limit recovery for #{thread_id} failed: #{inspect(error)}")
      end

      command
    end
  end

  @doc """
  The command that moves a limited thread's recovery on at `now_ms`: arming it, the
  continuation message once its reset passed, or nil. The failed run and its reset
  identify one opportunity.
  """
  def command(thread, auto_resume, now_ms, snooze \\ false) do
    reset_ms = epoch_ms(thread["usageLimitResetAt"])
    stopped_ms = epoch_ms(thread["latestRunCompletedAt"] || thread["updatedAt"])
    recovery = thread["limitRecovery"]

    cond do
      thread["status"] != "failed" or thread["lastErrorClass"] != "usage_limit" or
        thread["latestRunId"] == nil or reset_ms == nil or thread["archivedAt"] != nil or
        thread["settledOverride"] == "settled" or thread["pendingRuntimeRequest"] != nil ->
        nil

      # An already-expired window reported with a fresh failure cannot start a retry loop.
      stopped_ms != nil and reset_ms <= stopped_ms ->
        nil

      recovery["runId"] != thread["latestRunId"] or
          recovery["resetAt"] != thread["usageLimitResetAt"] ->
        if auto_resume or (snooze and reset_ms > now_ms) do
          %{
            "type" => "thread.metadata.update",
            "commandId" => "limit-arm:#{identity(thread, reset_ms)}",
            "threadId" => thread["id"],
            "limitRecovery" => %{
              "runId" => thread["latestRunId"],
              "resetAt" => thread["usageLimitResetAt"],
              "autoResume" => auto_resume,
              "snooze" => snooze and reset_ms > now_ms
            }
          }
        end

      recovery["autoResume"] != true or reset_ms > now_ms or
          (epoch_ms(thread["snoozedUntil"]) || 0) > now_ms ->
        nil

      true ->
        delivery = "#{identity(thread, reset_ms)}:#{recovery["requestId"] || "legacy"}"

        %{
          "type" => "message.dispatch",
          "commandId" => "limit-resume:#{delivery}",
          "messageId" => "limit-resume:#{delivery}",
          "threadId" => thread["id"],
          "usageLimitContinuationOfRunId" => thread["latestRunId"],
          "text" => "Continue where you left off.",
          "attachments" => [],
          "dispatchMode" => %{"type" => "start_immediately"},
          "createdBy" => "user",
          "creationSource" => "server"
        }
    end
  end

  defp identity(thread, reset_ms), do: "#{thread["id"]}:#{thread["latestRunId"]}:#{reset_ms}"
end
