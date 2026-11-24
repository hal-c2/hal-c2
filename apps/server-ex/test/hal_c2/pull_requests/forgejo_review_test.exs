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
               "body" => "draft",
               "comments_count" => 1
             }
           ]},
        # The pending review's author can read its drafts; nobody else has seen them.
        "/api/v1/repos/acme/shop/pulls/7/reviews/2/comments" =>
          {200,
           [
             %{
               "user" => %{"login" => "maint"},
               "path" => "lib/cart.ex",
               "position" => 3,
               "body" => "Draft.",
               "created_at" => @t2
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
          {200, [%{"user" => %{"login" => "stranger"}, "body" => "+1", "created_at" => @t1}]},
        "/api/v1/repos/acme/shop/issues/7/timeline" => {200, []}
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

  test "activity names each author's standing in the repository, as trust does",
       %{tmp_dir: tmp} do
    inline = fn login ->
      %{"user" => %{"login" => login}, "path" => "lib/cart.ex", "position" => 3, "body" => "?"}
    end

    {base, _} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews/1/comments" =>
            {200, [inline.("maint"), inline.("acme"), inline.("stranger")]}
        })
      )

    assert {:ok, %{"comments" => comments, "reviewThreads" => threads}} =
             Forgejo.activity(ctx(base))

    assert Enum.all?(comments, &(&1["author"]["association"] == "NONE"))

    assert ["COLLABORATOR", "OWNER", "NONE"] =
             for(%{"comments" => [c]} <- threads, do: c["author"]["association"])

    # Collaborators it may not read count as none, and the activity still reads.
    {base, _} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/collaborators" => {403, %{"message" => "no"}},
          "/api/v1/repos/acme/shop/pulls/7/reviews/1/comments" => {200, [inline.("maint")]}
        })
      )

    assert {:ok, %{"reviewThreads" => [%{"comments" => [c]}]}} = Forgejo.activity(ctx(base))
    assert c["author"]["association"] == "NONE"
  end

  # Forgejo answers an issue's comments all at once and ignores `page` and `limit`.
  test "an issue's many comments are read once, not once a page", %{tmp_dir: tmp} do
    many =
      for n <- 1..120,
          do: %{"user" => %{"login" => "stranger"}, "body" => "#{n}", "created_at" => @t1}

    {base, log} =
      serve(
        tmp,
        routes("reviewer", %{"/api/v1/repos/acme/shop/issues/7/comments" => {200, many}})
      )

    assert {:ok, %{"comments" => comments}} = Forgejo.activity(ctx(base))
    assert Enum.count(comments, &(&1["kind"] == "comment")) == 120
    assert {:ok, %{"comments" => trusted}} = Forgejo.trust(ctx(base), nil)
    assert length(trusted) == 120

    reads = for r <- FakeHttp.requests(log), r["path"] =~ ~r"/issues/7/comments$", do: r["query"]
    assert reads == ["", ""]
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

  # Forgejo's administrator can cap a page below the 50 rows asked for.
  test "a list is read to its end when the server serves smaller pages", %{tmp_dir: tmp} do
    reviews =
      for n <- 1..5,
          do: %{
            "id" => 10 + n,
            "user" => %{"login" => "maint"},
            "state" => "COMMENT",
            "body" => "review #{n}",
            "submitted_at" => @t2
          }

    {base, log} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" => fn conn ->
            page = String.to_integer(Plug.Conn.fetch_query_params(conn).query_params["page"])

            conn
            |> Plug.Conn.put_resp_header("x-total-count", "5")
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, JSON.encode!(Enum.slice(reviews, (page - 1) * 2, 2)))
          end,
          "/api/v1/settings/api" => {200, %{"max_response_items" => 2}}
        })
      )

    assert {:ok, %{"comments" => comments}} = Forgejo.activity(ctx(base))

    assert for(%{"kind" => "review", "body" => b} <- comments, do: b) ==
             for(r <- reviews, do: r["body"])

    pages = for r <- FakeHttp.requests(log), r["path"] =~ ~r"/pulls/7/reviews$", do: r["query"]
    assert pages == ["limit=50&page=1", "limit=50&page=2", "limit=50&page=3"]
  end

  # Forgejo pages reviews before it hides other accounts' pending ones, and counts them.
  test "a page left empty by hidden reviews is not the end of the list", %{tmp_dir: tmp} do
    review = %{
      "id" => 60,
      "user" => %{"login" => "maint"},
      "state" => "COMMENT",
      "body" => "late",
      "submitted_at" => @t2
    }

    {base, _} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" => fn conn ->
            page = String.to_integer(Plug.Conn.fetch_query_params(conn).query_params["page"])

            conn
            |> Plug.Conn.put_resp_header("x-total-count", "51")
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, JSON.encode!(if page == 2, do: [review], else: []))
          end,
          "/api/v1/settings/api" => {200, %{"max_response_items" => 50}}
        })
      )

    assert {:ok, %{"comments" => comments}} = Forgejo.activity(ctx(base))
    assert for(%{"kind" => "review", "body" => body} <- comments, do: body) == ["late"]
  end

  # A review is deleted between two reads: the second page's rows moved up a page.
  test "a list whose total changes while it is read is an error", %{tmp_dir: tmp} do
    {base, _} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" => fn conn ->
            page = String.to_integer(Plug.Conn.fetch_query_params(conn).query_params["page"])

            {total, rows} =
              if page == 1,
                do:
                  {"3",
                   [%{"id" => 1, "state" => "COMMENT", "body" => "A", "submitted_at" => @t2}]},
                else: {"2", []}

            conn
            |> Plug.Conn.put_resp_header("x-total-count", total)
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, JSON.encode!(rows))
          end,
          "/api/v1/settings/api" => {200, %{"max_response_items" => 1}}
        })
      )

    assert {:error, {:failed, message}} = Forgejo.activity(ctx(base))
    assert message =~ "changed"
  end

  # Forgejo's timeline leaves review line comments out of each page after reading it,
  # and its total counts only the page: a short page is the last only when the line
  # comments cannot account for it.
  test "trust reads the timeline past pages that line comments shortened", %{tmp_dir: tmp} do
    event = fn n ->
      %{
        "type" => "comment",
        "body" => "c#{n}",
        "user" => %{"login" => "stranger"},
        "created_at" => "2030-01-01T08:00:00Z"
      }
    end

    label = %{
      "type" => "label",
      "body" => "1",
      "label" => %{"name" => "ai-review"},
      "user" => %{"login" => "maint"},
      "created_at" => "2030-01-01T09:00:00Z"
    }

    # 40 of page 1's rows and 20 of page 2's are line comments.
    by_page = %{
      1 => for(n <- 1..10, do: event.(n)),
      2 => for(n <- 11..40, do: event.(n)),
      3 => [label]
    }

    {base, log} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" =>
            {200,
             [
               %{
                 "id" => 1,
                 "user" => %{"login" => "maint"},
                 "state" => "COMMENT",
                 "submitted_at" => @t2,
                 "comments_count" => 60
               }
             ]},
          "/api/v1/repos/acme/shop/issues/7/timeline" => fn conn ->
            page = String.to_integer(Plug.Conn.fetch_query_params(conn).query_params["page"])
            rows = Map.get(by_page, page, [])

            conn
            |> Plug.Conn.put_resp_header("x-total-count", "#{length(rows)}")
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, JSON.encode!(rows))
          end,
          "/api/v1/settings/api" => {200, %{"max_response_items" => 50}}
        })
      )

    assert {:ok, %{"labeled" => %{"login" => "maint"}}} = Forgejo.trust(ctx(base), "ai-review")

    reads = for r <- FakeHttp.requests(log), r["path"] =~ ~r"/issues/7/timeline$", do: r["query"]
    assert reads == ["limit=50&page=1", "limit=50&page=2", "limit=50&page=3"]
  end

  test "a list with more pages than are read is an error, not a short history",
       %{tmp_dir: tmp} do
    rows = fn page ->
      for n <- 1..50,
          do: %{
            "id" => page * 100 + n,
            "user" => %{"login" => "maint"},
            "state" => "COMMENT",
            "body" => "r",
            "submitted_at" => @t2
          }
    end

    serve_total = fn total ->
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" => fn conn ->
            page = String.to_integer(Plug.Conn.fetch_query_params(conn).query_params["page"])

            conn
            |> Plug.Conn.put_resp_header("x-total-count", "#{total}")
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, JSON.encode!(rows.(page)))
          end
        })
      )
    end

    {base, _} = serve_total.(501)
    assert {:error, {:failed, _}} = Forgejo.activity(ctx(base))

    # Ten pages that hold it all are the whole of it.
    {base, _} = serve_total.(500)
    assert {:ok, %{"comments" => comments}} = Forgejo.activity(ctx(base))
    assert length(for %{"kind" => "review"} <- comments, do: 1) == 500
  end

  # The code review plugin reposts only when its own review is absent.
  test "reviews that cannot be read are an error, not an empty history", %{tmp_dir: tmp} do
    {base, _} =
      serve(
        tmp,
        routes("reviewer", %{"/api/v1/repos/acme/shop/pulls/7/reviews" => {503, %{}}})
      )

    assert {:error, _} = Forgejo.activity(ctx(base))
  end

  test "a head's statuses are read across pages; a page that fails reads as none",
       %{tmp_dir: tmp} do
    status = fn statuses_by_page ->
      fn conn ->
        page = String.to_integer(Plug.Conn.fetch_query_params(conn).query_params["page"])

        # As Forgejo answers: the body counts the page, the header every status.
        case Enum.at(statuses_by_page, page - 1) do
          :fail ->
            {500, %{}}

          rows ->
            conn
            |> Plug.Conn.put_resp_header("x-total-count", "3")
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              JSON.encode!(%{"total_count" => length(rows), "statuses" => rows})
            )
        end
      end
    end

    ok = fn name -> %{"context" => name, "status" => "success"} end

    {base, _} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/commits/abc123/status" =>
            status.([[ok.("a"), ok.("b")], [%{"context" => "c", "status" => "failure"}]])
        })
      )

    assert {:ok, %{"checks" => checks}} = Forgejo.detail(ctx(base))
    assert Enum.map(checks, & &1["name"]) == ["a", "b", "c"]

    {base, _} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/commits/abc123/status" =>
            status.([[ok.("a"), ok.("b")], :fail])
        })
      )

    assert {:ok, %{"checks" => []}} = Forgejo.detail(ctx(base))
  end

  # A full page whose body counts only itself: the header says 20 more follow.
  test "a head with more statuses than a page reads them all", %{tmp_dir: tmp} do
    rows = for i <- 1..70, do: %{"context" => "c#{i}", "status" => "success"}
    rows = List.replace_at(rows, 69, %{"context" => "c70", "status" => "failure"})

    {base, log} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/commits/abc123/status" => fn conn ->
            page = String.to_integer(Plug.Conn.fetch_query_params(conn).query_params["page"])
            page_rows = rows |> Enum.drop((page - 1) * 50) |> Enum.take(50)

            conn
            |> Plug.Conn.put_resp_header("x-total-count", "70")
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              JSON.encode!(%{"total_count" => length(page_rows), "statuses" => page_rows})
            )
          end
        })
      )

    assert {:ok, %{"checks" => checks}} = Forgejo.detail(ctx(base))
    assert length(checks) == 70
    assert %{"name" => "c70"} = List.last(checks)

    assert 2 ==
             Enum.count(FakeHttp.requests(log), &String.ends_with?(&1["path"], "abc123/status"))
  end

  # A review's comments would be published into the pending review, which may be the
  # user's draft: it is neither deleted nor posted into.
  test "a post is refused while the account has a pending review", %{tmp_dir: tmp} do
    {base, log} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" =>
            {200,
             [
               %{"id" => 5, "user" => %{"login" => "Reviewer"}, "state" => "PENDING"},
               %{"id" => 6, "user" => %{"login" => "maint"}, "state" => "PENDING"}
             ]},
          "/api/v1/repos/acme/shop/pulls/7/reviews/5/comments" =>
            {200, [%{"path" => "a.ex", "body" => "Mine.", "user" => %{"login" => "reviewer"}}]}
        })
      )

    comments = [
      %{"path" => "a.ex", "body" => "added", "position" => %{"kind" => "added", "newLine" => 4}}
    ]

    assert {:error, {:failed, message}} =
             Forgejo.submit_review(ctx(base), "comment", "Hm.", comments)

    assert message =~ "pending review"
    assert message =~ "earlier post"
    assert for(r <- FakeHttp.requests(log), r["method"] in ~w(POST DELETE), do: r) == []

    # Another account's pending review is no hindrance.
    {base, log} =
      serve(
        tmp,
        routes("agent", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" => fn conn ->
            if conn.method == "POST",
              do: {200, %{"id" => 9}},
              else: {200, [%{"id" => 6, "user" => %{"login" => "maint"}, "state" => "PENDING"}]}
          end
        })
      )

    assert :ok = Forgejo.submit_review(ctx(base), "comment", "Hm.", [])

    assert [%{"method" => "POST"}] =
             for(r <- FakeHttp.requests(log), r["method"] == "POST", do: r)
  end

  # Forgejo keeps a failed post's staged comments in a pending review, and while it
  # stands the next post fails too.
  test "a failed post deletes the pending review of its own comments, and no other",
       %{tmp_dir: tmp} do
    {:ok, posted} = Agent.start_link(fn -> false end)
    on_exit(fn -> if Process.alive?(posted), do: Agent.stop(posted) end)
    mine = %{"id" => 8, "user" => %{"login" => "reviewer"}, "state" => "PENDING"}
    theirs = %{"id" => 9, "user" => %{"login" => "reviewer"}, "state" => "PENDING"}

    {base, log} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" => fn conn ->
            cond do
              conn.method == "POST" ->
                Agent.update(posted, fn _ -> true end)
                {500, %{"message" => "boom"}}

              Agent.get(posted, & &1) ->
                {200, [mine, theirs]}

              true ->
                {200, []}
            end
          end,
          "/api/v1/repos/acme/shop/pulls/7/reviews/8/comments" =>
            {200, [%{"path" => "a.ex", "body" => "added", "user" => %{"login" => "reviewer"}}]},
          # One the user began in the web UI meanwhile.
          "/api/v1/repos/acme/shop/pulls/7/reviews/9/comments" =>
            {200, [%{"path" => "a.ex", "body" => "Mine.", "user" => %{"login" => "reviewer"}}]},
          "/api/v1/repos/acme/shop/pulls/7/reviews/8" => {204, nil}
        })
      )

    comments = [
      %{"path" => "a.ex", "body" => "added", "position" => %{"kind" => "added", "newLine" => 4}}
    ]

    assert {:error, {_, message}} =
             Forgejo.submit_review(ctx(base), "comment", "Hm.", comments)

    assert message =~ "could not be cleared"

    assert [
             {"POST", "/api/v1/repos/acme/shop/pulls/7/reviews"},
             {"DELETE", "/api/v1/repos/acme/shop/pulls/7/reviews/8"}
           ] =
             for(
               r <- FakeHttp.requests(log),
               r["method"] in ~w(POST DELETE),
               do: {r["method"], r["path"]}
             )
  end

  # Forgejo creates the pending review before it stores the first comment: a post that
  # failed in between leaves one with nothing staged, which is not known to be its own.
  test "a failed post that leaves an empty pending review says to discard it",
       %{tmp_dir: tmp} do
    {:ok, posted} = Agent.start_link(fn -> false end)
    on_exit(fn -> if Process.alive?(posted), do: Agent.stop(posted) end)
    empty = %{"id" => 8, "user" => %{"login" => "reviewer"}, "state" => "PENDING"}

    {base, log} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" => fn conn ->
            cond do
              conn.method == "POST" ->
                Agent.update(posted, fn _ -> true end)
                {500, %{"message" => "boom"}}

              Agent.get(posted, & &1) ->
                {200, [empty]}

              true ->
                {200, []}
            end
          end,
          "/api/v1/repos/acme/shop/pulls/7/reviews/8/comments" => {200, []}
        })
      )

    comments = [
      %{"path" => "a.ex", "body" => "added", "position" => %{"kind" => "added", "newLine" => 4}}
    ]

    assert {:error, {_, message}} =
             Forgejo.submit_review(ctx(base), "comment", "Hm.", comments)

    assert message =~ "Discard it in Forgejo"
    refute Enum.any?(FakeHttp.requests(log), &(&1["method"] == "DELETE"))
  end

  # A failed post whose pending review could not be deleted then leaves one of this
  # review's own comments: the next attempt deletes it and posts.
  test "a pending review left by a failed post of this review is deleted, and the review posted",
       %{tmp_dir: tmp} do
    leftover = %{"id" => 8, "user" => %{"login" => "reviewer"}, "state" => "PENDING"}

    {base, log} =
      serve(
        tmp,
        routes("reviewer", %{
          "/api/v1/repos/acme/shop/pulls/7/reviews" => fn conn ->
            if conn.method == "POST", do: {200, %{"id" => 9}}, else: {200, [leftover]}
          end,
          "/api/v1/repos/acme/shop/pulls/7/reviews/8/comments" =>
            {200, [%{"path" => "a.ex", "body" => "added", "user" => %{"login" => "reviewer"}}]},
          "/api/v1/repos/acme/shop/pulls/7/reviews/8" => {204, nil}
        })
      )

    comments = [
      %{"path" => "a.ex", "body" => "added", "position" => %{"kind" => "added", "newLine" => 4}}
    ]

    assert :ok = Forgejo.submit_review(ctx(base), "comment", "Hm.", comments)

    assert [
             {"DELETE", "/api/v1/repos/acme/shop/pulls/7/reviews/8"},
             {"POST", "/api/v1/repos/acme/shop/pulls/7/reviews"}
           ] =
             for(
               r <- FakeHttp.requests(log),
               r["method"] in ~w(POST DELETE),
               do: {r["method"], r["path"]}
             )
  end

  test "fj's token is not sent to a server over plain HTTP", %{tmp_dir: tmp} do
    {_base, log} = serve(tmp, routes("reviewer"))
    keys = Path.join(tmp, "keys.json")

    File.write!(
      keys,
      JSON.encode!(%{
        "hosts" => %{"forgejo.invalid" => %{"type" => "Application", "token" => "t0ken"}}
      })
    )

    ctx = %{
      cwd: nil,
      remote_url: "http://forgejo.invalid/acme/shop.git",
      repository: "acme/shop",
      number: 7
    }

    assert {:error, {:failed, message}} = Forgejo.detail(ctx)
    assert message =~ "plain HTTP"
    assert FakeHttp.requests(log) == []

    # Nor handed to a clone that fetches from it.
    assert {:ok, %{"url" => "http://forgejo.invalid/acme/shop.git", "token" => nil}} =
             Forgejo.fetch_access(ctx)
  end

  test "stats are the pull request's additions and deletions", %{tmp_dir: tmp} do
    {base, _} = serve(tmp, routes("reviewer"))
    assert {3, 1} = Forgejo.stats(ctx(base))
    assert nil == Forgejo.stats(%{ctx(base) | number: 8})
  end

  test "a clone fetches from the server the API is read on, with fj's token", %{tmp_dir: tmp} do
    {base, _} = serve(tmp, routes("reviewer"))

    assert {:ok, %{"url" => url, "token" => "t0ken", "username" => _, "server" => server}} =
             Forgejo.fetch_access(ctx(base))

    assert url == base <> "/acme/shop.git"
    # The token is for that server, and git may fetch with it from there alone.
    assert server == base
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
