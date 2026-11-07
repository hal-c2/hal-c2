defmodule HalC2.StorageCleanupPropTest do
  @moduledoc """
  `HalC2.StorageCleanup` removing a deleted thread's worktree, against a model of what
  the worktree holds and what the deletion still has to do. Files of every kind
  appear in it (a tracked edit, untracked and ignored files, installed dependencies,
  repositories nested in an untracked or ignored folder), the thread's effects come
  and go in every status, and sweeps run under each "Keep worktrees with local
  changes" choice, one of them unknown, sometimes with the agent writing a file just
  before removal, inside the worktree's lease.

  The worktree goes exactly when no cleanup of the deletion waits or runs (a failed
  effect, or any other kind, holds nothing) and nothing the choice counts is in it;
  a worktree that stays has lost nothing, not even what the choice would let go.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  @kinds [:tracked_edit, :untracked, :ignored, :dependency, :nested_untracked, :nested_ignored]
  @choices ["any-local-files", "uncommitted-changes", "tracked-changes", "uncommited"]
  @types ["terminal.cleanup", "attachment.cleanup", "thread-title.generate"]
  @statuses ["pending", "running", "failed", "cancelled", :done]
  # What the agent may write while the sweep is about to remove the worktree.
  @late [nil, :tracked_edit, :untracked, :ignored]

  # Where each kind lives, and what it holds.
  @files %{
    tracked_edit: {"a.txt", "edit\n"},
    untracked: {"notes.txt", "mine\n"},
    ignored: {".env", "SECRET=1\n"},
    dependency: {"node_modules/pkg/index.js", "dep\n"},
    nested_untracked: {"scratch/repo/work.txt", "unpushed\n"},
    nested_ignored: {"deps/repo/work.txt", "unpushed\n"}
  }

  property "a deleted thread's worktree goes only with nothing to lose and nothing pending",
    numtests: HalC2.Prop.numtests(60),
    max_size: 12 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start_case()

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            end_case()
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start_case do
    home = HalC2.Prop.scratch_home("storage-cleanup")
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

    repo = Path.join(home, "repo")
    git(home, ~w(init -q -b main repo))
    File.write!(Path.join(repo, "a.txt"), "a\n")
    File.write!(Path.join(repo, ".gitignore"), ".env\nnode_modules/\ndeps/\n")
    git(repo, ~w(add .))
    git(repo, ~w(-c user.name=t -c user.email=t@t commit -q -m first))

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "p1",
        "title" => "Repo",
        "workspaceRoot" => repo
      })

    {:ok, %{"worktree" => %{"path" => path}}} =
      HalC2.Vcs.create_worktree(%{"cwd" => repo, "refName" => "main", "newRefName" => "hal-c2/t"})

    :ok = HalC2.Shell.subscribe(self())

    {:ok, _} =
      HalC2.Streams.commit("t", :thread, [
        {"thread", "t",
         %{
           "s" => %{
             "id" => "t",
             "projectId" => "p1",
             "title" => "t",
             "branch" => "hal-c2/t",
             "worktreePath" => path,
             "createdAt" => "2026-01-01T00:00:00.000Z",
             "deletedAt" => "2026-01-02T00:00:00.000Z"
           }
         }}
      ])

    receive do
      {:hal_c2_shell, {:rows, _, [{"t", _}]}} -> :ok
    after
      5_000 -> raise "the thread's row never reached the shell"
    end

    Process.put(:path, path)
    Process.put(:choice, nil)
  end

  defp end_case do
    HalC2.Prop.stop_services()
    Application.delete_env(:hal_c2, :storage_cleanup_first_ms)
    Application.delete_env(:hal_c2, :storage_cleanup_hook)
  end

  defp git(cwd, args), do: {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)

  # --- model ------------------------------------------------------------------

  # files: the kinds in the worktree. effects: type => status of its one record.
  def initial_state, do: %{files: MapSet.new(), effects: %{}, removed: false}

  def command(_state) do
    frequency([
      {3, {:call, __MODULE__, :put, [oneof(@kinds)]}},
      {3, {:call, __MODULE__, :effect, [oneof(@types), oneof(@statuses)]}},
      {4, {:call, __MODULE__, :sweep, [oneof(@choices), oneof(@late)]}}
    ])
  end

  def precondition(state, {:call, _, :put, [kind]}),
    do: not state.removed and kind not in state.files

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :put, [kind]}),
    do: %{state | files: MapSet.put(state.files, kind)}

  def next_state(state, _result, {:call, _, :effect, [type, :done]}),
    do: %{state | effects: Map.delete(state.effects, type)}

  def next_state(state, _result, {:call, _, :effect, [type, status]}),
    do: %{state | effects: Map.put(state.effects, type, status)}

  def next_state(state, _result, {:call, _, :sweep, [choice, late]}) do
    case outcome(state, choice, late) do
      {:kept, files} -> %{state | files: files}
      :removed -> %{state | removed: true}
    end
  end

  def postcondition(state, {:call, _, :sweep, [choice, late]}, {exists, intact}) do
    case outcome(state, choice, late) do
      {:kept, _files} -> exists and intact
      :removed -> not exists
    end
  end

  def postcondition(_state, _call, result), do: result == :ok

  # A sweep that reaches removal (nothing pending, nothing to lose) is when the agent
  # writes `late`, after every look but the last.
  defp outcome(state, choice, late) do
    late_files = if late, do: MapSet.put(state.files, late), else: state.files

    cond do
      state.removed -> :removed
      pending?(state) or loses?(state.files, choice) -> {:kept, state.files}
      loses?(late_files, choice) -> {:kept, late_files}
      true -> :removed
    end
  end

  defp pending?(state) do
    Enum.any?(state.effects, fn {type, status} ->
      type in ["terminal.cleanup", "attachment.cleanup"] and status in ["pending", "running"]
    end)
  end

  # Whether the worktree holds something `choice` counts; an unknown choice counts
  # the most. Nested repositories always count; installed dependencies never do.
  defp loses?(files, choice) do
    counted =
      case choice do
        "tracked-changes" -> [:tracked_edit]
        "uncommitted-changes" -> [:tracked_edit, :untracked]
        _ -> [:tracked_edit, :untracked, :ignored]
      end

    Enum.any?(files, &(&1 in [:nested_untracked, :nested_ignored | counted]))
  end

  # --- commands ---------------------------------------------------------------

  def put(kind) do
    {name, content} = @files[kind]
    file = Path.join(Process.get(:path), name)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, content)

    if kind in [:nested_untracked, :nested_ignored] do
      repo = Path.dirname(file)
      git(repo, ~w(init -q))
      git(repo, ~w(add .))
      git(repo, ~w(-c user.name=t -c user.email=t@t commit -q -m work))
    end

    :ok
  end

  def effect(type, status) do
    key = "effect:t:#{type}"

    case status do
      :done ->
        HalC2.Store.delete_meta(key)

      status ->
        record = %{"id" => type, "threadId" => "t", "type" => type, "status" => status}
        HalC2.Store.put_meta(key, JSON.encode!(record))
    end
  end

  # One sweep under `choice`, the agent writing `late` at removal.
  # A changed choice sweeps inside StorageCleanup on its own; a call queued behind that
  # returns once it is done. `{worktree still there, every file in it as it was}`.
  def sweep(choice, late) do
    path = Process.get(:path)
    before = snapshot(path)
    hook = if late, do: {__MODULE__, :write_at, [late]}
    Application.put_env(:hal_c2, :storage_cleanup_hook, hook)

    if Process.get(:choice) != choice do
      {_, version} = HalC2.Settings.get()
      cleanup = %{"worktreeOnDelete" => true, "worktreeKeepWhen" => choice}
      {:ok, _} = HalC2.Settings.put(%{"storageCleanup" => cleanup}, version)
      _ = :sys.get_state(HalC2.StorageCleanup, :infinity)
      Process.put(:choice, choice)
    end

    :ok = HalC2.StorageCleanup.sweep()
    Application.delete_env(:hal_c2, :storage_cleanup_hook)
    exists = File.dir?(path)

    {exists,
     exists and Enum.all?(before, fn {file, content} -> File.read(file) == {:ok, content} end)}
  end

  @doc false
  def write_at(kind, :removing, path) do
    {name, content} = @files[kind]
    File.write!(Path.join(path, name), content)
  end

  def write_at(_kind, _stage, _path), do: :ok

  # The files the model put there, with what they hold, as the sweep found them.
  defp snapshot(path) do
    for {_kind, {name, content}} <- @files,
        file = Path.join(path, name),
        File.read(file) == {:ok, content},
        do: {file, content}
  end
end
