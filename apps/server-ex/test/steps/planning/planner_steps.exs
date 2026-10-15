defmodule HalC2.Steps.Planning.Planner do
  @moduledoc """
  Steps for `features/planning/planner.feature`, run against the real package in the
  repository's `plugins/planner`, copied into the MC's plugins directory as a user
  would install it.

  Every action's prompt ends in "answer from gate", so the fake Codex holds its turn
  open until the scenario writes the gate file (`end_turns/1`). The plan's today is
  held on `@today` unless a step moves it. The plugin's `plan` and `runs` topics are
  watched from the start, each on a client of its own; `await_topic/3` waits on them
  for what changes outside a call (a turn ending, a Slack reply). Agents call the
  plugin's tools through the MC's MCP endpoint as the thread's agent would.

  The sample tasks (`@samples`) are added on first mention, in the project "api";
  actions on the whole plan run on Schema, API (waiting for Schema) and Docs.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Steps.Support.GitHubIssues
  alias HalC2.Steps.Support.Slack, as: SlackSupport
  alias HalC2.Test.{FakeSlack, Mc}
  alias HalC2.Test.Mc.World

  @id "planner"
  @package Path.expand("../../../../../plugins/planner", __DIR__)
  @gate " answer from gate"
  @today "2026-10-15"
  @defaults @package
            |> Path.join("plugin.json")
            |> File.read!()
            |> JSON.decode!()
            |> Map.fetch!("settings")
            |> Enum.find(&(&1["key"] == "actions"))
            |> Map.fetch!("default")
  @samples %{
    "Schema" => {"2026-10-19", "2026-10-23"},
    "API" => {"2026-10-21", "2026-10-30"},
    "Docs" => {"2026-10-26", "2026-11-02"}
  }
  @healths %{"on track" => "on-track", "at risk" => "at-risk", "off track" => "off-track"}

  # --- background ------------------------------------------------------------------------

  step "an MC running the plugin {string}", %{args: [@id]} = context do
    dir = Path.join([context.mc.home, "plugins", @id])
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(@package, dir)
    World.put_app_env(:planner_today, @today)

    context =
      context
      |> World.agents()
      |> Fixtures.ensure()
      |> Fixtures.rescan()

    World.worktree_services()
    Mc.ensure(HalC2.Mcp)
    accepted = Enum.map(Fixtures.entry(@id)["permissions"], & &1["id"])

    {_, context} =
      World.call!(context, "plugins.enable", %{"id" => @id, "acceptPermissions" => accepted})

    assert %{"status" => "running"} = Fixtures.entry(@id)
    actions = Map.new(@defaults, fn {id, action} -> {id, gated(action, action["prompt"])} end)

    context
    |> Map.merge(%{
      planner: true,
      actions: actions,
      prs: %{},
      newer_prs: 0,
      older_prs: 0,
      watched: %{}
    })
    |> save(%{
      "provider" => "codex",
      "model" => "fake/one",
      "pollMinutes" => 60,
      "actions" => actions
    })
    |> watch("plan", "plan")
    |> watch("runs", "runs")
  end

  # --- tasks, milestones and dependencies ------------------------------------------------

  step "the user adds the task {string} in {string} from {string} to {string}",
       %{args: [title, project, start, due]} = context do
    add!(context, %{
      "title" => title,
      "projectId" => World.project(context, project).id,
      "start" => start,
      "due" => due
    })
  end

  step "the plan has {string} from {string} to {string}, not started",
       %{args: [title, start, due]} = context do
    assert %{"start" => ^start, "due" => ^due, "status" => "todo", "derivedProgress" => 0} =
             item!(context, title)

    context
  end

  step "the user adds the milestone {string} on {string}", %{args: [title, due]} = context do
    add!(context, %{"title" => title, "kind" => "milestone", "due" => due})
  end

  step "the plan has the milestone {string} on {string}", %{args: [title, due]} = context do
    assert %{"kind" => "milestone", "due" => ^due, "start" => nil} = item!(context, title)
    context
  end

  step "the plan has the task {string}", %{args: [title]} = context do
    if then?(context) do
      assert %{"kind" => "task"} = item!(context, title)
      context
    else
      ensure(context, title)
    end
  end

  step "the user adds the task {string} under {string}", %{args: [title, parent]} = context do
    add!(context, %{"title" => title, "parent" => item!(context, parent)["id"]})
  end

  step "{string} is a subtask of {string}", %{args: [title, parent]} = context do
    if then?(context) do
      assert item!(context, title)["parent"] == item!(context, parent)["id"]
      context
    else
      context = ensure(context, parent)
      ensure(context, title, %{"parent" => item!(context, parent)["id"]})
    end
  end

  step "the plan has {string} from {string} to {string}",
       %{args: [title, start, due]} = context do
    ensure(context, title, %{"start" => start, "due" => due})
  end

  step "the user makes {string} wait for {string}", %{args: [title, other]} = context do
    context = context |> ensure(title) |> ensure(other)
    item = item!(context, title)
    after_ids = item["after"] ++ [item!(context, other)["id"]]

    {reply, context} =
      plugin(context, "updateItem", %{"id" => item["id"], "fields" => %{"after" => after_ids}})

    Map.put(context, :reply, reply)
  end

  step "the user puts {string} under {string}", %{args: [title, parent]} = context do
    update!(context, title, %{"parent" => item!(context, parent)["id"]})
  end

  step "{string} is marked as starting before {string} ends", %{args: [title, other]} = context do
    assert item!(context, other)["id"] in item!(context, title)["early"]
    context
  end

  step "{string} waits for {string}", %{args: [title, other]} = context do
    context = context |> ensure(title) |> ensure(other)
    item = item!(context, title)

    update!(context, title, %{
      "after" => Enum.uniq(item["after"] ++ [item!(context, other)["id"]])
    })
  end

  step "the user is told that would make {string} wait for itself", %{args: [title]} = context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ "That would make #{title} wait for itself."
    context
  end

  step "a client adds a task with no title", context do
    {reply, context} = plugin(context, "addItem", %{"fields" => %{"status" => "todo"}})
    Map.put(context, :reply, reply)
  end

  step "a client changes {string} with fields that are not an object",
       %{args: [title]} = context do
    input = %{"id" => item!(context, title)["id"], "fields" => ["title", "Renamed"]}
    {reply, context} = plugin(context, "updateItem", input)
    Map.put(context, :reply, reply)
  end

  step "a client links {string} to a pull request and to an issue whose repository is not text",
       %{args: [title]} = context do
    id = item!(context, title)["id"]
    ref = %{"repository" => 7, "number" => 12}
    {reply, context} = plugin(context, "link", %{"itemId" => id, "pullRequest" => ref})
    assert {:error, _, _} = reply
    {reply, context} = plugin(context, "link", %{"itemId" => id, "issue" => ref})
    Map.put(context, :reply, reply)
  end

  step "a client links {string} to the pull request \#{int} and the issue \#{int} of {string} at once",
       %{args: [title, pr, issue, repository]} = context do
    input = %{
      "itemId" => item!(context, title)["id"],
      "pullRequest" => %{"repository" => repository, "number" => pr},
      "issue" => %{"repository" => repository, "number" => issue}
    }

    {reply, context} = plugin(context, "link", input)
    Map.put(context, :reply, reply)
  end

  step "{string} is linked to no pull request and no issue", %{args: [title]} = context do
    assert %{"pullRequests" => [], "issue" => nil} = item!(context, title)
    context
  end

  step "a client unlinks from {string} a pull request whose repository is not text",
       %{args: [title]} = context do
    input = %{"itemId" => item!(context, title)["id"], "kind" => "pullRequest"}
    input = Map.put(input, "ref", %{"repository" => 7, "number" => 12})
    {reply, context} = plugin(context, "unlink", input)
    Map.put(context, :reply, reply)
  end

  step "a client unlinks from {string} an issue it does not name", %{args: [title]} = context do
    input = %{"itemId" => item!(context, title)["id"], "kind" => "issue"}
    {reply, context} = plugin(context, "unlink", input)
    Map.put(context, :reply, reply)
  end

  step "{string} is linked to the issue \#{int} of {string}",
       %{args: [title, number, repository]} = context do
    context = ensure(context, title)
    issue = %{"repository" => repository, "number" => number}

    {reply, context} =
      plugin(context, "link", %{"itemId" => item!(context, title)["id"], "issue" => issue})

    assert {:ok, _} = reply
    Map.put(context, :repository, repository)
  end

  step "another client relinks {string} to the issue \#{int}",
       %{args: [title, number]} = context do
    issue = %{"repository" => context.repository, "number" => number}

    {reply, context} =
      plugin(context, "link", %{"itemId" => item!(context, title)["id"], "issue" => issue})

    assert {:ok, _} = reply
    context
  end

  step "a client that still shows \#{int} unlinks it from {string}",
       %{args: [number, title]} = context do
    ref = %{"repository" => context.repository, "number" => number}
    input = %{"itemId" => item!(context, title)["id"], "kind" => "issue", "ref" => ref}
    {reply, context} = plugin(context, "unlink", input)
    assert {:ok, _} = reply
    context
  end

  step "{string} is linked to the issue \#{int}", %{args: [title, number]} = context do
    assert %{"issue" => %{"number" => ^number}} = item!(context, title)
    context
  end

  step "the planner answers {string}", %{args: [message]} = context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ message
    context
  end

  step "the plan holds only {string}", %{args: [title]} = context do
    assert [%{"title" => ^title}] = plan!(context)["items"]
    context
  end

  step "{string} waits for nothing", %{args: [title]} = context do
    assert item!(context, title)["after"] == []
    context
  end

  step "the milestones {string} and {string}, with {string} waiting for {string}",
       %{args: [first, second, waiting, title]} = context do
    context = ensure(context, title)

    context =
      for milestone <- [first, second], reduce: context do
        context ->
          add!(context, %{"title" => milestone, "kind" => "milestone", "due" => "2026-11-30"})
      end

    update!(context, waiting, %{"after" => [item!(context, title)["id"]]})
  end

  step "the user moves {string} from {string} to {string}",
       %{args: [title, from, to]} = context do
    context = ensure(context, to)
    {reply, context} = plugin(context, "moveToMilestone", move_input(context, title, from, to))
    Map.put(context, :reply, reply)
  end

  step "{string} waits for {string} and {string} no longer does",
       %{args: [title, other, left]} = context do
    assert item!(context, title)["after"] == [item!(context, other)["id"]]
    refute item!(context, other)["id"] in item!(context, left)["after"]
    context
  end

  step "the user is told there is no milestone {string}", %{args: [title]} = context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ "There is no milestone #{item!(context, title)["id"]}."
    context
  end

  step "{string} still waits for {string}", %{args: [title, other]} = context do
    assert item!(context, other)["id"] in item!(context, title)["after"]
    context
  end

  step "today is {string}", %{args: [day]} = context do
    World.put_app_env(:planner_today, day)
    context
  end

  step "the plan has {string} due {string} and in progress", %{args: [title, due]} = context do
    ensure(context, title, %{"due" => due, "status" => "doing"})
  end

  step "{string} is marked late", %{args: [title]} = context do
    assert item!(context, title)["late"] == true
    context
  end

  step "the user removes {string}", %{args: [name]} = context do
    {reply, context} =
      case Enum.find(plan!(context)["views"], &(&1["name"] == name)) do
        nil -> plugin(context, "removeItem", %{"id" => item!(context, name)["id"]})
        view -> plugin(context, "removeView", %{"id" => view["id"]})
      end

    assert {:ok, _} = reply
    context
  end

  step "the user has removed {string}", %{args: [title]} = context do
    {reply, context} = plugin(context, "removeItem", %{"id" => item!(context, title)["id"]})
    assert {:ok, _} = reply
    context
  end

  step "{string} has no parent", %{args: [title]} = context do
    assert item!(context, title)["parent"] == nil
    context
  end

  step "{string} has the subtasks {string}, done, and {string}, not started",
       %{args: [parent, done, todo]} = context do
    context = ensure(context, parent)
    id = item!(context, parent)["id"]

    context
    |> ensure(done, %{"parent" => id, "status" => "done"})
    |> ensure(todo, %{"parent" => id, "status" => "todo"})
  end

  step "{string} is {int}% done", %{args: [title, progress]} = context do
    assert item!(context, title)["derivedProgress"] == progress
    context
  end

  step "the user sets {string} to {int}% done", %{args: [title, progress]} = context do
    update!(context, title, %{"progress" => progress})
  end

  step "the user saves a baseline", context do
    {reply, context} = plugin(context, "setBaseline", %{})
    assert {:ok, _} = reply
    context
  end

  step "{string} moves to end on {string}", %{args: [title, due]} = context do
    context |> ensure(title) |> update!(title, %{"due" => due})
  end

  step "{string} shows it ends {int} days after its baseline", %{args: [title, days]} = context do
    assert item!(context, title)["slip"] == days
    context
  end

  step "two clients watch the plan", context do
    context |> watch("a", "plan") |> watch("b", "plan")
  end

  step "the user moves {string} to start on {string}", %{args: [title, start]} = context do
    context |> ensure(title) |> update!(title, %{"start" => start})
  end

  step "both clients see {string} start on {string}", %{args: [title, start]} = context do
    starts = fn plan ->
      Enum.find(plan["items"], &(&1["title"] == title and &1["start"] == start))
    end

    {_, context} = await_topic(context, "a", starts)
    {_, context} = await_topic(context, "b", starts)
    context
  end

  # --- views -----------------------------------------------------------------------------

  step "the user opens the plan for the first time", context do
    Map.put(context, :opened, plan!(context))
  end

  step "it has the views {string}, {string} and {string}", %{args: names} = context do
    assert Enum.map(context.opened["views"], & &1["name"]) == names
    context
  end

  step "the user saves the view {string} as a Gantt chart of {string} grouped by owner, zoomed to weeks, without done tasks",
       %{args: [name, project]} = context do
    view = %{
      "name" => name,
      "layout" => "gantt",
      "filter" => %{"projects" => [World.project(context, project).id], "hideDone" => true},
      "groupBy" => "owner",
      "zoom" => "week"
    }

    {reply, context} = plugin(context, "saveView", %{"view" => view})
    assert {:ok, %{"view" => _}} = reply
    Map.put(context, :view, view)
  end

  step "every client has the view {string} with that layout, filter, grouping and zoom",
       %{args: [name]} = context do
    expected = context.view

    laid_out = fn plan ->
      Enum.find(plan["views"], fn view ->
        view["name"] == name and
          Map.take(view, ~w(layout groupBy zoom)) == Map.take(expected, ~w(layout groupBy zoom)) and
          Map.take(view["filter"], ~w(projects hideDone)) == expected["filter"]
      end)
    end

    {_, context} = await_topic(context, "plan", laid_out)
    # A client that starts watching now gets it with the plan.
    context = watch(context, "late", "plan")
    {_, context} = await_topic(context, "late", laid_out)
    context
  end

  step "the user saves a view grouped by {string}", %{args: [group]} = context do
    {reply, context} =
      plugin(context, "saveView", %{"view" => %{"name" => "Mine", "groupBy" => group}})

    Map.put(context, :reply, reply)
  end

  step "the user is told {string} is not something a view can group by",
       %{args: [group]} = context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ "#{group} is not something a view can group by."
    context
  end

  step "the view {string}", %{args: [name]} = context do
    {reply, context} =
      plugin(context, "saveView", %{"view" => %{"name" => name, "layout" => "gantt"}})

    assert {:ok, _} = reply

    {_, context} =
      await_topic(context, "plan", fn plan -> Enum.find(plan["views"], &(&1["name"] == name)) end)

    context
  end

  step "no client has the view {string}", %{args: [name]} = context do
    {_, context} =
      await_topic(context, "plan", fn plan ->
        not Enum.any?(plan["views"], &(&1["name"] == name))
      end)

    refute Enum.any?(plan!(context)["views"], &(&1["name"] == name))
    context
  end

  # --- actions ---------------------------------------------------------------------------

  step "the user opens the settings of {string}", %{args: [@id]} = context do
    {reply, context} = plugin(context, "settings", %{})
    assert {:ok, settings} = reply
    Map.put(context, :settings, settings)
  end

  step "the actions {string}, {string}, {string}, {string}, {string} and {string} are there, each with its prompt",
       %{args: labels} = context do
    actions = Map.values(context.settings["settings"]["actions"])
    assert Enum.sort(Enum.map(actions, & &1["label"])) == Enum.sort(labels)
    assert Enum.all?(actions, &(String.trim(&1["prompt"]) != ""))

    assert Enum.sort(Enum.map(Map.values(context.settings["defaultActions"]), & &1["label"])) ==
             Enum.sort(labels)

    context
  end

  step "the action {string} has the prompt {string}", %{args: [label, prompt]} = context do
    set_prompt(context, label, String.replace(prompt, "\\n", "\n") <> @gate)
  end

  step "the user runs {string} on {string}, due {string}",
       %{args: [label, title, due]} = context do
    context |> ensure(title, %{"due" => due}) |> start_run(label, title)
  end

  step "a thread in {string} starts with the configured agent and {string}",
       %{args: [project, text]} = context do
    thread = thread(context.thread)
    assert thread["projectId"] == World.project(context, project).id
    assert %{"instanceId" => "codex", "model" => "fake/one"} = thread["modelSelection"]
    assert String.starts_with?(prompt(context.thread), text)
    context
  end

  step "the run of {string} on {string} is running", %{args: [label, title]} = context do
    if then?(context) do
      run = run!(context)
      assert %{"status" => "running", "label" => ^label} = run
      assert run["itemIds"] == [item!(context, title)["id"]]
      context
    else
      start_run(context, label, title)
    end
  end

  step "its thread starts with today's date and every task with its dates, state and dependencies",
       context do
    text = prompt(context.thread)
    items = plan!(context)["items"]
    assert String.starts_with?(text, "Today is #{@today}. The plan:\n")

    for item <- items do
      assert text =~
               "- [#{item["id"]}] #{item["title"]} (task, #{item["status"]}, 0% done): #{item["start"]} to #{item["due"]}"
    end

    schema = Enum.find(items, &(&1["title"] == "Schema"))
    assert text =~ "waits for Schema [#{schema["id"]}]"
    context
  end

  step "the user adds the action {string} on the whole plan with the prompt {string}",
       %{args: [label, prompt]} = context do
    id = label |> String.downcase() |> String.replace(" ", "-")

    action = %{
      "label" => label,
      "scope" => "plan",
      "kind" => "action",
      "apply" => "propose",
      "prompt" => prompt <> @gate
    }

    save_actions(context, Map.put(context.actions, id, action))
  end

  step "{string} can be run on the plan", %{args: [label]} = context do
    assert Enum.any?(plan!(context)["actions"], &(&1["label"] == label and &1["scope"] == "plan"))
    context = start_run(context, label)
    prompt = Enum.find_value(context.actions, fn {_, a} -> a["label"] == label && a["prompt"] end)
    lead = prompt |> String.split("{{") |> hd()
    assert String.starts_with?(prompt(context.thread), lead <> "- [")
    context
  end

  step "the user changed the prompt of {string}", %{args: [label]} = context do
    set_prompt(context, label, "Something of my own about {{plan}}." <> @gate)
  end

  step "the user resets the prompt of {string}", %{args: [label]} = context do
    {reply, context} = plugin(context, "settings", %{})
    assert {:ok, %{"defaultActions" => defaults}} = reply
    set_prompt(context, label, defaults[action_id(context, label)]["prompt"])
  end

  step "the next run of {string} uses the plugin's prompt", %{args: [label]} = context do
    context = start_run(context, label)
    text = prompt(context.thread)
    [lead, rest] = String.split(@defaults[action_id(context, label)]["prompt"], "{{plan}}")
    assert String.starts_with?(text, String.replace(lead, "{{today}}", @today))
    assert text =~ String.trim(rest)
    context
  end

  step "the user saves the action {string} with an empty prompt", %{args: [label]} = context do
    id = action_id(context, label)
    actions = put_in(context.actions, [id, "prompt"], "")

    {reply, context} =
      World.call(context, "plugins.saveSettings", %{
        "id" => @id,
        "settings" => %{"actions" => actions}
      })

    Map.put(context, :reply, reply)
  end

  step "the save is refused saying the prompt of {string} cannot be empty",
       %{args: [label]} = context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ "the prompt of #{label} cannot be empty"

    assert String.trim(plan_settings(context)["actions"][action_id(context, label)]["prompt"]) !=
             ""

    context
  end

  step "the default project of {string} is {string}", %{args: [@id, project]} = context do
    save(context, %{"defaultProject" => World.project(context, project).id})
  end

  step "{string} has no default project", %{args: [@id]} = context do
    save(context, %{"defaultProject" => ""})
  end

  step "the plan has {string} in no project", %{args: [title]} = context do
    ensure(context, title, %{"projectId" => nil})
  end

  step "the user runs {string} on {string}", %{args: [label, title]} = context do
    context = ensure(context, title)
    ids = [item!(context, title)["id"]]

    {reply, context} =
      plugin(context, "run", %{"action" => action_id(context, label), "itemIds" => ids})

    case reply do
      {:ok, %{"run" => run}} -> started(context, run)
      _ -> Map.put(context, :reply, reply)
    end
  end

  step "its thread starts in {string}", %{args: [project]} = context do
    assert thread(context.thread)["projectId"] == World.project(context, project).id
    context
  end

  step "the user is told to give {string} a project or set a default project",
       %{args: [title]} = context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ "Give #{title} a project or set a default project"
    context
  end

  step "the run of {string} is running", %{args: [label]} = context do
    start_run(context, label)
  end

  step "its agent reads the plan", context do
    Map.put(context, :read, tool!(context, "planner_read", %{}))
  end

  step "it gets every task with its dates, state, progress, dependencies and links", context do
    items = context.read["items"]
    assert context.read["today"] == @today

    assert Enum.map(items, & &1["id"]) |> Enum.sort() ==
             plan!(context)["items"] |> Enum.map(& &1["id"]) |> Enum.sort()

    for item <- items do
      assert Enum.all?(
               ~w(start due status derivedProgress after pullRequests issue),
               &Map.has_key?(item, &1)
             )
    end

    schema = Enum.find(items, &(&1["title"] == "Schema"))

    assert %{"start" => "2026-10-21", "due" => "2026-10-30", "after" => [id]} =
             Enum.find(items, &(&1["title"] == "API"))

    assert id == schema["id"]
    context
  end

  step "the run is failed saying the agent reported nothing", context do
    {run, context} = await_run(context, &(&1["status"] == "failed"))
    assert run["error"] =~ "finished without reporting"
    context
  end

  step "the run of {string} on {string} failed", %{args: [label, title]} = context do
    context = context |> start_run(label, title) |> end_turns()
    {_, context} = await_run(context, &(&1["status"] == "failed"))
    context
  end

  step "a new thread starts for {string} on {string}", %{args: [label, title]} = context do
    run = context.retried
    assert run["id"] == context.run["id"]
    assert run["threadId"] not in [nil, context.thread]
    assert %{"label" => ^label, "status" => "running"} = run
    assert run["itemIds"] == [item!(context, title)["id"]]
    World.await_row(run["threadId"], & &1, 10_000)
    context
  end

  step "the run is failed saying the plugin stopped while it ran", context do
    run = run!(context)
    assert %{"status" => "failed"} = run
    assert run["error"] =~ "planner restarted"
    assert run["threadId"] == context.thread
    context
  end

  step "its agent can still report", context do
    assert %{"reported" => true, "status" => "done"} =
             report!(context, %{"summary" => "Nothing to change."})

    assert %{"status" => "done", "summary" => "Nothing to change."} = run!(context)
    context
  end

  # --- proposals -------------------------------------------------------------------------

  step "its agent reports moving {string} to end on {string} because {string}",
       %{args: [title, due, reason]} = context do
    report!(context, %{"summary" => "Moved.", "changes" => [move(context, title, due, reason)]})
    context
  end

  step "the run proposes moving {string} to end on {string} with the reason",
       %{args: [title, due]} = context do
    run = run!(context)
    id = item!(context, title)["id"]
    assert %{"status" => "proposed", "changes" => [change]} = run

    assert %{"op" => "update", "itemId" => ^id, "fields" => %{"due" => ^due}, "reason" => reason} =
             change

    assert reason not in [nil, ""]
    context
  end

  step "{string} still ends on {string}", %{args: [title, due]} = context do
    assert item!(context, title)["due"] == due
    context
  end

  step "the run of {string} proposes moving {string} and {string}",
       %{args: [label, one, two]} = context do
    propose(context, label, [one, two])
  end

  step "the run of {string} proposes moving {string}", %{args: [label, title]} = context do
    propose(context, label, [title])
  end

  step "the user dismisses the change to {string} and applies the run",
       %{args: [title]} = context do
    id = item!(context, title)["id"]
    change = Enum.find(run!(context)["changes"], &(&1["itemId"] == id))

    {reply, context} =
      plugin(context, "dismissChange", %{"runId" => context.run["id"], "changeId" => change["id"]})

    assert {:ok, _} = reply
    apply_run(context)
  end

  step "{string} is moved and {string} is not", %{args: [moved, kept]} = context do
    assert item!(context, moved)["due"] == context.moves[moved]
    assert item!(context, kept)["due"] == elem(@samples[kept], 1)
    context
  end

  step "the run is applied", context do
    assert %{"status" => "applied"} = run!(context)
    context
  end

  step "its agent reports the subtasks {string} and {string}, the second waiting for the first",
       %{args: [first, second]} = context do
    parent = hd(context.run["itemIds"])

    changes = [
      %{
        "op" => "add",
        "ref" => "a",
        "fields" => %{
          "title" => first,
          "parent" => parent,
          "start" => "2026-10-19",
          "due" => "2026-10-22"
        }
      },
      %{
        "op" => "add",
        "ref" => "b",
        "fields" => %{
          "title" => second,
          "parent" => parent,
          "after" => ["a"],
          "start" => "2026-10-23",
          "due" => "2026-10-27"
        }
      }
    ]

    assert %{"status" => "proposed"} =
             report!(context, %{"summary" => "Two parts.", "changes" => changes})

    context
  end

  step "the user applies the run", context do
    apply_run(context)
  end

  step "the user applies it", context do
    apply_run(context)
  end

  step "{string} has the subtasks {string} and {string}, the second waiting for the first",
       %{args: [parent, first, second]} = context do
    plan = plan!(context)
    id = item(plan, parent)["id"]
    first = item(plan, first)
    assert %{"parent" => ^id} = first
    assert %{"parent" => ^id, "after" => [after_id]} = item(plan, second)
    assert after_id == first["id"]
    context
  end

  step "the change to {string} is marked as no longer applicable", %{args: [title]} = context do
    change = Enum.find(run!(context)["changes"], &(&1["itemId"] == context.moved_ids[title]))
    assert %{"outcome" => "stale", "staleReason" => reason} = change
    assert reason =~ "no longer in the plan"
    context
  end

  step "its agent reports making {string} wait for {string}", %{args: [title, other]} = context do
    change = %{
      "op" => "update",
      "itemId" => item!(context, title)["id"],
      "fields" => %{"after" => [item!(context, other)["id"]]}
    }

    Map.put(
      context,
      :tool_result,
      tool(context, "planner_report", %{"summary" => "Reordered.", "changes" => [change]})
    )
  end

  step "its agent reports linking {string} to the pull request \#{int} and the issue \#{int} of {string} at once",
       %{args: [title, pr, issue, repository]} = context do
    change = %{
      "op" => "link",
      "itemId" => item!(context, title)["id"],
      "fields" => %{
        "pullRequest" => %{"repository" => repository, "number" => pr},
        "issue" => %{"repository" => repository, "number" => issue}
      }
    }

    Map.put(
      context,
      :tool_result,
      tool(context, "planner_report", %{"summary" => "Linked.", "changes" => [change]})
    )
  end

  step "the agent is told {string}", %{args: [message]} = context do
    assert %{"isError" => true} = context.tool_result
    assert inspect(context.tool_result) =~ message
    context
  end

  step "the agent is told that would make {string} wait for itself", %{args: [title]} = context do
    assert %{"isError" => true} = context.tool_result
    assert inspect(context.tool_result) =~ "That would make #{title} wait for itself."
    context
  end

  step "its agent reports making {string} wait for the task {string}",
       %{args: [title, id]} = context do
    change = %{
      "op" => "update",
      "itemId" => item!(context, title)["id"],
      "fields" => %{"after" => [id]}
    }

    Map.put(
      context,
      :tool_result,
      tool(context, "planner_report", %{"summary" => "Reordered.", "changes" => [change]})
    )
  end

  step "the agent is told there is no task {string}", %{args: [id]} = context do
    assert %{"isError" => true} = context.tool_result
    assert inspect(context.tool_result) =~ "There is no task #{id}."
    context
  end

  step "the run is still running", context do
    assert %{"status" => "running", "changes" => []} = run!(context)
    context
  end

  step "{string} applies its changes without asking", %{args: [label]} = context do
    id = action_id(context, label)
    save_actions(context, put_in(context.actions, [id, "apply"], "apply"))
  end

  step "its agent reports {string} is {int}% done", %{args: [title, progress]} = context do
    change = %{
      "op" => "update",
      "itemId" => item!(context, title)["id"],
      "fields" => %{"progress" => progress}
    }

    report!(context, %{"summary" => "Checked.", "changes" => [change]})
    context
  end

  step "the user discards the run", context do
    {reply, context} = plugin(context, "discard", %{"runId" => context.run["id"]})
    assert {:ok, _} = reply
    context
  end

  step "the planner keeps the {int} latest finished runs", %{args: [kept]} = context do
    World.put_app_env(:planner_kept_runs, kept)
    context
  end

  step "{string}, {string} and {string} each run and report nothing to change",
       %{args: labels} = context do
    proposal = context.run["id"]

    {finished, context} =
      Enum.map_reduce(labels, context, fn label, context ->
        context = start_run(context, label)
        report!(context, %{"summary" => "Nothing to change."})
        {context.run["id"], context}
      end)

    Map.merge(context, %{proposal: proposal, finished: finished})
  end

  step "the runs are the proposal of {string} and the last two that finished",
       %{args: [label]} = context do
    runs = runs!(context)

    assert %{"label" => ^label, "status" => "proposed"} =
             Enum.find(runs, &(&1["id"] == context.proposal))

    kept = [context.proposal | Enum.take(context.finished, -2)]
    assert Enum.sort(Enum.map(runs, & &1["id"])) == Enum.sort(kept)
    context
  end

  step "{string} is not moved and the run is gone", %{args: [title]} = context do
    assert item!(context, title)["due"] == elem(@samples[title], 1)
    refute Enum.any?(runs!(context), &(&1["id"] == context.run["id"]))
    context
  end

  step "its agent reports the feedback {string} on {string} and {string} on the plan",
       %{args: [text, title, on_plan]} = context do
    feedback = [%{"itemId" => item!(context, title)["id"], "text" => text}, %{"text" => on_plan}]
    report!(context, %{"summary" => "Looked at it.", "feedback" => feedback})
    context
  end

  step "{string} has the feedback {string}", %{args: [title, text]} = context do
    if then?(context) do
      assert text in Enum.map(item!(context, title)["feedback"], & &1["text"])
      context
    else
      context = context |> ensure(title) |> start_run("Give feedback")

      report!(context, %{
        "summary" => "Looked.",
        "feedback" => [%{"itemId" => item!(context, title)["id"], "text" => text}]
      })

      Map.put(context, :feedback, {title, text})
    end
  end

  step "the run's summary has {string}", %{args: [text]} = context do
    assert run!(context)["summary"] =~ text
    context
  end

  step "the user dismisses that feedback", context do
    {title, text} = context.feedback
    item = item!(context, title)
    feedback = Enum.find(item["feedback"], &(&1["text"] == text))

    {reply, context} =
      plugin(context, "dismissFeedback", %{"itemId" => item["id"], "feedbackId" => feedback["id"]})

    assert {:ok, _} = reply
    context
  end

  step "{string} has no feedback", %{args: [title]} = context do
    assert item!(context, title)["feedback"] == []
    context
  end

  step "its agent reports the plan is {string} with {string}",
       %{args: [health, text]} = context do
    # An update from before the run, which the run's must not replace.
    {earlier, context} = post_update(context, "on track", "Earlier, all on track.")
    report!(context, %{"summary" => text, "health" => @healths[health]})
    Map.put(context, :earlier, earlier)
  end

  step "the plan's latest update is {string} with {string}", %{args: [health, text]} = context do
    health = @healths[health]
    assert %{"health" => ^health, "text" => ^text} = hd(plan!(context)["updates"])
    context
  end

  step "the earlier updates are kept", context do
    updates = plan!(context)["updates"]
    assert length(updates) == 2
    assert List.last(updates)["id"] == context.earlier["id"]
    context
  end

  step "the user posts the update {string} with {string}", %{args: [health, text]} = context do
    {_, context} = post_update(context, health, text)
    context
  end

  # --- work on a task --------------------------------------------------------------------

  step "a thread in a new worktree of {string} starts working on {string}",
       %{args: [project, title]} = context do
    id = context.thread

    thread =
      World.await_stream(
        id,
        fn state ->
          thread = HalC2.StreamState.get(state, "thread")[id]
          thread && thread["worktreePath"] && thread
        end,
        15_000
      )

    assert thread["projectId"] == World.project(context, project).id
    assert thread["worktreePath"] != World.project(context, project).root
    assert String.starts_with?(prompt(id), ~s(Work on "#{title}"))
    context
  end

  # The task is marked once its thread has started, after the run's reply.
  step "the thread is linked to {string}", %{args: [title]} = context do
    {_, context} =
      await_topic(context, "plan", fn plan ->
        context.thread in ((item(plan, title) || %{})["threads"] || [])
      end)

    context
  end

  step "{string} is in progress", %{args: [title]} = context do
    {_, context} = await_topic(context, "plan", &match?(%{"status" => "doing"}, item(&1, title)))
    context
  end

  step "{string} runs its actions with an agent this MC does not have",
       %{args: [@id]} = context do
    save(context, %{"provider" => "nowhere", "model" => ""})
  end

  step "the user starts work on {string}", %{args: [title]} = context do
    context = ensure(context, title)
    ids = [item!(context, title)["id"]]

    {reply, context} =
      plugin(context, "run", %{"action" => action_id(context, "Start work"), "itemIds" => ids})

    assert {:ok, %{"run" => run}} = reply
    Map.put(context, :run, run)
  end

  # The launch's call to the worktree setup exits, with no process to answer it.
  step "the MC cannot set up worktrees", context do
    :ok = ExUnit.Callbacks.stop_supervised(HalC2.WorktreeSetup)
    context
  end

  step "the run is failed saying its thread could not start", context do
    {run, context} = await_run(context, &(&1["status"] == "failed"))
    assert run["error"] =~ "The thread could not start"
    context
  end

  step "the run is failed saying there is no such agent", context do
    {run, context} = await_run(context, &(&1["status"] == "failed"))
    assert run["error"] =~ "There is no agent nowhere"
    context
  end

  step "{string} is not started and no thread is linked to it", %{args: [title]} = context do
    assert %{"status" => "todo"} = item = item!(context, title)
    assert (item["threads"] || []) == []
    context
  end

  step "{string} runs one action at a time", %{args: [@id]} = context do
    save(context, %{"concurrency" => 1})
  end

  step "the user starts work on {string}, which waits its turn", %{args: [title]} = context do
    context = ensure(context, title)

    {reply, context} =
      plugin(context, "run", %{
        "action" => action_id(context, "Start work"),
        "itemIds" => [item!(context, title)["id"]]
      })

    assert {:ok, %{"run" => %{"status" => "queued"} = run}} = reply
    Map.put(context, :queued, run)
  end

  step "{string} is removed and the work on {string} ends", %{args: [title, _]} = context do
    {reply, context} = plugin(context, "removeItem", %{"id" => item!(context, title)["id"]})
    assert {:ok, _} = reply
    end_turns(context)
  end

  step "the work on {string} is failed saying its task was removed", context do
    {run, context} = await_run(%{context | run: context.queued}, &(&1["status"] == "failed"))
    assert run["error"] =~ "task was removed"
    assert run["threadId"] == nil
    context
  end

  step "the user started work on {string}", %{args: [title]} = context do
    start_run(context, "Start work", title)
  end

  step "its agent reports {string} is {int}% done with the note {string}",
       %{args: [title, progress, note]} = context do
    tool!(context, "planner_progress", %{
      "itemId" => item!(context, title)["id"],
      "progress" => progress,
      "note" => note
    })

    Map.put(context, :note, note)
  end

  step "{string} is {int}% done with that note", %{args: [title, progress]} = context do
    assert %{"derivedProgress" => ^progress, "note" => note} = item!(context, title)
    assert note == context.note
    context
  end

  step "its agent links the pull request \#{int} of {string}",
       %{args: [number, repository]} = context do
    tool!(context, "planner_progress", %{
      "pullRequest" => %{"repository" => repository, "number" => number}
    })

    context
  end

  step "{string} is linked to \#{int}", %{args: [title, number]} = context do
    assert number in Enum.map(item!(context, title)["pullRequests"], & &1["number"])
    context
  end

  step "an agent in a thread {string} did not start lists its tools", %{args: [@id]} = context do
    context = World.create_thread(context, "Not the planner's", "api")
    Map.put(context, :tools, tools(context.threads["Not the planner's"]))
  end

  step "no planner tool is offered", context do
    refute Enum.any?(context.tools, &String.starts_with?(&1, "planner_"))
    context
  end

  step "{string} offers the plan to every thread", %{args: [@id]} = context do
    save(context, %{"offerToAllThreads" => true})
  end

  step "an agent in any thread lists its tools", context do
    context = World.create_thread(context, "Any thread", "api")
    thread = context.threads["Any thread"]
    Map.merge(context, %{tools: tools(thread), thread: thread})
  end

  step "it can read the plan but not change it", context do
    assert "planner_read" in context.tools
    refute "planner_report" in context.tools
    refute "planner_progress" in context.tools
    assert %{"today" => @today, "items" => _} = tool!(context, "planner_read", %{})
    assert %{"isError" => true} = tool(context, "planner_report", %{"summary" => "Mine now."})
    context
  end

  # --- pull requests and GitHub issues ---------------------------------------------------

  step "{string} is linked to \#{int} of {string}",
       %{args: [title, number, repository]} = context do
    context |> ensure(title) |> link_prs(title, repository, [number])
  end

  step "{string} is linked to \#{int} and \#{int} of {string}, and \#{int} is merged",
       %{args: [title, one, two, repository, merged]} = context do
    context
    |> ensure(title)
    |> link_prs(title, repository, [one, two])
    |> merge(merged)
  end

  # The plugin reads tasks in id order; one read after a task that saw the merge
  # is the one whose open copy of the pull request was dropped.
  step "{string} is linked to the merged \#{int} of {string}",
       %{args: [title, number, repository]} = context do
    context |> add_last(title) |> link_prs(title, repository, [number]) |> merge(number)
  end

  step "\#{int} is merged", %{args: [number]} = context do
    merge(context, number)
  end

  # A repository no project checks out is not listed; its pull request is read alone.
  step "\#{int} of {string} is merged", %{args: [number, repository]} = context do
    pr = Shared.gh_pr(repository, number, %{"state" => "MERGED"})
    World.cli_rules(context, [%{"args" => ["pr view #{number}", repository], "stdout" => pr}])
  end

  step "{string} has {int} pull requests updated since \#{int}",
       %{args: [_repository, count, _number]} = context do
    pr_list(%{context | newer_prs: count})
  end

  step "{string} has {int} pull requests updated before \#{int}",
       %{args: [_repository, count, _number]} = context do
    pr_list(%{context | older_prs: count})
  end

  step "the plugin read no page of {string}'s pull requests past \#{int}",
       %{args: [_repository, _number]} = context do
    assert [_first] = World.cli_calls(context, "pr list")
    context
  end

  step "the plugin did not list {string}'s pull requests again", context do
    assert [_first] = World.cli_calls(context, "pr list")
    context
  end

  step "the plugin looks at GitHub", context do
    {reply, context} = plugin(context, "sync", %{})
    assert {:ok, %{"items" => _}} = reply
    context
  end

  step "{string} is done", %{args: [title]} = context do
    assert item!(context, title)["status"] == "done"
    context
  end

  step "{string} follows the issues of {string}", %{args: [@id, repository]} = context do
    save(context, %{"repositories" => [repository], "sync" => "import"})
  end

  step "{string} follows the issues of {string} labelled {string}",
       %{args: [@id, repository, label]} = context do
    save(context, %{"repositories" => [repository], "sync" => "import", "issueLabel" => label})
  end

  step "{string} has the open issue \#{int} {string} assigned to {string} with the label {string}",
       %{args: [repository, number, title, owner, label]} = context do
    GitHubIssues.answers(context, repository, [
      GitHubIssues.issue(repository, number, %{
        "title" => title,
        "assignees" => %{"nodes" => [%{"login" => owner}]},
        "labels" => %{"nodes" => [%{"name" => label}]}
      })
    ])
  end

  step "the plan has {string} linked to \#{int}, owned by {string} with the label {string}",
       %{args: [title, number, owner, label]} = context do
    assert %{"issue" => %{"number" => ^number}, "owner" => ^owner, "labels" => [^label]} =
             item!(context, title)

    context
  end

  step "{string} has the open issues \#{int} labelled {string} and \#{int} without it",
       %{args: [repository, labelled, label, other]} = context do
    GitHubIssues.answers(context, repository, [
      GitHubIssues.issue(repository, labelled, %{"labels" => %{"nodes" => [%{"name" => label}]}}),
      GitHubIssues.issue(repository, other)
    ])
  end

  step "the plan has \#{int} and not \#{int}", %{args: [present, absent]} = context do
    plan = plan!(context)
    assert task_of(plan, present)
    refute task_of(plan, absent)
    context
  end

  step "{string} has the milestone {string} due {string} holding \#{int}",
       %{args: [repository, title, due, number]} = context do
    milestone = %{"number" => 1, "title" => title, "dueOn" => due <> "T00:00:00Z"}

    GitHubIssues.answers(context, repository, [
      GitHubIssues.issue(repository, number, %{"milestone" => milestone})
    ])
  end

  step "the plan has the milestone {string} on {string} waiting for \#{int}'s task",
       %{args: [title, due, number]} = context do
    plan = plan!(context)
    assert %{"kind" => "milestone", "due" => ^due, "after" => after_ids} = item(plan, title)
    assert task_of(plan, number)["id"] in after_ids
    context
  end

  step "\#{int} is a sub-issue of \#{int}, and \#{int} is blocked by \#{int}",
       %{args: [sub, number, number, blocker]} = context do
    repository = context.repository

    GitHubIssues.answers(context, repository, [
      GitHubIssues.issue(repository, number, %{"subIssues" => [sub], "blockedBy" => [blocker]}),
      GitHubIssues.issue(repository, sub, %{"parent" => number}),
      GitHubIssues.issue(repository, blocker, %{"blocking" => [number]})
    ])
  end

  step "\#{int}'s task is a subtask of \#{int}'s, and \#{int}'s task waits for \#{int}'s",
       %{args: [sub, number, number, blocker]} = context do
    plan = plan!(context)
    task = task_of(plan, number)
    assert task_of(plan, sub)["parent"] == task["id"]
    assert task["after"] == [task_of(plan, blocker)["id"]]
    context
  end

  step "\#{int}'s task was imported as a subtask of \#{int}'s",
       %{args: [sub, number]} = context do
    repository = context.repository

    context =
      context
      |> GitHubIssues.answers(repository, [
        GitHubIssues.issue(repository, number, %{"subIssues" => [sub]}),
        GitHubIssues.issue(repository, sub, %{"parent" => number})
      ])
      |> sync!()

    plan = plan!(context)
    assert task_of(plan, sub)["parent"] == task_of(plan, number)["id"]
    context
  end

  step "\#{int} is taken out of \#{int} on GitHub", %{args: [sub, number]} = context do
    repository = context.repository

    GitHubIssues.answers(context, repository, [
      GitHubIssues.issue(repository, number),
      GitHubIssues.issue(repository, sub)
    ])
  end

  step "\#{int}'s task is not a subtask", %{args: [number]} = context do
    assert task_of(plan!(context), number)["parent"] == nil
    context
  end

  step "\#{int} is moved on GitHub from \#{int} to {string} \#{int}, which the plan does not follow",
       %{args: [sub, number, other, parent]} = context do
    repository = context.repository
    parent = %{"number" => parent, "repository" => %{"nameWithOwner" => other}}

    GitHubIssues.answers(context, repository, [
      GitHubIssues.issue(repository, number),
      Map.put(GitHubIssues.issue(repository, sub), "parent", parent)
    ])
  end

  # The issue moved comes first in the list, so the look takes it while its new parent is
  # still under it.
  step "\#{int} is moved on GitHub under \#{int}, which leaves it",
       %{args: [number, sub]} = context do
    repository = context.repository

    GitHubIssues.answers(context, repository, [
      GitHubIssues.issue(repository, number, %{"parent" => sub}),
      GitHubIssues.issue(repository, sub, %{"subIssues" => [number]})
    ])
  end

  step "the tasks of \#{int} and \#{int} were imported, neither a subtask of the other",
       %{args: numbers} = context do
    repository = context.repository

    context =
      context
      |> GitHubIssues.answers(repository, Enum.map(numbers, &GitHubIssues.issue(repository, &1)))
      |> sync!()

    plan = plan!(context)
    for number <- numbers, do: assert(%{"parent" => nil} = task_of(plan, number))
    context
  end

  # The parent comes first in the list, so the look takes it before its sub-issue.
  step "GitHub lists \#{int} as a sub-issue of \#{int} late", %{args: [sub, number]} = context do
    repository = context.repository

    late(
      context,
      listing([
        GitHubIssues.issue(repository, number, %{"subIssues" => [sub]}),
        GitHubIssues.issue(repository, sub, %{"parent" => number})
      ])
    )
  end

  step "the user puts \#{int}'s task under \#{int}'s while the plugin looks at GitHub",
       %{args: [number, parent]} = context do
    while_looking(context, fn context ->
      update_task(context, number, %{"parent" => task_of(plan!(context), parent)["id"]})
    end)
  end

  step "\#{int}'s task is a subtask of \#{int}'s, and \#{int}'s task is not a subtask",
       %{args: [sub, number, number]} = context do
    plan = plan!(context)
    assert task_of(plan, sub)["parent"] == task_of(plan, number)["id"]
    assert task_of(plan, number)["parent"] == nil
    context
  end

  step "the tasks of \#{int} and \#{int} were imported in the milestone {string}",
       %{args: [one, two, title]} = context do
    repository = context.repository
    milestone = %{"number" => 1, "title" => title, "dueOn" => "2026-11-30T00:00:00Z"}

    context
    |> GitHubIssues.answers(repository, [
      GitHubIssues.issue(repository, one, %{"milestone" => milestone}),
      GitHubIssues.issue(repository, two, %{"milestone" => milestone})
    ])
    |> sync!()
    |> Map.put(:milestone, milestone)
  end

  step "\#{int} is moved out of {string} on GitHub, leaving \#{int} in it",
       %{args: [moved, _title, kept]} = context do
    repository = context.repository

    GitHubIssues.answers(context, repository, [
      GitHubIssues.issue(repository, moved),
      GitHubIssues.issue(repository, kept, %{"milestone" => context.milestone})
    ])
  end

  step "the milestone {string} waits for \#{int}'s task and not \#{int}'s",
       %{args: [title, kept, moved]} = context do
    plan = plan!(context)
    assert %{"kind" => "milestone", "after" => after_ids} = item(plan, title)
    assert task_of(plan, kept)["id"] in after_ids
    refute task_of(plan, moved)["id"] in after_ids
    context
  end

  step "\#{int} and \#{int} are moved out of {string} on GitHub",
       %{args: [one, two, _title]} = context do
    repository = context.repository

    GitHubIssues.answers(context, repository, [
      GitHubIssues.issue(repository, one),
      GitHubIssues.issue(repository, two)
    ])
  end

  step "the milestone {string} waits for no task", %{args: [title]} = context do
    assert %{"kind" => "milestone", "after" => []} = item(plan!(context), title)
    context
  end

  step "\#{int} is closed by the pull request \#{int}", %{args: [number, pr]} = context do
    repository = context.repository

    GitHubIssues.answers(context, repository, [
      GitHubIssues.issue(repository, number, %{"pullRequests" => [pr]})
    ])
  end

  step "\#{int} is no longer closed by \#{int} on GitHub", %{args: [number, _pr]} = context do
    repository = context.repository
    GitHubIssues.answers(context, repository, [GitHubIssues.issue(repository, number)])
  end

  step "\#{int}'s task is linked to \#{int} and not \#{int}",
       %{args: [number, kept, gone]} = context do
    assert [kept] == Enum.map(task_of(plan!(context), number)["pullRequests"], & &1["number"]),
           "expected only ##{kept}, not ##{gone}"

    context
  end

  step "\#{int}'s task is linked to \#{int}", %{args: [number, pr]} = context do
    assert pr in Enum.map(task_of(plan!(context), number)["pullRequests"], & &1["number"])
    context
  end

  step "\#{int}'s task is in progress", %{args: [number]} = context do
    context =
      context
      |> save(%{"repositories" => [context.repository], "sync" => "import"})
      |> GitHubIssues.answers(context.repository, [GitHubIssues.issue(context.repository, number)])
      |> sync!()

    update_task(context, number, %{"status" => "doing"})
  end

  step "\#{int} is closed on GitHub", %{args: [number]} = context do
    close_issue(context, number, "COMPLETED")
  end

  step "\#{int} is closed on GitHub as not planned", %{args: [number]} = context do
    close_issue(context, number, "NOT_PLANNED")
  end

  step "\#{int}'s task is dropped", %{args: [number]} = context do
    assert task_of(plan!(context), number)["status"] == "dropped"
    context
  end

  defp close_issue(context, number, reason) do
    repository = context.repository

    closed =
      GitHubIssues.issue(repository, number, %{"state" => "CLOSED", "stateReason" => reason})

    context
    |> GitHubIssues.answers(repository, [closed])
    # The listing only has open issues, so a closed one is read alone.
    |> World.cli_rules([
      %{
        "args" => ["api graphql"],
        "stdin" => ["issues(first: $first"],
        "stdout" => %{
          "data" => %{
            "repository" => %{
              "issues" => %{
                "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                "nodes" => []
              }
            }
          }
        }
      }
    ])
  end

  step "\#{int}'s task is done", %{args: [number]} = context do
    assert task_of(plan!(context), number)["status"] == "done"
    context
  end

  step "\#{int}'s task was imported as {string}", %{args: [number, title]} = context do
    repository = context.repository
    issue = GitHubIssues.issue(repository, number, %{"title" => title, "body" => "First notes"})
    context = context |> GitHubIssues.answers(repository, [issue]) |> sync!()
    assert %{"title" => ^title, "notes" => "First notes"} = task_of(plan!(context), number)
    context
  end

  step "\#{int} is renamed on GitHub to {string} with the description {string}",
       %{args: [number, title, body]} = context do
    repository = context.repository

    GitHubIssues.answers(context, repository, [
      GitHubIssues.issue(repository, number, %{"title" => title, "body" => body})
    ])
  end

  step "\#{int}'s task is named {string} with the notes {string}",
       %{args: [number, title, notes]} = context do
    assert %{"title" => ^title, "notes" => ^notes} = task_of(plan!(context), number)
    context
  end

  step "{string} follows the board {string} with {string} and {string} as its dates",
       %{args: [@id, board, start, target]} = context do
    save(context, %{
      "repositories" => [context.repository],
      "sync" => "import",
      "board" => board,
      "startField" => start,
      "targetField" => target
    })
    |> Map.put(:board_fields, {start, target})
  end

  step "\#{int} is on {string} from {string} to {string}",
       %{args: [number, board, start, due]} = context do
    board_item(context, number, board, start, due)
  end

  step "\#{int} was imported from {string} with the dates {string} to {string}",
       %{args: [number, board, start, due]} = context do
    context
    |> board_item(number, board, start, due)
    |> sync!()
    |> Map.merge(%{board_dates: {start, due}, board_issue: number})
  end

  # GitHub keeps a field's values through a rename.
  step "{string} renames its {string} field to {string}",
       %{args: [board, field, name]} = context do
    {start_field, ^field} = context.board_fields
    {start, due} = context.board_dates

    context
    |> Map.put(:board_fields, {start_field, name})
    |> board_item(context.board_issue, board, start, due)
  end

  step "the {string} of \#{int} is cleared on {string}",
       %{args: [field, number, board]} = context do
    {start, _due} = context.board_dates
    assert {_, ^field} = context.board_fields
    board_item(context, number, board, start, nil)
  end

  step "\#{int}'s task starts on {string} and has no due date",
       %{args: [number, start]} = context do
    assert %{"start" => ^start, "due" => nil} = task_of(plan!(context), number)
    context
  end

  step "\#{int}'s task is from {string} to {string}", %{args: [number, start, due]} = context do
    assert %{"start" => ^start, "due" => ^due} = task_of(plan!(context), number)
    context
  end

  step "{string} has the boards {string} {string} and {string} {string}, which is closed",
       %{args: [owner, open, open_title, closed, closed_title]} = context do
    GitHubIssues.boards(context, owner, [
      %{"number" => board_number(open), "title" => open_title, "closed" => false},
      %{"number" => board_number(closed), "title" => closed_title, "closed" => true}
    ])
  end

  step "the settings of {string} list the boards", %{args: [@id]} = context do
    {reply, context} = plugin(context, "boards", %{})
    assert {:ok, offer} = reply
    Map.put(context, :offer, offer)
  end

  step "they offer {string} {string} and not {string}",
       %{args: [board, title, other]} = context do
    offered = for board <- context.offer["boards"], into: %{}, do: {board["id"], board["title"]}
    assert offered[board] == title
    refute Map.has_key?(offered, other)
    context
  end

  step "they say gh needs the {string} scope", %{args: [scope]} = context do
    assert context.offer["boards"] == []
    assert Enum.any?(context.offer["problems"], &(&1 =~ "-s #{scope}"))
    context
  end

  step "the settings of {string} read the fields of {string}", %{args: [@id, board]} = context do
    {reply, context} = plugin(context, "boardFields", %{"board" => board})
    assert {:ok, offer} = reply
    Map.put(context, :offer, offer)
  end

  step "they offer {string} and {string} as its dates", %{args: dates} = context do
    assert context.offer["dateFields"] == dates
    context
  end

  step "{string} syncs {string} both ways with the board {string}",
       %{args: [@id, repository, board]} = context do
    item = fn n, start, due ->
      %{
        "number" => n,
        "repository" => repository,
        "fields" => %{"Start date" => start, "Target date" => due}
      }
    end

    context
    |> save(%{"repositories" => [repository], "sync" => "twoWay", "board" => board})
    |> GitHubIssues.answers(repository, [
      GitHubIssues.issue(repository, 7),
      GitHubIssues.issue(repository, 5)
    ])
    |> GitHubIssues.board(board, ["Start date", "Target date"], [
      item.(5, "2026-10-12", "2026-10-16"),
      item.(7, "2026-10-20", "2026-11-02")
    ])
    |> sync!()
  end

  step "the board {string} holds \#{int} and not \#{int}",
       %{args: [board, number, _absent]} = context do
    GitHubIssues.board(context, board, ["Start date", "Target date"], [
      %{"number" => number, "repository" => context.repository, "fields" => %{}}
    ])
  end

  # Every page is full and says another follows, and none holds `number`.
  step "the board {string} has more items than the plugin reads, and \#{int} is past them",
       %{args: [board, number]} = context do
    items =
      for n <- 1001..1100,
          n != number,
          do: %{"number" => n, "repository" => context.repository, "fields" => %{}}

    GitHubIssues.board(context, board, ["Start date", "Target date"], items, true)
  end

  step "{string} switches to the board {string}", %{args: [@id, board]} = context do
    save(context, %{"board" => board})
  end

  # The issue is added to `board` (the fake names every added item `#0`'s), and the date
  # is set on that item, not on the one it had on the board before.
  step "GitHub is asked to add \#{int} to {string} and set its {string} to {string}",
       %{args: [_number, board, field, date]} = context do
    [owner, n] = String.split(board, "/")
    project = "PVT_#{owner}_#{n}"

    assert [%{"project" => ^project}] =
             GitHubIssues.graphql_calls(context, "addProjectV2ItemById")

    assert_board_set(context, project, field, date)
    context
  end

  step "its {string} on {string} is set to {string} too",
       %{args: [field, board, date]} = context do
    [owner, n] = String.split(board, "/")
    assert_board_set(context, "PVT_#{owner}_#{n}", field, date)
    context
  end

  step "the user relinks \#{int}'s task to \#{int}", %{args: [number, other]} = context do
    task = task_of(plan!(context), number) || flunk("no task follows ##{number}")
    issue = %{"repository" => context.repository, "number" => other}
    {reply, context} = plugin(context, "link", %{"itemId" => task["id"], "issue" => issue})
    assert {:ok, _} = reply
    context
  end

  step "{string} syncs {string} both ways", %{args: [@id, repository]} = context do
    context
    |> save(%{"repositories" => [repository], "sync" => "twoWay"})
    |> GitHubIssues.answers(repository, [GitHubIssues.issue(repository, 7)])
    |> sync!()
  end

  step "{string} follows the issues of {string} without syncing back",
       %{args: [@id, repository]} = context do
    context
    |> save(%{"repositories" => [repository], "sync" => "import"})
    |> GitHubIssues.answers(repository, [GitHubIssues.issue(repository, 7)])
    |> sync!()
  end

  # The outline's changes, each as "the user <change> #n's task".
  step "the user marks as done \#{int}'s task", %{args: [number]} = context do
    update_task(context, number, %{"status" => "done"})
  end

  step "the user marks \#{int}'s task as done", %{args: [number]} = context do
    update_task(context, number, %{"status" => "done"})
  end

  step "the user renames to {string} \#{int}'s task", %{args: [title, number]} = context do
    update_task(context, number, %{"title" => title})
  end

  step "the user renames \#{int}'s task to {string}", %{args: [number, title]} = context do
    update_task(context, number, %{"title" => title})
  end

  step "the user moves to end on {string} \#{int}'s task", %{args: [due, number]} = context do
    update_task(context, number, %{"due" => due})
  end

  step "the user moves \#{int}'s task to end on {string}", %{args: [number, due]} = context do
    update_task(context, number, %{"due" => due})
  end

  step "the user makes wait for \#{int}'s task \#{int}'s task",
       %{args: [other, number]} = context do
    update_task(context, number, %{"after" => [task_of(plan!(context), other)["id"]]})
  end

  step "the user makes \#{int}'s task wait for {string}", %{args: [number, title]} = context do
    update_task(context, number, %{"after" => [item!(context, title)["id"]]})
  end

  step "GitHub is not asked to mark \#{int} as blocked", %{args: [_number]} = context do
    assert GitHubIssues.graphql_calls(context, "addBlockedBy(input") == []
    context
  end

  step "\#{int}'s task is marked as synced", %{args: [number]} = context do
    refute task_of(plan!(context), number)["syncError"]
    context
  end

  step "GitHub answers renaming \#{int} to {string} late, refusing it",
       %{args: [number, title]} = context do
    answers_late(context, number, title, %{
      "exit" => 1,
      "stderr" => "HTTP 422: Validation Failed\n"
    })
  end

  step "GitHub answers renaming \#{int} to {string} late, taking it",
       %{args: [number, title]} = context do
    answers_late(context, number, title, %{"stdout" => %{"number" => number}})
  end

  step "the user renames \#{int}'s task to {string}, then the plugin looks at GitHub before GitHub answers",
       %{args: [number, title]} = context do
    task = task_of(plan!(context), number) || flunk("no task follows ##{number}")
    {renaming, context} = rename_late(context, task, title)
    # GitHub still lists the issue by its old title: the rename has not reached it.
    context = sync!(context)
    answer_late(context)
    assert {{:ok, _}, _} = Task.await(renaming, 30_000)
    context
  end

  step "\#{int} is blocked by \#{int} on GitHub", %{args: [number, blocker]} = context do
    repository = context.repository

    context =
      context
      |> GitHubIssues.answers(repository, [
        GitHubIssues.issue(repository, number, %{"blockedBy" => [blocker]}),
        GitHubIssues.issue(repository, blocker, %{"blocking" => [number]})
      ])
      |> sync!()

    plan = plan!(context)
    assert task_of(plan, number)["after"] == [task_of(plan, blocker)["id"]]
    context
  end

  step "GitHub refuses to unblock \#{int}", %{args: [number]} = context do
    World.cli_rules(context, [
      unblocking(number, %{
        "exit" => 1,
        "stderr" => "GraphQL: Resource not accessible by integration (removeBlockedBy)\n"
      })
    ])
  end

  # GitHub's wording for this is not documented; this is the shape the plugin matches.
  step "GitHub answers unblocking \#{int} that \#{int} no longer blocks it",
       %{args: [number, blocker]} = context do
    World.cli_rules(context, [
      unblocking(number, %{
        "exit" => 1,
        "stderr" =>
          "GraphQL: Issue ##{number} is not blocked by issue ##{blocker} (removeBlockedBy)\n"
      })
    ])
  end

  step "GitHub takes unblocking \#{int} again", %{args: [number]} = context do
    World.cli_rules(context, [
      unblocking(number, %{
        "stdout" => %{"data" => %{"removeBlockedBy" => %{"clientMutationId" => nil}}}
      })
    ])
  end

  step "the user makes \#{int}'s task wait for nothing", %{args: [number]} = context do
    update_task(context, number, %{"after" => []})
  end

  step "GitHub is asked a second time to unblock \#{int} from \#{int}",
       %{args: [number, blocker]} = context do
    asked = GitHubIssues.graphql_calls(context, "removeBlockedBy(input")
    pair = %{"issue" => GitHubIssues.issue_id(number), "other" => GitHubIssues.issue_id(blocker)}
    assert Enum.count(asked, &(&1 == pair)) == 2, inspect(asked)
    context
  end

  step "GitHub is asked to unblock \#{int} from \#{int}", %{args: [number, blocker]} = context do
    GitHubIssues.assert_related(context, "removeBlockedBy", number, blocker)
  end

  step "GitHub is asked to take \#{int} out of \#{int}", %{args: [sub, number]} = context do
    GitHubIssues.assert_related(context, "removeSubIssue", number, sub)
  end

  step "GitHub is asked to block \#{int} by \#{int}", %{args: [number, blocker]} = context do
    GitHubIssues.assert_related(context, "addBlockedBy", number, blocker)
  end

  step "GitHub is asked to put \#{int} under \#{int}", %{args: [sub, number]} = context do
    GitHubIssues.assert_related(context, "addSubIssue", number, sub)
  end

  step "the user unlinks \#{int}'s task from its issue", %{args: [number]} = context do
    task = task_of(plan!(context), number) || flunk("no task follows ##{number}")
    ref = Map.take(task["issue"], ~w(repository number))

    {reply, context} =
      plugin(context, "unlink", %{"itemId" => task["id"], "kind" => "issue", "ref" => ref})

    assert {:ok, _} = reply
    context
  end

  step "{string} is tied to no other task", %{args: [title]} = context do
    plan = plan!(context)
    %{"id" => id} = item = item(plan, title) || flunk("the plan has no #{title}")
    assert %{"after" => [], "parent" => nil} = item

    assert [] ==
             for(
               other <- plan["items"],
               other["parent"] == id or id in other["after"],
               do: other["title"]
             )

    context
  end

  # GitHub takes renaming #`number` to `late` once the scenario answers it, and to `soon`
  # at once; it notes each name in the order it takes them.
  step "GitHub takes renaming \#{int} to {string} late and to {string} at once",
       %{args: [number, late, soon]} = context do
    gate = Path.join(context.mc.home, "gh-gate")
    {_, 0} = System.cmd("mkfifo", [gate])
    names = Path.join(context.mc.home, "gh-names")

    rename = fn title, wait ->
      %{
        "args" => ["--method PATCH", "repos/#{context.repository}/issues/#{number} "],
        "stdin" => [JSON.encode!(%{"title" => title})],
        "run" => wait <> "echo '#{title}' >> '#{names}'",
        "stdout" => %{"number" => number}
      }
    end

    context
    |> World.cli_rules([rename.(late, "cat '#{gate}' > /dev/null; "), rename.(soon, "")])
    |> Map.merge(%{gh_gate: gate, gh_names: names})
  end

  step "GitHub names \#{int} {string} last", %{args: [_number, title]} = context do
    assert context.gh_names |> File.read!() |> String.split("\n", trim: true) |> List.last() ==
             title

    context
  end

  step "\#{int}'s task is marked as not synced", %{args: [number]} = context do
    error = task_of(plan!(context), number)["syncError"]
    assert is_binary(error) and error != "", "##{number}'s task is marked as synced"
    context
  end

  step "the user makes {string} the owner of \#{int}'s task",
       %{args: [owner, number]} = context do
    update_task(context, number, %{"owner" => owner})
  end

  step "GitHub is asked to rename \#{int} to {string} and assign it to {string} at once",
       %{args: [number, title, owner]} = context do
    GitHubIssues.assert_patched(context, number, %{"title" => title, "assignees" => [owner]})
  end

  step "the user renames \#{int}'s task to {string}, then to {string} before GitHub answers",
       %{args: [number, first, second]} = context do
    task = task_of(plan!(context), number) || flunk("no task follows ##{number}")
    {renaming, context} = rename_late(context, task, first)
    context = update_task(context, number, %{"title" => second})
    answer_late(context)
    assert {{:ok, _}, _} = Task.await(renaming, 30_000)
    context
  end

  step "the user renames \#{int}'s task to {string}, then makes {string} its owner before GitHub answers",
       %{args: [number, title, owner]} = context do
    task = task_of(plan!(context), number) || flunk("no task follows ##{number}")
    {renaming, context} = rename_late(context, task, title)
    context = update_task(context, number, %{"owner" => owner})
    answer_late(context)
    assert {{:ok, _}, _} = Task.await(renaming, 30_000)
    context
  end

  step "the user renames \#{int}'s task to {string}, then unlinks it before GitHub answers",
       %{args: [number, title]} = context do
    task = task_of(plan!(context), number) || flunk("no task follows ##{number}")
    {renaming, context} = rename_late(context, task, title)
    ref = Map.take(task["issue"], ~w(repository number))

    {reply, context} =
      plugin(context, "unlink", %{"itemId" => task["id"], "kind" => "issue", "ref" => ref})

    assert {:ok, _} = reply
    answer_late(context)
    assert {{:ok, _}, _} = Task.await(renaming, 30_000)
    context
  end

  step "GitHub lists \#{int} as {string} late", %{args: [number, title]} = context do
    late(context, listed(context, number, title))
  end

  step "the user renames \#{int}'s task to {string} while the plugin looks at GitHub",
       %{args: [number, title]} = context do
    while_looking(context, fn context ->
      context = update_task(context, number, %{"title" => title})
      # GitHub has the rename now, for the looks after this one.
      World.cli_rules(context, [listed(context, number, title)])
    end)
  end

  step "the user renames \#{int}'s task to {string}, then relinks it to {string} \#{int} before GitHub answers",
       %{args: [number, title, repository, other]} = context do
    task = task_of(plan!(context), number) || flunk("no task follows ##{number}")
    {renaming, context} = rename_late(context, task, title)
    issue = %{"repository" => repository, "number" => other}
    {reply, context} = plugin(context, "link", %{"itemId" => task["id"], "issue" => issue})
    assert {:ok, _} = reply
    answer_late(context)
    assert {{:ok, _}, _} = Task.await(renaming, 30_000)
    context
  end

  step "{string} is linked to {string} \#{int} and not marked as not synced",
       %{args: [title, repository, number]} = context do
    task = item!(context, title)
    assert %{"repository" => ^repository, "number" => ^number} = task["issue"]
    refute task["syncError"], "#{title} is marked as not synced: #{task["syncError"]}"
    context
  end

  step "{string} is linked to no issue and not marked as not synced",
       %{args: [title]} = context do
    task = item!(context, title)
    refute task["issue"]
    refute task["syncError"], "#{title} is marked as not synced: #{task["syncError"]}"
    context
  end

  step "\#{int}'s task is named {string} and marked as synced",
       %{args: [number, title]} = context do
    task = task_of(plan!(context), number)
    assert task["title"] == title
    refute task["syncError"], "##{number}'s task is marked as not synced: #{task["syncError"]}"
    context
  end

  step "GitHub is not asked to change \#{int}", %{args: [number]} = context do
    assert GitHubIssues.rest_calls(context, "PATCH", "/issues/#{number}") == []
    assert GitHubIssues.graphql_calls(context, "addBlockedBy(input") == []
    assert GitHubIssues.graphql_calls(context, "updateProjectV2ItemFieldValue") == []
    context
  end

  step "GitHub refuses changes to \#{int}", %{args: [number]} = context do
    World.cli_rules(context, [
      %{
        "args" => ["--method PATCH", "repos/#{context.repository}/issues/#{number} "],
        "exit" => 1,
        "stderr" =>
          "HTTP 422: Validation Failed (https://docs.github.com/rest/issues/issues#update-an-issue)\n"
      }
    ])
  end

  step "GitHub takes changes to \#{int} again", %{args: [number]} = context do
    World.cli_rules(context, [
      %{
        "args" => ["--method PATCH", "repos/#{context.repository}/issues/#{number} "],
        "stdout" => %{"number" => number}
      }
    ])
  end

  step "the user labels \#{int}'s task {string}", %{args: [number, label]} = context do
    update_task(context, number, %{"labels" => [label]})
  end

  step "GitHub is asked to rename \#{int} to {string} and label it {string} at once",
       %{args: [number, title, label]} = context do
    GitHubIssues.assert_patched(context, number, %{"title" => title, "labels" => [label]})
  end

  step "GitHub is never asked to change \#{int}'s assignees", %{args: [number]} = context do
    changes = GitHubIssues.rest_calls(context, "PATCH", "/issues/#{number}")
    refute Enum.any?(changes, &Map.has_key?(&1, "assignees")), inspect(changes)
    context
  end

  step "\#{int} is in the milestone {string} and \#{int} in {string} on GitHub",
       %{args: [one, first, two, second]} = context do
    in_milestones(context, [{one, first}, {two, second}])
  end

  step "\#{int} is in the milestone {string}, \#{int} in {string} and \#{int} in {string} on GitHub",
       %{args: [one, first, two, second, three, third]} = context do
    in_milestones(context, [{one, first}, {two, second}, {three, third}])
  end

  # GitHub takes moving #`number` to the milestone `late` once the scenario answers it,
  # and to `soon` at once; it notes each milestone in the order it takes them.
  step "GitHub takes moving \#{int} to {string} late and to {string} at once",
       %{args: [number, late, soon]} = context do
    gate = Path.join(context.mc.home, "gh-gate")
    {_, 0} = System.cmd("mkfifo", [gate])
    taken = Path.join(context.mc.home, "gh-milestones")

    move = fn title, wait ->
      milestone = context.milestones[title]

      %{
        "args" => ["--method PATCH", "repos/#{context.repository}/issues/#{number} "],
        "stdin" => [~s("milestone":#{milestone})],
        "run" => wait <> "echo '#{milestone}' >> '#{taken}'",
        "stdout" => %{"number" => number}
      }
    end

    context
    |> World.cli_rules([move.(late, "cat '#{gate}' > /dev/null; "), move.(soon, "")])
    |> Map.merge(%{gh_gate: gate, gh_milestones: taken})
  end

  step "the user moves {string} from {string} to {string}, then to {string} before GitHub answers",
       %{args: [title, from, first, second]} = context do
    %{mc: mc} = context
    input = move_input(context, title, from, first)
    call = %{"id" => @id, "method" => "moveToMilestone", "input" => input}

    # The first move goes from a client of its own, as another window's would, so it can
    # wait on GitHub while the scenario goes on.
    moving =
      Task.async(fn -> Mc.call(Mc.connect(mc), mc.environment, "plugins.call", call) end)

    {_, context} =
      await_topic(context, "plan", fn plan ->
        item(plan, title)["id"] in (item(plan, first) || %{"after" => []})["after"]
      end)

    {reply, context} =
      plugin(context, "moveToMilestone", move_input(context, title, first, second))

    assert {:ok, _} = reply
    answer_late(context)
    assert {{:ok, _}, _} = Task.await(moving, 30_000)
    context
  end

  # GitHub takes moving #`number` to the milestone `title` once the scenario answers it,
  # through a gate of the move's own.
  step "GitHub takes moving \#{int} to {string} late", %{args: [number, title]} = context do
    gate = Path.join(context.mc.home, "gh-gate-#{number}-#{context.milestones[title]}")
    {_, 0} = System.cmd("mkfifo", [gate])

    context
    |> World.cli_rules([
      %{
        "args" => ["--method PATCH", "repos/#{context.repository}/issues/#{number} "],
        "stdin" => [~s("milestone":#{context.milestones[title]})],
        "run" => "cat '#{gate}' > /dev/null",
        "stdout" => %{"number" => number}
      }
    ])
    |> Map.merge(%{gh_gate: gate, gh_gates: Map.put(context[:gh_gates] || %{}, title, gate)})
  end

  step "the user moves {string} from {string} to {string}, then {string} from {string} to {string} and out of it, before GitHub answers",
       %{args: [title, from, to, other, other_from, other_to]} = context do
    %{mc: mc} = context
    input = move_input(context, title, from, to)
    call = %{"id" => @id, "method" => "moveToMilestone", "input" => input}

    # The first move goes from a client of its own, so it can wait on GitHub while the
    # second task moves to the same milestone and out of it.
    moving =
      Task.async(fn -> Mc.call(Mc.connect(mc), mc.environment, "plugins.call", call) end)

    {_, context} =
      await_topic(context, "plan", fn plan ->
        item(plan, title)["id"] in (item(plan, to) || %{"after" => []})["after"]
      end)

    {reply, context} =
      plugin(context, "moveToMilestone", move_input(context, other, other_from, other_to))

    assert {:ok, _} = reply
    id = item!(context, other)["id"]
    context = update!(context, other_to, %{"after" => item!(context, other_to)["after"] -- [id]})
    answer_late(context)
    assert {{:ok, _}, _} = Task.await(moving, 30_000)
    context
  end

  step "the user moves {string} from {string} to {string}, then {string} from {string} to {string} and back, before GitHub answers",
       %{args: [title, from, to, other, other_from, other_to]} = context do
    %{mc: mc} = context
    input = move_input(context, title, from, to)
    call = %{"id" => @id, "method" => "moveToMilestone", "input" => input}

    # The first move goes from a client of its own, so it can wait on GitHub while the
    # second task moves out of the same milestone, GitHub takes that, and it moves back.
    moving =
      Task.async(fn -> Mc.call(Mc.connect(mc), mc.environment, "plugins.call", call) end)

    {_, context} =
      await_topic(context, "plan", fn plan ->
        item(plan, title)["id"] in (item(plan, to) || %{"after" => []})["after"]
      end)

    context =
      for {from, to} <- [{other_from, other_to}, {other_to, other_from}], reduce: context do
        context ->
          {reply, context} =
            plugin(context, "moveToMilestone", move_input(context, other, from, to))

          assert {:ok, _} = reply
          context
      end

    answer_late(context)
    assert {{:ok, _}, _} = Task.await(moving, 30_000)
    context
  end

  step "the user moves {string} from {string} to {string} and back, GitHub takes the move back first, and the plugin looks at GitHub once it takes the first move",
       %{args: [title, from, to]} = context do
    %{mc: mc} = context

    # Each move goes from a client of its own, as another window's would, so it can
    # wait on GitHub while the scenario goes on.
    move = fn from, to ->
      call = %{
        "id" => @id,
        "method" => "moveToMilestone",
        "input" => move_input(context, title, from, to)
      }

      Task.async(fn -> Mc.call(Mc.connect(mc), mc.environment, "plugins.call", call) end)
    end

    in? = fn milestone ->
      fn plan ->
        item(plan, title)["id"] in (item(plan, milestone) || %{"after" => []})["after"]
      end
    end

    moving = move.(from, to)
    {_, context} = await_topic(context, "plan", in?.(to))
    back = move.(to, from)
    {_, context} = await_topic(context, "plan", in?.(from))
    answer_late(context, from)
    assert {{:ok, _}, _} = Task.await(back, 30_000)
    answer_late(context, to)

    # GitHub has taken the first move, and lists it, and the milestone the task moved to
    # first asks it to move the task back again.
    {number, context} =
      await_topic(context, "plan", fn plan ->
        issue = item(plan, title)["issue"]
        issue["milestone"] == context.milestones[to] and issue["number"]
      end)

    issues = List.keystore(context.on_github, number, 0, {number, to})

    context =
      context
      |> GitHubIssues.lists(context.repository, milestone_issues(context, issues))
      |> sync!()

    answer_late(context, from)
    assert {{:ok, _}, _} = Task.await(moving, 30_000)
    context
  end

  step "the user moves {string} from {string} to {string} and the plugin looks at GitHub before GitHub answers",
       %{args: [title, from, to]} = context do
    %{mc: mc} = context
    input = move_input(context, title, from, to)
    call = %{"id" => @id, "method" => "moveToMilestone", "input" => input}

    # The move goes from a client of its own, so it can wait on GitHub during the look.
    moving =
      Task.async(fn -> Mc.call(Mc.connect(mc), mc.environment, "plugins.call", call) end)

    {_, context} =
      await_topic(context, "plan", fn plan ->
        item(plan, title)["id"] in (item(plan, to) || %{"after" => []})["after"]
      end)

    context = sync!(context)
    answer_late(context)
    assert {{:ok, _}, _} = Task.await(moving, 30_000)
    context
  end

  step "GitHub is asked once to move \#{int} out of its milestone", %{args: [number]} = context do
    moves =
      for patch <- GitHubIssues.rest_calls(context, "PATCH", "/issues/#{number}"),
          Map.has_key?(patch, "milestone"),
          do: patch["milestone"]

    assert moves == [nil]
    context
  end

  step "GitHub has \#{int} in the milestone {string} last", %{args: [_number, title]} = context do
    taken = context.gh_milestones |> File.read!() |> String.split("\n", trim: true)
    assert List.last(taken) == to_string(context.milestones[title]), inspect(taken)
    context
  end

  # One write for the move, not one for each milestone it touched.
  step "GitHub is asked once to move \#{int} to the milestone {string}",
       %{args: [number, title]} = context do
    moves =
      for patch <- GitHubIssues.rest_calls(context, "PATCH", "/issues/#{number}"),
          Map.has_key?(patch, "milestone"),
          do: patch["milestone"]

    assert moves == [context.milestones[title]]
    context
  end

  step "GitHub is asked last to move \#{int} to the milestone {string}",
       %{args: [number, title]} = context do
    moves =
      for patch <- GitHubIssues.rest_calls(context, "PATCH", "/issues/#{number}"),
          Map.has_key?(patch, "milestone"),
          do: patch["milestone"]

    assert List.last(moves) == context.milestones[title], inspect(moves)
    context
  end

  step "\#{int}'s task is in the milestone {string} and not {string}",
       %{args: [number, to, from]} = context do
    plan = plan!(context)
    id = task_of(plan, number)["id"]
    assert id in item(plan, to)["after"]
    refute id in item(plan, from)["after"]
    context
  end

  step "the milestone {string} is marked as not synced", %{args: [title]} = context do
    error = item!(context, title)["syncError"]
    assert is_binary(error) and error != "", "#{title} is marked as synced"
    context
  end

  step "the plan has {string} in {string} labelled {string}",
       %{args: [title, project, label]} = context do
    ensure(context, title, %{
      "projectId" => World.project(context, project).id,
      "labels" => [label]
    })
  end

  step "GitHub is asked to create the issue {string} labelled {string}",
       %{args: [title, label]} = context do
    created = GitHubIssues.rest_calls(context, "POST", "/issues")

    assert Enum.any?(created, &(&1["title"] == title and &1["labels"] == [label])),
           "GitHub was not asked to create #{title} labelled #{label}: #{inspect(created)}"

    context
  end

  # A stand-in for git that holds the first `git remote -v` from here on, which reading
  # the MC's projects runs for each, on a fifo until the scenario lets it go.
  step "the MC is slow to read its projects' git remotes", context do
    dir = Mc.tmp_dir(context.mc, "slow-git")
    gate = Path.join(dir, "gate")
    {_, 0} = System.cmd("mkfifo", [gate])
    script = Path.join(dir, "git")

    File.write!(script, """
    #!/bin/sh
    if [ "$1 $2" = "remote -v" ] && mkdir '#{dir}/held' 2>/dev/null; then read _ < '#{gate}'; fi
    exec '#{System.find_executable("git")}' "$@"
    """)

    File.chmod!(script, 0o755)
    World.put_app_env(:git_command, script)
    Map.put(context, :git_gate, gate)
  end

  # The rename comes from a client of its own, as another window's would, and the plan
  # is read while the MC reads its projects' remotes for it.
  step "the user renames \#{int}'s task to {string} while the MC reads them",
       %{args: [number, title]} = context do
    %{mc: mc} = context
    task = task_of(plan!(context), number) || flunk("no task follows ##{number}")
    input = %{"id" => task["id"], "fields" => %{"title" => title}}
    call = %{"id" => @id, "method" => "updateItem", "input" => input}
    renaming = Task.async(fn -> Mc.call(Mc.connect(mc), mc.environment, "plugins.call", call) end)
    # Opening the gate waits for git to read it, so the remotes are being read.
    {:ok, gate} = :file.open(context.git_gate, [:write, :raw])
    {meanwhile, context} = plugin(context, "plan", %{})
    :ok = :file.close(gate)
    assert {{:ok, _}, _} = Task.await(renaming, 30_000)
    Map.put(context, :meanwhile, meanwhile)
  end

  step "the plan could be read meanwhile", context do
    assert {:ok, %{"items" => _}} = context.meanwhile
    context
  end

  step "\#{int}'s task is named {string} and marked as not synced, with GitHub's reason",
       %{args: [number, title]} = context do
    assert %{"title" => ^title, "syncError" => error} = task_of(plan!(context), number)
    assert is_binary(error) and error != ""
    assert error =~ "422" or error =~ "Validation Failed"
    context
  end

  step "the plan has {string} in {string}", %{args: [title, project]} = context do
    ensure(context, title, %{"projectId" => World.project(context, project).id})
  end

  step "the user creates an issue for {string} in {string}",
       %{args: [title, repository]} = context do
    context = GitHubIssues.answers(context, repository, [])

    {reply, context} =
      plugin(context, "createIssue", %{
        "itemId" => item!(context, title)["id"],
        "repository" => repository
      })

    assert {:ok, _} = reply
    context
  end

  # GitHub lists #7, the issues of the plan's tasks and the one it made, #13, with the
  # relations between them it was asked to add and not asked to drop since.
  step "the plugin looks at GitHub, which has taken what it was asked", context do
    repository = context.repository

    made =
      for %{"title" => title} <- GitHubIssues.rest_calls(context, "POST", "/issues"),
          into: %{},
          do: {13, %{"title" => title}}

    number = fn "I_" <> n -> String.to_integer(n) end

    asked = fn mutation ->
      for %{"issue" => issue, "other" => other} <-
            GitHubIssues.graphql_calls(context, mutation <> "(input"),
          do: {number.(issue), number.(other)}
    end

    blocked = asked.("addBlockedBy") -- asked.("removeBlockedBy")
    subs = asked.("addSubIssue") -- asked.("removeSubIssue")

    numbers =
      Enum.uniq([
        7
        | for(
            %{"issue" => %{"repository" => ^repository, "number" => n}} <- plan!(context)["items"],
            do: n
          )
      ])

    issue = fn n, fields ->
      parent = Enum.find_value(subs, fn {parent, sub} -> if sub == n, do: parent end)
      fields = Map.merge(fields, %{"blockedBy" => for({^n, b} <- blocked, do: b)})

      GitHubIssues.issue(
        repository,
        n,
        if(parent, do: Map.put(fields, "parent", parent), else: fields)
      )
    end

    context
    |> GitHubIssues.answers(repository, for(n <- numbers, do: issue.(n, made[n] || %{})))
    |> sync!()
  end

  step "{string} is linked to the new issue", %{args: [title]} = context do
    assert %{"issue" => %{"number" => 13}} = item!(context, title)
    context
  end

  step "the plugin reports that no project has {string}", %{args: [repository]} = context do
    assert repository in plan!(context)["sync"]["unwatched"]
    context
  end

  step "{string} follows the board {string}", %{args: [@id, board]} = context do
    context |> ensure("API") |> save(%{"board" => board})
  end

  step "{string} follows the issues of {string} and the board {string}",
       %{args: [@id, repository, board]} = context do
    save(context, %{"repositories" => [repository], "sync" => "import", "board" => board})
  end

  # Every page GitHub answers is full and says another follows, so the plugin stops
  # at its limit.
  step "{string} has more open issues, and {string} more items, than the plugin reads",
       %{args: [repository, board]} = context do
    issues = for n <- 1..100, do: GitHubIssues.issue(repository, n)
    items = for n <- 1..100, do: %{"number" => n, "repository" => repository}

    context
    |> GitHubIssues.answers(repository, issues, true)
    |> GitHubIssues.board(board, ["Start date"], items, true)
  end

  step "the plugin reports that only part of {string} and of {string} was read",
       %{args: [repository, board]} = context do
    problem = plan!(context)["sync"]["problem"]
    assert problem =~ "#{repository}: only its 500 most recently updated open issues were read."
    assert problem =~ "#{board}: only its first 500 items were read."
    context
  end

  step "the plugin reports that gh needs the {string} scope", %{args: [scope]} = context do
    assert plan!(context)["sync"]["problem"] =~ "-s #{scope}"
    context
  end

  step "the tasks it has are kept", context do
    assert item!(context, "API")
    context
  end

  # --- Slack -----------------------------------------------------------------------------

  step "the MC is connected to Slack as the bot {string}", %{args: [bot]} = context do
    context = SlackSupport.connect(context, %{bot: bot})
    # Slash command answers go out after the event is handled; this tells the scenario
    # each request as it reaches the fake workspace. FakeSlack puts Req back at the end.
    test = self()

    Req.default_options(
      plug: fn conn ->
        conn = FakeSlack.call(conn, [])
        send(test, {:slack_request, conn.host, conn.request_path})
        conn
      end,
      retry: false
    )

    context
  end

  step "{string} posts to the Slack channel {string}", %{args: [@id, channel]} = context do
    save(context, %{"slackChannel" => channel})
  end

  step "the user posts the update {string} saying the plan is at risk",
       %{args: [text]} = context do
    {_, context} = post_update(context, "at risk", text)
    context
  end

  step "{string} gets {string} marked at risk", %{args: [channel, text]} = context do
    assert_posted(channel, ":large_yellow_circle: *At risk*: #{text}")
    context
  end

  step "{string} gets {string} marked on track", %{args: [channel, text]} = context do
    assert_posted(channel, ":large_green_circle: *On track*: #{text}")
    context
  end

  step "{string} proposed the update {string} saying the plan is on track",
       %{args: [label, text]} = context do
    context = start_run(context, label)

    assert %{"status" => "proposed"} =
             report!(context, %{"summary" => text, "health" => "on-track"})

    context
  end

  step "{string} proposes {int} changes", %{args: [label, 3]} = context do
    propose(context, label, ["Schema", "API", "Docs"])
  end

  step "{string} is told {string} has {int} changes waiting in HAL-C2",
       %{args: [channel, label, count]} = context do
    texts = posted(channel)

    assert Enum.any?(
             texts,
             &String.starts_with?(&1, "#{label} has #{count} changes waiting in HAL-C2")
           ),
           inspect(texts)

    context
  end

  step "{string} does not announce proposals in Slack", %{args: [@id]} = context do
    save(context, %{"slackAnnounce" => false})
  end

  step "nothing is posted to {string}", %{args: [channel]} = context do
    assert posted(channel) == []
    context
  end

  step "the update {string} was posted to {string}", %{args: [text, channel]} = context do
    {update, context} = post_update(context, "at risk", text)
    assert_posted(channel, ":large_yellow_circle: *At risk*: #{text}")
    Map.put(context, :update, update)
  end

  step "{string} replies {string} in its thread", %{args: ["dana", text]} = context do
    update = Enum.find(plan!(context)["updates"], &(&1["id"] == context.update["id"]))
    assert %{"slack" => %{"ts" => ts}} = update

    FakeSlack.event(%{
      "type" => "message",
      "channel" => "CPLAN",
      "user" => "UDANA",
      "text" => text,
      "ts" => "1700000100.000009",
      "thread_ts" => ts,
      "parent_user_id" => "UHAL"
    })

    context
  end

  # Both posts fail (a post is tried before postUpdate answers), so neither update is in
  # Slack until the scenario says it is.
  step "Slack is down while the updates {string} and {string} are posted",
       %{args: texts} = context do
    FakeSlack.available(false)

    {updates, context} =
      Enum.map_reduce(texts, context, fn text, context ->
        post_update(context, "at risk", text)
      end)

    FakeSlack.available(true)
    Map.put(context, :slack_updates, Map.new(Enum.zip(texts, updates)))
  end

  # The answers to two posts, heard in the other order: each post's answer is timed
  # before the planner hears it, so a slow one can arrive after a newer one.
  step "the planner hears {string} was posted, then that {string} was posted before it",
       %{args: [later, earlier]} = context do
    at = System.monotonic_time()

    for {text, at, ts} <- [
          {later, at, "1700000050.000002"},
          {earlier, at - 1, "1700000040.000001"}
        ] do
      posted = %{"channel" => "CPLAN", "ts" => ts}
      update = context.slack_updates[text]["id"]
      :ok = GenServer.call(HalC2Plugins.Planner, {:slack, update, {:ok, posted}, at})
    end

    Map.put(context, :update, context.slack_updates[earlier])
  end

  step "the plan has the feedback {string} from {string} in Slack",
       %{args: [text, person]} = context do
    by = "slack:#{person}"

    {_, context} =
      await_topic(context, "plan", fn plan ->
        Enum.find(plan["planFeedback"], &(&1["text"] == text and &1["by"] == by))
      end)

    context
  end

  step "{string} is late and {string} is in progress", %{args: [late, doing]} = context do
    World.put_app_env(:planner_today, "2026-10-31")

    context
    |> ensure(late, %{"status" => "doing"})
    |> ensure(doing, %{"status" => "doing"})
  end

  step "the plan has a second task called {string}", %{args: [title]} = context do
    context = seed(context)
    first = item!(context, title)["id"]
    context = add!(context, Map.put(sample(context, title), "due", "2026-11-20"))
    second = Enum.find(plan!(context)["items"], &(&1["title"] == title and &1["id"] != first))
    Map.put(context, :second, second)
  end

  step "{string} runs {string} with the second {string} task's id in Slack",
       %{args: ["dana", "/planner " <> text, _title]} = context do
    slash(context, "#{text} #{context.second["id"]}")
  end

  step "{string} runs {string} in Slack", %{args: ["dana", "/planner " <> text]} = context do
    context |> seed() |> slash(text)
  end

  step "only {string} is asked to run {string} on one of the {string} tasks by its id",
       %{args: ["dana", label, title]} = context do
    assert %{"response_type" => "ephemeral", "text" => text} = context.answer
    assert text =~ ~s(More than one task is called "#{title}"; run #{label} on one by its id:)
    tasks = Enum.filter(plan!(context)["items"], &(&1["title"] == title))
    assert length(tasks) == 2

    for task <- tasks,
        do: assert(text =~ "/planner run #{action_id(context, label)} #{task["id"]} — #{title} (")

    context
  end

  step "a {string} run of the second {string} task starts", %{args: [label, _title]} = context do
    run = Enum.find(runs!(context), &(&1["label"] == label))
    assert %{"status" => "running", "itemIds" => [id]} = run
    assert id == context.second["id"]
    context
  end

  step "only {string} is shown that {string} is late, {string} is in progress, and the latest health",
       %{args: ["dana", late, doing]} = context do
    assert %{"response_type" => "ephemeral", "text" => text} = context.answer
    assert text =~ "Late: #{late} (due "
    assert text =~ "In progress: #{doing} ("
    assert text =~ "Health: "
    context
  end

  step "a {string} run of {string} starts", %{args: [label, title]} = context do
    id = item!(context, title)["id"]
    run = Enum.find(runs!(context), &(&1["label"] == label and &1["itemIds"] == [id]))
    assert %{"status" => "running", "threadId" => thread} = run
    World.await_row(thread, & &1, 10_000)
    Map.merge(context, %{run: run, thread: thread})
  end

  step "only {string} is told it started", %{args: ["dana"]} = context do
    assert %{"response_type" => "ephemeral", "text" => text} = context.answer
    assert text == "Started #{context.run["label"]} on #{item!(context, "API")["title"]}."
    context
  end

  step "only {string} is told no task is called {string}", %{args: ["dana", title]} = context do
    assert %{"response_type" => "ephemeral", "text" => text} = context.answer
    assert text == ~s(No task is called "#{title}".)
    context
  end

  step "the user added the actions {string} and {string} on the whole plan",
       %{args: labels} = context do
    actions =
      for label <- labels, into: context.actions do
        action = %{
          "label" => label,
          "scope" => "plan",
          "kind" => "action",
          "apply" => "propose",
          "prompt" => label <> @gate
        }

        {label |> String.downcase() |> String.replace(" ", "-"), action}
      end

    save_actions(context, actions)
  end

  step "only {string} is asked to run {string} or {string} by its id",
       %{args: ["dana" | labels]} = context do
    assert %{"response_type" => "ephemeral", "text" => text} = context.answer
    assert text =~ "check could be more than one action"

    for label <- labels,
        do:
          assert(
            text =~
              "/planner run #{label |> String.downcase() |> String.replace(" ", "-")} — #{label}"
          )

    context
  end

  step "{string} runs the line its answer gives for {string}",
       %{args: ["dana", label]} = context do
    assert %{"text" => text} = context.answer

    line =
      text
      |> String.split("\n")
      |> Enum.find(&String.ends_with?(&1, " — #{label}")) || flunk("no line for #{label}")

    ["/planner " <> command, _] = String.split(line, " — ", parts: 2)
    slash(context, command)
  end

  step "a {string} run of the plan starts", %{args: [label]} = context do
    run = Enum.find(runs!(context), &(&1["label"] == label)) || flunk("no #{label} run")
    assert %{"status" => "running", "itemIds" => []} = run
    context
  end

  step "no run starts", context do
    assert runs!(context) == []
    context
  end

  step "the plan has the update {string}", %{args: [text]} = context do
    assert Enum.any?(plan!(context)["updates"], &(&1["text"] == text))
    context
  end

  step "the plugin reports that Slack is not connected", context do
    assert plan!(context)["sync"]["slack"]["problem"] =~ "Slack is not connected"
    context
  end

  # --- what other step files dispatch here -------------------------------------------------

  @doc "\"the user runs {string}\" for an action on the whole plan."
  def run(context, label), do: start_run(context, label)

  @doc "\"the user retries it\": the failed run of `context.run` again."
  def retry(context) do
    {reply, context} = plugin(context, "retry", %{"runId" => context.run["id"]})
    assert {:ok, %{"run" => run}} = reply
    Map.put(context, :retried, run)
  end

  # --- helpers ---------------------------------------------------------------------------

  # `field` is set to `date` on the item the fake added, and every date set goes there.
  defp assert_board_set(context, project, field, date) do
    calls = GitHubIssues.graphql_calls(context, "updateProjectV2ItemFieldValue")
    item = GitHubIssues.item_id(0)
    assert Enum.all?(calls, &match?(%{"project" => ^project, "item" => ^item}, &1))

    assert Enum.any?(
             calls,
             &(&1["field"] == GitHubIssues.field_id(field) and &1["value"] == %{"date" => date})
           )
  end

  # Issue `number` on `board` with its dates; a nil one is empty there.
  defp board_item(context, number, board, start, due) do
    repository = context.repository
    {start_field, target_field} = context.board_fields
    fields = Map.reject(%{start_field => start, target_field => due}, fn {_, v} -> is_nil(v) end)

    context
    |> GitHubIssues.answers(repository, [GitHubIssues.issue(repository, number)])
    |> GitHubIssues.board(board, [start_field, target_field], [
      %{"number" => number, "repository" => repository, "fields" => fields}
    ])
  end

  defp board_number(board), do: board |> String.split("/") |> List.last() |> String.to_integer()

  defp save(context, patch) do
    {_, context} =
      World.call!(context, "plugins.saveSettings", %{"id" => @id, "settings" => patch})

    context
  end

  defp save_actions(context, actions),
    do: context |> save(%{"actions" => actions}) |> Map.put(:actions, actions)

  defp set_prompt(context, label, prompt),
    do:
      save_actions(
        context,
        put_in(context.actions, [action_id(context, label), "prompt"], prompt)
      )

  defp gated(action, prompt), do: Map.put(action, "prompt", prompt <> @gate)

  defp plan_settings(context) do
    {reply, _} = plugin(context, "settings", %{})
    assert {:ok, %{"settings" => settings}} = reply
    settings
  end

  defp slash(context, text) do
    FakeSlack.command(%{
      "command" => "/planner",
      "text" => text,
      "user_id" => "UDANA",
      "user_name" => "dana",
      "channel_id" => "CPLAN",
      "response_url" => FakeSlack.response_url()
    })

    assert_receive {:slack_request, "hooks.slack.com", _}, 10_000
    Map.put(context, :answer, List.last(FakeSlack.responses())["body"])
  end

  # GitHub's list of the open issues: #`number`, named `title`.
  defp listed(context, number, title) do
    issue =
      GitHubIssues.issue(context.repository, number, %{"title" => title, "body" => "First notes"})

    listing([issue])
  end

  # GitHub's list of the open issues: `issues`, as `GitHubIssues.issue/3` makes them.
  defp listing(issues) do
    page = %{"pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}, "nodes" => issues}

    %{
      "args" => ["api graphql"],
      "stdin" => ["issues(first: $first"],
      "stdout" => %{"data" => %{"repository" => %{"issues" => page}}}
    }
  end

  defp action_id(context, label),
    do:
      Enum.find_value(context.actions, fn {id, a} -> a["label"] == label && id end) ||
        flunk("no action #{label}")

  defp plugin(context, method, input),
    do: World.call(context, "plugins.call", %{"id" => @id, "method" => method, "input" => input})

  # Reads go through the default client without keeping what it skipped; no step
  # waits for frames on it.
  defp plan!(context) do
    {reply, _} = plugin(context, "plan", %{})
    assert {:ok, plan} = reply
    plan
  end

  defp runs!(context) do
    {reply, _} = plugin(context, "runs", %{})
    assert {:ok, %{"runs" => runs}} = reply
    runs
  end

  defp run!(context),
    do: Enum.find(runs!(context), &(&1["id"] == context.run["id"])) || flunk("the run is gone")

  defp item(plan, title), do: Enum.find(plan["items"], &(&1["title"] == title))
  defp item!(context, title), do: item(plan!(context), title) || flunk("the plan has no #{title}")

  defp task_of(plan, number),
    do: Enum.find(plan["items"], &match?(%{"issue" => %{"number" => ^number}}, &1))

  defp add!(context, fields) do
    {reply, context} = plugin(context, "addItem", %{"fields" => fields})
    assert {:ok, %{"item" => _}} = reply
    context
  end

  defp update!(context, title, fields) do
    {reply, context} =
      plugin(context, "updateItem", %{"id" => item!(context, title)["id"], "fields" => fields})

    assert {:ok, %{"item" => _}} = reply
    context
  end

  # The next look's gh answers with `rule` once the scenario opens and closes the fifo it
  # waits on; later looks no longer wait.
  defp late(context, rule) do
    gate = Path.join(context.mc.home, "gh-gate")
    {_, 0} = System.cmd("mkfifo", [gate])
    wait = "if [ -p '#{gate}' ]; then cat '#{gate}' > /dev/null; rm -f '#{gate}'; fi"
    context |> World.cli_rules([Map.put(rule, "run", wait)]) |> Map.put(:gh_gate, gate)
  end

  # Runs `change` while a look at GitHub that `late/2` holds has read the plan, then lets
  # the look go on and waits for it.
  defp while_looking(context, change) do
    %{mc: mc} = context
    call = %{"id" => @id, "method" => "sync", "input" => %{}}
    looking = Task.async(fn -> Mc.call(Mc.connect(mc), mc.environment, "plugins.call", call) end)
    # Opening the gate waits for the look's gh to read it, so the look has read the plan.
    {:ok, gate} = :file.open(context.gh_gate, [:write, :raw])
    context = change.(context)
    :ok = :file.close(gate)
    assert {{:ok, _}, _} = Task.await(looking, 30_000)
    context
  end

  # Lets the late rename's gh answer, once it is waiting. The fifo is opened raw: through
  # the file server, the open would hold every other file call until gh reads it, the
  # rename's own on its way to gh included.
  defp answer_late(context), do: File.write!(context.gh_gate, "answer", [:raw])
  defp answer_late(context, title), do: File.write!(context.gh_gates[title], "answer", [:raw])

  # GitHub's answer to renaming #`number` to `title` (a fake gh rule's outcome) waits on
  # a fifo until the scenario answers it.
  defp answers_late(context, number, title, outcome) do
    gate = Path.join(context.mc.home, "gh-gate")
    {_, 0} = System.cmd("mkfifo", [gate])

    rule =
      Map.merge(outcome, %{
        "args" => ["--method PATCH", "repos/#{context.repository}/issues/#{number} "],
        "stdin" => [JSON.encode!(%{"title" => title})],
        "run" => "cat '#{gate}' > /dev/null"
      })

    context |> World.cli_rules([rule]) |> Map.put(:gh_gate, gate)
  end

  # GitHub's answer (a fake gh rule's outcome) to unblocking #`number`.
  defp unblocking(number, outcome),
    do:
      Map.merge(outcome, %{
        "args" => ["api graphql"],
        "stdin" => ["removeBlockedBy(input", ~s("issue":"#{GitHubIssues.issue_id(number)}")]
      })

  # Renames `task` to `title` in a client of its own, as another window's would, so the
  # rename can wait on GitHub while the scenario goes on; returns once the plan has it.
  defp rename_late(context, task, title) do
    %{mc: mc} = context
    call = %{"id" => @id, "method" => "updateItem"}
    input = %{"id" => task["id"], "fields" => %{"title" => title}}

    renaming =
      Task.async(fn ->
        Mc.call(Mc.connect(mc), mc.environment, "plugins.call", Map.put(call, "input", input))
      end)

    {_, context} = await_topic(context, "plan", &item(&1, title))
    {renaming, context}
  end

  defp move_input(context, title, from, to) do
    plan = plan!(context)
    ids = Enum.map([title, from, to], &(item(plan, &1) || flunk("the plan has no #{&1}"))["id"])
    Enum.zip(["id", "from", "to"], ids) |> Map.new()
  end

  defp update_task(context, number, fields) do
    task = task_of(plan!(context), number) || flunk("no task follows ##{number}")
    {reply, context} = plugin(context, "updateItem", %{"id" => task["id"], "fields" => fields})
    assert {:ok, _} = reply
    context
  end

  # `title` in the plan, added from its sample when it is not; `fields` set on it.
  defp ensure(context, title, fields \\ %{}) do
    case item(plan!(context), title) do
      nil -> add!(context, Map.merge(sample(context, title), fields))
      _ when fields == %{} -> context
      _ -> update!(context, title, fields)
    end
  end

  # Adds `title` again until its random id sorts after every other task's.
  defp add_last(context, title) do
    context = ensure(context, title)
    %{"id" => id} = item!(context, title)

    if Enum.any?(plan!(context)["items"], &(&1["id"] > id)) do
      {reply, context} = plugin(context, "removeItem", %{"id" => id})
      assert {:ok, _} = reply
      add_last(context, title)
    else
      context
    end
  end

  defp sample(context, title) do
    {start, due} = @samples[title] || {"2026-10-19", "2026-10-30"}

    %{
      "title" => title,
      "start" => start,
      "due" => due,
      "projectId" => World.project(context, "api").id
    }
  end

  # Schema, API waiting for it, and Docs, for actions on the whole plan.
  defp seed(context) do
    context = context |> ensure("Schema") |> ensure("API") |> ensure("Docs")
    schema = item!(context, "Schema")["id"]

    if schema in item!(context, "API")["after"],
      do: context,
      else: update!(context, "API", %{"after" => [schema]})
  end

  defp start_run(context, label, title \\ nil) do
    context = if title, do: ensure(context, title), else: seed(context)
    ids = if title, do: [item!(context, title)["id"]], else: []

    {reply, context} =
      plugin(context, "run", %{"action" => action_id(context, label), "itemIds" => ids})

    assert {:ok, %{"run" => run}} = reply
    started(context, run)
  end

  defp started(context, run) do
    assert %{"status" => "running", "threadId" => thread} = run
    World.await_row(thread, & &1, 10_000)
    Map.merge(context, %{run: run, thread: thread})
  end

  # The run of `label` proposing to move each of `titles` a week later.
  defp propose(context, label, titles) do
    context = start_run(context, label)
    plan = plan!(context)
    moves = Map.new(titles, &{&1, &1 |> then(fn t -> item(plan, t)["due"] end) |> later(7)})
    changes = for title <- titles, do: move(context, title, moves[title], "Schema slipped")

    assert %{"status" => "proposed"} =
             report!(context, %{"summary" => "Moved.", "changes" => changes})

    Map.merge(context, %{moves: moves, moved_ids: Map.new(titles, &{&1, item(plan, &1)["id"]})})
  end

  defp move(context, title, due, reason),
    do: %{
      "op" => "update",
      "itemId" => item!(context, title)["id"],
      "fields" => %{"due" => due},
      "reason" => reason
    }

  defp later(day, days), do: day |> Date.from_iso8601!() |> Date.add(days) |> Date.to_iso8601()

  defp apply_run(context) do
    {reply, context} = plugin(context, "apply", %{"runId" => context.run["id"]})
    assert {:ok, %{"run" => %{"status" => "applied"}}} = reply
    context
  end

  defp post_update(context, health, text) do
    {reply, context} =
      plugin(context, "postUpdate", %{"health" => @healths[health], "text" => text})

    assert {:ok, %{"update" => update}} = reply
    {update, context}
  end

  defp link_prs(context, title, repository, numbers) do
    id = item!(context, title)["id"]

    context =
      Enum.reduce(numbers, context, fn number, context ->
        pr = %{"repository" => repository, "number" => number}
        {reply, context} = plugin(context, "link", %{"itemId" => id, "pullRequest" => pr})
        assert {:ok, _} = reply
        context
      end)

    prs = Map.merge(context.prs, Map.new(numbers, &{&1, "OPEN"}))
    pr_list(%{context | prs: prs})
  end

  defp merge(context, number), do: pr_list(put_in(context.prs[number], "MERGED"))

  # The fake GitHub lists the linked pull requests in the states of `context.prs`,
  # after `context.newer_prs` more recently updated ones and before
  # `context.older_prs` older ones; a list that runs past a page carries on from the
  # oldest instant on it.
  defp pr_list(context) do
    prs =
      for {number, state} <- Enum.sort(context.prs),
          do: Shared.gh_pr(context.repository, number, %{"state" => state})

    newer =
      for minutes <- context.newer_prs..1//-1 do
        at = DateTime.add(~U[2026-09-10 00:00:00Z], minutes, :minute)
        fields = %{"updatedAt" => DateTime.to_iso8601(at)}
        Shared.gh_pr(context.repository, 1000 + minutes, fields)
      end

    older =
      for minutes <- 1..context.older_prs//1 do
        at = DateTime.add(~U[2026-09-01 00:00:00Z], -minutes, :minute)

        Shared.gh_pr(context.repository, 2000 + minutes, %{"updatedAt" => DateTime.to_iso8601(at)})
      end

    rows = newer ++ prs ++ older
    first = %{"args" => ["pr list"], "stdout" => Enum.take(rows, 501)}

    case Enum.at(rows, 499) do
      %{"updatedAt" => boundary} when length(rows) > 500 ->
        rest = %{"args" => ["pr list", "updated:<=#{boundary}"], "stdout" => Enum.drop(rows, 499)}
        World.cli_rules(context, [rest, first])

      _ ->
        World.cli_rules(context, [first])
    end
  end

  # Each `{number, title}` is an issue in that milestone on GitHub, the milestones numbered
  # from 1 in order, synced into the plan.
  defp in_milestones(context, issues) do
    numbers = issues |> Enum.with_index(1) |> Map.new(fn {{_, title}, n} -> {title, n} end)
    context = Map.merge(context, %{milestones: numbers, on_github: issues})

    context
    |> GitHubIssues.answers(context.repository, milestone_issues(context, issues))
    |> sync!()
  end

  # The issue nodes for `issues`, each `{number, milestone title}`.
  defp milestone_issues(context, issues) do
    for {number, title} <- issues do
      milestone = %{
        "number" => context.milestones[title],
        "title" => title,
        "dueOn" => "2026-11-30T00:00:00Z"
      }

      GitHubIssues.issue(context.repository, number, %{"milestone" => milestone})
    end
  end

  defp sync!(context) do
    {reply, context} = plugin(context, "sync", %{})
    assert {:ok, _} = reply
    context
  end

  defp posted(channel) do
    id = if channel == "#planning", do: "CPLAN", else: channel
    for %{"channel" => ^id, "text" => text} <- FakeSlack.calls("chat.postMessage"), do: text
  end

  defp assert_posted(channel, text) do
    texts = posted(channel)
    assert text in texts, "#{channel} did not get #{inspect(text)}: #{inspect(texts)}"
  end

  # Watches the plugin's `topic` on the client `name`; `await_topic/3` waits on it.
  defp watch(context, name, topic) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => topic
    }

    client = context |> World.client(name) |> Mc.sub(sub, shape)

    context
    |> World.put_client(name, client)
    |> put_in([:watched, name], {sub, nil})
  end

  # `{found, context}` once `fun` answers something truthy for the value of the topic
  # watched as `name`; the last value seen is kept, as a topic only moves forward.
  defp await_topic(context, name, fun) do
    {sub, last} = context.watched[name]

    if found = last && fun.(last) do
      {found, context}
    else
      {frame, client} =
        Mc.await(
          World.client(context, name),
          &(&1["t"] == "plugin" and &1["id"] == sub and !!fun.(&1["value"])),
          10_000
        )

      context =
        context
        |> World.put_client(name, client)
        |> put_in([:watched, name], {sub, frame["value"]})

      {fun.(frame["value"]), context}
    end
  end

  defp await_run(context, fun) do
    id = context.run["id"]

    await_topic(context, "runs", fn value ->
      Enum.find(value["runs"], &(&1["id"] == id and fun.(&1)))
    end)
  end

  # Lets the fake Codex finish every turn held at the gate.
  defp end_turns(context) do
    gate = Path.join(context.mc.home, "gate")
    File.mkdir_p!(gate)
    File.write!(Path.join(gate, "answer"), "I looked at it.")
    context
  end

  defp mcp(thread, method, params) do
    %{authorization: auth} = HalC2.Mcp.server(thread, "codex")
    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    {200, %{"result" => result}} = HalC2.Mcp.handle(auth, body)
    result
  end

  defp tools(thread), do: Enum.map(mcp(thread, "tools/list", %{})["tools"], & &1["name"])

  defp tool(context, name, arguments),
    do: mcp(context.thread, "tools/call", %{"name" => name, "arguments" => arguments})

  defp tool!(context, name, arguments) do
    result = tool(context, name, arguments)
    assert result["isError"] != true, inspect(result)
    result["structuredContent"]
  end

  defp report!(context, arguments), do: tool!(context, "planner_report", arguments)

  defp prompt(thread_id) do
    World.await_stream(thread_id, fn state ->
      state
      |> HalC2.StreamState.list("message")
      |> Enum.find_value(&(&1["role"] == "user" and &1["text"]))
    end)
  end

  defp thread(thread_id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
    HalC2.StreamState.get(state, "thread")[thread_id]
  end

  # Whether the running step is a Then (or an And/But following one), for the texts
  # that set something up as a Given and check it as a Then.
  defp then?(context) do
    context
    |> Map.get(:step_history, [])
    |> Enum.reverse()
    |> Enum.map(&String.trim(&1.keyword))
    |> Enum.find(&(&1 not in ["And", "But", "*"]))
    |> Kernel.==("Then")
  end
end
