defmodule HalC2.Steps.SourceControl.StatusAndChanges do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  defp git(context, args), do: World.git!(context.cwd, args)

  defp status(context) do
    assert {:ok, status} = context.reply
    status
  end

  step "a connected environment with the project {string} in a git repository",
       %{args: [title]} = context do
    Shared.thread_in_git_project(context, title)
  end

  # --- local status --------------------------------------------------------------------

  step "the user has changed {string} and added {string} on the branch {string}",
       %{args: [changed, added, branch]} = context do
    World.commit!(context.cwd, %{changed => "one\ntwo\nthree\n"}, "Add #{changed}")
    git(context, ["checkout", "-q", "-b", branch])
    File.write!(Path.join(context.cwd, changed), "one\n2\n3\nfour\n")
    File.write!(Path.join(context.cwd, added), "export const tax = 1\nexport const rate = 2\n")
    git(context, ["add", added])
    Map.put(context, :changed, %{changed => {3, 2}, added => {2, 0}})
  end

  step "the status names the branch {string}", %{args: [branch]} = context do
    assert status(context)["refName"] == branch
    context
  end

  step "it lists both files with their inserted and deleted line counts", context do
    files =
      for f <- status(context)["workingTree"]["files"],
          into: %{},
          do: {f["path"], {f["insertions"], f["deletions"]}}

    assert files == context.changed
    context
  end

  step "it says the working tree has changes", context do
    assert status(context)["hasWorkingTreeChanges"] == true
    context
  end

  step "{string} tracks {string} and is 2 commits ahead and 1 behind",
       %{args: [branch, "origin/" <> branch]} = context do
    git(context, ["checkout", "-q", "-b", branch])
    World.commit!(context.cwd, %{"upstream.ts" => "1\n"}, "Upstream work")
    git(context, ~w(push -q -u origin HEAD))
    git(context, ~w(reset -q --hard HEAD~1))
    World.commit!(context.cwd, %{"cart.ts" => "1\n"}, "Add cart")
    World.commit!(context.cwd, %{"tax.ts" => "1\n"}, "Add tax")
    context
  end

  step "the status says the branch has an upstream", context do
    assert status(context)["hasUpstream"] == true
    context
  end

  step "it reports 2 commits ahead and 1 behind", context do
    assert {status(context)["aheadCount"], status(context)["behindCount"]} == {2, 1}
    context
  end

  # --- the status stream ------------------------------------------------------------

  step "the agent's turn ends after editing a file", context do
    World.run_turn(context, context.thread_title, "write notes.md")
  end

  step "the thread's status shows the new change without the user asking for a refresh",
       context do
    {event, context} =
      World.await_vcs(context, &(&1["_tag"] == "localUpdated"), 10_000)

    assert event["local"]["hasWorkingTreeChanges"]
    assert Enum.any?(event["local"]["workingTree"]["files"], &(&1["path"] == "notes.md"))
    context
  end

  step "the user is looking at a thread in {string} with uncommitted changes",
       %{args: [title]} = context do
    root = World.project(context, title).root
    File.write!(Path.join(root, "cart.ts"), "export const cart = 1\n")
    context = World.watch_vcs(context, root)
    assert context.vcs.local["hasWorkingTreeChanges"]
    context
  end

  step "the user commits the changes", context do
    {events, context} =
      World.git_action(context, context.cwd, "commit", %{"commitMessage" => "Add the cart"})

    assert List.last(events)["kind"] == "action_finished"
    Map.put(context, :git_events, events)
  end

  step "the thread's status reports a clean working tree", context do
    {event, context} =
      World.await_vcs(
        context,
        &(&1["_tag"] == "localUpdated" and &1["local"]["hasWorkingTreeChanges"] == false)
      )

    assert event["local"]["workingTree"]["files"] == []
    context
  end

  # --- background fetches -----------------------------------------------------------

  defp fetch_interval(context, seconds) do
    Mc.ensure(HalC2.BackgroundPolicy)

    World.put_settings(context, %{
      "backgroundActivity" => %{
        "profile" => "custom",
        "baseProfile" => "balanced",
        "overrides" => %{"automaticGitFetchInterval" => seconds * 1_000}
      }
    })
  end

  # A client lease on the checkout's status, as `server.reportClientActivity` takes it.
  defp show(context, in_front?) do
    Mc.ensure(HalC2.BackgroundPolicy)
    context = World.watch_vcs(context, context.cwd)

    HalC2.BackgroundPolicy.report_client_activity("session", self(), %{
      "clientId" => "client-1",
      "clientKind" => "web",
      "visible" => in_front?,
      "focused" => in_front?,
      "scopes" => [%{"type" => "vcs-status", "cwd" => context.cwd}]
    })

    # Leases are cast; a call behind it sees the lease in place.
    assert HalC2.BackgroundPolicy.snapshot()["activeForegroundLeaseCount"] ==
             if(in_front?, do: 1, else: 0)

    context
  end

  defp watcher(context) do
    [{pid, _}] = Registry.lookup(HalC2.Vcs.Registry, context.cwd)
    pid
  end

  # Someone else pushes to the remote; only a fetch shows it here.
  defp upstream_moves(context) do
    other = Mc.tmp_dir(context.mc, "other")
    World.git!(other, ["clone", "-q", context.bare, "."])

    World.git!(
      other,
      ~w(-c user.email=o@example.com -c user.name=O commit -q --allow-empty -m remote)
    )

    World.git!(other, ~w(push -q origin HEAD:main))
    Map.put(context, :tracking_before, git(context, ~w(rev-parse origin/main)))
  end

  # Time passes until the watcher's armed timer fires: it is cancelled and its
  # message delivered now. Returns which message that was.
  defp elapse(context) do
    pid = watcher(context)
    {message, ref} = :sys.get_state(pid).timer
    remaining = Process.cancel_timer(ref)
    send(pid, message)
    _ = :sys.get_state(pid)
    {message, remaining}
  end

  step "the automatic Git fetch interval is {int} seconds", %{args: [seconds]} = context do
    fetch_interval(context, seconds)
  end

  step "a client in front is showing a thread in {string}", %{args: [title]} = context do
    assert World.project(context, title).root == context.cwd
    context = context |> shared_answers() |> show(true) |> upstream_moves()
    Map.put(context, :reply, {:ok, Map.merge(context.vcs.local, context.vcs.remote)})
  end

  step "{int} seconds pass", %{args: [seconds]} = context do
    if root = context[:codex_skills_read] do
      # A Codex skills read (providers/codex.feature) is bounded at 20 seconds of
      # its own; asking for the folder's skills is what waits it out.
      reply = HalC2.Environment.refresh_providers(%{"cwd" => root, "instanceId" => "codex"})

      context
      |> Map.merge(%{reply: reply, skills_cwd: root})
      |> Map.delete(:codex_skills_read)
    else
      {message, remaining} = elapse(context)
      assert message == :fetch
      assert remaining <= seconds * 1_000
      context
    end
  end

  step "the MC fetches from the remote and the ahead and behind counts are updated",
       context do
    {event, context} = World.await_vcs(context, &(&1["_tag"] == "remoteUpdated"))
    assert event["remote"]["behindCount"] == 1
    refute git(context, ~w(rev-parse origin/main)) == context.tracking_before
    context
  end

  step "a client shows a thread in {string} for several minutes", %{args: [title]} = context do
    assert World.project(context, title).root == context.cwd
    context = context |> show(true) |> upstream_moves()
    fired = for _ <- 1..6, do: elapse(context) |> elem(0)
    Map.put(context, :fired, fired)
  end

  step "the MC never fetches from the remote without being asked", context do
    assert Enum.all?(context.fired, &(&1 == :fetch_off))
    assert git(context, ~w(rev-parse origin/main)) == context.tracking_before
    context
  end

  step "no client is showing a thread in {string}", %{args: [title]} = context do
    assert World.project(context, title).root == context.cwd
    # A client has the thread open in the background: subscribed, not in front.
    context |> fetch_interval(30) |> show(false) |> upstream_moves()
  end

  step "the fetch interval elapses", context do
    {message, _} = elapse(context)
    assert message == :fetch
    context
  end

  step "the MC does not fetch {string} from the remote", %{args: [_title]} = context do
    assert git(context, ~w(rev-parse origin/main)) == context.tracking_before
    context
  end

  # --- pull requests ------------------------------------------------------------------

  defp pr(number, branch, state, draft?) do
    %{
      "number" => number,
      "title" => "Add tax",
      "url" => "https://github.com/acme/shop/pull/#{number}",
      "baseRefName" => "main",
      "headRefName" => branch,
      "state" => state,
      "isDraft" => draft?,
      "updatedAt" => "2026-09-20T10:00:00Z"
    }
  end

  step "{string} has an open draft pull request on GitHub", %{args: [branch]} = context do
    git(context, ["checkout", "-q", "-b", branch])

    World.cli_rules(context, [
      %{"args" => ["pr list", "--head #{branch}"], "stdout" => [pr(42, branch, "OPEN", true)]}
    ])
  end

  step "the status carries that pull request with its state open and marked as a draft",
       context do
    assert %{"number" => 42, "state" => "open", "isDraft" => true, "headRef" => "feature/tax"} =
             status(context)["pr"]

    context
  end

  step "{string} once had a merged pull request from the same branch name",
       %{args: [branch]} = context do
    World.cli_rules(context, [
      %{"args" => ["pr list", "--head #{branch}"], "stdout" => [pr(9, branch, "MERGED", false)]}
    ])
  end

  step "status is read on {string}", %{args: [branch]} = context do
    assert git(context, ~w(branch --show-current)) == branch
    {reply, context} = World.call(context, "vcs.refreshStatus", %{"cwd" => context.cwd})
    assert World.cli_calls(context, "--head #{branch}") != []
    Map.put(context, :reply, reply)
  end

  step "the status carries no pull request", context do
    assert status(context)["pr"] == nil
    context
  end

  # --- one answer per branch (`HalC2.PullRequests.Branches`) ----------------------------

  # The branch answers are shared, on a clock the scenario moves.
  defp shared_answers(context) do
    if context[:clock] do
      context
    else
      Mc.ensure(HalC2.PullRequests.Branches)
      ref = :atomics.new(1, signed: true)
      :atomics.put(ref, 1, DateTime.to_unix(~U[2026-11-03 10:00:00Z], :millisecond))
      Application.put_env(:hal_c2, :github_clock, fn -> :atomics.get(ref, 1) end)
      ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :github_clock) end)
      Map.put(context, :clock, ref)
    end
  end

  defp pass(context, ms), do: :atomics.add(context.clock, 1, ms)

  # Discovery has handled every message it was sent and has no run of its own queued.
  # Each round trip lets it handle one more message; a run it keeps queueing for itself
  # fails here, with what it still has, rather than as a timeout.
  defp discovery_idle(rounds \\ 100) do
    pid = Process.whereis(HalC2.PullRequests.Discovery)
    state = :sys.get_state(pid)
    {:message_queue_len, queued} = Process.info(pid, :message_queue_len)

    cond do
      state.pending == %{} and queued == 0 ->
        :ok

      rounds > 0 ->
        discovery_idle(rounds - 1)

      true ->
        flunk("Discovery never went idle: #{queued} queued, pending #{inspect(state.pending)}")
    end
  end

  defp asked(context, branch), do: length(World.cli_calls(context, "--head #{branch}"))

  # The watcher's automatic fetch runs now; the pull request it holds afterwards.
  defp fetch_now(context) do
    {message, _} = elapse(context)
    assert message == :fetch
    :sys.get_state(watcher(context)).remote["pr"]
  end

  step "the host refuses the pull request lookup for {string} every time",
       %{args: [branch]} = context do
    context
    |> shared_answers()
    |> World.cli_rules(%{
      "args" => ["pr list", "--head #{branch}"],
      "stderr" => "error connecting to api.github.com\n",
      "exit" => 1
    })
    |> Map.put(:pr_branch, branch)
  end

  step ~r/^the host's last answer for "(?<branch>[^"]+)" was (?<answer>an open pull request|a merged pull request|no pull request at all)$/,
       %{args: [branch, answer]} = context do
    answer =
      case answer do
        "an open pull request" -> [pr(42, branch, "OPEN", false)]
        "a merged pull request" -> [pr(42, branch, "MERGED", false)]
        "no pull request at all" -> []
      end

    context
    |> shared_answers()
    |> World.cli_rules(%{"args" => ["pr list", "--head #{branch}"], "stdout" => answer})
    |> Map.put(:pr_branch, branch)
  end

  step "a client in front is showing a thread in {string} on {string}",
       %{args: [title, branch]} = context do
    assert World.project(context, title).root == context.cwd
    git(context, ["checkout", "-q", "-b", branch])
    context = context |> fetch_interval(30) |> show(true)
    Map.put(context, :asked_at, asked(context, branch))
  end

  step "the status's automatic fetch runs again and again", context do
    fetch_now(context)
    # The watcher asked when it started, and the failure is still waited out.
    assert asked(context, context.pr_branch) == 1
    context
  end

  step "the lookup is retried after 20 seconds, then 40 seconds, doubling up to 15 minutes",
       context do
    for wait <- [20, 40, 80, 160, 320, 640, 900, 900], reduce: 1 do
      asks ->
        pass(context, wait * 1_000 - 1)
        fetch_now(context)
        assert asked(context, context.pr_branch) == asks, "asked before #{wait} s"
        pass(context, 1)
        fetch_now(context)
        assert asked(context, context.pr_branch) == asks + 1, "not asked after #{wait} s"
        asks + 1
    end

    context
  end

  step "the first answer that succeeds brings back the normal rhythm", context do
    branch = context.pr_branch

    context =
      World.cli_rules(context, %{
        "args" => ["pr list", "--head #{branch}"],
        "stdout" => [pr(42, branch, "OPEN", false)]
      })

    asks = asked(context, branch)
    pass(context, 900_000)
    assert %{"number" => 42, "state" => "open"} = fetch_now(context)
    assert asked(context, branch) == asks + 1
    # An open pull request is believed for a minute.
    pass(context, 59_999)
    fetch_now(context)
    assert asked(context, branch) == asks + 1
    pass(context, 1)
    fetch_now(context)
    assert asked(context, branch) == asks + 2
    context
  end

  step "the status's automatic fetch runs over the next minutes", context do
    fetch_now(context)
    assert asked(context, context.pr_branch) == 1
    context
  end

  step ~r/^the host is asked again after about (?<count>\d+) minutes?$/,
       %{args: [count]} = context do
    wait = String.to_integer(count) * 60_000
    pass(context, wait - 1)
    fetch_now(context)
    assert asked(context, context.pr_branch) == 1
    pass(context, 1)
    fetch_now(context)
    assert asked(context, context.pr_branch) == 2
    context
  end

  step "the MC has found the pull request of the thread {string} on {string}",
       %{args: [thread, branch]} = context do
    context = shared_answers(context)
    Mc.ensure({HalC2.PullRequests.Discovery, interval: nil})

    context =
      World.command(context, %{
        "type" => "thread.metadata.update",
        "threadId" => World.thread_id(context, thread),
        "branch" => branch
      })

    assert {:ok, _} = context.reply
    # The sidebar row Discovery reads is written behind the command.
    HalC2.Streams.flush_shell(World.thread_id(context, thread))
    :ok = HalC2.PullRequests.Discovery.sweep()
    # The branch change also queued a run of Discovery's own behind the sweep, which may
    # read the row from before the sweep's write and ask GitHub to confirm it: it ends
    # before the count, with the sweep's row in the shell, rather than during the status.
    HalC2.Streams.flush_shell(World.thread_id(context, thread))
    discovery_idle()
    assert %{"number" => 42} = World.thread(context, thread)["branchPullRequest"]
    Map.put(context, :asked_before, asked(context, branch))
  end

  step "the status did not ask the host about {string}", %{args: [branch]} = context do
    assert asked(context, branch) == context.asked_before
    context
  end

  step "the status asked the host about {string} again", %{args: [branch]} = context do
    assert asked(context, branch) == context.asked_before + 1
    context
  end

  step "the user refreshes the pull requests", context do
    context = Map.put(context, :asked_before, asked(context, "feature/tax"))
    {reply, context} = World.call(context, "pullRequests.invalidate", %{})
    assert {:ok, _} = reply
    context
  end

  step "the status's automatic fetch runs", context do
    fetch_now(context)
    context
  end

  # --- not a repository ---------------------------------------------------------------

  step "the project {string} is not in a git repository", %{args: [title]} = context do
    root = Mc.tmp_dir(context.mc, World.slug(title))
    World.create_project(context, title, %{"workspaceRoot" => root})
  end

  step "the status says it is not a repository", context do
    assert status(context)["isRepo"] == false
    context
  end

  step "{string} becomes a git repository", %{args: [title]} = context do
    assert {:ok, _} = context.reply
    assert File.dir?(Path.join(World.project(context, title).root, ".git"))
    context
  end

  step "the git actions for {string} become available", %{args: [title]} = context do
    {reply, context} =
      World.call(context, "vcs.refreshStatus", %{"cwd" => World.project(context, title).root})

    assert {:ok, %{"isRepo" => true}} = reply
    context
  end

  # --- paths exactly as git has them ---------------------------------------------------

  # A name as a scenario writes it: in either kind of quotes, or a name with the invisible
  # byte-order mark in front.
  defp name("\"" <> _ = text), do: String.trim(text, "\"")
  defp name("'" <> _ = text), do: text |> String.trim("'")

  defp name("a name of U+FEFF followed by " <> rest), do: "\uFEFF" <> name(rest)
  defp name("that name, U+FEFF included"), do: :listed_name

  defp write_and_add(context, path, content \\ "one\ntwo\n") do
    File.mkdir_p!(Path.dirname(Path.join(context.cwd, path)))
    File.write!(Path.join(context.cwd, path), content)
    git(context, ["--literal-pathspecs", "add", "--", path])
  end

  step ~r/^the user has (?<kind>added|renamed) (?<change>.+) in "(?<title>[^"]+)"$/,
       %{args: [kind, change, title]} = context do
    assert World.project(context, title).root == context.cwd

    case kind do
      "added" ->
        path = name(change)
        write_and_add(context, path)
        Map.put(context, :listed, %{path: path, previous: nil})

      "renamed" ->
        [from, to] = Regex.run(~r/^("[^"]+") to (.+)$/, change, capture: :all_but_first)
        from = name(from)
        to = name(to)
        World.commit!(context.cwd, %{from => "one\ntwo\nthree\nfour\nfive\n"}, "Add #{from}")
        File.mkdir_p!(Path.dirname(Path.join(context.cwd, to)))
        git(context, ["mv", "--", from, to])
        Map.put(context, :listed, %{path: to, previous: from})
    end
  end

  step ~r/^it lists (?<listed>"[^"]*"|'[^']*'|that name, U\+FEFF included)(?:,? as renamed from (?<from>"[^"]*"))?$/,
       %{args: [listed | from]} = context do
    expected = context.listed
    previous = from |> List.first() |> then(&(&1 && name(&1)))
    path = if name(listed) == :listed_name, do: expected.path, else: name(listed)
    assert path == expected.path
    file = Enum.find(status(context)["workingTree"]["files"], &(&1["path"] == path))
    assert file, "#{inspect(path)} is not in #{inspect(status(context)["workingTree"]["files"])}"
    assert file["previousPath"] == previous
    context
  end

  step "a git action given that path acts on that file", context do
    path = context.listed.path

    {events, context} =
      World.git_action(context, context.cwd, "commit", %{
        "commitMessage" => "Take the file",
        "filePaths" => [path]
      })

    assert List.last(events)["kind"] == "action_finished"

    committed =
      context.cwd
      |> World.git!(~w(show --name-only --format= -z HEAD))
      |> String.split(<<0>>, trim: true)

    assert path in committed
    context
  end

  # --- a bare repository among the project's files --------------------------------------

  step "the folder {string} in {string} is shaped like a bare repository with a hook",
       %{args: [folder, title]} = context do
    root = World.project(context, title).root
    evil = Path.join(root, folder)
    File.mkdir_p!(evil)
    World.git!(evil, ~w(init -q --bare))
    marker = Path.join(Mc.tmp_dir(context.mc, "hook"), "ran")
    hook = Path.join(evil, "hook.sh")
    File.write!(hook, "#!/bin/sh\ntouch '#{marker}'\n")
    File.chmod!(hook, 0o755)
    # What a hostile repository would plant: a program git runs on every status.
    World.git!(evil, ["config", "core.bare", "false"])
    World.git!(evil, ["config", "core.worktree", evil])
    World.git!(evil, ["config", "core.fsmonitor", hook])
    Map.merge(context, %{evil: evil, hook_marker: marker})
  end

  step "HAL-C2 runs git inside {string}", %{args: [folder]} = context do
    assert context.evil == Path.join(context.cwd, folder)
    Map.put(context, :git_result, HalC2.Git.run(context.evil, ~w(status --porcelain=2)))
  end

  step "{string} is not opened as a repository", %{args: [folder]} = context do
    assert context.evil == Path.join(context.cwd, folder)
    assert {:ok, %{status: status}} = context.git_result
    assert status != 0
    assert HalC2.Vcs.local_status(context.evil)["isRepo"] == false
    context
  end

  step "the hook does not run", context do
    refute File.exists?(context.hook_marker)
    context
  end

  # --- a folder git cannot read the status of ------------------------------------------

  step "git is not installed on the MC's machine", context do
    previous = Application.get_env(:hal_c2, :git_command)
    Application.put_env(:hal_c2, :git_command, "/nonexistent/hal-c2-git")

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :git_command, previous),
        else: Application.delete_env(:hal_c2, :git_command)
    end)

    context
  end

  step "no failure is reported", context do
    assert {:ok, _} = context.reply
    context
  end

  step "the status names the branch the first commit will go on", context do
    assert status(context)["refName"] ==
             World.git!(context.cwd, ~w(symbolic-ref --short HEAD))

    context
  end

  step "{string} and {string} are listed with their changed line counts",
       %{args: [a, b]} = context do
    files =
      for f <- status(context)["workingTree"]["files"],
          into: %{},
          do: {f["path"], {f["insertions"], f["deletions"]}}

    assert Map.take(files, [a, b]) == %{a => {1, 0}, b => {1, 0}}
    context
  end

  step "another git process is holding the index lock of {string}", %{args: [title]} = context do
    root = World.project(context, title).root
    File.write!(Path.join(root, ".git/index.lock"), "")
    Map.put(context, :index_lock, Path.join(root, ".git/index.lock"))
  end

  step "the status read fails with {string}", %{args: [message]} = context do
    assert {:error, _, %{"detail" => detail}} = context.reply
    assert detail == message
    context
  end

  step "the next status read after the lock is gone reports the checkout normally", context do
    File.rm!(context.index_lock)
    {reply, context} = World.call(context, "vcs.refreshStatus", %{"cwd" => context.cwd})
    assert {:ok, %{"isRepo" => true}} = reply
    context
  end

  # --- initializing ---------------------------------------------------------------------

  step "the user initializes {string} without naming a version control system",
       %{args: [title]} = context do
    {reply, context} =
      World.call(context, "vcs.init", %{"cwd" => World.project(context, title).root})

    Map.put(context, :reply, reply)
  end

  step "status was just read for {string} and said it is not a repository",
       %{args: [title]} = context do
    {reply, context} =
      World.call(context, "vcs.refreshStatus", %{"cwd" => World.project(context, title).root})

    assert {:ok, %{"isRepo" => false}} = reply
    context
  end

  step "{string} is initialized as a git repository", %{args: [title]} = context do
    {reply, context} =
      World.call(context, "vcs.init", %{"cwd" => World.project(context, title).root})

    assert {:ok, _} = reply
    context
  end

  step "the next status for {string} reports the repository", %{args: [title]} = context do
    {reply, context} =
      World.call(context, "vcs.refreshStatus", %{"cwd" => World.project(context, title).root})

    assert {:ok, %{"isRepo" => true}} = reply
    context
  end

  # --- the turn-end pull request check ---------------------------------------------------

  step "the status has no pull request for {string}", %{args: [branch]} = context do
    git(context, ["checkout", "-q", "-b", branch])
    assert context.vcs.remote["pr"] == nil
    context
  end

  step "someone opened a pull request for it on the host", context do
    branch = git(context, ~w(branch --show-current))

    World.cli_rules(context, [
      %{"args" => ["pr list", "--head #{branch}"], "stdout" => [pr(42, branch, "OPEN", false)]}
    ])
  end

  # The turn runs to its end; the status the watcher holds once it has told its clients
  # what the turn changed in the pull request.
  step "the thread's turn ends", context do
    context = World.run_turn(context, context.thread_title, "write notes.md")
    {_event, context} = World.await_vcs(context, &(&1["_tag"] == "remoteUpdated"))
    # The fresh lookup runs off the watcher: wait for it to finish (it casts its answer
    # before it exits), then read what the watcher holds.
    with %{lookup: {_ref, _again, pid}} <- :sys.get_state(watcher(context)) do
      down = Process.monitor(pid)
      assert_receive {:DOWN, ^down, :process, _, _}, 5_000
    end

    state = :sys.get_state(watcher(context))
    Map.put(context, :reply, {:ok, Map.merge(state.local, state.remote)})
  end

  step "the status carries that pull request without waiting for the slower recheck", context do
    assert %{"number" => 42, "state" => "open"} = status(context)["pr"]
    context
  end

  step "the status of {string} carries the pull request of {string}",
       %{args: [title, branch]} = context do
    assert World.project(context, title).root == context.cwd
    git(context, ["checkout", "-q", "-b", branch])

    context =
      World.cli_rules(context, [
        %{"args" => ["pr list", "--head #{branch}"], "stdout" => [pr(42, branch, "OPEN", false)]}
      ])

    context = show(shared_answers(context), true)
    assert %{"number" => 42} = context.vcs.remote["pr"]
    context
  end

  step "the agent checks out {string}, which has no pull request, during its turn",
       %{args: [branch]} = context do
    git(context, ["checkout", "-q", "-b", branch])
    context
  end

  # --- git itself -----------------------------------------------------------------------

  # Every git the MC starts says how it was started, so what it asked of git is checked.
  defp record_git(context) do
    previous = Application.get_env(:hal_c2, :git_command)
    log = Path.join(Mc.tmp_dir(context.mc, "gitlog"), "calls")
    script = Path.join(Path.dirname(log), "git")

    File.write!(script, """
    #!/bin/sh
    echo "$GIT_OPTIONAL_LOCKS $*" >> '#{log}'
    exec git "$@"
    """)

    File.chmod!(script, 0o755)
    Application.put_env(:hal_c2, :git_command, script)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :git_command, previous),
        else: Application.delete_env(:hal_c2, :git_command)
    end)

    Map.put(context, :git_log, log)
  end

  step "the MC keeps the status of {string} fresh in the background",
       %{args: [title]} = context do
    assert World.project(context, title).root == context.cwd
    context |> record_git() |> World.watch_vcs(context.cwd)
  end

  step "the user runs {string} or {string} in {string} while a status read is under way",
       %{args: [checkout, commit, _title]} = context do
    {reply, context} = World.call(context, "vcs.refreshStatus", %{"cwd" => context.cwd})
    assert {:ok, _} = reply
    assert checkout == "git checkout" and commit == "git commit"
    File.write!(Path.join(context.cwd, "user.txt"), "mine\n")
    git(context, ["checkout", "-q", "-b", "user-branch"])
    git(context, ["add", "user.txt"])
    git(context, ["commit", "-q", "-m", "mine"])
    context
  end

  step "the user's git command is not refused for a lock the MC holds", context do
    calls = context.git_log |> File.read!() |> String.split("\n", trim: true)
    reads = Enum.filter(calls, &String.contains?(&1, "status"))
    assert reads != []
    # Status (and every other read) asks git not to refresh the index, which takes its lock.
    assert Enum.all?(calls, &String.starts_with?(&1, "0 "))
    refute File.exists?(Path.join(context.cwd, ".git/index.lock"))
    context
  end

  step "git reports a lock file or a vanished file while a checkpoint is being captured",
       context do
    # A git that fails the capture's `git add` twice as a held lock does, then works.
    tmp = Mc.tmp_dir(context.mc, "flaky")
    counter = Path.join(tmp, "failures")
    script = Path.join(tmp, "git")
    previous = Application.get_env(:hal_c2, :git_command)

    File.write!(script, """
    #!/bin/sh
    for a in "$@"; do
      if [ "$a" = add ]; then
        n=$(cat '#{counter}' 2>/dev/null || echo 0)
        if [ "$n" -lt 2 ]; then
          echo $((n + 1)) > '#{counter}'
          echo "fatal: Unable to create '/x/index.lock': File exists." >&2
          exit 128
        fi
      fi
    done
    exec git "$@"
    """)

    File.chmod!(script, 0o755)
    Application.put_env(:hal_c2, :git_command, script)
    Application.put_env(:hal_c2, :checkpoint_retry_ms, 1)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:hal_c2, :checkpoint_retry_ms)

      if previous,
        do: Application.put_env(:hal_c2, :git_command, previous),
        else: Application.delete_env(:hal_c2, :git_command)
    end)

    Map.put(context, :flaky_counter, counter)
  end

  step "the capture command is retried", context do
    File.write!(Path.join(context.cwd, "captured.txt"), "x\n")
    Map.put(context, :capture, HalC2.Checkpoint.capture(context.cwd, "refs/hal-c2/test/flaky"))
  end

  step "the checkpoint is captured if the second or third attempt succeeds", context do
    assert context.capture == :ok
    assert File.read!(context.flaky_counter) |> String.trim() == "2"
    assert HalC2.Checkpoint.exists?(context.cwd, "refs/hal-c2/test/flaky")
    context
  end

  # --- paths that start with a space -----------------------------------------------------

  step "the user has added {string} to {string}", %{args: [path, title]} = context do
    assert World.project(context, title).root == context.cwd
    write_and_add(context, path)
    Map.put(context, :listed, %{path: path, previous: nil})
  end

  step "it lists {string} with its leading space", %{args: [path]} = context do
    assert path == context.listed.path
    assert Enum.any?(status(context)["workingTree"]["files"], &(&1["path"] == path))
    context
  end

  step "a git action given {string} acts on that file, not on {string}",
       %{args: [path, other]} = context do
    {events, context} =
      World.git_action(context, context.cwd, "commit", %{
        "commitMessage" => "Take the file",
        "filePaths" => [path]
      })

    assert List.last(events)["kind"] == "action_finished"

    committed =
      context.cwd
      |> World.git!(~w(show --name-only --format=%x00 -z HEAD))
      |> String.split(<<0>>, trim: true)
      |> Enum.map(&String.trim_leading(&1, "\n"))

    assert committed == [path]
    refute other in committed
    context
  end

  # --- what a branch tracks ----------------------------------------------------------------

  step "the repository also has a local branch named {string}", %{args: [name]} = context do
    git(context, ["branch", name, "HEAD"])
    record_git(context)
  end

  step "the upstream is {string} on the remote {string}",
       %{args: [upstream, remote]} = context do
    assert HalC2.Git.upstream(context.cwd, git(context, ~w(branch --show-current))) ==
             %{remote: remote, ref: upstream}

    # The refresh fetched the remote that was named, not "remotes".
    calls = File.read!(context.git_log)
    assert calls =~ "fetch --quiet --no-tags #{remote}\n"
    context
  end

  step "it reports 1 commit ahead", context do
    assert status(context)["aheadCount"] == 1
    context
  end

  step "pushing {string} keeps {string} as its base", %{args: [branch, upstream]} = context do
    {events, _context} = World.git_action(context, context.cwd, "push")
    assert %{"push" => %{"upstreamBranch" => ^upstream}} = List.last(events)["result"] || %{}
    assert git(context, ~w(branch --show-current)) == branch
    :ok
  end

  step "{string} tracks the local branch {string} and is 1 commit ahead of it",
       %{args: [branch, parent]} = context do
    git(context, ["checkout", "-q", "-b", parent])
    World.commit!(context.cwd, %{"part1.ts" => "1\n"}, "Part one")
    git(context, ["checkout", "-q", "-b", branch, "--track", parent])
    World.commit!(context.cwd, %{"part2.ts" => "1\n"}, "Part two")
    record_git(context)
  end

  step "nothing is fetched for {string}", %{args: [_branch]} = context do
    calls = if File.exists?(context.git_log), do: File.read!(context.git_log), else: ""
    refute calls =~ " fetch "
    context
  end

  # --- the base a branch is compared with ----------------------------------------------------

  step "the branch {string} has no upstream and is set to merge into {string}",
       %{args: [branch, base]} = context do
    [remote, base_branch] = String.split(base, "/", parts: 2)
    root = Path.dirname(context.bare)
    other = Path.join(root, "#{remote}.git")
    File.mkdir_p!(other)
    World.git!(other, ["init", "-q", "--bare", "-b", "main"])
    git(context, ["remote", "add", remote, other])
    git(context, ["push", "-q", remote, "HEAD:refs/heads/#{base_branch}"])
    # The other remote moves on by a commit origin's main has not seen.
    World.commit!(context.cwd, %{"upstream-only.ts" => "1\n"}, "Only upstream has this")
    git(context, ["push", "-q", remote, "HEAD:refs/heads/#{base_branch}"])
    git(context, ["fetch", "-q", remote])
    git(context, ["checkout", "-q", "--no-track", "-b", branch])
    World.commit!(context.cwd, %{"tax.ts" => "1\n"}, "Fix tax")
    git(context, ["config", "branch.#{branch}.gh-merge-base", base])
    context
  end

  step "the fork's {string} is behind {string}", %{args: [fork, base]} = context do
    assert git(context, ["rev-list", "--count", "#{fork}..#{base}"]) != "0"
    context
  end

  step "status is read for {string} on {string}", %{args: [_title, branch]} = context do
    assert git(context, ~w(branch --show-current)) == branch
    {reply, context} = World.call(context, "vcs.refreshStatus", %{"cwd" => context.cwd})
    Map.put(context, :reply, reply)
  end

  step "its changes and the commits it is ahead are counted against {string}",
       %{args: [base]} = context do
    branch = git(context, ~w(branch --show-current))
    assert HalC2.Git.base_branch(context.cwd, branch) == base
    assert status(context)["aheadCount"] == 1
    assert status(context)["aheadOfDefaultCount"] == 1
    context
  end

  step "commits only {string} has are not shown as the branch's changes",
       %{args: [base]} = context do
    branch = git(context, ~w(branch --show-current))
    only_base = git(context, ["rev-list", "--count", "#{branch}..#{base}"])
    assert only_base == "0"
    assert git(context, ["rev-list", "--count", "origin/main..#{branch}"]) == "2"
    assert status(context)["aheadOfDefaultCount"] == 1
    context
  end

  # --- the primary remote ------------------------------------------------------------------------

  step ~r/^"(?<title>[^"]+)" has (?<remotes>only the remote "[^"]+"|the remotes "[^"]+" and "[^"]+")$/,
       %{args: [title, remotes]} = context do
    assert World.project(context, title).root == context.cwd

    for existing <- String.split(git(context, ["remote"]), "\n", trim: true),
        do: git(context, ["remote", "remove", existing])

    for [name] <- Regex.scan(~r/"([^"]+)"/, remotes, capture: :all_but_first) do
      git(context, ["remote", "add", name, "git@github.com:acme/#{name}.git"])
    end

    context
  end

  step "the MC reads the git status of {string}", %{args: [title]} = context do
    {reply, context} =
      World.call(context, "vcs.refreshStatus", %{"cwd" => World.project(context, title).root})

    Map.put(context, :reply, reply)
  end

  step ~r/^"(?<title>[^"]+)" (?<has>has|does not have) a primary remote$/,
       %{args: [_title, has]} = context do
    assert status(context)["hasPrimaryRemote"] == (has == "has")
    context
  end

  # --- a branch named like a tag -------------------------------------------------------------------

  step "the checked out branch {string} has a tag also named {string}",
       %{args: [branch, tag]} = context do
    git(context, ["checkout", "-q", "-b", branch])
    World.commit!(context.cwd, %{"release.ts" => "1\n"}, "Release work")
    git(context, ["tag", tag])

    World.cli_rules(context, [
      %{"args" => ["pr list", "--head #{branch}"], "stdout" => [pr(42, branch, "OPEN", false)]}
    ])
  end

  step "the status names the branch {string}, not {string}", %{args: [branch, wrong]} = context do
    assert status(context)["refName"] == branch
    refute status(context)["refName"] == wrong
    context
  end

  step "the review compares {string} with the default branch", %{args: [branch]} = context do
    assert HalC2.Git.current_branch(context.cwd) == branch
    assert HalC2.Git.base_branch(context.cwd, branch) in ["origin/main", "main"]
    context
  end

  step "the pull request of {string} is still found", %{args: [branch]} = context do
    assert %{"number" => 42, "headRef" => ^branch} = status(context)["pr"]
    context
  end

  # --- thousands of changed files --------------------------------------------------------------------

  step "the user has changed {int} files with long paths in {string}",
       %{args: [count, title]} = context do
    assert World.project(context, title).root == context.cwd

    for n <- 1..count do
      dir =
        Path.join([
          "packages",
          "some-rather-long-package-name-#{rem(n, 40)}",
          "src",
          "components",
          "nested"
        ])

      path = Path.join(dir, "a-component-with-a-very-long-file-name-number-#{n}.ts")
      File.mkdir_p!(Path.join(context.cwd, dir))
      File.write!(Path.join(context.cwd, path), "export const n = #{n}\n")
    end

    git(context, ["add", "-A"])
    Map.put(context, :changed_count, count)
  end

  step "the status lists all {int} files with their line counts", %{args: [count]} = context do
    files = status(context)["workingTree"]["files"]
    assert length(files) == count
    assert Enum.all?(files, &(&1["insertions"] == 1))
    context
  end

  step "a commit can be prepared from them", context do
    {events, context} =
      World.git_action(context, context.cwd, "commit", %{"commitMessage" => "Take them all"})

    assert List.last(events)["kind"] == "action_finished"
    context
  end

  # --- a late answer for the branch that was left -----------------------------------------------------

  step "a pull request lookup for {string} is still waiting", %{args: [branch]} = context do
    git(context, ["checkout", "-q", "-b", branch])

    context =
      World.cli_rules(context, [
        %{
          "args" => ["pr list", "--head #{branch}"],
          "sleep" => 1,
          "stdout" => [pr(42, branch, "OPEN", false)]
        }
      ])

    context = context |> shared_answers() |> show(true)
    Application.put_env(:hal_c2, :auto_actions, false)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :auto_actions) end)
    HalC2.Vcs.Watch.turn_ended(context.cwd)
    %{lookup: {_ref, _again, _pid}} = :sys.get_state(watcher(context))
    context
  end

  step "the user checks out {string} and the lookup for {string} then answers",
       %{args: [branch, _previous]} = context do
    git(context, ["checkout", "-q", "-b", branch])

    context =
      World.cli_rules(context, [
        %{"args" => ["pr list", "--head #{branch}"], "stdout" => [pr(43, branch, "OPEN", false)]}
      ])

    HalC2.Vcs.Watch.refresh(context.cwd)
    %{lookup: {_ref, _again, pid}} = :sys.get_state(watcher(context))
    down = Process.monitor(pid)
    assert_receive {:DOWN, ^down, :process, _, _}, 10_000
    state = :sys.get_state(watcher(context))
    Map.put(context, :reply, {:ok, Map.merge(state.local, state.remote)})
  end

  step "the status for {string} does not carry the pull request of {string}",
       %{args: [_branch, _previous]} = context do
    assert status(context)["pr"] == nil
    context
  end

  step "a later lookup still finds the pull request of {string}", %{args: [_branch]} = context do
    HalC2.Vcs.Watch.turn_ended(context.cwd)
    %{lookup: {_ref, _again, pid}} = :sys.get_state(watcher(context))
    down = Process.monitor(pid)
    assert_receive {:DOWN, ^down, :process, _, _}, 10_000
    assert %{"number" => 43} = :sys.get_state(watcher(context)).remote["pr"]
    context
  end

  # --- what the user does asks the host again ---------------------------------------------------

  step "status showed no pull request for {string} a moment ago", %{args: [branch]} = context do
    git(context, ["checkout", "-q", "-b", branch])
    World.commit!(context.cwd, %{"tax.ts" => "1\n"}, "Add tax")
    context = context |> shared_answers() |> show(true)
    assert context.vcs.remote["pr"] == nil
    assert asked(context, branch) >= 1
    context
  end

  step "the user refreshes the status", context do
    Map.put(context, :next_status, :refresh)
  end

  step "the user pushes the branch", context do
    {events, context} = World.git_action(context, context.cwd, "push")
    assert List.last(events)["kind"] == "action_finished"
    Map.put(context, :next_status, :fetch)
  end

  step "the user creates the pull request", context do
    {events, context} = World.git_action(context, context.cwd, "create_pr")
    assert List.last(events)["kind"] == "action_finished"
    Map.put(context, :next_status, :fetch)
  end

  step "the next status asks the host about the branch again", context do
    branch = git(context, ~w(branch --show-current))
    before = asked(context, branch)

    case context.next_status do
      :refresh ->
        {reply, _context} = World.call(context, "vcs.refreshStatus", %{"cwd" => context.cwd})
        assert {:ok, _} = reply

      :fetch ->
        assert fetch_now(context) == nil
    end

    assert asked(context, branch) == before + 1
    context
  end

  # --- watchers ---------------------------------------------------------------------------------------

  step "a client is watching the status of {string}", %{args: [title]} = context do
    assert World.project(context, title).root == context.cwd
    HalC2.Vcs.Watch.subscribe(context.cwd, self())
    context
  end

  step "the status is refreshed and nothing about the checkout changed", context do
    HalC2.Vcs.Watch.refresh(context.cwd)
    # The watcher has handled the refresh once it answers.
    _ = :sys.get_state(watcher(context))
    context
  end

  step "the client receives no update", context do
    refute_received {:hal_c2_vcs, _, _}
    context
  end

  step "two clients are watching the status of {string}", %{args: [title]} = context do
    assert World.project(context, title).root == context.cwd
    context = context |> shared_answers() |> show(true) |> upstream_moves() |> record_git()
    parent = self()
    cwd = context.cwd

    for name <- [:one, :two] do
      spawn_link(fn ->
        HalC2.Vcs.Watch.subscribe(cwd, self())
        send(parent, {:ready, name})

        receive do
          {:hal_c2_vcs, _, event} -> send(parent, {:got, name, event})
        end
      end)
    end

    assert_receive {:ready, :one}
    assert_receive {:ready, :two}
    context
  end

  step "the MC fetches {string} once", %{args: [_title]} = context do
    fetches =
      context.git_log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(&(&1 =~ " fetch "))

    assert length(fetches) == 1
    context
  end

  step "both clients receive the result", context do
    assert_receive {:got, :one, %{"_tag" => "remoteUpdated"}}
    assert_receive {:got, :two, %{"_tag" => "remoteUpdated"}}
    context
  end

  # --- background settings and the host ----------------------------------------------------------------

  step "background work is paused for {string} by the user's background activity settings",
       %{args: [title]} = context do
    assert World.project(context, title).root == context.cwd
    git(context, ["checkout", "-q", "-b", "feature/tax"])

    context =
      World.cli_rules(context, [
        %{
          "args" => ["pr list", "--head feature/tax"],
          "stdout" => [pr(42, "feature/tax", "OPEN", false)]
        }
      ])

    # No client is in front: nothing wants the checkout's status.
    context = context |> shared_answers() |> show(false)
    Map.put(context, :asked_before, asked(context, "feature/tax"))
  end

  step "a thread's turn ends in {string}", %{args: [title]} = context do
    assert World.project(context, title).root == context.cwd
    context = World.run_turn(context, context.thread_title, "write notes.md")
    # The watcher has handled the turn's end once it answers.
    _ = :sys.get_state(watcher(context))
    context
  end

  step "the host is not asked about the pull request", context do
    assert asked(context, "feature/tax") == context.asked_before
    context
  end

  # --- a slow pull request lookup --------------------------------------------------------------------------

  step "the host is slow to answer the pull request lookup for {string}",
       %{args: [branch]} = context do
    git(context, ["checkout", "-q", "-b", branch])
    context = context |> shared_answers() |> show(true)

    World.cli_rules(context, [
      %{
        "args" => ["pr list", "--head #{branch}"],
        "sleep" => 2,
        "stdout" => [pr(42, branch, "OPEN", false)]
      }
    ])
  end

  step "the user changes {string} while the lookup is still waiting", %{args: [path]} = context do
    HalC2.Vcs.Watch.turn_ended(context.cwd)
    %{lookup: {_ref, _again, pid}} = :sys.get_state(watcher(context))
    File.mkdir_p!(Path.dirname(Path.join(context.cwd, path)))
    File.write!(Path.join(context.cwd, path), "export const cart = 1\n")
    HalC2.Vcs.Watch.refresh(context.cwd)
    Map.put(context, :lookup_pid, pid)
  end

  step "the status shows the change to {string} before the lookup answers",
       %{args: [path]} = context do
    {event, context} =
      World.await_vcs(context, fn event ->
        event["_tag"] == "localUpdated" and
          Enum.any?(event["local"]["workingTree"]["files"], &(&1["path"] == path))
      end)

    assert event["local"]["hasWorkingTreeChanges"]
    # The lookup is still waiting on the host.
    assert Process.alive?(context.lookup_pid)
    down = Process.monitor(context.lookup_pid)
    assert_receive {:DOWN, ^down, :process, _, _}, 10_000
    context
  end
end
