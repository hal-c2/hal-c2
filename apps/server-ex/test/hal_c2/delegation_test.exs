defmodule HalC2.Orchestration.DelegationTest do
  use ExUnit.Case, async: false

  alias HalC2.Orchestration.{Delegation, Recovery}
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

    on_exit(fn -> Application.delete_env(:hal_c2, :delegation_hook) end)
    :ok
  end

  # Called by the code under test at its stages (`hook/2` in Delegation).
  def hook(fun, stage, id), do: fun.(stage, id)

  defp hook_with(fun),
    do: Application.put_env(:hal_c2, :delegation_hook, {__MODULE__, :hook, [fun]})

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

  defp task do
    "p"
    |> HalC2.Streams.ensure()
    |> HalC2.Streams.Server.state()
    |> StreamState.get("subagent")
    |> Map.get("task")
  end

  describe "a task whose child was interrupted at boot" do
    test "is interrupted when the project does not continue it" do
      :ok = HalC2.Shell.subscribe(self())
      delegate("running")
      assert_receive {:hal_c2_shell, {:rows, _, [{"c", {"thread", _}}]}}, 1_000

      assert "c" in Recovery.run()
      assert task()["status"] == "running"

      Recovery.continue()

      assert %{"status" => "interrupted", "completionDelivery" => %{"state" => "disposed"}} =
               task()
    end
  end

  describe "a task whose child thread was never created" do
    test "fails at boot but is left alone once a launch may be under way" do
      {:ok, _} =
        HalC2.Streams.commit("p", :thread, [
          thread("p"),
          {"subagent", "task",
           %{
             "s" => %{
               "id" => "task",
               "origin" => "app_owned",
               "childThreadId" => "c",
               "status" => "running",
               "completionDelivery" => %{"state" => "pending"}
             }
           }},
          {"node", "task",
           %{"s" => %{"id" => "task", "kind" => "subagent", "status" => "running"}}}
        ])

      assert Delegation.reconcile("p", false) == 0
      assert task()["status"] == "running"
      assert Delegation.reconcile("p") == 1
      assert %{"status" => "failed", "completionDelivery" => %{"state" => "disposed"}} = task()
    end
  end

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

  describe "a report that raises" do
    test "is retried and settles the task" do
      delegate("completed")
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      hook_with(fn
        :reporting, _ ->
          if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0, do: raise("busy")

        _, _ ->
          :ok
      end)

      assert Delegation.report("c", "cr", "completed", 2, 0) == :ok
      assert Agent.get(counter, & &1) == 2
      assert task()["status"] == "completed"
    end
  end
end
