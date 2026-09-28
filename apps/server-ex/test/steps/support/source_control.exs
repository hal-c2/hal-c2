defmodule HalC2.Steps.SourceControl.Shared do
  @moduledoc """
  Setup the `features/source-control/` step files share (loaded before the step
  files, so they can call it). Conventions the step files follow:

    * `context.cwd` - the checkout under test (the project root, or a worktree)
    * `context.thread_title` - the thread a "thread in the git project" step made
    * `context.git_events` - the progress events of the last git action (`World.git_action/5`)
    * `context.reply` - the last RPC reply, `{:ok, result}` or `{:error, error, detail}`
    * `context.writer_log` - the prompts the fake writer model was given (see `writer_prompts/1`)
  """

  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @fake_text Path.expand("../../support/fake_text_cli.py", __DIR__)

  @doc """
  A project `title` with the thread "work" in it, as a real project looks: its
  checkout is on GitHub as `acme/<title>` (`World.github_remote/3`) with a signed-in
  fake `gh` that knows no pull requests yet, and a writer model that answers
  (`test/support/fake_text_cli.py`). The checkout under test is its root.
  """
  def thread_in_git_project(context, title) do
    Node.ensure({Registry, keys: :unique, name: HalC2.Vcs.Registry})
    Node.ensure({DynamicSupervisor, name: HalC2.Vcs.Supervisor, strategy: :one_for_one})
    %{writer_log: writer_log} = answering_writer(context)
    repository = "acme/#{World.slug(title)}"
    context = World.create_project(context, title)
    root = World.project(context, title).root
    bare = World.github_remote(context, root, repository)

    context
    |> World.cli_rules([
      %{"args" => ["api user"], "stdout" => %{"id" => 7, "login" => "monalisa"}},
      %{"args" => ["pr list"], "stdout" => []},
      %{"args" => ["pr create"], "stdout" => "https://github.com/#{repository}/pull/7\n"},
      %{
        "args" => ["repo view"],
        "stderr" => "GraphQL: Could not resolve to a Repository with that name.\n",
        "exit" => 1
      }
    ])
    |> World.create_thread("work", title)
    |> Map.merge(%{
      cwd: root,
      thread_title: "work",
      repository: repository,
      bare: bare,
      writer_log: writer_log
    })
    |> then(&World.put_client(&1, World.client(&1)))
  end

  @doc """
  Makes the model that writes commit messages and PR descriptions answer every field
  it is asked for (`test/support/fake_text_cli.py`) until the scenario ends, logging
  its prompts to `context.writer_log`.
  """
  def answering_writer(context) do
    Node.ensure(HalC2.Settings)
    writer = Application.get_env(:hal_c2, :text_claude_command)
    writer_log = Path.join(Node.tmp_dir(context.node, "writer"), "calls.jsonl")
    Application.put_env(:hal_c2, :text_claude_command, @fake_text)
    System.put_env("FAKE_TEXT_LOG", writer_log)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:hal_c2, :text_claude_command, writer)
      System.delete_env("FAKE_TEXT_LOG")
    end)

    Map.put(context, :writer_log, writer_log)
  end

  @doc "The prompts the fake writer model has been given so far, oldest first."
  def writer_prompts(context) do
    case File.read(context.writer_log) do
      {:ok, text} ->
        text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!(&1)["prompt"])

      _ ->
        []
    end
  end

  @doc """
  Expands `path` of the working tree review the way the diff panel does: reads the
  file's entry from `review.getDiffPreview`, takes its change type from the patch
  header, and asks `review.getDiffFileContents` for both sides. Sets `context.reply`
  to the contents reply and `context.change_type` to the type sent.
  """
  def expand_review_file(context, path) do
    {{:ok, %{"sources" => sources}}, context} =
      World.call(context, "review.getDiffPreview", %{"cwd" => context.cwd})

    source = Enum.find(sources, &(&1["kind"] == "working-tree"))
    entry = Enum.find(source["files"], &(&1["path"] == path))
    assert entry, "#{path} is not in the review: #{inspect(source["files"])}"
    old_path = entry["previousPath"] || path
    type = change_type(source["diff"], old_path, path, entry)

    {reply, context} =
      World.call(context, "review.getDiffFileContents", %{
        "cwd" => context.cwd,
        "sourceKind" => "working-tree",
        "changeType" => type,
        "baseRef" => source["baseRef"],
        "headRef" => source["headRef"],
        "oldPath" => old_path,
        "newPath" => path
      })

    Map.merge(context, %{reply: reply, change_type: type})
  end

  defp change_type(patch, old_path, path, entry) do
    header =
      patch
      |> String.split("diff --git ")
      |> Enum.find(&String.starts_with?(&1, "a/#{old_path} b/#{path}\n"))

    assert header, "no patch for #{path}"

    cond do
      header =~ ~r/^new file mode/m -> "new"
      header =~ ~r/^deleted file mode/m -> "deleted"
      entry["previousPath"] && header =~ ~r/^similarity index 100%/m -> "rename-pure"
      entry["previousPath"] -> "rename-changed"
      true -> "change"
    end
  end

  @doc """
  A pull request of `repository` as `gh pr list --json` / `gh pr view --json` give it,
  open, by "octocat", with `fields` merged over it (GitHub's own names and casing).
  """
  def gh_pr(repository, number, fields \\ %{}) do
    Map.merge(
      %{
        "number" => number,
        "title" => "Pull request #{number}",
        "url" => "https://github.com/#{repository}/pull/#{number}",
        "author" => %{"login" => "octocat"},
        "headRefName" => "feature/#{number}",
        "baseRefName" => "main",
        "state" => "OPEN",
        "isDraft" => false,
        "createdAt" => "2026-09-01T00:00:00Z",
        "updatedAt" => "2026-09-02T00:00:00Z",
        "reviewRequests" => [],
        "latestReviews" => [],
        "labels" => [],
        "statusCheckRollup" => []
      },
      fields
    )
  end

  @doc """
  The fake GitHub's answer to the permission read every pull request action makes
  first: the user's `permission` on the repository (`"WRITE"`, `"READ"`, ...), and
  `pull_request` fields such as `viewerDidAuthor` over the defaults.
  """
  def permissions_rule(permission, pull_request \\ %{}) do
    %{
      "args" => ["api graphql"],
      "stdin" => ["viewerCanUpdate viewerDidAuthor }"],
      "stdout" => %{
        "data" => %{
          "repository" => %{
            "mergeCommitAllowed" => true,
            "squashMergeAllowed" => true,
            "rebaseMergeAllowed" => true,
            "viewerPermission" => permission,
            "pullRequest" =>
              Map.merge(
                %{
                  "viewerCanUpdate" => permission in ["WRITE", "MAINTAIN", "ADMIN"],
                  "viewerDidAuthor" => false
                },
                pull_request
              )
          }
        }
      }
    }
  end

  @pr_node_id "PR_kwDOpr42"
  @pr_sha "5f1d2c0a9e8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d"

  @doc "The GraphQL node id the fake GitHub gives the scenario's pull request."
  def pr_node_id, do: @pr_node_id

  @doc "The head commit of the scenario's pull request."
  def pr_sha, do: @pr_sha

  @doc """
  Pull request `number` of the scenario's only (GitHub) project, open and by
  "octocat" unless `fields` (GitHub's GraphQL names) say otherwise, with the user
  holding write access. Sets `pr_number`, `pr_repository`, `pr_fields`, `permission`
  and `acted` (false until an action runs); `gh pr merge|ready|close|reopen|update-branch`
  and the node id read answer.
  """
  def open_pull_request(context, number, fields \\ %{}) do
    [repository] = Map.keys(context.projects)

    context
    |> Map.merge(%{
      pr_number: number,
      pr_repository: repository,
      pr_fields: fields,
      permission: "WRITE",
      acted: false
    })
    |> World.cli_rules([
      %{"args" => ["pr merge #{number}"], "stdout" => ""},
      %{"args" => ["pr ready #{number}"], "stdout" => ""},
      %{"args" => ["pr close #{number}"], "stdout" => ""},
      %{"args" => ["pr reopen #{number}"], "stdout" => ""},
      %{"args" => ["pr update-branch #{number}"], "stdout" => ""},
      %{
        "args" => ["api graphql"],
        "stdin" => ["pullRequest(number: $number) { id } }"],
        "stdout" => %{"data" => %{"repository" => %{"pullRequest" => %{"id" => @pr_node_id}}}}
      }
    ])
    |> answer_pr()
  end

  @doc "The `pullRequests.*` reference of the scenario's pull request."
  def pr_ref(context),
    do: %{
      "projectId" => World.project(context, context.pr_repository).id,
      "repository" => context.pr_repository,
      "number" => context.pr_number
    }

  @doc "`pullRequests.detail` of the scenario's pull request (`open_pull_request/3`); asserts it answers."
  def pr_detail!(context) do
    {reply, _} = World.call(context, "pullRequests.detail", pr_ref(context))
    assert {:ok, detail} = reply
    detail
  end

  @doc "Merges GitHub `fields` (GraphQL names) into the pull request and answers with it from now on."
  def reshape_pr(context, fields) do
    context |> Map.update!(:pr_fields, &Map.merge(&1, fields)) |> answer_pr()
  end

  @doc """
  Answers GitHub's permission read (every action makes it first) and detail read for
  the pull request as `context.pr_fields` and `context.permission` now describe it.
  """
  def answer_pr(context) do
    fields = context.pr_fields

    can_update =
      Map.get(fields, "viewerCanUpdate", context.permission in ~w(WRITE MAINTAIN ADMIN))

    permissions =
      permissions_rule(context.permission, %{"viewerCanUpdate" => can_update})

    World.cli_rules(context, [permissions, core_rule(context, can_update)])
  end

  defp core_rule(context, can_update) do
    number = context.pr_number

    pr =
      Map.merge(
        %{
          "number" => number,
          "title" => "Add the tax table",
          "url" => "https://github.com/#{context.pr_repository}/pull/#{number}",
          "body" => "Adds the tax table.",
          "state" => "OPEN",
          "isDraft" => false,
          "mergeable" => "MERGEABLE",
          "reviewDecision" => nil,
          "additions" => 10,
          "deletions" => 2,
          "changedFiles" => 3,
          "createdAt" => "2026-09-01T00:00:00Z",
          "updatedAt" => "2026-09-02T00:00:00Z",
          "mergedAt" => nil,
          "closedAt" => nil,
          "headRefName" => "feature/#{number}",
          "baseRefName" => "main",
          "headRefOid" => @pr_sha,
          "isCrossRepository" => false,
          "headRepositoryOwner" => %{"login" => "acme"},
          "author" => %{"login" => "octocat", "avatarUrl" => nil},
          "autoMergeRequest" => nil,
          "viewerDidAuthor" => false,
          "viewerCanUpdateBranch" => false,
          "baseRef" => %{"compare" => %{"behindBy" => 0}},
          "reviewRequests" => %{"nodes" => []},
          "labels" => %{"nodes" => []},
          "commits" => pr_commits([%{"status" => "COMPLETED", "conclusion" => "SUCCESS"}])
        },
        context.pr_fields
      )
      |> Map.put("viewerCanUpdate", can_update)

    %{
      "args" => ["api graphql"],
      "stdin" => ["viewerCanUpdateBranch"],
      "stdout" => %{
        "data" => %{
          "repository" => %{
            "mergeCommitAllowed" => true,
            "squashMergeAllowed" => true,
            "rebaseMergeAllowed" => true,
            "viewerPermission" => context.permission,
            "pullRequest" => pr
          }
        }
      }
    }
  end

  @doc "The `commits` connection of a pull request whose head commit ran `checks` (CheckRun fields)."
  def pr_commits(checks) do
    %{
      "nodes" => [
        %{
          "commit" => %{
            "statusCheckRollup" => %{
              "contexts" => %{
                "nodes" =>
                  for(
                    c <- checks,
                    do: Map.merge(%{"__typename" => "CheckRun", "name" => "build"}, c)
                  ),
                "pageInfo" => %{"hasNextPage" => false}
              }
            }
          }
        }
      ]
    }
  end

  @providers %{
    "GitHub" => "github",
    "GitLab" => "gitlab",
    "Forgejo" => "forgejo",
    "Azure DevOps" => "azure-devops",
    "Bitbucket" => "bitbucket"
  }

  @doc "The `SourceControlProviderKind` of a host as the scenarios name it."
  def provider(host), do: Map.fetch!(@providers, host)

  @doc """
  Makes the host's CLI (`gh` or `glab`) know `repository`, with `urls` (`"url"`,
  `"sshUrl"`) overriding its usual web and SSH addresses. The answer goes after the
  rules already there, so a scenario that set up its own answer keeps it. Hosts
  without a CLI get no answer.
  """
  def answer_lookup(context, provider, repository, urls \\ %{}) do
    context = World.fake_cli(context, ["gh", "glab", "az", "tea"])
    url = urls["url"]
    ssh = urls["sshUrl"]

    rule =
      case provider do
        "github" ->
          %{
            "cmd" => "gh",
            "args" => ["repo view #{repository} "],
            "stdout" => %{
              "nameWithOwner" => repository,
              "url" => url || "https://github.com/#{repository}",
              "sshUrl" => ssh || "git@github.com:#{repository}.git"
            }
          }

        "gitlab" ->
          %{
            "cmd" => "glab",
            "args" => ["repo view #{repository} "],
            "stdout" => %{
              "path_with_namespace" => repository,
              "web_url" => url || "https://gitlab.com/#{repository}",
              "http_url_to_repo" => "https://gitlab.com/#{repository}.git",
              "ssh_url_to_repo" => ssh || "git@gitlab.com:#{repository}.git"
            }
          }

        "azure-devops" ->
          [owner, name] = String.split(repository, "/")

          %{
            "cmd" => "az",
            "args" => ["repos show", "--repository #{repository} "],
            "stdout" => %{
              "name" => name,
              "project" => %{"name" => owner},
              "webUrl" => "https://dev.azure.com/#{owner}/#{owner}/_git/#{name}",
              "remoteUrl" =>
                url || "https://#{owner}@dev.azure.com/#{owner}/#{owner}/_git/#{name}",
              "sshUrl" => ssh || "git@ssh.dev.azure.com:v3/#{owner}/#{owner}/#{name}"
            }
          }

        "forgejo" ->
          [
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
              "args" => [
                "api",
                "--login codeberg",
                "https://codeberg.org/api/v1/repos/#{repository}"
              ],
              "stderr" => "HTTP/2.0 200 OK\n",
              "stdout" => %{
                "full_name" => repository,
                "clone_url" => url || "https://codeberg.org/#{repository}.git",
                "ssh_url" => ssh || "git@codeberg.org:#{repository}.git"
              }
            }
          ]

        "bitbucket" ->
          fake_bitbucket(context)
          nil
      end

    if rule do
      existing = context.cli.rules |> File.read!() |> JSON.decode!()
      File.write!(context.cli.rules, JSON.encode!(existing ++ List.wrap(rule)))
    end

    context
  end

  @doc """
  A fake Bitbucket API (`HalC2.Steps.SourceControl.FakeBitbucket`) the node reaches
  through `HAL_C2_BITBUCKET_API_BASE_URL`, with `HAL_C2_BITBUCKET_ACCESS_TOKEN` set
  to the token it knows as octocat's, until the scenario ends.
  """
  def fake_bitbucket(context) do
    server =
      Node.ensure({Bandit, plug: HalC2.Steps.SourceControl.FakeBitbucket, port: 0, ip: :loopback})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    put_env("HAL_C2_BITBUCKET_API_BASE_URL", "http://127.0.0.1:#{port}/2.0")
    put_env("HAL_C2_BITBUCKET_ACCESS_TOKEN", HalC2.Steps.SourceControl.FakeBitbucket.token())
    context
  end

  @doc "Sets an OS environment variable until the scenario ends."
  def put_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    ExUnit.Callbacks.on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end
end

defmodule HalC2.Steps.SourceControl.FakeBitbucket do
  @moduledoc false
  # Bitbucket's `/user` and `/repositories/{workspace}/{slug}` for one token.
  @behaviour Plug

  @token "bitbucket-token"
  def token, do: @token

  def init(opts), do: opts

  def call(conn, _opts) do
    authorized? = Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]

    case {authorized?, String.split(conn.request_path, "/", trim: true)} do
      {false, _} ->
        Plug.Conn.send_resp(conn, 401, "")

      {true, ["2.0", "user"]} ->
        json(conn, %{"username" => "octocat", "account_id" => "1"})

      {true, ["2.0", "repositories", workspace, slug]} ->
        name = "#{workspace}/#{slug}"

        json(conn, %{
          "full_name" => name,
          "links" => %{
            "html" => %{"href" => "https://bitbucket.org/#{name}"},
            "clone" => [
              %{"name" => "https", "href" => "https://bitbucket.org/#{name}.git"},
              %{"name" => "ssh", "href" => "git@bitbucket.org:#{name}.git"}
            ]
          }
        })

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(body))
end
