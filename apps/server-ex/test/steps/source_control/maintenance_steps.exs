defmodule HalC2.Steps.SourceControl.Maintenance do
  @moduledoc """
  Steps for `features/source-control/maintenance.feature`, run against the real
  package in the repository's `plugins/maintenance`, copied into the MC's plugins
  directory as a user would install it.

  The repository is the fake GitHub's (`World.github_remote/3`): pushes land in a
  bare repository, and `gh` answers from rules. Every run's prompt carries "answer
  from gate", so the fake Codex holds its turn open until the scenario writes the
  gate file (`end_turns/1`); what the agent would do in its worktree, the scenario
  commits itself. The plugin's `maintenance` topic is watched from the start;
  `await_run/2` waits on it for what changes outside a call. Agents call the
  plugin's tool through the MC's MCP endpoint as a thread's agent would.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @id "maintenance"
  @package Path.expand("../../../../../plugins/maintenance", __DIR__)
  @gate " answer from gate"
  @manifest @package |> Path.join("plugin.json") |> File.read!() |> JSON.decode!()
  @defaults Map.new(@manifest["settings"], &{&1["key"], &1["default"]})
  @pr_url "https://github.com/acme/api/pull/43"

  # --- background ------------------------------------------------------------------------

  step "an MC running the maintenance plugin", context do
    dir = Path.join([context.mc.home, "plugins", @id])
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(@package, dir)

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

    context
    |> Map.put(:watched, nil)
    |> save(settings())
    |> watch()
  end

  step "{string} maintains {string}", %{args: [@id, repository]} = context do
    context
    |> World.cli_rules([%{"args" => ["pr create"], "stdout" => @pr_url <> "\n"}])
    |> save(%{"repositories" => [repository]})
    |> Map.put(:repository, repository)
  end

  step "{string} runs in {string} mode", %{args: [@id, mode]} = context do
    save(context, %{"mode" => mode})
  end

  step "{string} fixes only security advisories", %{args: [@id]} = context do
    save(context, %{"securityOnly" => true})
  end

  step "{string} publishes {string}", %{args: [@id, publishing]} = context do
    save(context, %{"publishing" => publishing})
  end

  step "{string} has the instructions {string} for {string}",
       %{args: [@id, text, repository]} = context do
    save(context, %{"instructions" => %{repository => text}})
  end

  step "{string} runs every day at {string}", %{args: [@id, time]} = context do
    save(context, %{"schedule" => "daily", "time" => time})
  end

  step "{string} has its own maintain skill in {string}", %{args: [project, dir]} = context do
    root = World.project(context, project).root
    File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join([root, dir, "SKILL.md"]), "---\nname: maintain\n---\n")
    context
  end

  step "{string} has an open pull request from {string}",
       %{args: [repository, branch]} = context do
    # The MC lists pull requests through GitHub's GraphQL (`HalC2.PullRequests.list/1`),
    # ahead of the empty listing the project's fake GitHub answers with.
    World.cli_rules(context, [
      %{
        "args" => ["api graphql"],
        "stdin" => ["PullRequestList"],
        "repository" => repository,
        "pulls" => [Shared.gh_pr(repository, 12, %{"headRefName" => branch})]
      }
    ])
  end

  # --- starting --------------------------------------------------------------------------

  step "the user runs maintenance on {string} now", %{args: [repository]} = context do
    {reply, context} = plugin(context, "run", %{"repository" => repository})
    context = Map.put(context, :reply, reply)

    case reply do
      {:ok, %{"status" => "running", "threadId" => thread} = run} ->
        World.await_row(thread, & &1, 10_000)

        context
        |> then(&if(&1[:run], do: Map.put_new(&1, :first_run, &1.run), else: &1))
        |> Map.merge(%{run: run, thread: thread})

      _ ->
        context
    end
  end

  step "the user can run maintenance on {string} again", %{args: [repository]} = context do
    {reply, context} = plugin(context, "run", %{"repository" => repository})
    assert {:ok, %{"status" => "running"}} = reply
    context
  end

  step "a maintenance run on {string}", %{args: [repository]} = context do
    start!(context, repository)
  end

  step "a maintenance run on {string} waiting with a commit", %{args: [repository]} = context do
    context = context |> start!(repository) |> commit!("chore(deps): bump lodash to 4.17.21")
    context |> report!(full_report(context)) |> await_status("waiting")
  end

  step "a maintenance run on {string} kept with a commit", %{args: [repository]} = context do
    context = context |> start!(repository) |> commit!("chore(deps): bump lodash to 4.17.21")
    context |> report!(full_report(context)) |> await_status("kept")
  end

  step "a maintenance run on {string} that is done", %{args: [repository]} = context do
    context = start!(context, repository)

    context
    |> report!(empty_report(context))
    |> await_status("done")
    |> Map.put(:first_run, context.run)
  end

  step "a maintenance run is running in a thread of the configured agent", context do
    run = run!(context)
    assert run["status"] == "running"

    assert %{"instanceId" => "codex", "model" => "fake/one"} =
             thread(context.thread)["modelSelection"]

    context
  end

  step "its thread works in a new worktree of {string} on a branch {string} from {string}",
       %{args: [project, branch, base]} = context do
    branch = String.replace(branch, "<today>", today())
    path = await_worktree(context.thread)
    assert path != World.project(context, project).root
    assert World.git!(path, ~w(branch --show-current)) == branch
    assert %{"branch" => ^branch, "base" => ^base} = run!(context)
    context
  end

  step "its thread works in the checkout of {string}", %{args: [project]} = context do
    _ = prompt(context.thread)
    assert thread(context.thread)["worktreePath"] in [nil, World.project(context, project).root]
    assert run!(context)["branch"] == nil
    context
  end

  step "its prompt names the maintain skill shipped with the plugin", context do
    [path] = Regex.run(~r{/\S+/skill/SKILL\.md}, prompt(context.thread))
    assert File.read!(path) =~ "name: maintain"
    context
  end

  step "its prompt names the maintain skill in {string}", %{args: [dir]} = context do
    assert prompt(context.thread) =~ "#{dir}/SKILL.md (this repository's own)"
    context
  end

  step "its prompt keeps it off {string}, one commit per category behind the gates, with major bumps deferred",
       %{args: [base]} = context do
    text = prompt(context.thread)
    assert text =~ "Never commit to, merge into or push #{base}"
    assert text =~ "Do not push at all"
    assert text =~ "one commit per category"
    assert text =~ "the repository's own gates pass"
    assert text =~ "Always defer major version bumps"
    assert text =~ "even when nothing changed"
    context
  end

  step "its prompt tells it to change nothing", context do
    assert prompt(context.thread) =~ "This is a report run: change nothing."
    refute prompt(context.thread) =~ "one commit per category"
    context
  end

  step "the run covers only {string}", %{args: [category]} = context do
    assert run!(context)["categories"] == [category]
    assert run!(context)["securityOnly"] == true
    context
  end

  step "its prompt asks for the smallest upgrade that resolves each advisory", context do
    assert prompt(context.thread) =~ "the smallest upgrade that resolves it"
    context
  end

  step "its prompt includes {string}", %{args: [text]} = context do
    assert prompt(context.thread) =~ text
    context
  end

  step "the run is skipped, naming that pull request", context do
    assert {:ok, %{"status" => "skipped"} = run} = context.reply
    assert run["prUrl"] =~ "/pull/12"
    assert run["error"] =~ "still open"
    context
  end

  step "no maintenance thread starts", context do
    runs = snapshot!(context)["runs"]
    refute Enum.any?(runs, &(&1["status"] == "running")), inspect(runs)
    context
  end

  step "the run is refused, told {string}", %{args: [message]} = context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ message
    context
  end

  # --- reporting -------------------------------------------------------------------------

  step "its agent committed {string} on its branch", %{args: [message]} = context do
    commit!(context, message)
  end

  step "its agent reports the commit, a deferred major bump and a passing gate", context do
    report!(context, full_report(context))
  end

  step "its agent reports nothing applied in every category", context do
    report!(context, empty_report(context))
  end

  step "its agent reports a commit", context do
    report = full_report(Map.put(context, :sha, "abc1234"))
    Map.put(context, :tool_result, tool(context, report))
  end

  step "its agent reports only {string}", %{args: [category]} = context do
    report = %{
      "summary" => "Only deps.",
      "categories" => [%{"category" => category}],
      "gate" => %{"command" => "npm test", "result" => "passed"}
    }

    Map.put(context, :tool_result, tool(context, report))
  end

  step "its agent reports a finding quoting the token {string}", %{args: [token]} = context do
    report =
      put_in(
        empty_report(context),
        ["categories", Access.at(0), "findings"],
        ["The CI log printed GITHUB_TOKEN #{token} in a failing step."]
      )

    report!(context, report)
  end

  step "its agent's turn ends without reporting", context do
    end_turns(context)
  end

  # As the host hands the plugin a turn that failed at a usage limit
  # (`HalC2.Plugins.turn_finished/3`), in this process so its handling is over on return.
  step "its agent's turn stops at a usage limit", context do
    HalC2Plugins.Maintenance.handle_event(
      %{
        "type" => "turn.finished",
        "threadId" => context.thread,
        "status" => "error",
        "errorClass" => "usage_limit",
        "error" => "You've hit your usage limit.",
        "resetAt" => System.system_time(:millisecond) + 3_600_000
      },
      %{id: @id}
    )

    context
  end

  step "its thread is left unsettled for the MC to resume", context do
    refute thread(context.thread)["settledOverride"] == "settled"
    context
  end

  step "the first run's agent reports nothing applied in every category", context do
    first = context.first_run

    context
    |> Map.merge(%{run: first, thread: first["threadId"]})
    |> then(&Map.put(&1, :tool_result, tool(&1, empty_report(&1))))
  end

  step "the run waits for the user to open its pull request", context do
    await_status(context, "waiting")
  end

  step "the run is done", context do
    await_status(context, "done")
  end

  step "the run is kept in HAL-C2", context do
    await_status(context, "kept")
  end

  step "the maintenance run is cancelled", context do
    await_status(context, "cancelled")
  end

  step "the maintenance run is still running", context do
    assert run!(context)["status"] == "running"
    context
  end

  step "nothing was pushed", context do
    assert World.cli_calls(context, "pr create") == []
    assert remote_branches(context) == []
    context
  end

  step "its report keeps the deferred bump with its command", context do
    deps = Enum.find(run!(context)["report"]["categories"], &(&1["category"] == "deps"))
    assert [%{"command" => "npm install react@19"}] = deps["deferred"]
    assert [%{"title" => "chore(deps): bump lodash to 4.17.21"}] = deps["applied"]
    context
  end

  step "the maintenance agent is told {string}", %{args: [message]} = context do
    assert context.tool_result["isError"] == true
    assert inspect(context.tool_result) =~ message
    context
  end

  step "the maintenance agent is told the pull request is open", context do
    assert context.tool_result["status"] == "published"
    assert context.tool_result["next"] =~ "The pull request is open: #{@pr_url}"
    context
  end

  step "the report says {string} where the token was", %{args: [marker]} = context do
    {run, context} = await_run(context, &(&1["report"] != nil))
    text = inspect(run["report"])
    assert text =~ marker
    refute text =~ "ghp_"
    context
  end

  step "the maintenance run failed, saying it finished without reporting", context do
    {run, context} = await_run(context, &(&1["status"] == "failed"))
    assert run["error"] =~ "finished without reporting"
    # Its turn is over, so the gate closes again for the turns that follow.
    File.rm!(Path.join([context.mc.home, "gate", "answer"]))
    context
  end

  # --- publishing ------------------------------------------------------------------------

  step "GitHub refuses to open the maintenance pull request", context do
    World.cli_rules(context, [
      %{
        "args" => ["pr create"],
        "exit" => 1,
        "stderr" => "pull request create failed: GraphQL: Resource not accessible\n"
      }
    ])
  end

  step "the user opens its pull request", context do
    {reply, context} = plugin(context, "publish", %{"runId" => context.run["id"]})
    Map.merge(context, %{reply: reply, publish_reply: reply})
  end

  step "its branch is pushed to {string}", %{args: [_repository]} = context do
    assert remote_branches(context) == [run!(context)["branch"]]
    context
  end

  step "a pull request is opened from its branch into {string} with the report as its body",
       %{args: [base]} = context do
    [call] = World.cli_calls(context, "pr create")
    branch = run!(context)["branch"]
    joined = Enum.join(call["args"], " ")
    assert joined =~ "--base #{base}"
    assert joined =~ "--head #{branch}"
    assert joined =~ "--repo #{context.repository}"
    assert call["stdin"] =~ "## Dependencies"
    assert call["stdin"] =~ "chore(deps): bump lodash to 4.17.21"
    assert call["stdin"] =~ "`npm install react@19`"
    assert call["stdin"] =~ "`npm test`: passed"
    context
  end

  step "the run is published with the pull request's address", context do
    # The user's publish answers once it is over, so one that failed says here why,
    # rather than as a frame that never comes.
    if reply = context[:publish_reply] do
      assert match?({:ok, %{"status" => "published"}}, reply),
             "opening the pull request answered #{inspect(reply)}; the run is #{inspect(run!(context))}"
    end

    {run, context} = await_run(context, &(&1["status"] == "published"))
    assert run["prUrl"] == @pr_url
    context
  end

  step "the run waits again, saying why it was refused", context do
    assert {:error, _, _} = context.reply
    {run, context} = await_run(context, &(&1["status"] == "waiting" and &1["publishError"]))
    assert run["publishError"] =~ "gh pr create failed"
    context
  end

  # --- cancelling, dismissing, rerunning -------------------------------------------------

  step "the user cancels the run", context do
    {reply, context} = plugin(context, "cancel", %{"runId" => context.run["id"]})
    assert {:ok, %{"status" => "cancelled"}} = reply
    context
  end

  step "a report from its agent is refused", context do
    result = tool(context, empty_report(context))
    assert result["isError"] == true
    assert inspect(result) =~ "cancelled"
    context
  end

  step "the user dismisses the run", context do
    {reply, context} = plugin(context, "dismiss", %{"runId" => context.run["id"]})
    assert {:ok, %{"dismissed" => true}} = reply
    context
  end

  step "the run is no longer listed", context do
    refute Enum.any?(snapshot!(context)["runs"], &(&1["id"] == context.run["id"]))
    context
  end

  step "both runs are listed", context do
    ids = Enum.map(snapshot!(context)["runs"], & &1["id"])
    assert context.first_run["id"] in ids
    assert context.run["id"] in ids
    assert context.first_run["id"] != context.run["id"]
    context
  end

  # --- scheduling ------------------------------------------------------------------------

  # What a plugin that last handled a slot long ago left behind. A settings save queues
  # a tick that writes the file under the new schedule (slots under another one are
  # dropped); a call to the plugin returns after it. The plugin is then stopped, so no
  # later tick puts back the slot it handled.
  step "the MC last ran maintenance on {string} for a slot long ago",
       %{args: [repository]} = context do
    snapshot!(context)
    {_, context} = World.call!(context, "plugins.disable", %{"id" => @id})
    path = Path.join(HalC2.Plugins.Host.data_dir(@id), "state.json")
    saved = path |> File.read!() |> JSON.decode!()
    File.write!(path, JSON.encode!(put_in(saved, ["slots", repository], "2020-01-06T06:00:00")))
    Map.put(context, :stopped, true)
  end

  step "the plugin starts again", context do
    {_, context} =
      if context[:stopped] do
        accepted = Enum.map(Fixtures.entry(@id)["permissions"], & &1["id"])
        World.call!(context, "plugins.enable", %{"id" => @id, "acceptPermissions" => accepted})
      else
        World.call!(context, "plugins.restart", %{"id" => @id})
      end

    Map.delete(context, :stopped)
  end

  step "a scheduled maintenance run starts on {string}", %{args: [repository]} = context do
    {run, context} =
      await_topic(context, fn value ->
        Enum.find(
          value["runs"],
          &(&1["trigger"] == "scheduled" and &1["repository"] == repository)
        )
      end)

    assert run["status"] == "running", inspect(run)
    World.await_row(run["threadId"], & &1, 10_000)
    Map.merge(context, %{run: run, thread: run["threadId"]})
  end

  step "{string} shows when its next run is", %{args: [repository]} = context do
    entry = Enum.find(snapshot!(context)["repositories"], &(&1["repository"] == repository))
    assert is_integer(entry["nextRunAt"])
    assert entry["nextRunAt"] > System.system_time(:millisecond)
    assert entry["project"] == "api"
    context
  end

  # --- settings --------------------------------------------------------------------------

  step "the user opens the maintenance settings", context do
    {reply, context} = plugin(context, "settings", %{})
    assert {:ok, offered} = reply
    Map.put(context, :offered, offered)
  end

  step "the MC's agents are offered with their models to maintain", context do
    assert %{"name" => _, "models" => [%{"slug" => _} | _]} =
             Enum.find(context.offered["providers"], &(&1["instanceId"] == "codex"))

    assert context.offered["settings"]["provider"] == "codex"
    context
  end

  step "{string} is offered to maintain", %{args: [repository]} = context do
    assert repository in context.offered["repositories"]
    context
  end

  step "{string} is not offered to maintain", %{args: [repository]} = context do
    refute repository in context.offered["repositories"]
    context
  end

  step "{string} maintains {string}, which no project has as its remote",
       %{args: [@id, repository]} = context do
    save(context, %{"repositories" => [context.repository, repository]})
  end

  step "the page says {string} has no project with it as its remote",
       %{args: [repository]} = context do
    {repositories, context} =
      await_topic(context, fn value ->
        listed = value["repositories"]
        Enum.any?(listed, &(&1["repository"] == repository)) && listed
      end)

    assert %{"project" => nil} = Enum.find(repositories, &(&1["repository"] == repository))
    assert %{"project" => "api"} = Enum.find(repositories, &(&1["repository"] == "acme/api"))
    context
  end

  step "the user saves the maintenance settings with the repository {string}",
       %{args: [bad]} = context do
    save_refused(context, %{"repositories" => [bad]})
  end

  step "the user saves the maintenance settings with the time {string}",
       %{args: [time]} = context do
    save_refused(context, %{"schedule" => "daily", "time" => time})
  end

  step "the user saves the maintenance settings with the category {string}",
       %{args: [category]} = context do
    save_refused(context, %{"categories" => [category]})
  end

  step "the user saves the maintenance settings with the mode {string}",
       %{args: [mode]} = context do
    save_refused(context, %{"mode" => mode})
  end

  step "the user saves the maintenance settings with the publishing {string}",
       %{args: [publishing]} = context do
    save_refused(context, %{"publishing" => publishing})
  end

  step "the user saves the maintenance settings with an empty prompt", context do
    save_refused(context, %{"prompt" => "  "})
  end

  # --- helpers ---------------------------------------------------------------------------

  defp settings do
    %{
      "repositories" => [],
      "schedule" => "manual",
      "prompt" => @defaults["prompt"] <> @gate,
      "provider" => "codex",
      "model" => "fake/one",
      "modelOptions" => %{},
      "runtimeMode" => "auto-accept-edits"
    }
  end

  defp today,
    do:
      :calendar.local_time()
      |> NaiveDateTime.from_erl!()
      |> NaiveDateTime.to_date()
      |> Date.to_iso8601()

  defp start!(context, repository) do
    {reply, context} = plugin(context, "run", %{"repository" => repository})
    assert {:ok, %{"status" => "running", "threadId" => thread} = run} = reply
    World.await_row(thread, & &1, 10_000)
    _ = prompt(thread)
    Map.merge(context, %{run: run, thread: thread})
  end

  defp commit!(context, message) do
    path = await_worktree(context.thread)

    sha =
      World.commit!(
        path,
        %{"package.json" => ~s({"dependencies":{"lodash":"4.17.21"}}\n)},
        message
      )

    Map.merge(context, %{sha: sha, commit_message: message})
  end

  # Every category of the run, deps with the commit made and a deferred major bump.
  defp full_report(context) do
    run = context.run

    %{
      "summary" => "Bumped lodash; react 19 needs a human.",
      "categories" =>
        for category <- run["categories"] do
          if category == "deps" do
            %{
              "category" => "deps",
              "applied" => [
                %{
                  "title" => context[:commit_message] || "chore(deps): bump lodash to 4.17.21",
                  "commit" => context[:sha]
                }
              ],
              "deferred" => [
                %{
                  "item" => "react 18 → 19",
                  "reason" => "major bump",
                  "command" => "npm install react@19"
                }
              ]
            }
          else
            %{"category" => category}
          end
        end,
      "gate" => %{"command" => "npm test", "result" => "passed"}
    }
  end

  defp empty_report(context) do
    %{
      "summary" => "Nothing needed doing.",
      "categories" => Enum.map(context.run["categories"], &%{"category" => &1, "findings" => []}),
      "gate" => %{"command" => "npm test", "result" => "passed"}
    }
  end

  defp report!(context, report) do
    result = tool(context, report)
    assert result["isError"] != true, inspect(result)
    Map.put(context, :tool_result, result["structuredContent"])
  end

  defp save(context, patch) do
    {_, context} =
      World.call!(context, "plugins.saveSettings", %{"id" => @id, "settings" => patch})

    context
  end

  defp save_refused(context, patch) do
    {reply, context} =
      World.call(context, "plugins.saveSettings", %{"id" => @id, "settings" => patch})

    Map.put(context, :reply, reply)
  end

  defp plugin(context, method, input),
    do: World.call(context, "plugins.call", %{"id" => @id, "method" => method, "input" => input})

  defp snapshot!(context) do
    {reply, _} = plugin(context, "maintenance", %{})
    assert {:ok, snapshot} = reply
    snapshot
  end

  defp run!(context),
    do:
      Enum.find(snapshot!(context)["runs"], &(&1["id"] == context.run["id"])) ||
        flunk("the run is gone")

  defp await_status(context, status) do
    {_, context} = await_run(context, &(&1["status"] == status))
    context
  end

  # The maintenance branches the fake GitHub has.
  defp remote_branches(context) do
    bare = Path.join(System.fetch_env!("HAL_C2_FAKE_REMOTES"), "#{context.repository}.git")

    World.git!(bare, ["branch", "--list", "maintenance/*", "--format=%(refname:short)"])
    |> String.split("\n", trim: true)
  end

  defp await_worktree(thread_id) do
    World.await_stream(
      thread_id,
      fn state ->
        thread = HalC2.StreamState.get(state, "thread")[thread_id]
        thread && thread["worktreePath"]
      end,
      15_000
    )
  end

  # Watches the plugin's `maintenance` topic; `await_topic/2` waits on it.
  defp watch(context) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "maintenance"
    }

    client = context |> World.client("maintenance") |> Mc.sub(sub, shape)

    context
    |> World.put_client("maintenance", client)
    |> Map.put(:watched, {sub, nil})
  end

  defp await_topic(context, fun) do
    {sub, last} = context.watched

    if found = last && fun.(last) do
      {found, context}
    else
      {frame, client} =
        Mc.await(
          World.client(context, "maintenance"),
          &(&1["t"] == "plugin" and &1["id"] == sub and !!fun.(&1["value"])),
          15_000
        )

      context =
        context
        |> World.put_client("maintenance", client)
        |> Map.put(:watched, {sub, frame["value"]})

      {fun.(frame["value"]), context}
    end
  end

  defp await_run(context, fun) do
    id = context.run["id"]
    await_topic(context, fn value -> Enum.find(value["runs"], &(&1["id"] == id and fun.(&1))) end)
  end

  # Lets the fake Codex finish every turn held at the gate.
  defp end_turns(context) do
    gate = Path.join(context.mc.home, "gate")
    File.mkdir_p!(gate)
    File.write!(Path.join(gate, "answer"), "I looked at it.")
    context
  end

  defp tool(context, arguments) do
    %{authorization: auth} = HalC2.Mcp.server(context.thread, "codex")

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "maintenance_report", "arguments" => arguments}
      })

    {200, %{"result" => result}} = HalC2.Mcp.handle(auth, body)
    result
  end

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
end
