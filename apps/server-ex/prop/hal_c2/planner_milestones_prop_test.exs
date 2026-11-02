defmodule HalC2.PlannerMilestonesPropTest do
  @moduledoc """
  A state machine model of how the planner plugin (`plugins/planner/mc`) moves issues
  between the milestones of a repository it syncs both ways, against the fake GitHub
  (`test/support/fake_gh.py`), which holds every move of an issue to a milestone or
  out of one until the model answers it, in any order, and writes down each move it
  takes.

  GitHub has three milestones, each holding one issue, and a fourth issue in none. The
  plan imports the three, and a client moves the tasks of the first two issues from one
  milestone to another, into one when the task is in none and out of the one it is in.
  It also relinks those tasks to an issue no task names, which hands an issue over when
  another task left it, unlinks them and removes them. Each change comes from a caller
  of its own, as another window's would, so it can wait on GitHub while the case goes
  on. GitHub answers the moves it holds one at a time, and now and then refuses one, and
  the plugin now and then looks at GitHub, which lists each issue in the milestone it
  took for it last, or restarts, its changes going on. After every step, a look's included, the plan has each task where
  it was moved to last and naming the issue it was linked to last, and once GitHub has
  answered everything:

  - GitHub has each issue in the milestone of the task naming it, or in none when no
    task names it or that task is in none, the move it took last being the one the plan
    kept, whichever order it took them in;
  - the moves end: GitHub is not asked to move issues for ever;
  - no milestone or task is marked as not synced or waiting on GitHub.

  A refusal stands until the item's next change, so once GitHub has refused a move it
  may end with an issue elsewhere than its task, but never without a mark saying so.
  Which milestone asked is not known to the case, so a refusal stands until every
  milestone has changed since the last one: then GitHub ends with every issue where its
  task is, and nothing is marked, as if it had refused nothing.

  A correction sent to the task that took its issue over takes a late push, a refusal and
  two relinks in a row, which cases this short rarely reach: its scenario in
  `features/planning/planner.feature` pins it.

  A look is generated only until the first relink, unlink or removal. It makes a task
  of an open issue no task names, and puts a newly linked task in the milestone GitHub
  has its issue in, so what it does then depends on what GitHub took by that moment,
  which the model does not follow.
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
  # Task n starts with issue n in milestone n; only the first two change. Issue 4 starts
  # in no milestone with no task.
  @tasks [1, 2, 3]
  @issues [1, 2, 3, 4]
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

  # `tasks`: task → the issue it names and the milestone it is in, either of them nil; a
  # removed task is gone. `relinked`: a task has left its issue, so no look is generated.
  def initial_state do
    %{tasks: Map.new(@tasks, &{&1, %{issue: &1, at: &1}}), relinked: false}
  end

  def command(m) do
    live = Enum.filter(@moving, &is_map_key(m.tasks, &1))

    changes =
      if live == [],
        do: [],
        else: [
          {4,
           let [t <- oneof(live), to <- oneof([nil | @milestones])] do
             {:call, __MODULE__, :move, [t, m.tasks[t].at, to]}
           end},
          {2,
           let [t <- oneof(live), n <- oneof(@issues)] do
             {:call, __MODULE__, :relink, [t, n, m.tasks[t].at]}
           end},
          {1,
           let t <- oneof(live) do
             {:call, __MODULE__, :unlink, [t, m.tasks[t].issue, m.tasks[t].at]}
           end},
          {1,
           let t <- oneof(live) do
             {:call, __MODULE__, :remove, [t, m.tasks[t].at]}
           end}
        ]

    frequency(
      changes ++
        [
          {4, {:call, __MODULE__, :answer, [integer(0, 3)]}},
          {1, {:call, __MODULE__, :refuse, [integer(0, 3)]}},
          {1, {:call, __MODULE__, :look, []}},
          {1, {:call, __MODULE__, :restart, []}},
          {1, {:call, __MODULE__, :settle, []}}
        ]
    )
  end

  def precondition(m, {:call, _, :move, [t, from, to]}),
    do: live?(m, t, from) and to != from

  def precondition(m, {:call, _, :relink, [t, n, from]}),
    do: live?(m, t, from) and not Enum.any?(m.tasks, fn {_, task} -> task.issue == n end)

  def precondition(m, {:call, _, :unlink, [t, issue, from]}),
    do: live?(m, t, from) and issue != nil and m.tasks[t].issue == issue

  def precondition(m, {:call, _, :remove, [t, from]}), do: live?(m, t, from)
  def precondition(m, {:call, _, :look, []}), do: not m.relinked
  # A restart looks at GitHub as it starts.
  def precondition(m, {:call, _, :restart, []}), do: not m.relinked
  def precondition(_m, _call), do: true

  defp live?(m, t, from), do: is_map_key(m.tasks, t) and m.tasks[t].at == from

  def next_state(m, _result, {:call, _, :move, [t, _from, to]}), do: put_in(m.tasks[t].at, to)

  def next_state(m, _result, {:call, _, :relink, [t, n, _from]}),
    do: %{put_in(m.tasks[t].issue, n) | relinked: true}

  def next_state(m, _result, {:call, _, :unlink, [t, _issue, _from]}),
    do: %{put_in(m.tasks[t].issue, nil) | relinked: true}

  def next_state(m, _result, {:call, _, :remove, [t, _from]}),
    do: %{m | tasks: Map.delete(m.tasks, t), relinked: true}

  def next_state(m, _result, _call), do: m

  def postcondition(m, {:call, _, :settle, []} = call, observed) do
    tasks = next_state(m, observed, call).tasks
    github = placed(tasks)

    observed.problems == [] and observed.tasks == tasks and
      if(observed.refused and MapSet.new(observed.changed) != MapSet.new(@milestones),
        do: observed.github == github or observed.marked != [],
        else: observed.github == github and observed.marked == []
      )
  end

  def postcondition(m, call, observed),
    do: observed.problems == [] and observed.tasks == next_state(m, observed, call).tasks

  # Issue → the milestone of the task naming it, or nil.
  defp placed(tasks) do
    Map.new(@issues, fn n ->
      {n, Enum.find_value(tasks, fn {_, task} -> if task.issue == n, do: task.at end)}
    end)
  end

  # --- commands ---------------------------------------------------------------------------

  # Moves task `t` from the milestone `from` to `to`, either of them none.
  def move(t, from, to) do
    plan = plan()
    task = Process.get(:pl_tasks)[t]

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

    change(method, input, [from, to])
  end

  # Links task `t`, in the milestone `from`, to the issue `n`, which no task names.
  def relink(t, n, from),
    do: change("link", %{"itemId" => Process.get(:pl_tasks)[t], "issue" => ref(n)}, [from])

  # Unlinks task `t`, in the milestone `from`, from the issue it names.
  def unlink(t, n, from) do
    input = %{"itemId" => Process.get(:pl_tasks)[t], "kind" => "issue", "ref" => ref(n)}
    change("unlink", input, [from])
  end

  # Removes task `t`, in the milestone `from`.
  def remove(t, from),
    do: change("removeItem", %{"id" => Process.get(:pl_tasks)[t]}, [from])

  defp ref(n), do: %{"repository" => @repository, "number" => n}

  # Calls the plugin from a caller of its own, and returns once GitHub holds a move or the
  # caller is done. `milestones`, any of them nil for none, are the ones the call changes.
  defp change(method, input, milestones) do
    # It ends with the plugin's answer, which `await_github/0` reads.
    caller = spawn_monitor(fn -> exit(call(method, input)) end)

    Process.put(:pl_callers, [caller | Process.get(:pl_callers)])
    await_github()
    changed = Enum.uniq(Process.get(:pl_changed) ++ Enum.reject(milestones, &is_nil/1))
    Process.put(:pl_changed, Enum.sort(changed))
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

        if word == "no" do
          Process.put(:pl_refused, true)
          Process.put(:pl_changed, [])
        end

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

  # The plugin restarts, its changes on the way to GitHub going on, and returns once it
  # has looked at GitHub, which it does on starting, as `look/0` has GitHub list each issue.
  def restart do
    rules(github())
    {:ok, _} = HalC2.Plugins.handle("restart", %{"id" => @id})
    drain()
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

      {:DOWN, ref, :process, pid, answer} ->
        if {pid, ref} in callers do
          Process.put(:pl_callers, List.delete(callers, {pid, ref}))

          case answer do
            {:ok, _} -> :ok
            # A link or an unlink reads its task again once GitHub answers, removed by then.
            {:error, %{"message" => "planner: There is no task " <> _}} -> :ok
            _ -> problem("a call failed: #{inspect(answer)}")
          end
        else
          await_github()
        end
    after
      15_000 -> problem("a move neither reached GitHub nor ended")
    end
  end

  # What the model checks: which issue the plan has each task name and which milestone
  # it has it in, where GitHub has each issue, and which items are marked as not synced
  # or waiting on GitHub.
  defp observe do
    plan = plan()

    tasks =
      for {t, id} <- Process.get(:pl_tasks),
          item = Enum.find(plan["items"], &(&1["id"] == id)),
          into: %{} do
        holders =
          for %{"milestone" => %{"number" => number}} = held <- plan["items"],
              id in held["after"],
              do: number

        at =
          case holders do
            [] -> nil
            [number] -> number
            many -> many
          end

        {t, %{issue: get_in(item, ["issue", "number"]), at: at}}
      end

    {items, _details} = GenServer.call(@server, :looking)

    marked =
      for {_, item} <- items,
          item["synced"] != nil or item["syncError"] != nil,
          do: item["title"]

    %{
      tasks: tasks,
      github: github(),
      marked: marked,
      refused: Process.get(:pl_refused),
      changed: Process.get(:pl_changed),
      problems: Process.put(:pl_problems, []) |> Enum.reverse()
    }
  end

  # Issue → the milestone GitHub took for it last, or the one it started in, if any.
  defp github do
    taken =
      case File.read(Path.join(Process.get(:pl_gh), "taken")) do
        {:ok, text} -> String.split(text, "\n", trim: true)
        {:error, _} -> []
      end

    Enum.reduce(taken, started(), fn line, github ->
      [n, milestone] = String.split(line, " ")
      milestone = if milestone == "null", do: nil, else: String.to_integer(milestone)
      Map.put(github, String.to_integer(n), milestone)
    end)
  end

  defp started, do: Map.new(@issues, &{&1, if(&1 in @tasks, do: &1)})

  defp problem(text), do: Process.put(:pl_problems, [text | Process.get(:pl_problems, [])])

  # Returns once the plugin has no look in flight, and has heard from everything that
  # ended. It waits on the look ending however long a loaded machine takes, so a planner
  # that never settles hangs the case rather than failing it.
  defp drain, do: drain(false)

  defp drain(settled_once) do
    with pid when is_pid(pid) <- Process.whereis(@server),
         {:ok, state} <- get_state(pid) do
      case kids(pid) do
        [] when state.polling == nil ->
          # Once more, for what the processes that just ended told it.
          if settled_once, do: :ok, else: drain(true)

        # A look that ended between the state read and the links read: its `:DOWN` is
        # already queued ahead of the next state read, so this goes round once, not forever.
        [] ->
          drain(false)

        kids ->
          await(kids)
          drain(false)
      end
    else
      _ -> problem("planner is not running")
    end
  end

  defp get_state(pid) do
    {:ok, :sys.get_state(pid, :infinity)}
  catch
    :exit, _ -> :gone
  end

  defp kids(pid) do
    {:parent, parent} = Process.info(pid, :parent)
    {:links, links} = Process.info(pid, :links)
    Enum.filter(links, &(is_pid(&1) and &1 != parent))
  end

  # Waits for the first of `kids` to end. A look that has ended leaves `polling` set
  # until the planner reads its `:DOWN`, which the next state read queues behind.

  defp await([kid | _]) do
    ref = Process.monitor(kid)
    receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
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
    rules(started())
    Process.put(:pl_held, [])
    Process.put(:pl_callers, [])
    Process.put(:pl_problems, [])
    Process.put(:pl_refused, false)
    Process.put(:pl_changed, [])

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

    items = plan()["items"]

    Process.put(
      :pl_tasks,
      Map.new(@tasks, fn t ->
        {t, Enum.find(items, &match?(%{"issue" => %{"number" => ^t}}, &1))["id"]}
      end)
    )

    Process.put(:pl_problems, [])
  end

  # The fake GitHub's rules, with each issue in the milestone `github` has it in: a move
  # waits on the case (see `begin_case/0`), and a read or list says where each issue is.
  # Only the issues tasks start with are listed: the list is read until a task leaves
  # its issue, and issue 4 would become a task of its own.
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
              "nodes" => Enum.map(@tasks, &issue_node(&1, github[&1]))
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
    # The callers end first, and for good. Left to find the plugin gone they would go on
    # telling it how their pushes went for 30 seconds (`report/6` in the plugin), reach
    # the next case's plugin, and run their next pushes under that case's rules and log.
    for {pid, ref} <- Process.get(:pl_callers) do
      Process.exit(pid, :kill)
      receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
    end

    HalC2.Prop.stop_services()
    # With no caller to go on, the moves GitHub still holds are answered so each gh ends.
    # Not File.write!: a gh already gone with its caller leaves a fifo with no reader, and
    # opening that blocks for good.
    for gate <- Process.get(:pl_held) do
      System.cmd("timeout", ["5", "sh", "-c", "echo go > '#{gate}'"])
    end

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
