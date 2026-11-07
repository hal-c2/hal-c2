defmodule HalC2.StorageCleanupLivePropTest do
  @moduledoc """
  `HalC2.StorageCleanup` deciding on a live thread's worktree, against a plain model
  of the rules. Each case is one worktree in a clone of a repository, with a thread
  of some idle age and settled time, something open in it or not (a terminal, a
  provider session, a running turn), files of every kind the "Keep worktrees with
  local changes" choice may count, an unpublished commit or not, and a rule set
  (idle days, settled days, merged, unchanged; the choice, one of them unknown).

  A worktree is removed only when a rule applies, nothing is open or running, the
  choice counts nothing in it, and its thread did not settle in the last minute;
  with no rule on nothing happens; every kept worktree carries a reason; the
  thread's branch survives a removal.
  """

  use ExUnit.Case, async: false
  use PropCheck

  @moduletag timeout: :infinity

  @day 86_400
  @kinds [:tracked_edit, :untracked, :ignored, :dependency]
  @choices ["any-local-files", "uncommitted-changes", "tracked-changes", "uncommited"]
  @files %{
    tracked_edit: {"a.txt", "edit\n"},
    untracked: {"notes.txt", "mine\n"},
    ignored: {".env", "SECRET=1\n"},
    dependency: {"node_modules/pkg/index.js", "dep\n"}
  }

  property "a live thread's worktree goes only by a rule, with nothing to lose and nothing open",
    numtests: HalC2.Prop.numtests(40) do
    forall s <- scenario() do
      trap_exit do
        result =
          try do
            run(s)
          rescue
            error -> {:crashed, Exception.format(:error, error, __STACKTRACE__)}
          catch
            kind, reason -> {:crashed, Exception.format(kind, reason, __STACKTRACE__)}
          after
            end_case()
          end

        (is_map(result) and agrees?(s, result))
        |> when_fail(
          IO.puts(:stderr, "scenario: #{inspect(s, pretty: true)}\nresult: #{inspect(result)}")
        )
      end
    end
  end

  defp scenario do
    let {activity, settled, status, open, kinds, commit, rules, choice} <-
          {oneof([5, 2 * @day, 10 * @day]), oneof([nil, 10, 3 * @day]),
           frequency([{4, "idle"}, {1, "running"}]),
           frequency([{4, nil}, {1, :terminal}, {1, :session}]), subset(@kinds), boolean(),
           {oneof([nil, 1, 5]), oneof([nil, 1, 5]), boolean(), boolean()}, oneof(@choices)} do
      %{
        activity: activity,
        settled: settled,
        status: status,
        open: open,
        kinds: kinds,
        commit: commit,
        rules: rules,
        choice: choice
      }
    end
  end

  defp subset(items), do: let(keep <- vector(length(items), boolean()), do: pick(items, keep))
  defp pick(items, keep), do: for({item, true} <- Enum.zip(items, keep), do: item)

  # --- model ------------------------------------------------------------------

  defp enabled?(%{rules: {idle, settled, merged, unchanged}}),
    do: idle != nil or settled != nil or merged or unchanged

  defp counted(choice) do
    case choice do
      "tracked-changes" -> [:tracked_edit]
      "uncommitted-changes" -> [:tracked_edit, :untracked]
      _ -> [:tracked_edit, :untracked, :ignored]
    end
  end

  # :untouched, :kept or :removed
  defp expected(s) do
    {idle, settled, _merged, unchanged} = s.rules
    last = if s.settled, do: min(s.settled, s.activity)

    cond do
      not enabled?(s) -> :untouched
      s.status != "idle" or s.open != nil -> :kept
      Enum.any?(s.kinds, &(&1 in counted(s.choice))) -> :kept
      last != nil and last < 60 -> :kept
      idle != nil and s.activity > idle * @day -> :removed
      settled != nil and last != nil and last >= settled * @day -> :removed
      unchanged and not s.commit -> :removed
      true -> :kept
    end
  end

  defp agrees?(s, %{exists: exists, entry: entry, branch: branch}) do
    want = expected(s)

    case want do
      :untouched -> exists and entry == nil
      :kept -> exists and kept?(entry)
      :removed -> not exists and removed?(entry) and branch
    end
  end

  defp kept?(%{"outcome" => "kept", "reason" => reason}), do: is_binary(reason) and reason != ""
  defp kept?(_), do: false

  defp removed?(%{"outcome" => "removed", "reason" => reason}), do: is_binary(reason)
  defp removed?(_), do: false

  # --- the world --------------------------------------------------------------

  defp run(s) do
    home = HalC2.Prop.scratch_home("storage-cleanup-live")
    Application.put_env(:hal_c2, :storage_cleanup_first_ms, nil)

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Settings,
      HalC2.WorkspaceLease,
      {Registry, keys: :unique, name: HalC2.Codex.Registry},
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
        id: :claude_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
        id: :acp_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Vcs.Registry},
        id: :vcs_registry
      ),
      HalC2.StorageCleanup
    ])

    origin = Path.join(home, "origin.git")
    seed = Path.join(home, "seed")
    repo = Path.join(home, "repo")
    git(home, ~w(init -q --bare -b main) ++ [origin])
    git(home, ~w(init -q -b main) ++ [seed])
    File.write!(Path.join(seed, "a.txt"), "a\n")
    File.write!(Path.join(seed, ".gitignore"), ".env\nnode_modules/\n")
    git(seed, ~w(add .))
    git(seed, ~w(-c user.name=t -c user.email=t@t commit -q -m first))
    git(seed, ["push", "-q", origin, "main"])
    git(home, ["clone", "-q", origin, repo])

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "title" => "Repo",
        "workspaceRoot" => repo
      })

    {:ok, %{"worktree" => %{"path" => path}}} =
      HalC2.Vcs.create_worktree(%{"cwd" => repo, "refName" => "main", "newRefName" => "hal-c2/t"})

    if s.commit do
      File.write!(Path.join(path, "c.txt"), "c\n")
      git(path, ~w(add c.txt))
      git(path, ~w(-c user.name=t -c user.email=t@t commit -q -m unpublished))
    end

    for kind <- s.kinds do
      {name, content} = @files[kind]
      file = Path.join(path, name)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, content)
    end

    open(s.open, path)
    thread(s, path)

    {idle, settled, merged, unchanged} = s.rules

    cleanup = %{
      "worktreeAfterDays" => idle,
      "worktreeSettledAfterDays" => settled,
      "worktreeOnMerge" => merged,
      "worktreeUnchanged" => unchanged,
      "worktreeKeepWhen" => s.choice
    }

    {_, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(%{"storageCleanup" => cleanup}, version)

    # The changed policy sweeps on its own; a call queued behind that returns when it is
    # done, and its report is the one read (a second sweep would find the worktree gone).
    _ = :sys.get_state(HalC2.StorageCleanup, :infinity)

    entry = Enum.find(HalC2.StorageCleanup.report(), &(&1["threadId"] == "t"))
    {_, branch} = System.cmd("git", ~w(rev-parse --verify -q refs/heads/hal-c2/t), cd: repo)

    %{exists: File.dir?(path), entry: entry, branch: branch == 0}
  end

  defp open(nil, _path), do: :ok
  # Its own process, since registering links to the registry the case stops.
  defp open(:session, _path) do
    me = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(HalC2.Codex.Registry, "t", nil)
        send(me, :registered)
        Process.sleep(:infinity)
      end)

    receive do
      :registered -> Process.put(:hub, pid)
    end
  end

  # A stand-in for the terminal hub, answering what the sweep asks it.
  defp open(:terminal, path) do
    pid =
      spawn(fn ->
        loop = fn loop ->
          receive do
            {:"$gen_call", from, :summaries} ->
              GenServer.reply(from, [%{"status" => "running", "worktreePath" => path}])
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    Process.register(pid, HalC2.Terminal.Hub)
    Process.put(:hub, pid)
  end

  defp thread(s, path) do
    ago = fn seconds ->
      DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.to_iso8601()
    end

    settled = if s.settled, do: %{"settledAt" => ago.(s.settled)}, else: %{}

    :ok = HalC2.Shell.subscribe(self())

    {:ok, _} =
      HalC2.Streams.commit("t", :thread, [
        {"thread", "t",
         %{
           "s" =>
             Map.merge(settled, %{
               "id" => "t",
               "projectId" => "p1",
               "title" => "t",
               "branch" => "hal-c2/t",
               "worktreePath" => path,
               "createdAt" => ago.(s.activity)
             })
         }}
      ])

    receive do
      {:hal_c2_shell, {:rows, _, [{"t", _}]}} -> :ok
    after
      5_000 -> raise "the thread's row never reached the shell"
    end

    # A turn in progress is a run, from which the row gets its `activeRunId`.
    if s.status == "running" do
      at = ago.(0)

      run = %{
        "id" => "run-1",
        "threadId" => "t",
        "ordinal" => 1,
        "providerInstanceId" => "codex",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "status" => "running",
        "requestedAt" => at,
        "startedAt" => at
      }

      {:ok, _} = HalC2.Streams.commit("t", :thread, [{"run", "run-1", %{"s" => run}}])
      :ok = HalC2.Streams.flush_shell("t")
    end
  end

  defp end_case do
    if pid = Process.delete(:hub), do: Process.exit(pid, :kill)
    HalC2.Prop.stop_services()
    Application.delete_env(:hal_c2, :storage_cleanup_first_ms)
  end

  defp git(cwd, args), do: {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
end
