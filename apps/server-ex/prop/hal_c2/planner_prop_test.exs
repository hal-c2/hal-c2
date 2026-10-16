defmodule HalC2.PlannerPropTest do
  @moduledoc """
  A state machine model of the planner plugin's MC process (`plugins/planner/mc`),
  loaded and enabled through `HalC2.Plugins` as a user installs it, with the fake
  Codex, whose turns stay open until the model ends them, and the fake GitHub
  (`test/support/fake_gh.py`), which holds the first push of a rename of a linked task
  until the model answers it, answers a later push carrying the name the same at once,
  writes down each name it takes and each relation between issues it makes or drops,
  and lists the open issues of the followed repository tasks are linked to, reads a
  closed one alone and lists it among those changed since a time, so a look at GitHub
  brings those tasks' names and states up to date. It keeps each board's items, the issues pushes added to it, and lists them
  when a look reads the board, as one page of what it holds or, once the board holds
  more than a look reads, as the first of more.

  Three tasks (`a`, `b`, `c`), any of them a milestone, are added, nested and moved to
  another parent, made to wait for each other, moved from one milestone to another and
  removed. Two actions on the whole plan run: one whose changes wait for the user and
  one that applies them itself; a third, like the first, runs on one task. The commands
  start runs, report through the agent tool (nothing, a task's new due date, the plan's
  health, a link to two things at once), end turns, retry, dismiss, apply and discard
  runs, look at GitHub, and restart the plugin, which looks too. The plugin keeps
  `@kept_runs` finished runs. Any of the tasks is linked to an issue of a repository the
  plan syncs both ways, with a board, by a client whose link may say a state of its own,
  closed or not text, or has one made for it there, which GitHub relates
  to nothing and puts on no board, is relinked to another issue, of that repository or of one no project on
  the MC has, which is pushed nothing, or to the one it has, which changes nothing, and
  unlinked again, by a client that may still
  show the issue it had before, and a client links one to the issue another has; a
  client moves one's due date, which goes to GitHub at once when nothing of the task is
  on the way, and renaming one also moves its due date, pushing both to GitHub from a
  caller of its own, and renaming it again before GitHub answers pushes nothing until it
  does. GitHub takes or
  refuses a name, and answers the pushes held in any order. A push for a task not yet on
  the board adds it there, and GitHub names the board item after the push. Someone takes
  a linked task's issue off the board, and the board grows past what a look reads whole
  and shrinks back. GitHub closes an issue of that repository as completed or not
  planned, and reopens it. Someone on GitHub makes a linked task's issue a sub-issue of
  another, one a task has or one none has, or of none, or puts an issue under its own
  sub-issue, which takes its place, marks one blocked by another, or by none, or turns
  around the dependency between two, and a client nests a task while a look at GitHub is
  on its way, holding GitHub's list as it was before the nest. Work on a task starts on
  a project the MC does not have, or on one whose worktree setup is not running so the
  launch exits, and its thread never launches. After every step:

  - nothing waits for itself, no task is its own ancestor, a removed task's subtasks move
    up to its parent and nothing waits for it any more;
  - a task with no title, a change whose fields are not an object, or a link to a pull
    request and an issue at once, from a client or in an agent's report, is refused and
    changes nothing, as is a link to an issue another task has;
  - a task moved between milestones leaves the one and joins the other in one step,
    or neither when either is not a milestone or it would wait for itself;
  - at most two runs run at once, the oldest queued starts first, and each run that
    started has a thread of its own; a run whose task was removed while it waited
    fails instead of starting, with no thread, even when it is a retry;
  - a report goes to an action that can still take one, changes wait for the user or
    apply at once as the action says, and a change to a task removed since is marked
    stale rather than applied;
  - a run is failed when its turn ends without a report or the plugin restarts under
    it, and only a failed run is tried again;
  - of the runs that are applied or had nothing to apply, only the `@kept_runs` that
    finished last are kept; the others stay until they are discarded;
  - GitHub has at most one push of a task at a time: a change made while one is on the
    way pushes nothing, and once GitHub answers, the task's caller pushes what the task
    has that GitHub has not, so the name GitHub keeps for an issue is the one that
    reached it last, and a chain of pushes that ends without a refusal leaves GitHub
    with the task's latest name;
  - a linked task's sync error is what the last push of its chain answered, and a push
    on the way when the task was removed, unlinked, relinked or the plugin restarted
    says nothing, though GitHub still takes it;
  - a push sends what the task has that GitHub has not, as far as the plugin knows, and
    only that: a change to a task whose rename GitHub refused sends the name again, as
    GitHub then answers, along with its due date and relations when GitHub does not have
    those either, and a change that leaves GitHub nothing to take sends nothing and
    clears the task's marks;
  - the relations GitHub has between issues are the ones the pushes made and dropped:
    a task waiting for, or a subtask of, another task with an issue is related to that
    issue on GitHub once a push takes, and the relation goes with the next push of the
    task that no longer has it, even when the other task was removed since; a task
    linked to an issue, made for it or not, or relinked to another, has its relations
    made on that issue at once and dropped from the one before, and the tasks tied to it
    move theirs to its new issue at once too, or drop them when it is unlinked, which
    leaves its own on the issue it had;
  - a look at GitHub brings a linked task's name up to date, makes it wait for the tasks
    whose issues GitHub has its open issue blocked by and for no other task with an
    issue, and the subtask of the task whose issue GitHub names as its open issue's
    parent, and of none when GitHub names an issue no task has, all of the tasks'
    together when that makes no task its own ancestor or wait for itself, and otherwise
    each unless that would once the others took theirs,
    and moves its state when its issue's moved since the plugin last read it or a push
    of the task moved it, closing the issue made for a done task, say: closed as
    not planned, the task is dropped, closed otherwise, done, and reopened, a task done
    or dropped is to do again;
    a reason changed on a closed issue counts as a move, a reason on an open one does
    not; none of it when GitHub refused its last change, a push to it is on the way, or
    it changed while the look was on its way;
  - a linked task's board item is the one a push of its chain added, or, with no push of
    it on the way, the one a look found for its issue on the board, whether or not the
    task had one: a push answered after the task was unlinked or relinked leaves it
    alone, though GitHub still puts the issue it named on the board, and unlinking or
    relinking clears it, as does saving the settings with another board, so the next
    push adds it to that one; a look that reads the whole board
    without the task's issue clears it too, so the next push of a date adds the issue
    back, and one that reads only part of the board leaves it as it was;
  - an unlink naming an issue the task no longer has leaves it linked, and one naming no
    issue is refused;
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
  # A repository no project on the MC has, whose issues are numbered from 20 up.
  @elsewhere "acme/web"
  @elsewhere_from 20
  @issues %{"a" => 1, "b" => 2, "c" => 3}
  # An issue of `@repository` no task is ever linked to.
  @unplanned 4
  @bad_ref %{"repository" => 7, "number" => 1}
  @due "2026-10-30"
  @moved "2026-11-06"
  @board "acme/3"
  @other_board "acme/4"
  @concurrency 2
  @kept_runs 1
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

    apps =
      ~w(gh_command codex_command settings_check_ms home planner_today planner_kept_runs
         planner_skew_seconds)a

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
    Application.put_env(:hal_c2, :planner_kept_runs, @kept_runs)
    # The fake GitHub stamps changes by the MC's clock, so a look lists only what changed
    # since the last one began.
    Application.put_env(:hal_c2, :planner_skew_seconds, 0)

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

  # An issue of `@repository`, which pushes go to.
  defguardp here?(n) when is_integer(n) and n < @elsewhere_from

  # `items`: slot → %{name (its title), kind (:task or :milestone), parent, after (slots, in order), due, issue (the number it is linked to, of `@elsewhere` from 20 up, or nil), sync
  # (its sync error: nil or {:refused, push}), board (the push that added its board item,
  # 0 for one that took at once, or nil), status (:todo, :done or :dropped), state (what
  # the plugin keeps of its issue's state: :open, :completed, :not_planned, or nil with
  # no issue)}. `runs`: k (the order it was asked for,
  # from 1) → %{action, on ({slot, gen} of the task it runs on, or nil), gone (it failed
  # without a thread since its task was removed while it waited), status, seq
  # (order queued), started (its thread started at least once), changes ([{slot, gen, dismissed, outcome}]), health,
  # finished (when it was applied or found nothing, counted by `finished`)}; a discarded
  # run, or one too long finished, is gone from it. `gens`: slot → how many times a task was added in it, so a change to a
  # removed task is not taken for one to the task added in its place. `updates`: how
  # many status updates the plan has. `pushes`: the last rename (numbered, its name
  # `<slot><push>`). `flights`: slot → %{gen, push, changed} for the task whose push
  # GitHub holds, the rename that made it and whether the task changed since. `held`:
  # push → %{slot, gen, ops, b} for the pushes GitHub holds, what they ask (see `ops/3`)
  # and what GitHub had of the task (`b`, a baseline as `own/2` makes); one whose flight
  # is gone speaks for nobody, but GitHub still takes it. `outcomes`: name → {push,
  # :ok | :refused}, how GitHub answers every push carrying the name. `synced`: slot → the
  # baseline a push left the task, until a push takes whole; a task with none has all of
  # it on GitHub. `github`: issue → the last name GitHub took for it. `rel`: the
  # relations GitHub has, `{:blocked, {issue, blocker}}` and `{:sub, {parent, child}}`.
  # `board`: the board the settings name. `boards`: board → issue → the push that put it
  # there last (its board item, 0 for one that took at once). `full`: whether the boards
  # hold more than a look reads. `closed`: issue of `@repository` → why GitHub closed
  # it, :completed or :not_planned; one not in it is open. `parents`: issue of
  # `@repository` → the issue GitHub has it as a sub-issue of. `blockers`: issue of
  # `@repository` → the issues GitHub has it blocked by, in the order GitHub lists them.
  def initial_state,
    do: %{
      board: @board,
      boards: %{},
      full: false,
      closed: %{},
      parents: %{},
      blockers: %{},
      items: %{},
      gens: %{},
      runs: %{},
      asked: 0,
      seq: 0,
      finished: 0,
      updates: 0,
      pushes: 0,
      flights: %{},
      held: %{},
      outcomes: %{},
      synced: %{},
      github: %{},
      rel: MapSet.new()
    }

  def command(m) do
    slot = elements(@slots)
    present = Map.keys(m.items)
    item = if present == [], do: slot, else: frequency([{4, elements(present)}, {1, slot}])
    parent = oneof([nil | if(present == [], do: [], else: [elements(present)])])
    started = for {k, %{started: true}} <- m.runs, do: k
    asked = Enum.to_list(1..max(m.asked, 1))
    linked = for {slot, %{issue: n}} <- m.items, n != nil, do: slot
    unlinked = for {slot, %{issue: nil}} <- m.items, do: slot
    # Only a task linked to an issue of `@repository` is pushed anything.
    pushed = for {slot, %{issue: n}} <- m.items, here?(n), do: slot
    # Switching boards matters most once a task is on one.
    switch = if Enum.any?(m.items, fn {_, item} -> item.board != nil end), do: 6, else: 1
    other = if m.board == @board, do: @other_board, else: @board
    # So does relinking: the board item and the pushes in flight are the issue's, not
    # the task's, and the relations of the tasks tied to it move with it.
    tied_to = for slot <- linked, Enum.any?(m.items, fn {_, i} -> tied_to?(i, slot) end), do: slot

    relink =
      if m.held != %{} or tied_to != [] or Enum.any?(linked, &(m.items[&1].board != nil)),
        do: 6,
        else: 1

    # And a change to a task GitHub refused, or has not answered yet, which sends what it
    # has not taken again.
    refused =
      Enum.uniq(for({slot, %{sync: {:refused, _}}} <- m.items, do: slot) ++ Map.keys(m.flights))

    # So does removing a linked task another linked task waits for or is a subtask of,
    # whose relation on GitHub the other's next push drops.
    related =
      for {slot, %{issue: n}} <- m.items,
          n != nil,
          Enum.any?(linked, &(m.items[&1].parent == slot or slot in m.items[&1].after)),
          do: slot

    # A look matters most while a push is on the way, or once GitHub moved an issue a
    # linked task has.
    moved =
      Enum.any?(m.items, fn {_, item} ->
        here?(item.issue) and item.state != Map.get(m.closed, item.issue, :open)
      end)

    # Or once a task's issue left the board it has a board item on.
    listed = Map.get(m.boards, m.board, %{})

    onboard =
      for {slot, %{issue: n, board: b}} <- m.items, b != nil, is_map_key(listed, n), do: slot

    unboarded =
      Enum.any?(m.items, fn {_, i} -> i.board != nil and not is_map_key(listed, i.issue) end)

    # Or once GitHub has issues blocked by others, and relations the tasks do not.
    unheard = m.blockers != %{} and Enum.any?(pushed, &(related(m, &1) != m.items[&1]))

    look =
      cond do
        unboarded -> 30
        moved or unheard -> 10
        m.held != %{} -> 4
        true -> 1
      end

    # A new due date puts a task on the board.
    redate = if Enum.any?(pushed, &(m.items[&1].board == nil)), do: 10, else: 3

    # And closing an issue again for the other reason, once the plan has read it closed.
    reread =
      for {_, %{issue: n, state: state}} <- m.items,
          here?(n) and state in [:completed, :not_planned] and m.closed[n] == state,
          do: {n, if(state == :completed, do: :not_planned, else: :completed)}

    # GitHub moving a sub-issue matters most once two tasks have issues to move between,
    # so the first move comes almost at once, and a nest while a look is on its way once
    # it has moved one.
    adopt =
      cond do
        length(pushed) < 2 -> 2
        m.parents == %{} -> 400
        true -> 4
      end

    looking = if m.parents == %{}, do: 1, else: 16
    # An issue made for a task, which GitHub relates to nothing, matters once the task is
    # tied to others; GitHub never makes a closed one.
    fresh = for slot <- unlinked, not Map.has_key?(m.closed, @issues[slot]), do: slot

    tied =
      for slot <- fresh,
          Enum.any?(linked, fn other ->
            item = m.items[other]

            item.parent == slot or slot in item.after or m.items[slot].parent == other or
              other in m.items[slot].after
          end),
          do: slot

    # And one made for a task done or dropped, whose push closes it, so GitHub reopening it
    # before a look moves the task. Such a task comes unlinked from the issue it was done
    # by, and reopening matters once a task has its issue closed, or the issue one would
    # be made for is closed.
    finished = for slot <- fresh, m.items[slot].status in [:done, :dropped], do: slot
    done = for slot <- linked, m.items[slot].status in [:done, :dropped], do: slot

    shut =
      Enum.uniq(
        for(
          {_, %{issue: n, state: state}} <- m.items,
          state in [:completed, :not_planned] and m.closed[n] == state,
          do: n
        ) ++
          for(
            slot <- unlinked,
            m.items[slot].status in [:done, :dropped],
            Map.has_key?(m.closed, @issues[slot]),
            do: @issues[slot]
          )
      )

    # A link to the issue another task has, which is refused.
    taken =
      for slot <- present,
          other <- linked,
          other != slot,
          do: {:call, __MODULE__, :link_taken, [slot, issue_of(m, other)]}

    # And GitHub putting a parent under its own sub-issue, which takes the parent's place,
    # as GitHub or the plan has them.
    swaps =
      for {sub, parent} <-
            Enum.uniq(
              for({sub, parent} <- m.parents, slot_of(m, parent), do: {sub, parent}) ++
                for(
                  slot <- pushed,
                  parent = m.items[slot].parent,
                  parent in pushed,
                  do: {issue_of(m, slot), issue_of(m, parent)}
                )
            ),
          do: {:call, __MODULE__, :swap, [sub, parent]}

    # And GitHub marking a parent blocked by its own sub-issue, and turning a dependency
    # around: most of all, once a task waits for its own subtask, the swap and the turn
    # of their issues, which together turn both around and either alone meets the other's
    # old one in a loop.
    crossed =
      for {sub, parent} <- m.parents,
          slot_of(m, sub),
          slot_of(m, parent),
          sub not in Map.get(m.blockers, parent, []),
          do: {:call, __MODULE__, :block, [parent, sub]}

    turns =
      for {number, blockers} <- m.blockers,
          blocker <- blockers,
          slot_of(m, number),
          slot_of(m, blocker),
          do: {:call, __MODULE__, :turn, [number, blocker]}

    turning =
      for {:call, _, _, issues} = call <- swaps ++ turns,
          [sub, parent] = Enum.map(issues, &slot_of(m, &1)),
          sub && parent && crossed?(m.items, sub, parent),
          do: call

    # Most of all a nest that goes against GitHub: the task of an issue GitHub has another
    # under goes under the other's task.
    against =
      for {sub, parent} <- m.parents,
          sub = slot_of(m, sub),
          parent = slot_of(m, parent),
          do: {:call, __MODULE__, :nest_while_looking, [parent, sub]}

    ([
       {4, {:call, __MODULE__, :add, [slot, parent, frequency([{3, :task}, {1, :milestone}])]}},
       {4, {:call, __MODULE__, :wait, [item, item]}},
       {2, {:call, __MODULE__, :nest, [item, oneof([nil, item])]}},
       {2, {:call, __MODULE__, :move, [item, oneof([nil, item]), oneof([nil, item])]}},
       {2, {:call, __MODULE__, :remove, [item]}},
       {1,
        {:call, __MODULE__, :malformed,
         [
           oneof([
             :untitled,
             item,
             {:link, item},
             {:both, item},
             {:unlink, item},
             {:unnamed, item}
           ])
         ]}},
       {4, {:call, __MODULE__, :run, [oneof(["propose", "auto"]), nil]}},
       {2, {:call, __MODULE__, :run, ["check", item]}},
       {2, {:call, __MODULE__, :work, [item, oneof(["nowhere", "api"])]}},
       {1, {:call, __MODULE__, :restart, []}},
       {look, {:call, __MODULE__, :look, []}},
       {switch, {:call, __MODULE__, :switch_board, [other]}},
       {if(onboard == [], do: 1, else: 3), {:call, __MODULE__, :crowd, [not m.full]}}
     ] ++
       if(onboard == [], do: [], else: [{16, {:call, __MODULE__, :unboard, [elements(onboard)]}}]) ++
       if(unlinked == [],
         do: [],
         else: [
           {8, {:call, __MODULE__, :link, [elements(unlinked), oneof([nil, "closed", %{}])]}}
         ]
       ) ++
       if(fresh == [], do: [], else: [{2, {:call, __MODULE__, :create, [elements(fresh)]}}]) ++
       if(tied == [], do: [], else: [{24, {:call, __MODULE__, :create, [elements(tied)]}}]) ++
       if(finished == [],
         do: [],
         else: [{24, {:call, __MODULE__, :create, [elements(finished)]}}]
       ) ++
       if(done == [],
         do: [],
         else: [
           {6,
            oneof(for slot <- done, do: {:call, __MODULE__, :unlink, [slot, issue_of(m, slot)]})}
         ]
       ) ++
       if(shut == [], do: [], else: [{8, {:call, __MODULE__, :reopen, [elements(shut)]}}]) ++
       if(swaps == [], do: [], else: [{16, oneof(swaps)}]) ++
       if(crossed == [], do: [], else: [{400, oneof(crossed)}]) ++
       if(turns == [], do: [], else: [{16, oneof(turns)}]) ++
       if(turning == [], do: [], else: [{400, oneof(turning)}]) ++
       if(taken == [], do: [], else: [{6, oneof(taken)}]) ++
       if(related == [], do: [], else: [{6, {:call, __MODULE__, :remove, [elements(related)]}}]) ++
       if(linked == [],
         do: [],
         else: [
           {relink,
            {:call, __MODULE__, :relink, [elements(linked), oneof([@repository, @elsewhere])]}},
           {4, {:call, __MODULE__, :link_again, [elements(linked)]}},
           {if(tied_to == [], do: 1, else: 3),
            {:call, __MODULE__, :unlink,
             [
               elements(linked),
               oneof(Enum.flat_map(linked, &[issue_of(m, &1), other_issue(m, &1)]))
             ]}}
         ]
       ) ++
       if(pushed == [],
         do: [],
         else: [
           {8,
            oneof(
              for slot <- pushed,
                  do:
                    {:call, __MODULE__, :rename,
                     [
                       slot,
                       oneof([:ok, :refused]),
                       m.pushes + 1,
                       Map.has_key?(m.flights, slot)
                     ]}
            )},
           {8,
            {:call, __MODULE__, :close,
             [elements(Enum.map(pushed, &issue_of(m, &1))), oneof([:completed, :not_planned])]}},
           {redate, {:call, __MODULE__, :redate, [elements(pushed), elements([@due, @moved])]}}
         ]
       ) ++
       if(pushed == [],
         do: [],
         else: [
           {adopt,
            {:call, __MODULE__, :adopt,
             [
               elements(Enum.map(pushed, &issue_of(m, &1))),
               elements([nil, @unplanned | Enum.map(pushed, &issue_of(m, &1))])
             ]}},
           {adopt,
            {:call, __MODULE__, :block,
             [
               elements(Enum.map(pushed, &issue_of(m, &1))),
               elements([nil, @unplanned | Enum.map(pushed, &issue_of(m, &1))])
             ]}},
           {looking, {:call, __MODULE__, :nest_while_looking, [item, oneof([nil, item])]}}
         ]
       ) ++
       if(against == [], do: [], else: [{40, oneof(against)}]) ++
       if(m.closed == %{},
         do: [],
         else: [{2, {:call, __MODULE__, :reopen, [elements(Map.keys(m.closed))]}}]
       ) ++
       if(reread == [],
         do: [],
         else: [
           {12, oneof(for {n, reason} <- reread, do: {:call, __MODULE__, :close, [n, reason]})}
         ]
       ) ++
       if(m.held != %{},
         do: [{10, {:call, __MODULE__, :answer, [elements(Map.keys(m.held))]}}],
         else: []
       ) ++
       if(refused == [],
         do: [],
         else: [{6, {:call, __MODULE__, :wait, [elements(refused), item]}}]
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
             [elements(started), oneof([:nothing, :health, {:due, item}, {:both, item}])]}},
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

  def precondition(m, {:call, _, cmd, [slot | _]})
      when cmd in [:remove, :wait, :nest, :nest_while_looking, :move, :work, :redate],
      do: Map.has_key?(m.items, slot)

  # GitHub refuses a sub-issue under its own sub-issue.
  def precondition(m, {:call, _, :adopt, [number, parent]}),
    do: here?(number) and number not in issue_ancestors(m.parents, parent)

  def precondition(m, {:call, _, :swap, [sub, parent]}),
    do:
      here?(sub) and here?(parent) and sub != parent and
        sub not in issue_ancestors(m.parents, parent)

  # GitHub refuses a dependency loop, and one it already has.
  def precondition(_m, {:call, _, :block, [number, nil]}), do: here?(number)

  def precondition(m, {:call, _, :block, [number, blocker]}),
    do:
      here?(number) and here?(blocker) and blocker not in Map.get(m.blockers, number, []) and
        not issue_waits?(m.blockers, blocker, number)

  def precondition(m, {:call, _, :turn, [number, blocker]}),
    do:
      blocker in Map.get(m.blockers, number, []) and
        not issue_waits?(unblocked(m.blockers, number, blocker), number, blocker)

  def precondition(m, {:call, _, :create, [slot]}),
    do:
      Map.has_key?(m.items, slot) and m.items[slot].issue == nil and
        not Map.has_key?(m.closed, @issues[slot])

  def precondition(m, {:call, _, :run, [_action, slot]}),
    do: slot == nil or Map.has_key?(m.items, slot)

  def precondition(m, {:call, _, :link, [slot, _state]}),
    do: Map.has_key?(m.items, slot) and m.items[slot].issue == nil

  def precondition(m, {:call, _, cmd, [slot | _]})
      when cmd in [:relink, :link_again, :unlink, :unboard],
      do: linked?(m, slot)

  def precondition(m, {:call, _, :link_taken, [slot, number]}),
    do: Map.has_key?(m.items, slot) and slot_of(m, number) not in [nil, slot]

  # A rename names its push, so the push's gate and name stay its own when shrinking, and
  # says whether GitHub holds a push of the task, which the rename then waits behind.
  def precondition(m, {:call, _, :rename, [slot, _outcome, push, flying]}),
    do:
      Map.has_key?(m.items, slot) and here?(m.items[slot].issue) and push > m.pushes and
        flying == Map.has_key?(m.flights, slot)

  def precondition(m, {:call, _, :answer, [push]}), do: Map.has_key?(m.held, push)
  def precondition(_m, {:call, _, :close, [number, _reason]}), do: here?(number)
  def precondition(m, {:call, _, :reopen, [number]}), do: Map.has_key?(m.closed, number)
  def precondition(m, {:call, _, :switch_board, [board]}), do: board != m.board

  def precondition(m, {:call, _, cmd, [k | _]}) when cmd in [:report, :turn_finished],
    do: match?(%{started: true}, m.runs[k])

  def precondition(m, {:call, _, cmd, [k | _]}) when cmd in [:retry, :apply, :dismiss, :discard],
    do: k <= m.asked

  def precondition(_m, _call), do: true

  def next_state(m, _result, call), do: m |> step(call) |> elem(0)

  defp issue_ancestors(_parents, nil), do: []
  defp issue_ancestors(parents, n), do: [n | issue_ancestors(parents, parents[n])]

  # Whether issue `n` waits on GitHub, through what it waits for, for issue `target`.
  defp issue_waits?(blockers, n, target, seen \\ []) do
    n == target or
      (n not in seen and
         Enum.any?(Map.get(blockers, n, []), &issue_waits?(blockers, &1, target, [n | seen])))
  end

  defp unblocked(blockers, number, blocker),
    do: Map.update(blockers, number, [], &List.delete(&1, blocker))

  def postcondition(before, call, observed) do
    {m, reply} = step(before, call)

    expected = %{
      reply: reply,
      items: m.items,
      runs: view(m),
      updates: m.updates,
      github: m.github,
      rel: m.rel,
      problems: []
    }

    if observed != expected do
      for {field, value} <- expected, observed[field] != value do
        IO.puts(
          "#{inspect(call)}: #{field} expected #{inspect(value, limit: :infinity)}, " <>
            "got #{inspect(observed[field], limit: :infinity)}"
        )
      end
    end

    observed == expected and latest_on_github?(before, m, call, observed) and
      not own_ancestor?(observed.items)
  end

  # Whether a task the plugin answers is its own ancestor.
  defp own_ancestor?(items) do
    Enum.any?(items, fn {slot, item} ->
      climbs_to?(items, item.parent, slot, MapSet.new()) and
        IO.puts("#{slot} is its own ancestor: #{inspect(items)}") == :ok
    end)
  end

  defp climbs_to?(_items, nil, _slot, _seen), do: false
  defp climbs_to?(_items, slot, slot, _seen), do: true

  defp climbs_to?(items, parent, slot, seen) do
    not MapSet.member?(seen, parent) and Map.has_key?(items, parent) and
      climbs_to?(items, items[parent].parent, slot, MapSet.put(seen, parent))
  end

  # Once GitHub answers the last push of a task's chain and refuses none of it, GitHub
  # has the task's name, whatever the model says it should.
  defp latest_on_github?(before, m, {:call, _, :answer, [push]}, observed) do
    %{slot: slot, gen: gen} = before.held[push]

    with %{gen: ^gen, push: ^push} <- before.flights[slot],
         %{sync: nil, issue: n} <- m.items[slot],
         false <- Map.has_key?(m.flights, slot),
         named = observed.github[n],
         %{name: name} when name != named <- observed.items[slot] do
      IO.puts("GitHub names ##{n} #{inspect(named)}, not #{inspect(name)}")
      false
    else
      _ -> true
    end
  end

  defp latest_on_github?(_before, _m, _call, _observed), do: true

  # `{model after call, the reply it expects}`: :ok or :error.
  defp step(m, {:call, _, :add, [slot, parent, kind]}) do
    m = %{m | gens: Map.update(m.gens, slot, 1, &(&1 + 1))}

    item = %{
      name: slot,
      kind: kind,
      parent: parent,
      after: [],
      due: @due,
      issue: nil,
      sync: nil,
      board: nil,
      status: :todo,
      state: nil
    }

    {%{put_in(m.items[slot], item) | synced: Map.delete(m.synced, slot)}, :ok}
  end

  defp step(m, {:call, _, :malformed, [_what]}), do: {m, :error}
  # An issue is one task's: a link to the one another task has is refused.
  defp step(m, {:call, _, :link_taken, [_slot, _number]}), do: {m, :error}

  defp step(m, {:call, _, :wait, [slot, other]}) do
    after_slots = Enum.uniq(m.items[slot].after ++ [other])

    cond do
      not Map.has_key?(m.items, other) -> {m, :error}
      other == slot or reaches?(m.items, [other], slot) -> {m, :error}
      after_slots == m.items[slot].after -> {m, :ok}
      true -> {m |> put_in([:items, slot, :after], after_slots) |> changed(slot, m), :ok}
    end
  end

  # `slot` becomes a subtask of `parent`, or of nothing.
  defp step(m, {:call, _, :nest, [slot, parent]}) do
    cond do
      parent != nil and not Map.has_key?(m.items, parent) -> {m, :error}
      parent == slot or slot in ancestors(m.items, parent) -> {m, :error}
      m.items[slot].parent == parent -> {m, :ok}
      true -> {m |> put_in([:items, slot, :parent], parent) |> changed(slot, m), :ok}
    end
  end

  # A client moves the task's due date.
  defp step(m, {:call, _, :redate, [slot, due]}) do
    if m.items[slot].due == due,
      do: {m, :ok},
      else: {m |> put_in([:items, slot, :due], due) |> changed(slot, m), :ok}
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
        else: {Enum.reduce(Enum.uniq([from, to]), %{m | items: items}, &moved(&2, &1, m)), :ok}
    else
      {m, :error}
    end
  end

  # The tasks that waited for the removed one, or were its subtasks, push what they lost
  # of it, and a push of it on the way speaks for nobody.
  defp step(before, {:call, _, :remove, [slot]}) do
    {removed, items} = Map.pop(before.items, slot)

    m = %{
      before
      | synced: Map.delete(before.synced, slot),
        flights: Map.delete(before.flights, slot)
    }

    touched =
      for {key, item} <- items, item.parent == slot or slot in item.after, do: key

    items =
      Map.new(items, fn {key, item} ->
        parent = if item.parent == slot, do: removed.parent, else: item.parent
        {key, %{item | parent: parent, after: List.delete(item.after, slot)}}
      end)

    {Enum.reduce(touched, %{m | items: items}, &changed(&2, &1, before)), :ok}
  end

  defp step(m, {:call, _, :run, [action, slot]}), do: {ask(m, action, slot), :ok}
  defp step(m, {:call, _, :work, [slot, _project]}), do: {ask(m, "work", slot), :ok}

  # GitHub is taken to have the task's name and due date, and none of its relations: the
  # task pushes those to tasks with an issue, and the tasks tied to it push theirs to its
  # issue (`ties_moved/3`). The plugin takes the issue for open until a look reads it,
  # whatever state the link says.
  defp step(m, {:call, _, :link, [slot, _state]}) do
    item = %{m.items[slot] | issue: @issues[slot], state: :open}
    {m |> put_in([:items, slot], item) |> changed(slot, m) |> ties_moved(slot, m), :ok}
  end

  # An issue made for the task links it as linking an issue does, but it is open and on
  # no board: the push closes it for a task done or dropped, which GitHub takes, and adds
  # it to the board with the task's due date. The plugin takes it to be as the push left
  # it until a look reads it, so GitHub reopening it since moves the task.
  defp step(before, {:call, _, :create, [slot]}) do
    n = @issues[slot]

    state =
      case before.items[slot].status do
        :done -> :completed
        :dropped -> :not_planned
        _ -> :open
      end

    item = %{before.items[slot] | issue: n, state: state}
    made = %{baseline(before, slot) | due: nil}
    m = before |> put_in([:items, slot], item) |> push_now(slot, made) |> ties_moved(slot, before)
    {if(state == :open, do: m, else: put_in(m.closed[n], state)), :ok}
  end

  # Linking a task to the issue it has changes nothing: the plugin keeps what it last
  # read of the issue.
  defp step(m, {:call, _, :link_again, [_slot]}), do: {m, :ok}

  # The board item, sync error and what GitHub has of the issue before stay with it, and
  # the push to it on the way speaks for nobody, whether or not the relink pushes
  # anything itself. GitHub is taken to have of the new issue the name and due date the
  # task had, so a rename GitHub has not answered yet is not pushed to it, but not its
  # relations, which move from the issue before, and those of the tasks tied to it too.
  defp step(before, {:call, _, :relink, [slot, repository]}) do
    item = %{
      before.items[slot]
      | issue: relinked(before, slot, repository),
        sync: nil,
        board: nil,
        state: :open
    }

    m = %{
      before
      | flights: Map.delete(before.flights, slot),
        synced: Map.delete(before.synced, slot)
    }

    {m |> put_in([:items, slot], item) |> changed(slot, m) |> ties_moved(slot, m), :ok}
  end

  # Nothing on the way speaks for a task no longer linked, and the tasks tied to it drop
  # their relations to its issue; the relations of its own stay on the issue. A client
  # that still shows an issue the task no longer has unlinks nothing.
  defp step(m, {:call, _, :unlink, [slot, number]}) do
    if m.items[slot].issue == number do
      item = %{m.items[slot] | issue: nil, sync: nil, board: nil, state: nil}
      m = %{m | flights: Map.delete(m.flights, slot), synced: Map.delete(m.synced, slot)}
      {m |> put_in([:items, slot], item) |> ties_moved(slot, m), :ok}
    else
      {m, :ok}
    end
  end

  # A rename with no push of the task on the way pushes, and GitHub holds it, answering
  # its name with `outcome`; until then the task's sync error and board item stay as they
  # were, and it keeps what GitHub had of it. One made while GitHub holds a push of the
  # task only marks it, to go once GitHub answers.
  defp step(before, {:call, _, :rename, [slot, outcome, push, flying]}) do
    item = %{before.items[slot] | name: "#{slot}#{push}", due: renamed_due(push)}
    outcomes = Map.put(before.outcomes, item.name, {push, outcome})
    m = put_in(%{before | pushes: push, outcomes: outcomes}, [:items, slot], item)

    if flying do
      {changed(m, slot, before), :ok}
    else
      gen = m.gens[slot]
      b = baseline(before, slot)
      held = %{slot: slot, gen: gen, ops: ops(m, slot, b), b: b, board: m.board}

      {%{
         m
         | held: Map.put(m.held, push, held),
           flights: Map.put(m.flights, slot, %{gen: gen, push: push, changed: false}),
           synced: Map.put(m.synced, slot, b)
       }, :ok}
    end
  end

  # GitHub takes the push held, as far as it does, whoever it speaks for, on the board the
  # settings named when it was made. When its task still waits on it, the task hears how
  # it went and, when it changed meanwhile, its caller pushes what GitHub lacks of it now,
  # which GitHub answers at once.
  defp step(m, {:call, _, :answer, [push]}) do
    {%{slot: slot, gen: gen, ops: ops, b: b, board: on}, held} = Map.pop(m.held, push)
    {m, took} = land(%{m | held: held}, ops, b, push, on)

    case m.flights[slot] do
      %{gen: ^gen, push: ^push, changed: changed?} ->
        m = settle(%{m | flights: Map.delete(m.flights, slot)}, slot, took)

        case changed? && ops(m, slot, took.b) do
          false -> {m, :ok}
          [] -> {clear(m, slot), :ok}
          ops -> {land_on(m, slot, ops, took.b, push), :ok}
        end

      _ ->
        {m, :ok}
    end
  end

  defp step(m, {:call, _, :look, []}), do: {looked(m), :ok}

  # The look reads the plan before the nest and GitHub as it was before it too, and the
  # task the nest changed keeps the change.
  defp step(m, {:call, _, :nest_while_looking, [slot, parent]}) do
    {nested, reply} = step(m, {:call, __MODULE__, :nest, [slot, parent]})
    changed? = nested.items[slot] != m.items[slot] or nested.synced[slot] != m.synced[slot]
    {looked(nested, if(changed?, do: [slot], else: [])), reply}
  end

  # GitHub makes an issue a sub-issue of another, or of none; the plan hears of it at the
  # next look.
  defp step(m, {:call, _, :adopt, [number, nil]}),
    do: {%{m | parents: Map.delete(m.parents, number)}, :ok}

  defp step(m, {:call, _, :adopt, [number, parent]}),
    do: {put_in(m.parents[number], parent), :ok}

  # GitHub puts `parent` under `sub`, and `sub` where `parent` was; the plan hears of it
  # at the next look.
  defp step(m, {:call, _, :swap, [sub, parent]}),
    do: {%{m | parents: swapped(m.parents, sub, parent)}, :ok}

  # GitHub marks an issue blocked by another too, or by none, or turns the dependency on
  # `blocker` around; the plan hears of it at the next look.
  defp step(m, {:call, _, :block, [number, nil]}),
    do: {%{m | blockers: Map.delete(m.blockers, number)}, :ok}

  defp step(m, {:call, _, :block, [number, blocker]}),
    do: {%{m | blockers: Map.update(m.blockers, number, [blocker], &(&1 ++ [blocker]))}, :ok}

  defp step(m, {:call, _, :turn, [number, blocker]}),
    do: {%{m | blockers: turned(m.blockers, number, blocker)}, :ok}

  # GitHub moves an issue; the plan hears of it at the next look.
  defp step(m, {:call, _, :close, [number, reason]}),
    do: {put_in(m.closed[number], reason), :ok}

  defp step(m, {:call, _, :reopen, [number]}),
    do: {%{m | closed: Map.delete(m.closed, number)}, :ok}

  # Someone takes the task's issue off the board the settings name; the plan hears of it
  # at the next look that reads the whole board.
  defp step(m, {:call, _, :unboard, [slot]}) do
    listed = Map.get(m.boards, m.board, %{})
    {%{m | boards: Map.put(m.boards, m.board, Map.delete(listed, issue_of(m, slot)))}, :ok}
  end

  defp step(m, {:call, _, :crowd, [full]}), do: {%{m | full: full}, :ok}

  defp step(m, {:call, _, :retry, [k]}) do
    case m.runs[k] do
      %{status: :failed} -> {m |> queue(k) |> pump(), :ok}
      _ -> {m, :error}
    end
  end

  # A report that links a task to two things at once is refused, whatever its run is in.
  defp step(m, {:call, _, :report, [_k, {:both, _slot}]}), do: {m, :error}

  # A run retried after its task was removed failed without a thread, so the thread it
  # had before reports to no run.
  defp step(m, {:call, _, :report, [k, kind]}) do
    run = m.runs[k]

    cond do
      run.status not in [:running, :failed, :proposed] or run.gone ->
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
            {m |> finish(k, %{run | status: :done}) |> pump(), :ok}

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
  # not know the pushes on the way, so their answers no longer say whether a task synced,
  # though GitHub still takes them, and it looks at GitHub.
  defp step(m, {:call, _, :restart, []}) do
    runs =
      Map.new(m.runs, fn {k, run} ->
        {k, if(run.status == :running, do: %{run | status: :failed}, else: run)}
      end)

    {%{m | runs: runs, flights: %{}} |> pump() |> looked(), :ok}
  end

  # Saving the settings with another board starts the plugin again, the tasks' board
  # items of the one before are forgotten, and it looks at the new one.
  defp step(m, {:call, _, :switch_board, [board]}) do
    {m, :ok} = step(m, {:call, __MODULE__, :restart, []})
    items = Map.new(m.items, fn {slot, item} -> {slot, %{item | board: nil}} end)
    {looked(%{m | board: board, items: items}), :ok}
  end

  defp put_run(m, k, run), do: %{m | runs: Map.put(m.runs, k, run)}

  # `run` finished last, applied or with nothing to apply; of the runs that did, only the
  # `@kept_runs` that finished last stay.
  defp finish(m, k, run) do
    n = m.finished + 1
    m = put_run(%{m | finished: n}, k, %{run | finished: n})

    dropped =
      m.runs
      |> Enum.filter(fn {_, run} -> run.status in [:applied, :done] end)
      |> Enum.sort_by(fn {_, run} -> run.finished end, :desc)
      |> Enum.drop(@kept_runs)
      |> Enum.map(&elem(&1, 0))

    %{m | runs: Map.drop(m.runs, dropped)}
  end

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
      health: nil,
      finished: nil
    }

    m = %{m | asked: k, runs: Map.put(m.runs, k, run)}
    m |> queue(k) |> pump()
  end

  defp linked?(m, slot), do: match?(%{issue: n} when n != nil, m.items[slot])
  defp tied_to?(item, slot), do: item.parent == slot or slot in item.after

  # Whether one of the tasks in `a` and `b` is the other's subtask and the other waits
  # for it.
  defp crossed?(items, a, b),
    do:
      (items[a].parent == b and a in items[b].after) or
        (items[b].parent == a and b in items[a].after)

  defp issue_of(m, slot), do: m.items[slot].issue

  defp slot_of(m, issue),
    do: Enum.find_value(m.items, fn {s, i} -> if i.issue == issue, do: s end)

  # The issue a relink moves the task in `slot` to: the one it was not linked to of two.
  defp other_issue(m, slot),
    do: if(m.items[slot].issue == @issues[slot], do: @issues[slot] + 10, else: @issues[slot])

  # The issue a relink to `repository` moves the task in `slot` to.
  defp relinked(m, slot, @repository), do: other_issue(m, slot)
  defp relinked(_m, slot, @elsewhere), do: @issues[slot] + @elsewhere_from

  defp repository_of(number) when here?(number), do: @repository
  defp repository_of(_number), do: @elsewhere

  # A change to the task in `slot` from `before`. A task linked to an issue of
  # `@repository` with no push on the way pushes what it has that GitHub has not (its
  # `synced`, or else what it had before the change), from the caller, which GitHub
  # answers at once. One with a push on the way is only marked, to go once GitHub
  # answers. A change that leaves GitHub nothing to take pushes nothing and clears the
  # task's marks. A task linked to an issue of `@elsewhere` is pushed nothing.
  defp changed(m, slot, before) do
    cond do
      not here?(m.items[slot][:issue]) -> m
      Map.has_key?(m.flights, slot) -> put_in(m.flights[slot].changed, true)
      true -> push_now(m, slot, baseline(before, slot))
    end
  end

  # The tasks waiting for the task in `slot` or under it, and the milestones it holds up,
  # once it is linked to another issue or none: each pushes its relation to the task
  # anew, from the issue it had in `before` to the one it has now, as `changed/3`.
  defp ties_moved(m, slot, before) do
    tied = for {other, item} <- m.items, tied_to?(item, slot), do: other
    Enum.reduce(tied, m, &changed(&2, &1, before))
  end

  defp push_now(m, slot, b) do
    case ops(m, slot, b) do
      [] -> if m.items[slot].sync != nil or m.synced[slot] != nil, do: clear(m, slot), else: m
      ops -> land_on(m, slot, ops, b, 0)
    end
  end

  # What GitHub has of the task in `slot` of `m`, as a push knows it: the baseline a push
  # left it, or else what it has.
  defp baseline(m, slot), do: m.synced[slot] || own(m, slot)

  # The task in `slot` of `m` as GitHub is taken to have it: its name, due date, the tasks
  # it waits for and its parent (`{slot, gen}`), of those with an issue, all GitHub can
  # have, the issues those had then (`refs`), and the issue it has them on, none when it
  # has no issue.
  defp own(m, slot) do
    item = m.items[slot]
    after_keys = Enum.map(item.after, &key(m, &1))
    parent = key(m, item.parent)
    keys = if item.issue, do: [parent | after_keys], else: []
    refs = for k <- keys, k != nil, r = issue_at(m, k), into: %{}, do: {k, r}

    %{
      name: item.name,
      due: item.due,
      after: Enum.filter(after_keys, &is_map_key(refs, &1)),
      parent: if(is_map_key(refs, parent), do: parent),
      refs: refs,
      issue: item.issue
    }
  end

  defp key(_m, nil), do: nil
  defp key(m, slot), do: {slot, m.gens[slot]}

  # The issue the task `{slot, gen}` has, nil when it has none or is gone.
  defp issue_at(m, {slot, gen}) do
    if m.gens[slot] == gen, do: m.items[slot][:issue]
  end

  # What a push of the task in `slot` asks GitHub, of which GitHub has `b`, in order: its
  # name; the relations it drops, from the issue it had them on (`b.issue`) when that is
  # of `@repository`, by the issue it had for the other task when it can: the issues it
  # no longer waits for, the parent it leaves; then the relations it makes on its issue:
  # the issues it waits for and the parent it joins, of `@repository` only; the board,
  # when it is not on it, and its due date there. A relation to a task linked to another
  # issue since, or of a task linked to another issue since, is dropped and made anew.
  defp ops(m, slot, b) do
    item = m.items[slot]
    n = item.issue
    was = b.issue
    now_after = Enum.map(item.after, &key(m, &1))
    to = key(m, item.parent)
    had = &(b.refs[&1] || issue_at(m, &1))
    kept? = &(was == n and had.(&1) != nil and had.(&1) == issue_at(m, &1))
    kept = Enum.filter(b.after, &(&1 in now_after and kept?.(&1)))
    title = if b.name != item.name, do: [{:title, n, item.name}], else: []

    unblocks =
      for k <- b.after -- kept, here?(was), r = had.(k), do: {:unblock, {was, r}, k}

    blocks = for k <- now_after -- kept, r = issue_at(m, k), do: {:block, {n, r}, k}

    {unsub, sub} =
      if b.parent == to and (to == nil or kept?.(to)) do
        {[], []}
      else
        r = b.parent && had.(b.parent)
        s = to && issue_at(m, to)

        {if(here?(was) and here?(r), do: [{:unsub, {r, was}, b.parent}], else: []),
         if(here?(s), do: [{:sub, {s, n}, to}], else: [])}
      end

    due =
      cond do
        b.due == item.due -> []
        item.board == nil -> [{:board, n}, {:due, item.due}]
        true -> [{:due, item.due}]
      end

    title ++ unblocks ++ unsub ++ blocks ++ sub ++ due
  end

  # GitHub takes `ops` in order, of which it had `b`, until it refuses a name, a board
  # item it adds to the board `on` named after `board`: `{m with what GitHub has, %{error,
  # b, board}}`, `b` with what took and `board` set when it added one. Once a relation is
  # made on the task's issue, GitHub has all of them there.
  defp land(m, ops, b, board, on) do
    Enum.reduce_while(ops, {m, %{error: nil, b: b, board: nil}}, fn op, {m, took} ->
      case op do
        {:title, n, name} ->
          case m.outcomes[name] do
            {push, :refused} -> {:halt, {m, %{took | error: {:refused, push}}}}
            _ -> {:cont, {put_in(m.github[n], name), put_in(took.b.name, name)}}
          end

        {:block, {n, r} = pair, k} ->
          b = %{
            took.b
            | after: Enum.uniq(took.b.after ++ [k]),
              refs: Map.put(took.b.refs, k, r),
              issue: n
          }

          {:cont, {%{m | rel: MapSet.put(m.rel, {:blocked, pair})}, %{took | b: b}}}

        {:unblock, pair, k} ->
          b = %{took.b | after: took.b.after -- [k]}
          {:cont, {%{m | rel: MapSet.delete(m.rel, {:blocked, pair})}, %{took | b: b}}}

        {:unsub, pair, _k} ->
          {:cont, {%{m | rel: MapSet.delete(m.rel, {:sub, pair})}, put_in(took.b.parent, nil)}}

        {:sub, {r, n} = pair, k} ->
          b = %{took.b | parent: k, refs: Map.put(took.b.refs, k, r), issue: n}
          {:cont, {%{m | rel: MapSet.put(m.rel, {:sub, pair})}, %{took | b: b}}}

        {:board, n} ->
          boards = Map.update(m.boards, on, %{n => board}, &Map.put(&1, n, board))
          {:cont, {%{m | boards: boards}, %{took | board: board}}}

        {:due, due} ->
          {:cont, {m, put_in(took.b.due, due)}}
      end
    end)
  end

  # The task in `slot` pushes `ops`, to the board the settings name, and hears how it went.
  defp land_on(m, slot, ops, b, board) do
    {m, took} = land(m, ops, b, board, m.board)
    settle(m, slot, took)
  end

  # The task in `slot` hears how its push went: the sync error, the board item it added,
  # and what GitHub has of it, which it keeps when GitHub refused some of it.
  defp settle(m, slot, %{error: error, b: b, board: board}) do
    item = %{m.items[slot] | sync: error}
    m = put_in(m.items[slot], if(board, do: %{item | board: board}, else: item))
    if error, do: put_in(m.synced[slot], b), else: %{m | synced: Map.delete(m.synced, slot)}
  end

  defp clear(m, slot),
    do: %{put_in(m.items[slot].sync, nil) | synced: Map.delete(m.synced, slot)}

  # A look at GitHub, which lists the open issues of `@repository` tasks are linked to,
  # with the parent GitHub has each under, and has the closed ones, with no relations,
  # from those changed since the last look began, reading the rest alone: such a task takes its issue's name and state, has all of it, and then, in
  # the order GitHub lists the issues, waits for no task with an issue and is the subtask
  # of the task whose issue GitHub names as its parent, or of none when its parent has an
  # issue, unless GitHub refused its last change, a push to it is on the way, or it is
  # one of the `kept` tasks, changed while the look was on its way. It reads the board
  # too: a task with no push on the way takes the board item its issue has there, loses
  # its own when a whole board has none, and keeps it when the board was read only in
  # part. A task with a push on the way, or kept, keeps all it has, its board item too,
  # as the plugin keeps such a task whole when it applies a look; the push's answer sets
  # the board item only when the push added one (`settle/3`).
  defp looked(m, kept \\ []) do
    listed = Map.get(m.boards, m.board, %{})
    whole? = &(Map.has_key?(m.flights, &1) or &1 in kept)

    items =
      Map.new(m.items, fn {slot, item} ->
        cond do
          whole?.(slot) -> {slot, item}
          is_map_key(listed, item.issue) -> {slot, %{item | board: listed[item.issue]}}
          m.full -> {slot, item}
          true -> {slot, %{item | board: nil}}
        end
      end)

    synced =
      for {slot, item} <- items, here?(item.issue), item.sync == nil, not whole?.(slot), do: slot

    m =
      Enum.reduce(synced, %{m | items: items}, fn slot, acc ->
        item = acc.items[slot]
        state = Map.get(m.closed, item.issue, :open)

        item = %{
          item
          | name: "Issue #{item.issue}",
            status: status_after(item, state),
            state: state
        }

        %{put_in(acc.items[slot], item) | synced: Map.delete(acc.synced, slot)}
      end)

    relations(m, Enum.sort_by(synced, &{Map.has_key?(m.closed, m.items[&1].issue), &1}))
  end

  # The tasks in `slots` take their relations all at once when the plan they make has no
  # task its own ancestor or waiting for itself. Otherwise they take them in order, and
  # the ones refused go again once the others are in, while any more of them take, so a
  # parent GitHub put under its sub-issue goes under it whichever GitHub lists first.
  defp relations(m, slots) do
    together = Enum.reduce(slots, m, &put_in(&2.items[&1], related(m, &1)))
    if Enum.any?(slots, &looped?(together.items, &1)), do: one_by_one(m, slots), else: together
  end

  defp one_by_one(m, slots) do
    {m, refused} =
      Enum.reduce(slots, {m, []}, fn slot, {m, refused} ->
        related = put_in(m.items[slot], related(m, slot))
        if looped?(related.items, slot), do: {m, refused ++ [slot]}, else: {related, refused}
      end)

    if refused != [] and length(refused) < length(slots), do: one_by_one(m, refused), else: m
  end

  # The task in `slot` waiting for the tasks whose issues GitHub has its open issue blocked
  # by and no other task with an issue, and the subtask of the task whose issue GitHub
  # names as its open issue's parent, or else of none when its parent has an issue.
  defp related(m, slot) do
    item = m.items[slot]
    issue? = &(&1 != nil and m.items[&1].issue != nil)
    open? = not Map.has_key?(m.closed, item.issue)
    named = if open?, do: m.parents[item.issue]
    by_github = named && slot_of(m, named)

    blockers =
      for n <- if(open?, do: Map.get(m.blockers, item.issue, []), else: []),
          blocker = slot_of(m, n),
          do: blocker

    parent =
      cond do
        by_github -> by_github
        issue?.(item.parent) -> nil
        true -> item.parent
      end

    %{item | parent: parent, after: Enum.uniq(Enum.reject(item.after, issue?) ++ blockers)}
  end

  # Whether the task in `slot` is its own ancestor or waits for itself.
  defp looped?(items, slot),
    do:
      climbs_to?(items, items[slot].parent, slot, MapSet.new()) or
        reaches?(items, items[slot].after, slot)

  # The task's status once the plugin reads its issue in `state`: it moves only when the
  # issue's state moved since the plugin last read it.
  defp status_after(%{state: state, status: status}, state), do: status
  defp status_after(_item, :not_planned), do: :dropped
  defp status_after(_item, :completed), do: :done
  defp status_after(%{status: status}, :open) when status in [:done, :dropped], do: :todo
  defp status_after(%{status: status}, :open), do: status

  defp renamed_due(push), do: Date.to_iso8601(Date.add(~D[2027-01-01], push))

  defp moved(m, slot, before),
    do:
      if(slot != nil and m.items[slot] != before.items[slot],
        do: changed(m, slot, before),
        else: m
      )

  defp ancestors(_items, nil), do: []
  defp ancestors(items, slot), do: [slot | ancestors(items, items[slot].parent)]

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

    before = m
    moved = for {slot, item} <- items, before.items[slot].due != item.due, do: slot
    m = Enum.reduce(moved, %{m | items: items}, &changed(&2, &1, before))
    m = finish(m, k, %{run | status: :applied, changes: changes})
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

  # A task with no title, or a change whose fields are not an object.
  def malformed(:untitled),
    do: observe(elem(call("addItem", %{"fields" => %{"kind" => "task"}}), 0))

  # A pull request whose repository is not text is neither linked nor unlinked.
  def malformed({:link, slot}),
    do: observe(elem(call("link", %{"itemId" => item_id(slot), "pullRequest" => @bad_ref}), 0))

  # A pull request and an issue at once: neither is linked.
  def malformed({:both, slot}) do
    input = %{"itemId" => item_id(slot), "pullRequest" => pr_ref(), "issue" => issue_ref(slot)}
    observe(elem(call("link", input), 0))
  end

  def malformed({:unlink, slot}) do
    input = %{"itemId" => item_id(slot), "kind" => "pullRequest", "ref" => @bad_ref}
    observe(elem(call("unlink", input), 0))
  end

  # An issue unlinked without naming which.
  def malformed({:unnamed, slot}),
    do: observe(elem(call("unlink", %{"itemId" => item_id(slot), "kind" => "issue"}), 0))

  def malformed(slot),
    do: observe(elem(call("updateItem", %{"id" => item_id(slot), "fields" => ["title"]}), 0))

  def wait(slot, other) do
    after_ids = Enum.uniq(item(slot)["after"] ++ [item_id(other)])

    observe(
      elem(call("updateItem", %{"id" => item_id(slot), "fields" => %{"after" => after_ids}}), 0)
    )
  end

  def nest(slot, parent) do
    fields = %{"parent" => parent && item_id(parent)}
    observe(elem(call("updateItem", %{"id" => item_id(slot), "fields" => fields}), 0))
  end

  def redate(slot, due),
    do:
      observe(elem(call("updateItem", %{"id" => item_id(slot), "fields" => %{"due" => due}}), 0))

  def move(slot, from, to) do
    ids = %{"id" => item_id(slot), "from" => from && item_id(from), "to" => to && item_id(to)}
    observe(elem(call("moveToMilestone", ids), 0))
  end

  def remove(slot) do
    {reply, _} = call("removeItem", %{"id" => item_id(slot)})
    Process.put(:pl_items, Map.delete(Process.get(:pl_items), slot))
    Process.delete({:pl_issue, slot})
    listed()
    observe(reply)
  end

  def run(action, slot) do
    ids = if slot, do: [item_id(slot)], else: []
    {reply, value} = call("run", %{"action" => action, "itemIds" => ids})
    if reply == :ok, do: Process.put(:pl_runs, Process.get(:pl_runs) ++ [value["run"]["id"]])
    observe(reply)
  end

  # Work on a project the MC does not have, or on "api", whose launch exits calling the
  # worktree setup the case does not run; either way its thread cannot launch.
  def work(slot, project) do
    input = %{"action" => "work", "itemIds" => [item_id(slot)], "projectId" => project}
    {reply, value} = call("run", input)
    if reply == :ok, do: Process.put(:pl_runs, Process.get(:pl_runs) ++ [value["run"]["id"]])
    observe(reply)
  end

  # Links the task to its issue, the link saying `state` when it is not nil.
  def link(slot, state), do: link_to(slot, @issues[slot], state)

  # Links the task to the issue it has.
  def link_again(slot), do: link_to(slot, Process.get({:pl_issue, slot}))

  # Links the task to the issue `number` another task has.
  def link_taken(slot, number), do: link_to(slot, number)

  # Links the task to the issue of `@repository` of the two it is not linked to, or to its
  # issue of `@elsewhere`.
  def relink(slot, @elsewhere), do: link_to(slot, @issues[slot] + @elsewhere_from)

  def relink(slot, @repository) do
    current = Process.get({:pl_issue, slot})
    link_to(slot, if(current == @issues[slot], do: @issues[slot] + 10, else: @issues[slot]))
  end

  # Unlinks the issue `number`, the task's or one it had before.
  def unlink(slot, number) do
    ref = %{"repository" => repository_of(number), "number" => number}
    {reply, _} = call("unlink", %{"itemId" => item_id(slot), "kind" => "issue", "ref" => ref})

    if reply == :ok and number == Process.get({:pl_issue, slot}),
      do: Process.delete({:pl_issue, slot})

    listed()
    observe(reply)
  end

  defp link_to(slot, number, state \\ nil) do
    issue = %{"repository" => repository_of(number), "number" => number}
    issue = if state, do: Map.put(issue, "state", state), else: issue
    {reply, _} = call("link", %{"itemId" => item_id(slot), "issue" => issue})
    if reply == :ok, do: Process.put({:pl_issue, slot}, number)
    listed()
    observe(reply)
  end

  # GitHub lists only the open issues of `@repository` a task is linked to, as if they
  # alone had the planner's label, with the parent each is under, so a look adds no task
  # and brings the linked one up to date; a closed one it answers when it is read alone
  # (see `close/2`), and in a listing of every state among those changed since a time.
  defp listed do
    gh_rule(changed())
    gh_rule(listing())
  end

  defp listing do
    nodes =
      for {number, node} <- linked(), not Map.has_key?(Process.get(:pl_closed), number), do: node

    rule = issue_list(nodes)
    %{rule | "stdin" => rule["stdin"] ++ [~s("states":["OPEN"])]}
  end

  # The linked issues of every state, which the fake gh cuts to those changed since the
  # listing's `since`.
  defp changed do
    rule = issue_list(Enum.map(linked(), &elem(&1, 1)))
    Map.merge(rule, %{"stdin" => rule["stdin"] ++ [~s("states":null)], "since" => true})
  end

  # The issues of `@repository` tasks are linked to, open with the parent each is under
  # and the issues it is blocked by, closed as read alone.
  defp linked do
    parents = Process.get(:pl_parents)
    blockers = Process.get(:pl_blockers)

    for {slot, _} <- Process.get(:pl_items),
        number = Process.get({:pl_issue, slot}),
        here?(number) do
      if Map.has_key?(Process.get(:pl_closed), number) do
        {number, issue_node(number)}
      else
        ref = &%{"number" => &1, "repository" => repo_ref()}

        {number,
         Map.merge(issue_node(number), %{
           "parent" => parents[number] && ref.(parents[number]),
           "blockedBy" => %{"nodes" => Enum.map(Map.get(blockers, number, []), ref)}
         })}
      end
    end
  end

  # GitHub stamps `numbers` as changed now.
  defp touch(numbers) do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    Process.put(:pl_updated, Map.merge(Process.get(:pl_updated), Map.new(numbers, &{&1, now})))
  end

  defp repo_ref, do: %{"nameWithOwner" => @repository}

  # Someone on GitHub makes issue `number` a sub-issue of `parent`, or of none.
  def adopt(number, parent) do
    parents = Process.get(:pl_parents)
    parents = if parent, do: Map.put(parents, number, parent), else: Map.delete(parents, number)
    Process.put(:pl_parents, parents)
    touch([number])
    listed()
    observe(:ok)
  end

  # Someone on GitHub puts `parent` under `sub`, its sub-issue there or in the plan, and
  # `sub` where `parent` was.
  def swap(sub, parent) do
    Process.put(:pl_parents, swapped(Process.get(:pl_parents), sub, parent))
    touch([sub, parent])
    listed()
    observe(:ok)
  end

  # Someone on GitHub marks issue `number` blocked by `blocker` too, or by none.
  def block(number, blocker) do
    blockers = Process.get(:pl_blockers)

    blockers =
      if blocker,
        do: Map.update(blockers, number, [blocker], &(&1 ++ [blocker])),
        else: Map.delete(blockers, number)

    Process.put(:pl_blockers, blockers)
    touch([number])
    listed()
    observe(:ok)
  end

  # Someone on GitHub turns around issue `number` being blocked by `blocker`: `blocker` is
  # blocked by `number` instead.
  def turn(number, blocker) do
    Process.put(:pl_blockers, turned(Process.get(:pl_blockers), number, blocker))
    touch([number, blocker])
    listed()
    observe(:ok)
  end

  defp turned(blockers, number, blocker),
    do:
      blockers
      |> unblocked(number, blocker)
      |> Map.update(blocker, [number], &(&1 ++ [number]))

  defp swapped(parents, sub, parent) do
    case parents[parent] do
      nil -> Map.delete(parents, sub)
      grand -> Map.put(parents, sub, grand)
    end
    |> Map.put(parent, sub)
  end

  # GitHub makes an issue for the task in `slot`, numbered as the one it links to, open,
  # and closes it with the reason the push for the task asks.
  def create(slot) do
    number = @issues[slot]

    gh_rule(%{
      "args" => ["--method POST", "repos/#{@repository}/issues"],
      "stdout" => %{"number" => number}
    })

    gh_rule(%{
      "args" => ["--method PATCH", "repos/#{@repository}/issues/#{number} "],
      "stdin" => [~s("state":"closed")],
      "stdout" => "{}"
    })

    issue_read(number)
    seen = length(gh_calls())
    input = %{"itemId" => item_id(slot), "repository" => @repository}
    {reply, _} = call("createIssue", input)
    if reply == :ok, do: Process.put({:pl_issue, slot}, number)

    for line <- Enum.drop(gh_calls(), seen),
        %{"args" => args, "stdin" => stdin} = JSON.decode!(line),
        "repos/#{@repository}/issues/#{number}" in args,
        {:ok, %{"state" => "closed", "state_reason" => reason}} <- [JSON.decode(stdin)] do
      Process.put(:pl_closed, Map.put(Process.get(:pl_closed), number, String.to_atom(reason)))
      touch([number])
      issue_read(number)
    end

    listed()
    observe(reply)
  end

  # A client nests the task in `slot` under `parent`, or under none, once a look has read
  # the plan; GitHub holds the look's list, as it was before, on a fifo until the nest is
  # in, then the case waits for the look.
  def nest_while_looking(slot, parent) do
    n = System.unique_integer([:positive])
    gate = Path.join(Process.get(:pl_gh), "look-#{n}")
    {_, 0} = System.cmd("mkfifo", [gate])
    hold = "if mkdir '#{gate}.held' 2>/dev/null; then read _ < '#{gate}' || :; fi"
    gh_rule(Map.put(listing(), "run", hold))
    case_pid = self()

    holder =
      spawn(fn ->
        ref = Process.monitor(case_pid)
        # Opening the fifo waits for the look's gh to read it.
        {:ok, fd} = :file.open(gate, [:write, :raw])
        send(case_pid, {:pl_looking, n})

        receive do
          :answer -> :file.close(fd)
          {:DOWN, ^ref, :process, _, _} -> :file.close(fd)
        end
      end)

    Process.put({:pl_holder, {:look, n}}, holder)

    {pid, ref} =
      spawn_monitor(fn ->
        try do
          call("sync", %{})
        catch
          :exit, _ -> :ok
        end
      end)

    receive do
      {:pl_looking, ^n} -> :ok
    after
      15_000 -> problem("the look never reached GitHub")
    end

    fields = %{"parent" => parent && item_id(parent)}
    reply = elem(call("updateItem", %{"id" => item_id(slot), "fields" => fields}), 0)
    send(holder, :answer)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      15_000 -> problem("the look never finished")
    end

    listed()
    observe(reply)
  end

  # Issue `number` of `@repository` as GitHub answers it: open, its reason "REOPENED" once
  # it was closed, or closed with the reason it was closed for, and when it last changed.
  defp issue_node(number) do
    {state, reason} =
      case Process.get(:pl_closed)[number] do
        nil -> {"OPEN", if(Process.get({:pl_reopened, number}), do: "REOPENED")}
        reason -> {"CLOSED", reason |> Atom.to_string() |> String.upcase()}
      end

    %{
      "number" => number,
      "title" => "Issue #{number}",
      "body" => "",
      "state" => state,
      "stateReason" => reason,
      "url" => "https://github.com/#{@repository}/issues/#{number}",
      "repository" => %{"nameWithOwner" => @repository},
      "updatedAt" => Map.get(Process.get(:pl_updated), number, "2026-10-01T00:00:00Z")
    }
  end

  # GitHub closes issue `number` as `:completed` or `:not_planned`: it leaves the listing
  # of open issues, and is answered as closed when read alone.
  def close(number, reason) do
    Process.put(:pl_closed, Map.put(Process.get(:pl_closed), number, reason))
    touch([number])
    issue_read(number)
    observe(:ok)
  end

  # GitHub reopens issue `number`, which the listing has again.
  def reopen(number) do
    Process.put(:pl_closed, Map.delete(Process.get(:pl_closed), number))
    Process.put({:pl_reopened, number}, true)
    touch([number])
    issue_read(number)
    observe(:ok)
  end

  # Someone takes the task's issue off the board the settings name, which the next board
  # read no longer lists.
  def unboard(slot) do
    board = Process.get(:pl_board)
    boards = Process.get(:pl_boards)
    items = Map.delete(Map.get(boards, board, %{}), Process.get({:pl_issue, slot}))
    Process.put(:pl_boards, Map.put(boards, board, items))
    observe(:ok)
  end

  # The boards hold more than a look reads (`full`), so a board read stops at its 500th
  # item with more to come, or hold no more than one page again.
  def crowd(full) do
    Process.put(:pl_full, full)
    observe(:ok)
  end

  # Issue `number` read alone, as GitHub has it now, and the listing with it or without.
  defp issue_read(number) do
    gh_rule(%{
      "args" => ["api graphql"],
      "stdin" => ["issue(number: $number) { ...IssueFields", ~s("number":#{number},)],
      "stdout" => %{"data" => %{"repository" => %{"issue" => issue_node(number)}}}
    })

    listed()
  end

  defp issue_list(nodes) do
    %{
      "args" => ["api graphql"],
      "stdin" => ["issues(first: $first"],
      "stdout" => %{
        "data" => %{
          "repository" => %{
            "issues" => %{
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
              "nodes" => nodes
            }
          }
        }
      }
    }
  end

  # The plugin looks at GitHub as the user asks it to.
  def look, do: observe(elem(call("sync", %{}), 0))

  # Renames the task to a name of the push's own and moves its due date. GitHub answers
  # every push carrying the name with `outcome`, at once, and writes the name down when
  # it takes it.
  #
  # With a push of the task on the way (`flying`), the rename only waits behind it.
  # Otherwise it pushes from a caller of its own, as another client's would, and GitHub
  # holds that push until `answer/1` lets it answer. The push is held on a fifo, whose
  # opening tells the case GitHub has it.
  def rename(slot, outcome, push, true) do
    gh_rule(name_rule(slot, push, outcome, ""))
    input = %{"id" => item_id(slot), "fields" => renamed(slot, push)}
    observe(elem(call("updateItem", input), 0))
  end

  def rename(slot, outcome, push, false) do
    title = "#{slot}#{push}"
    gate = gate(push)
    {_, 0} = System.cmd("mkfifo", [gate])
    hold = "if mkdir '#{gate}.held' 2>/dev/null; then read _ < '#{gate}' || :; fi; "
    gh_rule(name_rule(slot, push, outcome, hold))

    case_pid = self()

    holder =
      spawn(fn ->
        ref = Process.monitor(case_pid)
        # Opening the fifo waits for the push to read it.
        {:ok, fd} = :file.open(gate, [:write, :raw])
        send(case_pid, {:pl_asked, push})

        receive do
          :answer -> :file.close(fd)
          {:DOWN, ^ref, :process, _, _} -> :file.close(fd)
        end
      end)

    Process.put({:pl_holder, push}, holder)
    input = %{"id" => item_id(slot), "fields" => renamed(slot, push)}

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

    receive do
      {:pl_asked, ^push} -> :ok
    after
      15_000 -> problem("the push #{push} never reached GitHub")
    end

    await_plan(&Enum.any?(&1["items"], fn item -> item["title"] == title end))
    observe(:ok)
  end

  defp renamed(slot, push), do: %{"title" => "#{slot}#{push}", "due" => renamed_due(push)}

  # GitHub's answer to every push naming the task's issue `slot<push>`: `outcome`, after
  # running `hold`, writing the name down as the issue's when it takes it.
  defp name_rule(slot, push, outcome, hold) do
    number = Process.get({:pl_issue, slot})
    title = "#{slot}#{push}"

    took =
      if outcome == :ok,
        do: "echo '#{number} #{title}' >> '#{Path.join(Process.get(:pl_gh), "named")}'",
        else: ":"

    %{
      "args" => ["--method PATCH", "repos/#{@repository}/issues/#{number} "],
      "stdin" => [~s("title":#{JSON.encode!(title)})],
      "run" => hold <> took,
      "stdout" => "{}",
      "exit" => if(outcome == :ok, do: 0, else: 1),
      "stderr" => if(outcome == :ok, do: "", else: "HTTP 422: refused push #{push}\n")
    }
  end

  # GitHub answers the push, naming a board item it adds after it, and its caller tells
  # the planner, then pushes what the planner answers with until it answers nothing.
  def answer(push) do
    {pid, ref} = Process.get({:pl_push, push})

    if Process.alive?(pid) do
      gh_rule(board_item(push))
      send(Process.get({:pl_holder, push}), :answer)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        15_000 -> problem("the push #{push} never finished")
      end

      boarded("item-#{push}")
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

        {:both, slot} ->
          fields = %{"pullRequest" => pr_ref(), "issue" => issue_ref(slot)}

          %{
            "summary" => "Linked.",
            "changes" => [%{"op" => "link", "itemId" => item_id(slot), "fields" => fields}]
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

  def switch_board(board) do
    before = Process.whereis(@server)
    input = %{"id" => @id, "settings" => %{"board" => board}}
    reply = reply(HalC2.Plugins.handle("saveSettings", input))
    if reply == :ok, do: Process.put(:pl_board, board)
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

  defp pr_ref, do: %{"repository" => @repository, "number" => 40}
  defp issue_ref(slot), do: %{"repository" => @repository, "number" => @issues[slot]}

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
    # What the step put on a board, the next look reads.
    boarded("item-0")
    board_reads()
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
           name: item["title"],
           kind: String.to_existing_atom(item["kind"]),
           parent: slots[item["parent"]],
           after: Enum.map(item["after"], &slots[&1]),
           due: item["due"],
           issue: item["issue"]["number"],
           sync: sync_error(item["syncError"]),
           board: board_push(item["boardItemId"]),
           status: String.to_atom(item["status"]),
           state: issue_state(item["issue"])
         }}
      end

    # Work never starts in the model, so no task is linked to a thread.
    for {id, slot} <- slots,
        item = by_id[id],
        (item["threads"] || []) != [],
        do: problem("#{slot} has the threads #{inspect(item["threads"])}")

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
      github: named(),
      rel: related(),
      problems: Process.put(:pl_problems, []) |> Enum.reverse()
    }
  end

  # Issue → the name GitHub took for it last.
  defp named do
    case File.read(Path.join(Process.get(:pl_gh), "named")) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true), into: %{} do
          [number, name] = String.split(line, " ", parts: 2)
          {String.to_integer(number), name}
        end

      {:error, :enoent} ->
        %{}
    end
  end

  # The gh calls so far, one JSON line each.
  defp gh_calls do
    case File.read(System.get_env("FAKE_GH_LOG")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  # Puts on its board each issue a push added since the calls last read, as the board
  # item `item`, which GitHub named it: the board and issue are those of the read that
  # comes before each add.
  defp boarded(item) do
    calls = gh_calls()

    boards =
      calls
      |> Enum.drop(Process.get(:pl_calls_read))
      |> Enum.reduce(Process.get(:pl_boards), fn line, boards ->
        with %{"stdin" => stdin} <- JSON.decode!(line),
             {:ok, %{"query" => query, "variables" => vars}} <- JSON.decode(stdin),
             true <- String.contains?(query, "contentOwner"),
             %{"owner" => owner, "number" => number, "content" => n} <- vars do
          Map.update(boards, "#{owner}/#{number}", %{n => item}, &Map.put(&1, n, item))
        else
          _ -> boards
        end
      end)

    Process.put(:pl_boards, boards)
    Process.put(:pl_calls_read, length(calls))
  end

  # GitHub's answers to reading each board: the issues on it, as one page, or, while the
  # boards are full, as a page of 100 items with more after it, whatever page is asked
  # for, so a look stops at 500 and says the read was cut. The reads name no date field,
  # so a look takes no dates from them; a push finds "Target date" through a read of its
  # own.
  defp board_reads do
    full = Process.get(:pl_full)

    reads =
      for board <- [@board, @other_board] do
        [_owner, number] = String.split(board, "/")

        issues =
          for {n, item} <- Map.get(Process.get(:pl_boards), board, %{}) do
            %{
              "id" => item,
              "content" => Map.put(issue_node(n), "__typename", "Issue"),
              "fieldValues" => %{"nodes" => []}
            }
          end

        draft = %{
          "id" => "draft",
          "content" => %{"__typename" => "DraftIssue", "title" => "Someday"},
          "fieldValues" => %{"nodes" => []}
        }

        nodes = if full, do: issues ++ List.duplicate(draft, 100 - length(issues)), else: issues

        %{
          "board_read" => true,
          "args" => ["api graphql"],
          "stdin" => ["items(first: $first", ~s("number":#{number},)],
          "stdout" => %{
            "data" => %{
              "repositoryOwner" => %{
                "projectV2" => %{
                  "id" => "PVT_board",
                  "title" => "Board",
                  "url" => "https://github.com/orgs/acme/projects/#{number}",
                  "fields" => %{"nodes" => []},
                  "items" => %{
                    "pageInfo" => %{"hasNextPage" => full, "endCursor" => if(full, do: "more")},
                    "nodes" => nodes
                  }
                }
              }
            }
          }
        }
      end

    path = System.get_env("FAKE_GH_RULES")
    rules = reads ++ Enum.reject(path |> File.read!() |> JSON.decode!(), & &1["board_read"])
    File.write!(path <> ".tmp", JSON.encode!(rules))
    File.rename!(path <> ".tmp", path)
  end

  # The relations GitHub has, as the mutations asked of it in order made and dropped them.
  defp related do
    Enum.reduce(gh_calls(), MapSet.new(), fn line, rel ->
      with %{"args" => ["api", "graphql" | _], "stdin" => stdin} <- JSON.decode!(line),
           {:ok, %{"query" => query, "variables" => vars}} <- JSON.decode(stdin),
           [_, change, kind] <- Regex.run(~r/(add|remove)(BlockedBy|SubIssue)\(input/, query) do
        pair = {issue_number(vars["issue"]), issue_number(vars["other"])}
        relation = {if(kind == "BlockedBy", do: :blocked, else: :sub), pair}

        if change == "add",
          do: MapSet.put(rel, relation),
          else: MapSet.delete(rel, relation)
      else
        _ -> rel
      end
    end)
  end

  defp issue_number("I_" <> n), do: String.to_integer(n)

  # The state the plugin keeps of a task's issue.
  defp issue_state(nil), do: nil
  defp issue_state(%{"state" => "closed", "stateReason" => "not_planned"}), do: :not_planned
  defp issue_state(%{"state" => "closed"}), do: :completed
  defp issue_state(%{"state" => "open"}), do: :open

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

    # The project is on GitHub as `@repository`, which the plan follows and which lists no
    # issue yet, with the empty board `@board` whose due dates are its "Target date"; gh
    # answers the reads after a push that took, and a push the model holds waits for its
    # gate.
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

    # Relations are made by node id, which GitHub reads for both issues at once: issue n
    # is `I_<n>`. `number` and `other` sort before the variables after them.
    here = Enum.flat_map(Map.values(@issues), &[&1, &1 + 10])
    every = here ++ Enum.map(Map.values(@issues), &(&1 + @elsewhere_from))

    pairs =
      for a <- here, b <- every, a != b do
        %{
          "args" => ["api graphql"],
          "stdin" => ["other: repository(", ~s("number":#{a},), ~s("other":#{b},)],
          "stdout" => %{
            "data" => %{
              "issue" => %{"issue" => %{"id" => "I_#{a}"}},
              "other" => %{"issue" => %{"id" => "I_#{b}"}}
            }
          }
        }
      end

    File.write!(
      Path.join(gh, "rules.json"),
      JSON.encode!(
        [issue_list([]), board_item(0)] ++
          pairs ++
          [
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
          ]
      )
    )

    for {{tag, _} = key, _} <- Process.get(),
        tag in [:pl_push, :pl_holder, :pl_issue, :pl_reopened],
        do: Process.delete(key)

    Process.put(:pl_items, %{})
    Process.put(:pl_closed, %{})
    Process.put(:pl_updated, %{})
    Process.put(:pl_parents, %{})
    Process.put(:pl_blockers, %{})
    Process.put(:pl_board, @board)
    Process.put(:pl_boards, %{})
    Process.put(:pl_full, false)
    Process.put(:pl_calls_read, 0)
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
          "repositories" => [@repository],
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
    # So do the pushes GitHub still holds, whose callers find the plugin gone. Their
    # callers end before the next case begins: a gh one of them ran later would read
    # that case's rules and log, and put this case's issue on its board.
    for {{:pl_holder, _}, holder} <- Process.get(), do: send(holder, :answer)

    for {{:pl_push, _}, {pid, ref}} <- Process.get() do
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        if(Process.alive?(pid), do: 15_000, else: 0) -> :ok
      end
    end

    take_messages()
  end

  defp git!(dir, args) do
    {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end
end
