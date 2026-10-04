defmodule HalC2.LoadBalancing do
  @moduledoc """
  Chooses the machine of the cluster a new thread starts on: of those that have a
  checkout of the project's repository and the thread's agent ready, the one with the
  most room, weighted by the user's preference.

  The MC a client is connected to chooses (`place/1`), with its own settings, so no
  client carries the rules and all of them balance alike. `loadBalancingEnabled` turns
  it on; `loadBalancingWeights` holds each machine's weight by environment id, from 0
  (never chosen: the user picks it by hand) to 100, 50 when unset. Every member answers
  for itself when asked (`offer/1`), so what is compared is how each machine is doing
  now; one that does not answer in time is not chosen.
  """

  alias HalC2.{Shell, ThreadArchive, ThreadMove}

  @weight 50
  # The user is waiting to start a thread: a machine that takes longer is passed over.
  @wait 1_000

  @doc """
  `hal-c2.placeThread`: where a new thread the user is starting in the project
  `projectId` of the machine `environmentId` should start, as that pair for the
  machine chosen (a project is one machine's, so the chosen machine's checkout has
  its own id). It is the user's own pick when balancing is off, when no other machine
  can take the thread, and when none has more room.
  """
  def place(%{"environmentId" => environment, "projectId" => project} = input) do
    settings = HalC2.Settings.settings()

    with true <- settings["loadBalancingEnabled"] == true,
         mc when mc != nil <- Shell.mc_for(environment),
         repository when is_binary(repository) <- repository(mc, project) do
      weights = settings["loadBalancingWeights"] || %{}
      online = [node() | Node.list()]

      members =
        for {member, %{"environmentId" => id}} <- Shell.environments(),
            member in online,
            weight = weight(weights[id]),
            weight > 0,
            do: {member, id, weight}

      request = %{"repository" => repository, "instanceId" => input["instanceId"]}

      offers =
        :erpc.multicall(
          for({member, _, _} <- members, do: member),
          __MODULE__,
          :offer,
          [request],
          @wait
        )

      placed =
        for {{_member, id, weight}, {:ok, %{"projectId" => offered} = offer}} <-
              Enum.zip(members, offers),
            is_binary(offered),
            score = weight * room(offer),
            score > 0 do
          # The user's own pick wins a tie, and keeps the checkout they picked.
          own = id == environment

          {{score, own},
           %{"environmentId" => id, "projectId" => if(own, do: project, else: offered)}}
        end

      case placed do
        [] -> {:ok, Map.take(input, ~w(environmentId projectId))}
        placed -> {:ok, placed |> Enum.max_by(&elem(&1, 0)) |> elem(1)}
      end
    else
      _ -> {:ok, Map.take(input, ~w(environmentId projectId))}
    end
  end

  @doc """
  What this MC has for a new thread in a repository: its checkout of it, whether the
  thread's agent can run here, and the machine's resources now.
  """
  def offer(%{"repository" => repository} = request) do
    project =
      Enum.find(ThreadArchive.local_projects(), fn project ->
        File.dir?(project["workspaceRoot"] || "") and
          ThreadArchive.repository(project["workspaceRoot"]) == repository
      end)

    instance = request["instanceId"]

    %{
      "projectId" => project && project["id"],
      "agent" => instance == nil or ThreadMove.agent(instance) == :ok,
      "resources" => project && resources()
    }
  end

  @doc "The repository a project of this MC is a checkout of, as `ThreadArchive.repository/1`."
  def repository(project_id) do
    project = Enum.find(ThreadArchive.local_projects(), &(&1["id"] == project_id))
    project && ThreadArchive.repository(project["workspaceRoot"])
  end

  defp repository(mc, project_id) do
    :erpc.call(mc, __MODULE__, :repository, [project_id], @wait)
  catch
    _, _ -> nil
  end

  # How much room a machine has: its idle processors, by the share of its memory that
  # is free. None when it is nearly out of either or cannot run the agent.
  defp room(%{
         "agent" => true,
         "resources" => %{
           "cpuUtilization" => cpu,
           "cpuCount" => count,
           "availableMemoryBytes" => available,
           "totalMemoryBytes" => total
         }
       })
       when is_number(cpu) and cpu < 0.95 and count > 0 and total > 0 and
              available / total > 0.05,
       do: count * (1 - cpu) * (available / total)

  defp room(_offer), do: 0

  defp weight(weight) when is_number(weight), do: weight
  defp weight(_unset), do: @weight

  defp resources do
    # Tests stand in for a machine's load.
    with nil <- Application.get_env(:hal_c2, :host_resources),
         {:ok, resources} <- HalC2.Diagnostics.host(),
         do: resources
  end
end
