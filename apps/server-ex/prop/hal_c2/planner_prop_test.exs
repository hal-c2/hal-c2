defmodule HalC2.PlannerPropTest do
  @moduledoc """
  A state machine model of the planner plugin's MC process (`plugins/planner/mc`),
  loaded and enabled through `HalC2.Plugins` as a user installs it, with the fake
  Codex, whose turns stay open until the model ends them.

  Three tasks (`a`, `b`, `c`) are added, nested, made to wait for each other and
  removed. Two actions on the whole plan run: one whose changes wait for the user and
  one that applies them itself. The commands start runs, report through the agent
  tool (nothing, a task's new due date, the plan's health), end turns, retry, dismiss,
  apply and discard runs, and restart the plugin. After every step:

  - nothing waits for itself, a removed task's subtasks move up to its parent and
    nothing waits for it any more;
  - at most two runs run at once, the oldest queued starts first, and each run that
    started has a thread of its own;
  - a report goes to an action that can still take one, changes wait for the user or
    apply at once as the action says, and a change to a task removed since is marked
    stale rather than applied;
  - a run is failed when its turn ends without a report or the plugin restarts under
    it, and only a failed run is tried again;
  - the `plan` and `runs` the plugin answers match the model, and the topics clients
    follow match what it answers.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  @id "planner"
  @server HalC2Plugins.Planner
  @package Path.expand("../../../../plugins/planner", __DIR__)
  @support Path.expand("../../test/support", __DIR__)
  @slots ~w(a b c)
  @due "2026-10-30"
  @moved "2026-11-06"
  @concurrency 2
  @actions %{
    "propose" => %{
      "label" => "Propose",
      "scope" => "plan",
      "kind" => "action",
      "apply" => "propose",
      "prompt" => "Look at {{plan}}. answer from gate"
    },
    "auto" => %{
      "label" => "Auto",
      "scope" => "plan",
      "kind" => "action",
      "apply" => "apply",
      "prompt" => "Fix {{plan}}. answer from gate"
    }
  }

  setup_all do
    vars = ~w(FAKE_CODEX_GATE GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0)
    previous_vars = Map.new(vars, &{&1, System.get_env(&1)})
    apps = ~w(codex_command settings_check_ms home planner_today)a
    previous_apps = Map.new(apps, &{&1, Application.fetch_env(:hal_c2, &1)})

    for var <- ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0),
        do: System.delete_env(var)

    Application.put_env(:hal_c2, :codex_command, [
      "python3",
      "-u",
      Path.join(@support, "fake_codex.py")
    ])

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
    end)

    :ok
  end

  property "the planner keeps its plan whole and runs each action once, as many at a time as it may",
    numtests: HalC2.Prop.numtests(30),
    max_size: 40 do
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

  # `items`: slot → %{parent, after (slots, in order), due}. `runs`: k (the order it
  # was asked for, from 1) → %{action, status, seq (order queued), started (it got a
  # thread at least once), changes ([{slot, gen, dismissed, outcome}]), health}; a
  # discarded run is gone from it. `gens`: slot → how many times a task was added in it,
  # so a change to a removed task is not taken for one to the task added in its place.
  # `updates`: how many status updates the plan has.
  def initial_state, do: %{items: %{}, gens: %{}, runs: %{}, asked: 0, seq: 0, updates: 0}

  def command(m) do
    slot = elements(@slots)
    present = Map.keys(m.items)
    item = if present == [], do: slot, else: frequency([{4, elements(present)}, {1, slot}])
    parent = oneof([nil | if(present == [], do: [], else: [elements(present)])])
    started = for {k, %{started: true}} <- m.runs, do: k
    asked = Enum.to_list(1..max(m.asked, 1))

    ([
       {4, {:call, __MODULE__, :add, [slot, parent]}},
       {4, {:call, __MODULE__, :wait, [item, item]}},
       {2, {:call, __MODULE__, :remove, [item]}},
       {4, {:call, __MODULE__, :run, [oneof(["propose", "auto"])]}},
       {1, {:call, __MODULE__, :restart, []}}
     ] ++
       if(m.asked > 0,
         do: [
           {2, {:call, __MODULE__, :retry, [elements(asked)]}},
           {3, {:call, __MODULE__, :apply, [elements(asked)]}},
           {2, {:call, __MODULE__, :dismiss, [elements(asked), boolean()]}},
           {2, {:call, __MODULE__, :discard, [elements(asked)]}}
         ],
         else: []
       ) ++
       if(started != [],
         do: [
           {6,
            {:call, __MODULE__, :report,
             [elements(started), oneof([:nothing, :health, {:due, item}])]}},
           {2,
            {:call, __MODULE__, :turn_finished,
             [elements(started), oneof(~w(completed interrupted))]}}
         ],
         else: []
       ))
    |> frequency()
  end

  def precondition(m, {:call, _, :add, [slot, parent]}),
    do: not Map.has_key?(m.items, slot) and (parent == nil or Map.has_key?(m.items, parent))

  def precondition(m, {:call, _, cmd, [slot | _]}) when cmd in [:remove, :wait],
    do: Map.has_key?(m.items, slot)

  def precondition(m, {:call, _, cmd, [k | _]}) when cmd in [:report, :turn_finished],
    do: match?(%{started: true}, m.runs[k])

  def precondition(m, {:call, _, cmd, [k | _]}) when cmd in [:retry, :apply, :dismiss, :discard],
    do: k <= m.asked

  def precondition(_m, _call), do: true

  def next_state(m, _result, call), do: m |> step(call) |> elem(0)

  def postcondition(m, call, observed) do
    {m, reply} = step(m, call)
    expected = %{reply: reply, items: m.items, runs: view(m), updates: m.updates, problems: []}

    if observed != expected do
      for {field, value} <- expected, observed[field] != value do
        IO.puts(
          "#{inspect(call)}: #{field} expected #{inspect(value, limit: :infinity)}, " <>
            "got #{inspect(observed[field], limit: :infinity)}"
        )
      end
    end

    observed == expected
  end

  # `{model after call, the reply it expects}`: :ok or :error.
  defp step(m, {:call, _, :add, [slot, parent]}) do
    m = %{m | gens: Map.update(m.gens, slot, 1, &(&1 + 1))}
    {put_in(m.items[slot], %{parent: parent, after: [], due: @due}), :ok}
  end

  defp step(m, {:call, _, :wait, [slot, other]}) do
    after_slots = Enum.uniq(m.items[slot].after ++ [other])

    cond do
      not Map.has_key?(m.items, other) -> {m, :error}
      other == slot or reaches?(m.items, [other], slot) -> {m, :error}
      true -> {put_in(m.items[slot].after, after_slots), :ok}
    end
  end

  defp step(m, {:call, _, :remove, [slot]}) do
    {removed, items} = Map.pop(m.items, slot)

    items =
      Map.new(items, fn {key, item} ->
        parent = if item.parent == slot, do: removed.parent, else: item.parent
        {key, %{item | parent: parent, after: List.delete(item.after, slot)}}
      end)

    {%{m | items: items}, :ok}
  end

  defp step(m, {:call, _, :run, [action]}) do
    k = m.asked + 1
    run = %{action: action, status: :queued, seq: nil, started: false, changes: [], health: nil}
    m = %{m | asked: k, runs: Map.put(m.runs, k, run)}
    {m |> queue(k) |> pump(), :ok}
  end

  defp step(m, {:call, _, :retry, [k]}) do
    case m.runs[k] do
      %{status: :failed} -> {m |> queue(k) |> pump(), :ok}
      _ -> {m, :error}
    end
  end

  defp step(m, {:call, _, :report, [k, kind]}) do
    run = m.runs[k]

    cond do
      run.status not in [:running, :failed, :proposed] ->
        {m, :error}

      match?({:due, _}, kind) and not Map.has_key?(m.items, elem(kind, 1)) ->
        {m, :error}

      true ->
        changes =
          with {:due, slot} <- kind, do: [{slot, m.gens[slot], false, nil}], else: (_ -> [])

        health = if kind == :health, do: "at-risk"
        run = %{run | changes: changes, health: health}

        cond do
          changes == [] and health == nil ->
            {m |> put_run(k, %{run | status: :done}) |> pump(), :ok}

          run.action == "auto" ->
            {m |> put_run(k, run) |> apply_run(k) |> pump(), :ok}

          true ->
            {m |> put_run(k, %{run | status: :proposed}) |> pump(), :ok}
        end
    end
  end

  defp step(m, {:call, _, :turn_finished, [k, _status]}) do
    case m.runs[k] do
      %{status: :running} = run -> {m |> put_run(k, %{run | status: :failed}) |> pump(), :ok}
      _ -> {m, :ok}
    end
  end

  defp step(m, {:call, _, :apply, [k]}) do
    case m.runs[k] do
      %{status: :proposed} -> {apply_run(m, k), :ok}
      _ -> {m, :error}
    end
  end

  defp step(m, {:call, _, :dismiss, [k, flag]}) do
    case m.runs[k] do
      %{status: :proposed, changes: [{slot, gen, _, outcome} | rest]} = run ->
        {put_run(m, k, %{run | changes: [{slot, gen, flag, outcome} | rest]}), :ok}

      _ ->
        {m, :error}
    end
  end

  defp step(m, {:call, _, :discard, [k]}) do
    case m.runs[k] do
      nil -> {m, :error}
      %{status: :running} -> {m, :error}
      _ -> {pump(%{m | runs: Map.delete(m.runs, k)}), :ok}
    end
  end

  # Starts again from what it saved: what ran is failed, and what waits starts.
  defp step(m, {:call, _, :restart, []}) do
    runs =
      Map.new(m.runs, fn {k, run} ->
        {k, if(run.status == :running, do: %{run | status: :failed}, else: run)}
      end)

    {pump(%{m | runs: runs}), :ok}
  end

  defp put_run(m, k, run), do: %{m | runs: Map.put(m.runs, k, run)}

  defp queue(m, k) do
    run = %{m.runs[k] | status: :queued, seq: m.seq + 1, changes: [], health: nil}
    %{put_run(m, k, run) | seq: m.seq + 1}
  end

  # Starts queued runs, oldest first, while fewer than `@concurrency` run.
  defp pump(m) do
    running = Enum.count(m.runs, fn {_, run} -> run.status == :running end)

    m.runs
    |> Enum.filter(fn {_, run} -> run.status == :queued end)
    |> Enum.sort_by(fn {_, run} -> run.seq end)
    |> Enum.take(max(@concurrency - running, 0))
    |> Enum.reduce(m, fn {k, run}, m ->
      put_run(m, k, %{run | status: :running, started: true})
    end)
  end

  # The changes the user kept, in order: a task still there gets its new due date, one
  # removed since is stale. A run with a health adds an update.
  defp apply_run(m, k) do
    run = m.runs[k]

    {items, changes} =
      Enum.map_reduce(run.changes, m.items, fn
        {slot, gen, true, outcome}, items ->
          {{slot, gen, true, outcome}, items}

        {slot, gen, false, _}, items ->
          if Map.has_key?(items, slot) and m.gens[slot] == gen,
            do: {{slot, gen, false, :applied}, put_in(items[slot].due, @moved)},
            else: {{slot, gen, false, :stale}, items}
      end)
      |> then(fn {changes, items} -> {items, changes} end)

    m = put_run(%{m | items: items}, k, %{run | status: :applied, changes: changes})
    if run.health, do: %{m | updates: m.updates + 1}, else: m
  end

  defp reaches?(items, slots, target, seen \\ MapSet.new())
  defp reaches?(_items, [], _target, _seen), do: false

  defp reaches?(items, [slot | rest], target, seen) do
    cond do
      slot == target -> true
      MapSet.member?(seen, slot) -> reaches?(items, rest, target, seen)
      true -> reaches?(items, items[slot].after ++ rest, target, MapSet.put(seen, slot))
    end
  end

  defp view(m) do
    Map.new(m.runs, fn {k, run} ->
      changes =
        for {slot, _gen, dismissed, outcome} <- run.changes, do: {slot, dismissed, outcome}

      {k, {run.action, run.status, run.status != :queued, changes}}
    end)
  end

  # --- commands ---------------------------------------------------------------------------

  def add(slot, parent) do
    fields = %{"title" => slot, "due" => @due, "parent" => parent && item_id(parent)}
    {reply, value} = call("addItem", %{"fields" => fields})

    if reply == :ok do
      id = value["item"]["id"]
      Process.put(:pl_items, Map.put(Process.get(:pl_items), slot, id))
      Process.put(:pl_ids, Map.put(Process.get(:pl_ids), id, slot))
    end

    observe(reply)
  end

  def wait(slot, other) do
    after_ids = Enum.uniq(item(slot)["after"] ++ [item_id(other)])

    observe(
      elem(call("updateItem", %{"id" => item_id(slot), "fields" => %{"after" => after_ids}}), 0)
    )
  end

  def remove(slot) do
    {reply, _} = call("removeItem", %{"id" => item_id(slot)})
    Process.put(:pl_items, Map.delete(Process.get(:pl_items), slot))
    observe(reply)
  end

  def run(action) do
    {reply, value} = call("run", %{"action" => action, "itemIds" => []})
    if reply == :ok, do: Process.put(:pl_runs, Process.get(:pl_runs) ++ [value["run"]["id"]])
    observe(reply)
  end

  def retry(k), do: observe(elem(call("retry", %{"runId" => run_id(k)}), 0))
  def apply(k), do: observe(elem(call("apply", %{"runId" => run_id(k)}), 0))

  def dismiss(k, flag),
    do:
      observe(
        elem(
          call("dismissChange", %{"runId" => run_id(k), "changeId" => "c1", "dismissed" => flag}),
          0
        )
      )

  def discard(k), do: observe(elem(call("discard", %{"runId" => run_id(k)}), 0))

  def report(k, kind) do
    arguments =
      case kind do
        :nothing ->
          %{"summary" => "Nothing to change."}

        :health ->
          %{"summary" => "Schema is behind.", "health" => "at-risk"}

        {:due, slot} ->
          id = Map.get(Process.get(:pl_items), slot, "gone-#{slot}")

          %{
            "summary" => "Later.",
            "changes" => [%{"op" => "update", "itemId" => id, "fields" => %{"due" => @moved}}]
          }
      end

    observe(reply(HalC2.Plugins.call_tool("planner_report", arguments, thread_of(k))))
  end

  def turn_finished(k, status) do
    event = %{"type" => "turn.finished", "threadId" => thread_of(k), "status" => status}
    # Compiled when the plugin starts, so unknown to the compiler here.
    Kernel.apply(@server, :handle_event, [event, %{}])
    observe(:ok)
  end

  def restart do
    before = Process.whereis(@server)
    reply = reply(HalC2.Plugins.handle("restart", %{"id" => @id}))
    if Process.whereis(@server) in [nil, before], do: problem("planner was not restarted")
    observe(reply)
  end

  defp call(method, input) do
    case HalC2.Plugins.handle("call", %{"id" => @id, "method" => method, "input" => input}) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, nil}
      {:error, _, _} -> {:error, nil}
    end
  end

  defp reply({:ok, _}), do: :ok
  defp reply(:ok), do: :ok
  defp reply({:error, _}), do: :error
  defp reply({:error, _, _}), do: :error
  # The thread of a run that takes no more reports is not offered the tool at all.
  defp reply(nil), do: :error

  defp item_id(slot), do: Map.get(Process.get(:pl_items), slot, "gone-#{slot}")
  defp item(slot), do: Enum.find(plan()["items"], &(&1["id"] == item_id(slot)))
  defp run_id(k), do: Enum.at(Process.get(:pl_runs), k - 1, "gone-#{k}")

  # The thread a run has now, or the last it had before it was queued again.
  defp thread_of(k) do
    id = run_id(k)
    thread = Enum.find_value(runs(), &(&1["id"] == id && &1["threadId"]))
    if thread, do: Process.put({:pl_thread, k}, thread)
    Process.get({:pl_thread, k})
  end

  defp plan do
    {:ok, plan} = call("plan", %{})
    plan
  end

  defp runs do
    {:ok, %{"runs" => runs}} = call("runs", %{})
    runs
  end

  # --- observing --------------------------------------------------------------------------

  # Waits for the plugin to settle, then reads what the model checks.
  defp observe(reply) do
    drain()
    # The plugin publishes through a cast to the host, which sends to watchers.
    :sys.get_state(HalC2.Plugins)
    take_messages()
    plan = plan()
    runs = runs()
    by_id = Map.new(plan["items"], &{&1["id"], &1})
    slots = Map.new(Process.get(:pl_items), fn {slot, id} -> {id, slot} end)

    if Process.get({:pl_topic, "plan"}) != plan, do: problem("the plan topic is behind")

    if Process.get({:pl_topic, "runs"}) != %{"runs" => runs},
      do: problem("the runs topic is behind")

    unknown = Enum.reject(Map.keys(by_id), &Map.has_key?(slots, &1))
    if unknown != [], do: problem("the plan has tasks nobody added: #{inspect(unknown)}")

    items =
      for {id, slot} <- slots, item = by_id[id], into: %{} do
        {slot,
         %{
           parent: slots[item["parent"]],
           after: Enum.map(item["after"], &slots[&1]),
           due: item["due"]
         }}
      end

    missing = for {id, slot} <- slots, not Map.has_key?(by_id, id), do: slot
    if missing != [], do: problem("tasks went missing: #{inspect(missing)}")

    order = Process.get(:pl_runs)

    view =
      for run <- runs, into: %{} do
        k = Enum.find_index(order, &(&1 == run["id"])) + 1
        thread = run["threadId"]
        if thread && not thread?(thread), do: problem("the run #{k} has no thread #{thread}")

        changes =
          for c <- run["changes"] || [] do
            {Process.get(:pl_ids)[c["itemId"]], c["dismissed"] == true,
             c["outcome"] && String.to_existing_atom(c["outcome"])}
          end

        {k, {run["action"], String.to_existing_atom(run["status"]), thread != nil, changes}}
      end

    %{
      reply: reply,
      items: items,
      runs: view,
      updates: length(plan["updates"]),
      problems: Process.put(:pl_problems, []) |> Enum.reverse()
    }
  end

  defp thread?(tid) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))
    HalC2.StreamState.get(state, "thread")[tid] != nil
  end

  defp take_messages do
    receive do
      {:hal_c2_plugin_topic, _, @id, topic, value} ->
        Process.put({:pl_topic, topic}, value)
        take_messages()

      _ ->
        take_messages()
    after
      0 -> :ok
    end
  end

  defp problem(text), do: Process.put(:pl_problems, [text | Process.get(:pl_problems, [])])

  # --- settling -------------------------------------------------------------------------

  # Returns once the plugin has no thread start or look in flight, and has heard from
  # everything that ended.
  defp drain, do: drain(System.monotonic_time(:millisecond) + 15_000, false)

  defp drain(deadline, settled_once) do
    with pid when is_pid(pid) <- Process.whereis(@server),
         {:ok, state} <- get_state(pid) do
      kids = kids(pid)

      cond do
        System.monotonic_time(:millisecond) > deadline ->
          problem("planner never settled: #{length(kids)} processes")

        kids == [] and state.polling == nil ->
          # Once more, for what the processes that just ended told it.
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
    home = HalC2.Prop.scratch_home("planner")
    gate = Path.join(home, "codex-gate")
    File.mkdir_p!(gate)
    System.put_env("FAKE_CODEX_GATE", gate)

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

    Process.put(:pl_items, %{})
    Process.put(:pl_ids, %{})
    Process.put(:pl_runs, [])
    Process.put(:pl_problems, [])

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
          "provider" => "codex",
          "model" => "fake/one",
          "pollMinutes" => 60,
          "concurrency" => @concurrency,
          "defaultProject" => "api",
          "actions" => @actions
        }
      })

    for topic <- ~w(plan runs) do
      {:ok, last} = HalC2.Plugins.subscribe_topic(self(), @id, topic)
      Process.put({:pl_topic, topic}, last)
    end

    drain()
    :sys.get_state(HalC2.Plugins)
    take_messages()
    Process.put(:pl_problems, [])
  end

  defp end_case do
    HalC2.Prop.stop_services()
    # The fake Codex turns still open end, and their processes with them.
    File.write(Path.join(System.get_env("FAKE_CODEX_GATE"), "answer"), "")
    take_messages()
  end

  defp git!(dir, args) do
    {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end
end
