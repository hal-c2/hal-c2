defmodule HalC2.PlannerPropTest do
  @moduledoc """
  A state machine model of the planner plugin's MC process (`plugins/planner/mc`),
  loaded and enabled through `HalC2.Plugins` as a user installs it, with the fake
  Codex, whose turns stay open until the model ends them, and the fake GitHub
  (`test/support/fake_gh.py`), which holds each rename of a linked task until the
  model answers it.

  Three tasks (`a`, `b`, `c`), any of them a milestone, are added, nested, made to wait
  for each other, moved from one milestone to another and removed. Two actions on the whole plan run: one whose changes wait for the user and
  one that applies them itself; a third, like the first, runs on one task. The commands
  start runs, report through the agent tool (nothing, a task's new due date, the plan's
  health), end turns, retry, dismiss, apply and discard runs, and restart the plugin. One task at a time is linked to an
  issue of a repository the plan syncs both ways, with a board, and unlinked again;
  renaming it also moves its due date, pushing both to GitHub from a caller of its own,
  and GitHub takes or refuses those pushes in any order. A push for a task not yet on the
  board adds it there, and GitHub names the board item after the push. Work on a task starts on a project the MC does not have, so its thread
  never launches. After every step:

  - nothing waits for itself, a removed task's subtasks move up to its parent and
    nothing waits for it any more;
  - a task moved between milestones leaves the one and joins the other in one step,
    or neither when either is not a milestone or it would wait for itself;
  - at most two runs run at once, the oldest queued starts first, and each run that
    started has a thread of its own; a run whose task was removed while it waited
    fails instead of starting;
  - a report goes to an action that can still take one, changes wait for the user or
    apply at once as the action says, and a change to a task removed since is marked
    stale rather than applied;
  - a run is failed when its turn ends without a report or the plugin restarts under
    it, and only a failed run is tried again;
  - a linked task's sync error is what its latest push answered: an older push that
    finishes after it leaves it alone, a change GitHub takes without being asked
    anything clears it, and a push in flight when the task was unlinked or the plugin
    restarted says nothing;
  - a linked task's board item is the one its latest push added: an older push, or one
    answered after the task was unlinked, leaves it alone, and unlinking clears it;
  - work that could not start leaves its task as it was, not started and linked to no
    thread;
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
  @repository "acme/api"
  @issues %{"a" => 1, "b" => 2, "c" => 3}
  @due "2026-10-30"
  @moved "2026-11-06"
  @board "acme/3"
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
    },
    "check" => %{
      "label" => "Check",
      "scope" => "item",
      "kind" => "action",
      "apply" => "propose",
      "prompt" => "Check {{item.title}}. answer from gate"
    },
    "work" => %{
      "label" => "Work",
      "scope" => "item",
      "kind" => "work",
      "apply" => "apply",
      "prompt" => "Work on {{item.title}}."
    }
  }

  setup_all do
    vars =
      ~w(PATH FAKE_GH_RULES FAKE_GH_LOG FAKE_CODEX_GATE GIT_CONFIG_COUNT GIT_CONFIG_KEY_0
         GIT_CONFIG_VALUE_0)

    previous_vars = Map.new(vars, &{&1, System.get_env(&1)})
    apps = ~w(gh_command codex_command settings_check_ms home planner_today)a
    previous_apps = Map.new(apps, &{&1, Application.fetch_env(:hal_c2, &1)})

    for var <- ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0),
        do: System.delete_env(var)

    # Every gh the MC runs is the fake, answering from the rules of the case.
    bin = Path.expand("../../tmp/prop/planner-gh-#{System.pid()}", __DIR__)
    File.rm_rf!(bin)
    File.mkdir_p!(bin)
    File.ln_s!(Path.join(@support, "fake_gh.py"), Path.join(bin, "gh"))
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    Application.put_env(:hal_c2, :gh_command, "gh")

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

      File.rm_rf!(bin)
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

  # `items`: slot → %{kind (:task or :milestone), parent, after (slots, in order), due, linked (to its issue), sync
  # (its sync error: nil or {:refused, push}), board (the push that added its board item,
  # 0 for one that took at once, or nil)}. `runs`: k (the order it was asked for,
  # from 1) → %{action, on ({slot, gen} of the task it runs on, or nil), gone (it failed
  # without a thread since its task was removed while it waited), status, seq
  # (order queued), started (its thread started at least once), changes ([{slot, gen, dismissed, outcome}]), health}; a discarded run is gone
  # from it. `gens`: slot → how many times a task was added in it, so a change to a
  # removed task is not taken for one to the task added in its place. `updates`: how
  # many status updates the plan has. `pushes`: the last push a rename made (renames
  # push one at a time, numbered); `latest`: slot → {gen, push} for the push that says
  # whether the task synced, `:now` for one that took at once; `held`: push → {slot,
  # gen, :ok | :refused, adds} for the renames GitHub has not answered, how it will, and
  # whether the push adds the task to the board.
  def initial_state,
    do: %{
      items: %{},
      gens: %{},
      runs: %{},
      asked: 0,
      seq: 0,
      updates: 0,
      pushes: 0,
      latest: %{},
      held: %{}
    }

  def command(m) do
    slot = elements(@slots)
    present = Map.keys(m.items)
    item = if present == [], do: slot, else: frequency([{4, elements(present)}, {1, slot}])
    parent = oneof([nil | if(present == [], do: [], else: [elements(present)])])
    started = for {k, %{started: true}} <- m.runs, do: k
    asked = Enum.to_list(1..max(m.asked, 1))
    linked = for {slot, %{linked: true}} <- m.items, do: slot

    ([
       {4, {:call, __MODULE__, :add, [slot, parent, frequency([{3, :task}, {1, :milestone}])]}},
       {4, {:call, __MODULE__, :wait, [item, item]}},
       {2, {:call, __MODULE__, :move, [item, oneof([nil, item]), oneof([nil, item])]}},
       {2, {:call, __MODULE__, :remove, [item]}},
       {4, {:call, __MODULE__, :run, [oneof(["propose", "auto"]), nil]}},
       {2, {:call, __MODULE__, :run, ["check", item]}},
       {2, {:call, __MODULE__, :work, [item]}},
       {1, {:call, __MODULE__, :restart, []}}
     ] ++
       if(linked == [],
         do: [{4, {:call, __MODULE__, :link, [item]}}],
         else: [
           {8,
            {:call, __MODULE__, :rename, [elements(linked), oneof([:ok, :refused]), m.pushes + 1]}},
           {1, {:call, __MODULE__, :unlink, [elements(linked)]}}
         ]
       ) ++
       if(m.held != %{},
         do: [{10, {:call, __MODULE__, :answer, [elements(Map.keys(m.held))]}}],
         else: []
       ) ++
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

  def precondition(m, {:call, _, :add, [slot, parent, _kind]}),
    do: not Map.has_key?(m.items, slot) and (parent == nil or Map.has_key?(m.items, parent))

  def precondition(m, {:call, _, cmd, [slot | _]}) when cmd in [:remove, :wait, :move, :work],
    do: Map.has_key?(m.items, slot)

  def precondition(m, {:call, _, :run, [_action, slot]}),
    do: slot == nil or Map.has_key?(m.items, slot)

  # One task is linked at a time, so no push asks GitHub to relate two issues.
  def precondition(m, {:call, _, :link, [slot]}),
    do: Map.has_key?(m.items, slot) and not Enum.any?(m.items, fn {_, item} -> item.linked end)

  def precondition(m, {:call, _, :unlink, [slot]}), do: match?(%{linked: true}, m.items[slot])

  # A rename names its push, so the push's gate and name stay its own when shrinking.
  def precondition(m, {:call, _, :rename, [slot, _outcome, push]}),
    do: match?(%{linked: true}, m.items[slot]) and push > m.pushes

  def precondition(m, {:call, _, :answer, [push]}), do: Map.has_key?(m.held, push)

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
  defp step(m, {:call, _, :add, [slot, parent, kind]}) do
    m = %{m | gens: Map.update(m.gens, slot, 1, &(&1 + 1))}

    item = %{
      kind: kind,
      parent: parent,
      after: [],
      due: @due,
      linked: false,
      sync: nil,
      board: nil
    }

    {put_in(m.items[slot], item), :ok}
  end

  defp step(m, {:call, _, :wait, [slot, other]}) do
    after_slots = Enum.uniq(m.items[slot].after ++ [other])

    cond do
      not Map.has_key?(m.items, other) -> {m, :error}
      other == slot or reaches?(m.items, [other], slot) -> {m, :error}
      after_slots == m.items[slot].after -> {m, :ok}
      true -> {m |> put_in([:items, slot, :after], after_slots) |> pushed(slot), :ok}
    end
  end

  # `slot` stops holding up the milestone `from` and holds up `to`; nil is no milestone.
  defp step(m, {:call, _, :move, [slot, from, to]}) do
    milestone? = &(&1 == nil or match?(%{kind: :milestone}, m.items[&1]))

    if milestone?.(from) and milestone?.(to) do
      items = m.items
      items = if from, do: update_in(items[from].after, &List.delete(&1, slot)), else: items
      items = if to, do: update_in(items[to].after, &Enum.uniq(&1 ++ [slot])), else: items

      if to != nil and (to == slot or reaches?(items, [slot], to)),
        do: {m, :error},
        else: {Enum.reduce([from, to], %{m | items: items}, &moved(&2, &1, m.items)), :ok}
    else
      {m, :error}
    end
  end

  defp step(m, {:call, _, :remove, [slot]}) do
    {removed, items} = Map.pop(m.items, slot)

    changed =
      for {key, item} <- items, item.parent == slot or slot in item.after, do: key

    items =
      Map.new(items, fn {key, item} ->
        parent = if item.parent == slot, do: removed.parent, else: item.parent
        {key, %{item | parent: parent, after: List.delete(item.after, slot)}}
      end)

    {Enum.reduce(changed, %{m | items: items}, &pushed(&2, &1)), :ok}
  end

  defp step(m, {:call, _, :run, [action, slot]}), do: {ask(m, action, slot), :ok}
  defp step(m, {:call, _, :work, [slot]}), do: {ask(m, "work", slot), :ok}

  defp step(m, {:call, _, :link, [slot]}),
    do: {m |> put_in([:items, slot, :linked], true) |> pushed(slot), :ok}

  # Nothing in flight speaks for a task no longer linked.
  defp step(m, {:call, _, :unlink, [slot]}) do
    item = %{m.items[slot] | linked: false, sync: nil, board: nil}
    {%{put_in(m.items[slot], item) | latest: Map.delete(m.latest, slot)}, :ok}
  end

  # The rename waits for GitHub, which will answer `outcome`; until then the task's sync
  # error and board item stay as they were.
  defp step(m, {:call, _, :rename, [slot, outcome, push]}) do
    gen = m.gens[slot]
    m = put_in(m.items[slot].due, renamed_due(push))

    {%{
       m
       | pushes: push,
         latest: Map.put(m.latest, slot, {gen, push}),
         held: Map.put(m.held, push, {slot, gen, outcome, m.items[slot].board == nil})
     }, :ok}
  end

  # Only the task's latest push says whether it synced, and what board item it added; a
  # refused rename stops before the board.
  defp step(m, {:call, _, :answer, [push]}) do
    {{slot, gen, outcome, adds}, held} = Map.pop(m.held, push)
    m = %{m | held: held}

    if Map.has_key?(m.items, slot) and m.latest[slot] == {gen, push} do
      item = %{m.items[slot] | sync: if(outcome == :refused, do: {:refused, push})}
      item = if outcome == :ok and adds, do: %{item | board: push}, else: item
      {put_in(m.items[slot], item), :ok}
    else
      {m, :ok}
    end
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

  # Starts again from what it saved: what ran is failed, and what waits starts. It does
  # not know the pushes in flight, so their answers no longer say whether a task synced.
  defp step(m, {:call, _, :restart, []}) do
    runs =
      Map.new(m.runs, fn {k, run} ->
        {k, if(run.status == :running, do: %{run | status: :failed}, else: run)}
      end)

    {pump(%{m | runs: runs, latest: %{}}), :ok}
  end

  defp put_run(m, k, run), do: %{m | runs: Map.put(m.runs, k, run)}

  # Queues a run of `action`, on the task in `slot` when it is given.
  defp ask(m, action, slot) do
    k = m.asked + 1
    on = if slot, do: {slot, m.gens[slot]}

    run = %{
      action: action,
      on: on,
      gone: false,
      status: :queued,
      seq: nil,
      started: false,
      changes: [],
      health: nil
    }

    m = %{m | asked: k, runs: Map.put(m.runs, k, run)}
    m |> queue(k) |> pump()
  end

  # A change to a linked task that asks GitHub nothing: its push takes at once.
  defp pushed(m, slot) do
    case m.items[slot] do
      %{linked: true} ->
        m = %{m | latest: Map.put(m.latest, slot, {m.gens[slot], :now})}
        put_in(m.items[slot].sync, nil)

      _ ->
        m
    end
  end

  # A linked task's new due date goes to the board, adding it there first if it is not on
  # it yet; GitHub names that item 0, as it takes at once.
  defp boarded(m, slot) do
    case m.items[slot] do
      %{linked: true, board: nil} -> put_in(m.items[slot].board, 0)
      _ -> m
    end
  end

  defp renamed_due(push), do: Date.to_iso8601(Date.add(~D[2027-01-01], push))

  defp moved(m, slot, before),
    do: if(slot != nil and m.items[slot] != before[slot], do: pushed(m, slot), else: m)

  defp queue(m, k) do
    run = %{m.runs[k] | status: :queued, gone: false, seq: m.seq + 1, changes: [], health: nil}
    %{put_run(m, k, run) | seq: m.seq + 1}
  end

  # Fails queued runs whose task is gone, then starts the others, oldest first, while
  # fewer than `@concurrency` run. Work never starts its thread, so it fails at once and
  # the next run starts in its place.
  defp pump(m) do
    gone? = fn
      %{on: {slot, gen}} -> not Map.has_key?(m.items, slot) or m.gens[slot] != gen
      _ -> false
    end

    m =
      Enum.reduce(m.runs, m, fn {k, run}, m ->
        if run.status == :queued and gone?.(run),
          do: put_run(m, k, %{run | status: :failed, gone: true}),
          else: m
      end)

    running = Enum.count(m.runs, fn {_, run} -> run.status == :running end)

    starting =
      m.runs
      |> Enum.filter(fn {_, run} -> run.status == :queued end)
      |> Enum.sort_by(fn {_, run} -> run.seq end)
      |> Enum.take(max(@concurrency - running, 0))

    m =
      Enum.reduce(starting, m, fn
        {k, %{action: "work"} = run}, m -> put_run(m, k, %{run | status: :failed})
        {k, run}, m -> put_run(m, k, %{run | status: :running, started: true})
      end)

    if Enum.any?(starting, fn {_, run} -> run.action == "work" end), do: pump(m), else: m
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

    moved = for {slot, item} <- items, m.items[slot].due != item.due, do: slot
    m = Enum.reduce(moved, %{m | items: items}, &(&2 |> pushed(&1) |> boarded(&1)))
    m = put_run(m, k, %{run | status: :applied, changes: changes})
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

      {k, {run.action, run.status, run.status != :queued and not run.gone, changes}}
    end)
  end

  # --- commands ---------------------------------------------------------------------------

  def add(slot, parent, kind) do
    fields = %{
      "title" => slot,
      "kind" => Atom.to_string(kind),
      "due" => @due,
      "parent" => parent && item_id(parent)
    }

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

  def move(slot, from, to) do
    ids = %{"id" => item_id(slot), "from" => from && item_id(from), "to" => to && item_id(to)}
    observe(elem(call("moveToMilestone", ids), 0))
  end

  def remove(slot) do
    {reply, _} = call("removeItem", %{"id" => item_id(slot)})
    Process.put(:pl_items, Map.delete(Process.get(:pl_items), slot))
    observe(reply)
  end

  def run(action, slot) do
    ids = if slot, do: [item_id(slot)], else: []
    {reply, value} = call("run", %{"action" => action, "itemIds" => ids})
    if reply == :ok, do: Process.put(:pl_runs, Process.get(:pl_runs) ++ [value["run"]["id"]])
    observe(reply)
  end

  # Work on a project the MC does not have, whose thread cannot launch.
  def work(slot) do
    input = %{"action" => "work", "itemIds" => [item_id(slot)], "projectId" => "nowhere"}
    {reply, value} = call("run", input)
    if reply == :ok, do: Process.put(:pl_runs, Process.get(:pl_runs) ++ [value["run"]["id"]])
    observe(reply)
  end

  def link(slot) do
    issue = %{"repository" => @repository, "number" => @issues[slot]}
    observe(elem(call("link", %{"itemId" => item_id(slot), "issue" => issue}), 0))
  end

  def unlink(slot),
    do: observe(elem(call("unlink", %{"itemId" => item_id(slot), "kind" => "issue"}), 0))

  # Renames the task to a name of the push's own and moves its due date, from a caller
  # of its own as another client's would be. GitHub holds the push until `answer/1` lets
  # it answer `outcome`.
  def rename(slot, outcome, push) do
    title = "#{slot}#{push}"
    gate = gate(push)

    gh_rule(%{
      "args" => ["--method PATCH", "repos/#{@repository}/issues/#{@issues[slot]} "],
      "stdin" => [JSON.encode!(%{"title" => title})],
      "run" => "while [ ! -e '#{gate}' ] && [ -d '#{Path.dirname(gate)}' ]; do sleep 0.01; done",
      "stdout" => "{}",
      "exit" => if(outcome == :ok, do: 0, else: 1),
      "stderr" => if(outcome == :ok, do: "", else: "HTTP 422: refused push #{push}\n")
    })

    input = %{"id" => item_id(slot), "fields" => %{"title" => title, "due" => renamed_due(push)}}

    caller =
      spawn_monitor(fn ->
        try do
          call("updateItem", input)
        catch
          # The plugin stopped with the case.
          :exit, _ -> :ok
        end
      end)

    Process.put({:pl_push, push}, caller)
    await_plan(&Enum.any?(&1["items"], fn item -> item["title"] == title end))
    observe(:ok)
  end

  # GitHub answers the push, naming a board item it adds after it, and its caller tells
  # the planner.
  def answer(push) do
    {pid, ref} = Process.get({:pl_push, push})

    if Process.alive?(pid) do
      gh_rule(board_item(push))
      File.write!(gate(push), "")

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        15_000 -> problem("the push #{push} never finished")
      end

      gh_rule(board_item(0))
    else
      problem("the push #{push} did not wait for GitHub")
    end

    observe(:ok)
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
           kind: String.to_existing_atom(item["kind"]),
           parent: slots[item["parent"]],
           after: Enum.map(item["after"], &slots[&1]),
           due: item["due"],
           linked: item["issue"] != nil,
           sync: sync_error(item["syncError"]),
           board: board_push(item["boardItemId"])
         }}
      end

    # Work never starts in the model, so no task is in progress or linked to a thread.
    for {id, slot} <- slots,
        item = by_id[id],
        item["status"] != "todo" or (item["threads"] || []) != [],
        do: problem("#{slot} is #{item["status"]} with the threads #{inspect(item["threads"])}")

    missing = for {id, slot} <- slots, not Map.has_key?(by_id, id), do: slot
    if missing != [], do: problem("tasks went missing: #{inspect(missing)}")

    order = Process.get(:pl_runs)

    view =
      for run <- runs, into: %{} do
        k = Enum.find_index(order, &(&1 == run["id"])) + 1
        thread = run["threadId"]

        if thread && run["kind"] != "work" && not thread?(thread),
          do: problem("the run #{k} has no thread #{thread}")

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

  # Which push GitHub refused, by the reason the fake gave.
  defp sync_error(nil), do: nil

  defp sync_error(error) do
    case Regex.run(~r/refused push (\d+)/, error) do
      [_, push] -> {:refused, String.to_integer(push)}
      nil -> {:other, error}
    end
  end

  defp board_push(nil), do: nil
  defp board_push("item-" <> push), do: String.to_integer(push)

  defp thread?(tid) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))
    HalC2.StreamState.get(state, "thread")[tid] != nil
  end

  defp take_messages do
    receive do
      {:hal_c2_plugin_topic, _, @id, topic, value} ->
        Process.put({:pl_topic, topic}, value)
        take_messages()

      # A push's caller ending is left for `answer/1`.
      message when elem(message, 0) != :DOWN ->
        take_messages()
    after
      0 -> :ok
    end
  end

  # Takes the plan topic's news until `fun` holds for it.
  defp await_plan(fun) do
    receive do
      {:hal_c2_plugin_topic, _, @id, topic, value} ->
        Process.put({:pl_topic, topic}, value)
        if topic == "plan" and fun.(value), do: :ok, else: await_plan(fun)
    after
      15_000 -> problem("the plan never showed the change")
    end
  end

  defp gate(push), do: Path.join(Process.get(:pl_gh), "go-#{push}")

  # GitHub's answer to adding an issue to the board: the item `item-<push>`.
  defp board_item(push) do
    %{
      "args" => ["api graphql"],
      "stdin" => ["addProjectV2ItemById"],
      "stdout" => %{"data" => %{"addProjectV2ItemById" => %{"item" => %{"id" => "item-#{push}"}}}}
    }
  end

  # Puts `rule` first in the fake gh's rules, in one step so a gh starting meanwhile
  # reads either the old rules or the new.
  defp gh_rule(rule) do
    path = System.get_env("FAKE_GH_RULES")
    rules = [rule | path |> File.read!() |> JSON.decode!()]
    File.write!(path <> ".tmp", JSON.encode!(rules))
    File.rename!(path <> ".tmp", path)
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

    # The project is on GitHub as `@repository`, with the empty board `@board` whose due
    # dates are its "Target date"; gh answers the reads after a push that took, and a push
    # the model holds waits for its gate.
    git!(root, ["remote", "add", "origin", "git@github.com:#{@repository}.git"])
    gh = Path.join(home, "gh")
    File.mkdir_p!(gh)
    Process.put(:pl_gh, gh)
    System.put_env("FAKE_GH_LOG", Path.join(gh, "calls.jsonl"))
    System.put_env("FAKE_GH_RULES", Path.join(gh, "rules.json"))
    issue = %{"number" => 1, "state" => "OPEN", "repository" => %{"nameWithOwner" => @repository}}
    due = %{"id" => "F_due", "name" => "Target date", "dataType" => "DATE"}

    board = %{
      "id" => "PVT_board",
      "title" => "Board",
      "url" => "https://github.com/orgs/acme/projects/3",
      "fields" => %{"nodes" => [due]},
      "items" => %{"pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}, "nodes" => []}
    }

    File.write!(
      Path.join(gh, "rules.json"),
      JSON.encode!([
        board_item(0),
        %{
          "args" => ["api graphql"],
          "stdout" => %{
            "data" => %{
              "repository" => %{"issue" => issue, "issueOrPullRequest" => %{"id" => "I_1"}},
              "repositoryOwner" => %{"projectV2" => board},
              "updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "item-0"}}
            }
          }
        }
      ])
    )

    for {{:pl_push, _} = key, _} <- Process.get(), do: Process.delete(key)
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
          "sync" => "twoWay",
          "board" => @board,
          "targetField" => "Target date",
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
    # So do the pushes GitHub still holds, whose callers find the plugin gone.
    for {{:pl_push, push}, _} <- Process.get(), do: File.write(gate(push), "")
    take_messages()
  end

  defp git!(dir, args) do
    {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end
end
