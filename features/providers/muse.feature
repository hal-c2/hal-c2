# Sources:
#   docs/user/providers-muse.md
#   apps/server-ex/lib/hal_c2/muse.ex, apps/server-ex/lib/hal_c2/muse/thread_runtime.ex
#   packages/contracts/src/settings.ts (MuseSettings)
#   upstream pingdotgg/t3code packages/provider-muse/src/settings.ts, packages/provider-muse/src/client.ts
#   upstream pingdotgg/t3code packages/provider-muse/src/server/status.ts (runtime modes, /compact, health messages)
#   upstream pingdotgg/t3code packages/provider-muse/src/server/adapter.ts (capabilities, approvals, questions, steering, MCP tools)
#   upstream pingdotgg/t3code packages/provider-muse/src/server/modelCatalog.ts (reasoning effort tiers)
#   upstream pingdotgg/t3code packages/provider-muse/src/server/protocol.ts (approval choices)
#
# Steering, the hidden plan/build toggle and the missing rewind are in capabilities.feature.

@plugin-muse @mc
Feature: Muse Code
  Muse Code uses the user's own Muse installation and login on the environment. Muse Code is in
  beta: it stays off until the user enables it.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Muse Code does nothing until the user enables it
    Given Muse Code is installed but not enabled
    When the MC starts
    Then no Muse Code process is started

  Scenario: Muse Code is only offered when the muse command is installed
    Given the muse command is not installed on the MC
    When the user opens the list of agents to enable
    Then Muse Code is not offered

  Scenario: Enabling Muse Code lists it with its models
    Given Muse Code is installed but not enabled
    When the user enables Muse Code
    Then Muse Code is listed with the models from Muse's catalog

  Scenario: A Muse Code turn runs on the user's own installation
    Given Muse Code is installed and enabled
    When the user sends a message to Muse Code
    Then the turn runs on the user's own Muse Code installation

  Scenario: A custom Muse Code binary path is used
    Given Muse Code's binary path is set to "/opt/muse/bin/muse"
    When the user sends a message to Muse Code
    Then that Muse Code binary runs the turn

  Scenario: A Muse Code thread keeps its conversation across turns
    Given a Muse Code thread with history
    When the MC restarts and the user sends another message
    Then Muse Code continues the same session

  Scenario: A Muse Code thread keeps its conversation when Muse Code exits between turns
    Given a Muse Code thread with history
    When Muse Code exits and the user sends another message
    Then Muse Code continues the same session

  Scenario: Muse Code with no models tells the user to sign in
    Given Muse Code reports no models
    When the user refreshes provider status
    Then Muse Code is shown with a warning to run "muse login" on the environment

  Scenario: Muse Code's sign-in state is not guessed
    Given Muse Code is installed and enabled
    When the user refreshes provider status
    Then Muse Code is shown as ready without claiming the user is signed in or out

  Scenario: Muse Code reasoning levels follow the model
    Given the Muse Code model reports the reasoning levels low, medium, high and max with high as its default
    When the user opens the options for the Muse Code model
    Then low, medium, high and max are offered under "Reasoning"
    And high is marked as the default

  Scenario: A Muse Code model that reports no reasoning levels gets the usual ones
    Given the Muse Code model does not report its reasoning levels
    When the user opens the options for the Muse Code model
    Then low, medium, high, extra high and max are offered under "Reasoning"
    And high is marked as the default

  Scenario: A custom Muse Code model gets the usual reasoning levels
    Given the Muse Code model reports the reasoning levels low, medium, high and max with high as its default
    And the user adds the custom Muse Code model "fake/custom"
    When the user opens the options for the custom Muse Code model
    Then low, medium, high, extra high and max are offered under "Reasoning"
    And high is marked as the default

  Scenario: The chosen reasoning level reaches Muse Code
    Given a Muse Code thread with reasoning set to max
    When the user sends a message to Muse Code
    Then Muse Code runs the turn at max reasoning

  Scenario: Muse Code offers only supervised and full access
    When the user opens the permission mode choices in a Muse Code thread
    Then supervised and full access are offered
    And auto-accept edits and auto are not offered

  Scenario Outline: Muse Code asks first only in supervised
    Given the thread runs Muse Code in <mode>
    When Muse Code wants to run a command
    Then the command is <outcome>

    Examples:
      | mode        | outcome                |
      | supervised  | asked for approval     |
      | full access | allowed without asking |

  Scenario: Approving a Muse Code request lets the turn continue
    Given Muse Code asked to edit a file
    When the user approves the Muse Code request
    Then Muse Code edits the file and the turn continues

  Scenario: Declining a Muse Code request is reported back to Muse
    Given Muse Code asked to run a command
    When the user declines the Muse Code request
    Then Muse Code is told the command was declined and the turn continues without it

  Scenario: Muse Code questions are answered from the composer
    When Muse Code asks the user a question with choices
    Then the choices appear in the composer and the answer goes back to Muse Code

  Scenario: Stopping a Muse Code turn interrupts it
    Given a Muse Code turn is running
    When the user stops the turn
    Then Muse Code stops working and the turn is shown as interrupted

  Scenario: /compact compacts the Muse Code conversation
    Given a Muse Code thread with history
    When the user sends "/compact" to Muse Code
    Then Muse Code compacts its conversation
    And the compaction is shown in the thread

  Scenario: Forking a Muse Code thread hands the conversation over as context
    Given a Muse Code thread with three turns
    When the user forks the Muse Code thread after the second turn
    Then the fork's first Muse Code turn starts from a summary of the first two turns

  Scenario: HAL-C2's tools are offered to Muse Code without blocking it
    Given Muse Code is installed and enabled
    When the user sends a message to Muse Code
    Then HAL-C2's orchestration tools are attached as an optional MCP server

  Scenario: Muse Code does not write titles, commit messages or pull requests
    Given Muse Code is installed and enabled
    When the user opens the model choices for generated text
    Then no Muse Code model is offered
