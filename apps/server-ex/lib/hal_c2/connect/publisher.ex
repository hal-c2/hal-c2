defmodule HalC2.Connect.Publisher do
  @moduledoc """
  Publishes what this node's agents are doing to the HAL-C2 Connect relay, so the
  user's phone gets alerts and live activity (`AgentAwarenessRelay.ts`).

  It follows this node's thread rows in `HalC2.Shell` and turns each into the relay's
  activity state (`projectThreadAwarenessV2`): a phase, headline, project, thread,
  model and deep link, or nil when there is nothing to show. A state is signed by
  the environment key (`hal-c2-env-activity+jwt`) and published only when it differs
  from the last one published for the thread, ignoring `updatedAt`.

  The last published states are kept in the secret store, so a turn cut off by a
  restart (settled as interrupted before this starts) is withdrawn. A failed
  publish is retried after 1, 2, 4, 8 and 16 seconds, and any newer change to the
  thread publishes afresh. Nothing is published unless the node is linked and
  publishing is on (`HalC2.Connect.publish_target/0`).
  """

  use GenServer

  require Logger

  alias HalC2.Connect
  alias HalC2.Connect.{Jwt, Secrets}

  @state_version 1
  @published "cloud-published-agent-activity"
  @retry_delays [1_000, 2_000, 4_000, 8_000, 16_000]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns once every shell change made so far has been published (or skipped), so
  callers can observe the relay without waiting on time.
  """
  def drain do
    # The shell has sent every notification queued before this call once it answers.
    HalC2.Shell.online_nodes()
    GenServer.call(__MODULE__, :drain, 30_000)
  end

  @doc """
  The relay activity state for a thread row, or nil when it shows nothing
  (`projectThreadAwarenessV2`; a failure's detail never carries the provider's error).
  """
  def awareness(environment_id, row, project_title) do
    phase = phase(row)

    if phase && project_title && row["deletedAt"] == nil && row["archivedAt"] == nil do
      state = %{
        "environmentId" => environment_id,
        "threadId" => row["id"],
        "projectTitle" => project_title,
        "threadTitle" => row["title"],
        "phase" => phase,
        "headline" => headline(phase),
        "modelTitle" => get_in(row, ["modelSelection", "model"]),
        "updatedAt" => row["updatedAt"],
        "deepLink" => "/threads/#{segment(environment_id)}/#{segment(row["id"])}"
      }

      case phase do
        "completed" -> Map.put(state, "detail", "Review the completed task.")
        "failed" -> Map.put(state, "detail", "The agent run failed.")
        _ -> state
      end
    end
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ok = HalC2.Shell.subscribe(self())
    published = with json when is_binary(json) <- Secrets.get(@published), do: JSON.decode!(json)

    {:ok, %{version: @state_version, published: published || %{}, retries: %{}},
     {:continue, :snapshot}}
  end

  # Threads that show activity now, and those last published live, which may have
  # ended while the node was stopped.
  @impl true
  def handle_continue(:snapshot, state) do
    ids =
      for({{node, id}, {"thread", _}} <- HalC2.Shell.rows(), node == node(), do: id) ++
        Map.keys(state.published)

    {:noreply, ids |> Enum.uniq() |> Enum.reduce(state, &publish/2)}
  end

  @impl true
  def handle_call(:drain, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:hal_c2_shell, {:rows, node, rows}}, state) when node == node() do
    ids = for {id, {"thread", _}} <- rows, do: id
    {:noreply, Enum.reduce(ids, state, &publish(&1, cancel_retry(&2, &1)))}
  end

  def handle_info({:retry, id, attempt}, state) do
    if get_in(state, [:retries, id]) == attempt,
      do: {:noreply, publish(id, state)},
      else: {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, %{state | version: @state_version}}

  # --- publishing ---------------------------------------------------------------

  defp publish(id, state) do
    case Connect.publish_target() do
      nil ->
        # Turning publishing back on (or relinking) publishes every state again.
        if state.published == %{}, do: state, else: forget(state)

      target ->
        environment_id = HalC2.Environment.id()
        activity = activity(environment_id, id)
        identity = identity(activity)

        if Map.get(state.published, id) == identity or
             (activity == nil and not Map.has_key?(state.published, id)) do
          %{state | retries: Map.delete(state.retries, id)}
        else
          send_activity(state, target, environment_id, id, activity, identity)
        end
    end
  end

  defp send_activity(state, target, environment_id, id, activity, identity) do
    {_public, private} = Jwt.key_pair()
    now = System.os_time(:second)

    proof =
      Jwt.sign(
        %{
          "iss" => "hal-c2-env:" <> environment_id,
          "aud" => Connect.normalize_issuer(target.issuer),
          "sub" => environment_id,
          "jti" => Connect.uuid(),
          "iat" => now,
          "exp" => now + 300,
          "environmentId" => environment_id,
          "threadId" => id,
          "state" => activity
        },
        "hal-c2-env-activity+jwt",
        private
      )

    url =
      "#{String.trim_trailing(target.relay_url, "/")}/v1/environments/#{segment(environment_id)}/threads/#{segment(id)}/agent-activity"

    case Connect.relay(:post, url, target.credential, %{"state" => activity, "proof" => proof}) do
      {:ok, _} ->
        published =
          if activity == nil,
            do: Map.delete(state.published, id),
            else: Map.put(state.published, id, identity)

        Secrets.put(@published, JSON.encode!(published))
        %{state | published: published, retries: Map.delete(state.retries, id)}

      failure ->
        Logger.warning("agent activity publish failed for #{id}: #{inspect(failure)}")
        schedule_retry(state, id)
    end
  end

  defp schedule_retry(state, id) do
    attempt = Map.get(state.retries, id, 0) + 1

    case Enum.at(@retry_delays, attempt - 1) do
      nil ->
        Logger.warning("agent activity publish retry budget exhausted for #{id}")
        state

      delay ->
        Process.send_after(self(), {:retry, id, attempt}, delay)
        put_in(state, [:retries, id], attempt)
    end
  end

  # Fresh activity replaces a pending retry.
  defp cancel_retry(state, id), do: %{state | retries: Map.delete(state.retries, id)}

  defp forget(state) do
    Secrets.delete(@published)
    %{state | published: %{}, retries: %{}}
  end

  defp activity(environment_id, id) do
    with {"thread", row} <- HalC2.Shell.row(node(), id),
         false <- get_in(row, ["lineage", "relationshipToParent"]) == "subagent" do
      project =
        case HalC2.Shell.row(node(), row["projectId"]) do
          {"project", project} -> project["title"]
          _ -> nil
        end

      awareness(environment_id, row, project)
    else
      _ -> nil
    end
  end

  # The state without its timestamp: a newer `updatedAt` alone is not news.
  defp identity(nil), do: "null"
  defp identity(activity), do: activity |> Map.delete("updatedAt") |> JSON.encode!()

  defp phase(row) do
    case row["pendingRuntimeRequest"] do
      %{"kind" => "user_input"} ->
        "waiting_for_input"

      %{"kind" => kind} when kind != "auth_refresh" ->
        "waiting_for_approval"

      _ ->
        case row["activityRunStatus"] || row["status"] do
          status when status in ["preparing", "starting"] -> "starting"
          status when status in ["running", "waiting"] -> "running"
          "completed" -> "completed"
          "failed" -> "failed"
          _ -> nil
        end
    end
  end

  defp headline("starting"), do: "Starting agent"
  defp headline("running"), do: "Agent is working"
  defp headline("waiting_for_approval"), do: "Approval needed"
  defp headline("waiting_for_input"), do: "Waiting for input"
  defp headline("completed"), do: "Agent finished"
  defp headline("failed"), do: "Agent failed"

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
