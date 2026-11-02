defmodule HalC2.Steps.SourceControl.PullRequestThreads do
  @moduledoc """
  Steps for `features/source-control/pull-request-threads.feature`: opening a pull
  request in a thread (`git.resolvePullRequest`, `git.preparePullRequestThread`) and
  the links a thread keeps (`thread.pull-request.link`, `HalC2.PullRequests.Discovery`,
  `HalC2.PullRequests.Sync`, `pullRequests.linkedThreads`).

  Pull request 42 of "acme/shop" has a real head: a commit pushed to the fake
  GitHub's `refs/pull/42/head` (and to its branch, unless it comes from a fork).
  Links are made on the thread "Tax work" unless a step names another.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.PullRequests
  alias HalC2.SourceControl.ChangeRequests
  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.{FakeHttp, Mc}
  alias HalC2.Test.Mc.World

  @repository "acme/shop"
  @url "https://github.com/acme/shop/pull/42"

  # --- resolving and preparing ---------------------------------------------------------

  step ~r/^the user asks to work on the pull request (?<reference>\S+)$/,
       %{args: [reference]} = context do
    context = answer_view(context)
    root = World.project(context, @repository).root

    {reply, context} =
      World.call(context, "git.resolvePullRequest", %{"cwd" => root, "reference" => reference})

    Map.put(context, :reply, reply)
  end

  step "pull request {int} of {string} is resolved with its title, branches and state",
       %{args: [number, repository]} = context do
    assert {:ok, %{"pullRequest" => pr}} = context.reply

    assert pr == %{
             "number" => number,
             "title" => "Charge tax at checkout",
             "url" => "https://github.com/#{repository}/pull/#{number}",
             "baseBranch" => "main",
             "headBranch" => "feature/tax",
             "state" => "open"
           }

    context
  end

  step "the user is told the pull request was not found", context do
    assert {:error, _, %{"detail" => detail}} = context.reply
    assert detail == "Pull request not found. Check the PR number or URL and try again."
    context
  end

  step "pull request {int} comes from the fork branch {string}",
       %{args: [42, branch]} = context do
    answer_view(context, %{"headRefName" => branch, "isCrossRepository" => true})
  end

  step "a worktree for pull request {int} exists with local commits", %{args: [42]} = context do
    context = context |> answer_view() |> prepare("worktree")
    assert {:ok, %{"worktreePath" => path, "isOnPullRequestHead" => true}} = context.reply
    World.commit!(path, %{"local.txt" => "mine\n"}, "Local work")
    Map.put(context, :existing_worktree, path)
  end

  step "the main checkout is on pull request {int}'s branch", %{args: [42]} = context do
    context = answer_view(context)
    World.git!(context.cwd, ~w(checkout -q feature/tax))
    context
  end

  step "{string} has a setup script for new worktrees", %{args: [repository]} = context do
    project = World.project(context, repository)

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => project.id,
        "scripts" => [
          %{
            "id" => "setup",
            "name" => "Setup",
            "command" => "echo ran > setup-ran.txt",
            "icon" => "configure",
            "runOnWorktreeCreate" => true,
            "async" => false
          }
        ]
      })

    World.await_row(project.id, &match?([_], &1["scripts"]))
    context
  end

  step ~r/^the user starts a thread on pull request 42 in (?<mode>the local checkout|a new worktree)$/,
       %{args: [mode]} = context do
    context |> answer_view() |> start(mode_of(mode))
  end

  step "the project's checkout switches to the pull request's branch", context do
    assert %{"branch" => "feature/tax", "worktreePath" => nil, "isOnPullRequestHead" => true} =
             context.prepared

    assert World.git!(context.cwd, ~w(branch --show-current)) == "feature/tax"
    assert World.git!(context.cwd, ~w(rev-parse HEAD)) == context.pr_head
    context
  end

  step "the new thread is linked to pull request {int}", %{args: [number]} = context do
    :ok = HalC2.PullRequests.Discovery.sweep()
    row = World.await_row(World.thread_id(context, "PR 42"), &(&1["branchPullRequest"] != nil))
    assert %{"number" => ^number, "url" => @url} = row["branchPullRequest"]
    context
  end

  step "the pull request's head is fetched into a worktree of its own", context do
    %{"worktreePath" => path, "branch" => "feature/tax"} = context.prepared
    assert path != context.cwd and File.dir?(path)
    assert World.git!(path, ~w(rev-parse HEAD)) == context.pr_head
    assert World.git!(path, ~w(branch --show-current)) == "feature/tax"
    assert World.git!(path, ~w(rev-parse --abbrev-ref @{upstream})) == "origin/feature/tax"
    # The main checkout stays where it was.
    assert World.git!(context.cwd, ~w(branch --show-current)) == "main"
    context
  end

  step "the new thread works in that worktree", context do
    row = World.await_row(World.thread_id(context, "PR 42"), & &1)
    assert row["worktreePath"] == context.prepared["worktreePath"]
    assert row["branch"] == "feature/tax"
    context
  end

  step "the worktree is on the branch {string} with no upstream", %{args: [branch]} = context do
    assert %{"branch" => ^branch, "worktreePath" => path} = context.prepared
    assert World.git!(path, ~w(branch --show-current)) == branch
    assert World.git!(path, ~w(rev-parse HEAD)) == context.pr_head

    assert {_, status} =
             System.cmd("git", ~w(rev-parse --abbrev-ref @{upstream}),
               cd: path,
               stderr_to_stdout: true
             )

    assert status != 0
    context
  end

  step "the existing worktree is reused", context do
    assert %{"worktreePath" => path} = context.prepared
    assert path == context.existing_worktree
    assert World.git!(path, ~w(log -1 --format=%s)) == "Local work"
    context
  end

  step "the user is told the checkout is not on the pull request's head", context do
    assert context.prepared["isOnPullRequestHead"] == false
    context
  end

  step "the user is told to use the local checkout or switch the main checkout off that branch",
       context do
    assert World.failure(context) ==
             "This PR branch is already checked out in the main repo. Use Local, or switch the main repo off that branch before creating a worktree thread."

    context
  end

  step "the setup script does not run", context do
    assert %{"worktreePath" => path} = context.prepared
    assert File.dir?(path)
    refute File.exists?(Path.join(path, "setup-ran.txt"))
    refute File.exists?(Path.join(context.cwd, "setup-ran.txt"))
    context
  end

  # --- reused worktrees ----------------------------------------------------------------

  step "a worktree for pull request {int} exists with no changes or commits of its own",
       %{args: [42]} = context do
    existing_worktree(context)
  end

  step ~r/^a worktree for pull request 42 exists and (?<state>.+)$/, %{args: [state]} = context do
    context = existing_worktree(context)
    path = context.existing_worktree

    case state do
      "it has uncommitted changes and the pull request has new commits" ->
        File.write!(Path.join(path, "tax.txt"), "edited\n")
        push_pr(context, context.pr_head, "More tax")

      "it has commits of its own and the pull request was rewritten" ->
        World.commit!(path, %{"local.txt" => "mine\n"}, "Local work")
        push_pr(context, "main", "Charge tax, rebased")

      "the host cannot say what the pull request's head is and the branch was cut from another branch" ->
        bare = bare(@repository)
        World.git!(bare, ~w(update-ref -d refs/pull/42/head))
        World.git!(bare, ~w(update-ref -d refs/heads/feature/tax))
        World.git!(path, ~w(branch -q --set-upstream-to=origin/main))
        context
    end
    |> then(fn context ->
      Map.put(context, :before, %{
        head: World.git!(path, ~w(rev-parse HEAD)),
        status: World.git!(path, ~w(status --porcelain))
      })
    end)
  end

  step "the pull request has since received new commits", context do
    push_pr(context, context.pr_head, "More tax")
  end

  step "the pull request's author has since rebased it and pushed over the old commits",
       context do
    push_pr(context, "main", "Charge tax, rebased")
  end

  step ~r/^the existing worktree is moved onto the (pull request's newest commit|rewritten head)$/,
       context do
    assert %{"worktreePath" => path} = context.prepared
    assert path == context.existing_worktree
    assert World.git!(path, ~w(rev-parse HEAD)) == context.new_head
    context
  end

  step "the user is not told the checkout is behind", context do
    assert context.prepared["isOnPullRequestHead"] == true
    context
  end

  step "the commit it was on can still be found afterwards", context do
    assert World.git!(context.existing_worktree, ~w(rev-parse refs/hal-c2/pre-refresh)) ==
             context.pr_head

    context
  end

  step "the existing worktree is handed back unchanged", context do
    assert %{"worktreePath" => path} = context.prepared
    assert path == context.existing_worktree
    assert World.git!(path, ~w(rev-parse HEAD)) == context.before.head
    assert World.git!(path, ~w(status --porcelain)) == context.before.status
    context
  end

  step ~r/^the user's own "(?<branch>[^"]+)" is checked out in another worktree$/,
       %{args: [branch]} = context do
    path = Path.join(Mc.tmp_dir(context.mc, "own-worktree"), branch)
    World.git!(context.cwd, ~w(checkout -q --detach))
    World.git!(context.cwd, ["worktree", "add", "-q", path, branch])

    Map.put(context, :own_worktree, %{
      path: path,
      head: World.git!(path, ~w(rev-parse HEAD)),
      upstream: World.git!(path, ~w(rev-parse --abbrev-ref @{upstream}))
    })
  end

  step ~r/^the user's "(?<branch>[^"]+)" worktree is not changed$/, %{args: [branch]} = context do
    %{path: path, head: head, upstream: upstream} = context.own_worktree
    assert World.git!(path, ~w(branch --show-current)) == branch
    assert World.git!(path, ~w(rev-parse HEAD)) == head
    assert World.git!(path, ~w(rev-parse --abbrev-ref @{upstream})) == upstream
    assert World.git!(path, ~w(status --porcelain)) == ""
    context
  end

  step "the thread is told the checkout is not on the pull request's head", context do
    assert %{"isOnPullRequestHead" => false} = context.prepared
    context
  end

  # --- fork remotes --------------------------------------------------------------------

  step ~r/^pull request 42 comes from the fork "(?<fork>[^"]+)"(?: branch "(?<branch>[^"]+)")?(?<unfetchable> and the fork cannot be fetched from)?$/,
       %{args: [fork | rest]} = context do
    [branch, unfetchable] = Enum.take(rest ++ [nil, nil], 2)
    branch = if branch in [nil, ""], do: "tax", else: branch
    fork(context, fork, branch, unfetchable not in [nil, ""])
  end

  step ~r/^the user starts a thread on pull request 42 from "(?<fork>[^"]+)" in a new worktree$/,
       %{args: [fork]} = context do
    context = fork(context, fork, "tax", false)
    start(context, "worktree")
  end

  step ~r/^the project's "origin" is reached over (?<protocol>ssh|https)$/,
       %{args: [protocol]} = context do
    if protocol == "https" do
      World.git!(context.cwd, ~w(remote set-url origin https://github.com/acme/shop.git))
      remotes = System.get_env("HAL_C2_FAKE_REMOTES")
      World.git!(context.cwd, ["config", "url.#{remotes}/.insteadOf", "https://github.com/"])
    end

    context
  end

  step "the checkout gets a remote for {string} named after its owner",
       %{args: [repository]} = context do
    [owner, _] = String.split(repository, "/")

    assert World.git!(context.cwd, ["config", "remote.#{owner}.url"]) ==
             "git@github.com:#{repository}.git"

    Map.put(context, :fork_remote, owner)
  end

  step "the branch follows {string} on that remote", %{args: [branch]} = context do
    assert_follows(context, "#{context.fork_remote}/#{branch}")
  end

  step ~r/^the fork's remote is added with its (?<protocol>ssh|https) address$/,
       %{args: [protocol]} = context do
    url =
      if protocol == "ssh", do: "git@github.com:sam/shop.git", else: "https://github.com/sam/shop"

    assert World.git!(context.cwd, ~w(config remote.sam.url)) == url
    assert_follows(context, "sam/tax")
  end

  step ~r/^the checkout already has a remote "(?<name>[^"]+)" for the address of "(?<repository>[^"]+)"$/,
       %{args: [name, repository]} = context do
    World.git!(context.cwd, ["remote", "add", name, "git@github.com:#{repository}.git"])
    context
  end

  step ~r/^the checkout has a remote "(?<name>[^"]+)" that points at another repository$/,
       %{args: [name]} = context do
    World.git!(context.cwd, ["remote", "add", name, "git@github.com:#{name}/other.git"])
    Map.put(context, :other_remote, {name, "git@github.com:#{name}/other.git"})
  end

  step "{string} is used", %{args: [name]} = context do
    assert_follows(context, "#{name}/tax")
  end

  step "no further remote is added", context do
    assert World.git!(context.cwd, ~w(remote)) |> String.split("\n") |> Enum.sort() ==
             ["origin", "sam-fork"]

    context
  end

  step "the fork is added as the remote {string}", %{args: [name]} = context do
    assert World.git!(context.cwd, ["config", "remote.#{name}.url"]) ==
             "git@github.com:sam/shop.git"

    assert_follows(context, "#{name}/tax")
  end

  step "the existing {string} remote is not changed", %{args: [name]} = context do
    {^name, url} = context.other_remote
    assert World.git!(context.cwd, ["config", "remote.#{name}.url"]) == url
    context
  end

  step "the pull request's head is fetched from the host's own pull request ref instead",
       context do
    assert %{"branch" => "hal-c2/pr-42/tax", "worktreePath" => path} = context.prepared
    assert World.git!(path, ~w(rev-parse HEAD)) == context.pr_head
    context
  end

  step "the thread starts in a worktree on it", context do
    row = World.await_row(World.thread_id(context, "PR 42"), & &1)
    assert row["worktreePath"] == context.prepared["worktreePath"]
    assert row["branch"] == "hal-c2/pr-42/tax"
    context
  end

  step "neither the fork nor the host's pull request ref can be fetched", context do
    File.rm_rf!(bare("sam/shop"))
    World.git!(bare(@repository), ~w(update-ref -d refs/pull/42/head))
    context
  end

  step "the thread is not prepared", context do
    assert {:error, _, _} = context.reply
    refute context[:prepared]
    context
  end

  step "the user is told that both fetches failed for pull request {int}",
       %{args: [number]} = context do
    assert World.failure(context) =~
             "Repository-head and pull-request-ref fetches both failed for pull request ##{number}"

    context
  end

  step "the remote cannot be reached when the branch is about to be set to follow it",
       context do
    context
    |> answer_view()
    |> World.cli_rules(%{
      "args" => ["pr checkout 42 --force"],
      "run" =>
        "git fetch -q origin +refs/pull/42/head:refs/heads/feature/tax && " <>
          "git checkout -q feature/tax && " <>
          "git remote set-url origin git@github.com:acme/gone.git"
    })
  end

  step "the checkout is on the pull request's branch", context do
    assert %{"branch" => "feature/tax", "worktreePath" => nil} = context.prepared
    assert World.git!(context.cwd, ~w(branch --show-current)) == "feature/tax"
    assert World.git!(context.cwd, ~w(rev-parse HEAD)) == context.pr_head
    context
  end

  step "the thread is prepared without an upstream", context do
    assert {_, status} =
             System.cmd("git", ~w(rev-parse --abbrev-ref @{upstream}),
               cd: context.cwd,
               stderr_to_stdout: true
             )

    assert status != 0
    context
  end

  # --- other hosts ---------------------------------------------------------------------

  step ~r/^a pull request on (?<host>GitHub|GitLab|Bitbucket|Forgejo) where (?<given>.+)$/,
       %{args: [host, given]} = context do
    {cross?, answer} = detection(host, given)
    context = push_head(context, %{"isCrossRepository" => cross?, "headRefName" => "feature/tax"})

    if cross? do
      World.git!(context.cwd, ["init", "-q", "--bare", bare("sam/shop")])

      World.git!(context.cwd, [
        "push",
        "-q",
        bare("sam/shop"),
        "#{context.pr_head}:refs/heads/feature/tax"
      ])
    end

    answer_host(context, host, answer)
  end

  step "the user starts a thread on it", context do
    start(context, "worktree")
  end

  step ~r/^it is treated as from (?<repository>another|the same) repository$/,
       %{args: [repository]} = context do
    branch = if repository == "another", do: "hal-c2/pr-42/feature/tax", else: "feature/tax"
    assert %{"branch" => ^branch, "worktreePath" => path} = context.prepared
    assert World.git!(path, ~w(rev-parse HEAD)) == context.pr_head
    context
  end

  step "the GitHub CLI answers with the source repository's name and its owner's login but no full name",
       context do
    context =
      answer_view(context, %{
        "headRefName" => "tax",
        "isCrossRepository" => true,
        "headRepository" => %{"name" => "name"},
        "headRepositoryOwner" => %{"login" => "owner"}
      })

    World.git!(context.cwd, ["init", "-q", "--bare", bare("owner/name")])

    World.git!(context.cwd, [
      "push",
      "-q",
      bare("owner/name"),
      "#{context.pr_head}:refs/heads/tax"
    ])

    Shared.answer_lookup(context, "github", "owner/name")
  end

  step "the user starts a thread on a pull request from that repository", context do
    start(context, "worktree")
  end

  step "the source repository is taken as {string}", %{args: [repository]} = context do
    assert World.cli_calls(context, "repo view #{repository}") != []

    assert World.git!(context.cwd, ~w(config remote.owner.url)) ==
             "git@github.com:#{repository}.git"

    assert_follows(context, "owner/tax")
  end

  # --- Forgejo -------------------------------------------------------------------------

  step ~r/^the Forgejo CLI is signed in and the checkout's remote is reached over (?<protocol>HTTPS|SSH)$/,
       %{args: [protocol]} = context do
    forgejo_checkout(context, protocol)
  end

  step ~r/^the checkout has no "pulls\/42"$/, context do
    context
  end

  step ~r/^the checkout has a "pulls\/42"$/, context do
    World.git!(context.cwd, ~w(branch pulls/42 main))
    context
  end

  step ~r/^the user starts a thread on Forgejo pull request 42 in the local checkout(?: forcing the update)?$/,
       context do
    start(context, "local")
  end

  # Only that address holds the pull request ref (`forgejo_checkout/2`).
  step ~r/^pull request 42's head is fetched from the repository's (?<protocol>HTTPS|SSH) address$/,
       context do
    assert World.git!(context.cwd, ~w(rev-parse pulls/42)) == context.pr_head
    context
  end

  step ~r/^the checkout is on (?<which>a new|the existing) branch "pulls\/42"(?: at the fetched head)?$/,
       %{args: [which]} = context do
    assert %{"branch" => "pulls/42", "worktreePath" => nil} = context.prepared
    assert World.git!(context.cwd, ~w(branch --show-current)) == "pulls/42"
    assert World.git!(context.cwd, ~w(rev-parse HEAD)) == context.pr_head
    # The reflog's first entry says where the branch was made from.
    created =
      World.git!(context.cwd, ~w(reflog show --format=%gs pulls/42))
      |> String.split("\n")
      |> List.last()

    if which == "a new",
      do: assert(created =~ "FETCH_HEAD"),
      else: refute(created =~ "FETCH_HEAD")

    context
  end

  step ~r/^the checkout has a branch "pulls\/42" behind pull request 42's head and an uncommitted file$/,
       context do
    context = forgejo_checkout(context, "SSH")
    World.git!(context.cwd, ~w(branch pulls/42 main))
    File.write!(Path.join(context.cwd, "notes.txt"), "draft\n")
    context
  end

  step "the branch is at pull request 42's head", context do
    assert World.git!(context.cwd, ~w(rev-parse pulls/42)) == context.pr_head
    context
  end

  step "the uncommitted file is still there", context do
    assert File.read!(Path.join(context.cwd, "notes.txt")) == "draft\n"
    context
  end

  step "the user starts a thread on the Forgejo reference {string}",
       %{args: [reference]} = context do
    context |> forgejo_checkout("SSH") |> prepare("local", reference)
  end

  step "the user is told to specify a pull request number or Forgejo pull request URL", context do
    assert World.failure(context) =~ "Specify a pull request number or Forgejo pull request URL."
    context
  end

  step "the branch {string} has pull requests on Forgejo among 120 others",
       %{args: ["feature/tax"]} = context do
    # Five of the branch's, spread over the first three pages of 50.
    pulls =
      for n <- 1..125 do
        head = if rem(n, 25) == 3, do: "feature/tax", else: "other-#{n}"
        forgejo_pull(n, head, "open")
      end

    forgejo_listing(context, fn _state -> pulls end)
  end

  step "the branch {string} has one merged and one closed pull request on Forgejo",
       %{args: ["feature/tax"]} = context do
    closed = [
      forgejo_pull(7, "feature/tax", "closed", true),
      forgejo_pull(8, "other", "closed"),
      forgejo_pull(9, "feature/tax", "closed")
    ]

    forgejo_listing(context, fn
      "closed" -> closed
      _ -> []
    end)
  end

  step ~r/^the MC lists the (?:(?<state>merged|closed) )?pull requests of "(?<branch>[^"]+)"(?: asking for none in particular)?$/,
       %{args: args} = context do
    {state, branch} =
      case args do
        [branch] -> {nil, branch}
        ["", branch] -> {nil, branch}
        [state, branch] -> {state, branch}
      end

    remote = PullRequests.parse_remote("git@codeberg.org:acme/shop.git")
    opts = if state, do: [state: state], else: []
    listed = ChangeRequests.forgejo_list(context.cwd, remote, branch, opts)
    Map.put(context, :listed, listed)
  end

  step "pull requests are read 50 at a time, the most recently updated first", context do
    for request <- forgejo_listings(context) do
      assert request["query"] =~ "state=all&sort=recentupdate&limit=50&page="
    end

    context
  end

  step "only those whose head is {string} are kept, up to 20", %{args: [branch]} = context do
    assert Enum.map(context.listed, & &1["number"]) == [3, 28, 53, 78, 103]
    assert Enum.all?(context.listed, &(&1["headRef"] == branch))
    context
  end

  step "reading stops when a page comes back empty", context do
    pages = for r <- forgejo_listings(context), do: URI.decode_query(r["query"])["page"]
    assert pages == ~w(1 2 3 4)
    context
  end

  step ~r/^only the (?<state>merged|closed) pull request is returned$/,
       %{args: [state]} = context do
    number = if state == "merged", do: 7, else: 9
    assert [%{"number" => ^number, "state" => ^state}] = context.listed
    assert Enum.all?(forgejo_listings(context), &(&1["query"] =~ "state=closed&"))
    context
  end

  step ~r/^the branch "(?<branch>[^"]+)" lives in the fork "(?<fork>[^"]+)" of "acme\/shop"$/,
       %{args: [branch, fork]} = context do
    [owner, _] = String.split(fork, "/")
    root = context.cwd
    World.git!(root, ~w(remote set-url origin git@codeberg.org:acme/shop.git))
    World.git!(root, ["init", "-q", "--bare", bare(fork)])
    World.git!(root, ["remote", "add", owner, "git@codeberg.org:#{fork}.git"])
    World.git!(root, ["checkout", "-q", "-b", branch])
    World.commit!(root, %{"tax.txt" => "10%\n"}, "Charge tax")
    World.git!(root, ["push", "-q", "-u", owner, branch])

    created = %{
      "number" => 43,
      "html_url" => "https://codeberg.org/acme/shop/pulls/43",
      "title" => "Charge tax"
    }

    context
    |> Shared.answering_writer()
    |> forgejo_api(%{
      "/api/v1/repos/acme/shop/pulls" => fn
        %{method: "POST"} -> {201, created}
        _ -> {200, []}
      end
    })
    |> World.create_thread("Tax work", @repository, %{"branch" => branch})
  end

  step "the user opens a pull request from it on Forgejo", context do
    id = World.thread_id(context, "Tax work")
    {events, context} = World.git_action(context, context.cwd, "create_pr", %{"threadId" => id})
    last = List.last(events)
    assert last["kind"] == "action_finished", "the action failed: #{inspect(last)}"
    assert %{"status" => "created", "number" => 43} = last["result"]["pr"]
    context
  end

  step ~r/^the pull request is created in "(?<repository>[^"]+)" with the head "(?<head>[^"]+)"$/,
       %{args: [repository, head]} = context do
    path = "/api/v1/repos/#{repository}/pulls"

    assert [request] =
             for(r <- FakeHttp.requests(context.forgejo), r["method"] == "POST", do: r)

    assert request["path"] == path
    assert %{"head" => ^head, "base" => "main"} = JSON.decode!(request["body"])
    context
  end

  # --- linking -------------------------------------------------------------------------

  step "the thread {string} has no linked pull request", %{args: [title]} = context do
    context = thread(context, title)
    row = World.await_row(World.thread_id(context, title), & &1)
    assert (row["pullRequests"] || []) == [] and row["branchPullRequest"] == nil
    context
  end

  step "the user links pull request {int} to {string}", %{args: [number, title]} = context do
    link(context, @repository, number, title)
  end

  step "{string} lists pull request {int} with its current state",
       %{args: [title, number]} = context do
    link = await_link(context, title, number, &(&1["snapshot"] != nil))
    assert %{"state" => "open", "title" => "Pull request 42"} = link["snapshot"]
    assert link["source"] == "manual"
    context
  end

  step "pull request {int} is linked to {string}", %{args: [number, title]} = context do
    context = link(context, @repository, number, title)
    await_link(context, title, number, &(&1["snapshot"] != nil))
    Map.merge(context, %{pr_thread: title, repository: @repository})
  end

  step "{string} no longer lists pull request {int}", %{args: [title, number]} = context do
    row = World.await_row(World.thread_id(context, title), & &1)
    refute Enum.any?(row["pullRequests"] || [], &(&1["number"] == number))
    context
  end

  step "the user links {string} pull request {int} and {string} pull request {int} to {string}",
       %{args: [repo_a, a, repo_b, b, title]} = context do
    context
    |> link(repo_a, a, title)
    |> link(repo_b, b, title)
    |> Map.put(:linked, [{repo_a, a}, {repo_b, b}])
  end

  step "{string} lists both pull requests", %{args: [title]} = context do
    wanted = context.linked

    row =
      World.await_row(World.thread_id(context, title), fn row ->
        Enum.all?(wanted, fn {repo, n} ->
          Enum.any?(row["pullRequests"] || [], &(&1["repository"] == repo and &1["number"] == n))
        end)
      end)

    assert length(row["pullRequests"]) == 2

    for link <- row["pullRequests"],
        do:
          assert(link["url"] == "https://github.com/#{link["repository"]}/pull/#{link["number"]}")

    context
  end

  step "the agent in {string} opens pull request {int} and links it with its tool",
       %{args: [title, number]} = context do
    Mc.ensure(HalC2.Mcp)
    context = thread(context, title)
    %{authorization: auth} = HalC2.Mcp.server(World.thread_id(context, title), "codex")

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "link_pull_request",
          "arguments" => %{"url" => "https://github.com/acme/shop/pull/#{number}"}
        }
      })

    assert {200, %{"result" => %{"structuredContent" => linked}}} = HalC2.Mcp.handle(auth, body)
    assert %{"number" => ^number, "alreadyLinked" => false} = linked
    Map.put(context, :expected_source, "agent")
  end

  step "{string} lists pull request {int}", %{args: [title, number]} = context do
    link = await_link(context, title, number, & &1)
    assert link["source"] == context.expected_source
    assert link["url"] == "https://github.com/acme/shop/pull/#{number}"
    context
  end

  step "the user creates a pull request from {string}", %{args: [title]} = context do
    context =
      context
      |> Shared.answering_writer()
      |> World.cli_rules([
        %{"args" => ["pr list"], "stdout" => []},
        %{"args" => ["pr create"], "stdout" => "https://github.com/acme/shop/pull/43\n"}
      ])

    World.git!(context.cwd, ~w(checkout -q -b feature/tax))
    World.commit!(context.cwd, %{"tax.txt" => "10%\n"}, "Charge tax")
    context = World.create_thread(context, title, @repository, %{"branch" => "feature/tax"})
    id = World.thread_id(context, title)
    {events, context} = World.git_action(context, context.cwd, "create_pr", %{"threadId" => id})
    last = List.last(events)
    assert last["kind"] == "action_finished", "the action failed: #{inspect(last)}"
    assert %{"status" => "created", "number" => 43} = last["result"]["pr"]
    Map.merge(context, %{expected_source: "created", created_pr: 43})
  end

  step "{string} lists the new pull request", %{args: [title]} = context do
    link = await_link(context, title, context.created_pr, & &1)
    assert link["source"] == "created"
    assert link["url"] == "https://github.com/acme/shop/pull/43"
    context
  end

  # The fake Codex reports `command` as a finished command item that printed the pull
  # request's address on a line of its own, as `gh pr create` does.
  step "the agent in {string} runs {string} and it prints pull request {int}",
       %{args: [title, command, number]} = context do
    url = "https://github.com/acme/shop/pull/#{number}"
    output = "\nCreating pull request for feature/tax into main in acme/shop\n\n#{url}\n"
    run = JSON.encode!(%{"command" => command, "output" => output})

    context
    |> thread(title)
    |> World.run_turn(title, "run command #{run}")
    |> Map.merge(%{expected_source: "created", command: command})
  end

  step "{string} still has no linked pull request", %{args: [title]} = context do
    items = HalC2.StreamState.list(World.state(context, title), "turn-item")
    assert Enum.any?(items, &(&1["input"] == context.command and &1["output"] =~ "/pull/"))
    assert (World.thread(context, title)["pullRequests"] || []) == []
    context
  end

  # --- discovery -----------------------------------------------------------------------

  step "{string} works in a worktree of its own on the branch {string}",
       %{args: [title, branch]} = context do
    context
    |> World.worktree_thread(title, @repository, %{"branch" => branch})
    |> Map.put(:branch, branch)
  end

  step "its own commit was pushed as the open pull request {int} from the branch {string}",
       %{args: [number, head_branch]} = context do
    World.commit!(context.worktree.path, %{"tax.txt" => "10%\n"}, "Charge tax")
    head_answer(context, number, head_branch)
  end

  step "the commit it started from heads the open pull request {int} from the branch {string}",
       %{args: [number, head_branch]} = context do
    head_answer(context, number, head_branch)
  end

  step "it fast-forwarded to a newer commit that heads the open pull request {int} from the branch {string}",
       %{args: [number, head_branch]} = context do
    path = context.worktree.path
    newer = World.git!(path, ["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Parent work"])
    World.git!(path, ~w(merge --ff-only #{newer}))
    head_answer(context, number, head_branch)
  end

  step "the thread's pull requests are looked for", context do
    context = discovery(context)
    :ok = HalC2.PullRequests.Discovery.sweep()
    assert World.cli_calls(context, "--head #{context.branch}") != []
    context
  end

  step "{string} links no pull request and its commit is not asked about",
       %{args: [title]} = context do
    assert (World.thread(context, title)["pullRequests"] || []) == []
    assert World.cli_calls(context, "/pulls") == []
    context
  end

  step "{string} shows no pull request as its branch's", %{args: [title]} = context do
    assert World.thread(context, title)["branchPullRequest"] == nil
    context
  end

  step "{string} is on the branch {string} with no linked pull request",
       %{args: [title, branch]} = context do
    context = World.create_thread(context, title, @repository, %{"branch" => branch})
    row = World.await_row(World.thread_id(context, title), & &1)
    assert row["branchPullRequest"] == nil and (row["pullRequests"] || []) == []
    Map.put(context, :branch, branch)
  end

  step "someone opens a pull request for {string} on GitHub", %{args: [branch]} = context do
    branch_answer(context, branch, 42, "OPEN")
  end

  # The MC sweeps unsettled threads every minute (`Discovery`'s timer); the sweep is
  # run here rather than waited for.
  step "within a minute {string} shows that pull request as its branch's",
       %{args: [title]} = context do
    context = discovery(context)
    :ok = HalC2.PullRequests.Discovery.sweep()
    row = World.await_row(World.thread_id(context, title), &(&1["branchPullRequest"] != nil))

    assert %{"number" => 42, "url" => @url, "repository" => @repository} =
             row["branchPullRequest"]

    context
  end

  step "{string} shows pull request {int} which has merged", %{args: [title, number]} = context do
    context = World.create_thread(context, title, @repository, %{"branch" => "feature/tax"})
    id = World.thread_id(context, title)
    project = World.project(context, @repository)

    # What an earlier discovery wrote.
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.pull-request.sync",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => id,
        "projectId" => project.id,
        "expected" => %{
          "workspaceRoot" => project.root,
          "branch" => "feature/tax",
          "worktreePath" => nil,
          "linkedPullRequest" => nil,
          "branchPullRequest" => nil
        },
        "branchPullRequest" => %{
          "projectId" => project.id,
          "repository" => @repository,
          "number" => number,
          "url" => "https://github.com/acme/shop/pull/#{number}"
        }
      })

    World.await_row(id, &(&1["branchPullRequest"]["number"] == number))

    context
    |> summaries(%{"state" => "MERGED", "mergedAt" => "2026-09-20T00:00:00Z"})
    |> Map.put(:pr_thread, title)
  end

  step "{string} now has the open pull request {int}", %{args: [branch, number]} = context do
    branch_answer(context, branch, number, "OPEN")
  end

  step "the thread's pull requests are checked again", context do
    context = discovery(context)
    :ok = HalC2.PullRequests.Discovery.sweep()
    assert World.cli_calls(context, "--head feature/tax") != []
    context
  end

  step "{string} shows pull request {int}", %{args: [title, number]} = context do
    row =
      World.await_row(
        World.thread_id(context, title),
        &(&1["branchPullRequest"]["number"] == number)
      )

    assert row["branchPullRequest"]["url"] == "https://github.com/acme/shop/pull/#{number}"
    context
  end

  # --- sync ----------------------------------------------------------------------------

  step "a review is submitted on pull request {int} on GitHub", %{args: [42]} = context do
    summaries(context, %{
      "reviewDecision" => "APPROVED",
      "updatedAt" => "2026-09-03T00:00:00Z",
      "latestReviews" => %{
        "nodes" => [%{"state" => "APPROVED", "author" => %{"login" => "hubot"}}]
      }
    })
  end

  step "{string} shows the new review state after the next sync", %{args: [title]} = context do
    :ok = HalC2.PullRequests.Sync.sweep()
    link = await_link(context, title, 42, &(&1["snapshot"]["reviewDecision"] == "approved"))
    assert link["snapshot"]["updatedAt"] == "2026-09-03T00:00:00Z"
    context
  end

  step "pull request {int} is linked to {string} and has merged",
       %{args: [number, title]} = context do
    context =
      context
      |> summaries(%{"state" => "MERGED", "mergedAt" => "2026-09-20T00:00:00Z"})
      |> link(@repository, number, title)

    await_link(context, title, number, &(&1["snapshot"]["state"] == "merged"))
    context
  end

  step "the sync sweep runs", context do
    if String.contains?(context[:file] || "", "pull-request-links") do
      # Those steps start the sweep and count its reads their own way.
      HalC2.Steps.Orchestration.PullRequestLinks.sync_sweep_now(context)
    else
      reads = summary_reads(context)
      :ok = HalC2.PullRequests.Sync.sweep()
      Map.put(context, :reads_before, reads)
    end
  end

  step "pull request {int} is not read again", %{args: [42]} = context do
    assert context.reads_before >= 1
    assert summary_reads(context) == context.reads_before
    context
  end

  step "pull request {int} is linked to {string} and to the archived thread {string}",
       %{args: [number, title, archived]} = context do
    context = context |> link(@repository, number, title) |> link(@repository, number, archived)
    id = World.thread_id(context, archived)
    {{:ok, _}, context} = World.dispatch(context, %{"type" => "thread.archive", "threadId" => id})
    World.await_row(id, &(&1["archivedAt"] != nil))
    Map.put(context, :pr_number, number)
  end

  step "the user asks which threads are linked to pull request {int}",
       %{args: [number]} = context do
    {reply, context} =
      World.call(context, "pullRequests.linkedThreads", %{
        "projectId" => World.project(context, @repository).id,
        "repository" => @repository,
        "number" => number
      })

    Map.put(context, :reply, reply)
  end

  step "both {string} and {string} are listed", %{args: [a, b]} = context do
    assert {:ok, %{"threads" => threads}} = context.reply
    assert threads |> Enum.map(& &1["title"]) |> Enum.sort() == Enum.sort([a, b])
    archived = Enum.find(threads, &(&1["title"] == b))
    assert archived["archivedAt"] != nil
    assert Enum.find(threads, &(&1["title"] == a))["archivedAt"] == nil
    context
  end

  # --- helpers -------------------------------------------------------------------------

  # As the pull request dialog does: the pull request is prepared, then the thread is
  # made on the branch and worktree it was prepared in.
  defp start(context, mode) do
    context =
      if mode == "local" and context[:pr_view]["headRefName"] == "feature/tax",
        do: context |> discovery() |> branch_answer("feature/tax", 42, "OPEN"),
        else: context

    context = prepare(context, mode)

    case context.reply do
      {:ok, prepared} ->
        context
        |> World.create_thread("PR 42", @repository, %{
          "branch" => prepared["branch"],
          "worktreePath" => prepared["worktreePath"]
        })
        |> Map.put(:prepared, prepared)

      _refused ->
        context
    end
  end

  # Pull request 42 prepared in a worktree of its own, as a thread before this one did.
  defp existing_worktree(context) do
    context = context |> answer_view() |> prepare("worktree")
    assert {:ok, %{"worktreePath" => path, "isOnPullRequestHead" => true}} = context.reply
    Map.put(context, :existing_worktree, path)
  end

  # A new head for pull request 42 on top of `base` (its head, or main for a rewrite),
  # force-pushed to its ref and branch on the fake GitHub by its author.
  defp push_pr(context, base, message) do
    root = context.cwd
    World.git!(root, ["checkout", "-q", "--detach", base])
    head = World.commit!(root, %{"tax.txt" => message <> "\n"}, message)
    # Straight to the bare repository, as the author's own push: the checkout's
    # remote-tracking branches stay where they were.
    World.git!(root, [
      "push",
      "-q",
      "-f",
      bare(@repository),
      "HEAD:refs/pull/42/head",
      "HEAD:refs/heads/feature/tax"
    ])

    World.git!(root, ~w(checkout -q main))
    Map.put(context, :new_head, head)
  end

  # A repository's bare repository on the fake host (`World.github_remote/3`).
  defp bare(repository),
    do: Path.join(System.get_env("HAL_C2_FAKE_REMOTES"), "#{repository}.git")

  # Pull request 42 from `branch` of the fork `repository`, which holds its head unless
  # `unfetchable`; `gh repo view` knows the fork's addresses.
  defp fork(context, repository, branch, unfetchable?) do
    [owner, name] = String.split(repository, "/")

    context =
      answer_view(context, %{
        "headRefName" => branch,
        "isCrossRepository" => true,
        "headRepository" => %{"id" => "R_fork", "name" => name, "nameWithOwner" => repository},
        "headRepositoryOwner" => %{"login" => owner}
      })

    unless unfetchable? do
      fork = bare(repository)
      World.git!(context.cwd, ["init", "-q", "--bare", fork])
      World.git!(context.cwd, ["push", "-q", fork, "#{context.pr_head}:refs/heads/#{branch}"])
    end

    Shared.answer_lookup(context, "github", repository)
  end

  # Whether a row of the detection outline is from another repository, and what its
  # host says about the source and target repositories.
  defp detection("GitHub", "the host says it comes from another repository"), do: {true, %{}}

  defp detection("GitLab", "the source and target projects have different ids"),
    do:
      {true,
       gitlab_projects("sam/shop", "acme/shop", %{
         "source_project_id" => 2,
         "target_project_id" => 1
       })}

  defp detection(
         "GitLab",
         "no ids are given and the source and target paths differ only in case"
       ),
       do: {false, gitlab_projects("ACME/shop", "acme/shop")}

  defp detection("GitLab", "no ids are given and the source and target paths differ"),
    do: {true, gitlab_projects("sam/shop", "acme/shop")}

  defp detection(
         "Bitbucket",
         "the source and destination repositories have different full names"
       ),
       do: {true, %{"full_name" => "sam/shop"}}

  defp detection("Bitbucket", "the source repository was deleted"), do: {false, nil}

  defp detection("Forgejo", "the head and base repositories have different full names"),
    do: {true, %{"full_name" => "sam/shop", "owner" => %{"login" => "sam"}}}

  defp detection("Forgejo", "the source repository was deleted"), do: {false, nil}

  defp gitlab_projects(source, target, ids \\ %{}),
    do:
      Map.merge(ids, %{
        "source_project" => %{"path_with_namespace" => source},
        "target_project" => %{"path_with_namespace" => target}
      })

  # Pull request 42 from "feature/tax" as each host answers for it; `source` is what it
  # says of the repository the head comes from ("sam/shop" when that is a fork).
  defp answer_host(context, "GitHub", _source) do
    context
    |> answer_view(%{
      "isCrossRepository" => true,
      "headRepository" => %{"id" => "R_fork", "name" => "shop", "nameWithOwner" => "sam/shop"},
      "headRepositoryOwner" => %{"login" => "sam"}
    })
    |> Shared.answer_lookup("github", "sam/shop")
  end

  defp answer_host(context, "GitLab", projects) do
    World.git!(context.cwd, ~w(remote set-url origin git@gitlab.com:acme/shop.git))

    mr =
      Map.merge(projects, %{
        "iid" => 42,
        "title" => "Charge tax at checkout",
        "web_url" => "https://gitlab.com/acme/shop/-/merge_requests/42",
        "target_branch" => "main",
        "source_branch" => "feature/tax",
        "state" => "opened",
        "sha" => context.pr_head
      })

    context
    |> World.fake_cli(["glab"])
    |> World.cli_rules(%{"cmd" => "glab", "args" => ["mr view 42 "], "stdout" => mr})
    |> Shared.answer_lookup("gitlab", "sam/shop")
  end

  defp answer_host(context, "Bitbucket", source) do
    World.git!(context.cwd, ~w(remote set-url origin git@bitbucket.org:acme/shop.git))

    pr = %{
      "id" => 42,
      "title" => "Charge tax at checkout",
      "state" => "OPEN",
      "links" => %{"html" => %{"href" => "https://bitbucket.org/acme/shop/pull-requests/42"}},
      "source" => %{
        "branch" => %{"name" => "feature/tax"},
        "commit" => %{"hash" => context.pr_head},
        "repository" => source
      },
      "destination" => %{
        "branch" => %{"name" => "main"},
        "repository" => %{"full_name" => "acme/shop"}
      }
    }

    fork = %{
      "full_name" => "sam/shop",
      "links" => %{
        "clone" => [
          %{"name" => "https", "href" => "https://bitbucket.org/sam/shop.git"},
          %{"name" => "ssh", "href" => "git@bitbucket.org:sam/shop.git"}
        ]
      }
    }

    {base, _log} =
      FakeHttp.start(%{
        "/2.0/repositories/acme/shop/pullrequests/42" => {200, pr},
        "/2.0/repositories/sam/shop" => {200, fork}
      })

    Shared.put_env("HAL_C2_BITBUCKET_API_BASE_URL", base <> "/2.0")
    Shared.put_env("HAL_C2_BITBUCKET_ACCESS_TOKEN", "bitbucket-token")
    context
  end

  defp answer_host(context, "Forgejo", source) do
    World.git!(context.cwd, ~w(remote set-url origin git@codeberg.org:acme/shop.git))

    pr = %{
      "number" => 42,
      "title" => "Charge tax at checkout",
      "html_url" => "https://codeberg.org/acme/shop/pulls/42",
      "state" => "open",
      "merged" => false,
      "base" => %{"ref" => "main", "repo" => %{"full_name" => "acme/shop"}},
      "head" => %{"ref" => "feature/tax", "sha" => context.pr_head, "repo" => source}
    }

    forgejo_api(context, %{
      "/api/v1/repos/acme/shop/pulls/42" => {200, pr},
      "/api/v1/repos/sam/shop" => {200, forgejo_repository("sam/shop")}
    })
  end

  defp forgejo_repository(repository),
    do: %{
      "full_name" => repository,
      "clone_url" => "https://codeberg.org/#{repository}.git",
      "ssh_url" => "git@codeberg.org:#{repository}.git"
    }

  # fj signed in to codeberg.org, whose API is a `HalC2.Test.FakeHttp` serving `routes`
  # (`HAL_C2_FORGEJO_API_BASE_URL`); its log is the context's `:forgejo`.
  defp forgejo_api(context, routes) do
    keys = Path.join(Mc.tmp_dir(context.mc, "forgejo-cli"), "keys.json")

    File.write!(
      keys,
      JSON.encode!(%{
        "hosts" => %{"codeberg.org" => %{"type" => "Application", "token" => "fj-token"}},
        "aliases" => %{}
      })
    )

    previous = Application.get_env(:hal_c2, :fj_keys_paths)
    Application.put_env(:hal_c2, :fj_keys_paths, [keys])
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:hal_c2, :fj_keys_paths, previous) end)

    {base, log} = FakeHttp.start(routes)
    Shared.put_env("HAL_C2_FORGEJO_API_BASE_URL", base)

    context
    |> World.fake_cli(["fj"])
    |> World.cli_rules([
      %{"cmd" => "fj", "args" => ["version"], "stdout" => "fj v0.6.0\n"},
      %{"cmd" => "fj", "args" => ["whoami"], "stdout" => "octocat\n"}
    ])
    |> Map.put(:forgejo, log)
  end

  # Pull request 42 of "acme/shop" on codeberg.org, its head at the server's
  # `refs/pull/42/head`, the checkout's origin reached over `protocol`. Over HTTPS the
  # repository is a mirror under `https/` of the fake remotes, and only it holds the
  # pull request ref; over SSH no HTTPS address resolves.
  defp forgejo_checkout(context, protocol) do
    context = push_head(context, %{"isCrossRepository" => true, "headRefName" => "feature/tax"})
    root = context.cwd

    if protocol == "HTTPS" do
      remotes = System.get_env("HAL_C2_FAKE_REMOTES")

      World.git!(root, [
        "clone",
        "-q",
        "--mirror",
        bare(@repository),
        Path.join(remotes, "https/acme/shop.git")
      ])

      World.git!(root, ~w(remote set-url origin https://codeberg.org/acme/shop.git))
      World.git!(root, ["config", "url.#{remotes}/https/.insteadOf", "https://codeberg.org/"])
      # The SSH address no longer has the head, so only an HTTPS fetch finds it.
      World.git!(bare(@repository), ~w(update-ref -d refs/pull/42/head))
    else
      World.git!(root, ~w(remote set-url origin git@codeberg.org:acme/shop.git))
    end

    pr = %{
      "number" => 42,
      "title" => "Charge tax at checkout",
      "html_url" => "https://codeberg.org/acme/shop/pulls/42",
      "state" => "open",
      "merged" => false,
      "base" => %{"ref" => "main", "repo" => %{"full_name" => "acme/shop"}},
      "head" => %{
        "ref" => "feature/tax",
        "sha" => context.pr_head,
        "repo" => %{"full_name" => "acme/shop"}
      }
    }

    forgejo_api(context, %{
      "/api/v1/repos/acme/shop/pulls/42" => {200, pr},
      "/api/v1/repos/acme/shop" => {200, forgejo_repository(@repository)}
    })
  end

  defp forgejo_pull(number, head, state, merged? \\ false),
    do: %{
      "number" => number,
      "title" => "Change #{number}",
      "html_url" => "https://codeberg.org/acme/shop/pulls/#{number}",
      "state" => state,
      "merged" => merged?,
      "base" => %{"ref" => "main"},
      "head" => %{"ref" => head}
    }

  # "acme/shop" on codeberg.org listing `pulls_of.(state)` 50 to a page, as Forgejo
  # pages `GET /repos/{repo}/pulls`.
  defp forgejo_listing(context, pulls_of) do
    World.git!(context.cwd, ~w(remote set-url origin git@codeberg.org:acme/shop.git))

    forgejo_api(context, %{
      "/api/v1/repos/acme/shop/pulls" => fn conn ->
        query = URI.decode_query(conn.query_string)
        page = String.to_integer(query["page"] || "1")
        {200, query["state"] |> pulls_of.() |> Enum.slice((page - 1) * 50, 50)}
      end
    })
  end

  defp forgejo_listings(context),
    do:
      for(
        r <- FakeHttp.requests(context.forgejo),
        r["path"] == "/api/v1/repos/acme/shop/pulls",
        do: r
      )

  defp assert_follows(context, upstream) do
    assert %{"worktreePath" => path} = context.prepared
    assert World.git!(path, ~w(rev-parse --abbrev-ref @{upstream})) == upstream
    assert World.git!(path, ~w(rev-parse HEAD)) == context.pr_head
    context
  end

  defp mode_of("the local checkout"), do: "local"
  defp mode_of("a new worktree"), do: "worktree"

  # Pull request 42's head on the fake GitHub, and `gh pr view` answering for it (by
  # number and by URL) with `fields` over the defaults; `gh pr checkout` checks it out
  # as `gh` would. Once per scenario, unless `fields` change.
  defp answer_view(context, fields \\ %{}) do
    if context[:pr_view] && fields == %{} do
      context
    else
      pr =
        Map.merge(
          %{
            "number" => 42,
            "title" => "Charge tax at checkout",
            "url" => @url,
            "baseRefName" => "main",
            "headRefName" => "feature/tax",
            "state" => "OPEN",
            "isCrossRepository" => false
          },
          fields
        )

      context = push_head(context, pr)

      context
      |> World.cli_rules([
        %{"args" => ["pr view 42 "], "stdout" => pr},
        %{"args" => ["pr view #{@url} "], "stdout" => pr},
        %{
          "args" => ["pr view 9999 "],
          "stderr" =>
            "GraphQL: Could not resolve to a PullRequest with the number of 9999. (repository.pullRequest)\n",
          "exit" => 1
        },
        %{
          "args" => ["pr checkout 42 --force"],
          "run" =>
            "git fetch -q origin +refs/pull/42/head:refs/heads/#{pr["headRefName"]} && " <>
              "git checkout -q #{pr["headRefName"]}"
        }
      ])
      |> Map.put(:pr_view, pr)
    end
  end

  # A commit only the pull request has, at `refs/pull/42/head` on the fake GitHub, and
  # on its branch there unless it comes from a fork. The checkout stays on main.
  defp push_head(%{pr_head: _} = context, _pr), do: context

  defp push_head(context, pr) do
    root = context.cwd
    World.git!(root, ~w(checkout -q -b pr-head-source))
    head = World.commit!(root, %{"tax.txt" => "tax\n"}, "Charge tax")
    World.git!(root, ~w(push -q origin HEAD:refs/pull/42/head))

    unless pr["isCrossRepository"],
      do: World.git!(root, ["push", "-q", "origin", "HEAD:refs/heads/#{pr["headRefName"]}"])

    World.git!(root, ~w(checkout -q main))
    World.git!(root, ~w(branch -q -D pr-head-source))
    if not pr["isCrossRepository"], do: World.git!(root, ["fetch", "-q", "origin"])
    Map.put(context, :pr_head, head)
  end

  defp prepare(context, mode, reference \\ "42") do
    {reply, context} =
      World.call(context, "git.preparePullRequestThread", %{
        "cwd" => World.project(context, @repository).root,
        "reference" => reference,
        "mode" => mode
      })

    Map.put(context, :reply, reply)
  end

  defp discovery(context) do
    Mc.ensure({HalC2.PullRequests.Discovery, interval: nil})
    context
  end

  # `gh pr list --head <branch>`: the branch's latest pull request.
  defp branch_answer(context, branch, number, state) do
    World.cli_rules(context, %{
      "args" => ["pr list", "--head #{branch}"],
      "stdout" => [
        %{
          "number" => number,
          "url" => "https://github.com/acme/shop/pull/#{number}",
          "state" => state,
          "mergedAt" => nil,
          "closedAt" => nil
        }
      ]
    })
  end

  # `gh pr list --head` finds nothing for the thread's branch; GitHub's pull requests of
  # the worktree's commit name the open pull request `number` from `head_branch`.
  defp head_answer(context, number, head_branch) do
    sha = World.git!(context.worktree.path, ~w(rev-parse HEAD))

    context
    |> World.cli_rules([
      %{"args" => ["pr list", "--head #{context.branch}"], "stdout" => []},
      %{
        "args" => ["commits/#{sha}/pulls"],
        "stdout" => [
          %{
            "number" => number,
            "html_url" => "https://github.com/acme/shop/pull/#{number}",
            "state" => "open",
            "head" => %{"sha" => sha, "ref" => head_branch}
          }
        ]
      }
    ])
    |> Map.put(:expected_source, "created")
  end

  defp thread(context, title) do
    if (context[:threads] || %{})[title],
      do: context,
      else: World.create_thread(context, title, @repository)
  end

  # A manual link, as the link dialog makes it, synced by `HalC2.PullRequests.Sync`.
  defp link(context, repository, number, title) do
    context = context |> thread(title) |> sync()
    id = World.thread_id(context, title)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.pull-request.link",
        "threadId" => id,
        "host" => "github.com",
        "repository" => repository,
        "number" => number,
        "url" => "https://github.com/#{repository}/pull/#{number}",
        "source" => "manual"
      })

    World.await_row(id, fn row ->
      Enum.any?(
        row["pullRequests"] || [],
        &(&1["repository"] == repository and &1["number"] == number)
      )
    end)

    context
  end

  defp sync(context) do
    Mc.ensure({HalC2.PullRequests.Sync, interval: nil})
    context = World.cli_rules(context, %{"args" => ["stacks?pull_request="], "stdout" => []})
    if context[:summaries], do: context, else: summaries(context, %{})
  end

  # GitHub's summary of every pull request asked about, as `fields` over an open one.
  defp summaries(context, fields) do
    pr =
      Map.merge(
        %{
          "title" => "Pull request 42",
          "url" => @url,
          "state" => "OPEN",
          "isDraft" => false,
          "headRefName" => "feature/tax",
          "baseRefName" => "main",
          "reviewDecision" => "REVIEW_REQUIRED",
          "updatedAt" => "2026-09-02T00:00:00Z",
          "mergedAt" => nil,
          "author" => %{"login" => "octocat"}
        },
        fields
      )

    context
    |> World.cli_rules(%{
      "args" => ["api graphql"],
      "stdin" => ["PullRequestSummaries"],
      "stdout" => %{"data" => Map.new(0..3, &{"s#{&1}", %{"pullRequest" => pr}})}
    })
    |> Map.put(:summaries, pr)
  end

  defp summary_reads(context),
    do:
      context
      |> World.cli_calls("graphql")
      |> Enum.count(&(&1["stdin"] =~ "PullRequestSummaries"))

  defp await_link(context, title, number, fun) do
    row =
      World.await_row(World.thread_id(context, title), fn row ->
        Enum.any?(row["pullRequests"] || [], &(&1["number"] == number and fun.(&1)))
      end)

    Enum.find(row["pullRequests"], &(&1["number"] == number and fun.(&1)))
  end
end
