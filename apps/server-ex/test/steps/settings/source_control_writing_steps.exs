defmodule HalC2.Steps.Settings.SourceControlWriting do
  @moduledoc """
  Who writes commit messages and in what style: a commit action
  (`HalC2.GitActions.run/2`) in a project whose text generation CLIs are the
  `fake_text_cli.py` fake, observed through the prompts and argv it logged.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  step "the environment's writing style is Conventional Commits", context do
    context
    |> World.fake_text_clis([:claude, :codex])
    |> World.update_settings(%{
      "sourceControlWritingStyle" => %{"mode" => "conventional_commits"}
    })
  end

  step "the project {string} overrides it with Repository conventions",
       %{args: [project]} = context do
    context = World.create_project(context, project)

    World.update_settings(context, %{
      "projectSettingsOverrides" => %{
        World.project(context, project).id => %{
          "sourceControlWritingStyle" => %{"mode" => "repo_conventions"}
        }
      }
    })
  end

  step "the separate writer model's provider is not installed", context do
    context
    |> World.fake_text_clis([:codex])
    |> World.update_settings(%{
      "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-text"},
      "sourceControlWriterModelSelection" => %{
        "instanceId" => "claudeAgent",
        "model" => "claude-writer"
      }
    })
  end

  step "a commit message is generated in {string}", %{args: [project]} = context do
    commit(context, project)
  end

  # mc/orchestration/text-generation.feature, whose writers are already set up
  # (`context.text_log`), asks for the message itself as a commit does.
  step "a commit message is generated", context do
    case context do
      %{text_log: _} ->
        cwd = World.project(context).root
        policy = HalC2.TextGeneration.Style.policy(cwd)

        result =
          HalC2.TextGeneration.commit_message(cwd, "main", "M README.md", "diff", false,
            policy: policy
          )

        Map.put(context, :reply, World.normalize_reply(result))

      _ ->
        context =
          if context.projects == %{}, do: World.create_project(context, "shop"), else: context

        commit(context, nil)
    end
  end

  step "it follows the repository's conventions", context do
    assert [%{"prompt" => prompt}] = World.text_calls(context)
    assert prompt =~ "Follow the repository's established commit message style"
    assert prompt =~ "Recent commit subjects from this repository:\ninit"
    refute prompt =~ "Use Conventional Commits"
    context
  end

  step "the text generation model writes it", context do
    assert [%{"argv" => ["exec" | _] = argv}] = World.text_calls(context)
    assert Enum.at(argv, Enum.find_index(argv, &(&1 == "--model")) + 1) == "gpt-text"
    assert {:ok, %{"commit" => %{"subject" => "codex subject"}}} = context.commit
    context
  end

  # Commits a change in the project the way the commit button does.
  defp commit(context, project) do
    root = World.project(context, project).root
    File.write!(Path.join(root, "checkout.ex"), "defmodule Checkout, do: nil\n")

    result = HalC2.GitActions.run(%{"cwd" => root, "action" => "commit"}, fn _ -> :ok end)
    assert {:ok, _} = result
    Map.put(context, :commit, result)
  end
end
