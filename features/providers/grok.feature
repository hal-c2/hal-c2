# Sources:
#   apps/server-ex/lib/hal_c2/acp.ex (grok agent, permission-mode args, supportsTextGeneration)
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex (permission requests, session/cancel)
#   apps/server-ex/lib/hal_c2/usage/transcripts.ex (Grok transcripts)
#   apps/server/src/provider/Layers/GrokProvider.ts, apps/server/src/provider/Drivers/GrokDriver.ts, apps/server/src/provider/acp/GrokAcpSupport.ts
#   apps/server/src/orchestration-v2/Adapters/GrokAdapterV2.ts, apps/server/src/provider/Drivers/GrokSkills.ts
#   apps/server/src/provider/Layers/grokUsageLimits.ts, apps/server/src/textGeneration/GrokTextGeneration.ts

@plugin-grok @node
Feature: Grok
  Grok runs the local grok CLI as an ACP agent. Sign-in stays with the Grok CLI, or with
  an xAI API key in the instance's environment.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Grok does nothing until the user enables it
    Given Grok is installed but not enabled
    When the node starts
    Then no Grok process is started

  Scenario: Grok is only offered when the grok command is installed
    Given the grok command is not installed on the node
    When the user opens the list of agents to enable
    Then Grok is not offered

  Scenario: Enabling Grok lists the models it offers
    Given the grok command is installed and signed in
    When the user enables Grok
    Then Grok's models are offered in the model picker

  Scenario: A signed-out Grok says so
    Given the grok command is installed but not signed in
    When the user enables Grok
    Then Grok is shown as signed out with a hint to sign in

  Scenario: Grok permission requests become approvals
    Given the thread runs Grok with approval required
    When Grok asks to run a command
    Then the user is asked to approve it
    And the user's decision is sent back to Grok

  Scenario: Stopping a Grok turn cancels it in Grok
    Given a Grok turn is running
    When the user stops the turn
    Then Grok is told to cancel the turn

  Scenario: Grok writes thread titles and commit messages
    Given Grok is picked for text generation
    When a new thread needs a title
    Then Grok writes it with every tool refused

  Scenario: Grok transcripts count toward usage
    Given Grok has written transcripts on this machine
    When the user opens the usage summary
    Then Grok's tokens and cost are included

  Scenario: An xAI API key in the instance's environment signs Grok in
    Given the Grok instance has an xAI API key in its environment
    When the user opens the provider list
    Then Grok shows that it uses an xAI API key

  Scenario: Grok's plan becomes a plan the user can implement
    When Grok proposes a plan
    Then the plan is shown as a proposed plan
    And the user can implement it

  Scenario: Grok's questions are asked in HAL-C2
    When Grok asks the user a question
    Then the question is shown and the answer is sent back to Grok

  Scenario: Grok subagents appear as child work
    When Grok starts a subagent
    Then the subagent's work is grouped under the step that started it

  Scenario: Grok's always-approve command is not offered
    When the user types a slash in a Grok thread
    Then Grok's own always-approve command is not offered
    And "/compact" is offered

  Scenario: Grok reasoning choices come from the model
    When the user opens the options for a Grok model that supports reasoning
    Then the reasoning levels Grok offers for that model are shown

  Scenario: Reverting is not offered for Grok threads
    Given a Grok thread with two turns
    When the user looks at the first turn
    Then reverting to it is not offered

  Scenario: Grok's billing period is shown in the limits view
    Given Grok is signed in with a Grok account
    When the user opens the limits view
    Then Grok shows how much of its billing period is used and when it resets

  Scenario: Grok usage limits are unavailable with an API key or custom endpoint
    Given the Grok instance uses an API key
    When the user opens the limits view
    Then Grok's limits are shown as unsupported

  Scenario: A Grok usage limit stops the turn with a clear reason
    When Grok stops because the account hit its usage limit
    Then the thread says Grok's usage limit was reached
