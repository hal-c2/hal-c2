defmodule HalC2.Steps.SourceControl.AgentCodeReviewForgejo do
  @moduledoc """
  Steps for `features/source-control/agent-code-review-forgejo.feature`, run against
  the real package in `plugins/code-review` as a user installs it.

  The project's origin is on codeberg.org, a Forgejo host, whose API is a fake
  (`HalC2.Steps.SourceControl.Shared.forgejo_api/3`) signed in as "octocat" with fj's
  token. The same fake serves the repository over git's smart HTTP under `/git`,
  through `git http-backend`, and turns away a request without that token; git is
  sent there by an `insteadOf` for `https://codeberg.org/`, which the project's SSH
  origin is out of the way of. The one pull request, #7,
  has its head at `refs/pull/7/head`; what the scenario changes of it and what was
  posted are kept in an Agent (`context.forgejo_pr`). Reviews run on the fake Codex
  with a prompt that keeps the turn open, and report through the MCP tool.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @id "code-review"
  @package Path.expand("../../../../../plugins/code-review", __DIR__)
  @prompt "Review \#{{pr.number}} {{pr.title}} in {{repository}}. answer from gate"
  @host "codeberg.org"
  @token "fj-token"
  @cart "export const total = 0;\nexport const tax = 1;\nexport const ship = 2;\n"

  step "an MC running the plugin {string} with Forgejo as its host", %{args: [@id]} = context do
    dir = Path.join([context.mc.home, "plugins", @id])
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(@package, dir)
    context = context |> World.agents() |> Fixtures.ensure() |> Fixtures.rescan()

    Mc.ensure(HalC2.Mcp)
    Mc.ensure({Registry, keys: :unique, name: HalC2.Vcs.Registry})
    Mc.ensure({DynamicSupervisor, name: HalC2.Vcs.Supervisor, strategy: :one_for_one})
    accepted = Enum.map(Fixtures.entry(@id)["permissions"], & &1["id"])

    {_, context} =
      World.call!(context, "plugins.enable", %{"id" => @id, "acceptPermissions" => accepted})

    assert %{"status" => "running"} = Fixtures.entry(@id)
    watch(context)
  end

  step "the project {string} whose remote is {string} on Forgejo",
       %{args: [title, repository]} = context do
    context = World.create_project(context, title)
    root = World.project(context, title).root
    remotes = Mc.tmp_dir(context.mc, "forgejo-remotes")
    bare = Path.join(remotes, "#{repository}.git")
    File.mkdir_p!(Path.dirname(bare))
    World.git!(remotes, ["init", "-q", "--bare", "-b", "main", bare])
    World.git!(root, ["push", "-q", bare, "HEAD:refs/heads/main"])
    # Over SSH, as a user's checkout often is; the plugin still fetches over HTTPS.
    World.git!(root, ["remote", "add", "origin", "git@#{@host}:#{repository}.git"])

    # The pull request's head, pushed from a clone of its own.
    source = Path.join(Mc.tmp_dir(context.mc, "forgejo-source"), "repo")
    World.git!(Path.dirname(source), ["clone", "-q", bare, source])
    base = World.git!(source, ~w(rev-parse HEAD))
    World.git!(source, ~w(checkout -q -b fix-cart))
    head = World.commit!(source, %{"src/cart.ts" => @cart}, "Fix the cart")
    World.git!(source, ~w(push -q origin HEAD:refs/pull/7/head HEAD:refs/heads/fix-cart))

    pr =
      ExUnit.Callbacks.start_supervised!(
        {Agent,
         fn -> %{repository: repository, head: head, base: base, author: "maint", posted: []} end},
        id: :forgejo_review_pr
      )

    context =
      context
      |> Map.merge(%{forgejo_pr: pr, repository: repository, git_root: remotes})
      |> Shared.forgejo_api(routes(pr, repository, remotes), @host)

    # The plugin's clone fetches the server over HTTPS; here that is the fake's `/git`.
    api = System.get_env("HAL_C2_FORGEJO_API_BASE_URL")
    Shared.put_env("GIT_CONFIG_COUNT", "1")
    Shared.put_env("GIT_CONFIG_KEY_0", "url.#{api}/git/.insteadOf")
    Shared.put_env("GIT_CONFIG_VALUE_0", "https://#{@host}/")

    save(context, %{
      "host" => "forgejo",
      "provider" => "codex",
      "model" => "fake/one",
      "prompt" => @prompt,
      "pollMinutes" => 60,
      "repositories" => [repository],
      "activation" => "selective",
      "publishing" => "draft",
      "readReviewMd" => false
    })
  end

  step "{string} posts its reviews automatically", %{args: [@id]} = context do
    save(context, %{"publishing" => "automatic"})
  end

  step "Forgejo pull request \#{int} is opened by {string}, who is no collaborator of {string}",
       %{args: [7, author, _repository]} = context do
    Agent.update(context.forgejo_pr, &%{&1 | author: author})
    context
  end

  step "the user asks for a review of Forgejo pull request \#{int}",
       %{args: [number]} = context do
    {reply, context} =
      World.call(context, "plugins.call", %{
        "id" => @id,
        "method" => "start",
        "input" => %{"repository" => context.repository, "number" => number}
      })

    Map.put(context, :reply, reply)
  end

  step "its thread works in a checkout of the head of Forgejo pull request \#{int}",
       %{args: [number]} = context do
    assert {:ok, _} = context.reply
    {review, context} = await_review(context, number, &(&1["threadId"] && &1["checkout"]))
    World.await_row(review["threadId"], & &1)
    assert World.git!(review["checkout"], ~w(rev-parse HEAD)) == head(context)

    assert World.git!(review["checkout"], ~w(config remote.origin.url)) ==
             "https://#{@host}/#{context.repository}.git"

    Map.merge(context, %{thread: review["threadId"], review: review})
  end

  step "the plugin fetched it from Forgejo with fj's token", context do
    fetches =
      for r <- HalC2.Test.FakeHttp.requests(context.forgejo),
          r["path"] == "/git/#{context.repository}.git/git-upload-pack",
          do: r

    assert [_ | _] = fetches
    assert Enum.all?(fetches, &(password(&1["authorization"]) == @token))
    context
  end

  step "the plugin's clone does not keep the token", context do
    common =
      World.git!(
        context.review["checkout"],
        ~w(rev-parse --path-format=absolute --git-common-dir)
      )

    # `grep` exits 1 when nothing matches.
    assert {_, 1} =
             System.cmd("grep", ["-r", "-l", "--exclude-dir=objects", @token, common],
               stderr_to_stdout: true
             )

    context
  end

  step "its agent requests changes with a comment on line {int} of {string}",
       %{args: [line, path]} = context do
    {review, context} = await_review(context, 7, &(&1["threadId"] && &1["checkout"]))
    context = Map.put(context, :thread, review["threadId"])

    result =
      call_report(context, %{
        "verdict" => "request-changes",
        "summary" => "One thing.",
        "comments" => [%{"path" => path, "line" => line, "body" => "Tax is wrong."}]
      })

    assert result["isError"] != true, inspect(result)
    Map.merge(context, %{told: result, comment: {path, line}})
  end

  step "Forgejo has a review of \#{int} requesting changes, with that comment on line {int} of the new file",
       %{args: [7, line]} = context do
    {_, context} = await_review(context, 7, &(&1["status"] == "published"))
    {path, ^line} = context.comment

    assert [posted] = Agent.get(context.forgejo_pr, & &1.posted)
    assert %{"event" => "REQUEST_CHANGES", "body" => body, "comments" => [comment]} = posted
    assert body =~ "One thing."
    assert %{"path" => ^path, "new_position" => ^line, "body" => text} = comment
    assert text =~ "Tax is wrong."
    refute Map.has_key?(comment, "old_position")
    context
  end

  step "the review of Forgejo pull request \#{int} is marked as published",
       %{args: [number]} = context do
    {review, context} = await_review(context, number, &(&1["status"] == "published"))
    assert review["publishError"] in [nil, ""]
    assert inspect(context.told) =~ "The review is posted to the pull request."
    context
  end

  step "the user is told to approve Forgejo pull request \#{int} on the Reviews page first",
       %{args: [7]} = context do
    assert {:error, message, _} = context.reply
    assert message =~ "Approve it on the Reviews page"
    assert Agent.get(context.forgejo_pr, & &1.posted) == []
    context
  end

  # --- the host ---------------------------------------------------------------------

  defp routes(pr, repository, git_root) do
    base = "/api/v1/repos/#{repository}"
    git = "/git/#{repository}.git"

    %{
      "/api/v1/user" => {200, %{"login" => "octocat"}},
      "#{base}/collaborators" => {200, [%{"login" => "maint"}]},
      "#{base}/pulls" => fn _conn -> {200, [Agent.get(pr, &pull/1)]} end,
      "#{base}/pulls/7" => fn _conn -> {200, Agent.get(pr, &pull/1)} end,
      "#{base}/pulls/7/reviews" => fn conn ->
        if conn.method == "POST" do
          posted = JSON.decode!(conn.assigns.fake_http_body)
          Agent.update(pr, &%{&1 | posted: &1.posted ++ [posted]})
          {200, Map.put(posted, "id", 1)}
        else
          {200, []}
        end
      end,
      "#{base}/issues/7/comments" => {200, []},
      "#{base}/issues/7/timeline" => {200, []},
      "#{git}/info/refs" => &git_http(&1, git_root),
      "#{git}/git-upload-pack" => &git_http(&1, git_root)
    }
  end

  defp pull(pr) do
    %{
      "number" => 7,
      "title" => "Fix the cart",
      "body" => "",
      "html_url" => "https://#{@host}/#{pr.repository}/pulls/7",
      "state" => "open",
      "merged" => false,
      "draft" => false,
      "mergeable" => true,
      "head" => %{
        "ref" => "fix-cart",
        "sha" => pr.head,
        "repo" => %{"id" => 1, "owner" => %{"login" => "acme"}}
      },
      "base" => %{
        "ref" => "main",
        "sha" => pr.base,
        "repo" => %{"id" => 1, "owner" => %{"login" => "acme"}}
      },
      "labels" => [],
      "additions" => 3,
      "deletions" => 0,
      "created_at" => "2030-01-01T10:00:00Z",
      "updated_at" => "2030-01-01T10:00:00Z",
      "user" => %{"login" => pr.author},
      "requested_reviewers" => []
    }
  end

  # git's smart HTTP for the repositories under `root`, as `git http-backend` answers
  # it, to a request carrying fj's token as its password; any other is asked to sign in.
  defp git_http(conn, root) do
    import Plug.Conn

    if password(List.first(get_req_header(conn, "authorization"))) == @token do
      body = Path.join(root, "request-#{System.unique_integer([:positive])}")
      File.write!(body, conn.assigns.fake_http_body)
      header = &(List.first(get_req_header(conn, &1)) || "")

      {out, 0} =
        System.cmd("sh", ["-c", ~s(exec git http-backend < "$1"), "sh", body],
          env: [
            {"GIT_PROJECT_ROOT", root},
            {"GIT_HTTP_EXPORT_ALL", "1"},
            {"PATH_INFO", String.replace_prefix(conn.request_path, "/git", "")},
            {"REQUEST_METHOD", conn.method},
            {"QUERY_STRING", conn.query_string},
            {"CONTENT_TYPE", header.("content-type")},
            {"CONTENT_LENGTH", "#{byte_size(conn.assigns.fake_http_body)}"},
            {"HTTP_CONTENT_ENCODING", header.("content-encoding")},
            {"GIT_PROTOCOL", header.("git-protocol")},
            {"REMOTE_ADDR", "127.0.0.1"}
          ]
        )

      [head, payload] = String.split(out, ~r/\r?\n\r?\n/, parts: 2)

      {status, conn} =
        head
        |> String.split(~r/\r?\n/)
        |> Enum.reduce({200, conn}, fn line, {status, conn} ->
          case String.split(line, ": ", parts: 2) do
            ["Status", value] -> {String.to_integer(hd(String.split(value))), conn}
            [name, value] -> {status, put_resp_header(conn, String.downcase(name), value)}
            _ -> {status, conn}
          end
        end)

      send_resp(conn, status, payload)
    else
      conn
      |> put_resp_header("www-authenticate", ~s(Basic realm="Forgejo"))
      |> send_resp(401, "")
    end
  end

  defp password("Basic " <> encoded) do
    case encoded |> Base.decode64!() |> String.split(":", parts: 2) do
      [_user, password] -> password
      _ -> nil
    end
  end

  defp password(_), do: nil

  # --- the plugin -------------------------------------------------------------------

  defp head(context), do: Agent.get(context.forgejo_pr, & &1.head)

  defp save(context, patch) do
    {_, context} =
      World.call!(context, "plugins.saveSettings", %{"id" => @id, "settings" => patch})

    context
  end

  defp watch(context) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "reviews"
    }

    client = context |> World.client("reviews") |> Mc.sub(sub, shape)

    context
    |> World.put_client("reviews", client)
    |> Map.merge(%{reviews_sub: sub, reviews_last: nil})
  end

  # `{review, context}` once `done?` holds for the review of `number` on the plugin's
  # `reviews` topic; the last value seen is kept, as the topic only moves forward.
  defp await_review(context, number, done?) do
    found = fn value ->
      with %{"reviews" => reviews} <- value,
           %{} = review <- Enum.find(reviews, &(&1["number"] == number)),
           true <- !!done?.(review),
           do: review,
           else: (_ -> nil)
    end

    if review = found.(context.reviews_last) do
      {review, context}
    else
      sub = context.reviews_sub

      {frame, client} =
        Mc.await(
          World.client(context, "reviews"),
          &(&1["t"] == "plugin" and &1["id"] == sub and found.(&1["value"])),
          10_000
        )

      context =
        context |> World.put_client("reviews", client) |> Map.put(:reviews_last, frame["value"])

      {found.(frame["value"]), context}
    end
  end

  defp call_report(context, arguments) do
    %{authorization: auth} = HalC2.Mcp.server(context.thread, "codex")

    {200, %{"result" => result}} =
      HalC2.Mcp.handle(
        auth,
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "code_review_report", "arguments" => arguments}
        })
      )

    result
  end
end
