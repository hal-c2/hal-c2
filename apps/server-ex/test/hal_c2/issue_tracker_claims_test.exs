for file <- ~w(triage issue_tracker),
    do: Code.require_file("../../../../plugins/issue-tracker/mc/#{file}.ex", __DIR__)

defmodule HalC2.IssueTrackerClaimsTest do
  @moduledoc """
  The apply claim's lifecycle in the issue tracker's server: a claimed run is
  released when the caller holding the claim dies, and a claim gone stale can
  be taken over — so no apply can strand a run in `applying`. The raise path
  is covered end to end by `features/source-control/issue-tracker.feature`
  ("An apply that raises leaves the run proposed, not applying").
  """
  use ExUnit.Case, async: false

  alias HalC2.Plugins
  alias HalC2Plugins.IssueTracker

  @moduletag :tmp_dir
  @manifest Path.expand("../../../../plugins/issue-tracker/plugin.json", __DIR__)
            |> File.read!()
            |> JSON.decode!()
  @settings Map.new(@manifest["settings"], &{&1["key"], &1["default"]})

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :bundled_plugins, [])
    start_supervised!(HalC2.Settings)
    start_supervised!(Plugins)
    start_supervised!(%{id: IssueTracker, start: {IssueTracker, :start_link, [@settings]}})

    run = %{
      "id" => "run-1",
      "action" => "followUp",
      "repository" => "acme/api",
      "number" => 7,
      "threadId" => "thread-1",
      "status" => "proposed",
      "createdAt" => 1,
      "summary" => "Asked.",
      "report" => %{
        "summary" => "Asked.",
        "items" => [%{"repository" => "acme/api", "number" => 7, "comment" => "More?"}]
      },
      "done" => [],
      "error" => nil
    }

    assert {:ok, _} = GenServer.call(IssueTracker, {:started, run})
    :ok
  end

  test "a dead claiming caller releases its run back to proposed" do
    test = self()

    caller =
      spawn(fn ->
        assert {:ok, %{"status" => "applying"}} =
                 GenServer.call(IssueTracker, {:claim_apply, "run-1"})

        send(test, :claimed)
        Process.sleep(:infinity)
      end)

    assert_receive :claimed
    assert status() == "applying"

    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, _}
    assert eventually(fn -> status() == "proposed" end)
  end

  test "a stale claim can be taken over while its caller still lives" do
    test = self()

    caller =
      spawn(fn ->
        assert {:ok, _} = GenServer.call(IssueTracker, {:claim_apply, "run-1"})
        send(test, :claimed)
        Process.sleep(:infinity)
      end)

    assert_receive :claimed
    assert {:error, _} = GenServer.call(IssueTracker, {:claim_apply, "run-1"})

    :sys.replace_state(IssueTracker, fn state ->
      put_in(state, [Access.key!(:claims), "run-1", Access.key!(:at)], 0)
    end)

    assert {:ok, %{"status" => "applying"}} =
             GenServer.call(IssueTracker, {:claim_apply, "run-1"})

    assert :ok = GenServer.call(IssueTracker, {:apply_failed, "run-1", "settled by the test"})
    assert status() == "proposed"

    Process.exit(caller, :kill)
  end

  defp status do
    IssueTracker
    |> GenServer.call(:snapshot)
    |> Map.fetch!("runs")
    |> Enum.find(&(&1["id"] == "run-1"))
    |> Map.fetch!("status")
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(), do: true, else: Process.sleep(10) && eventually(fun, attempts - 1)
  end
end
