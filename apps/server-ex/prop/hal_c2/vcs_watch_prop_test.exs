defmodule HalC2.VcsWatchPropTest do
  @moduledoc """
  A state machine over one watched checkout (`HalC2.Vcs.Watch`): branches checked out, the
  git index locked and unlocked by another git, and the watcher told that the checkout
  changed or that a turn ended. After each command the watcher is read back:

  - the status it shows names the branch the checkout was on at the last read git
    could give, and a read refused for the index lock leaves the last one standing;
  - the branch its pull request was looked up for follows the checkout, so a pull
    request found for one branch is never held for another;
  - the background fetch timer firing (with no client in front, so nothing is fetched or
    pulled) leaves the status as it was.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @branches ~w(main feature/a feature/b)

  property "the watched status follows the checkout and survives a locked index",
    numtests: HalC2.Prop.numtests(100),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("vcs-watch")
        work = Path.join(home, "work")
        File.mkdir_p!(work)
        git(work, ~w(init -q -b main))
        git(work, ~w(-c user.email=p@example.com -c user.name=P commit -q --allow-empty -m one))

        HalC2.Prop.start_services([
          {Registry, keys: :unique, name: HalC2.Vcs.Registry},
          {DynamicSupervisor, name: HalC2.Vcs.Supervisor, strategy: :one_for_one}
        ])

        Process.put(:cwd, work)
        HalC2.Vcs.Watch.subscribe(work, self(), nil)
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # branch: the checkout's; shown: the branch the watcher's status names; locked: whether
  # another git holds the index.
  def initial_state, do: %{branch: "main", shown: "main", locked: false}

  def command(s) do
    frequency(
      [
        {3, {:call, __MODULE__, :refresh, []}},
        {2, {:call, __MODULE__, :turn_ended, []}},
        {1, {:call, __MODULE__, :fetch_tick, []}},
        {1, {:call, __MODULE__, :lock, []}},
        {1, {:call, __MODULE__, :unlock, []}}
      ] ++
        if(s.locked, do: [], else: [{3, {:call, __MODULE__, :checkout, [oneof(@branches)]}}])
    )
  end

  def precondition(s, {:call, _, :checkout, _}), do: not s.locked
  def precondition(s, {:call, _, :lock, _}), do: not s.locked
  def precondition(s, {:call, _, :unlock, _}), do: s.locked
  def precondition(_s, _call), do: true

  def next_state(s, _res, {:call, _, :checkout, [branch]}), do: %{s | branch: branch}
  def next_state(s, _res, {:call, _, :lock, _}), do: %{s | locked: true}
  def next_state(s, _res, {:call, _, :unlock, _}), do: %{s | locked: false}
  def next_state(s, _res, {:call, _, :fetch_tick, _}), do: s

  def next_state(s, _res, {:call, _, read, _}) when read in [:refresh, :turn_ended],
    do: if(s.locked, do: s, else: %{s | shown: s.branch})

  def postcondition(s, {:call, _, read, _}, {shown, pr_branch})
      when read in [:refresh, :turn_ended] do
    shown == if(s.locked, do: s.shown, else: s.branch) and pr_branch == s.branch
  end

  def postcondition(s, {:call, _, :fetch_tick, _}, {shown, pr_branch}),
    do: shown == s.shown and pr_branch == s.branch

  def postcondition(_s, _call, _result), do: true

  def checkout(branch), do: git(Process.get(:cwd), ["checkout", "-q", "-B", branch])
  def lock, do: File.write!(Path.join(Process.get(:cwd), ".git/index.lock"), "")
  def unlock, do: File.rm!(Path.join(Process.get(:cwd), ".git/index.lock"))
  def refresh, do: read(&HalC2.Vcs.Watch.refresh/1)
  def turn_ended, do: read(&HalC2.Vcs.Watch.turn_ended/1)

  # The fetch timer fires; the watcher has handled it once it answers.
  def fetch_tick do
    cwd = Process.get(:cwd)
    [{pid, _}] = Registry.lookup(HalC2.Vcs.Registry, cwd)
    send(pid, :fetch)
    state = :sys.get_state(pid)
    {state.local["refName"], state.pr_branch}
  end

  # What the watcher shows once it has handled the news: a call behind the cast sees it.
  defp read(tell) do
    cwd = Process.get(:cwd)
    tell.(cwd)
    [{pid, _}] = Registry.lookup(HalC2.Vcs.Registry, cwd)
    state = :sys.get_state(pid)
    {state.local["refName"], state.pr_branch}
  end

  defp git(cwd, args), do: {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
end
