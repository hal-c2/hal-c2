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

  Scenario: An enabled Muse Code that cannot be found says so
    Given the muse command is not installed on the MC
    When the user enables Muse Code
    Then Muse Code is listed as not installed, saying it was not found

  Scenario: A Muse Code whose version check fails says it could not be run
    Given Muse Code is installed but its version check fails
    When the user enables Muse Code
    Then Muse Code is listed as unavailable, saying it could not be run

  Scenario: A Muse Code that exits while listing its models says so
    Given Muse Code is installed but exits while listing its models
    When the user enables Muse Code
    Then Muse Code is listed as unavailable, saying it could not list its models

  Scenario: Enabling Muse Code lists it with its models
    Given Muse Code is installed but not enabled
    When the user enables Muse Code
    Then Muse Code is listed with the models from Muse's catalog

  Scenario: A Muse Code turn runs on the user's own installation
    Given Muse Code is installed and enabled
    When the user sends a message to Muse Code
    Then the turn runs on the user's own Muse Code installation

  Scenario: A Muse Code instance the user added is read again after its binary changes
    Given a Muse Code instance the user added runs a muse whose version check fails
    When the user points that instance at a working muse
    Then that instance is listed with the models from Muse's catalog

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

  Scenario Outline: A Muse Code host that answers <command> for another id is replaced
    Given a Muse Code thread whose host answers <command> for another id
    When the user sends a message that Muse Code takes under that other id
    Then the turn fails and that Muse Code host is stopped
    And the next message runs on a new Muse Code host

    Examples:
      | command        |
      | session/start  |
      | session/resume |
      | turn/start     |

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

  Scenario: A reasoning level the Muse Code model does not offer is left to Muse
    Given a Muse Code thread with reasoning set to max on a model that offers low, medium and high
    When the user sends a message to Muse Code
    Then Muse Code runs the turn at the model's own default reasoning

  Scenario: Context usage Muse Code reports after a turn reaches the context meter
    Given Muse Code is installed and enabled
    When Muse Code reports its context usage after the turn has ended
    Then the turn's context usage is shown

  Scenario: Context usage Muse Code reports as the next turn starts stays with its turn
    Given Muse Code is installed and enabled
    When Muse Code reports a turn's context usage as the next turn starts
    Then the usage stays with the turn it followed

  Scenario: Steps Muse Code cancelled are left out of its plan
    Given Muse Code shares a plan with a step it cancelled
    Then the plan leaves the cancelled step out

  Scenario: A Muse Code subagent is shown as a subagent with its progress and answer
    Given Muse Code delegates a review to a subagent that reports progress and answers
    Then the subagent is shown as a child of the turn with its progress and its answer
    And the user can open the subagent's own thread with its task and its answer

  Scenario: A Muse Code subagent that fails shows why
    Given Muse Code delegates a review to a subagent that fails
    Then the subagent is shown as failed with Muse's reason

  Scenario: Muse Code subagents running at once each show their own progress and answer
    Given Muse Code delegates two reviews to subagents that run at once
    Then each subagent is shown with its own progress and its own answer

  Scenario: A Muse Code subagent first reported as done shows what it did
    Given Muse Code delegates a review to a subagent it first reports as done
    Then the subagent is shown with what it did and its answer

  Scenario: Muse Code subagents in different turns are different subagents
    Given Muse Code delegates a review to a subagent in each of two turns
    Then each turn's subagent is its own, with its own thread

  Scenario: A Muse Code subagent that answers only with a summary shows the summary
    Given Muse Code delegates a review to a subagent that answers only with a summary
    Then the subagent's answer is its summary

  Scenario: A Muse Code subagent that Muse cancels shows as cancelled
    Given Muse Code delegates a review to a subagent it cancels
    Then the subagent is shown as cancelled, without an answer

  Scenario: A Muse Code subagent that fails without a reason shows what it answered
    Given Muse Code delegates a review to a subagent that fails without a reason after answering in part
    Then the subagent is shown as failed with what it answered

  # Muse may name states of its own; only one it ends a subagent with ends it.
  Scenario: A Muse Code subagent in a state Muse has not named before is still running
    Given Muse Code delegates a review to a subagent it reports in a state of its own before it answers
    Then the subagent is shown running, then with its answer

  Scenario: A Muse Code subagent still running when the turn ends stops with it
    Given Muse Code delegates a review to a subagent and the turn ends first
    Then the subagent is shown as stopped with the turn, without an answer

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

  Scenario: A Muse Code workflow's request with a second requirement is approved for it too
    Given the thread runs Muse Code in full access
    When a Muse Code workflow asks twice to run a command it can be approved for
    Then both approvals are given without asking the user

  Scenario: A Muse Code workflow's request that cannot be approved for it asks the user
    Given the thread runs Muse Code in full access
    When a Muse Code workflow asks to run a command it offers no way to approve
    Then the request is shown to the user

  Scenario: Approving a Muse Code request lets the turn continue
    Given Muse Code asked to edit a file
    When the user approves the Muse Code request
    Then Muse Code edits the file and the turn continues

  Scenario: A Muse Code request that needs a second approval asks again
    Given Muse Code asked to run a command that needs two approvals
    When the user approves the Muse Code command
    Then the request still waits for the user
    When the user approves the Muse Code command
    Then Muse Code runs the command and the turn continues

  Scenario: Declining a Muse Code request is reported back to Muse
    Given Muse Code asked to run a command
    When the user declines the Muse Code request
    Then Muse Code is told the command was declined and the turn continues without it

  Scenario: Muse Code questions are answered from the composer
    When Muse Code asks the user a question with choices
    Then the choices appear in the composer and the answer goes back to Muse Code

  Scenario: A dismissed Muse Code question is closed and the turn goes on
    When Muse Code asks the user a question with choices
    And the user dismisses the Muse Code question
    Then Muse Code is told and the turn goes on

  Scenario: An overloaded Muse Code is asked again
    Given Muse Code is busy with a long task and overloaded the first two times it is steered
    When the user steers the Muse Code turn
    Then Muse Code is asked again until the steer lands

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
