defmodule HalC2.PlannerMilestonesPropTest do
  @moduledoc """
  A state machine model of how the planner plugin (`plugins/planner/mc`) moves issues
  between the milestones of a repository it syncs both ways, against the fake GitHub
  (`test/support/fake_gh.py`), which holds every move of an issue to a milestone or
  out of one until the model answers it, in any order, and writes down each move it
  takes.

  GitHub has three milestones, each holding one issue. The plan imports them, and a
  client moves the tasks of the first two issues from one milestone to another, into
  one when the task is in none and out of the one it is in, each move from a caller of
  its own, as another window's would, so it can wait on GitHub while the case goes on.
  GitHub answers the moves it holds one at a time, and now and then refuses one, and the
  plugin now and then looks at GitHub, which lists each issue in the milestone it took
  for it last. After every step, a look's included, the plan has each task in the
  milestone it was moved to last, and once GitHub has answered everything:

  - GitHub has each issue in the milestone its task is in, or in none, the move it took
    last being the one the plan kept, whichever order it took them in;
  - the moves end: GitHub is not asked to move issues for ever;
  - no milestone or task is marked as not synced or waiting on GitHub.

  A refusal stands until the item's next change, so once GitHub has refused a move it
  may end with an issue elsewhere than its task, but never without a mark saying so.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  @id "planner"
  @server HalC2Plugins.Planner
  @package Path.expand("../../../../plugins/planner", __DIR__)
  @support Path.expand("../../test/support", __DIR__)
  @repository "acme/api"
  # Issue n starts in milestone n; only the first two move.
  @issues [1, 2, 3]
  @moving [1, 2]
  @milestones [1, 2, 3]
  # The most moves one settling answers before it calls them endless.
  @answers 40

  setup_all do
    vars = ~w(PATH FAKE_GH_RULES FAKE_GH_LOG GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0)
    previous_vars = Map.new(vars, &{&1, System.get_env(&1)})
    apps = ~w(gh_command settings_check_ms home planner_today)a
    previous_apps = Map.new(apps, &{&1, Application.fetch_env(:hal_c2, &1)})

    for var <- ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0),
        do: System.delete_env(var)

    # Every gh the MC runs is the fake, answering from the rules of the case.
    bin = Path.expand("../../tmp/prop/planner-milestones-gh-#{System.pid()}", __DIR__)
    File.rm_rf!(bin)
    File.mkdir_p!(bin)
    File.ln_s!(Path.join(@support, "fake_gh.py"), Path.join(bin, "gh"))
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    Application.put_env(:hal_c2, :gh_command, "gh")
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    Application.put_env(:hal_c2, :planner_today, "2026-10-15")

    on_exit(fn ->
      for {var, value} <- previous_vars,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))

      for {key, value} <- previous_apps do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end

      File.rm_rf!(bin)
    end)

    :ok
  end

  property "GitHub ends with each issue in the milestone its task was moved to last",
    numtests: HalC2.Prop.numtests(30),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        begin_case()
        {history, state, result} = run_commands(__MODULE__, cmds)
        end_case()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------------

  # `at`: issue → the milestone its task is in, or nil.
  def initial_state, do: %{at: Map.new(@issues, &{&1, &1})}

  def command(m) do
    frequency([
      {4,
       let [n <- oneof(@moving), to <- oneof([nil | @milestones])] do
         {:call, __MODULE__, :move, [n, m.at[n], to]}
       end},
      {4, {:call, __MODULE__, :answer, [integer(0, 3)]}},
      {1, {:call, __MODULE__, :refuse, [integer(0, 3)]}},
      {1, {:call, __MODULE__, :look, []}},
      {1, {:call, __MODULE__, :settle, []}}
    ])
  end

  def precondition(m, {:call, _, :move, [n, from, to]}), do: from == m.at[n] and to != from
  def precondition(_m, _call), do: true

  def next_state(m, _result, {:call, _, :move, [n, _from, to]}), do: put_in(m.at[n], to)
  def next_state(m, _result, _call), do: m

  def postcondition(m, {:call, _, :settle, []} = call, observed) do
    at = next_state(m, observed, call).at

    observed.problems == [] and observed.at == at and
      if(observed.refused,
        do: observed.github == at or observed.marked != [],
        else: observed.github == at and observed.marked == []
      )
  end

  def postcondition(m, call, observed),
    do: observed.problems == [] and observed.at == next_state(m, observed, call).at

  # --- commands ---------------------------------------------------------------------------

  # Moves issue `n`'s task from the milestone `from` to `to`, either of them none, from a
  # caller of its own, and returns once GitHub holds a move or the caller is done.
  def move(n, from, to) do
    plan = plan()
    task = task_id(plan, n)

    {method, input} =
      case {from, to} do
        {nil, to} ->
          {"updateItem", held(plan, to, &(&1 ++ [task]))}

        {from, nil} ->
          {"updateItem", held(plan, from, &(&1 -- [task]))}

        {from, to} ->
          ids = %{"from" => milestone_id(plan, from), "to" => milestone_id(plan, to)}
          {"moveToMilestone", Map.put(ids, "id", task)}
      end

    caller =
      spawn_monitor(fn ->
        try do
          call(method, input)
        catch
          # The plugin stopped with the case.
          :exit, _ -> :ok
        end
      end)

    Process.put(:pl_callers, [caller | Process.get(:pl_callers)])
    await_github()
    observe()
  end

  # GitHub answers the `k`th move it holds, counting round, if it holds any, and returns
  # once it holds the next move or the caller of the one it answered is done.
  def answer(k), do: answer(k, "go")

  # GitHub refuses the `k`th move it holds, as `answer/1` takes it.
  def refuse(k), do: answer(k, "no")

  defp answer(k, word) do
    case Process.get(:pl_held) do
      [] ->
        :ok

      held ->
        gate = Enum.at(held, rem(k, length(held)))
        Process.put(:pl_held, List.delete(held, gate))
        if word == "no", do: Process.put(:pl_refused, true)
        File.write!(gate, word <> "\n", [:raw])
        await_github()
    end

    observe()
  end

  # The plugin looks at GitHub, which lists each issue in the milestone it took for it
  # last, and returns once the look is applied. The moves GitHub holds wait on.
  def look do
    rules(github())
    {:ok, _} = call("sync", %{})
    observe()
  end

  # GitHub answers every move it holds, and the ones they lead to, until none is left.
  def settle, do: settle(@answers)

  defp settle(0) do
    problem("GitHub was still asked to move issues after #{@answers} moves")
    observe()
  end

  defp settle(left) do
    case Process.get(:pl_held) do
      [] ->
        observe()

      [gate | rest] ->
        Process.put(:pl_held, rest)
        File.write!(gate, "go\n", [:raw])
        await_github()
        settle(left - 1)
    end
  end

  # The milestone `number`'s update, its tasks changed by `fun`.
  defp held(plan, number, fun) do
    milestone = Enum.find(plan["items"], &match?(%{"milestone" => %{"number" => ^number}}, &1))
    %{"id" => milestone["id"], "fields" => %{"after" => fun.(milestone["after"])}}
  end

  defp milestone_id(plan, number),
    do: Enum.find(plan["items"], &match?(%{"milestone" => %{"number" => ^number}}, &1))["id"]

  defp task_id(plan, number),
    do: Enum.find(plan["items"], &match?(%{"issue" => %{"number" => ^number}}, &1))["id"]

  defp call(method, input) do
    HalC2.Plugins.handle("call", %{"id" => @id, "method" => method, "input" => input})
  end

  defp plan do
    {:ok, plan} = call("plan", %{})
    plan
  end

  # --- observing --------------------------------------------------------------------------

  # Waits until the one caller that may be running, the one just started or answered,
  # has GitHub hold its next move or is done: every other caller waits on GitHub.
  defp await_github do
    callers = Process.get(:pl_callers)
    {reader, _} = Process.get(:pl_reader)

    receive do
      {^reader, {:data, {:eol, gate}}} ->
        Process.put(:pl_held, Process.get(:pl_held) ++ [gate])

      {:DOWN, ref, :process, pid, _} ->
        if {pid, ref} in callers,
          do: Process.put(:pl_callers, List.delete(callers, {pid, ref})),
          else: await_github()
    after
      15_000 -> problem("a move neither reached GitHub nor ended")
    end
  end

  # What the model checks: where the plan has each task, where GitHub has each issue,
  # and which items are marked as not synced or waiting on GitHub.
  defp observe do
    plan = plan()

    at =
      Map.new(@issues, fn n ->
        task = task_id(plan, n)

        holders =
          for %{"milestone" => %{"number" => number}} = item <- plan["items"],
              task in item["after"],
              do: number

        case holders do
          [] -> {n, nil}
          [number] -> {n, number}
          many -> {n, many}
        end
      end)

    {items, _details} = GenServer.call(@server, :looking)

    marked =
      for {_, item} <- items,
          item["synced"] != nil or item["syncError"] != nil,
          do: item["title"]

    %{
      at: at,
      github: github(),
      marked: marked,
      refused: Process.get(:pl_refused),
      problems: Process.put(:pl_problems, []) |> Enum.reverse()
    }
  end

  # Issue → the milestone GitHub took for it last, or the one it started in.
  defp github do
    taken =
      case File.read(Path.join(Process.get(:pl_gh), "taken")) do
        {:ok, text} -> String.split(text, "\n", trim: true)
        {:error, _} -> []
      end

    Enum.reduce(taken, Map.new(@issues, &{&1, &1}), fn line, github ->
      [n, milestone] = String.split(line, " ")
      milestone = if milestone == "null", do: nil, else: String.to_integer(milestone)
      Map.put(github, String.to_integer(n), milestone)
    end)
  end

  defp problem(text), do: Process.put(:pl_problems, [text | Process.get(:pl_problems, [])])

  # Returns once the plugin has no look in flight, and has heard from everything that
  # ended.
  defp drain, do: drain(System.monotonic_time(:millisecond) + 15_000, false)

  defp drain(deadline, settled_once) do
    with pid when is_pid(pid) <- Process.whereis(@server),
         {:ok, state} <- get_state(pid) do
      kids = kids(pid)

      cond do
        System.monotonic_time(:millisecond) > deadline ->
          problem("planner never settled: #{length(kids)} processes")

        kids == [] and state.polling == nil ->
          if settled_once, do: :ok, else: drain(deadline, true)

        true ->
          await_any(kids)
          drain(deadline, false)
      end
    else
      _ -> problem("planner is not running")
    end
  end

  defp get_state(pid) do
    {:ok, :sys.get_state(pid)}
  catch
    :exit, _ -> :gone
  end

  defp kids(pid) do
    {:parent, parent} = Process.info(pid, :parent)
    {:links, links} = Process.info(pid, :links)
    Enum.filter(links, &(is_pid(&1) and &1 != parent))
  end

  defp await_any([]), do: :ok

  defp await_any(kids) do
    refs = Enum.map(kids, &Process.monitor/1)
    receive do: ({:DOWN, ref, :process, _, _} when is_reference(ref) -> :ok)
    for ref <- refs, do: Process.demonitor(ref, [:flush])
  end

  # --- one case ----------------------------------------------------------------------------

  defp begin_case do
    home = HalC2.Prop.scratch_home("planner-milestones")
    root = Path.join(home, "api")
    File.mkdir_p!(root)
    git!(root, ["init", "-q"])

    git!(root, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "start"
    ])

    git!(root, ["remote", "add", "origin", "git@github.com:#{@repository}.git"])
    gh = Path.join(home, "gh")
    File.mkdir_p!(gh)
    Process.put(:pl_gh, gh)
    System.put_env("FAKE_GH_LOG", Path.join(gh, "calls.jsonl"))
    System.put_env("FAKE_GH_RULES", Path.join(gh, "rules.json"))

    # GitHub tells the case of each move it holds by a line on the fifo `held`, naming a
    # fifo of the move's own that it waits on until the case writes to it, then writes
    # the move down in `taken`, or fails when the case wrote "no". The reader, whose lines come to the case as messages,
    # keeps `held` open for writing too, so it never sees its end, and stops at "stop".
    notify = Path.join(gh, "held")
    {_, 0} = System.cmd("mkfifo", [notify])

    reader =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, 4096},
        args: ["-c", ~s|exec awk '$0 == "stop" { exit } { print; fflush() }' 0<> '#{notify}'|]
      ])

    Process.put(:pl_reader, {reader, notify})
    rules(Map.new(@issues, &{&1, &1}))
    Process.put(:pl_held, [])
    Process.put(:pl_callers, [])
    Process.put(:pl_problems, [])
    Process.put(:pl_refused, false)

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Settings,
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Orchestration.TurnWatch,
      {Registry, keys: :unique, name: HalC2.Codex.Registry},
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
        id: :claude_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
        id: :acp_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Pi.Registry}, id: :pi_registry),
      {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
      HalC2.Mcp,
      {Registry, keys: :unique, name: HalC2.Vcs.Registry},
      {DynamicSupervisor, name: HalC2.Vcs.Supervisor, strategy: :one_for_one},
      HalC2.PullRequests.Refreshes,
      HalC2.Plugins
    ])

    :sys.get_state(HalC2.Plugins)

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "api",
        "title" => "api",
        "workspaceRoot" => root
      })

    HalC2.Streams.flush_shell("api")
    :sys.get_state(HalC2.Shell)
    File.mkdir_p!(Path.join(HalC2.Paths.data_dir(), "plugins"))
    File.cp_r!(@package, Path.join([HalC2.Paths.data_dir(), "plugins", @id]))
    {:ok, _} = HalC2.Plugins.handle("rescan", %{})
    {:ok, %{"plugins" => plugins}} = HalC2.Plugins.handle("list", %{})
    permissions = Enum.find(plugins, &(&1["id"] == @id))["permissions"] |> Enum.map(& &1["id"])
    {:ok, _} = HalC2.Plugins.handle("enable", %{"id" => @id, "acceptPermissions" => permissions})

    {:ok, _} =
      HalC2.Plugins.handle("saveSettings", %{
        "id" => @id,
        "settings" => %{
          "pollMinutes" => 60,
          "defaultProject" => "api",
          "sync" => "twoWay",
          "repositories" => [@repository]
        }
      })

    drain()
    {:ok, _} = call("sync", %{})
    drain()
    Process.put(:pl_problems, [])
  end

  # The fake GitHub's rules, with each issue in the milestone `github` has it in: a move
  # waits on the case (see `begin_case/0`), and a read or list says where each issue is.
  # They are replaced whole, as a gh running meanwhile reads them.
  defp rules(github) do
    gh = Process.get(:pl_gh)
    {_, notify} = Process.get(:pl_reader)
    taken = Path.join(gh, "taken")

    moves =
      for n <- @issues, milestone <- [nil | @milestones] do
        value = JSON.encode!(milestone)

        %{
          "args" => ["--method PATCH", "repos/#{@repository}/issues/#{n} "],
          "stdin" => [~s("milestone":#{value}})],
          "run" =>
            "g='#{gh}/move-'$$; mkfifo \"$g\"; echo \"$g\" > '#{notify}'; " <>
              "read a < \"$g\" || :; rm -f \"$g\"; [ \"$a\" != no ] || exit 1; " <>
              "echo '#{n} #{value}' >> '#{taken}'",
          "stdout" => %{"number" => n}
        }
      end

    reads =
      for n <- @issues do
        %{
          "args" => ["api graphql"],
          "stdin" => ["issue(number: $number) { ...IssueFields", ~s("number":#{n},)],
          "stdout" => %{"data" => %{"repository" => %{"issue" => issue_node(n, github[n])}}}
        }
      end

    list = %{
      "args" => ["api graphql"],
      "stdin" => ["issues(first: $first"],
      "stdout" => %{
        "data" => %{
          "repository" => %{
            "issues" => %{
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
              "nodes" => Enum.map(@issues, &issue_node(&1, github[&1]))
            }
          }
        }
      }
    }

    path = Path.join(gh, "rules.json")
    File.write!(path <> ".new", JSON.encode!(moves ++ reads ++ [list]))
    File.rename!(path <> ".new", path)
  end

  # Issue `n` as GitHub lists it, in `milestone` or none.
  defp issue_node(n, milestone) do
    %{
      "number" => n,
      "title" => "Issue #{n}",
      "body" => "",
      "state" => "OPEN",
      "stateReason" => nil,
      "url" => "https://github.com/#{@repository}/issues/#{n}",
      "repository" => %{"nameWithOwner" => @repository},
      "milestone" =>
        milestone &&
          %{"number" => milestone, "title" => "M#{milestone}", "dueOn" => "2026-11-30T00:00:00Z"}
    }
  end

  defp end_case do
    HalC2.Prop.stop_services()
    # The moves GitHub still holds are answered, and their callers find the plugin gone.
    # They end before the next case begins: a gh one of them ran later would read that
    # case's rules and log.
    release(System.monotonic_time(:millisecond) + 15_000)
    {reader, notify} = Process.get(:pl_reader)
    File.write!(notify, "stop
", [:raw])

    receive do
      {^reader, {:exit_status, _}} -> :ok
    after
      15_000 -> :ok
    end

    # Notices that came after the last answer.
    receive_all(reader)
  end

  defp release(deadline) do
    for gate <- Process.get(:pl_held), do: File.write!(gate, "go\n", [:raw])
    Process.put(:pl_held, [])

    if Process.get(:pl_callers) != [] and System.monotonic_time(:millisecond) < deadline do
      await_github()
      release(deadline)
    end
  end

  defp receive_all(reader) do
    receive do
      {^reader, _} -> receive_all(reader)
    after
      0 -> :ok
    end
  end

  defp git!(dir, args) do
    {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end
end
