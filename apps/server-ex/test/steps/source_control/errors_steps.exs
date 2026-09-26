defmodule HalC2.Steps.SourceControl.Errors do
  @moduledoc "Steps for `features/source-control/errors.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node.World

  step "the thread's folder is not a git repository", context do
    File.rm_rf!(Path.join(context.cwd, ".git"))
    context
  end

  step "the repository has no remote", context do
    World.git!(context.cwd, ~w(remote remove origin))
    context
  end

  step "the working tree has uncommitted changes", context do
    File.write!(Path.join(context.cwd, "notes.txt"), "draft\n")
    context
  end

  step "no pull request is opened", context do
    assert World.cli_calls(context, "pr create") == []
    context
  end

  step "GitHub refuses to open the pull request", context do
    World.cli_rules(context, [
      %{
        "args" => ["pr create"],
        "stderr" =>
          "pull request create failed: GraphQL: Base branch is protected (createPullRequest)\n",
        "exit" => 1
      }
    ])
  end

  step "the action fails saying the pull request could not be created, with GitHub's reason",
       context do
    message = World.failure(context)
    assert message =~ "pr create failed"
    assert message =~ "Base branch is protected"
    context
  end

  # There is a change to commit, and the remote turns every push away.
  step "the push will be rejected by the remote", context do
    hook = Path.join([context.bare, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\necho 'pushes are frozen' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)
    File.write!(Path.join(context.cwd, "cart.ts"), "export const cart = []\n")
    Map.put(context, :head_before, World.git!(context.cwd, ~w(rev-parse HEAD)))
  end

  step "the commit is kept and the status shows the branch ahead of its upstream", context do
    refute World.git!(context.cwd, ~w(rev-parse HEAD)) == context.head_before
    {status, context} = World.call!(context, "vcs.refreshStatus", %{"cwd" => context.cwd})
    assert status["hasUpstream"]
    assert status["aheadCount"] == 1
    refute status["hasWorkingTreeChanges"]
    context
  end

  step "the failure is reported with the push step that failed", context do
    failed = List.last(context.git_events)
    assert failed["kind"] == "action_failed"
    assert failed["phase"] == "push"
    assert failed["message"] =~ "push"
    context
  end

  # A `.git` file pointing nowhere makes `git init` exit non-zero.
  step "git exits with an error while initializing {string}", %{args: [title]} = context do
    root = World.project(context, title).root
    File.rm_rf!(Path.join(root, ".git"))
    File.write!(Path.join(root, ".git"), "gitdir: /nonexistent\n")
    context
  end

  step "the error names the git command, the folder and the exit code", context do
    assert {:error, message, detail} = context.reply
    root = World.project(context, "shop").root
    assert message =~ root
    assert detail["command"] == "git init"
    assert detail["cwd"] == root
    assert is_integer(detail["exitCode"]) and detail["exitCode"] != 0
    context
  end

  step "the user is told the repository could not be found on GitHub", context do
    assert {:error, message, detail} = context.reply
    assert detail["provider"] == "github"
    assert message =~ "Could not resolve to a Repository"
    context
  end
end
