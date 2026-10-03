defmodule HalC2.Steps.SourceControl.StatusChangeRequests do
  @moduledoc """
  Steps for the change requests of hosts other than GitHub in
  `features/source-control/status-and-changes.feature`. GitLab, Azure DevOps and
  Forgejo are the fake CLI under their own names (`glab`, `az`, `tea`), Bitbucket a
  local server in place of its API (`HAL_C2_BITBUCKET_API_BASE_URL`). Each host
  answers in its own shape, with a change request of another branch beside the one
  asked for where the host leaves the choosing to the MC.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @branch "feature/tax"
  @title "Add the tax table"
  @token "bitbucket-status-token"

  @remotes %{
    "GitLab" => "git@gitlab.com:acme/shop.git",
    "Forgejo" => "git@codeberg.org:acme/shop.git",
    "Azure DevOps" => "git@ssh.dev.azure.com:v3/acme/acme/shop",
    "Bitbucket" => "git@bitbucket.org:acme/shop.git"
  }

  @urls %{
    "GitLab" => "https://gitlab.com/acme/shop/-/merge_requests/5",
    "Forgejo" => "https://codeberg.org/acme/shop/pulls/5",
    "Azure DevOps" => "https://dev.azure.com/acme/acme/_git/shop/pullrequest/5",
    "Bitbucket" => "https://bitbucket.org/acme/shop/pull-requests/5"
  }

  # Bitbucket's pull requests of acme/shop for one token: the one whose source branch
  # the query names, and none for any other query.
  defmodule Bitbucket do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, %{test: test, token: token, pull_request: pull_request, branch: branch}) do
      conn = Plug.Conn.fetch_query_params(conn)
      send(test, {:bitbucket_request, conn.request_path, conn.query_params["q"]})

      cond do
        Plug.Conn.get_req_header(conn, "authorization") != ["Bearer " <> token] ->
          Plug.Conn.send_resp(conn, 401, "")

        conn.request_path == "/2.0/repositories/acme/shop/pullrequests" ->
          asked? = (conn.query_params["q"] || "") =~ ~s(source.branch.name = "#{branch}")

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            JSON.encode!(%{"values" => if(asked?, do: [pull_request], else: [])})
          )

        true ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end
  end

  step ~r/^"(?<title>[^"]+)" has its primary remote on (?<host>GitLab|Forgejo|Azure DevOps|Bitbucket)$/,
       %{args: [title, host]} = context do
    assert World.project(context, title).root == context.cwd
    World.git!(context.cwd, ["remote", "set-url", "origin", @remotes[host]])
    Map.put(context, :host, host)
  end

  step "the current branch has an open change request there", context do
    World.git!(context.cwd, ["checkout", "-q", "-b", @branch])
    context |> World.fake_cli(["gh", "glab", "az", "tea"]) |> open_change_request(context.host)
  end

  step "the status carries that change request", context do
    assert {:ok, status} = context.reply

    assert %{
             "number" => 5,
             "title" => @title,
             "baseRef" => "main",
             "headRef" => @branch,
             "state" => "open",
             "isDraft" => false
           } = status["pr"]

    assert status["pr"]["url"] == @urls[context.host]
    assert status["refName"] == @branch
    assert_asked(context, context.host)
    context
  end

  defp open_change_request(context, "GitLab") do
    World.cli_rules(context, [
      %{
        "cmd" => "glab",
        "args" => ["mr list", "--source-branch #{@branch}"],
        "stdout" => [
          %{
            "iid" => 5,
            "title" => @title,
            "web_url" => @urls["GitLab"],
            "source_branch" => @branch,
            "target_branch" => "main",
            "state" => "opened",
            "draft" => false,
            "updated_at" => "2026-09-20T10:00:00Z"
          }
        ]
      }
    ])
  end

  defp open_change_request(context, "Azure DevOps") do
    World.cli_rules(context, [
      %{
        "cmd" => "az",
        "args" => ["repos pr list", "--source-branch #{@branch}"],
        "stdout" => [
          %{
            "pullRequestId" => 5,
            "title" => @title,
            "sourceRefName" => "refs/heads/#{@branch}",
            "targetRefName" => "refs/heads/main",
            "status" => "active",
            "isDraft" => false,
            "creationDate" => "2026-09-20T10:00:00Z",
            "repository" => %{"webUrl" => "https://dev.azure.com/acme/acme/_git/shop"}
          }
        ]
      }
    ])
  end

  defp open_change_request(context, "Forgejo") do
    pull = fn number, branch ->
      %{
        "number" => number,
        "title" => if(number == 5, do: @title, else: "Another change"),
        "html_url" => "https://codeberg.org/acme/shop/pulls/#{number}",
        "state" => "open",
        "merged" => false,
        "draft" => false,
        "base" => %{"ref" => "main"},
        "head" => %{"ref" => branch},
        "updated_at" => "2026-09-20T10:00:00Z"
      }
    end

    World.cli_rules(context, [
      %{
        "cmd" => "tea",
        "args" => ["login list"],
        "stdout" => [
          %{
            "name" => "codeberg",
            "url" => "https://codeberg.org",
            "user" => "octocat",
            "default" => "true",
            "valid" => "true"
          }
        ]
      },
      %{
        "cmd" => "tea",
        "args" => ["api", "--login codeberg", "/api/v1/repos/acme/shop/pulls?state=all"],
        "stderr" => "HTTP/2.0 200 OK\n",
        "stdout" => [pull.(6, "feature/other"), pull.(5, @branch)]
      }
    ])
  end

  defp open_change_request(context, "Bitbucket") do
    pull_request = %{
      "id" => 5,
      "title" => @title,
      "state" => "OPEN",
      "draft" => false,
      "updated_on" => "2026-09-20T10:00:00Z",
      "links" => %{"html" => %{"href" => @urls["Bitbucket"]}},
      "source" => %{"branch" => %{"name" => @branch}},
      "destination" => %{"branch" => %{"name" => "main"}}
    }

    server =
      Mc.ensure(
        {Bandit,
         plug:
           {Bitbucket,
            %{test: self(), token: @token, pull_request: pull_request, branch: @branch}},
         port: 0,
         ip: :loopback}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Shared.put_env("HAL_C2_BITBUCKET_API_BASE_URL", "http://127.0.0.1:#{port}/2.0")
    Shared.put_env("HAL_C2_BITBUCKET_ACCESS_TOKEN", @token)
    context
  end

  defp assert_asked(context, "GitLab"),
    do: assert([%{"cmd" => "glab"} | _] = World.cli_calls(context, "--source-branch #{@branch}"))

  defp assert_asked(context, "Azure DevOps"),
    do: assert([%{"cmd" => "az"} | _] = World.cli_calls(context, "--source-branch #{@branch}"))

  defp assert_asked(context, "Forgejo"),
    do: assert([%{"cmd" => "tea"} | _] = World.cli_calls(context, "repos/acme/shop/pulls"))

  defp assert_asked(_context, "Bitbucket") do
    assert_received {:bitbucket_request, "/2.0/repositories/acme/shop/pullrequests", query}
    assert query =~ ~s(source.branch.name = "#{@branch}")
  end
end
