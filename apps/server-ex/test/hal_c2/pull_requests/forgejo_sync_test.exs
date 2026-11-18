defmodule HalC2.PullRequests.ForgejoSyncTest do
  @moduledoc """
  A thread linked to a pull request on Forgejo: `HalC2.PullRequests.Sync` keeps its
  snapshot from the server's REST API (Forgejo has no native stacks, so it has none),
  and `HalC2.PullRequests.Wakes` wakes the thread when a review lands or its checks
  fail, telling it how to read them from that server's API.
  """

  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.PullRequests.{Sync, Wakes}
  alias HalC2.Test.FakeHttp

  @moduletag :tmp_dir
  # The wake starts a turn no provider here takes.
  @moduletag :capture_log
  @url "https://forgejo.test/acme/shop/pulls/7"

  setup %{tmp_dir: dir} do
    put_app_env(:home, dir)
    {:ok, server} = Agent.start_link(fn -> %{reviews: [], status: "pending", viewer: "agent"} end)

    {base, _log} =
      FakeHttp.start(%{
        "/api/v1/user" => fn _ ->
          case Agent.get(server, & &1.viewer) do
            nil -> {500, %{}}
            viewer -> {200, %{"login" => viewer}}
          end
        end,
        "/api/v1/repos/acme/shop/collaborators" => {200, [%{"login" => "maint"}]},
        "/api/v1/repos/acme/shop/pulls/7" =>
          {200,
           %{
             "number" => 7,
             "title" => "Fix the cart",
             "html_url" => @url,
             "state" => "open",
             "merged" => false,
             "mergeable" => true,
             "head" => %{"ref" => "fix-cart", "sha" => "abc123"},
             "base" => %{"ref" => "main", "repo" => %{"owner" => %{"login" => "acme"}}},
             "updated_at" => "2030-01-01T09:00:00Z",
             "user" => %{"login" => "agent"}
           }},
        "/api/v1/repos/acme/shop/pulls/7/reviews" => fn _ ->
          {200, Agent.get(server, & &1.reviews)}
        end,
        "/api/v1/repos/acme/shop/issues/7/comments" => {200, []},
        "/api/v1/repos/acme/shop/commits/abc123/status" => fn _ ->
          status = Agent.get(server, & &1.status)
          {200, %{"state" => status, "total_count" => 1, "statuses" => [%{"status" => status}]}}
        end
      })

    keys = Path.join(dir, "keys.json")

    File.write!(
      keys,
      JSON.encode!(%{"hosts" => %{"forgejo.test" => %{"type" => "Application", "token" => "t"}}})
    )

    fj = Path.join(dir, "fj")
    File.write!(fj, "#!/bin/sh\nexit 0\n")
    File.chmod!(fj, 0o755)
    put_app_env(:fj_keys_paths, [keys])
    put_app_env(:fj_command, fj)
    put_env("HAL_C2_FORGEJO_API_BASE_URL", base)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    :ok = HalC2.Shell.subscribe(self())

    root = Path.join(dir, "shop")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: root)
    {_, 0} = System.cmd("git", ~w(remote add origin https://forgejo.test/acme/shop.git), cd: root)

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "title" => "shop",
        "workspaceRoot" => root
      })

    await_row("p1", & &1)
    %{server: server, root: root}
  end

  # The account's own comment must not pass for a collaborator's, which wakes a thread
  # even during its own run.
  test "until the server says who is signed in, a summary holds state and checks, no activity",
       %{server: server, root: root} do
    Agent.update(server, fn s ->
      %{
        s
        | viewer: nil,
          status: "failure",
          reviews: [
            %{
              "id" => 1,
              "user" => %{"login" => "agent"},
              "state" => "COMMENT",
              "body" => "mine",
              "submitted_at" => "2030-01-01T10:00:00Z"
            }
          ]
      }
    end)

    summaries =
      HalC2.PullRequests.Forgejo.summaries(root, "https://forgejo.test/acme/shop.git", [
        {"acme/shop", 7}
      ])

    assert %{{"acme/shop", 7} => summary} = summaries
    assert %{"state" => "open", "checksState" => "failing"} = summary

    refute Enum.any?(
             ~w(activity ownActivity activities ownActivities),
             &Map.has_key?(summary, &1)
           )
  end

  # With a second server's login beside it, a read pointed at no remote could not tell
  # which server the repository is on.
  test "a checkout whose only remote is not origin is read through that remote's server",
       %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "keys.json"),
      JSON.encode!(%{
        "hosts" => %{
          "forgejo.test" => %{"type" => "Application", "token" => "t"},
          "other.test" => %{"type" => "Application", "token" => "o"}
        }
      })
    )

    root = Path.join(dir, "upstream-only")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: root)

    {_, 0} =
      System.cmd("git", ~w(remote add upstream https://forgejo.test/acme/shop.git), cd: root)

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p2",
        "title" => "shop upstream",
        "workspaceRoot" => root
      })

    await_row("p2", & &1)

    ref = %{
      "host" => "forgejo.test",
      "repository" => "acme/shop",
      "number" => 7,
      "projectId" => "p2"
    }

    assert %{^ref => %{"state" => "open"}} = HalC2.PullRequests.summaries([ref])
  end

  # Forgejo has no native stacks, GitHub does: one this MC cannot read stays as it was,
  # never recorded as none.
  test "a GitHub pull request a Forgejo project's thread links is not taken for Forgejo's" do
    ref = %{
      "projectId" => "p1",
      "host" => "github.com",
      "repository" => "acme/shop",
      "number" => 7
    }

    assert {:error, _} = HalC2.PullRequests.stack(ref)
  end

  test "without a Forgejo login, a plugin's read says what Forgejo needs, not GitHub",
       %{tmp_dir: dir} do
    File.write!(Path.join(dir, "keys.json"), JSON.encode!(%{"hosts" => %{}}))
    put_app_env(:tea_command, Path.join(dir, "no-tea"))

    for read <- [&HalC2.PullRequests.trust/1, &HalC2.PullRequests.fetch_access/1] do
      assert {:error, %{"provider" => "forgejo", "message" => message}} =
               read.(%{"projectId" => "p1", "repository" => "acme/shop", "number" => 7})

      assert message =~ "fj"
      refute message =~ "gh "
    end
  end

  test "a plugin is handed fj's token only when it may write to pull requests" do
    start_supervised!(HalC2.Settings)
    {settings, version} = HalC2.Settings.get()

    plugins = %{
      "reader" => %{"enabled" => true, "granted" => ["pullRequests:read"]},
      "writer" => %{"enabled" => true, "granted" => ["pullRequests:read", "pullRequests:write"]}
    }

    {:ok, _} = HalC2.Settings.put(Map.put(settings, "plugins", plugins), version)
    ref = %{"projectId" => "p1", "repository" => "acme/shop", "number" => 7}

    assert {:error, refusal} = HalC2.Plugins.Host.pull_request_fetch("reader", ref)
    assert refusal =~ "pullRequests:write"
    assert {:ok, %{"token" => "t"}} = HalC2.Plugins.Host.pull_request_fetch("writer", ref)
  end

  test "a linked Forgejo pull request syncs and wakes its thread on a review and failing checks",
       %{server: server} do
    start_supervised!({Sync, interval: nil})

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => "t1",
        "projectId" => "p1",
        "title" => "t1",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
      })

    await_row("t1", & &1)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.pull-request.link",
        "threadId" => "t1",
        "host" => "forgejo.test",
        "repository" => "acme/shop",
        "number" => 7,
        "url" => @url,
        "source" => "agent"
      })

    await_row("t1", &match?([_], &1["pullRequests"]))
    :ok = Sync.sweep()

    assert [%{"snapshot" => %{"state" => "open", "checksState" => "pending"} = snapshot} = link] =
             pull_requests("t1")

    assert snapshot["title"] == "Fix the cart"
    assert link["stack"] == nil
    assert Wakes.check("t1") == :quiet

    Agent.update(server, fn s ->
      %{
        s
        | status: "failure",
          reviews: [
            %{
              "id" => 1,
              "user" => %{"login" => "maint"},
              "state" => "REQUEST_CHANGES",
              "submitted_at" => "2030-01-01T10:00:00Z"
            }
          ]
      }
    end)

    :ok = Sync.sweep()
    assert Wakes.check("t1") == :woken

    [wake] =
      for message <- StreamState.list(current("t1"), "message"),
          get_in(message, ["notification", "source", "kind"]) == "pull_request",
          do: message

    assert wake["notification"]["summary"] == "acme/shop#7: checks failing, new review"
    assert wake["notification"]["outcome"] == "failed"
    assert wake["text"] =~ "New review from maint (changes requested)."
    assert wake["text"] =~ "`https://forgejo.test/api/v1/repos/acme/shop/pulls/7/reviews`"
    refute wake["text"] =~ "tea "
    refute wake["text"] =~ "gh "

    # Heard: the same snapshot is not news again, once the thread is idle to hear it.
    await_idle("t1")

    assert [%{"heard" => %{"checksState" => "failing", "reviewActivityAt" => at}}] =
             pull_requests("t1")

    assert at == "2030-01-01T10:00:00Z"
    :ok = Sync.sweep()
    assert Wakes.check("t1") == :quiet
  end

  @busy ~w(preparing starting running waiting queued)

  # Until none of the thread's runs is going (the wake's run fails: no agent here).
  # Subscribes once and waits on the one deadline: each subscription replays the state,
  # so subscribing on every message would keep the mailbox from ever running dry.
  defp await_idle(id) do
    :ok = HalC2.Streams.subscribe(id, self(), nil)
    await_idle(id, System.monotonic_time(:millisecond) + 10_000)
  end

  defp await_idle(id, deadline) do
    if Enum.any?(StreamState.list(current(id), "run"), &(&1["status"] in @busy)) do
      receive do
        {:hal_c2_stream, ^id, _} -> await_idle(id, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("#{id}'s run never ended")
      end
    else
      :ok
    end
  end

  defp current(id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(id))

  defp pull_requests(id),
    do: HalC2.Projection.PullRequests.of(StreamState.get(current(id), "thread")[id])

  defp await_row(id, fun) do
    case HalC2.Shell.row(node(), id) do
      {_kind, row} -> if fun.(row), do: row, else: await_next_row(id, fun)
      nil -> await_next_row(id, fun)
    end
  end

  defp await_next_row(id, fun) do
    receive do
      {:hal_c2_shell, {:rows, _, rows}} ->
        case List.keyfind(rows, id, 0) do
          {^id, {_kind, row}} -> if fun.(row), do: row, else: await_next_row(id, fun)
          nil -> await_next_row(id, fun)
        end
    after
      2_000 -> flunk("#{id}'s row never changed as expected")
    end
  end

  defp put_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  defp put_app_env(key, value) do
    previous = Application.get_env(:hal_c2, key)
    Application.put_env(:hal_c2, key, value)
    on_exit(fn -> Application.put_env(:hal_c2, key, previous) end)
  end
end
