defmodule HalC2.PullRequestSyncKeyPropTest do
  @moduledoc """
  The laws of `HalC2.PullRequests.sync_key/2`
  (`features/mc/orchestration/pull-request-links.feature`, the checkout-scoped
  reference scenarios): every spelling of an Azure DevOps checkout keys its own
  repository's bare name to the one canonical key and nothing else, a reference
  that names a host keeps it, and a key fed back as a reference is itself.
  The function is pure in the identity it is given, so these are plain `forall`s.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.PullRequests

  # GitHub-size names, already lowercase, as `parse_remote/1` hands them on.
  defp name, do: resize(8, non_empty(list(oneof([range(?a, ?z), range(?0, ?9), ?-, ?_]))))

  defp azure_identity do
    let {org, project, repo} <- {name(), name(), name()} do
      let spelling <-
            oneof([
              {"dev.azure.com", "#{org}/#{project}/_git/#{repo}"},
              {"ssh.dev.azure.com", "v3/#{org}/#{project}/#{repo}"},
              {"vs-ssh.visualstudio.com", "v3/#{org}/#{project}/#{repo}"},
              {"#{org}.visualstudio.com", "defaultcollection/#{project}/_git/#{repo}"},
              {"#{org}.visualstudio.com", "#{project}/_git/#{repo}"}
            ]) do
        {%{host: elem(spelling, 0), repository: elem(spelling, 1), kind: "azure-devops"},
         %{org: List.to_string(org), project: List.to_string(project), repo: List.to_string(repo)}}
      end
    end
  end

  property "every Azure DevOps spelling keys the checkout's own repository to the canonical key",
    numtests: HalC2.Prop.numtests(100) do
    forall {identity, parts} <- azure_identity() do
      forall host <-
               oneof([
                 nil,
                 "dev.azure.com",
                 "DEV.AZURE.COM",
                 "ssh.dev.azure.com",
                 "#{parts.org}.visualstudio.com"
               ]) do
        ref =
          %{"repository" => parts.repo, "number" => 7}
          |> then(&if host, do: Map.put(&1, "host", host), else: &1)

        PullRequests.sync_key(ref, identity) ==
          %{
            "host" => "dev.azure.com",
            "repository" => "#{parts.org}/#{parts.project}/_git/#{parts.repo}",
            "number" => 7
          }
      end
    end
  end

  property "an Azure DevOps reference naming anything else is not identified",
    numtests: HalC2.Prop.numtests(100) do
    forall {identity, parts} <- azure_identity() do
      other = parts.repo <> "x"

      PullRequests.sync_key(%{"repository" => other, "number" => 7}, identity) == nil and
        PullRequests.sync_key(
          %{"repository" => parts.repo, "number" => 7, "host" => "unrelated.test"},
          identity
        ) == nil
    end
  end

  property "a host the reference names wins, and the checkout's host is the fallback",
    numtests: HalC2.Prop.numtests(100) do
    forall {owner, repo} <- {name(), name()} do
      repository = "#{List.to_string(owner)}/#{List.to_string(repo)}"
      identity = %{host: "github.com", repository: "acme/app", kind: "github"}

      PullRequests.sync_key(%{"repository" => repository, "number" => 3}, identity) ==
        %{"host" => "github.com", "repository" => repository, "number" => 3} and
        PullRequests.sync_key(
          %{"repository" => repository, "number" => 3, "host" => "gitlab.com"},
          identity
        ) == %{"host" => "gitlab.com", "repository" => repository, "number" => 3} and
        PullRequests.sync_key(%{"repository" => repository, "number" => 3}, nil) == nil
    end
  end

  property "a key fed back as a reference is itself", numtests: HalC2.Prop.numtests(100) do
    forall {identity, parts} <- azure_identity() do
      key = PullRequests.sync_key(%{"repository" => parts.repo, "number" => 1}, identity)
      PullRequests.sync_key(key, nil) == key
    end
  end
end
