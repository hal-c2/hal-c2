defmodule HalC2.Orchestration.DelegationTest do
  use ExUnit.Case, async: false

  alias HalC2.Orchestration.Delegation
  alias HalC2.StreamState

  @moduletag :tmp_dir
  @at "2026-09-23T10:00:00.000Z"

  setup %{tmp_dir: dir} do
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)

    for name <- [
          HalC2.Codex.Registry,
          HalC2.Claude.Registry,
          HalC2.Acp.Registry,
          HalC2.Pi.Registry
        ],
        do: start_supervised!({Registry, keys: :unique, name: name}, id: name)

    :ok
  end

  defp thread(id, extra \\ %{}) do
    {"thread", id,
     %{
       "s" =>
         Map.merge(
           %{"id" => id, "title" => id, "createdAt" => @at, "updatedAt" => @at},
           extra
         )
     }}
  end

  defp run(id, ordinal, status, extra \\ %{}) do
    {"run", id,
     %{
       "s" =>
         Map.merge(
           %{"id" => id, "ordinal" => ordinal, "status" => status, "requestedAt" => @at},
           extra
         )
     }}
  end

  # A parent working on `pr` with one task running in child `c`; the child has a
  # run in `child_status`.
  defp delegate(child_status, task_extra \\ %{}) do
    task =
      Map.merge(
        %{
          "id" => "task",
          "origin" => "app_owned",
          "childThreadId" => "c",
          "completionWake" => "always",
          "completionDelivery" => %{"state" => "pending", "observedByRunId" => nil},
          "status" => "running",
          "runId" => "pr",
          "startedAt" => @at
        },
        task_extra
      )

    {:ok, _} =
      HalC2.Streams.commit("p", :thread, [
        thread("p", %{"runtimeMode" => "full-access", "interactionMode" => "default"}),
        run("pr", 1, "running"),
        {"subagent", "task", %{"s" => task}},
        {"node", "task", %{"s" => %{"id" => "task", "kind" => "subagent", "status" => "running"}}}
      ])

    {:ok, _} =
      HalC2.Streams.commit("c", :thread, [
        thread("c", %{
          "lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => "p"}
        }),
        run("cr", 1, child_status, completed(child_status))
      ])

    :ok
  end

  defp completed(status) when status in ["running", "queued"], do: %{}
  defp completed(_), do: %{"completedAt" => @at}

  describe "a request the provider instance refuses" do
    test "ends the task failed instead of leaving it running" do
      delegate("running")

      assert {:error, _} =
               Delegation.request(%{
                 "parentThreadId" => "p",
                 "parentRunId" => "pr",
                 "task" => "x",
                 "modelSelection" => %{"instanceId" => "ghost", "model" => "m"}
               })

      failed =
        "p"
        |> HalC2.Streams.ensure()
        |> HalC2.Streams.Server.state()
        |> StreamState.list("subagent")
        |> Enum.find(&(&1["id"] != "task"))

      assert %{"status" => "failed", "completionDelivery" => %{"state" => "disposed"}} = failed
    end
  end
end
