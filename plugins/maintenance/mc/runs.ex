defmodule HalC2Plugins.Maintenance.Runs do
  @moduledoc """
  How a maintenance run moves, as pure steps from one run to the next. Each answers
  `{:ok, run}` or `{:error, message}` for a step its status does not allow.

      running ──report──▶ done | kept | waiting | publishing
       │  ▲                         │        ▲  │
       │  └─report─┐                └─claim──┘  ├─▶ published
       ├─turn ends unreported─▶ failed          └─▶ waiting (publishError)
       └─cancel─▶ cancelled

  A turn that ends without a report fails the run, but not for good: the user can
  continue its thread, and the report its agent then makes is kept as if the run
  had never stopped. A turn that ended at a usage limit leaves the run running, as
  the MC resumes it once the limit resets. `skipped` is a run that never started,
  because the repository already has an open maintenance pull request. A finished
  run can be dismissed, which hides it from the page; a dismissed run is never
  published and takes no report.
  """

  # A run holding its repository: no second run starts beside it. One waiting for
  # the user holds it too, so maintenance does not pile up unread branches.
  @holding ~w(running waiting publishing)
  @finished ~w(done kept waiting failed cancelled skipped published)

  def holding?(run), do: run["status"] in @holding and run["dismissed"] != true

  @doc "Whether a run's turn is still going, which is what counts toward runs at once."
  def working?(run), do: run["status"] == "running"

  @doc """
  Whether a run may still report: only once, while it runs or after a turn of it
  ended without reporting.
  """
  def reportable(%{"status" => "running"}), do: :ok

  def reportable(%{"dismissed" => true}),
    do: {:error, "This run was dismissed; your report is not kept."}

  def reportable(%{"status" => "failed", "unreported" => true}), do: :ok

  def reportable(%{"status" => "cancelled"}),
    do: {:error, "This run was cancelled; your report is not kept. Stop here."}

  def reportable(_run), do: {:error, "This run has already reported."}

  @doc """
  The status a run's report leaves it in. A run that applied nothing has nothing
  to publish; one that did waits for the user (`draft`), stays local (`local`), or
  is published at once (`automatic`, `publishing` until it is).
  """
  def reported(run, report, applied, body, publishing) do
    with :ok <- reportable(run), do: {:ok, reported_as(run, report, applied, body, publishing)}
  end

  defp reported_as(run, report, applied, body, publishing) do
    status =
      cond do
        run["mode"] == "report" or applied == 0 -> "done"
        publishing == "local" -> "kept"
        publishing == "automatic" -> "publishing"
        true -> "waiting"
      end

    run
    |> Map.merge(%{
      "status" => status,
      "report" => report,
      "body" => body,
      "applied" => applied,
      "error" => nil
    })
    |> Map.delete("unreported")
    |> finish()
  end

  @doc """
  The agent's turn ended (`class` is the failure's, if any): a run still running
  never reported, and failed until a report comes. One stopped at a usage limit is
  still running.
  """
  def finished(%{"status" => "running"} = run, _error, "usage_limit"), do: {:ok, run}

  def finished(%{"status" => "running"} = run, error, _class),
    do:
      {:ok,
       run
       |> Map.merge(%{"status" => "failed", "error" => error, "unreported" => true})
       |> finish()}

  def finished(run, _error, _class), do: {:ok, run}

  def cancel(%{"status" => "running"} = run),
    do: {:ok, run |> Map.put("status", "cancelled") |> finish()}

  def cancel(run),
    do: {:error, "That run is #{run["status"]}; only a running one can be cancelled."}

  def dismiss(%{"status" => status} = run) when status in @finished,
    do: {:ok, Map.put(run, "dismissed", true)}

  def dismiss(run), do: {:error, "That run is #{run["status"]}; cancel it first."}

  @doc "Takes a run for opening its pull request; a second publish waits it out."
  def claim(%{"dismissed" => true}), do: {:error, "That run was dismissed."}

  def claim(%{"status" => status} = run) when status in ~w(waiting kept),
    do: {:ok, Map.merge(run, %{"status" => "publishing", "publishError" => nil})}

  def claim(%{"status" => "publishing"}), do: {:error, "Its pull request is being opened."}

  def claim(run),
    do: {:error, "That run is #{run["status"]}; there is no pull request to open."}

  def published(%{"status" => "publishing"} = run, url),
    do: {:ok, Map.merge(run, %{"status" => "published", "prUrl" => url, "publishError" => nil})}

  def published(run, _url), do: {:error, "That run is #{run["status"]}, not publishing."}

  def publish_failed(%{"status" => "publishing"} = run, message),
    do: {:ok, Map.merge(run, %{"status" => "waiting", "publishError" => message})}

  def publish_failed(run, _message), do: {:error, "That run is #{run["status"]}, not publishing."}

  @doc """
  A run as the server finds it on starting again: one it was publishing waits for
  the user again (whether its pull request was opened, a retry tells), and one it
  was running stays running for its thread's turn to settle.
  """
  def revive(%{"status" => "publishing"} = run), do: Map.put(run, "status", "waiting")
  def revive(run), do: run

  # The run's turn is over, whatever is left to do with its branch.
  defp finish(run), do: Map.put(run, "finishedAt", System.system_time(:millisecond))
end
