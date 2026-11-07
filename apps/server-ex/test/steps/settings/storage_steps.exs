defmodule HalC2.Steps.Settings.Storage do
  @moduledoc """
  Steps for `features/settings/storage.feature`: the MC's storage sweep
  (`HalC2.StorageCleanup`) against real worktrees of the scenario's project. Merged
  pull requests come from the fake `gh` (`test/support/fake_gh.py`); the
  project gets an `origin` on "github.com" so the MC asks it.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  @fake_gh Path.expand("../../support/fake_gh.py", __DIR__)

  # --- rules -------------------------------------------------------------------------

  step ~r/^the user turned on deleting (?<rule>worktrees of deleted threads|worktrees idle for \d+ days|worktrees of threads settled for \d+ days|merged worktrees|unchanged worktrees)(?: only)?$/,
       %{args: [rule]} = context do
    rules =
      case rule do
        "worktrees of deleted threads" ->
          %{"worktreeOnDelete" => true}

        "worktrees of threads settled for " <> days ->
          %{
            "worktreeSettledAfterDays" =>
              days |> String.trim_trailing(" days") |> String.to_integer()
          }

        "merged worktrees" ->
          %{"worktreeOnMerge" => true}

        "unchanged worktrees" ->
          %{"worktreeUnchanged" => true}

        "worktrees idle for " <> days ->
          %{"worktreeAfterDays" => days |> String.trim_trailing(" days") |> String.to_integer()}
      end

    World.update_settings(context, %{"storageCleanup" => rules})
  end

  step ~r/^the user turned on deleting (?<files>browser captures|rotated logs) after (?<days>\d+) days$/,
       %{args: [files, days]} = context do
    days = String.to_integer(days)

    case files do
      "browser captures" ->
        World.update_settings(context, %{
          "storageCleanup" => %{"browserArtifactsAfterDays" => days}
        })

      "rotated logs" ->
        # An MC that has run a while has rotated logs, some of them old.
        context
        |> World.update_settings(%{"storageCleanup" => %{"logsAfterDays" => days}})
        |> Map.put(:logs, logs(context, days))
    end
  end

  # --- worktrees ---------------------------------------------------------------------

  step "a thread's worktree has a merged pull request", context do
    merged_worktree(context, "merged work")
  end

  step "a thread's worktree has no commits beyond the default branch", context do
    context
    |> origin()
    |> World.worktree_thread("unchanged work")
  end

  step ~r/^an idle thread's worktree (?<condition>has uncommitted changes|has an open terminal|is shared with another thread|is checked out on a different branch|holds ignored files besides node_modules)$/,
       %{args: [condition]} = context do
    context = idle_worktree(context, "idle work")
    %{path: path, branch: branch} = context.worktree

    case condition do
      "has uncommitted changes" ->
        File.write!(Path.join(path, "README.md"), "changed\n")

      "has an open terminal" ->
        World.open_terminal(World.thread_id(context, "idle work"), path)

      "is shared with another thread" ->
        World.worktree_thread(context, "sharing work", nil, %{
          "branch" => branch,
          "worktreePath" => path,
          "createdAt" => World.iso_from_now(-World.days(9))
        })

      "is checked out on a different branch" ->
        World.git!(path, ~w(checkout -q -b other))

      "holds ignored files besides node_modules" ->
        File.write!(Path.join(path, ".gitignore"), ".env\nnode_modules/\n")
        World.git!(path, ~w(add .gitignore))
        World.git!(path, ~w(commit -q -m ignore))
        File.mkdir_p!(Path.join(path, "node_modules/left-pad"))
        File.write!(Path.join(path, ".env"), "SECRET=1\n")
    end

    context
  end

  step "the thread keeps its branch so it can be checked out again", context do
    %{thread: title, path: path, branch: branch, root: root} = context.worktree
    thread = World.thread(context, title)
    assert thread["branch"] == branch
    assert thread["worktreePath"] == path

    assert {:ok, %{"worktree" => %{"path" => ^path}}} =
             HalC2.Vcs.create_worktree(%{"cwd" => root, "refName" => branch, "path" => path})

    assert World.git!(path, ~w(rev-parse --abbrev-ref HEAD)) == branch
    context
  end

  # --- a thread that becomes active mid-sweep ----------------------------------------

  step "a worktree about to be removed as idle", context do
    context
    |> World.update_settings(%{"storageCleanup" => %{"worktreeAfterDays" => 8}})
    |> idle_worktree("idle work")
  end

  # The sweep asks the terminal hub whether anything runs in the worktree before
  # its git checks; the scenario stands in for the hub and lets the user's
  # message land while the sweep waits on that answer.
  step "the user sends a message in its thread before removal", context do
    context = World.start_storage_cleanup(context)
    refute Process.whereis(HalC2.Terminal.Hub), "a real terminal hub is running"
    Process.register(self(), HalC2.Terminal.Hub)
    cleanup = Process.whereis(HalC2.StorageCleanup)
    task = Task.async(fn -> HalC2.StorageCleanup.sweep() end)

    send_message = fn ->
      World.add_message(context, "idle work", "user", "One more thing")
    end

    try do
      assert hub(task, cleanup, send_message, false), "the sweep never checked the worktree"
    after
      Process.unregister(HalC2.Terminal.Hub)
    end

    assert World.row(context, "idle work")["latestUserMessageAt"]
    context
  end

  defp hub(task, cleanup, send_message, sent?) do
    receive do
      {:"$gen_call", {pid, _} = from, :summaries} ->
        sent? = sent? or (pid == cleanup and (send_message.() && true))
        GenServer.reply(from, [])
        hub(task, cleanup, send_message, sent?)

      {ref, :ok} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        sent?
    after
      30_000 -> flunk("the sweep did not finish")
    end
  end

  # --- defaults and changes ----------------------------------------------------------

  # Worktrees and files every rule would remove, on an MC whose settings were
  # never touched.
  step "a fresh MC", context do
    context = origin(context)

    {context, worktrees} =
      Enum.reduce(
        [
          &deleted_worktree(&1, "deleted work"),
          &World.worktree_thread(&1, "unchanged work"),
          &idle_worktree(&1, "idle work", 400),
          &merged_worktree(&1, "merged work")
        ],
        {context, []},
        fn make, {context, paths} ->
          context = make.(context)
          {context, [context.worktree.path | paths]}
        end
      )

    files = [capture(context, 400) | logs(context, 1).old]
    Map.put(context, :removables, worktrees ++ files)
  end

  step "nothing is removed", context do
    rules = HalC2.StorageCleanup.rules(HalC2.Settings.settings(), World.project(context).id)
    assert Enum.all?(rules, fn {_rule, on} -> on in [nil, false] end)

    assert get_in(HalC2.Settings.settings(), ["storageCleanup", "browserArtifactsAfterDays"]) ==
             nil

    assert get_in(HalC2.Settings.settings(), ["storageCleanup", "logsAfterDays"]) == nil

    for path <- context.removables, do: assert(File.exists?(path), "#{path} was removed")
    context
  end

  step "an old worktree that no rule covers", context do
    context = context |> idle_worktree("idle work", 30) |> World.sweep_storage()
    assert File.dir?(context.worktree.path)
    context
  end

  step "the user turns on a rule that covers it", context do
    {{:ok, read}, context} = World.call(context, "hal-c2.readSettings")

    settings =
      World.deep_merge(read["settings"], %{"storageCleanup" => %{"worktreeAfterDays" => 7}})

    {reply, context} =
      World.call(context, "hal-c2.writeSettings", %{
        "settings" => settings,
        "version" => read["version"]
      })

    assert {:ok, _} = reply
    context
  end

  # No hourly tick is scheduled in scenarios (`World.start_storage_cleanup/1`), so
  # the removal can only come from the settings change.
  step "the MC sweeps without waiting for the next hour", context do
    assert Application.get_env(:hal_c2, :storage_cleanup_first_ms) == nil
    _ = :sys.get_state(HalC2.StorageCleanup)
    refute File.exists?(context.worktree.path)
    context
  end

  # --- project overrides -------------------------------------------------------------

  step "worktree cleanup is off for the environment", context do
    off = %{
      "worktreeAfterDays" => nil,
      "worktreeOnMerge" => false,
      "worktreeOnDelete" => false,
      "worktreeUnchanged" => false
    }

    context =
      context
      |> World.update_settings(%{"storageCleanup" => off})
      |> World.create_project("web")
      |> merged_worktree("api work", "api")

    api = context.worktree.path
    context = merged_worktree(context, "web work", "web")
    Map.put(context, :merged, %{"api" => api, "web" => context.worktree.path})
  end

  step "project {string} turns on deleting merged worktrees", %{args: [project]} = context do
    id = World.project(context, project).id
    rules = %{"mode" => "custom", "rules" => %{"worktreeOnMerge" => true}}

    World.update_settings(context, %{
      "projectSettingsOverrides" => %{id => %{"worktreeCleanup" => rules}}
    })
  end

  step "merged worktrees in {string} are removed", %{args: [project]} = context do
    refute File.exists?(context.merged[project])
    context
  end

  step "merged worktrees in other projects are kept", context do
    others = Map.drop(context.merged, ["api"])
    assert others != %{}
    for {_project, path} <- others, do: assert(File.dir?(path), "#{path} was removed")
    context
  end

  # --- browser captures and logs -----------------------------------------------------

  step "a capture from {int} days ago", %{args: [days]} = context do
    capture = capture(context, days)
    recent = capture(context, 1)

    {{:ok, %{"relativeUrl" => url}}, context} =
      World.call(context, "assets.createUrl", %{
        "resource" => %{"_tag" => "media-file", "threadId" => "thread-1", "path" => capture}
      })

    assert get(context, url) == 200
    Map.put(context, :capture, %{path: capture, recent: recent, url: url})
  end

  step "the capture is deleted", context do
    refute File.exists?(context.capture.path)
    assert File.exists?(context.capture.recent), "a newer capture was deleted too"
    context
  end

  step "its old link no longer opens", context do
    assert get(context, context.capture.url) == 404
    context
  end

  step "rotated logs older than {int} days are deleted", %{args: [_days]} = context do
    for path <- context.logs.old, do: refute(File.exists?(path), "#{path} was kept")
    assert File.exists?(context.logs.recent), "a newer rotated log was deleted"
    context
  end

  step "the current logs are kept", context do
    for path <- context.logs.current, do: assert(File.exists?(path), "#{path} was deleted")
    context
  end

  # --- settled threads ---------------------------------------------------------------

  step "a thread settles and the MC sweeps storage within a minute", context do
    context
    |> World.worktree_thread("settled work")
    |> World.patch_thread("settled work", %{"settledAt" => World.iso_from_now(0)})
    |> World.sweep_storage()
  end

  step "the worktree is kept so the project's settle script can run in it", context do
    assert File.dir?(context.worktree.path)
    assert kept_reason(context) == "Settled moments ago"
    context
  end

  step "the next sweep after that minute removes it", context do
    past = World.iso_from_now(-61_000)

    context =
      context
      |> World.patch_thread("settled work", %{"settledAt" => past, "createdAt" => past})
      |> World.sweep_storage()

    refute File.exists?(context.worktree.path)
    assert outcome(context)["reason"] == "Settled for 0 days"
    context
  end

  step "a thread was settled 3 days ago and its session has stopped", context do
    three_days_ago = World.iso_from_now(-World.days(3))

    context =
      context
      |> World.fake_codex()
      |> idle_worktree("settled work", 3)
      |> World.add_message("settled work", "user", "Fix the login bug", three_days_ago)
      |> World.add_message("settled work", "assistant", "Fixed it.", three_days_ago)
      |> World.patch_thread("settled work", %{"settledAt" => three_days_ago})

    assert Registry.count(HalC2.Codex.Registry) == 0
    context
  end

  step "the thread keeps its branch and its history", context do
    %{path: path, branch: branch} = context.worktree
    thread = World.thread(context, "settled work")
    assert thread["branch"] == branch
    assert thread["worktreePath"] == path

    id = World.thread_id(context, "settled work")

    texts =
      HalC2.Streams.ensure(id)
      |> HalC2.Streams.Server.state()
      |> HalC2.StreamState.list("message")
      |> Enum.map(& &1["text"])

    assert "Fix the login bug" in texts and "Fixed it." in texts
    context
  end

  step "the user sends the thread a new message", context do
    context = World.socket_message(context, "settled work", "One more thing")
    World.await_run(context, "settled work", &(&1["status"] == "completed"))
    context
  end

  step "its worktree is checked out again from the branch", context do
    %{path: path, branch: branch} = context.worktree
    assert File.dir?(path)
    assert World.git!(path, ~w(rev-parse --abbrev-ref HEAD)) == branch
    assert World.thread(context, "settled work")["worktreePath"] == path
    context
  end

  # --- the last look before removal --------------------------------------------------

  step "a worktree about to be removed is being measured", context do
    context =
      context
      |> World.update_settings(%{"storageCleanup" => %{"worktreeAfterDays" => 8}})
      |> idle_worktree("idle work")

    thread = World.thread_id(context, "idle work")
    World.put_app_env(:storage_cleanup_hook, {__MODULE__, :start_turn_at, [self(), thread]})
    context
  end

  step "its thread starts a turn before the measuring ends", context do
    context = World.sweep_storage(context)
    assert_received {:turn_started, :measuring}
    assert World.row(context, "idle work")["activeRunId"]
    assert kept_reason(context) == "Thread activity or shared worktree changed since check"
    context
  end

  @doc false
  # The sweep's `:measuring` stage: the thread's turn starts, its row committed before
  # the sweep goes on.
  def start_turn_at(test, thread, stage, _path) do
    if stage == :measuring do
      {id, run} = run(thread, "running", World.iso_from_now(0))
      {:ok, _} = HalC2.Streams.commit(thread, :thread, [{"run", id, %{"s" => run}}])
      :ok = HalC2.Streams.flush_shell(thread)
      send(test, {:turn_started, stage})
    end

    :ok
  end

  # The sweep is held where it is about to remove the folder, holding its lease, while
  # the terminal asks for that lease; the trace on the lease server is the receipt that
  # the terminal is waiting before the sweep goes on.
  step ~r/^a terminal is (?<action>opened|restarted) in that worktree while the sweep is removing it$/,
       %{args: [action]} = context do
    context = World.start_storage_cleanup(context)
    World.start_terminals()
    %{path: path, root: root} = context.worktree
    thread = World.thread_id(context, "idle work")

    # A terminal restarted into the worktree was running elsewhere (in the project).
    if action == "restarted", do: World.open_terminal(thread, root)

    input = %{"threadId" => thread, "terminalId" => "term-1", "cwd" => path}
    World.put_app_env(:storage_cleanup_hook, {__MODULE__, :pause_at, [self(), :removing]})
    sweep = Task.async(fn -> HalC2.StorageCleanup.sweep() end)

    paused =
      receive do
        {:paused, :removing, pid} -> pid
      after
        30_000 -> flunk("the sweep never came to removing the worktree")
      end

    lease = Process.whereis(HalC2.WorkspaceLease)
    :erlang.trace(lease, true, [:receive])
    start = if action == "opened", do: :open, else: :restart
    terminal = Task.async(fn -> apply(HalC2.Terminal, start, [input]) end)
    terminal_pid = terminal.pid

    receive do
      {:trace, ^lease, :receive, {:"$gen_call", {^terminal_pid, _}, {:acquire, _}}} -> :ok
    after
      10_000 -> flunk("the terminal never asked for the worktree's lease")
    end

    :erlang.trace(lease, false, [:receive])
    assert HalC2.WorkspaceLease.held() == [real(path)]
    assert Task.yield(terminal, 0) == nil, "the terminal started while the sweep held the folder"
    send(paused, :go)
    assert :ok = Task.await(sweep, 30_000)
    Map.put(context, :terminal_start, Task.await(terminal, 30_000))
  end

  @doc false
  def pause_at(test, wanted, stage, _path) do
    if stage == wanted do
      send(test, {:paused, stage, self()})

      receive do
        :go -> :ok
      after
        30_000 -> :ok
      end
    end

    :ok
  end

  step "the sweep and the terminal's start run one after the other", context do
    refute File.exists?(context.worktree.path), "the sweep did not remove the worktree"
    assert {:error, %{"_tag" => "TerminalCwdNotFoundError"}} = context.terminal_start
    context
  end

  step "the terminal is never started inside a folder that is being deleted", context do
    path = context.worktree.path

    refute Enum.any?(HalC2.Terminal.Hub.summaries(), fn t ->
             t["status"] in ["starting", "running"] and
               String.starts_with?(Path.expand(t["cwd"] || "/") <> "/", path <> "/")
           end)

    context
  end

  # --- deleted threads ---------------------------------------------------------------

  step "a thread was deleted and its cleanup steps have not all finished", context do
    HalC2.Test.Mc.ensure(HalC2.Orchestration.Effects)
    context = World.worktree_thread(context, "deleted work")
    id = World.thread_id(context, "deleted work")
    World.put_app_env(:effects_hook, {__MODULE__, :hold_effect, [self(), id, "terminal.cleanup"]})
    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})
    World.await_row(id, & &1["deletedAt"])

    held =
      receive do
        {:effect_held, effect, pid} -> {effect, pid}
      after
        10_000 -> flunk("the deletion's terminal cleanup never ran")
      end

    Map.put(context, :held_effect, held)
  end

  @doc false
  def hold_effect(test, thread, type, :execute, %{"threadId" => thread, "type" => type} = record) do
    id = record["id"]
    send(test, {:effect_held, id, self()})

    receive do
      {:release_effect, ^id} -> :ok
    after
      30_000 -> :ok
    end
  end

  def hold_effect(_test, _thread, _type, _stage, _record), do: :ok

  step "its worktree is kept", context do
    assert File.dir?(context.worktree.path)
    assert kept_reason(context) == "Thread deletion is still pending"
    context
  end

  step "the cleanup steps have finished and the MC sweeps storage again", context do
    {effect, pid} = context.held_effect
    send(pid, {:release_effect, effect})
    id = World.thread_id(context, "deleted work")
    :ok = HalC2.Orchestration.Effects.drain(id)

    assert Enum.all?(
             HalC2.Orchestration.Effects.effects(id),
             &(&1["status"] in ["succeeded", "cancelled"])
           )

    World.sweep_storage(context)
  end

  step "a deleted thread's worktree is set not to show untracked files in its status",
       context do
    context = deleted_worktree(context, "deleted work")
    World.git!(context.worktree.path, ~w(config status.showUntrackedFiles no))
    assert World.git!(context.worktree.path, ~w(status --porcelain)) == ""
    context
  end

  step "it holds an untracked file {string}", %{args: [name]} = context do
    File.write!(Path.join(context.worktree.path, name), "mine\n")
    assert World.git!(context.worktree.path, ~w(status --porcelain)) == ""
    Map.put(context, :untracked, name)
  end

  step "the worktree is kept with {string}", %{args: [name]} = context do
    assert File.read!(Path.join(context.worktree.path, name)) == "mine\n"
    assert kept_reason(context) == "Has uncommitted changes (1 file)"
    context
  end

  # --- what the default branch has -----------------------------------------------------

  step "a thread's worktree has commits the default branch does not have", context do
    context |> origin() |> World.worktree_thread("branch work") |> commit("feature.txt")
  end

  step "a thread's worktree on branch {string} has commits the default branch does not have",
       %{args: [branch]} = context do
    context
    |> origin()
    |> World.worktree_thread("#{branch} work", nil, %{"branch" => branch})
    |> commit("feature.txt")
  end

  step "no merged pull request covers them", context do
    gh_rule(context, %{"args" => ["pr list", context.worktree.branch], "stdout" => []})
  end

  step ~r/^GitHub says pull request (?<number>\d+) from "(?<branch>[^"]+)" was squash merged (?<detail>.+)$/,
       %{args: [number, branch, detail]} = context do
    head = World.git!(context.worktree.path, ~w(rev-parse HEAD))
    base = if detail =~ "release branch", do: "release", else: "main"
    context = gh_rule(context, merged_pr(context, String.to_integer(number), branch, base, head))

    if detail =~ "later commit",
      do: commit(context, "later.txt"),
      else: context
  end

  step "a thread's worktree whose pull request was squash merged at its current head", context do
    context =
      context |> origin() |> World.worktree_thread("squashed work") |> commit("feature.txt")

    %{path: path, branch: branch} = context.worktree
    head = World.git!(path, ~w(rev-parse HEAD))
    gh_rule(context, merged_pr(context, 7, branch, "main", head))
  end

  step "its pull request was not read", context do
    calls =
      case File.read(Path.join(context.mc.home, "gh.log")) do
        {:ok, log} -> log |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
        {:error, :enoent} -> []
      end

    refute Enum.any?(calls, &(Enum.join(&1["args"], " ") =~ "pr list")),
           "the sweep asked for the pull request: #{inspect(calls)}"

    context
  end

  # An origin whose default is "trunk", pushed to and never fetched from, so the
  # checkout has no `origin/HEAD`.
  step "the repository's remote was added by hand, so the checkout does not record its default branch",
       context do
    context = World.worktree_thread(context, "trunk work")
    %{id: id, root: root} = World.project(context)
    origin = Path.join([context.mc.home, "github.com", "acme", "#{id}.git"])
    File.mkdir_p!(Path.dirname(origin))
    World.git!(context.mc.home, ["init", "-q", "--bare", "-b", "trunk", origin])
    World.git!(root, ["remote", "add", "origin", origin])
    World.git!(root, ~w(push -q origin main:trunk))
    assert {_, code} = System.cmd("git", ~w(symbolic-ref -q refs/remotes/origin/HEAD), cd: root)
    assert code != 0
    commit(context, "feature.txt")
  end

  step ~r/^the remote says its default is "trunk" and the worktree's commits are (?<where>on "trunk"|only on "main")$/,
       %{args: [where]} = context do
    %{path: path, branch: branch} = context.worktree
    target = if where == ~s(on "trunk"), do: "trunk", else: "main"
    World.git!(path, ["push", "-q", "origin", "#{branch}:#{target}"])
    head = World.git!(path, ~w(rev-parse HEAD))
    context = gh_rule(context, merged_pr(context, 9, branch, target, head))
    if target == "main", do: Map.put(context, :expected_reason, "Not merged"), else: context
  end

  # Its commits are on a "main" the remote has, which a guess at the default would
  # take as merged.
  step "the remote cannot be asked for its default branch", context do
    %{path: path, branch: branch, root: root} = context.worktree
    World.git!(path, ["push", "-q", "origin", "#{branch}:main"])
    head = World.git!(path, ~w(rev-parse HEAD))
    missing = Path.join([context.mc.home, "github.com", "acme", "missing.git"])
    World.git!(root, ["remote", "set-url", "origin", missing])
    context = gh_rule(context, merged_pr(context, 9, branch, "main", head))
    Map.put(context, :expected_reason, "Default branch is unavailable")
  end

  # --- statuses ------------------------------------------------------------------------

  step ~r/^a thread whose last turn (?<ended>completed|was interrupted|failed|was cancelled|was rolled back) has been idle for 9 days with no pending work$/,
       %{args: [ended]} = context do
    status =
      Map.fetch!(
        %{
          "completed" => "completed",
          "was interrupted" => "interrupted",
          "failed" => "failed",
          "was cancelled" => "cancelled",
          "was rolled back" => "rolled_back"
        },
        ended
      )

    context = idle_worktree(context, "idle work")
    context = World.add_run(context, "idle work", status, World.iso_from_now(-World.days(9)))
    row = World.row(context, "idle work")
    assert row["status"] == status and row["activeRunId"] == nil
    context
  end

  # --- shared worktrees ----------------------------------------------------------------

  step "a thread and a subagent it delegated to share its worktree", context do
    context |> idle_worktree("parent work") |> share("subagent work", "subagent")
  end

  step "a thread and two subagents it delegated to share its worktree on its branch", context do
    context
    |> idle_worktree("parent work")
    |> share("first subagent", "subagent")
    |> share("second subagent", "subagent", "first subagent")
  end

  step "all three have been idle for 9 days with no pending work", context do
    for title <- ["parent work", "first subagent", "second subagent"],
        do: assert(World.row(context, title)["status"] == "idle")

    context
  end

  step ~r/^(?<condition>the subagent is on another branch|the subagent has no branch|a forked thread also works in the worktree|an unrelated thread also works in the worktree)$/,
       %{args: [condition]} = context do
    case condition do
      "the subagent is on another branch" ->
        World.patch_thread(context, "subagent work", %{"branch" => "other"})

      "the subagent has no branch" ->
        World.patch_thread(context, "subagent work", %{"branch" => nil})

      "a forked thread also works in the worktree" ->
        share(context, "forked work", "fork")

      "an unrelated thread also works in the worktree" ->
        share(context, "unrelated work", nil)
    end
  end

  step "the worktree is kept with the reason {string}", %{args: [reason]} = context do
    assert File.dir?(context.worktree.path)
    assert kept_reason(context) == reason
    context
  end

  step "a thread idle for 9 days shares its worktree with a subagent that worked 2 days ago",
       context do
    context
    |> idle_worktree("parent work")
    |> share("subagent work", "subagent")
    |> World.add_message(
      "subagent work",
      "user",
      "Keep going",
      World.iso_from_now(-World.days(2))
    )
    |> Map.put(:expected_reason, "Inactive for 2 of 8 days")
  end

  # The archived thread's worktree goes; the one it shares with a thread that has
  # changes in it is checked by the sweep too (`a worktree an archived thread shares…`).
  step "an archived thread's worktree has been idle for 9 days with nothing to lose", context do
    context =
      context
      |> idle_worktree("archived sharing")
      |> World.patch_thread("archived sharing", %{"archivedAt" => World.iso_from_now(0)})
      |> share("changing work", nil)

    File.write!(Path.join(context.worktree.path, "README.md"), "changed\n")
    shared = context.worktree.path

    context
    |> idle_worktree("archived work")
    |> World.patch_thread("archived work", %{"archivedAt" => World.iso_from_now(0)})
    |> Map.put(:shared_with_archived, shared)
  end

  step "a worktree an archived thread shares with one that could lose work is kept", context do
    path = context.shared_with_archived
    assert File.read!(Path.join(path, "README.md")) == "changed\n"
    entry = Enum.find(HalC2.StorageCleanup.report(), &(&1["path"] == Path.expand(path)))
    assert %{"outcome" => "kept", "reason" => "Shared by 2 threads"} = entry
    context
  end

  # --- submodules ----------------------------------------------------------------------

  step "an idle thread's worktree has initialized submodules with nothing to lose", context do
    context |> idle_worktree("idle work") |> submodule()
  end

  step "an idle thread's worktree has a submodule with a commit not pushed anywhere", context do
    context = context |> idle_worktree("idle work") |> submodule()
    %{path: path} = context.worktree
    lib = Path.join(path, "lib")
    File.write!(Path.join(lib, "local.txt"), "unpublished\n")
    World.git!(lib, ~w(add local.txt))
    World.git!(lib, ~w(-c user.email=hal-c2@example.com -c user.name=HAL-C2 commit -q -m local))
    World.git!(path, ~w(add lib))
    World.git!(path, ~w(commit -q -m bump))

    Map.put(
      context,
      :expected_reason,
      "Submodule has commits not on a remote-tracking ref"
    )
  end

  # --- browser captures through links --------------------------------------------------

  step "the captures folder holds a symbolic link to an old file elsewhere", context do
    old = System.os_time(:second) - 400 * 86_400
    target = Path.join([context.mc.home, "elsewhere", "kept.png"])
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, "mine\n")
    File.touch!(target, old)
    dir = Path.join(context.mc.home, "browser-artifacts")
    File.mkdir_p!(dir)
    link = Path.join(dir, "browser-screenshot-link.png")
    File.ln_s!(target, link)
    {_, 0} = System.cmd("touch", ["-h", "-d", "@#{old}", link])
    Map.put(context, :link, %{target: target, path: link, mtime: File.stat!(target).mtime})
  end

  step "the file the link points to is untouched", context do
    %{target: target, mtime: mtime} = context.link
    assert File.read!(target) == "mine\n"
    assert File.stat!(target).mtime == mtime
    context
  end

  step "the link is left in place", context do
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(context.link.path)
    assert File.read_link!(context.link.path) == context.link.target
    context
  end

  # --- helpers -----------------------------------------------------------------------

  # The last sweep's result for the scenario's worktree, and why it kept it.
  defp outcome(context) do
    path = Path.expand(context.worktree.path)
    report = HalC2.StorageCleanup.report() || []

    Enum.find(report, &(&1["path"] == path)) ||
      flunk("the last sweep did not report #{path}: #{inspect(report)}")
  end

  defp kept_reason(context) do
    entry = outcome(context)
    assert entry["outcome"] == "kept", "the worktree was not kept: #{inspect(entry)}"
    entry["reason"]
  end

  defp commit(context, file) do
    path = context.worktree.path
    File.write!(Path.join(path, file), "#{file}\n")
    World.git!(path, ["add", file])
    World.git!(path, ["commit", "-q", "-m", file])
    context
  end

  # A fake `gh` rule answering the branch's pull request: merged into `base` from `head`.
  defp merged_pr(context, number, branch, base, head) do
    pr = %{
      "number" => number,
      "title" => branch,
      "url" => "https://github.com/acme/#{World.project(context).id}/pull/#{number}",
      "baseRefName" => base,
      "headRefName" => branch,
      "headRefOid" => head,
      "state" => "MERGED",
      "isDraft" => false,
      "updatedAt" => World.iso_from_now(0),
      "mergedAt" => World.iso_from_now(0)
    }

    %{"args" => ["pr list", branch], "stdout" => [pr]}
  end

  # Another thread, idle as long, in the scenario's worktree on its branch: under
  # `parent` as `relationship` ("subagent", "fork"), or unrelated with none.
  defp share(context, title, relationship, parent \\ "parent work") do
    %{path: path, branch: branch} = worktree = context.worktree

    context =
      context
      |> World.worktree_thread(title, nil, %{"branch" => branch, "worktreePath" => path})
      |> World.patch_thread(title, %{"createdAt" => World.iso_from_now(-World.days(9))})

    context =
      if relationship do
        parent_id = World.thread_id(context, parent)
        root = get_in(World.thread(context, parent), ["lineage", "rootThreadId"]) || parent_id

        World.patch_thread(context, title, %{
          "lineage" => %{
            "parentThreadId" => parent_id,
            "relationshipToParent" => relationship,
            "rootThreadId" => root
          }
        })
      else
        context
      end

    Map.put(context, :worktree, worktree)
  end

  # A submodule cloned from a repository of its own and committed in the worktree.
  defp submodule(context) do
    lib = World.git_repo(context, "lib-#{System.unique_integer([:positive])}")
    path = context.worktree.path

    World.git!(path, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "--quiet",
      "add",
      lib,
      "lib"
    ])

    World.git!(path, ~w(commit -q -m submodule))
    assert File.exists?(Path.join(path, "lib/README.md"))
    context
  end

  defp run(thread, status, at) do
    id = "run-#{System.unique_integer([:positive])}"

    {id,
     %{
       "id" => id,
       "threadId" => thread,
       "ordinal" => System.unique_integer([:positive, :monotonic]),
       "providerInstanceId" => "codex",
       "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
       "providerThreadId" => nil,
       "userMessageId" => nil,
       "rootNodeId" => nil,
       "activeAttemptId" => nil,
       "status" => status,
       "queuePosition" => nil,
       "requestedAt" => at,
       "startedAt" => at,
       "completedAt" => nil,
       "checkpointId" => nil,
       "contextHandoffId" => nil
     }}
  end

  defp real(path) do
    {:ok, real} = HalC2.Paths.real(path)
    real
  end

  defp deleted_worktree(context, title) do
    context = World.worktree_thread(context, title)
    id = World.thread_id(context, title)
    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})
    World.await_row(id, & &1["deletedAt"])
    :ok = HalC2.Orchestration.Effects.drain(id)
    context
  end

  defp idle_worktree(context, title, days \\ 9) do
    context
    |> World.worktree_thread(title)
    |> World.patch_thread(title, %{"createdAt" => World.iso_from_now(-World.days(days))})
  end

  # A worktree whose branch was merged into `main` on origin through a pull request.
  defp merged_worktree(context, title, project \\ nil) do
    context = context |> origin(project) |> World.worktree_thread(title, project)
    %{path: path, branch: branch} = context.worktree
    File.write!(Path.join(path, "feature.txt"), "#{title}\n")
    World.git!(path, ~w(add feature.txt))
    World.git!(path, ["commit", "-q", "-m", title])
    World.git!(path, ["push", "-q", "origin", "#{branch}:main"])

    pr = %{
      "number" => System.unique_integer([:positive]),
      "title" => title,
      "url" => "https://github.com/acme/#{World.project(context, project).id}/pull/1",
      "baseRefName" => "main",
      "headRefName" => branch,
      "state" => "MERGED",
      "isDraft" => false,
      "updatedAt" => World.iso_from_now(0)
    }

    gh_rule(context, %{"args" => ["pr list", branch], "stdout" => [pr]})
  end

  defp origin(context, project \\ nil) do
    id = World.project(context, project).id

    if id in (context[:origins] || []),
      do: context,
      else:
        context
        |> World.github_origin(project)
        |> Map.update(:origins, [id], &[id | &1])
  end

  # Adds a rule to the fake `gh`, installing it on first use.
  defp gh_rule(context, rule) do
    rules_path = Path.join(context.mc.home, "gh-rules.json")

    unless context[:gh_rules] do
      World.put_app_env(:gh_command, @fake_gh)
      World.put_env("FAKE_GH_RULES", rules_path)
      World.put_env("FAKE_GH_LOG", Path.join(context.mc.home, "gh.log"))
    end

    rules = (context[:gh_rules] || []) ++ [rule]
    File.write!(rules_path, JSON.encode!(rules))
    Map.put(context, :gh_rules, rules)
  end

  defp capture(context, days_ago) do
    dir = Path.join(context.mc.home, "browser-artifacts")
    File.mkdir_p!(dir)
    path = Path.join(dir, "browser-screenshot-#{System.unique_integer([:positive])}.png")
    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>>)
    File.touch!(path, System.os_time(:second) - days_ago * 86_400)
    path
  end

  # The MC's logs: rotated ones older than `days`, a rotated one newer than
  # that, and the current files (as old as the oldest, so only rotation spares them).
  defp logs(context, days) do
    dir = Path.join(context.mc.home, "logs")
    old_at = System.os_time(:second) - (days + 10) * 86_400
    write = fn name, at -> write_log(Path.join(dir, name), at) end

    %{
      old: [
        write.("server.log.1", old_at),
        write.("server.trace.ndjson.1", old_at),
        write.("provider/codex.log.3", old_at)
      ],
      recent: write.("server.log.2", System.os_time(:second) - 86_400),
      current: [
        write.("server.log", old_at),
        write.("server.trace.ndjson", old_at),
        write.("provider/codex.log", old_at)
      ]
    }
  end

  defp write_log(path, at) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "log\n")
    File.touch!(path, at)
    path
  end

  defp get(context, url) do
    Application.ensure_all_started(:inets)
    target = ~c"http://127.0.0.1:#{context.mc.port}#{url}"
    {:ok, {{_, status, _}, _, _}} = :httpc.request(:get, {target, []}, [], [])
    status
  end
end
