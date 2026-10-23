defmodule HalC2.Steps.SourceControl.Errors do
  @moduledoc "Steps for `features/source-control/errors.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

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

  step "GitHub refuses the push because the sign-in lacks the workflow scope", context do
    hook = Path.join([context.bare, "hooks", "pre-receive"])

    File.write!(hook, """
    #!/bin/sh
    echo 'refusing to allow an OAuth App to create or update workflow `.github/workflows/ci.yml` without `workflow` scope' >&2
    exit 1
    """)

    File.chmod!(hook, 0o755)
    File.write!(Path.join(context.cwd, "cart.ts"), "export const cart = []\n")
    context
  end

  step "GitHub refuses the push because the token lacks the workflows permission", context do
    hook = Path.join([context.bare, "hooks", "pre-receive"])

    File.write!(hook, """
    #!/bin/sh
    echo 'refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission' >&2
    exit 1
    """)

    File.chmod!(hook, 0o755)
    File.write!(Path.join(context.cwd, "cart.ts"), "export const cart = []\n")
    context
  end

  # The Background's origin is GitHub's `acme/<project>` already.
  step "the repository's remote is the GitHub one {string}", %{args: [repository]} = context do
    assert context.repository == repository
    context
  end

  step "the repository's remote is not on GitHub", context do
    World.git!(context.cwd, ["remote", "set-url", "origin", context.bare])
    context
  end

  step "the failure says the push changes a workflow file and the sign-in lacks the workflow scope",
       context do
    assert World.failure(context) =~
             "GitHub refused it because it changes a workflow file and the sign-in that " <>
               "pushed lacks the workflow scope."

    context
  end

  step "the failure says the GitHub App that pushed lacks the Workflows permission", context do
    failure = World.failure(context)
    assert failure =~ "the GitHub App whose token pushed lacks the Workflows permission"
    assert failure =~ "Grant the App read and write access to Workflows"
    refute failure =~ "gh auth refresh"
    context
  end

  step "the failure tells a user pushing with the GitHub CLI's sign-in to run {string}",
       %{args: [command]} = context do
    assert World.failure(context) =~
             "If this machine pushes with the GitHub CLI's sign-in, run `#{command}`"

    context
  end

  step "the failure offers {string} to copy {string}", %{args: [label, command]} = context do
    assert %{"kind" => "copy_command", "label" => ^label, "command" => ^command} =
             failure_cta(context)

    context
  end

  step "the failure offers {string} to open {string}", %{args: [label, url]} = context do
    assert %{"kind" => "open_url", "label" => ^label, "url" => ^url} = failure_cta(context)
    context
  end

  step "the failure offers nothing to do", context do
    World.failure(context)
    assert failure_cta(context) == nil
    context
  end

  defp failure_cta(context), do: List.last(context.git_events)["cta"]

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

  # A stand-in for git (`:git_command`) that misbehaves the way the row names, with
  # limits small enough to reach at once (`:vcs_status_limits`).
  step ~r/^a git command (?<condition>runs past its time limit|prints more than the limit|cannot be started)$/,
       %{args: [condition]} = context do
    dir = HalC2.Test.Mc.tmp_dir(context.mc, "runaway-git")
    script = Path.join(dir, "git")

    {command, limits} =
      case condition do
        "runs past its time limit" ->
          File.write!(script, "#!/bin/sh\nexec sleep 60\n")
          {script, timeout: 200}

        "prints more than the limit" ->
          File.write!(script, "#!/bin/sh\nhead -c 200000 /dev/zero | tr '\\0' 'x'\n")
          {script, max_bytes: 100_000}

        "cannot be started" ->
          {Path.join(dir, "no-such-git"), []}
      end

    if File.exists?(script), do: File.chmod!(script, 0o755)
    World.put_app_env(:git_command, command)
    World.put_app_env(:vcs_status_limits, limits)
    context
  end

  step ~r/^the user is told the command (?<result>timed out|produced too much output|could not be started)$/,
       %{args: [result]} = context do
    assert {:error, message, detail} = context.reply
    root = World.project(context, "shop").root
    assert detail["_tag"] == "GitCommandError"
    assert detail["command"] == "git"
    assert detail["cwd"] == root
    assert detail["detail"] =~ result
    assert message =~ result
    context
  end

  step "the user is told the repository could not be found on GitHub", context do
    assert {:error, message, detail} = context.reply
    assert detail["provider"] == "github"
    assert message =~ "Could not resolve to a Repository"
    context
  end
end
