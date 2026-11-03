defmodule HalC2.GitHubTest do
  use ExUnit.Case, async: false

  alias HalC2.GitHub
  alias HalC2.GitHub.Limits

  test "a call spends the budget GitHub charges it to" do
    assert GitHub.bucket(~w(api graphql --hostname github.com --input -)) == "graphql"
    assert GitHub.bucket(~w(api --hostname github.com repos/acme/shop/pulls)) == "core"
    assert GitHub.bucket(~w(api -X GET /search/issues -f q=is:pr)) == "search"
    assert GitHub.bucket(~w(api user)) == "core"
    assert GitHub.bucket(~w(run list --repo acme/shop)) == "core"
    assert GitHub.bucket(~w(pr view 42 --json title)) == "graphql"
    # These never touch the budget, and the budget's own reading is free.
    assert GitHub.bucket(~w(api rate_limit --hostname github.com)) == nil
    assert GitHub.bucket(~w(auth token --hostname github.com)) == nil
    assert GitHub.bucket(~w(config get git_protocol)) == nil
  end

  test "a call's host is the one its arguments name" do
    assert GitHub.host(~w(api graphql --hostname GHE.test)) == "ghe.test"
    assert GitHub.host(~w(pr view 1 --repo ghe.test/acme/shop)) == "ghe.test"
    assert GitHub.host(~w(pr view 1 -R acme/shop)) == "github.com"
    assert GitHub.host(~w(repo view GHE.test/acme/shop --json url)) == "ghe.test"
    assert GitHub.host(~w(repo view acme/shop --json url)) == "github.com"
    assert GitHub.host(~w(api user)) == "github.com"
  end

  describe "a paused host" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      gh = Path.join(dir, "gh")
      File.write!(gh, "#!/bin/sh\necho asked >> #{Path.join(dir, "calls")}\necho '{}'\n")
      File.chmod!(gh, 0o755)
      previous = Application.get_env(:hal_c2, :gh_command)
      Application.put_env(:hal_c2, :gh_command, gh)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:hal_c2, :gh_command, previous),
          else: Application.delete_env(:hal_c2, :gh_command)
      end)

      start_supervised!(Limits)
      until = Limits.limited("github.com", "graphql", System.system_time(:millisecond))
      %{calls: Path.join(dir, "calls"), until: until}
    end

    test "turns a read away without running gh", %{calls: calls, tmp_dir: dir} do
      assert {:error, {:rate_limited, detail}} = GitHub.gh(dir, ~w(pr view 1))
      assert detail =~ "paused until it resets at"
      refute File.exists?(calls)
    end

    test "lets through what the user asked for, in tasks it starts too, and stays paused",
         %{calls: calls, tmp_dir: dir, until: until} do
      assert {:ok, _} =
               GitHub.asked(fn ->
                 Task.await(Task.async(fn -> GitHub.gh(dir, ~w(pr view 1)) end))
               end)

      assert File.read!(calls) == "asked\n"
      assert {:paused, ^until} = Limits.check("github.com", "graphql", until - 1)
      assert {:error, {:rate_limited, _}} = GitHub.gh(dir, ~w(pr view 1))
    end

    test "a checkout on another host asks that host, which is not paused",
         %{calls: calls, tmp_dir: dir} do
      {_, 0} = System.cmd("git", ~w(init -q), cd: dir)
      {_, 0} = System.cmd("git", ~w(remote add origin git@github.com:me/shop.git), cd: dir)
      # gh asks `upstream`'s host before `origin`'s.
      {_, 0} = System.cmd("git", ~w(remote add upstream git@ghe.test:acme/shop.git), cd: dir)

      assert {:ok, _} = GitHub.gh(dir, ~w(pr view 1))
      assert File.read!(calls) == "asked\n"
    end

    test "a failed read whose answer quotes a rate limit is not one", %{tmp_dir: dir} do
      # gh prints a GraphQL answer carrying `errors` on stdout, titles and all.
      File.write!(Path.join(dir, "gh"), """
      #!/bin/sh
      echo '{"data":{"title":"Handle API rate limit exceeded"},"errors":[{"type":"NOT_FOUND"}]}'
      echo 'GraphQL: Could not resolve to a User.' >&2
      exit 1
      """)

      now = System.system_time(:millisecond)
      assert {:error, {:failed, _}} = GitHub.gh(dir, ~w(api graphql --hostname ghe.test))
      assert Limits.check("ghe.test", "graphql", now) == :ok
      assert Limits.check("ghe.test", "core", now) == :ok
    end
  end
end
