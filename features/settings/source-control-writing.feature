# Sources:
#   docs/user/source-control.md (writing style, Repository conventions)
#   apps/web/src/components/settings/SourceControlWritingSettings.tsx
#   apps/web/src/components/settings/SourceControlWritingSettings.test.tsx (mixed instructions, bulk apply and reset)
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

  # Writing to the template is the MC's (mc/orchestration/text-generation.feature).
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

  @mc
  Scenario: A project's own writing style wins over the environment's
    Given the environment's writing style is Conventional Commits
    And the project "shop" overrides it with Repository conventions
    When a commit message is generated in "shop"
    Then it follows the repository's conventions

  @mc
  Scenario: An unusable writer model falls back to the text generation model
    Given the separate writer model's provider is not installed
    When a commit message is generated
    Then the text generation model writes it

  @backlog @desktop @mobile
  Scenario: Environments with different writing styles show as mixed
    Given "Laptop" writes in Conventional Commits and "Build box" in Repository conventions
    When the user opens Settings, Source Control for both
    Then the writing style reads "Mixed"
    And the only way to write instructions is to write them for all environments at once

  @backlog @desktop @mobile
  Scenario: Instructions written for all environments replace each one's
    Given the settings scope covers two environments with different writing styles
    When the user chooses to write custom instructions for all
    And writes "Keep titles under 50 characters." and applies them
    Then both environments use Custom instructions with those instructions
    And applying is not possible until something was typed

  @backlog @desktop @mobile
  Scenario: Custom instructions are saved when the field is left
    Given the writing style is Custom instructions
    When the user types instructions with spaces around them and leaves the field
    Then they are saved without the surrounding spaces
    And leaving the field without a change saves nothing

  @backlog @desktop @mobile
  Scenario: Switching writing style keeps the instructions typed so far
    Given the writing style is Custom instructions with "Short titles."
    When the user switches to Conventional Commits and back
    Then the instructions are still "Short titles."

  @backlog @desktop @mobile
  Scenario: The writing style can be reset
    Given the writing style is Custom instructions with "Short titles."
    When the user resets the writing style
    Then the style is Repository conventions
    And the instructions are empty

  @backlog @desktop @mobile
  Scenario: Environments that differ on templates show as mixed
    Given "Laptop" follows change request templates and "Build box" does not
    When the user opens Settings, Source Control for both
    Then following templates shows as mixed
    And resetting it makes both follow templates

  @backlog @desktop @mobile
  Scenario: The writer model needs a connected environment
    Given no environment is connected
    When the user opens Settings, Source Control
    Then the user is told to connect an environment to choose its source control writer model

  @backlog @desktop @mobile
  Scenario: A separate writer model needs a usable text generation model first
    Given the environment's text generation model is not usable
    When the user looks at the separate writer model switch
    Then it cannot be turned on

  @backlog @desktop @mobile
  Scenario: A separate writer model that has no provider says so
    Given a separate writer model is on
    And no provider that can write text is available
    Then the user is told "No text generation providers available."
    And the switch can still be turned off

  @backlog @desktop @mobile
  Scenario: A separate writer model starts from the text generation model
    When the user turns on a separate source control writer model
    Then it starts as the environment's current text generation model

  @backlog @desktop @mobile
  Scenario: Writer models differing between environments show as mixed
    Given the settings scope covers two environments with different writer models
    When the user looks at the writer model
    Then it reads "Mixed"

  @backlog @desktop @mobile
  Scenario: Only providers that can write text are offered as writers
    Given a provider that cannot generate text is configured
    When the user looks at the writer model choices
    Then that provider's models are not offered

  @backlog @desktop @mobile
  Scenario: Instructions for all environments can be cleared on purpose
    Given the settings scope covers two environments with different writing styles
    When the user chooses to write custom instructions for all
    And types something, then clears it and applies
    Then both environments use Custom instructions with no text

  @backlog @desktop @mobile
  Scenario: Resetting templates leaves each environment's instructions alone
    Given "Laptop" and "Build box" differ on templates and on instructions
    When the user resets following change request templates
    Then both follow templates
    And each keeps its own writing style and instructions

  @backlog @desktop @mobile
  Scenario: Resetting the writing style resets every environment
    Given the settings scope covers two environments and the first already has the default style
    When the user resets the writing style
    Then both environments are at Repository conventions with no instructions
