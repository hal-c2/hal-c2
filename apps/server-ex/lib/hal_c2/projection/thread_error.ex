defmodule HalC2.Projection.ThreadError do
  @moduledoc """
  The error a thread shows.

  Only a failed root turn of the latest run owns the thread's failure; a provider
  session error that says something different supersedes its classification while
  that run is the failed one.
  """

  import HalC2.Projection.JS, only: [get: 2, json: 1, epoch_ms: 1]

  @doc "The `failure` of the latest failed root error item of `run`, if it failed."
  @spec latest_root_provider_failure(map | nil, [map]) :: map | nil
  def latest_root_provider_failure(run, turn_items) do
    if get(run, "status") == "failed" do
      turn_items
      |> Enum.filter(fn item ->
        get(item, "type") == "error" and get(item, "status") == "failed" and
          get(item, "runId") == get(run, "id") and get(item, "nodeId") == get(run, "rootNodeId")
      end)
      |> Enum.reduce(nil, fn item, latest ->
        if latest == nil or later?(item, latest), do: item, else: latest
      end)
      |> get("failure")
      |> json()
    end
  end

  defp later?(item, latest) do
    {epoch_ms(get(item, "updatedAt")), get(item, "ordinal"), get(item, "id")} >
      {epoch_ms(get(latest, "updatedAt")), get(latest, "ordinal"), get(latest, "id")}
  end

  @doc """
  The shell's `usageLimitResetAt`, `lastError`, `lastErrorClass` and `lastErrorCode`
  (the provider's own code for it, such as a ChatGPT plan's sharing limit) for the thread's
  latest `run`. The provider session keeps its last error after later runs, so it
  counts only while that run failed (or before the thread has a run).
  """
  @spec summary(map | nil, map | nil, String.t() | nil) :: map
  def summary(run, failure, session_error) do
    session_error = if run == nil or get(run, "status") == "failed", do: session_error

    current =
      if session_error != nil and session_error != get(failure, "message"), do: nil, else: failure

    %{
      "usageLimitResetAt" =>
        if(get(current, "class") == "usage_limit", do: get(current, "resetAt")),
      "lastError" => session_error || get(failure, "message"),
      "lastErrorClass" => get(current, "class"),
      "lastErrorCode" => get(current, "code")
    }
  end
end
