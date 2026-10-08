defmodule HalC2.Steps.SourceControl.AgentCodeReview do
  @moduledoc """
  Steps for `features/source-control/agent-code-review.feature`, run against the real
  package in the repository's `plugins/code-review`, copied into the MC's plugins
  directory as a user would install it.

  The fake GitHub lists the pull requests in `context.prs` (number → gh fields); each
  has a head commit at `refs/pull/<n>/head` of the fake remote, pushed from a clone
  of its own so the project's checkout is never touched. Reviews run on the fake
  Codex with a prompt that ends in "answer from gate", which keeps the turn open
  until the scenario writes the gate file (`end_turns/1`). The plugin's `reviews`
  topic is watched from the start; `await_review/3` waits on it.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @id "code-review"
  @package Path.expand("../../../../../plugins/code-review", __DIR__)
  @prompt "Review \#{{pr.number}} {{pr.title}} in {{repository}}. answer from gate"
  @limits "export const limit = 10;\nexport const burst = 20;\nexport function allow() {\n  return true;\n}\n"
  @verdicts %{
    "changes requested" => "request-changes",
    "approved" => "approve",
    "commented" => "comment"
  }
  @counts %{"one" => 1, "two" => 2, "three" => 3, "four" => 4}

  # --- background ------------------------------------------------------------------------

  step "an MC running the plugin {string} with GitHub as its host", %{args: [@id]} = context do
    dir = Path.join([context.mc.home, "plugins", @id])
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(@package, dir)

    context =
      context
      |> World.agents()
      |> Fixtures.ensure()
      |> Fixtures.rescan()

    Mc.ensure(HalC2.Mcp)
    Mc.ensure({Registry, keys: :unique, name: HalC2.Vcs.Registry})
    Mc.ensure({DynamicSupervisor, name: HalC2.Vcs.Supervisor, strategy: :one_for_one})
    accepted = Enum.map(Fixtures.entry(@id)["permissions"], & &1["id"])

    {_, context} =
      World.call!(context, "plugins.enable", %{"id" => @id, "acceptPermissions" => accepted})

    assert %{"status" => "running"} = Fixtures.entry(@id)

    context
    |> Map.merge(%{prs: %{}, heads: %{}})
    |> save(%{
      "provider" => "codex",
      "model" => "fake/one",
      "prompt" => @prompt,
      "pollMinutes" => 60
    })
    |> watch()
  end

  step "the project {string} whose remote is {string} on GitHub",
       %{args: [title, repository]} = context do
    context = World.create_project(context, title)
    root = World.project(context, title).root
    bare = World.github_remote(context, root, repository)
    source = Path.join(Mc.tmp_dir(context.mc, "pr-source"), "repo")
    World.git!(Path.dirname(source), ["clone", "-q", bare, source])

    context
    |> World.cli_rules([
      %{"args" => ["api user"], "stdout" => %{"id" => 7, "login" => "monalisa"}},
      %{"args" => ["pr list"], "stdout" => []},
      Shared.permissions_rule("WRITE"),
      %{"args" => ["--method POST", "pulls/"], "stdout" => "{}"}
    ])
    |> Map.merge(%{
      repository: repository,
      root: root,
      source: source,
      untouched: checkout_state(root)
    })
  end

  step "the project {string} whose remote is {string} on GitLab",
       %{args: [title, repository]} = context do
    context = World.create_project(context, title)

    World.git!(World.project(context, title).root, [
      "remote",
      "add",
      "origin",
      "git@gitlab.com:#{repository}.git"
    ])

    context
  end

  # --- what is watched and when -------------------------------------------------------------

  step "{string} watches {string} automatically", %{args: [@id, repo]} = context do
    save(context, %{"repositories" => [repo], "activation" => "automatic"})
  end

  step "{string} watches {string} selectively", %{args: [@id, repo]} = context do
    save(context, %{"repositories" => [repo], "activation" => "selective"})
  end

  step "{string} watches {string} selectively with the trigger {string}",
       %{args: [@id, repo, trigger]} = context do
    triggers =
      case trigger do
        "review requested" -> %{"reviewRequested" => true, "label" => "", "command" => ""}
        "label" -> %{"reviewRequested" => false, "label" => "agent-review", "command" => ""}
        "comment command" -> %{"reviewRequested" => false, "label" => "", "command" => "/review"}
      end

    save(
      context,
      Map.merge(triggers, %{"repositories" => [repo], "activation" => "selective"})
    )
  end

  step "{string} watches {string} automatically and skips drafts",
       %{args: [@id, repo]} = context do
    save(context, %{
      "repositories" => [repo],
      "activation" => "automatic",
      "skipDrafts" => true
    })
  end

  step "{string} watches {string} automatically and ignores the author {string}",
       %{args: [@id, repo, author]} = context do
    save(context, %{
      "repositories" => [repo],
      "activation" => "automatic",
      "ignoredAuthors" => [author]
    })
  end

  step "{string} watches {string} automatically and skips changes over {int} lines",
       %{args: [@id, repo, lines]} = context do
    save(context, %{
      "repositories" => [repo],
      "activation" => "automatic",
      "maxChangedLines" => lines
    })
  end

  step "the pull request \#{int} is opened on {string}", %{args: [number, _repo]} = context do
    context |> open(number) |> refresh()
  end

  step "the draft pull request \#{int} is opened on {string}", %{args: [number, _]} = context do
    context |> open(number, %{"isDraft" => true}) |> refresh()
  end

  step "\#{int} by {string} is opened on {string}", %{args: [number, author, _]} = context do
    context |> open(number, %{"author" => %{"login" => author}}) |> refresh()
  end

  step "\#{int} changing {int} lines is opened on {string}",
       %{args: [number, lines, _]} = context do
    context
    |> open(number, %{"additions" => lines - 1000, "deletions" => 1000})
    |> refresh()
  end

  step "the user is requested as a reviewer of \#{int}", %{args: [number]} = context do
    context
    |> open(number, %{"reviewRequests" => [%{"login" => "monalisa"}]})
    |> refresh()
  end

  step "\#{int} gets the label {string}", %{args: [number, label]} = context do
    context
    |> open(number, %{"labels" => [%{"name" => label, "color" => "0e8a16"}]})
    |> refresh()
  end

  step "someone comments {string} on \#{int}", %{args: [body, number]} = context do
    activity = %{
      "author" => %{"login" => "octocat"},
      "comments" => [
        %{
          "id" => "IC_1",
          "author" => %{"login" => "hubot"},
          "body" => body,
          "createdAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "url" => "https://github.com/acme/api/pull/#{number}#issuecomment-1"
        }
      ],
      "reviews" => [],
      "commits" => []
    }

    context
    |> World.cli_rules([
      %{"args" => ["pr view #{number}", "author,comments"], "stdout" => activity}
    ])
    |> open(number, %{"updatedAt" => "2026-09-03T00:00:00Z"})
    |> refresh()
  end

  step "the user asks for a review of \#{int}", %{args: [number]} = context do
    context |> open(number) |> start(number)
  end

  step "the open pull requests of {string} cannot be listed", context do
    Map.put(context, :unlisted, true)
  end

  step "the user asks for a review of \#{int}, which is merged", %{args: [number]} = context do
    context = open(context, number, %{"state" => "MERGED", "mergedAt" => "2026-09-02T00:00:00Z"})

    {reply, context} =
      plugin(context, "start", %{"repository" => context.repository, "number" => number})

    context |> Map.put(:reply, reply) |> refresh()
  end

  step "{string} looks at {string} again", %{args: [@id, _repo]} = context do
    refresh(context)
  end

  step "{string} looks at {string}", %{args: [@id, repo]} = context do
    context |> save(%{"repositories" => [repo]}) |> refresh()
  end

  step "a review of \#{int} starts with the configured agent", %{args: [number]} = context do
    context = started(context, number)

    assert %{"instanceId" => "codex", "model" => "fake/one"} =
             thread(context.thread)["modelSelection"]

    context
  end

  step "a review of \#{int} starts", %{args: [number]} = context do
    started(context, number)
  end

  step "no review starts", context do
    snapshot = context.snapshot

    refute Enum.any?(
             snapshot["reviews"],
             &(&1["status"] in ~w(queued running) or &1["threadId"])
           ),
           inspect(snapshot["reviews"])

    context
  end

  step "\#{int} is listed as ready to review", %{args: [number]} = context do
    assert %{"status" => "ready"} = review(context.snapshot, number)
    context
  end

  step "\#{int} was reviewed at its current head commit", %{args: [number]} = context do
    reviewed(context, number)
  end

  step "\#{int} was reviewed at an older head commit", %{args: [number]} = context do
    context = reviewed(context, number)

    head =
      push_head(context, number, %{"src/limits.ts" => @limits <> "export const later = 1;\n"})

    context
    |> put_in([:heads, number], head)
    |> open(number, %{"headRefOid" => head, "updatedAt" => "2026-09-04T00:00:00Z"})
  end

  step "{string} reviews new pushes", %{args: [@id]} = context do
    save(context, %{"reviewNewPushes" => true})
  end

  step "{string} does not review new pushes", %{args: [@id]} = context do
    save(context, %{"reviewNewPushes" => false})
  end

  step "a new review of \#{int} starts for the new head commit", %{args: [number]} = context do
    old = context.thread
    head = context.heads[number]

    {review, context} =
      await_review(context, number, &(&1["threadId"] != old and &1["reviewedSha"] == head))

    assert review["status"] in ~w(running failed)
    World.await_row(review["threadId"], & &1)
    context
  end

  step "no new review of \#{int} starts", %{args: [number]} = context do
    review = review(context.snapshot, number)
    assert review["threadId"] == context.thread
    refute review["status"] in ~w(queued running)
    context
  end

  step "\#{int} is listed as changed since its review", %{args: [number]} = context do
    assert %{"changed" => true, "status" => "waiting"} = review(context.snapshot, number)
    context
  end

  step "{string} runs at most {int} reviews at once", %{args: [@id, count]} = context do
    save(context, %{
      "concurrency" => count,
      "repositories" => [context.repository],
      "activation" => "automatic"
    })
  end

  step "four watched pull requests are opened", context do
    12..15 |> Enum.reduce(context, &open(&2, &1)) |> refresh()
  end

  step "two reviews run and two wait their turn", context do
    statuses = Enum.map(context.snapshot["reviews"], & &1["status"])
    assert Enum.frequencies(statuses) == %{"running" => 2, "queued" => 2}
    context
  end

  # --- the agent and its prompt ----------------------------------------------------------------

  step "{string} reviews with Claude on {string} in the {string} mode",
       %{args: [@id, model, mode]} = context do
    save(context, %{
      "provider" => World.instance("Claude"),
      "model" => model,
      "runtimeMode" => mode
    })
    |> Map.merge(%{model: model, runtime_mode: mode})
  end

  step "\#{int} is reviewed", %{args: [number]} = context do
    context |> open(number) |> start(number) |> started(number)
  end

  step "\#{int} {string} into {string} is reviewed", %{args: [number, title, base]} = context do
    context
    |> open(number, %{"title" => title, "baseRefName" => base})
    |> start(number)
    |> started(number)
  end

  step "its thread runs Claude with that model and mode", context do
    thread = thread(context.thread)
    assert thread["modelSelection"]["instanceId"] == World.instance("Claude")
    assert thread["modelSelection"]["model"] == context.model
    assert thread["runtimeMode"] == context.runtime_mode
    context
  end

  step "the settings of {string} are opened", %{args: [@id]} = context do
    {{:ok, offered}, context} = plugin(context, "settings", %{})
    Map.put(context, :offered, offered)
  end

  step "the MC's agents are offered with their models", context do
    assert %{"name" => _, "models" => [%{"slug" => _} | _]} =
             Enum.find(context.offered["providers"], &(&1["instanceId"] == "codex"))

    context
  end

  step "{string} is offered as a repository to watch", %{args: [repo]} = context do
    assert repo in context.offered["repositories"]
    context
  end

  step "the review prompt template is {string}", %{args: [template]} = context do
    save(context, %{"prompt" => template})
  end

  step "the agent is asked {string}", %{args: [text]} = context do
    prompt = prompt(context.thread)
    assert String.starts_with?(prompt, text), prompt
    Map.put(context, :prompt, prompt)
  end

  step "it is told how to report what it finds", context do
    assert context.prompt =~ "code_review_report"
    context
  end

  step "{string} has extra review instructions {string}", %{args: [repo, text]} = context do
    save(context, %{"instructions" => %{repo => text}})
  end

  step "the agent's prompt includes {string}", %{args: [text]} = context do
    prompt = prompt(context.thread)
    assert prompt =~ text, prompt
    context
  end

  step "{string} reads REVIEW.md", %{args: [@id]} = context do
    save(context, %{"readReviewMd" => true})
  end

  step "the head of \#{int} has a REVIEW.md saying {string}", %{args: [number, text]} = context do
    head = push_head(context, number, %{"src/limits.ts" => @limits, "REVIEW.md" => text <> "\n"})
    put_in(context, [:heads, number], head)
  end

  step "the head of \#{int} has a REVIEW.md that links to a file outside its repository",
       %{args: [number]} = context do
    outside = Path.join(context.mc.home, "outside.md")
    File.write!(outside, "outside the checkout\n")
    source = context.source
    World.git!(source, ~w(fetch -q origin))
    World.git!(source, ~w(checkout -q --detach origin/main))
    File.ln_s!(outside, Path.join(source, "REVIEW.md"))
    File.mkdir_p!(Path.join(source, "src"))
    File.write!(Path.join(source, "src/limits.ts"), @limits)
    World.git!(source, ~w(add REVIEW.md src/limits.ts))
    World.git!(source, ["commit", "-q", "-m", "Pull request #{number}"])
    World.git!(source, ["push", "-q", "--force", "origin", "HEAD:refs/pull/#{number}/head"])
    put_in(context, [:heads, number], World.git!(source, ~w(rev-parse HEAD)))
  end

  step "the head of \#{int} has a REVIEW.md that is longer than a prompt takes",
       %{args: [number]} = context do
    text = "a very long REVIEW.md\n" <> String.duplicate("Check everything.\n", 4000)
    head = push_head(context, number, %{"src/limits.ts" => @limits, "REVIEW.md" => text})
    put_in(context, [:heads, number], head)
  end

  step "the head of \#{int} has a REVIEW.md that is not UTF-8 text",
       %{args: [number]} = context do
    text = "not UTF-8 text\n" <> <<0xFF, 0xFE>>
    head = push_head(context, number, %{"src/limits.ts" => @limits, "REVIEW.md" => text})
    put_in(context, [:heads, number], head)
  end

  step "the agent's prompt does not include {string}", %{args: [text]} = context do
    prompt = prompt(context.thread)
    refute prompt =~ text, prompt
    context
  end

  step "the user changed the review prompt template", context do
    save(context, %{"prompt" => "Look hard at {{pr.title}}. answer from gate"})
  end

  step "the user resets the review prompt", context do
    save(context, %{"prompt" => nil})
  end

  step "the next review uses the plugin's default prompt", context do
    context = context |> open(12) |> start(12) |> started(12)
    prompt = prompt(context.thread)

    assert String.starts_with?(prompt, ~s(Review pull request #12 "Pull request 12" in acme/api)),
           prompt

    assert prompt =~ "git diff #{context.review["mergeBase"]} HEAD"
    context
  end

  step "its thread works in a checkout of the head of \#{int}", %{args: [number]} = context do
    {review, context} = await_review(context, number, & &1["checkout"])
    assert thread(context.thread)["worktreePath"] == review["checkout"]
    assert World.git!(review["checkout"], ~w(rev-parse HEAD)) == context.heads[number]
    context
  end

  step "the user's own checkout of {string} is not touched", context do
    assert checkout_state(context.root) == context.untouched
    context
  end

  # --- findings --------------------------------------------------------------------------------

  step "a review of \#{int} is running", %{args: [number]} = context do
    running(context, number)
  end

  step "the agent reports the verdict {string} with two comments on {string}",
       %{args: [verdict, path]} = context do
    report(context, %{
      "verdict" => @verdicts[verdict],
      "summary" => "The limits are never enforced.",
      "comments" => [
        %{"path" => path, "line" => 1, "body" => "Make the limit configurable."},
        %{"path" => path, "line" => 4, "body" => "This always allows."}
      ]
    })
  end

  step "the agent reports the verdict {string} with no summary and no comments",
       %{args: [verdict]} = context do
    result =
      call_report(context, %{"verdict" => @verdicts[verdict], "summary" => " ", "comments" => []})

    Map.put(context, :report_result, result)
  end

  step "the agent is told its report needs a summary or a comment on the change", context do
    assert %{"isError" => true, "content" => [%{"text" => text}]} = context.report_result
    assert text =~ "summary must say what the review found"
    context
  end

  step "the review of \#{int} is finished with that verdict, summary and comments",
       %{args: [number]} = context do
    {review, context} = await_review(context, number, &(&1["status"] == "waiting"))
    assert review["verdict"] == "request-changes"
    assert review["summary"] == "The limits are never enforced."

    assert [
             %{"line" => 1, "position" => %{"kind" => "added", "newLine" => 1}},
             %{"line" => 4, "position" => %{"kind" => "added", "newLine" => 4}}
           ] = review["comments"]

    context
  end

  step "the agent's turn ends without a report", context do
    end_turns(context)
  end

  step "the review of \#{int} is failed saying the agent gave no findings",
       %{args: [number]} = context do
    {review, context} = await_review(context, number, &(&1["status"] == "failed"))
    assert review["error"] =~ "without reporting its findings"
    context
  end

  step "the review of \#{int} failed", %{args: [number]} = context do
    context = context |> running(number) |> end_turns()
    await_review!(context, number, &(&1["status"] == "failed"))
  end

  step "the user retries the review of \#{int}", %{args: [number]} = context do
    {reply, context} = plugin(context, "retry", %{"key" => key(context, number)})
    assert {:ok, snapshot} = reply
    Map.put(context, :snapshot, snapshot)
  end

  step "a new review of \#{int} starts", %{args: [number]} = context do
    old = context.thread
    {review, context} = await_review(context, number, &(&1["threadId"] not in [nil, old]))
    World.await_row(review["threadId"], & &1)
    context
  end

  step "the review of \#{int} is still running in the same thread", %{args: [number]} = context do
    {reply, context} = plugin(context, "reviews", %{})
    assert {:ok, snapshot} = reply
    assert %{"status" => "running", "threadId" => thread} = review(snapshot, number)
    assert thread == context.thread
    context
  end

  step "the user discards the review of \#{int}", %{args: [number]} = context do
    {reply, context} = plugin(context, "discard", %{"key" => key(context, number)})
    Map.put(context, :reply, reply)
  end

  step "the user is told the review of \#{int} is running", context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ "is running"
    context
  end

  step "{string} is restarted", %{args: [@id]} = context do
    {_, context} = World.call!(context, "plugins.restart", %{"id" => @id})
    context
  end

  step "the review of \#{int} is failed saying the plugin stopped while it ran",
       %{args: [number]} = context do
    {review, context} = await_review(context, number, &(&1["status"] == "failed"))
    assert review["error"] =~ "code-review restarted"
    assert review["threadId"] == context.thread
    context
  end

  step "its agent can still report what it found", context do
    context
    |> report(findings("approve", 1))
    |> await_review!(
      context.review["number"],
      &(&1["status"] == "waiting" and &1["verdict"] == "approve")
    )
  end

  step "{string} reviews with an agent the MC does not have", %{args: [@id]} = context do
    save(context, %{"provider" => "nobody", "model" => ""})
  end

  step "the review of \#{int} is failed saying there is no such agent",
       %{args: [number]} = context do
    {review, context} = await_review(context, number, &(&1["status"] == "failed"))
    assert review["error"] =~ "There is no agent nobody"
    Map.put(context, :review, review)
  end

  step "no checkout of \#{int} is left", %{args: [number]} = context do
    checkouts =
      Path.join([
        HalC2.Plugins.Host.data_dir(@id),
        "checkouts",
        context.review["projectId"],
        "pr-#{number}"
      ])

    assert Path.wildcard(Path.join(checkouts, "*")) == []
    refute World.git!(context.root, ~w(worktree list)) =~ "pr-#{number}"
    context
  end

  step "the head of \#{int} adds the file {string}", %{args: [number, file]} = context do
    head =
      push_head(context, number, %{"src/limits.ts" => @limits, file => "export const x = 1;\n"})

    put_in(context, [:heads, number], head)
  end

  step "the agent reports a comment on line {int} of {string}", %{args: [line, file]} = context do
    report(context, %{
      "verdict" => "comment",
      "summary" => "One thing.",
      "comments" => [%{"path" => file, "line" => line, "body" => "Name it."}]
    })
  end

  step "the comment sits on line {int} of {string}", %{args: [line, file]} = context do
    {review, context} = await_review(context, 12, &(&1["status"] == "waiting"))

    assert [
             %{
               "path" => ^file,
               "line" => ^line,
               "position" => %{"kind" => "added", "newLine" => ^line}
             }
           ] =
             review["comments"]

    assert review["summary"] == "One thing."
    context
  end

  step "the agent reports a comment on a line that is not in the diff of \#{int}",
       %{args: [number]} = context do
    context
    |> running(number)
    |> report(%{
      "verdict" => "comment",
      "summary" => "Mostly fine.",
      "comments" => [%{"path" => "src/other.ts", "line" => 40, "body" => "Check the caller."}]
    })
  end

  step "the comment is kept in the review's summary instead of on the line", context do
    {review, context} = await_review(context, 12, &(&1["status"] == "waiting"))
    assert review["comments"] == []
    assert review["summary"] == "Mostly fine.\n\n`src/other.ts:40`: Check the caller."
    context
  end

  # --- publishing ------------------------------------------------------------------------------

  step "the publishing mode for {string} is {string}", %{args: [repo, mode]} = context do
    save(context, %{"publishingByRepository" => %{repo => mode}})
  end

  # The report waits for an automatic post, so a held one is reported from a process
  # of its own; the tool's answer is kept in `context.told`.
  step "the review of \#{int} finishes with two comments", %{args: [number]} = context do
    context = running(context, number)

    if context[:github_gate] do
      spawn(fn -> call_report(context, findings("comment", 2)) end)
      context
    else
      result = call_report(context, findings("comment", 2))
      assert result["isError"] != true, inspect(result)
      Map.put(context, :told, result)
    end
  end

  step "the agent is told GitHub's reason and not to post the review itself", context do
    told = inspect(context.told)
    assert told =~ "Can not approve your own pull request"
    assert told =~ "do not post it yourself"
    context
  end

  step "nothing can be posted to {string} and the review stays in HAL-C2", context do
    {review, context} = await_review(context, 12, &(&1["status"] == "kept"))
    assert %{"status" => "kept"} = review
    context = publish(context, 12)
    assert inspect(context.reply) =~ "kept in HAL-C2"
    assert World.cli_calls(context, "pulls/12/reviews") == []
    context
  end

  step "the review waits for the user to publish it", context do
    {review, context} = await_review(context, 12, &(&1["status"] == "waiting"))
    assert %{"status" => "waiting"} = review
    assert World.cli_calls(context, "pulls/12/reviews") == []
    context
  end

  step "the review is posted to \#{int} as a review with both line comments and the agent is told so",
       %{args: [number]} = context do
    context = await_review!(context, number, &(&1["status"] == "published"))
    assert [call] = World.cli_calls(context, "pulls/#{number}/reviews")
    assert %{"event" => "COMMENT", "comments" => [_, _]} = JSON.decode!(call["stdin"])
    assert inspect(context.told) =~ "The review is posted to the pull request."
    context
  end

  step "the review of \#{int} is waiting with {word} comments",
       %{args: [number, count]} = context do
    context = context |> running(number) |> report(findings("request-changes", @counts[count]))
    await_review!(context, number, &(&1["status"] == "waiting"))
  end

  step "the user dismisses one comment and publishes the review", context do
    key = key(context, 12)
    {reply, context} = plugin(context, "dismiss", %{"key" => key, "commentId" => "c1"})
    assert {:ok, _} = reply
    publish(context, 12)
  end

  step "\#{int} gets a review with the two remaining comments and the verdict",
       %{args: [number]} = context do
    assert {:ok, _} = context.reply
    assert [call] = World.cli_calls(context, "pulls/#{number}/reviews")
    review = JSON.decode!(call["stdin"])
    assert review["event"] == "REQUEST_CHANGES"
    assert Enum.map(review["comments"], & &1["body"]) == ["Finding 2.", "Finding 3."]
    context
  end

  step "the review of \#{int} is marked as published", %{args: [number]} = context do
    context = await_review!(context, number, &(&1["status"] == "published"))
    context
  end

  step "\#{int} gets a new push", %{args: [number]} = context do
    head =
      push_head(context, number, %{"src/limits.ts" => @limits <> "export const later = 1;\n"})

    Map.put(context, :pushed, head)
  end

  step "\#{int} gets a review of the commit that was reviewed", %{args: [number]} = context do
    {review, context} = await_review(context, number, &(&1["status"] == "published"))
    assert [call] = World.cli_calls(context, "pulls/#{number}/reviews")
    assert %{"commit_id" => sha} = JSON.decode!(call["stdin"])
    assert sha == review["reviewedSha"]
    refute sha == context.pushed
    context
  end

  step "\#{int} is the user's own pull request", %{args: [number]} = context do
    put_in(context, [:prs, number], Map.put(context.prs[number] || %{}, "viewerDidAuthor", true))
  end

  step "the user posts verdicts as comments", context do
    save(context, %{"verdictAsComment" => true})
  end

  step "the user publishes the review of \#{int} with the verdict {string}",
       %{args: [number, verdict]} = context do
    context = context |> running(number) |> report(findings(@verdicts[verdict], 1))
    context = await_review!(context, number, &(&1["status"] == "waiting"))
    publish(context, number)
  end

  step "\#{int} gets a commented review rather than a request for changes",
       %{args: [number]} = context do
    assert [call] = World.cli_calls(context, "pulls/#{number}/reviews")
    review = JSON.decode!(call["stdin"])
    assert review["event"] == "COMMENT"
    assert String.starts_with?(review["body"], "**Changes requested**")
    context
  end

  step "the review of \#{int} is waiting to be published", %{args: [number]} = context do
    context = context |> running(number) |> report(findings("approve", 2))
    await_review!(context, number, &(&1["status"] == "waiting"))
  end

  step "GitHub refuses the review", context do
    World.cli_rules(context, [
      %{
        "args" => ["--method POST", "pulls/12/reviews"],
        "stderr" =>
          "gh: Unprocessable Entity\nCan not approve your own pull request (HTTP 422)\n",
        "stdout" =>
          ~s({"message":"Unprocessable Entity","errors":["Can not approve your own pull request"]}),
        "exit" => 1
      }
    ])
  end

  step "the user publishes the review of \#{int}", %{args: [number]} = context do
    publish(context, number)
  end

  step "the user is told GitHub's reason", context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ "Can not approve your own pull request"
    context
  end

  step "the review of \#{int} is still waiting with its comments", %{args: [number]} = context do
    {review, context} = await_review(context, number, & &1["publishError"])
    assert %{"status" => "waiting", "comments" => [_, _]} = review
    assert review["publishError"] =~ "Can not approve your own pull request"
    context
  end

  # Holds every review posted to #12 until `take_reviews/1`, or the scenario ends.
  step "GitHub is slow to take reviews", context do
    gate = Path.join(context.mc.home, "github-gate")
    on_exit_gate(gate)

    context
    |> World.cli_rules([
      %{
        "args" => ["--method POST", "pulls/12/reviews"],
        "run" =>
          "echo $PPID > '#{gate}.pid'; while [ ! -e '#{gate}' ] && [ -d '#{context.mc.home}' ]; do sleep 0.05; done",
        "stdout" => "{}"
      }
    ])
    |> Map.put(:github_gate, gate)
  end

  step "the user publishes the review of \#{int} while it is being posted",
       %{args: [number]} = context do
    context = await_review!(context, number, &(&1["status"] == "publishing"))
    publish(context, number)
  end

  step "the user is told the review is already being posted", context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ "is being published"
    context
  end

  step "once GitHub has it, \#{int} has one review and it is marked as published",
       %{args: [number]} = context do
    context = context |> take_reviews() |> await_review!(number, &(&1["status"] == "published"))
    assert [_] = World.cli_calls(context, "pulls/#{number}/reviews")
    context
  end

  step "the user retries the review of \#{int} while it is being posted",
       %{args: [number]} = context do
    {review, context} = await_review(context, number, &(&1["status"] == "publishing"))
    {reply, context} = plugin(context, "retry", %{"key" => key(context, number)})
    assert {:ok, _} = reply
    Map.put(context, :earlier_run, review["threadId"])
  end

  # The post is still held, so its answer is delivered as the plugin's publisher
  # would deliver it; when it lands is then the scenario's to say.
  step "the post of the earlier run comes back", context do
    :ok =
      GenServer.call(
        HalC2Plugins.CodeReview,
        {:published, key(context, 12), context.earlier_run, nil}
      )

    context
  end

  step "the new review of \#{int} is not marked as published", %{args: [number]} = context do
    review = review(GenServer.call(HalC2Plugins.CodeReview, :snapshot), number)
    assert review["status"] in ~w(queued running)
    assert review["threadId"] != context.earlier_run
    take_reviews(context)
  end

  # The user's post waits for GitHub's answer, so it is sent from a process of its own.
  step "the user starts publishing the review of \#{int}", %{args: [number]} = context do
    input = %{"id" => @id, "method" => "publish", "input" => %{"key" => key(context, number)}}
    spawn(fn -> HalC2.Plugins.handle("call", input) end)
    context
  end

  step "{string} is turned off while the review of \#{int} is being posted",
       %{args: [@id, number]} = context do
    context = await_review!(context, number, &(&1["status"] == "publishing"))
    # The post is under way once GitHub holds it.
    pid = context.github_gate <> ".pid"

    assert {_, 0} =
             System.cmd("timeout", ["5", "sh", "-c", "until [ -s '#{pid}' ]; do sleep 0.05; done"])

    {_, context} = World.call!(context, "plugins.disable", %{"id" => @id})
    context
  end

  step "the post to GitHub is called off", context do
    pid = context.github_gate |> Kernel.<>(".pid") |> File.read!() |> String.trim()
    # `tail --pid` returns once the process is gone.
    assert {_, 0} =
             System.cmd("timeout", ["5", "tail", "--pid=#{pid}", "-s", "0.05", "-f", "/dev/null"])

    take_reviews(context)
  end

  step "once {string} is turned back on, the review of \#{int} is waiting to be published",
       %{args: [@id, number]} = context do
    accepted = Enum.map(Fixtures.entry(@id)["permissions"], & &1["id"])

    {_, context} =
      World.call!(context, "plugins.enable", %{"id" => @id, "acceptPermissions" => accepted})

    review = review(GenServer.call(HalC2Plugins.CodeReview, :snapshot), number)
    assert %{"status" => "waiting", "comments" => [_, _]} = review
    context
  end

  # --- where reviews show up -------------------------------------------------------------------

  step "{string} shows reviews as {string}", %{args: [@id, display]} = context do
    save(context, %{"display" => display})
  end

  step "its thread is not listed with the threads", context do
    assert %{"id" => @id, "kind" => "review", "listed" => false} =
             thread(context.thread)["plugin"]

    context
  end

  step "its thread is listed with the threads", context do
    assert %{"id" => @id, "kind" => "review", "listed" => true} = thread(context.thread)["plugin"]
    context
  end

  # --- the host --------------------------------------------------------------------------------

  step "the clients of its thread see a review of \#{int} waiting with the verdict {string}",
       %{args: [number, verdict]} = context do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "threads"
    }

    thread = context.thread
    wanted = @verdicts[verdict]

    {_, client} =
      context
      |> World.client("threads")
      |> Mc.sub(sub, shape)
      |> Mc.await(
        &(&1["t"] == "plugin" and &1["id"] == sub and
            match?(
              %{^thread => %{"number" => ^number, "status" => "waiting", "verdict" => ^wanted}},
              &1["value"]
            )),
        10_000
      )

    World.put_client(context, "threads", client)
  end

  step "gh is not signed in on the MC's machine", context do
    signed_out = %{
      "stderr" => "To get started with GitHub CLI, please run:  gh auth login\n",
      "exit" => 1
    }

    World.cli_rules(context, [
      Map.put(signed_out, "args", ["api user"]),
      Map.put(signed_out, "args", ["pr list"])
    ])
  end

  step "{string} reports that gh needs to sign in", %{args: [@id]} = context do
    assert context.snapshot["problem"] =~ "gh auth login", inspect(context.snapshot)
    context
  end

  # --- helpers ---------------------------------------------------------------------------------

  # Saves `patch` over the plugin's settings, which restarts it.
  defp save(context, patch) do
    {_, context} =
      World.call!(context, "plugins.saveSettings", %{"id" => @id, "settings" => patch})

    context
  end

  defp plugin(context, method, input) do
    World.call(context, "plugins.call", %{"id" => @id, "method" => method, "input" => input})
  end

  # Watches the plugin's `reviews` topic on a client of its own.
  defp watch(context) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "reviews"
    }

    client = context |> World.client("reviews") |> Mc.sub(sub, shape)

    context
    |> World.put_client("reviews", client)
    |> Map.merge(%{reviews_sub: sub, reviews_last: nil})
  end

  # `{review, context}` once `fun` holds for the review of `number` on the `reviews`
  # topic; the last value seen is kept, as the topic only moves forward.
  defp await_review(context, number, fun) do
    found = fn value ->
      with %{} <- value,
           %{} = review <- review(value, number),
           true <- !!fun.(review),
           do: review,
           else: (_ -> nil)
    end

    if review = found.(context.reviews_last) do
      {review, context}
    else
      sub = context.reviews_sub

      {frame, client} =
        Mc.await(
          World.client(context, "reviews"),
          &(&1["t"] == "plugin" and &1["id"] == sub and found.(&1["value"])),
          10_000
        )

      context =
        context |> World.put_client("reviews", client) |> Map.put(:reviews_last, frame["value"])

      {found.(frame["value"]), context}
    end
  end

  # Asserts the review of `number` comes to `fun`; returns the context.
  defp await_review!(context, number, fun), do: context |> await_review(number, fun) |> elem(1)

  defp review(snapshot, number), do: Enum.find(snapshot["reviews"], &(&1["number"] == number))

  defp key(context, number), do: "#{context.repository}##{number}"

  # Lists pull request `number` (opened with a head commit if it is new) with `fields`
  # over what it had.
  defp open(context, number, fields \\ %{}) do
    context =
      if context.heads[number],
        do: context,
        else:
          put_in(
            context,
            [:heads, number],
            push_head(context, number, %{"src/limits.ts" => @limits})
          )

    pr =
      Shared.gh_pr(context.repository, number, %{
        "headRefOid" => context.heads[number],
        "additions" => 5,
        "deletions" => 0
      })
      |> Map.merge(context.prs[number] || %{})
      |> Map.merge(fields)
      |> Map.put("headRefOid", fields["headRefOid"] || context.heads[number])

    prs = Map.put(context.prs, number, pr)

    listed =
      if context[:unlisted],
        do: %{"args" => ["pr list"], "stderr" => "HTTP 502: Bad Gateway\n", "exit" => 1},
        else: %{
          "args" => ["pr list"],
          "stdout" => prs |> Map.values() |> Enum.sort_by(& &1["number"])
        }

    context
    |> World.cli_rules([listed, detail_rule(pr)])
    |> Map.put(:prs, prs)
  end

  # GitHub's answer when pull request `pr` (as `gh pr list` gives it) is read on its own.
  defp detail_rule(pr) do
    graphql =
      Map.merge(pr, %{
        "body" => "",
        "changedFiles" => 1,
        "isCrossRepository" => false,
        "baseRef" => %{"compare" => %{"behindBy" => 0}},
        "labels" => %{"nodes" => pr["labels"]},
        "reviewRequests" => %{
          "nodes" => Enum.map(pr["reviewRequests"], &%{"requestedReviewer" => &1})
        },
        "commits" => Shared.pr_commits([])
      })

    %{
      "args" => ["api graphql"],
      "stdin" => ["viewerCanUpdateBranch", "refs/pull/#{pr["number"]}/head"],
      "stdout" => %{
        "data" => %{"repository" => %{"viewerPermission" => "WRITE", "pullRequest" => graphql}}
      }
    }
  end

  # A commit off main with `files` at `refs/pull/<number>/head` of the fake GitHub.
  defp push_head(context, number, files) do
    source = context.source
    World.git!(source, ~w(fetch -q origin))
    World.git!(source, ~w(checkout -q --detach origin/main))
    head = World.commit!(source, files, "Pull request #{number}")
    World.git!(source, ["push", "-q", "--force", "origin", "HEAD:refs/pull/#{number}/head"])
    head
  end

  defp refresh(context) do
    {reply, context} = plugin(context, "refresh", %{})
    assert {:ok, snapshot} = reply
    Map.put(context, :snapshot, snapshot)
  end

  defp start(context, number) do
    {reply, context} =
      plugin(context, "start", %{"repository" => context.repository, "number" => number})

    assert {:ok, snapshot} = reply
    Map.put(context, :snapshot, snapshot)
  end

  # The review of `number` has a thread; puts it in `context.thread`, the review in
  # `context.review`.
  defp started(context, number) do
    {review, context} = await_review(context, number, &(&1["threadId"] && &1["checkout"]))
    World.await_row(review["threadId"], & &1)
    Map.merge(context, %{thread: review["threadId"], review: review})
  end

  # The review of `number` running, its thread working on the change.
  defp running(context, number) do
    context = context |> open(number) |> start(number) |> started(number)
    assert context.review["status"] == "running"
    context
  end

  # The review of `number`, watched automatically, finished at its head and waiting
  # to be published; its thread is `context.thread`.
  defp reviewed(context, number) do
    context
    |> save(%{"repositories" => [context.repository], "activation" => "automatic"})
    |> open(number)
    |> refresh()
    |> started(number)
    |> report(findings("approve", 1))
    |> await_review!(number, &(&1["status"] == "waiting"))
  end

  # The agent of the review's thread calls the report tool with `arguments`.
  defp report(context, arguments) do
    result = call_report(context, arguments)
    assert result["isError"] != true, inspect(result)
    context
  end

  # The tool result the report tool gives for `arguments`.
  defp call_report(context, arguments) do
    %{authorization: auth} = HalC2.Mcp.server(context.thread, "codex")

    {200, %{"result" => result}} =
      HalC2.Mcp.handle(
        auth,
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "code_review_report", "arguments" => arguments}
        })
      )

    result
  end

  defp findings(verdict, count) do
    %{
      "verdict" => verdict,
      "summary" => "Found #{count}.",
      "comments" =>
        for i <- 1..count//1 do
          %{"path" => "src/limits.ts", "line" => i, "body" => "Finding #{i}."}
        end
    }
  end

  defp publish(context, number) do
    {reply, context} = plugin(context, "publish", %{"key" => key(context, number)})
    Map.put(context, :reply, reply)
  end

  defp take_reviews(context) do
    File.write!(context.github_gate, "")
    context
  end

  defp on_exit_gate(gate), do: ExUnit.Callbacks.on_exit(fn -> File.write(gate, "") end)

  # Lets the fake Codex finish every turn held at the gate.
  defp end_turns(context) do
    gate = Path.join(context.mc.home, "gate")
    File.mkdir_p!(gate)
    File.write!(Path.join(gate, "answer"), "I looked at it.")
    context
  end

  defp prompt(thread_id) do
    World.await_stream(thread_id, fn state ->
      state
      |> HalC2.StreamState.list("message")
      |> Enum.find_value(&(&1["role"] == "user" and &1["text"]))
    end)
  end

  defp checkout_state(root) do
    {World.git!(root, ~w(rev-parse HEAD)), World.git!(root, ~w(branch --list)),
     World.git!(root, ~w(status --porcelain))}
  end

  defp thread(thread_id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
    HalC2.StreamState.get(state, "thread")[thread_id]
  end
end
