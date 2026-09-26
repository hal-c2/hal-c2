defmodule HalC2.Steps.Settings.Storage do
  @moduledoc """
  Steps for `features/settings/storage.feature`: the node's storage sweep
  (`HalC2.StorageCleanup`) against real worktrees of the scenario's project. Merged
  pull requests come from the fake `gh` (`test/support/fake_gh.py`); the
  project gets an `origin` on "github.com" so the node asks it.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Node.World

  @fake_gh Path.expand("../../support/fake_gh.py", __DIR__)

  # --- rules -------------------------------------------------------------------------

  step ~r/^the user turned on deleting (?<rule>worktrees of deleted threads|worktrees idle for \d+ days|merged worktrees|unchanged worktrees)$/,
       %{args: [rule]} = context do
    rules =
      case rule do
        "worktrees of deleted threads" ->
          %{"worktreeOnDelete" => true}

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
        # A node that has run a while has rotated logs, some of them old.
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

  # Worktrees and files every rule would remove, on a node whose settings were
  # never touched.
  step "a fresh node", context do
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
    {{:ok, read}, context} = World.call(context, "halc2.readSettings")

    settings =
      World.deep_merge(read["settings"], %{"storageCleanup" => %{"worktreeAfterDays" => 7}})

    {reply, context} =
      World.call(context, "halc2.writeSettings", %{
        "settings" => settings,
        "version" => read["version"]
      })

    assert {:ok, _} = reply
    context
  end

  # No hourly tick is scheduled in scenarios (`World.start_storage_cleanup/1`), so
  # the removal can only come from the settings change.
  step "the node sweeps without waiting for the next hour", context do
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

  # --- helpers -----------------------------------------------------------------------

  defp deleted_worktree(context, title) do
    context = World.worktree_thread(context, title)
    id = World.thread_id(context, title)
    {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})
    World.await_row(id, & &1["deletedAt"])
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
    rules_path = Path.join(context.node.home, "gh-rules.json")

    unless context[:gh_rules] do
      World.put_app_env(:gh_command, @fake_gh)
      World.put_env("FAKE_GH_RULES", rules_path)
      World.put_env("FAKE_GH_LOG", Path.join(context.node.home, "gh.log"))
    end

    rules = (context[:gh_rules] || []) ++ [rule]
    File.write!(rules_path, JSON.encode!(rules))
    Map.put(context, :gh_rules, rules)
  end

  defp capture(context, days_ago) do
    dir = Path.join(context.node.home, "browser-artifacts")
    File.mkdir_p!(dir)
    path = Path.join(dir, "browser-screenshot-#{System.unique_integer([:positive])}.png")
    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>>)
    File.touch!(path, System.os_time(:second) - days_ago * 86_400)
    path
  end

  # The node's logs: rotated ones older than `days`, a rotated one newer than
  # that, and the current files (as old as the oldest, so only rotation spares them).
  defp logs(context, days) do
    dir = Path.join(context.node.home, "logs")
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
    target = ~c"http://127.0.0.1:#{context.node.port}#{url}"
    {:ok, {{_, status, _}, _, _}} = :httpc.request(:get, {target, []}, [], [])
    status
  end
end
