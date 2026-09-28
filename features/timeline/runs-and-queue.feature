# Sources:
#   docs/user/composer.md (Queued messages, Follow-up behavior)
#   docs/user/updating.md (Continue threads after restarts)
#   packages/contracts/src/orchestrationV2.ts (message.dispatch, run.interrupt, queue.resume, queued-run.reorder, queued-run.cancel, queued-run.edit, queued-message.promote-to-steer, provider-session.detach, run.created, run.updated, run_interrupt_request, run_interrupt_result)
#   apps/server-ex/lib/hal_c2/orchestration.ex (queueing, steering, restart, interrupt, detach)
#   apps/server-ex/lib/hal_c2/orchestration/recovery.ex (settle at boot, Continue where you left off)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (next queued message starts)
#   apps/server-ex/lib/hal_c2/projection/timeline.ex (cancelled queued messages and superseded interrupts hidden)
#   apps/web/src/components/chat/QueuedRunsControl.tsx
#   apps/web/src/components/chat/MessagesTimeline.tsx (Queued, Steer markers, Interrupt requested, Run interrupted, Superseded attempt, Partial output retained)
#   apps/web/src/components/chat/ThreadErrorBanner.tsx
#   apps/web/src/components/chat/UsageLimitRecoveryBanner.tsx
#   apps/web/src/components/chat/ProviderStatusBanner.tsx
#   apps/web/src/components/chat/ContextWindowMeter.tsx
#   apps/web/src/components/chat/ContextWindowMeter.logic.ts
#   apps/tui/src/contextWindow.ts
#   apps/tui/src/components/ChatView.tsx (interrupt)

Feature: Runs, interruptions and the queue
  A turn runs until it finishes, fails or the user stops it. Messages sent meanwhile
  wait in a queue or steer the running turn, and problems are explained where they happen.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  # TUI: implemented in apps/tui/src/components/ChatView.tsx
  @node
  Scenario: The user interrupts the running turn
    Given the agent is working
    When the user interrupts the turn
    Then the turn stops
    And the timeline marks the run as interrupted

  @node
  Scenario: A message sent while the agent works waits its turn
    Given the agent is working
    When the user queues "also update the changelog"
    Then the message is queued at position 1
    And it starts when the running turn ends

  @node
  Scenario Outline: Steering reaches the running turn when the provider allows it
    Given the agent is working on <provider>
    When the user steers with "use the new API"
    Then the message <outcome>

    Examples:
      | provider | outcome                           |
      | Codex    | joins the running turn            |
      | Claude   | joins the running turn            |
      | OpenCode | joins the running turn            |
      | Grok     | is queued behind the running turn |

  @node
  Scenario: Restarting puts the new message first
    Given the agent is working and one message is queued
    When the user sends "stop, do this instead" as a restart
    Then the running turn is interrupted
    And "stop, do this instead" runs before the queued message

  @node
  Scenario Outline: The user manages the queue
    Given the agent is working and "A" and "B" are queued
    When the user <action>
    Then the queue holds <queue>

    Examples:
      | action                         | queue                 |
      | moves "B" above "A"            | "B" then "A"          |
      | removes "A" from the queue     | "B"                   |
      | edits "A" to read "A, briefly" | "A, briefly" then "B" |

  @node
  Scenario: A queued message is promoted to steer the running turn
    Given the agent is working on Codex and "A" is queued
    When the user sends "A" as a steer instead
    Then "A" joins the running turn
    And the queue is empty

  @shared @backlog
  Scenario Outline: A sent message says how it reached the agent
    When the user's message was <how>
    Then the message is marked "<marker>"

    Examples:
      | how                                  | marker                                                    |
      | queued behind the active turn        | Queued behind the active turn                             |
      | sent as a steer                      | Steered the active turn                                   |
      | queued and later promoted to a steer | Originally queued, then promoted to steer the active turn |

  @node
  Scenario: After a restart the queue waits for the user
    Given two messages were queued when the node restarted
    Then the queue is held and the messages are kept
    When the user resumes the queue
    Then the first queued message starts

  @node
  Scenario: A turn that was running when the node stopped is settled
    Given the agent was working when the node stopped
    When the node starts again
    Then the turn is marked interrupted
    And the thread is not shown as still working

  @node
  Scenario Outline: A thread continues after a restart only when the project asks for it
    Given the agent was working when the node stopped
    And continuing threads after restarts is <setting>
    When the node starts again
    Then <outcome>

    Examples:
      | setting | outcome                                          |
      | on      | the agent is sent "Continue where you left off." |
      | off     | the thread waits for the user                    |

  @node
  Scenario: The provider stops while a turn is starting
    When the provider exits before the turn starts
    Then the run fails with "The provider stopped while starting the turn."

  @shared @backlog
  Scenario: The user dismisses a thread's error
    Given the thread shows the error "Rate limited"
    When the user dismisses the error
    Then the error is hidden for this thread
    And a different error on the same thread is still shown

  @shared @backlog
  Scenario Outline: A usage limit can resume the thread when it resets
    Given the thread stopped because the provider's usage limit was reached
    And the limit resets at 3 pm
    When the user <action>
    Then <outcome>

    Examples:
      | action                     | outcome                                  |
      | chooses to resume at reset | the thread continues at 3 pm             |
      | cancels the auto-resume    | the thread waits for the user after 3 pm |

  # TUI: renders the meter from apps/tui/src/contextWindow.ts, but the node does not report context usage yet.
  @shared @backlog
  Scenario Outline: The thread shows how full the context window is
    Given the agent has used 144,000 tokens <of>
    Then the context window reads "<reading>"

    Examples:
      | of                        | reading         |
      | of a 200,000 token window | 72% · 144k/200k |
      | of an unknown window      | 144k used       |

  @desktop @backlog
  Scenario Outline: The thread says when its provider cannot run
    Given the thread in "shop" runs on Codex
    And Codex <problem>
    When the user looks at the thread
    Then the thread shows "<title>" with "<message>"

    Examples:
      | problem                                                  | title                    | message                                                   |
      | is not installed and HAL-C2 can install it              | Codex provider status    | Open provider setup to install Codex on this environment. |
      | is signed out and HAL-C2 can sign it in                 | Codex is unauthenticated | Open provider setup to sign in.                           |
      | is signed out and can only be signed in from its own CLI | Codex is unauthenticated | Sign in via the CLI to authenticate again.                |
      | is unavailable                                           | Codex provider status    | Codex provider is unavailable.                            |

  @desktop @backlog
  Scenario: A provider version known to break turns is flagged even when it is ready
    Given the thread in "shop" runs on Codex 0.9.0
    And Codex 0.9.0 is known to be broken
    When the user looks at the thread
    Then the thread warns "Codex 0.9.0 is known to be broken"

  @desktop @backlog
  Scenario: The user installs or signs in to the provider from the thread
    Given the thread shows that Codex is signed out
    When the user opens provider setup from the thread
    Then the setup for Codex opens

  @desktop @backlog
  Scenario: A dismissed provider notice stays away until the problem changes
    Given the thread shows that Codex is signed out
    When the user dismisses the notice
    Then the notice is gone
    When Codex later becomes unavailable for another reason
    Then the thread shows the new problem

  @desktop @backlog
  Scenario: Antigravity after a restart is not reported as signed out
    Given the thread in "shop" runs on Antigravity
    And Antigravity has not checked its saved sign-in since the environment restarted
    When the user looks at the thread
    Then no provider notice is shown
