# Sources:
#   docs/user/providers-pi.md
#   docs/internals/providers.md (Pi RPC mode, forks through the CLI in the destination directory)
#   apps/server-ex/lib/hal_c2/pi.ex, apps/server-ex/lib/hal_c2/pi/thread_runtime.ex (Pi RPC mode)
#   apps/server/src/provider/Layers/PiProvider.ts, apps/server/src/provider/Drivers/PiDriver.ts
#   apps/server/src/orchestration-v2/Adapters/PiAdapterV2.ts, apps/server/src/orchestration-v2/Adapters/PiRpc.ts
#   apps/server/src/orchestration-v2/Adapters/piHalC2McpInjection.ts, apps/server/src/provider/PiCommands.ts
#   apps/server/src/provider/Layers/piThinkingCapabilities.ts, apps/server/src/textGeneration/PiTextGeneration.ts

@plugin-pi @node
Feature: Pi
  Pi uses the user's existing Pi installation with its own models, logins, extensions,
  skills and session files. Pi is early access.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Pi does nothing until the user enables it
    Given Pi is installed but not enabled
    When the node starts
    Then no Pi process is started

  Scenario: Pi is only offered when the pi command is installed
    Given the pi command is not installed on the node
    When the user opens the list of agents to enable
    Then Pi is not offered

  # The node runs Pi in its own RPC mode, as the TS server does (PiAdapterV2), not through pi-acp.
  Scenario: Pi runs in its own RPC mode
    Given Pi is installed and enabled
    When the user sends a message to Pi
    Then the turn runs on the user's own Pi installation

  Scenario: A custom Pi binary path is used
    Given Pi's binary path is set to "/opt/pi/bin/pi"
    When the user sends a message to Pi
    Then that Pi binary runs the turn

  Scenario: Pi older than 0.80.5 is refused
    Given the installed Pi is 0.79.0
    When the user refreshes provider status
    Then Pi is shown as unsupported with a hint to update to 0.80.5 or newer

  Scenario: Pi launch arguments that change how HAL-C2 runs Pi are refused
    When the user adds the launch argument "--mode json" to Pi
    Then the setting is refused with a message that HAL-C2 owns that part of Pi

  Scenario: Pi with no usable models explains how to sign in
    Given Pi reports no models
    When the user refreshes provider status
    Then Pi says to sign in with Pi in a terminal or configure an API key

  Scenario: Pi stays usable when discovery cannot finish
    Given Pi discovery needs interactive input
    When the user refreshes provider status
    Then Pi stays available with the "Pi default" model
    And the first thread lets Pi handle its startup prompt

  Scenario: Pi thinking levels follow the model
    Given the Pi model supports thinking levels up to extra high
    When the user opens the options for that model
    Then off, minimal, low, medium, high and extra high are offered
    And Pi's configured level is marked as the default

  Scenario Outline: Pi access modes decide which tools ask first
    Given the thread runs Pi in <mode>
    When Pi wants to <action>
    Then it is <outcome>

    Examples:
      | mode              | action           | outcome                 |
      | approval required | read a file      | allowed without asking  |
      | approval required | edit a file      | asked for approval      |
      | approval required | run a command    | asked for approval      |
      | auto-accept edits | edit a file      | allowed without asking  |
      | auto-accept edits | run a command    | asked for approval      |
      | full access       | run a command    | allowed without asking  |

  Scenario: Auto mode is not offered for Pi
    When the user opens the access picker in a Pi thread
    Then auto is not offered

  Scenario: Older Pi threads saved in auto behave as approval required
    Given a Pi thread saved with auto mode
    When the user opens the thread
    Then it shows and behaves as approval required

  Scenario: Changing the access mode restarts Pi on the same conversation
    Given a Pi thread with history
    When the user switches the thread to full access
    Then Pi restarts and continues the same native conversation

  Scenario: Allowing a Pi tool for the session stops further prompts for it
    Given Pi asked to run the same command twice
    When the user allows it for the session the first time
    Then the second request is allowed without asking

  Scenario: Pi extension dialogs appear in the composer
    When a Pi extension asks the user to pick from a list
    Then the choices appear in the composer and the answer goes back to the extension

  Scenario: A Pi thread can be resumed in the Pi terminal app
    Given a Pi thread in HAL-C2
    When the user opens the same session in Pi's own terminal app
    Then the conversation continues there from the same session file

  Scenario: Reverting a Pi turn rewinds Pi's session file
    Given a Pi thread with three turns
    When the user reverts to the end of the first turn
    Then Pi continues from the first turn

  Scenario: Forking a Pi thread copies the native conversation into the new workspace
    Given a Pi thread with three turns
    When the user forks from the second turn into a new worktree
    Then the new thread continues Pi's conversation through the second turn in that worktree

  Scenario: Pi skills appear in the skill menu
    Given Pi loads the project skill "deploy"
    When the user opens the skill menu in a Pi thread
    Then "deploy" is offered and uses Pi's own skill expansion

  Scenario: Pi retries and compactions show in the work log
    When Pi retries a failed request and later compacts the conversation
    Then the work log shows the retry and the compaction

  Scenario: The context meter follows Pi's usage reports
    When Pi reports its context usage while answering
    Then the context meter shows Pi's reported usage

  Scenario: Pi delegates work to child threads through the HAL-C2 tools
    When Pi delegates a task
    Then the task appears as a child thread in the subagent view

  Scenario: Pi exiting mid-turn is reported
    Given a Pi turn is running
    When the Pi process exits unexpectedly
    Then the turn fails saying Pi exited unexpectedly
