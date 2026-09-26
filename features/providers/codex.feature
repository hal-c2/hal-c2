# Sources:
#   docs/user/providers-codex.md
#   docs/internals/providers.md (Codex async questions, shadow homes, update ownership)
#   apps/server-ex/lib/t3/codex/provider.ex, apps/server-ex/lib/t3/codex/thread_runtime.ex
#   apps/server-ex/lib/t3/orchestration.ex (provider.uploadFeedback)
#   apps/server-ex/lib/t3/provider_updates.ex (@openai/codex advisory)
#   apps/server-ex/lib/t3/provider_usage_limits/codex.ex (account/rateLimits/read, reset credits)
#   apps/server-ex/lib/t3/text_generation.ex (codex exec)
#   apps/server/src/provider/Layers/CodexProvider.ts, apps/server/src/provider/Layers/CodexSessionRuntime.ts
#   apps/server/src/provider/Drivers/CodexDriver.ts, apps/server/src/provider/Drivers/CodexHomeLayout.ts
#   apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts
#   apps/server/src/provider/Layers/codexUsageLimits.ts, apps/server/src/provider/Layers/codexResetCredit.ts
#   packages/contracts/src/rpc.ts (provider.uploadFeedback, provider.consumeResetCredit)

@plugin:codex @node
Feature: Codex
  Codex runs as a bundled provider plugin through the codex app-server protocol. The
  node reads Codex's own model list, maps T3 Code's access modes to Codex's approval
  and sandbox policies, and keeps Codex's login where Codex keeps it.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Codex is offered when the codex command is on the node's path
    Given the codex command is installed on the node
    When the user opens the provider list
    Then Codex is listed as ready with its installed version

  Scenario: Codex is not offered when the codex command is missing
    Given the codex command is not installed on the node
    When the user opens the provider list
    Then Codex is not offered as a provider

  Scenario: Codex models come from Codex itself
    Given Codex reports the models "GPT-6 Astra" and "GPT-6 Luna"
    When the node has read the Codex model list
    Then both models are offered in the model picker with Codex's default marked

  Scenario: A default model is offered until Codex's list has been read
    Given the node has just started and has not read the Codex model list yet
    When the user opens the model picker for Codex
    Then a single default Codex model is offered

  Scenario: Updating Codex uses the installer that owns it
    Given Codex was installed with npm and is outdated
    When the user updates Codex
    Then Codex is updated through npm and the new version is shown

  Scenario Outline: Codex approvals are answered from T3 Code
    Given the thread runs Codex with approval required
    When Codex asks to <action>
    Then the user is asked to approve it
    And the user's decision is sent back to Codex

    Examples:
      | action                        |
      | run a command                 |
      | change a file                 |
      | widen its sandbox permissions |

  Scenario Outline: Codex approval decisions keep their scope
    Given Codex asked to run a command
    When the user answers <decision>
    Then Codex <result>

    Examples:
      | decision              | result                                      |
      | allow once            | runs the command this time only             |
      | allow for the session | runs matching commands for the session      |
      | decline               | skips the command and continues             |
      | cancel                | stops the turn                              |

  Scenario: Codex questions are asked in T3 Code
    When Codex asks the user a question with choices
    Then the question is shown with its choices
    And the user's answer is sent back to Codex

  Scenario: A Codex question can be dismissed
    Given Codex asked the user a question
    When the user dismisses the question
    Then Codex is told the question was not answered

  Scenario: A Codex turn can be steered while it runs
    Given a Codex turn is running
    When the user sends a follow-up message
    Then Codex receives the message during the running turn

  Scenario: Codex's plan and task list are shown during the turn
    Given the thread is in plan mode on Codex
    When Codex updates its plan
    Then the task list shows each step and its status
    And the finished plan is shown as a proposed plan

  Scenario: Codex can use the T3 Code tools
    Given the project allows the T3 Code tools
    When a Codex turn starts
    Then Codex can call the T3 Code tools for this thread

  Scenario: Reverting a Codex turn rolls Codex back too
    Given a Codex thread with three turns
    When the user reverts to the end of the first turn
    Then Codex's own thread is rolled back to that point

  Scenario: Forking a Codex thread forks Codex's thread
    Given a Codex thread with three turns
    When the user forks from the second turn
    Then a new thread continues from a fork of Codex's thread at the second turn

  Scenario: Feedback about a Codex thread is sent to OpenAI
    Given a Codex thread has run at least one turn on this node
    When the user sends feedback "The agent stopped early"
    Then the conversation and Codex logs are uploaded to OpenAI
    And the user is given the feedback thread id

  Scenario: Feedback before any Codex turn has run is refused
    Given a Codex thread that has not run a turn yet
    When the user sends feedback
    Then the user is told to send a message first

  Scenario: Codex writes thread titles and commit messages
    Given Codex is picked for text generation
    When a commit needs a message
    Then Codex writes it in a read-only sandbox

  @backlog
  Scenario: Several Codex accounts share one Codex home
    Given a shared Codex home and a second Codex instance with its own shadow home
    When the user signs in to the second instance
    Then both instances see the same Codex sessions and settings
    And each keeps its own login and model list

  @backlog
  Scenario: The user can switch a Codex thread to another account
    Given two Codex instances share a Codex home
    When the user picks the other account from the thread's model picker
    Then the thread continues on that account without moving its history

  @backlog
  Scenario: Accounts with a different Codex home are not offered for an existing thread
    Given a Codex instance with a separate Codex home
    When the user opens the model picker in an existing Codex thread
    Then that instance is not offered for the thread

  @backlog
  Scenario: Answering a question while Codex keeps working
    Given Codex asked a question and kept working
    When the user answers it
    Then the answer reaches the running turn as a new message

  @backlog
  Scenario: An answer after Codex finished starts a new turn
    Given Codex asked a question and then finished the turn
    When the user answers it
    Then the answer starts a new turn

  @backlog
  Scenario: Unanswered Codex questions survive a reconnect
    Given Codex asked a question that is not answered yet
    When the client reconnects to the node
    Then the question is still waiting for an answer

  @backlog
  Scenario Outline: Codex tools can ask for access to another app
    Given a Codex tool asks for access to "Linear"
    When the user grants access <scope>
    Then the tool gets access <scope>

    Examples:
      | scope                 |
      | for this request      |
      | for this session      |
      | permanently           |

  @backlog
  Scenario: Declining an app access request lets the tool continue without it
    Given a Codex tool asks for access to "Linear"
    When the user declines
    Then the tool is told access was declined

  @backlog
  Scenario: Codex stopping on a usage limit names the limit and the reset
    When Codex stops because the weekly limit is used up
    Then the thread says the weekly limit is used up and when it resets
    And it says to send the message again after the reset

  @backlog
  Scenario: A workspace plan out of credits says who can fix it
    Given the Codex account is on a workspace plan with no credits left
    When Codex stops on a usage limit
    Then the thread says the workspace owner needs to add credits

  @backlog
  Scenario Outline: Codex model options
    When the user opens the options for a Codex model that supports <option>
    Then the user can choose <choices>

    Examples:
      | option       | choices                                               |
      | reasoning    | none, minimal, low, medium, high, extra high, max     |
      | service tier | standard or fast                                      |

  @backlog
  Scenario: Codex subagents appear as child threads
    When Codex starts a subagent
    Then the subagent's work is shown as a child of the turn
    And the user can open the subagent's own thread

  @backlog
  Scenario: Codex auto mode uses Codex's automatic reviewer
    Given the thread runs Codex in auto mode
    When Codex wants to run a command outside its sandbox
    Then Codex's automatic reviewer decides instead of asking the user

  @backlog
  Scenario: A signed-out Codex explains how to sign in
    Given the Codex CLI on the node is not signed in
    When the user opens the provider list
    Then Codex is shown as not signed in with a hint to run the Codex login command

  Scenario: Codex shows the signed-in account and plan
    Given Codex is signed in with a ChatGPT Pro subscription
    When Codex's usage has been checked
    Then Codex shows the account's email and its ChatGPT Pro plan

  Scenario: Codex signed in with an API key says so
    Given Codex is signed in with an OpenAI API key
    When Codex's usage has been checked
    Then Codex shows that it uses an OpenAI API key

  @backlog
  Scenario: Codex offers its compact and feedback commands in the composer
    When the user types a slash in a Codex thread
    Then "/compact" and "/feedback" are offered
