defmodule HalC2.PullRequests.ForgejoSummariesTest do
  @moduledoc """
  `HalC2.PullRequests.Forgejo.summaries/3` against a fake Forgejo server signed in
  with fj's token: the pull request, its reviews and their inline comments, its
  comments and its head's commit statuses make the summary a GitHub link's would.
  """

  use ExUnit.Case, async: false

  alias HalC2.PullRequests.Forgejo
  alias HalC2.Test.FakeHttp

  @moduletag :tmp_dir

  @t1 "2030-01-01T10:00:00+02:00"
  @t2 "2030-01-01T09:00:00Z"
  @t3 "2030-01-01T09:30:00Z"
  @t4 "2030-01-01T09:40:00Z"
  @t5 "2030-01-01T09:50:00Z"

  defp pull(extra \\ %{}) do
    Map.merge(
      %{
        "number" => 7,
        "title" => "Fix the cart",
        "html_url" => "https://forgejo.test/acme/shop/pulls/7",
        "state" => "open",
        "merged" => false,
        "draft" => false,
        "mergeable" => true,
        "head" => %{"ref" => "fix-cart", "sha" => "abc123"},
        "base" => %{"ref" => "main", "repo" => %{"owner" => %{"login" => "acme"}}},
        "updated_at" => @t5,
        "closed_at" => nil,
        "merged_at" => nil,
        "additions" => 3,
        "deletions" => 1,
        "changed_files" => 2,
        "user" => %{"login" => "agent", "full_name" => "Agent", "avatar_url" => "https://a/1"},
        "requested_reviewers" => [%{"login" => "rev"}]
      },
      extra
    )
  end

  defp review(id, login, state, at, extra \\ %{}),
    do:
      Map.merge(
        %{
          "id" => id,
          "user" => %{"login" => login},
          "state" => state,
          "submitted_at" => at,
          "comments_count" => 0,
          "official" => false
        },
        extra
      )

  defp serve(tmp, routes) do
    {base, log} = FakeHttp.start(routes)
    host = String.replace_prefix(base, "http://", "")
    keys = Path.join(tmp, "keys.json")

    File.write!(
      keys,
      JSON.encode!(%{"hosts" => %{host => %{"type" => "Application", "token" => "t"}}})
    )

    fj = Path.join(tmp, "fj")
    File.write!(fj, "#!/bin/sh\nexit 0\n")
    File.chmod!(fj, 0o755)
    put_app_env(:fj_keys_paths, [keys])
    put_app_env(:fj_command, fj)
    {base, log}
  end

  defp routes(overrides) do
    Map.merge(
      %{
        "/api/v1/user" => {200, %{"login" => "agent"}},
        "/api/v1/repos/acme/shop/collaborators" => {200, [%{"login" => "maint"}]},
        "/api/v1/repos/acme/shop/pulls/7" => {200, pull()},
        "/api/v1/repos/acme/shop/pulls/7/reviews" =>
          {200,
           [
             review(1, "maint", "APPROVED", @t1),
             review(2, "rev", "REQUEST_CHANGES", @t2, %{"comments_count" => 2}),
             review(3, "drive-by", "COMMENT", @t5),
             review(4, "maint", "PENDING", @t5),
             review(5, "rev", "REQUEST_REVIEW", @t5)
           ]},
        "/api/v1/repos/acme/shop/pulls/7/reviews/2/comments" =>
          {200,
           [
             %{"user" => %{"login" => "rev"}, "created_at" => @t2, "body" => "here"},
             %{"user" => %{"login" => "rev"}, "created_at" => @t4, "body" => "and a reply"}
           ]},
        "/api/v1/repos/acme/shop/issues/7/comments" =>
          {200,
           [
             %{"user" => %{"login" => "agent"}, "created_at" => @t3, "body" => "fixed"},
             %{"user" => %{"login" => "stranger"}, "created_at" => @t5, "body" => "+1"}
           ]},
        "/api/v1/repos/acme/shop/commits/abc123/status" =>
          {200,
           %{
             "state" => "failure",
             "total_count" => 2,
             "statuses" => [
               %{"context" => "ci / build", "status" => "success"},
               %{"context" => "ci / test", "status" => "failure"}
             ]
           }}
      },
      overrides
    )
  end

  defp summarize(base),
    do: Forgejo.summaries(nil, base <> "/acme/shop.git", [{"acme/shop", 7}])[{"acme/shop", 7}]

  test "a pull request's summary carries its reviews, trusted activity and failing checks",
       %{tmp_dir: tmp} do
    {base, log} = serve(tmp, routes(%{}))

    assert %{
             "number" => 7,
             "title" => "Fix the cart",
             "url" => "https://forgejo.test/acme/shop/pulls/7",
             "state" => "open",
             "isDraft" => false,
             "headBranch" => "fix-cart",
             "baseBranch" => "main",
             "updatedAt" => @t5,
             "author" => %{"login" => "agent", "name" => "Agent"},
             "additions" => 3,
             "changedFiles" => 2,
             "mergeability" => "mergeable",
             # maint approved, rev (asked to review) wants changes: rev's verdict holds.
             "reviewDecision" => "changes-requested",
             "checksState" => "failing",
             # The reply on rev's review is newest among the trusted; the drive-by
             # review and the stranger's comment are not activity.
             "activity" => %{"at" => @t4, "author" => "rev", "kind" => "comment"},
             "ownActivity" => %{"at" => @t3, "author" => "agent", "kind" => "comment"}
           } = summarize(base)

    assert Enum.all?(FakeHttp.requests(log), &(&1["authorization"] == "token t"))
  end

  test "a review's verdict is its activity state, in the server's zone made UTC",
       %{tmp_dir: tmp} do
    {base, _log} =
      serve(
        tmp,
        routes(%{
          "/api/v1/repos/acme/shop/pulls/7/reviews" =>
            {200, [review(1, "maint", "APPROVED", "2030-01-02T10:00:00+02:00")]},
          "/api/v1/repos/acme/shop/issues/7/comments" => {200, []}
        })
      )

    assert %{
             "reviewDecision" => "approved",
             "activity" => %{
               "at" => "2030-01-02T08:00:00Z",
               "kind" => "review",
               "state" => "approved"
             },
             "ownActivity" => nil
           } = summarize(base)
  end

  test "an official reviewer is trusted although not a collaborator", %{tmp_dir: tmp} do
    {base, _log} =
      serve(
        tmp,
        routes(%{
          "/api/v1/repos/acme/shop/collaborators" => {403, %{"message" => "no"}},
          "/api/v1/repos/acme/shop/pulls/7" => {200, pull(%{"requested_reviewers" => []})},
          "/api/v1/repos/acme/shop/pulls/7/reviews" =>
            {200, [review(1, "bot", "COMMENT", @t2, %{"official" => true})]},
          "/api/v1/repos/acme/shop/issues/7/comments" => {200, []}
        })
      )

    assert %{
             "reviewDecision" => nil,
             "activity" => %{"author" => "bot", "kind" => "review", "state" => "commented"}
           } = summarize(base)
  end

  test "checks still running are pending; none at all say nothing", %{tmp_dir: tmp} do
    {base, _log} =
      serve(
        tmp,
        routes(%{
          "/api/v1/repos/acme/shop/commits/abc123/status" =>
            {200,
             %{
               "state" => "warning",
               "total_count" => 2,
               "statuses" => [%{"status" => "warning"}, %{"status" => "pending"}]
             }},
          "/api/v1/repos/acme/shop/commits/def456/status" =>
            {200, %{"state" => "", "total_count" => 0, "statuses" => []}}
        })
      )

    assert %{"checksState" => "pending"} = summarize(base)

    {base, _log} =
      serve(
        tmp,
        routes(%{
          "/api/v1/repos/acme/shop/pulls/7" =>
            {200, pull(%{"head" => %{"ref" => "fix-cart", "sha" => "def456"}})},
          "/api/v1/repos/acme/shop/commits/def456/status" =>
            {200, %{"state" => "", "total_count" => 0, "statuses" => []}}
        })
      )

    assert %{"checksState" => nil} = summarize(base)
  end

  test "a merged pull request is merged; a conflicting one says so", %{tmp_dir: tmp} do
    {base, _log} =
      serve(
        tmp,
        routes(%{
          "/api/v1/repos/acme/shop/pulls/7" =>
            {200,
             pull(%{
               "state" => "closed",
               "merged" => true,
               "merged_at" => @t5,
               "closed_at" => @t5,
               "mergeable" => false
             })}
        })
      )

    assert %{
             "state" => "merged",
             "mergedAt" => @t5,
             "closedAt" => @t5,
             "mergeability" => "conflicting"
           } = summarize(base)
  end

  test "a pull request the server does not have is absent", %{tmp_dir: tmp} do
    {base, _log} = serve(tmp, routes(%{"/api/v1/repos/acme/shop/pulls/7" => {404, %{}}}))
    assert summarize(base) == nil
  end

  defp put_app_env(key, value) do
    previous = Application.get_env(:hal_c2, key)
    Application.put_env(:hal_c2, key, value)
    on_exit(fn -> Application.put_env(:hal_c2, key, previous) end)
  end
end
