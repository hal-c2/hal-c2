defmodule HalC2.Steps.SourceControl.CommitAndGeneratedMessages do
  @moduledoc "Steps for `features/source-control/commit-and-generated-messages.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc.World

  @styles %{
    "Repository conventions" => %{"mode" => "repo_conventions"},
    "Conventional Commits" => %{"mode" => "conventional_commits"},
    "Custom instructions" => %{
      "mode" => "custom",
      "customInstructions" => "Write every subject in Icelandic."
    }
  }

  @instructions %{
    "follow the repository's recent commit subjects and AGENTS.md" => [
      "Follow the repository's established commit message style",
      "Recent commit subjects from this repository:",
      "Local AGENTS.md:"
    ],
    "use Conventional Commits with the narrowest accurate type" => [
      "Use Conventional Commits",
      "Prefer the narrowest accurate type"
    ],
    "follow the user's own instructions" => ["Write every subject in Icelandic."],
    "follow the repository's pull request style, recent subjects and AGENTS.md" => [
      "Follow the repository's established change request title and body style",
      "Recent commit subjects from this repository:",
      "Local AGENTS.md:"
    ],
    "keep the title concise without forcing Conventional Commit syntax" => [
      "Keep the change request title concise.",
      "Do not force Conventional Commit syntax"
    ]
  }

  defp commit(context, input) do
    {events, context} = World.git_action(context, context.cwd, input["action"] || "commit", input)
    Map.put(context, :git_events, events)
  end

  defp result(context) do
    last = List.last(context.git_events)
    assert last["kind"] == "action_finished", "the action failed: #{inspect(last)}"
    last["result"]
  end

  defp head_files(cwd),
    do: cwd |> World.git!(~w(show --name-only --format= HEAD)) |> String.split("\n", trim: true)

  defp subject(cwd, ref \\ "HEAD"), do: World.git!(cwd, ["log", "-1", "--format=%s", ref])

  step "the user has changed {string} and {string}", %{args: [first, second]} = context do
    for path <- [first, second] do
      File.mkdir_p!(Path.dirname(Path.join(context.cwd, path)))

      File.write!(
        Path.join(context.cwd, path),
        "export const #{Path.rootname(Path.basename(path))} = 1\n"
      )
    end

    Map.merge(context, %{
      changed: [first, second],
      head_before: World.git!(context.cwd, ~w(rev-parse HEAD))
    })
  end

  step "the user commits with the message {string}", %{args: [message]} = context do
    commit(context, %{"commitMessage" => message})
  end

  step "a commit {string} holds both files", %{args: [message]} = context do
    assert subject(context.cwd) == message
    assert Enum.sort(head_files(context.cwd)) == Enum.sort(context.changed)
    context
  end

  step "the user is told the commit was made with its short hash", context do
    sha = World.git!(context.cwd, ~w(rev-parse --short=7 HEAD))
    assert result(context)["toast"]["title"] == "Committed #{sha}"
    context
  end

  step "the user commits without writing a message", context do
    commit(context, %{})
  end

  step "the user commits", context do
    commit(context, %{"commitMessage" => "Add tax to the cart"})
  end

  step "the writer model writes the commit message from the staged diff", context do
    assert [prompt | _] = Shared.writer_prompts(context)
    for path <- context.changed, do: assert(prompt =~ path)
    assert prompt =~ "export const cart = 1"
    context
  end

  step "the commit is made with that message", context do
    # The fake writer answers each field it is asked for with "claude <field>".
    assert subject(context.cwd) == "claude subject"
    assert result(context)["commit"]["subject"] == "claude subject"
    context
  end

  step "the user leaves {string} out of the commit and commits", %{args: [left_out]} = context do
    commit(context, %{
      "commitMessage" => "Add the cart",
      "filePaths" => context.changed -- [left_out]
    })
  end

  step "the commit holds only {string}", %{args: [path]} = context do
    result(context)
    assert head_files(context.cwd) == [path]
    context
  end

  step "{string} is still changed in the working tree", %{args: [path]} = context do
    assert World.git!(context.cwd, ~w(status --porcelain)) =~ path
    context
  end

  step "the checkout is on the default branch {string}", %{args: [branch]} = context do
    assert World.git!(context.cwd, ~w(branch --show-current)) == branch
    context
  end

  step "the user commits on a new branch with the message {string}",
       %{args: [message]} = context do
    commit(context, %{"commitMessage" => message, "featureBranch" => true})
  end

  step "a branch named after the message under {string} is created and checked out",
       %{args: ["feature/"]} = context do
    branch = result(context)["branch"]
    assert branch["status"] == "created"
    assert branch["name"] == "feature/add-tax-to-the-cart"
    assert World.git!(context.cwd, ~w(branch --show-current)) == branch["name"]
    Map.put(context, :new_branch, branch["name"])
  end

  step "the commit is made on that branch", context do
    assert subject(context.cwd, context.new_branch) == "Add tax to the cart"
    refute subject(context.cwd, "main") == "Add tax to the cart"
    context
  end

  step "a branch {string} already exists", %{args: [branch]} = context do
    World.git!(context.cwd, ["branch", branch])
    context
  end

  step "the new branch is {string}", %{args: [branch]} = context do
    assert result(context)["branch"]["name"] == branch
    assert World.git!(context.cwd, ~w(branch --show-current)) == branch
    context
  end

  step "the working tree is clean", context do
    World.git!(context.cwd, ~w(clean -fdq))
    assert World.git!(context.cwd, ~w(status --porcelain)) == ""
    context
  end

  step "the user asks to commit on a new branch", context do
    commit(context, %{"featureBranch" => true})
  end

  step "the user asks to push on a new branch", context do
    commit(context, %{"action" => "push", "featureBranch" => true})
  end

  step ~r/^the project's source control writing style is (?<style>.+)$/,
       %{args: [style]} = context do
    # The repository has conventions to follow: recent subjects and an AGENTS.md.
    World.commit!(
      context.cwd,
      %{"AGENTS.md" => "Keep commit subjects short.\n"},
      "Add agent notes"
    )

    id = World.project(context, "shop").id

    World.put_settings(context, %{
      "projectSettingsOverrides" => %{id => %{"sourceControlWritingStyle" => @styles[style]}}
    })
  end

  step ~r/^the writer model is told to (?<instruction>.+?)( for the pull request title and description)?$/,
       %{args: [instruction | pr]} = context do
    wanted = @instructions[instruction] || flunk("no instruction #{inspect(instruction)}")
    prompts = Shared.writer_prompts(context)

    prompt =
      if pr in [[], [""], [nil]],
        do: Enum.find(prompts, &(&1 =~ "git commit messages")),
        else: Enum.find(prompts, &(&1 =~ "change request content"))

    assert prompt, "no matching prompt among #{inspect(prompts)}; #{inspect(context.git_events)}"
    for text <- wanted, do: assert(prompt =~ text)
    context
  end

  step "the writing style is Repository conventions and the writer model is a Claude model",
       context do
    World.commit!(
      context.cwd,
      %{"CLAUDE.md" => "Mention the ticket number.\n"},
      "Add Claude notes"
    )

    World.put_settings(context, %{"sourceControlWritingStyle" => %{"mode" => "repo_conventions"}})

    assert HalC2.TextGeneration.driver(HalC2.TextGeneration.model_selection(context.cwd, :writer)) ==
             "claudeAgent"

    context
  end

  step "the writer model also sees the repository's CLAUDE.md", context do
    assert [prompt | _] = Shared.writer_prompts(context)
    assert prompt =~ "Local CLAUDE.md:\nMention the ticket number."
    context
  end

  step "the user commits, pushes and opens a pull request without writing its text", context do
    commit(context, %{"action" => "commit_push_pr"})
  end

  step "nothing is committed", context do
    assert World.git!(context.cwd, ~w(rev-parse HEAD)) == context.head_before
    context
  end

  # A git's trace record, from a session that is not the commit's.
  @trace_shaped ~s({"event":"child_exit","sid":"hook-printed","child_id":0,"code":9})

  step "the repository has a pre-commit hook that prints {string}", %{args: [text]} = context do
    hook(context, "echo '#{text}'")
  end

  step "the repository has a pre-commit hook that prints {string} without a newline and exits with {int}",
       %{args: [text, code]} = context do
    hook(context, "printf '%s' '#{text}' >&2\nexit #{code}")
  end

  step "the repository has a pre-commit hook that prints a line shaped like a git trace record",
       context do
    hook(context, "echo '#{@trace_shaped}'")
  end

  step "the action reports the hook starting, that line as its output and the hook finishing",
       context do
    result(context)
    hook_events(context, @trace_shaped, 0)
    context
  end

  step "the repository has a pre-commit hook that prints {string} and what {string} prints",
       %{args: [text, command]} = context do
    hook(context, ~s[echo "#{text}$(#{command})"])
  end

  step "the action reports the hook starting, its output {string} and the hook finishing",
       %{args: [text]} = context do
    result(context)
    hook_events(context, text, 0)
    context
  end

  step "the hook's output {string} is reported before it finishes with exit code {int}",
       %{args: [text, code]} = context do
    hook_events(context, text, code)
    context
  end

  defp hook(context, script) do
    hook = Path.join([context.cwd, ".git", "hooks", "pre-commit"])
    File.write!(hook, "#!/bin/sh\n#{script}\n")
    File.chmod!(hook, 0o755)
    context
  end

  # The hook's start, its output line `text` and its finish with exit `code`, in order.
  defp hook_events(context, text, code) do
    events = context.git_events
    started = Enum.find_index(events, &(&1["kind"] == "hook_started"))
    output = Enum.find_index(events, &(&1["kind"] == "hook_output" and &1["text"] == text))
    finished = Enum.find_index(events, &(&1["kind"] == "hook_finished"))
    assert started && output && finished, "hook events missing: #{inspect(events)}"
    assert started < output and output < finished, "out of order: #{inspect(events)}"

    for at <- [started, output, finished],
        do: assert(Enum.at(events, at)["hookName"] == "pre-commit")

    assert Enum.at(events, finished)["exitCode"] == code
  end
end
