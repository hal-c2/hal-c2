defmodule HalC2.PullRequests.GitHubSummariesTest do
  @moduledoc """
  `HalC2.PullRequests.GitHub.summaries/2` against the fake `gh`: the merge-queue
  fields ride the batched read, and a host whose schema has no merge queue (an
  older GitHub Enterprise) is read again without them instead of losing every
  summary on it.
  """

  use ExUnit.Case, async: false

  alias HalC2.PullRequests.GitHub

  @moduletag :tmp_dir
  @fake_gh Path.expand("../../support/fake_gh.py", __DIR__)

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :gh_command)
    Application.put_env(:hal_c2, :gh_command, @fake_gh)
    System.put_env("FAKE_GH_RULES", Path.join(dir, "rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(dir, "gh.log"))
    File.write!(Path.join(dir, "gh.log"), "")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :gh_command, previous),
        else: Application.delete_env(:hal_c2, :gh_command)

      System.delete_env("FAKE_GH_RULES")
      System.delete_env("FAKE_GH_LOG")
    end)

    %{dir: dir}
  end

  defp pr_node(extra \\ %{}) do
    Map.merge(
      %{
        "number" => 12,
        "title" => "PR 12",
        "url" => "https://ghes.test/acme/app/pull/12",
        "state" => "OPEN",
        "isDraft" => false,
        "mergeable" => "MERGEABLE",
        "headRefName" => "feature/12",
        "baseRefName" => "main",
        "updatedAt" => "2030-01-01T00:00:00Z",
        "mergedAt" => nil,
        "closedAt" => nil,
        "author" => %{"__typename" => "User", "login" => "monalisa"},
        "commits" => %{"nodes" => []},
        "comments" => %{"nodes" => []},
        "reviews" => %{"nodes" => []}
      },
      extra
    )
  end

  defp serve(dir, rules), do: File.write!(Path.join(dir, "rules.json"), JSON.encode!(rules))

  defp asked_with_queue(dir) do
    dir
    |> Path.join("gh.log")
    |> File.read!()
    |> String.split("mergeQueueEntry")
    |> length()
    |> Kernel.-(1)
  end

  test "the summary carries the queue entry and the latest removal", %{dir: dir} do
    host = "ghes-queue-#{System.unique_integer([:positive])}.test"

    serve(dir, [
      %{
        "args" => ["api graphql"],
        "stdin" => ["PullRequestSummaries"],
        "viewer" => "monalisa",
        "summaries" => %{
          "acme/app#12" =>
            pr_node(%{
              "mergeQueueEntry" => %{"state" => "AWAITING_CHECKS", "position" => 2},
              "mergeQueueRemoval" => %{
                "nodes" => [%{"createdAt" => "2030-01-01T00:00:10Z", "reason" => "failed_checks"}]
              }
            })
        }
      }
    ])

    ctx = %{cwd: dir, host: host}
    assert %{{"acme/app", 12} => summary} = GitHub.summaries(ctx, [{"acme/app", 12}])
    assert summary["mergeQueue"] == %{"state" => "awaiting-checks", "position" => 2}

    assert summary["mergeQueueRemoval"] == %{
             "at" => "2030-01-01T00:00:10Z",
             "reason" => "failed_checks"
           }
  end

  test "a host with no merge queue in its schema is read again without the queue fields",
       %{dir: dir} do
    host = "ghes-old-#{System.unique_integer([:positive])}.test"

    serve(dir, [
      %{
        "args" => ["api graphql"],
        "stdin" => ["mergeQueueEntry"],
        "stderr" => "gh: Field 'mergeQueueEntry' doesn't exist on type 'PullRequest'\n",
        "exit" => 1
      },
      %{
        "args" => ["api graphql"],
        "stdin" => ["PullRequestSummaries"],
        "viewer" => "monalisa",
        "summaries" => %{"acme/app#12" => pr_node()}
      }
    ])

    ctx = %{cwd: dir, host: host}
    assert %{{"acme/app", 12} => summary} = GitHub.summaries(ctx, [{"acme/app", 12}])
    assert summary["state"] == "open"
    assert summary["mergeQueue"] == nil
    assert summary["mergeQueueRemoval"] == nil

    # And the host is not asked for the queue fields again.
    assert %{{"acme/app", 12} => _} = GitHub.summaries(ctx, [{"acme/app", 12}])
    assert asked_with_queue(dir) == 1
  end
end
