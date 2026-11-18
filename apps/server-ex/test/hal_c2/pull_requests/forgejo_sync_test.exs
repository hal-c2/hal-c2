defmodule HalC2.PullRequests.ForgejoSyncTest do
  @moduledoc """
  A thread linked to a pull request on Forgejo: `HalC2.PullRequests.Sync` keeps its
  snapshot from the server's REST API (Forgejo has no native stacks, so it has none),
  and `HalC2.PullRequests.Wakes` wakes the thread when a review lands or its checks
  fail, telling it how to read them with `tea`.
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
    Application.put_env(:hal_c2, :home, dir)
    {:ok, server} = Agent.start_link(fn -> %{reviews: [], status: "pending"} end)

    {base, _log} =
      FakeHttp.start(%{
        "/api/v1/user" => {200, %{"login" => "agent"}},
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
    System.put_env("HAL_C2_FORGEJO_API_BASE_URL", base)
    on_exit(fn -> System.delete_env("HAL_C2_FORGEJO_API_BASE_URL") end)

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
    %{server: server}
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
    assert wake["text"] =~ "`tea api repos/acme/shop/pulls/7/reviews`"
    refute wake["text"] =~ "gh "

    # Heard: the same snapshot is not news again.
    :ok = Sync.sweep()
    assert Wakes.check("t1") == :quiet
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

  defp put_app_env(key, value) do
    previous = Application.get_env(:hal_c2, key)
    Application.put_env(:hal_c2, key, value)
    on_exit(fn -> Application.put_env(:hal_c2, key, previous) end)
  end
end
