defmodule HalC2.PullRequests.GitHubTrustTest do
  # Who stands behind a pull request, read from GitHub's real answers: the fixtures in
  # test/fixtures/github_trust are what github.com gave the trust query for public pull
  # requests (comment bodies cut to their first line), and what its collaborator
  # permission endpoint gives. Synthetic cases say so.
  use ExUnit.Case, async: false

  alias HalC2.PullRequests.GitHub

  @moduletag :tmp_dir
  @fake_gh Path.expand("../../support/fake_gh.py", __DIR__)
  @fixtures Path.expand("../../fixtures/github_trust", __DIR__)

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :gh_command)
    Application.put_env(:hal_c2, :gh_command, @fake_gh)
    System.put_env("FAKE_GH_RULES", Path.join(dir, "rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(dir, "gh.log"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :gh_command, previous),
        else: Application.delete_env(:hal_c2, :gh_command)

      System.delete_env("FAKE_GH_RULES")
      System.delete_env("FAKE_GH_LOG")
    end)

    %{dir: dir}
  end

  # Reads `name`'s trust for `label`, GitHub answering the trust query with the fixture
  # (changed by `edit`) and each login's permission with the named answer.
  defp trust(context, name, label, permissions \\ %{}, edit \\ & &1) do
    answer = @fixtures |> Path.join("#{name}.json") |> File.read!() |> JSON.decode!() |> edit.()
    known = @fixtures |> Path.join("permissions.json") |> File.read!() |> JSON.decode!()

    rules =
      for(
        {login, kind} <- permissions,
        do: Map.put(known[kind], "args", ["collaborators/#{login}/permission"])
      ) ++ [%{"args" => ["api graphql"], "stdin" => ["PullRequestTrust"], "stdout" => answer}]

    File.write!(Path.join(context.dir, "rules.json"), JSON.encode!(rules))
    File.write!(Path.join(context.dir, "gh.log"), "")
    [owner, repo, number] = Regex.run(~r/^(.+)_(.+)_(\d+)$/, name, capture: :all_but_first)

    {:ok, trust} =
      GitHub.trust(
        %{
          cwd: context.dir,
          host: "github.com",
          repository: "#{owner}/#{repo}",
          number: String.to_integer(number)
        },
        label
      )

    trust
  end

  defp permission_reads(context) do
    context.dir
    |> Path.join("gh.log")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(&(&1 =~ "/permission"))
  end

  test "a member's own pull request from the repository itself", context do
    trust = trust(context, "hal-c2_hal-c2_1423", nil)

    assert %{
             "viewer" => "olafura",
             "author" => %{
               "login" => "olafura",
               "isUser" => true,
               "isBot" => false,
               "association" => "MEMBER"
             },
             "isCrossRepository" => false,
             "headOwner" => "hal-c2",
             "headSha" => "ea695370b969f690750b29fff859ece7d904dfd0"
           } = trust

    # The user asked a bot for its review, never themselves: GitHub names no user.
    assert trust["requested"] == nil
  end

  test "a fork deleted since still names whose fork it was", context do
    trust = trust(context, "cli_cli_14823", "external")

    assert %{
             "author" => %{"login" => "Hrushikesh-ramilla", "association" => "NONE"},
             "isCrossRepository" => true,
             "headOwner" => "Hrushikesh-ramilla"
           } = trust

    # Its label was added by an app, whose permission is not read by its login.
    assert %{"login" => "github-actions", "isBot" => true, "isUser" => false, "role" => nil} =
             trust["labeled"]

    assert permission_reads(context) == []

    # A bot's comment carries the association GitHub gives the app, never a trusted one.
    assert [%{"login" => "github-actions", "isBot" => true, "association" => "CONTRIBUTOR"}] =
             trust["comments"]
  end

  test "a fork with neither its repository nor its owner left names no one", context do
    trust =
      trust(context, "cli_cli_14823", nil, %{}, fn answer ->
        put_in(answer, ["data", "repository", "pullRequest", "headRepositoryOwner"], nil)
      end)

    assert %{"isCrossRepository" => true, "headOwner" => nil} = trust
  end

  test "an app's own pull request, labelled and asked for review by the app", context do
    trust = trust(context, "cli_cli_14906", "go")

    assert %{"login" => "dependabot", "isBot" => true, "isUser" => false} = trust["author"]
    assert trust["author"]["association"] == "CONTRIBUTOR"
    assert %{"login" => "dependabot", "isBot" => true, "role" => nil} = trust["labeled"]
    assert trust["requested"] == nil
    assert permission_reads(context) == []
  end

  test "a user's label has the permission GitHub gives them, or none it would not say",
       context do
    for {kind, role} <- [
          {"admin", "admin"},
          {"read", "read"},
          {"no push access", nil},
          {"not a user", nil}
        ] do
      trust = trust(context, "nodejs_node_67326", "invalid", %{"MikeMcC399" => kind})

      assert %{"login" => "MikeMcC399", "isUser" => true, "role" => ^role} = trust["labeled"],
             kind

      assert [_] = permission_reads(context)
    end

    # A machine account is a user, with the permission it has.
    trust = trust(context, "nodejs_node_67326", "needs-ci", %{"nodejs-github-bot" => "read"})

    assert %{"login" => "nodejs-github-bot", "isUser" => true, "role" => "read"} =
             trust["labeled"]

    refute trust["labeled"]["tied"]
  end

  test "a deleted account's pull request is no one's in particular", context do
    trust = trust(context, "EficodeDemoOrg_mythapi-demo_24", nil)
    assert %{"login" => "ghost", "isUser" => true, "association" => "NONE"} = trust["author"]
  end

  # Synthetic: no public pull request has a mannequin, an imported account standing
  # for someone who never signed in, as its labeller. Its login is the source's.
  test "a mannequin with a user's login has no permission read", context do
    trust =
      trust(context, "nodejs_node_67326", "invalid", %{"MikeMcC399" => "admin"}, fn answer ->
        update_in(answer, ["data", "repository", "pullRequest", "timelineItems", "nodes"], fn
          nodes ->
            Enum.map(nodes, fn
              %{"label" => %{"name" => "invalid"}} = event ->
                put_in(event, ["actor", "__typename"], "Mannequin")

              event ->
                event
            end)
        end)
      end)

    assert %{"login" => "MikeMcC399", "isUser" => false, "isBot" => false, "role" => nil} =
             trust["labeled"]

    assert permission_reads(context) == []
  end

  # Synthetic: a user with the login of the bot that opened the pull request labels it.
  # They go by their own permission, never by the bot's association, low or high.
  test "a user with a bot author's login goes by their own permission", context do
    for {association, kind, role} <- [
          {"CONTRIBUTOR", "admin", "admin"},
          {"MEMBER", "read", "read"}
        ] do
      trust =
        trust(context, "cli_cli_14906", "go", %{"dependabot" => kind}, fn answer ->
          answer
          |> put_in(["data", "repository", "pullRequest", "authorAssociation"], association)
          |> update_in(["data", "repository", "pullRequest", "timelineItems", "nodes"], fn
            nodes ->
              Enum.map(nodes, fn
                %{"label" => %{"name" => "go"}} = event ->
                  put_in(event, ["actor", "__typename"], "User")

                event ->
                  event
              end)
          end)
        end)

      assert %{"login" => "dependabot", "isBot" => true, "association" => ^association} =
               trust["author"]

      assert %{"login" => "dependabot", "isUser" => true, "association" => nil, "role" => ^role} =
               trust["labeled"]

      assert [_] = permission_reads(context)
    end
  end

  # Synthetic: a bot with the login of the user who labelled at the same second.
  test "a bot with a user's login at the same time is someone else", context do
    trust =
      trust(context, "nodejs_node_67326", "invalid", %{"MikeMcC399" => "admin"}, fn answer ->
        update_in(answer, ["data", "repository", "pullRequest", "timelineItems", "nodes"], fn
          nodes ->
            bot =
              nodes
              |> List.last()
              |> put_in(["actor", "__typename"], "Bot")

            nodes ++ [bot]
        end)
      end)

    assert %{"login" => "MikeMcC399", "isBot" => true, "role" => nil} = trust["labeled"]

    assert [%{"login" => "MikeMcC399", "isUser" => true, "role" => "admin"}] =
             trust["labeled"]["tied"]
  end
end
