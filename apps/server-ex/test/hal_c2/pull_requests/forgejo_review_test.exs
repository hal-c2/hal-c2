defmodule HalC2.PullRequests.ForgejoReviewTest do
  @moduledoc """
  What the code-review plugin reads from and posts to a Forgejo pull request, against
  a fake Forgejo server signed in with fj's token: its detail, its activity, who
  stands behind it, a review with inline comments, and how a clone fetches it.
  """

  use ExUnit.Case, async: false

  alias HalC2.PullRequests.Forgejo
  alias HalC2.Test.FakeHttp

  @moduletag :tmp_dir

  @t1 "2030-01-01T10:00:00+02:00"
  @t2 "2030-01-01T09:00:00Z"

  defp pull(extra \\ %{}) do
    Map.merge(
      %{
        "number" => 7,
        "title" => "Fix the cart",
        "body" => "It was broken.",
        "html_url" => "https://forgejo.test/acme/shop/pulls/7",
        "state" => "open",
        "merged" => false,
        "draft" => false,
        "head" => %{
          "ref" => "fix-cart",
          "sha" => "abc123",
          "repo" => %{"id" => 2, "owner" => %{"login" => "agent"}}
        },
        "base" => %{
          "ref" => "main",
          "sha" => "def456",
          "repo" => %{"id" => 1, "owner" => %{"login" => "acme"}}
        },
        "labels" => [%{"name" => "ai-review"}],
        "updated_at" => @t1,
        "additions" => 3,
        "deletions" => 1,
        "user" => %{"login" => "agent", "full_name" => "Agent"},
        "requested_reviewers" => [%{"login" => "reviewer"}]
      },
      extra
    )
  end

  defp serve(tmp, routes, opts \\ []) do
    {base, log} = FakeHttp.start(routes)
    host = String.replace_prefix(base, "http://", "")
    keys = Path.join(tmp, "keys.json")

    File.write!(
      keys,
      JSON.encode!(%{"hosts" => %{host => %{"type" => "Application", "token" => "t0ken"}}})
    )

    fj = Path.join(tmp, "fj")
    File.write!(fj, "#!/bin/sh\nexit 0\n")
    File.chmod!(fj, 0o755)
    put_app_env(:fj_keys_paths, [keys])
    put_app_env(:fj_command, Keyword.get(opts, :fj, fj))
    {base, log}
  end

  defp routes(viewer, overrides \\ %{}) do
    Map.merge(
      %{
        "/api/v1/user" => {200, %{"login" => viewer}},
        "/api/v1/repos/acme/shop/collaborators" => {200, [%{"login" => "Maint"}]},
        "/api/v1/repos/acme/shop/pulls/7" => {200, pull()},
        "/api/v1/repos/acme/shop/commits/abc123/status" =>
          {200,
           %{
             "statuses" => [
               %{"context" => "ci / build", "status" => "success"},
               %{"context" => "ci / test", "status" => "pending"}
             ]
           }},
        "/api/v1/repos/acme/shop/pulls/7/reviews" =>
          {200,
           [
             %{
               "id" => 1,
               "user" => %{"login" => "reviewer"},
               "state" => "REQUEST_CHANGES",
               "body" => "Not yet.",
               "submitted_at" => @t2,
               "comments_count" => 1
             },
             %{
               "id" => 2,
               "user" => %{"login" => "maint"},
               "state" => "PENDING",
               "body" => "draft"
             }
           ]},
        "/api/v1/repos/acme/shop/pulls/7/reviews/1/comments" =>
          {200,
           [
             %{
               "user" => %{"login" => "reviewer"},
               "path" => "lib/cart.ex",
               "position" => 0,
               "original_position" => 12,
               "resolver" => %{"login" => "agent"},
               "body" => "Off by one.",
               "created_at" => @t2
             }
           ]},
        "/api/v1/repos/acme/shop/issues/7/comments" =>
          {200, [%{"user" => %{"login" => "stranger"}, "body" => "+1", "created_at" => @t1}]}
      },
      overrides
    )
  end

  defp ctx(base),
    do: %{cwd: nil, remote_url: base <> "/acme/shop.git", repository: "acme/shop", number: 7}

  test "a pull request's detail names its head and base, its checks and its asked reviewers",
       %{tmp_dir: tmp} do
    {base, _} = serve(tmp, routes("reviewer"))

    assert {:ok,
            %{
              "number" => 7,
              "title" => "Fix the cart",
              "body" => "It was broken.",
              "state" => "open",
              "isDraft" => false,
              "author" => %{"login" => "agent"},
              "headBranch" => "fix-cart",
              "baseBranch" => "main",
              "headSha" => "abc123",
              "baseSha" => "def456",
              "labels" => [%{"name" => "ai-review"}],
              "additions" => 3,
              "deletions" => 1,
              "updatedAt" => "2030-01-01T08:00:00Z",
              "checks" => [
                %{"name" => "ci / build", "status" => "success"},
                %{"name" => "ci / test", "status" => "pending"}
              ],
              "reviewers" => [%{"login" => "reviewer"}],
              "viewer" => "reviewer",
              "viewerPermissions" => %{"verdicts" => ["approve", "request-changes", "comment"]}
            }} = Forgejo.detail(ctx(base))
  end

  test "the author of a pull request may only comment on it", %{tmp_dir: tmp} do
    {base, _} = serve(tmp, routes("Agent"))

    assert {:ok, %{"viewerPermissions" => %{"verdicts" => ["comment"]}}} =
             Forgejo.detail(ctx(base))
  end

  test "activity holds the comments and submitted reviews, and each inline comment as a thread",
       %{tmp_dir: tmp} do
    {base, _} = serve(tmp, routes("reviewer"))

    assert {:ok, %{"comments" => comments, "reviewThreads" => threads}} =
             Forgejo.activity(ctx(base))

    assert [
             %{"kind" => "comment", "author" => %{"login" => "stranger"}, "body" => "+1"},
             # The pending review is nobody's to read yet.
             %{"kind" => "review", "author" => %{"login" => "reviewer"}, "body" => "Not yet."}
           ] = comments

    # An outdated comment keeps the line it was made on.
    assert [
             %{
               "path" => "lib/cart.ex",
               "line" => 12,
               "isResolved" => true,
               "comments" => [%{"body" => "Off by one.", "createdAt" => @t2}]
             }
           ] = threads
  end

  test "trust names the owner and collaborators, and who last labelled or asked for a review",
       %{tmp_dir: tmp} do
    timeline = [
      %{
        "type" => "label",
        "body" => "1",
        "label" => %{"name" => "AI-Review"},
        "user" => %{"login" => "stranger"},
        "created_at" => "2030-01-01T08:00:00Z"
      },
      %{
        "type" => "label",
        "body" => "1",
        "label" => %{"name" => "ai-review"},
        "user" => %{"login" => "maint"},
        "created_at" => "2030-01-01T09:00:00Z"
      },
      %{
        "type" => "label",
        "body" => "1",
        "label" => %{"name" => "ai-review"},
        "user" => %{"login" => "stranger"},
        "created_at" => "2030-01-01T11:00:00+02:00"
      },
      # Taking the label off is not putting it on.
      %{
        "type" => "label",
        "body" => "",
        "label" => %{"name" => "ai-review"},
        "user" => %{"login" => "agent"},
        "created_at" => "2030-01-01T10:00:00Z"
      },
      %{
        "type" => "review_request",
        "assignee" => %{"login" => "reviewer"},
        "user" => %{"login" => "acme"},
        "created_at" => @t2
      },
      %{
        "type" => "review_request",
        "assignee" => %{"login" => "reviewer"},
        "removed_assignee" => true,
        "user" => %{"login" => "stranger"},
        "created_at" => "2030-01-01T10:00:00Z"
      }
    ]

    {base, _} =
      serve(
        tmp,
        routes("reviewer", %{"/api/v1/repos/acme/shop/issues/7/timeline" => {200, timeline}})
      )

    assert {:ok, trust} = Forgejo.trust(ctx(base), "ai-review")

    assert %{
             "viewer" => "reviewer",
             "author" => %{"login" => "agent", "association" => "NONE", "isUser" => true},
             "isCrossRepository" => true,
             "headOwner" => "agent",
             "headSha" => "abc123",
             "comments" => [%{"login" => "stranger", "association" => "NONE", "body" => "+1"}],
             "requested" => %{
               "login" => "acme",
               "association" => "OWNER",
               "createdAt" => @t2
             }
           } = trust

    # Maint and the stranger added it in the same second: the tie is named.
    assert %{
             "login" => "stranger",
             "association" => "NONE",
             "createdAt" => "2030-01-01T09:00:00Z",
             "tied" => [%{"login" => "maint", "association" => "COLLABORATOR"}]
           } = trust["labeled"]
  end

  test "a review posts its verdict, its body and each comment on its line, on the head commit",
       %{tmp_dir: tmp} do
    {base, log} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" => fn conn ->
            if conn.method == "POST", do: {200, %{"id" => 9}}, else: {200, []}
          end
        })
      )

    comments = [
      %{"path" => "a.ex", "body" => "added", "position" => %{"kind" => "added", "newLine" => 4}},
      %{"path" => "b.ex", "body" => "gone", "position" => %{"kind" => "deleted", "oldLine" => 7}},
      %{
        "path" => "c.ex",
        "body" => "left",
        "position" => %{"kind" => "context", "side" => "left", "oldLine" => 2, "newLine" => 3}
      },
      %{
        "path" => "d.ex",
        "body" => "right",
        "position" => %{"kind" => "context", "side" => "right", "oldLine" => 5, "newLine" => 6}
      }
    ]

    assert :ok =
             Forgejo.submit_review(ctx(base), "request-changes", "Fix these.", comments, "abc123")

    assert [%{"body" => body, "authorization" => "token t0ken"}] =
             for(r <- FakeHttp.requests(log), r["method"] == "POST", do: r)

    assert %{
             "event" => "REQUEST_CHANGES",
             "body" => "Fix these.",
             "commit_id" => "abc123",
             "comments" => [
               %{"path" => "a.ex", "body" => "added", "new_position" => 4},
               %{"path" => "b.ex", "body" => "gone", "old_position" => 7},
               %{"path" => "c.ex", "body" => "left", "old_position" => 2},
               %{"path" => "d.ex", "body" => "right", "new_position" => 6}
             ]
           } = JSON.decode!(body)
  end

  test "a refused review is an error", %{tmp_dir: tmp} do
    {base, _} =
      serve(
        tmp,
        routes("agent", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" =>
            {422, %{"message" => "approve your own pull is not allowed"}}
        })
      )

    assert {:error, _} = Forgejo.submit_review(ctx(base), "approve", "LGTM", [])
  end

  test "stats are the pull request's additions and deletions", %{tmp_dir: tmp} do
    {base, _} = serve(tmp, routes("reviewer"))
    assert {3, 1} = Forgejo.stats(ctx(base))
    assert nil == Forgejo.stats(%{ctx(base) | number: 8})
  end

  test "a clone fetches from the server the API is read on, with fj's token", %{tmp_dir: tmp} do
    {base, _} = serve(tmp, routes("reviewer"))

    assert {:ok, %{"url" => url, "token" => "t0ken", "username" => _}} =
             Forgejo.fetch_access(ctx(base))

    assert url == base <> "/acme/shop.git"
  end

  defp put_app_env(key, value) do
    previous = Application.fetch_env(:hal_c2, key)
    Application.put_env(:hal_c2, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:hal_c2, key, old)
        :error -> Application.delete_env(:hal_c2, key)
      end
    end)
  end
end
