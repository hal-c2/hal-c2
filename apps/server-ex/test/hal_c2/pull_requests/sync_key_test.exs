defmodule HalC2.PullRequests.SyncKeyTest do
  @moduledoc """
  `HalC2.PullRequests.sync_key/2` over a given checkout: the examples of
  `features/mc/orchestration/pull-request-links.feature` (a reference tied to
  a checkout), without an MC running.
  """

  use ExUnit.Case, async: true

  alias HalC2.PullRequests

  @github %{host: "github.com", repository: "acme/app", kind: "github"}
  @azure %{host: "dev.azure.com", repository: "org/project/_git/web", kind: "azure-devops"}

  test "a GitHub checkout lends its host, and a named host wins" do
    assert PullRequests.sync_key(%{"repository" => "acme/web", "number" => 7}, @github) ==
             %{"host" => "github.com", "repository" => "acme/web", "number" => 7}

    assert PullRequests.sync_key(
             %{"repository" => "acme/web", "number" => 7, "host" => "gitlab.com"},
             @github
           ) == %{"host" => "gitlab.com", "repository" => "acme/web", "number" => 7}
  end

  test "an Azure DevOps bare name keys the checkout's own repository, and nothing else" do
    assert PullRequests.sync_key(%{"repository" => "web", "number" => 7}, @azure) ==
             %{"host" => "dev.azure.com", "repository" => "org/project/_git/web", "number" => 7}

    assert PullRequests.sync_key(%{"repository" => "other", "number" => 7}, @azure) == nil

    assert PullRequests.sync_key(
             %{"repository" => "web", "number" => 7, "host" => "unrelated.test"},
             @azure
           ) == nil
  end

  test "every spelling of an Azure DevOps remote names the same pull request" do
    for remote <- [
          "https://dev.azure.com/org/project/_git/web",
          "git@ssh.dev.azure.com:v3/org/project/web",
          "org@vs-ssh.visualstudio.com:v3/org/project/web",
          "https://org.visualstudio.com/defaultcollection/project/_git/web"
        ] do
      identity = PullRequests.parse_remote(remote)

      assert PullRequests.sync_key(%{"repository" => "web", "number" => 7}, identity) ==
               %{
                 "host" => "dev.azure.com",
                 "repository" => "org/project/_git/web",
                 "number" => 7
               },
             "remote: #{remote}"
    end
  end
end
