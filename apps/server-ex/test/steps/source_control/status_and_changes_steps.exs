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
end
