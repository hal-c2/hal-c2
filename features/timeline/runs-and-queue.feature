# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/composer.md (Queued messages, Follow-up behavior)
#   docs/user/updating.md (Continue threads after restarts)
#   packages/contracts/src/orchestrationV2.ts (message.dispatch, run.interrupt, queue.resume, queued-run.reorder, queued-run.cancel, queued-run.edit, queued-message.promote-to-steer, provider-session.detach, run.created, run.updated, run_interrupt_request, run_interrupt_result)
#   apps/server-ex/lib/hal_c2/orchestration.ex (queueing, steering, restart, interrupt, detach)
#   apps/server-ex/lib/hal_c2/orchestration/recovery.ex (settle at boot, Continue where you left off)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (next queued message starts)
#   apps/server-ex/lib/hal_c2/projection/timeline.ex (cancelled queued messages and superseded interrupts hidden)
#   apps/web/src/components/chat/QueuedRunsControl.tsx
#   apps/web/src/components/ChatView.tsx (waiting on background tasks, Stop)
#   apps/web/src/components/chat/MessagesTimeline.tsx (Queued, Steer markers, Interrupt requested, Run interrupted, Superseded attempt, Partial output retained)
#   apps/web/src/components/chat/ThreadErrorBanner.tsx
#   apps/web/src/components/chat/UsageLimitRecoveryBanner.tsx
#   apps/web/src/components/chat/ProviderStatusBanner.tsx
#   apps/web/src/components/chat/ContextWindowMeter.tsx
#   apps/web/src/components/chat/ContextWindowMeter.logic.ts
#   apps/web/src/lib/contextWindow.ts (live report, stored report, compaction fallback)
#   apps/web/src/components/chat/ComposerBannerStack.tsx (several notices above the composer)
#   apps/tui/src/contextWindow.ts
#   apps/tui/src/components/ChatView.tsx (interrupt)
#   apps/desktop-qt/src/native/ThreadStore.cpp (a sent image's signed address, asked for again once it expires)
#   apps/mobile/src/features/threads/ThreadFeed.tsx (sent file, video and unknown attachments)
#   apps/mobile/src/features/threads/ThreadFeed.tsx (a message not yet acknowledged shows Pending)

Feature: Runs, interruptions and the queue
  A turn runs until it finishes, fails or the user stops it. Messages sent meanwhile
  wait in a queue or steer the running turn, and problems are explained where they happen.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  # TUI: implemented in apps/tui/src/components/ChatView.tsx
  @mc
  Scenario: The user interrupts the running turn
    Given the agent is working
    When the user interrupts the turn
    Then the turn stops
    And the timeline marks the run as interrupted

  @mc
  Scenario: A message sent while the agent works waits its turn
    Given the agent is working
    When the user queues "also update the changelog"
    Then the message is queued at position 1
    And it starts when the running turn ends

  @mc
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

  @mc
  Scenario: Restarting puts the new message first
    Given the agent is working and one message is queued
    When the user sends "stop, do this instead" as a restart
    Then the running turn is interrupted
    And "stop, do this instead" runs before the queued message

  @mc
  Scenario Outline: The user manages the queue
    Given the agent is working and "A" and "B" are queued
    When the user <action>
    Then the queue holds <queue>

    Examples:
      | action                         | queue                 |
      | moves "B" above "A"            | "B" then "A"          |
      | removes "A" from the queue     | "B"                   |
      | edits "A" to read "A, briefly" | "A, briefly" then "B" |

  @mc
  Scenario: A queued message is promoted to steer the running turn
    Given the agent is working on Codex and "A" is queued
    When the user sends "A" as a steer instead
    Then "A" joins the running turn
    And the queue is empty

  @shared @backlog-mobile @backlog-tui
  Scenario Outline: A sent message says how it reached the agent
    When the user's message was <how>
    Then the message is marked "<marker>"

    Examples:
      | how                                  | marker                                                    |
      | queued behind the active turn        | Queued behind the active turn                             |
      | sent as a steer                      | Steered the active turn                                   |
      | queued and later promoted to a steer | Originally queued, then promoted to steer the active turn |

  @backlog @mobile
  Scenario: A message the MC has not acknowledged yet is marked as pending
    Given the user sent a message that the MC has not yet acknowledged
    When the user reads the thread
    Then the message's time reads "Pending"
    When the MC acknowledges the message
    Then the message shows the time it was sent

  @shared @backlog-mobile @backlog-tui
  Scenario: A sent message shows its images
    When the user sent the image "cart.png" with a message
    Then the message shows the image "cart.png" from its MC

  @shared @backlog-mobile @backlog-tui
  Scenario: An image is still shown after its address stops working
    Given the user sent the image "cart.png" with a message
    And the message shows the image "cart.png" from its MC
    When more than an hour passes
    Then the message shows the image "cart.png" from a new address

  @backlog @mobile
  Scenario: A sent file shows its name, kind and size
    When the user sent the file "report.pdf" of 2 MB with a message
    Then the message shows "report.pdf" with its kind and size

  @backlog @mobile
  Scenario: A sent file can be shared out by long pressing it
    Given the user sent the file "report.pdf" with a message
    When the user long presses "report.pdf" in the message
    Then the system share sheet offers "report.pdf"

  @backlog @mobile
  Scenario: A sent file that cannot be fetched says so
    Given the user sent the file "report.pdf" with a message
    And "My MacBook" no longer has "report.pdf"
    When the user opens "report.pdf" from the message
    Then the user is told the attachment could not be opened and why

  @backlog @mobile
  Scenario: A sent video is shown as a video that plays on request
    When the user sent the video "demo.mp4" with a message
    Then the message shows "demo.mp4" as a video
    When the user opens it
    Then the video plays

  @backlog @mobile
  Scenario: A sent attachment of a kind this client does not know is listed by name only
    Given the message carries an attachment of a kind a newer environment added
    Then the message lists the attachment by its name
    And there is nothing to open

  # MCs join only by clustering, and a cluster hands the address to the member that signed it.
  @dropped @shared
  Scenario: An image sent in a linked environment is loaded from that environment
    Given the user is looking at a thread on an environment the MC is linked to
    When the user sent the image "cart.png" with a message
    Then the message shows the image "cart.png" from the linked environment

  @mc
  Scenario: After a restart the queue waits for the user
    Given two messages were queued when the MC restarted
    Then the queue is held and the messages are kept
    When the user resumes the queue
    Then the first queued message starts

  @mc
  Scenario: A turn that was running when the MC stopped is settled
    Given the agent was working when the MC stopped
    When the MC starts again
    Then the turn is marked interrupted
    And the thread is not shown as still working

  @mc
  Scenario Outline: A thread continues after a restart only when the project asks for it
    Given the agent was working when the MC stopped
    And continuing threads after restarts is <setting>
    When the MC starts again
    Then <outcome>

    Examples:
      | setting | outcome                                          |
      | on      | the agent is sent "Continue where you left off." |
      | off     | the thread waits for the user                    |

  @mc
  Scenario: The provider stops while a turn is starting
    When the provider exits before the turn starts
    Then the run fails with "The provider stopped while starting the turn."

  @backlog @desktop
  Scenario Outline: A finished turn that left work running says what it is waiting on
    Given the turn has finished and left <tasks> running in the background
    Then the thread says "<notice>"
    And it names each task by its description
    And the user can stop them from that notice

    Examples:
      | tasks                              | notice                        |
      | the task "watch tests"             | Waiting on background task    |
      | the tasks "watch tests" and "lint" | Waiting on 2 background tasks |

  @backlog @desktop
  Scenario: Background work is not announced while a turn is running
    Given a turn is running and has started background tasks
    Then the thread shows no notice about background work
    And stopping the turn is the way to stop them

  @backlog @desktop
  Scenario: Stopping background work can be asked again
    Given the turn has finished and left the task "watch tests" running
    When the user stops the background work and the environment accepts
    And "watch tests" is still running
    Then the user can ask to stop it again

  @backlog @desktop
  Scenario: Background work that cannot be stopped says why
    Given the turn has finished and left the task "watch tests" running
    And the environment rejects the stop
    When the user stops the background work
    Then the thread shows the reason as its error
    And the notice about "watch tests" stays

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

  # TUI: renders the meter from apps/tui/src/contextWindow.ts, but the MC does not report context usage yet.
  @shared @backlog
  Scenario Outline: The thread shows how full the context window is
    Given the agent has used 144,000 tokens <of>
    Then the context window reads "<reading>"

    Examples:
      | of                        | reading         |
      | of a 200,000 token window | 72% · 144k/200k |
      | of an unknown window      | 144k used       |

  @backlog @desktop
  Scenario: The context window reading is shown only when its setting is on
    Given the context window meter setting is off
    When the agent has used 144,000 tokens of a 200,000 token window
    Then the thread shows no context window reading
    When the user turns the context window meter setting on
    Then the context window reads "72% · 144k/200k"

  @backlog @desktop
  Scenario Outline: A context window under a tenth full is read to one decimal
    Given the agent has used <used> tokens of a 200,000 token window
    Then the context window is "<percent>" full

    Examples:
      | used    | percent |
      | 5,000   | 2.5%    |
      | 4,000   | 2%      |
      | 25,000  | 13%     |

  @backlog @desktop
  Scenario: A context window more than nine tenths full is flagged
    Given the agent has used 184,000 tokens of a 200,000 token window
    Then the context window reading is marked as nearly full

  # Legacy: apps/web/src/lib/contextWindow.ts (deriveLatestContextWindowSnapshot)
  @backlog @desktop
  Scenario: The context window follows the provider's live report during a turn
    Given the thread's last compaction left 40,000 tokens in context
    And the provider's last stored report says 90,000 of 200,000 tokens
    When the provider reports 120,000 of 200,000 tokens while a turn runs
    Then the context window reads "60% · 120k/200k"

  # Legacy: apps/web/src/lib/contextWindow.ts (deriveLatestContextWindowSnapshot)
  @backlog @desktop
  Scenario: The context window falls back to the provider's last stored report
    Given the thread's last compaction left 40,000 tokens in context
    And the provider's last stored report says 90,000 of 200,000 tokens
    And no turn is running
    Then the context window reads "45% · 90k/200k"

  # Legacy: apps/web/src/lib/contextWindow.ts (compaction item fallback)
  @backlog @desktop
  Scenario: With no report from the provider the context window reads what the last compaction left
    Given the provider has reported no context usage for the thread
    And the thread's last compaction left 40,000 tokens in context
    Then the context window reads "40k used"
    And the window's size is not known

  @backlog @desktop
  Scenario: The context window's details show what the thread has processed and cost
    Given the agent has used 144,000 tokens of a 200,000 token window
    And the thread has processed 1,200,000 tokens in all at a cost of 0.42 US dollars
    When the user opens the context window's details
    Then the details show "Total processed" as 1.2m and "Cost" as "USD 0.42"
    And a thread whose provider reports no cost shows no cost

  @backlog @desktop
  Scenario Outline: The context window's details say when the provider compacts on its own
    Given the thread runs on a model named "Sonnet" that compacts its context automatically
    And the provider <reports>
    When the user opens the context window's details
    Then the details say "<message>"

    Examples:
      | reports                                    | message                                                |
      | says it compacts at 160,000 tokens         | Compacts automatically at 160,000 tokens.              |
      | does not say when it compacts              | Context for Sonnet compacts automatically when needed. |

  @backlog @desktop
  Scenario: The conversation is compacted from the context window's details
    Given the thread's provider can compact a conversation on request
    When the user chooses "Compact context" in the context window's details
    Then the provider is asked to compact the conversation
    And a provider that cannot compact on request is not offered "Compact context"

  @backlog @desktop
  Scenario Outline: Compacting from the context window's details waits until the thread is free
    Given the thread's provider can compact a conversation on request
    And <busy>
    When the user opens the context window's details
    Then "Compact context" cannot be chosen and says "Compacting is unavailable right now"

    Examples:
      | busy                                         |
      | the agent is working on a turn               |
      | an approval is waiting for the user          |
      | a question is waiting for the user           |
      | a proposed plan is waiting for the user      |
      | the environment cannot be reached            |
      | the thread's worktree is still being prepared |

  @backlog @desktop
  Scenario Outline: Compacting says why it cannot be offered at all
    Given <state>
    When the user looks at the control that compacts the conversation
    Then it cannot be chosen and says "<reason>"

    Examples:
      | state                                                    | reason                                      |
      | the draft has no project yet                             | Choose a project before compacting          |
      | the thread's provider cannot compact on request          | Compaction is unavailable for this provider |
      | the thread holds no message other than "/compact" itself | Compacting is unavailable right now         |

  @backlog @desktop
  Scenario Outline: Coming back to a long Claude conversation offers to continue with less context
    Given a Claude thread with <tokens> tokens in its context window that was last active <ago> ago
    When the user opens the thread
    Then the offer "Resume with less context" is <shown>

    Examples:
      | tokens  | ago        | shown                                          |
      | 100,000 | 70 minutes | shown, saying how many tokens come from earlier |
      | 99,999  | 3 hours    | not shown                                      |
      | 400,000 | 69 minutes | not shown                                      |

  @backlog @desktop
  Scenario: Only Claude threads are offered to continue with less context
    Given a Codex thread with 400,000 tokens in its context window that was last active 3 hours ago
    When the user opens the thread
    Then the offer "Resume with less context" is not shown

  @backlog @desktop
  Scenario Outline: The offer to continue with less context waits while the thread is busy
    Given a Claude thread that would be offered "Resume with less context"
    And <busy>
    Then the offer is not shown

    Examples:
      | busy                               |
      | the agent is working on a turn     |
      | a question is waiting for the user |

  @backlog @desktop
  Scenario: Compacting from the offer compacts the conversation
    Given a Claude thread shows the offer "Resume with less context"
    When the user chooses "Compact"
    Then Claude is asked to compact the conversation

  @backlog @desktop
  Scenario: Keeping the full history puts the offer away until the conversation moves on
    Given the Claude threads "Cart totals" and "Tax rounding" both show the offer "Resume with less context"
    When the user chooses "Keep full history" in "Cart totals"
    Then the offer is gone from "Cart totals" and still shown in "Tax rounding"
    When "Cart totals" runs another turn and again sits unused for 70 minutes
    Then the offer is shown in "Cart totals" again

  @backlog @desktop
  Scenario: Telling Claude never to ask about compacting also ends HAL-C2's offer
    Given Claude asked whether to compact before resuming and the user answered never to be asked again
    When the user later comes back to a long Claude conversation on that Claude instance
    Then the offer "Resume with less context" is not shown

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

  @backlog @desktop
  Scenario Outline: A message to Antigravity is held with the reason it cannot be sent
    Given the thread in "shop" runs on Antigravity
    And <state>
    When the user writes a message
    Then the message cannot be sent and the user is told "<reason>"

    Examples:
      | state                                                             | reason                                                              |
      | Antigravity is not installed                                      | Install Antigravity in provider settings before sending.            |
      | Antigravity is signed out                                         | Sign in to Antigravity in provider settings before sending.         |
      | no Antigravity model is chosen                                    | Choose an Antigravity model before sending.                         |
      | Antigravity is signed in and lists no models                      | Refresh Antigravity models in provider settings before sending.     |
      | Antigravity is ready and the thread's model has left its catalog  | That Antigravity model is no longer available. Choose another model. |

  @backlog @desktop
  Scenario Outline: A message to Antigravity is not held when only starting the turn can tell
    Given the thread in "shop" runs on Antigravity with a model chosen
    And <state>
    When the user writes a message
    Then the message can be sent

    Examples:
      | state                                                                              |
      | Antigravity has not checked its saved sign-in since the environment restarted      |
      | Antigravity reports an error and the thread's model is missing from its catalog    |
      | the thread uses Antigravity's default model and the catalog does not list it       |

  @backlog @desktop
  Scenario: Several notices above the composer show one at a time, the most pressing first
    Given the thread shows the error "Rate limited" and the answer to "/usage-limits"
    Then the error is the notice shown and the composer says there are other notices behind it
    When the user asks for the other notices
    Then the answer to "/usage-limits" is shown as well
    When the user presses Escape
    Then only the error is shown again

  @backlog @desktop
  Scenario: Dismissing the notice in front brings the next one forward
    Given the thread shows the error "Rate limited" and the answer to "/usage-limits"
    When the user dismisses the error
    Then the answer to "/usage-limits" is the notice shown
    And the composer no longer says there are other notices

  @backlog @desktop
  Scenario: What the agent is doing stays in front of every notice
    Given the thread says it is waiting on the background work "watch tests"
    And the thread shows the error "Rate limited"
    Then the notice about "watch tests" is the one shown and the error waits behind it
