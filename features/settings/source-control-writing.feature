# Sources:
#   docs/user/source-control.md (writing style, Repository conventions)
#   apps/web/src/components/settings/SourceControlWritingSettings.tsx
#   apps/server-ex/lib/hal_c2/settings.ex (sourceControlWritingStyle, sourceControlWriterModelSelection, project overrides)
#   apps/server-ex/lib/hal_c2/text_generation.ex (model_selection)
#   apps/server-ex/lib/hal_c2/text_generation/style.ex

Feature: Source control writing settings
  The Text generation part of Source Control settings chooses how commit messages, pull
  request text and branch names are written, and which model writes them. The writing
  itself lives in source-control/commit-and-generated-messages.feature.

  Background:
    Given the user is connected to an environment and opens Settings, Source Control

  @desktop @mobile @backlog-mobile
  Scenario Outline: Choosing a writing style
    When the user picks the writing style "<style>"
    Then the panel explains "<explanation>"
    And generated commits and pull requests follow that style

    Examples:
      | style                  | explanation                                                                         |
      | Repository conventions | In each project, matches recent change descriptions and change request titles.     |
      | Conventional Commits   | Use Conventional Commit prefixes and keep change request text concise.             |
      | Custom instructions    | Use your instructions for change descriptions and change requests in every project. |

  @desktop @mobile @backlog-mobile
  Scenario: Writing custom instructions
    Given the writing style is Custom instructions
    When the user writes "Keep titles under 50 characters." as the instructions
    Then generated commits and pull requests follow those instructions

  @desktop @mobile @backlog-mobile
  Scenario: Custom instructions for several environments at once
    Given the settings scope covers two environments
    When the user writes custom instructions
    Then both environments use those instructions

  # Writing to the template is the node's (node/orchestration/text-generation.feature).
  @desktop @mobile @backlog-mobile
  Scenario: Pull request templates are followed until turned off
    Then following change request templates is shown on
    And the environment's settings leave templates followed

  @desktop @mobile @backlog-mobile
  Scenario: Ignoring the repository's pull request template
    When the user turns off following change request templates
    Then pull request descriptions are written without the repository's template

  @desktop @mobile @backlog-mobile
  Scenario: Choosing a separate writer model
    When the user turns on a separate source control writer model and picks one
    Then commits, pull requests and branch names are written by that model

  @desktop @mobile @backlog-mobile
  Scenario: Going back to the text generation model
    Given a separate source control writer model is on
    When the user turns it off
    Then the environment's text generation model writes source control text again

  @desktop @mobile @backlog-mobile
  Scenario: A writer model that cannot be used is explained
    Given the provider of a model is turned off
    When the user looks at the writer model choices
    Then that model cannot be picked and the reason is shown

  @desktop @mobile @backlog-mobile
  Scenario: A writer model that could not be saved
    Given saving settings fails
    When the user picks a writer model
    Then the user is told "Source control writer model not saved"

  @node
  Scenario: A project's own writing style wins over the environment's
    Given the environment's writing style is Conventional Commits
    And the project "shop" overrides it with Repository conventions
    When a commit message is generated in "shop"
    Then it follows the repository's conventions

  @node
  Scenario: An unusable writer model falls back to the text generation model
    Given the separate writer model's provider is not installed
    When a commit message is generated
    Then the text generation model writes it
