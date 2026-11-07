defmodule HalC2.Steps.Orchestration.AutoSettle do
  @moduledoc """
  Steps for `features/mc/orchestration/auto-settle.feature`. The settlement
  service starts, without its timer, only once a step sweeps (or changes the
  settings), so the Given steps build a thread without a change-driven sweep
  settling it halfway through.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Orchestration.Settlement
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @hour 60 * 60 * 1_000

  step "auto-settle after {int} days and auto-settle on merge are on",
       %{args: [days]} = context do
    Mc.ensure(HalC2.Settings)

    write_settings(context, %{
      "sidebarAutoSettleAfterDays" => days,
      "sidebarAutoSettleOnMerge" => true
    })
  end

  step "auto-settle on merge is off", context do
    write_settings(context, %{"sidebarAutoSettleOnMerge" => false})
  end

  step "project {string} sets auto-settle after {int} day(s)", %{args: [title, days]} = context do
    id = World.project(context, title).id

    write_settings(context, %{
      "projectSettingsOverrides" => %{id => %{"sidebarAutoSettleAfterDays" => days}}
    })
  end

  step "the user changes auto-settle to {int} day(s)", %{args: [days]} = context do
    Mc.ensure({Settlement, interval: nil})
    write_settings(context, %{"sidebarAutoSettleAfterDays" => days})
  end

  step "thread {string} finished its last turn {int} days ago",
       %{args: [thread, days]} = context do
    finished(context, thread, -World.days(days) - 60_000)
  end

  step "thread {string} links a pull request that merged after the user last worked in it",
       %{args: [thread]} = context do
    context |> worked(thread, -@hour) |> link(thread) |> sync(thread, "merged", 0)
  end

  step "thread {string} links a pull request that closed after the user last worked in it",
       %{args: [thread]} = context do
    context |> worked(thread, -@hour) |> link(thread) |> sync(thread, "closed", 0)
  end

  step "thread {string} links a pull request that merged an hour ago",
       %{args: [thread]} = context do
    context
    |> ensure_thread(thread)
    |> World.patch_thread(thread, %{"createdAt" => World.iso_from_now(-2 * @hour)})
    |> link(thread)
    |> sync(thread, "merged", -@hour)
  end

  step "thread {string} links a pull request that merged yesterday",
       %{args: [thread]} = context do
    context
    |> ensure_thread(thread)
    |> World.patch_thread(thread, %{"createdAt" => World.iso_from_now(-World.days(2))})
    |> link(thread)
    |> sync(thread, "merged", -World.days(1))
  end

  step "the user sent a message in {string} today", %{args: [thread]} = context do
    World.add_message(context, thread, "user", "One more change", World.iso_from_now(-@hour))
  end

  step "thread {string} links an open pull request", %{args: [thread]} = context do
    context |> ensure_thread(thread) |> link(thread) |> sync(thread, "open", 0)
  end

  # Idle long enough to settle, so only the unsynced link holds it back.
  step "thread {string} links a pull request whose state is not known yet",
       %{args: [thread]} = context do
    context |> finished(thread, -World.days(10)) |> link(thread)
  end

  # Shared with threads, thread-organization and pull-request-links. As a Given it
  # archives the thread, creating it (named as its id) when the scenario has none;
  # otherwise it asserts.
  step "thread {string} is archived", %{args: [thread]} = context do
    if World.given?(context) do
      context =
        context
        |> Map.put(:thread, thread)
        |> Map.update(:threads, %{thread => thread}, &Map.put_new(&1, thread, thread))

      context =
        if World.thread(context, thread), do: context, else: World.named_thread(context, thread)

      update(context, thread, "thread.archive", &(&1["archivedAt"] != nil))
    else
      assert World.thread(context, thread)["archivedAt"] != nil
      context
    end
  end

  step "thread {string} was settled or unsettled by the user", %{args: [thread]} = context do
    update(context, thread, "thread.unsettle", &(&1["settledOverride"] == "active"))
  end

  step "thread {string} is pinned", %{args: [thread]} = context do
    update(context, thread, "thread.pin", &(&1["pinnedAt"] != nil))
  end

  step "thread {string} waits on an approval or a question", %{args: [thread]} = context do
    id = "rr-#{System.unique_integer([:positive])}"
    at = World.iso_from_now(0)

    context =
      World.put_entity(context, thread, "runtime-request", id, %{
        "s" => %{
          "id" => id,
          "threadId" => World.thread_id(context, thread),
          "kind" => "approval",
          "status" => "pending",
          "createdAt" => at,
          "updatedAt" => at
        }
      })

    World.await_row(World.thread_id(context, thread), &(&1["pendingRuntimeRequest"] != nil))
    context
  end

  step "thread {string} has a running turn", %{args: [thread]} = context do
    context = World.add_run(context, thread, "running")
    World.await_row(World.thread_id(context, thread), &(&1["activityRunStatus"] == "running"))
    context
  end

  step "thread {string} has background tasks still running", %{args: [thread]} = context do
    [run | _] = World.state(context, thread) |> HalC2.StreamState.list("run")
    id = "item-#{System.unique_integer([:positive])}"

    context =
      World.put_entity(context, thread, "turn-item", id, %{
        "s" => %{
          "id" => id,
          "threadId" => World.thread_id(context, thread),
          "runId" => run["id"],
          "type" => "command_execution",
          "status" => "running",
          "input" => "npm run dev"
        }
      })

    World.await_row(World.thread_id(context, thread), &(&1["pendingBackgroundTasks"] != []))
    context
  end

  step "thread {string} received a message less than two minutes ago",
       %{args: [thread]} = context do
    World.add_message(context, thread, "user", "Also this", World.iso_from_now(-30_000))
  end

  step "thread {string} is snoozed and has not woken since", %{args: [thread]} = context do
    World.patch_thread(context, thread, %{
      "snoozedAt" => World.iso_from_now(-@hour),
      "snoozedUntil" => World.iso_from_now(World.days(1))
    })
  end

  step "thread {string} was snoozed and a turn completed after the snooze",
       %{args: [thread]} = context do
    context
    |> ensure_thread(thread)
    |> World.patch_thread(thread, %{
      "createdAt" => World.iso_from_now(-2 * @hour),
      "snoozedAt" => World.iso_from_now(-@hour),
      "snoozedUntil" => World.iso_from_now(World.days(1))
    })
    |> World.add_run(thread, "completed", World.iso_from_now(-div(@hour, 2)))
  end

  step "its linked pull request merged after that", context do
    context |> link("t1") |> sync("t1", "merged", 0)
  end

  step "the MC sweeps for threads to settle", context do
    Mc.ensure({Settlement, interval: nil})
    :ok = Settlement.sweep()
    Map.put(context, :settle_swept, true)
  end

  step "its settled time is its last user activity", context do
    row = World.row(context, "t1")
    assert row["settledAt"] != nil

    assert HalC2.Projection.JS.epoch_ms(row["settledAt"]) ==
             HalC2.Projection.JS.epoch_ms(row["latestUserMessageAt"])

    context
  end

  step "thread {string} is not settled", %{args: [thread]} = context do
    assert World.thread(context, thread)["settledOverride"] != "settled"
    assert World.row(context, thread)["settledOverride"] != "settled"
    context
  end

  step "thread {string} is settled without waiting for the next periodic sweep",
       %{args: [thread]} = context do
    World.await_row(World.thread_id(context, thread), &(&1["settledOverride"] == "settled"))
    context
  end

  # The timer is the only thing that changes here: the service sweeps on its own
  # schedule, and "a minute passes" is the tick that schedule delivers. Backdating
  # the message changes no field the service watches, so no sweep starts by itself.
  step "thread {string} becomes eligible to settle", %{args: [thread]} = context do
    pid = Mc.ensure({Settlement, interval: 60_000})
    context = ensure_thread(context, thread)
    :ok = Settlement.sweep()
    at = World.iso_from_now(-World.days(4))

    context =
      context
      |> World.patch_thread(thread, %{"createdAt" => at})
      |> World.add_message(thread, "user", "Ship it", at)

    _ = :sys.get_state(pid)
    assert World.thread(context, thread)["settledOverride"] == nil
    Map.put(context, :settlement, pid)
  end

  step "a minute passes", context do
    if context[:settlement] do
      id = World.thread_id(context, "t1")
      send(context.settlement, :tick)
      World.await_row(id, &(&1["settledOverride"] == "settled"))
      Map.put(context, :settle_swept, true)
    else
      # The pull-request-links file shares this wording for discovery's tick.
      HalC2.Steps.Orchestration.PullRequestLinks.minute_passes(context)
    end
  end

  step "the MC decided to settle {string} from a snapshot", %{args: [thread]} = context do
    context = finished(context, thread, -World.days(4))
    Map.put(context, :auto_settle, auto_settle(context, thread))
  end

  step "thread {string} was updated after that snapshot", %{args: [thread]} = context do
    snapshot = HalC2.Projection.JS.epoch_ms(context.auto_settle["snapshotAt"])
    context = World.patch_thread(context, thread, %{"title" => "Renamed"})
    assert HalC2.Projection.JS.epoch_ms(World.row(context, thread)["updatedAt"]) > snapshot
    context
  end

  step "the auto-settle command runs", context do
    Map.put(context, :auto_settle_result, HalC2.Orchestration.dispatch(context.auto_settle))
  end

  step "the user unsettled {string}", %{args: [thread]} = context do
    context
    |> ensure_thread(thread)
    |> update(thread, "thread.unsettle", &(&1["settledOverride"] == "active"))
  end

  step "an auto-settle command for {string} runs", %{args: [thread]} = context do
    result = HalC2.Orchestration.dispatch(auto_settle(context, thread))
    Map.put(context, :auto_settle_result, result)
  end

  # An automatic settlement refused, or else the command the step before sent
  # (`context.reply`).
  step "the command is refused", context do
    case context do
      %{auto_settle_result: result} ->
        assert {:error, message} = result
        assert message =~ "changed before automatic settlement"

      %{reply: reply} ->
        assert elem(reply, 0) == :error, "expected a refusal, got #{inspect(reply)}"
    end

    context
  end

  step "thread {string} stays active by override", %{args: [thread]} = context do
    assert World.thread(context, thread)["settledOverride"] == "active"
    context
  end

  step "thread {string} was auto-settled", %{args: [thread]} = context do
    context = finished(context, thread, -World.days(4))
    Mc.ensure({Settlement, interval: nil})
    :ok = Settlement.sweep()
    World.await_row(World.thread_id(context, thread), &(&1["settledOverride"] == "settled"))
    context
  end

  # --- the per-thread switch ---------------------------------------------------------------

  step "thread {string} has auto-settle disabled", %{args: [thread]} = context do
    context
    |> ensure_thread(thread)
    |> set_auto_settle(thread, false, &(&1["autoSettleDisabledAt"] != nil))
  end

  step "the user settles {string} and then un-settles it", %{args: [thread]} = context do
    context
    |> update(thread, "thread.settle", &(&1["settledOverride"] == "settled"))
    |> update(thread, "thread.unsettle", &(&1["settledOverride"] == "active"))
  end

  step "{string} still has auto-settle disabled", %{args: [thread]} = context do
    assert World.thread(context, thread)["autoSettleDisabledAt"] != nil
    assert World.row(context, thread)["autoSettleDisabledAt"] != nil
    context
  end

  # --- several linked pull requests --------------------------------------------------------

  step "thread {string} links a pull request that merged an hour ago and another that is still open",
       %{args: [thread]} = context do
    context
    |> worked(thread, -2 * @hour)
    |> link(thread, 5)
    |> sync(thread, "merged", -@hour, 5)
    |> link(thread, 6)
    |> sync(thread, "open", 0, 6)
  end

  # Merged an hour after the thread began, an hour before the user's last message.
  step "thread {string} links a pull request that merged before the user's last message",
       %{args: [thread]} = context do
    context
    |> worked(thread, -@hour)
    |> link(thread, 5)
    |> sync(thread, "merged", -2 * @hour, 5)
  end

  step "thread {string} links another pull request that merged after it",
       %{args: [thread]} = context do
    context |> link(thread, 6) |> sync(thread, "merged", 0, 6)
  end

  # --- the branch's pull request -----------------------------------------------------------

  step "thread {string} is on a branch whose pull request merged after the user last worked in it",
       %{args: [thread]} = context do
    branch = "feature/#{thread}"

    context
    |> github()
    |> worked(thread, -@hour)
    |> World.patch_thread(thread, %{"branch" => branch})
    |> branch_answer(branch, 9, "MERGED", World.iso_from_now(0))
  end

  step "thread {string} links no pull request", %{args: [thread]} = context do
    row = World.row(context, thread)
    assert row["pullRequests"] in [nil, []]
    assert row["linkedPullRequest"] == nil
    assert row["branchPullRequest"] == nil
    context
  end

  step "the worktree of {string} has been removed", %{args: [thread]} = context do
    gone = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "gone-worktree"), "t1")
    refute File.exists?(gone)
    World.patch_thread(context, thread, %{"worktreePath" => gone})
  end

  step "the pull request is looked up from the folder of {string}",
       %{args: [project]} = context do
    calls = World.cli_calls(context, "pr list")
    assert [_ | _] = calls
    assert Enum.all?(calls, &(&1["cwd"] == World.project(context, project).root))
    context
  end

  # Discovery recorded #5 on the thread's branch; the host's summary read says it merged.
  step "the pull request of {string} merged after the user last worked in it",
       %{args: [thread]} = context do
    context
    |> github()
    |> worked(thread, -@hour)
    |> recorded_branch_pull_request(thread, "feature/#{thread}", 5)
    |> World.cli_rules(%{
      "args" => ["api graphql"],
      "stdin" => ["PullRequestSummaries"],
      "summaries" => %{"acme/app#5" => summary_node(5, "MERGED", World.iso_from_now(0))}
    })
  end

  step "the branch of {string} now has a new open pull request in the repository of {string}",
       %{args: [thread, _project]} = context do
    branch_answer(context, "feature/#{thread}", 9, "OPEN", nil)
  end

  # --- a merge the MC learns of ------------------------------------------------------------

  step "thread {string} belongs to pull request {int} and thread {string} to pull request {int}, both open",
       %{args: [first, first_number, second, second_number]} = context do
    context =
      for {thread, number} <- [{first, first_number}, {second, second_number}],
          reduce: context do
        context ->
          context
          |> worked(thread, -@hour)
          |> link(thread, number)
          |> sync(thread, "open", 0, number)
      end

    Map.put(context, :pull_request_threads, %{first_number => first, second_number => second})
  end

  step "the MC learns pull request {int} merged", %{args: [number]} = context do
    Mc.ensure({Settlement, interval: nil})
    sync(context, context.pull_request_threads[number], "merged", 0, number)
  end

  # --- lookups that fail -------------------------------------------------------------------

  step "the source control host cannot be reached", context do
    context
    |> github()
    |> recorded_branch_pull_request("t1", "feature/t1", 5)
    |> unreachable()
  end

  step "the pull request of {string} cannot be looked up", %{args: [thread]} = context do
    context
    |> github()
    |> worked(thread, -@hour)
    |> recorded_branch_pull_request(thread, "feature/#{thread}", 5)
    |> unreachable()
  end

  # --- what settling reads -----------------------------------------------------------------

  step "auto-settle after days and auto-settle on merge are both off for the environment",
       context do
    write_settings(context, %{
      "sidebarAutoSettleAfterDays" => nil,
      "sidebarAutoSettleOnMerge" => false
    })
  end

  step "the user sent a message in {string} a minute ago and its turn failed to start",
       %{args: [thread]} = context do
    at = World.iso_from_now(-60_000)

    context =
      context
      |> ensure_thread(thread)
      |> World.patch_thread(thread, %{"createdAt" => World.iso_from_now(-@hour)})
      |> World.add_message(thread, "user", "Ship it", at)
      |> World.add_run(thread, "failed", at, %{"startedAt" => nil})

    World.await_row(World.thread_id(context, thread), &(&1["status"] == "failed"))
    context
  end

  step "the linked pull request of {string} merged after that message",
       %{args: [thread]} = context do
    context |> link(thread) |> sync(thread, "merged", 0)
  end

  # --- helpers ---------------------------------------------------------------------------

  defp set_auto_settle(context, thread, enabled, done) do
    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.auto-settle.set",
        "threadId" => World.thread_id(context, thread),
        "enabled" => enabled
      })

    World.await_row(World.thread_id(context, thread), done)
    context
  end

  # The demo project as a GitHub checkout of "acme/app", with branch lookups held fresh.
  defp github(context) do
    if context[:gh_remote] do
      context
    else
      World.github_remote(context, World.project(context, "demo").root, "acme/app")

      context
      |> World.cli_rules(%{"args" => ["stacks?pull_request="], "stdout" => []})
      |> Map.put(:gh_remote, true)
    end
  end

  defp branch_answer(context, branch, number, state, at) do
    World.cli_rules(context, %{
      "args" => ["pr list", "--head #{branch}"],
      "stdout" => [
        %{
          "number" => number,
          "url" => "https://github.com/acme/app/pull/#{number}",
          "state" => state,
          "mergedAt" => if(state == "MERGED", do: at),
          "closedAt" => if(state in ~w(MERGED CLOSED), do: at)
        }
      ]
    })
  end

  defp recorded_branch_pull_request(context, thread, branch, number) do
    context =
      World.patch_thread(context, thread, %{
        "branch" => branch,
        "branchPullRequest" => %{
          "projectId" => World.project(context, "demo").id,
          "repository" => "acme/app",
          "number" => number,
          "url" => "https://github.com/acme/app/pull/#{number}"
        }
      })

    World.await_row(World.thread_id(context, thread), &(&1["branchPullRequest"] != nil))
    context
  end

  defp summary_node(number, state, at) do
    %{
      "number" => number,
      "title" => "PR #{number}",
      "url" => "https://github.com/acme/app/pull/#{number}",
      "state" => state,
      "isDraft" => false,
      "mergeable" => "UNKNOWN",
      "headRefName" => "feature/t1",
      "baseRefName" => "main",
      "updatedAt" => at,
      "mergedAt" => if(state == "MERGED", do: at),
      "closedAt" => if(state in ~w(MERGED CLOSED), do: at),
      "author" => %{"login" => "octocat"},
      "commits" => %{"nodes" => []},
      "comments" => %{"nodes" => []},
      "reviews" => %{"nodes" => []}
    }
  end

  # Every `gh` call fails, as it does when the host cannot be reached.
  defp unreachable(context) do
    World.cli_rules(context, %{
      "args" => [""],
      "stderr" => "error connecting to api.github.com\n",
      "exit" => 1
    })
  end

  defp ensure_thread(context, thread) do
    if context.threads[thread], do: context, else: World.create_thread(context, thread, "demo")
  end

  # Backdates the thread and gives it a user message and a finished run `ago_ms` ago.
  defp finished(context, thread, ago_ms) do
    at = World.iso_from_now(ago_ms)

    context
    |> ensure_thread(thread)
    |> World.patch_thread(thread, %{"createdAt" => at})
    |> World.add_message(thread, "user", "Ship it", at)
    |> World.add_run(thread, "completed", at)
  end

  defp worked(context, thread, ago_ms) do
    context
    |> ensure_thread(thread)
    |> World.patch_thread(thread, %{"createdAt" => World.iso_from_now(ago_ms - @hour)})
    |> World.add_message(thread, "user", "Ship it", World.iso_from_now(ago_ms))
  end

  defp update(context, thread, type, done) do
    {{:ok, _}, context} =
      World.dispatch(context, %{"type" => type, "threadId" => World.thread_id(context, thread)})

    World.await_row(World.thread_id(context, thread), done)
    context
  end

  defp auto_settle(context, thread) do
    row = World.row(context, thread)

    %{
      "type" => "thread.auto-settle",
      "commandId" => "server:auto-settle:#{row["id"]}:#{HalC2.Environment.uuid4()}",
      "threadId" => row["id"],
      "snapshotAt" => row["updatedAt"],
      "settledAt" => row["latestUserMessageAt"] || row["createdAt"]
    }
  end

  defp write_settings(context, patch) do
    {settings, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(deep_merge(settings, patch), version)
    context
  end

  defp deep_merge(a, b),
    do:
      Map.merge(a, b, fn _, x, y -> if is_map(x) and is_map(y), do: deep_merge(x, y), else: y end)

  defp link(context, thread, number \\ 5) do
    id = World.thread_id(context, thread)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.pull-request.link",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/demo",
        "number" => number,
        "url" => "https://github.com/acme/demo/pull/#{number}",
        "source" => "manual"
      })

    World.await_row(id, fn row ->
      Enum.any?(row["pullRequests"] || [], &(&1["number"] == number))
    end)

    context
  end

  defp sync(context, thread, state, ago_ms, number \\ 5) do
    id = World.thread_id(context, thread)
    at = World.iso_from_now(ago_ms)

    snapshot =
      %{"state" => state, "title" => "PR #{number}", "syncedAt" => World.iso_from_now(0)}
      |> Map.merge(
        case state do
          "merged" -> %{"mergedAt" => at}
          "closed" -> %{"closedAt" => at}
          "open" -> %{}
        end
      )

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.pull-request-link.sync",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/demo",
        "number" => number,
        "snapshot" => snapshot,
        "stack" => nil
      })

    World.await_row(id, fn row ->
      Enum.any?(
        row["pullRequests"] || [],
        &(&1["number"] == number and &1["snapshot"]["state"] == state)
      )
    end)

    context
  end
end
