# Sources:
#   https://github.com/pingdotgg/t3code/pull/27779
#   https://github.com/pingdotgg/t3code/pull/21460
#   https://github.com/pingdotgg/t3code/pull/29535
#   https://github.com/pingdotgg/t3code/pull/22661
#   https://github.com/pingdotgg/t3code/pull/29221
#   https://github.com/pingdotgg/t3code/pull/29877
#   https://github.com/pingdotgg/t3code/pull/26165
#   https://github.com/pingdotgg/t3code/pull/24734
#   https://github.com/pingdotgg/t3code/pull/27757
#   https://github.com/pingdotgg/t3code/pull/25230
#   https://github.com/pingdotgg/t3code/pull/23939
#   https://github.com/pingdotgg/t3code/pull/15672
#   https://github.com/pingdotgg/t3code/pull/19636
#   https://github.com/pingdotgg/t3code/pull/21007
#   https://github.com/pingdotgg/t3code/pull/22938
#   https://github.com/pingdotgg/t3code/pull/20446
#   https://github.com/pingdotgg/t3code/pull/20882
#   https://github.com/pingdotgg/t3code/pull/17922
#   https://github.com/pingdotgg/t3code/pull/16544
#   https://github.com/pingdotgg/t3code/pull/21103
#   https://github.com/pingdotgg/t3code/pull/16796
#   https://github.com/pingdotgg/t3code/pull/16145
#   https://github.com/pingdotgg/t3code/pull/16448
#   https://github.com/pingdotgg/t3code/pull/10606
#   https://github.com/pingdotgg/t3code/pull/18315
#   https://github.com/pingdotgg/t3code/pull/21507
#   https://github.com/pingdotgg/t3code/pull/21979
#   https://github.com/pingdotgg/t3code/pull/18561
#   https://github.com/pingdotgg/t3code/pull/19367
#   https://github.com/pingdotgg/t3code/pull/17134
#   https://github.com/pingdotgg/t3code/pull/19319
#   https://github.com/pingdotgg/t3code/pull/17414
#   https://github.com/pingdotgg/t3code/pull/17424
#   https://github.com/pingdotgg/t3code/pull/12469
#   https://github.com/pingdotgg/t3code/pull/14752
#   https://github.com/pingdotgg/t3code/pull/14744
#   https://github.com/pingdotgg/t3code/pull/16142
#   https://github.com/pingdotgg/t3code/pull/13651
#   https://github.com/pingdotgg/t3code/pull/12003
#   https://github.com/pingdotgg/t3code/pull/14198
#   https://github.com/pingdotgg/t3code/pull/13368
#   https://github.com/pingdotgg/t3code/pull/13328
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/providers-opencode.md
#   docs/internals/providers.md (OpenCode server per thread, full-access replies once)
#   apps/server-ex/lib/hal_c2/acp.ex (opencode acp, models split into subProvider)
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex, apps/server-ex/lib/hal_c2/acp/opencode.ex (rewind, fork)
#   apps/server/src/provider/Layers/OpenCodeProvider.ts, apps/server/src/provider/Drivers/OpenCodeDriver.ts
#   apps/server/src/provider/opencodeRuntime.ts, apps/server/src/provider/OpenCodeServerOwner.ts
#   apps/server/src/orchestration-v2/Adapters/OpenCodeAdapterV2.ts
#   apps/server-ex/priv/model-manifest.json (compatibility: opencode ranges)
#   apps/server/src/provider/providerCompatibility.ts
#   apps/server/src/provider/Layers/openCodeUsageLimits.ts, apps/server/src/textGeneration/OpenCodeTextGeneration.ts
#   https://github.com/pingdotgg/t3code/pull/14978
#   https://github.com/pingdotgg/t3code/pull/22596
#   https://github.com/pingdotgg/t3code/pull/26182
#   https://github.com/pingdotgg/t3code/pull/26302
#   https://github.com/pingdotgg/t3code/pull/23591
#   https://github.com/pingdotgg/t3code/pull/23598
#   https://github.com/pingdotgg/t3code/pull/23270
#   https://github.com/pingdotgg/t3code/pull/28294
#   https://github.com/pingdotgg/t3code/pull/28372
#   https://github.com/pingdotgg/t3code/pull/29301
#   https://github.com/pingdotgg/t3code/pull/29762
#   https://github.com/pingdotgg/t3code/pull/30643
#   https://github.com/pingdotgg/t3code/pull/30201
#   https://github.com/pingdotgg/t3code/pull/29326
#   https://github.com/pingdotgg/t3code/pull/29765
#   https://github.com/pingdotgg/t3code/pull/29824

@plugin-opencode @mc
Feature: OpenCode
  OpenCode reaches the models of every upstream provider it is connected to. The MC
  runs OpenCode locally, or connects to an OpenCode server the user already runs.

  Background:
    Given a connected environment with the project "shop"

  Scenario: OpenCode does nothing until the user enables it
    Given OpenCode is installed but not enabled
    When the MC starts
    Then no OpenCode process is started

  Scenario: OpenCode lists the models of its connected providers
    Given OpenCode is connected to OpenAI and Anthropic
    When the user enables OpenCode
    Then the model picker offers the OpenAI and Anthropic models through OpenCode
    And each model is grouped under its upstream provider

  # Upstream #16448: a freshly started OpenCode server's first, partial model list was cached;
  # the catalog now settles first.
  @backlog
  Scenario: OpenCode's model list is not cut short by a server still starting
    Given a newly started OpenCode server first reports only some of its models
    When the MC lists OpenCode's models
    Then every model OpenCode lists once it settles is offered without a refresh

  # Upstream #17424: OpenCode 2 lost the provider beside each model, so one model offered by
  # two subscriptions read the same twice.
  @backlog @mc @shared @mobile @priority-low
  Scenario Outline: A model offered by two OpenCode providers says which one it bills
    Given OpenCode 2 is connected to <provider>, which names itself "<name>" and lists "Step 5 Preview Free"
    When the user opens the model picker
    Then "Step 5 Preview Free" from it reads "<label>"
    And searching the picker for "<search>" finds it

    Examples:
      | provider          | name         | label                                       | search       |
      | OpenCode Zen      | OpenCode Zen | OpenCode Zen                                | Zen          |
      | OpenRouter        | OpenRouter   | OpenCode · OpenRouter                       | OpenRouter   |
      | OpenCode itself   | OpenCode     | OpenCode                                    | Step 5       |
      | OpenCode Go       |              | OpenCode · opencode-go, until it is named   | opencode-go  |

  @backlog @mc
  Scenario: OpenCode's models are still listed when it cannot name its providers
    Given OpenCode 2 lists its models but its list of providers cannot be read
    When the MC checks OpenCode's status
    Then its models are offered, each with its provider's id

  # Upstream #23939: a failed version check or model list left OpenCode unusable until the user
  # refreshed providers.
  @backlog @mc
  Scenario: An OpenCode whose models could not be read is checked again until it recovers
    Given an installed and enabled OpenCode whose model list could not be read
    When the provider health check interval passes
    Then the MC reads OpenCode's models again, each interval, until they are listed
    And the reason each read failed is in the MC's log

  @backlog @mc @priority-low
  Scenario: An OpenCode server that rejects the MC's password is not retried
    Given an OpenCode server refuses the MC's password
    Then OpenCode is shown as signed out
    And the MC does not keep retrying it in the background

  Scenario: OpenCode is only offered when the opencode command is installed
    Given the opencode command is not installed on the MC
    When the user opens the list of agents to enable
    Then OpenCode is not offered

  Scenario: OpenCode permission requests become approvals
    Given the thread runs OpenCode with approval required
    When OpenCode asks to edit a file
    Then the user is asked to approve it

  Scenario: OpenCode in full access is never asked about anything
    Given the thread runs OpenCode with full access
    When OpenCode asks to run a command
    Then the request is granted without asking the user

  Scenario: OpenCode writes thread titles and commit messages
    Given OpenCode is picked for text generation
    When a new thread needs a title
    Then OpenCode writes it with every tool refused

  # Upstream #23598: the 3-minute limit started only after OpenCode answered the session and prompt.
  # Upstream #28372: OpenCode 1.x had no limit at all and kept generating after the MC gave up.
  @backlog
  Scenario: An OpenCode title that never comes back fails within three minutes
    Given OpenCode is picked for text generation
    And OpenCode accepts the request but never answers it
    When a new thread needs a title
    Then within three minutes the title fails with "OpenCode did not finish generating in time."
    And OpenCode is told to stop generating it

  # Upstream #23598: the interrupt after a timeout had no deadline of its own.
  @backlog @priority-low
  Scenario: An OpenCode generation that times out is not held up by a stalled interrupt
    Given an OpenCode title generation reached its three-minute limit
    And OpenCode does not answer the request to stop it
    When five more seconds pass
    Then the title has failed with "OpenCode did not finish generating in time."

  # Upstream #23591: a reconnect mid-reply replaced the text already streamed with what came after.
  @backlog @priority-high
  Scenario: An OpenCode reply keeps its streamed text across an event stream reconnect
    Given OpenCode has streamed one paragraph and part of a second
    When OpenCode's event stream drops and the MC reconnects
    And OpenCode streams the rest of the second paragraph
    Then the reply shows both whole paragraphs

  # Upstream #28294: each OpenCode 1.x title, branch name or commit message left a "T3 Code"
  # session behind in the user's OpenCode history.
  @backlog @priority-low
  Scenario Outline: An OpenCode text generation leaves no session behind
    Given OpenCode is picked for text generation
    When OpenCode writes a commit message and <ends>
    Then OpenCode's session history has no session for that generation

    Examples:
      | ends              |
      | it succeeds       |
      | it fails          |
      | the user cancels it |

  # Upstream #10606: a cancelled OpenCode text generation kept running; it is now aborted.
  @backlog @priority-low
  Scenario: A cancelled OpenCode title or commit message stops OpenCode generating it
    Given OpenCode is writing a commit message
    When the user cancels it
    Then OpenCode stops generating it
    And another generation on the same server still finishes

  # Upstream #29877: a failed OpenCode 1.x generation copied the model provider's raw text into
  # its error, sometimes only "<none>"; known failures now get fixed explanations.
  @backlog @priority-low
  Scenario Outline: An OpenCode text generation the model provider fails says why in plain words
    Given OpenCode 1.x is picked for text generation
    When OpenCode writes a commit message and the model provider fails with <failure>
    Then the commit message fails with "<explanation>"
    And the error carries none of the model provider's own text

    Examples:
      | failure                    | explanation                                                                                     |
      | a sign-in error            | The model provider rejected the credentials. Check the provider's sign-in or API key in OpenCode. |
      | HTTP 403                   | The model provider rejected the credentials. Check the provider's sign-in or API key in OpenCode. |
      | HTTP 429                   | The model provider's usage or rate limit was reached. Try again later.                          |
      | a context overflow         | The prompt is too long for the selected model's context window.                                 |
      | an aborted message         | OpenCode stopped the generation.                                                                |
      | HTTP 502                   | The model provider failed the request (HTTP 502).                                               |
      | an error body of "<none>"  | OpenCode could not generate the text.                                                           |

  Scenario: Refreshing providers picks up a changed OpenCode login
    Given the user connected a new upstream provider in OpenCode
    When the user refreshes provider status
    Then the new provider's models are offered

  Scenario: OpenCode older than the supported version is refused
    Given the installed OpenCode is older than 1.14.19
    When the user enables OpenCode
    Then OpenCode is shown as too old with the version to upgrade to

  @backlog
  Scenario: OpenCode can use an external server
    Given the user runs an OpenCode server elsewhere
    When the user sets its URL and password on the OpenCode instance
    Then OpenCode threads run on that server

  # Upstream #25230: health checks and session requests left out the configured password.
  @backlog @priority-high
  Scenario: A password-protected OpenCode server is checked and used with its password
    Given the OpenCode instance points at a server that requires the password the user set
    When the user starts an OpenCode thread
    Then the server's health check and the thread's session both use that password
    And the thread runs
    But a server the user set up elsewhere is never sent the MC's own OpenCode password

  # Upstream #20446: the OpenCode server password moves to the secret store and is never read back.
  @priority-high
  Scenario: The external OpenCode server's password is kept as a secret
    Given the user saved a password for the external OpenCode server
    When a client reads the settings or is told they changed
    Then the password is not in what it receives, only that one is stored
    And the password is not written to the settings file
    And saving other settings keeps the stored password

  # Upstream #20446: a password saved in plain text by an older version moves to the secret store.
  @priority-high
  Scenario: An OpenCode password saved in plain text moves to the secret store
    Given the settings file holds the OpenCode server password in plain text
    When the MC reads the settings
    Then the password is kept in the secret store and removed from the settings file
    And OpenCode still reaches the external server with it

  Scenario: A wrong password for an external OpenCode server is explained
    Given the OpenCode instance points at a server with the wrong password
    When the user refreshes provider status
    Then OpenCode says the server rejected authentication and to check the URL and password

  Scenario: An unreachable external OpenCode server is explained
    Given the OpenCode instance points at a server that is not running
    When the user refreshes provider status
    Then OpenCode says it could not reach the server at that URL

  Scenario: Clearing the server URL goes back to a local OpenCode
    Given the OpenCode instance uses an external server
    When the user clears the server URL
    Then OpenCode threads run on a local OpenCode again

  Scenario: OpenCode with no connected providers is a warning
    Given OpenCode has no upstream providers connected
    When the user refreshes provider status
    Then OpenCode is shown with a warning that no providers are connected

  # Health states of OpenCodeProvider.ts (probeFailureMessage, version probe).
  @backlog
  Scenario Outline: A local OpenCode that cannot run explains why
    Given the opencode command fails with <failure>
    When the user refreshes provider status
    Then OpenCode is shown with the message "<message>"

    Examples:
      | failure                     | message                                                                                                                      |
      | an invalid code signature   | macOS killed the OpenCode process due to an invalid code signature. The binary may be corrupted — try reinstalling OpenCode. |
      | a macOS quarantine block    | macOS is blocking the OpenCode binary (quarantine). Run `xattr -d com.apple.quarantine $(which opencode)` to fix this.       |
      | the command not being found | OpenCode CLI (`opencode`) is not installed or not on PATH.                                                                   |

  # Upstream #17922: OpenCode starts are retried briefly when the shared database is locked.
  @backlog
  Scenario: An OpenCode start that finds its database locked is tried again
    Given another OpenCode is holding the shared database
    When an OpenCode session starts and its database is locked
    Then the start is tried again up to three times, a quarter of a second apart
    And a start that fails on its configuration is not retried

  @backlog @priority-low
  Scenario: An OpenCode whose version cannot be read is refused
    Given the opencode command prints no version
    When the user refreshes provider status
    Then OpenCode says it could not determine the version and that 1.14.19 or newer is required

  @backlog @priority-low
  Scenario: An OpenCode version check that does not finish is reported
    Given the opencode version check does not finish in time
    When the user refreshes provider status
    Then OpenCode says its CLI version probe timed out

  # Upstream #16544: a slow OpenCode version check gets ten seconds.
  @backlog
  Scenario: A slow OpenCode version check is given ten seconds
    Given OpenCode runs through a wrapper that takes six seconds to report its version
    When the MC checks OpenCode
    Then OpenCode is shown as available

  @backlog @priority-low
  Scenario: A disabled OpenCode with a server URL says the URL is kept
    Given OpenCode is turned off and its instance has a server URL
    When the user opens the provider list
    Then OpenCode is shown with the message "OpenCode is disabled in HAL-C2 settings. A server URL is configured."

  @backlog @priority-low
  Scenario: An OpenCode that has not been checked yet says so
    Given the MC has just started and has not checked OpenCode yet
    When the user opens the provider list
    Then OpenCode is shown with a warning that its status has not been checked in this session yet

  Scenario Outline: OpenCode approvals follow the access mode
    Given the thread runs OpenCode in <mode>
    When OpenCode wants to <action>
    Then it is <outcome>

    Examples:
      | mode              | action                  | outcome                   |
      | approval required | read a source file      | allowed without asking    |
      | approval required | read the .env file      | asked for approval        |
      | approval required | read .env.example       | allowed without asking    |
      | approval required | edit a file             | asked for approval        |
      | auto-accept edits | edit a file             | allowed without asking    |
      | auto-accept edits | run a command           | asked for approval        |
      | full access       | work outside the project| allowed without asking    |

  # Upstream #26182: an OpenCode session kept the rules it was created with, so a thread moved
  # from full access to approval required was never asked. #26302 does the same for subagents,
  # which keep their own limits such as not delegating further.
  # Upstream #26302: subagent sessions follow the thread's access mode too, keeping their own limits.
  @backlog @priority-high
  Scenario Outline: Changing the access mode of an OpenCode thread changes what its sessions are asked
    Given the thread started OpenCode in full access and <session> exists
    When the user changes the thread to approval required and sends a message
    Then OpenCode is asked for approval before <session> runs a command
    And a subagent session still cannot start subagents of its own

    Examples:
      | session                                         |
      | the thread's own session                        |
      | a subagent session the thread started           |
      | a subagent session the thread later resumes     |

  Scenario Outline: OpenCode approval decisions
    Given OpenCode asked to run a command
    When the user answers <decision>
    Then OpenCode <result>

    Examples:
      | decision              | result                                          |
      | allow once            | runs it this time only                          |
      | allow for the session | runs matching commands without asking again     |
      | decline               | does not run it                                 |

  Scenario: OpenCode reasoning variants and agents are offered as options
    When the user opens the options for an OpenCode model
    Then the model's reasoning variants are offered
    And OpenCode's primary agents are offered with "build" as the default

  Scenario: OpenCode plan mode uses OpenCode's plan agent
    When the user switches an OpenCode thread to plan mode
    Then the turn runs with OpenCode's plan agent

  Scenario: An OpenCode turn can be steered while it runs
    Given an OpenCode turn is running
    When the user sends a follow-up message
    Then OpenCode receives the message during the running turn

  # Upstream #23270: a steer to OpenCode 1.x sent only the text, so the rest of the turn ran with
  # OpenCode's default agent, no reasoning variant and none of HAL-C2's instructions.
  @backlog @priority-high
  Scenario: A steer keeps the OpenCode turn's agent, variant and instructions
    Given an OpenCode turn is running with the agent "reviewer" and the "high" variant in plan mode
    When the user steers the OpenCode turn with "check the tests too"
    Then the rest of the turn still runs with the agent "reviewer" and the "high" variant
    And OpenCode still has HAL-C2's plan mode instructions

  Scenario: A message sent as an OpenCode turn ends is answered in that turn
    Given an OpenCode turn is running that ends as it is steered
    When the user sends a follow-up message
    Then OpenCode's answer to the message is the turn's

  Scenario: A message OpenCode answers after the turn's loop failed ends the turn with its answer
    Given an OpenCode turn is running that fails as it is steered
    When the user sends a follow-up message
    Then OpenCode's answer to the message is the turn's

  Scenario: A message whose own OpenCode loop fails fails the turn
    Given an OpenCode turn is running that ends as it is steered
    When the user steers the OpenCode turn with "look here, its loop fails"
    Then the OpenCode turn fails with "The steer's loop failed"

  Scenario: Stopping an OpenCode turn ends it while a message sent into it goes unanswered
    Given an OpenCode turn is running that ends as it is steered
    And the user steers the OpenCode turn with "this is never answered"
    And the user steers the OpenCode turn with "this keeps working"
    And OpenCode answers the turn's prompt and the message in a loop of its own
    When the user stops the turn
    Then the OpenCode turn is interrupted

  # Upstream #29762: OpenCode 1.x rewrites a tool it stopped as an error, so every running command,
  # edit or subagent read as failed, and a stopped edit showed "Tool execution aborted" as its diff.
  @priority-high
  Scenario Outline: A <tool> running when an OpenCode turn is stopped shows as interrupted
    Given an OpenCode 1 turn is running <tool>
    When the user stops the turn
    Then <tool> shows as interrupted, not failed
    And no error text is shown as its output or diff

    Examples:
      | tool                |
      | a command           |
      | a file edit         |
      | a subagent task     |

  # Upstream #30643: an edit replacing text with nothing, or with only whitespace, lost its before
  # and after text, so its diff had no after state.
  @backlog @priority-low
  Scenario Outline: An OpenCode edit that <change> keeps its before and after text
    Given an OpenCode turn made an edit that <change>
    When the user opens the edit's diff
    Then the diff shows the text before and the text after, empty or blank as it is

    Examples:
      | change                                |
      | deletes text                          |
      | replaces text with only spaces        |
      | writes an empty file                  |

  Scenario: A running OpenCode command shows what it runs and its output so far
    Given an OpenCode turn is running
    Then the running command reads "ls" with the output "a.txt"

  Scenario: Reverting an OpenCode turn rewinds OpenCode's session
    Given an OpenCode thread with three turns
    When the user reverts to the end of the first turn
    Then OpenCode's session is rewound to that point

  Scenario: Forking an OpenCode thread forks OpenCode's session
    Given an OpenCode thread with three turns
    When the user forks from the second turn
    Then the new thread continues from a fork of OpenCode's session

  # Upstream #29221: OpenCode 2.2.5 compactions lack a field the bundled client required, so every
  # send of a fork from a compacted thread failed with an empty error.
  @priority-high
  Scenario: Forking an OpenCode thread whose session was compacted forks OpenCode's session
    Given an OpenCode 2.2 thread with three turns whose session OpenCode compacted
    When the user forks from the second turn and sends a message
    Then the new thread continues from a fork of OpenCode's session

  # Upstream #22661: OpenCode 2.1 compactions lack a field the bundled client required, so reading
  # the session's history failed before the revert was asked for.
  @priority-high
  Scenario: Reverting an OpenCode 2.1 thread whose session was compacted rewinds OpenCode's session
    Given an OpenCode 2.1 thread with three turns whose session OpenCode compacted
    When the user reverts to the end of the first turn
    Then OpenCode's session is rewound to that point

  Scenario: OpenCode Go limits are shown for a local OpenCode
    Given OpenCode is signed in to OpenCode Go and runs locally
    When the user opens the limits view
    Then OpenCode Go shows its session, weekly and monthly windows

  # Upstream #27757: one timed-out usage read at startup left Go limits unavailable until restart,
  # though OpenCode itself was ready and signed in.
  @backlog @priority-low
  Scenario: OpenCode Go limits come back after a usage read times out at startup
    Given OpenCode is signed in to OpenCode Go and runs locally
    And reading its Go usage timed out when OpenCode started
    When the next health check comes round
    Then the Go usage is read again without restarting OpenCode
    And OpenCode Go shows its session, weekly and monthly windows

  # Upstream #26165: a Go key replaced in OpenCode 2 lived only in its credential store, so usage used the old key.
  @backlog @priority-low
  Scenario: OpenCode Go limits use a Go key replaced in OpenCode 2
    Given a local OpenCode 2 whose Go key was replaced after it imported "auth.json"
    And the key left in "auth.json" has expired
    When the user opens the limits view
    Then OpenCode Go shows its session, weekly and monthly windows
    And the user is not told "OpenCode Go could not read usage."

  # Upstream #21007: OpenCode 2 running Go through a Console API key showed "could not read usage".
  @backlog @priority-low
  Scenario: OpenCode Go limits are read through a connected Console API key
    Given a local OpenCode runs Go through a connected Console API key
    And its separate OpenCode Go key has expired
    When the user opens the limits view
    Then OpenCode Go shows its windows read through the Console API key

  # Upstream #19636: a probe timeout cached an empty command list for good.
  @backlog @priority-low
  Scenario: OpenCode's workspace commands are read again after a probe times out
    Given OpenCode's workspace command list did not arrive within ten seconds
    When the MC checks OpenCode again
    Then the commands it read before are still offered
    And the command list is asked for again

  # Upstream #15672: OpenCode 2 waiting to retry a failed model request looked silently busy.
  @backlog
  Scenario: An OpenCode turn waiting to retry its model request says so
    Given an OpenCode turn is running
    When OpenCode schedules a retry of a failed model request
    Then the turn shows one retry row that updates with each attempt
    And the row settles when the request recovers, fails or is interrupted

  # Upstream #18315: OpenCode's quota and rate-limit stops read as provider errors; they are now
  # usage limits, with no reset time made up.
  @backlog
  Scenario Outline: An OpenCode stop for <reason> shows as a usage limit
    Given an OpenCode turn is running
    When OpenCode stops it for <reason>
    Then the turn shows it hit a usage limit, not a provider error
    And no reset time is given

    Examples:
      | reason             |
      | an exhausted quota |
      | a rate limit       |

  # Upstream #29301: a spent Claude plan used through OpenCode's Claude provider failed as a plain
  # provider error, so Snooze until reset and auto-resume never turned on.
  @backlog
  Scenario Outline: A Claude plan limit reached through OpenCode is a usage limit
    Given an OpenCode turn is running on OpenCode's Claude provider
    When OpenCode fails it with "<message>"
    Then the turn shows it hit a usage limit <reset>

    Examples:
      | message                                                                          | reset                                 |
      | You've hit your weekly limit · resets 9pm Resets at 2026-11-02T20:00:00.000Z.     | that resets at 2026-11-02T20:00:00Z   |
      | You've hit your weekly limit · resets 9pm                                         | with no reset time given              |

  # Upstream #22596: a quota stop that is a payment problem (HTTP 402) is not a usage limit.
  @backlog
  Scenario Outline: An OpenCode quota stop shows as a usage limit only when it is one
    Given an OpenCode turn is running
    When OpenCode stops it for its quota with status <status> and the message "<message>"
    Then the turn shows <shown>

    Examples:
      | status | message                      | shown                                              |
      | 429    | Too many requests            | it hit a usage limit                               |
      | 402    | Add credits to keep going    | a provider error saying "Add credits to keep going" |

  Scenario: OpenCode Go limits are unsupported on an external server
    Given the OpenCode instance uses an external server
    When the user opens the limits view
    Then OpenCode's limits are shown as unsupported

  Scenario: An existing thread keeps its OpenCode model when it leaves the catalog
    Given an OpenCode thread uses a model that OpenCode no longer lists
    When the user opens the thread
    Then the thread still shows its model
    And if OpenCode rejects the model the user can pick another and retry

  @backlog
  Scenario: Deleting a thread whose OpenCode turn was interrupted before its message was sent
    Given the user sent a message to an OpenCode thread
    And the turn was interrupted before OpenCode received the message
    When the user deletes the thread
    Then the thread is deleted
    And the user can start a new thread straight away

  Scenario: An OpenCode older than the supported range is flagged as known broken
    Given OpenCode 1.14.10 is installed
    When the MC checks its providers
    Then OpenCode is reported as a known broken version for this HAL-C2 release
    And the user is told to use OpenCode 1.14.19 or newer

  @backlog @priority-low
  Scenario: An OpenCode 2 or later is flagged as known broken with 1.14.19 to downgrade to
    Given OpenCode 2.0.3 is installed
    When the MC checks its providers
    Then OpenCode is reported as a known broken version for this HAL-C2 release
    And the user is told to downgrade to OpenCode 1.14.19

  @backlog @shared @priority-low
  Scenario: A broken OpenCode version's notice is shown even when OpenCode also reports an error
    Given OpenCode 2.0.3 is installed and its inventory times out
    When the user opens the provider settings
    Then the compatibility notice with the downgrade advice is shown before the timeout
    And an unauthenticated OpenCode still shows its authentication error

  Scenario: OpenCode in the supported range carries no compatibility warning
    Given OpenCode 1.14.19 is installed
    When the MC checks its providers
    Then OpenCode carries no compatibility warning

  # OpenCode has no background tasks; its subagents finish inside the turn.
  Scenario: A command OpenCode leaves running ends with its turn
    When OpenCode ends a turn with a command still running
    Then the command it left running ends with the turn

  @backlog @priority-low
  Scenario: A current OpenCode server is accepted as ready
    Given the MC starts an OpenCode server of the supported version
    When OpenCode reports that the server is ready
    Then the first prompt is sent to it

  Scenario: An OpenCode event stream that ends fails the turn
    Given an OpenCode turn is streaming
    When the event stream ends unexpectedly
    Then the turn fails saying OpenCode exited unexpectedly
    And the thread takes the next message

  # Upstream #30201: a server that accepted the event request but never answered it held the session
  # open for about five minutes, since the 45-second silence limit starts only after an answer.
  @backlog
  Scenario: An OpenCode event stream that is never answered fails within 10 seconds
    Given OpenCode 2 takes the event stream request and never answers it
    When the MC opens an OpenCode session or reconnects its event stream
    Then the attempt fails after 10 seconds
    And the session is cleaned up or reconnects as it would after any failed attempt

  @backlog
  Scenario: An idle report for an earlier prompt does not end a later run
    Given two OpenCode prompts were sent close together
    When OpenCode reports the first prompt idle
    Then the second run is still working

  @backlog
  Scenario: Stopping an OpenCode run stops its descendant processes
    Given an OpenCode run has descendant processes
    When the user stops the run
    Then the descendant processes are asked to stop
    And the MC reports any that could not be stopped

  Scenario: An OpenCode server whose owner crashed is stopped
    Given an OpenCode server was started for a thread
    When the provider process that owned it crashes
    Then the OpenCode server is stopped
    And no OpenCode process stays owned by the thread

  # Upstream #21103: on Windows npm's shim is bypassed so OpenCode's server is a direct child
  # that the system ends when the server is killed, hard kill included.
  @backlog @priority-low
  Scenario: An OpenCode server does not outlive a killed MC
    Given the MC started an OpenCode server installed through npm
    When the MC is killed without shutting down
    Then the OpenCode server stops too

  # OpenCodeServerOwner.ts: one lazy local server per instance, shared by status checks,
  # model listing and text generation, stopped 30 seconds after its last user.
  @backlog
  Scenario: Status checks and title writing share one local OpenCode server
    Given OpenCode runs locally
    When the MC refreshes OpenCode's status and a thread title is written at the same time
    Then both use the same OpenCode server process

  @backlog @priority-low
  Scenario: An OpenCode server nobody uses is stopped after 30 seconds
    Given the MC started a local OpenCode server for a status check
    When 30 seconds pass without anything using it
    Then the OpenCode server is stopped

  @backlog @priority-low
  Scenario: Using the OpenCode server again keeps it from being stopped
    Given a local OpenCode server is waiting to be stopped as idle
    When a thread title needs it before the 30 seconds pass
    Then the server is kept and used

  @backlog @priority-low
  Scenario: A local OpenCode server that exited is started again on next use
    Given the local OpenCode server exited on its own
    When the MC refreshes OpenCode's status
    Then a new OpenCode server is started for it

  # Upstream #19367: a tool killed for memory no longer stops every OpenCode thread.
  @backlog @priority-high
  Scenario: A tool killed for using too much memory stops only its own thread's turn
    Given two threads run on the same local OpenCode server
    When a tool in the first thread is killed for using too much memory
    Then the first thread's turn says the tool was killed
    And the second thread keeps working

  # OpenCodeAdapterV2.ts: OpenCode has no sandbox, so its permission rules are the only guard.
  @backlog
  Scenario Outline: OpenCode tools that never need approval
    Given the thread runs OpenCode in approval required
    When OpenCode wants to <action>
    Then it is allowed without asking

    Examples:
      | action                       |
      | ask the user a question      |
      | search file names            |
      | search file contents         |
      | use the language server      |
      | update its to-do list        |
      | start a subagent             |
      | load a skill                 |

  @backlog
  Scenario Outline: OpenCode running where nobody can approve
    Given an OpenCode run that no user can answer and that <network> use the network
    When OpenCode wants to <action>
    Then it is <outcome>

    Examples:
      | network | action                      | outcome |
      | may     | read the .env file          | denied  |
      | may     | read .env.example           | allowed |
      | may     | run a command               | denied  |
      | may     | fetch a web page            | allowed |
      | may not | fetch a web page            | denied  |
      | may not | search the web              | denied  |

  @backlog
  Scenario: OpenCode running where nobody can approve may use the extra folders it was given
    Given an OpenCode run that no user can answer may write to the project and to one folder outside it
    When OpenCode works in that folder
    Then it is allowed
    And work in any other folder outside the project is denied

  @backlog
  Scenario: An OpenCode subagent works under the thread's access mode
    Given the thread runs OpenCode in approval required
    When an OpenCode subagent wants to edit a file
    Then the user is asked for approval in the parent thread
    And the subagent keeps the limits its own agent adds

  @backlog
  Scenario: A request from a subagent OpenCode has not announced yet is not lost
    Given an OpenCode subagent asks for approval before OpenCode says which run it belongs to
    When OpenCode names the subagent's parent shortly after
    Then the approval reaches the thread that started the subagent

  @backlog
  Scenario: The question OpenCode asks is not also shown as a tool call
    When OpenCode asks the user a question
    Then the thread shows the question to answer
    And no separate tool entry for it

  # Upstream #20882: OpenCode's multi-select and custom-answer flags are kept
  @backlog @shared
  Scenario: An OpenCode question keeps how it may be answered
    Given OpenCode asks a question that allows several answers and no typed answer
    When the user answers it
    Then several options can be picked
    And no typed answer is offered

  @backlog
  Scenario Outline: Answering an OpenCode request is refused when it cannot be applied
    When a client <answers>
    Then the answer is refused with "<message>"

    Examples:
      | answers                                         | message                                          |
      | answers the request "r9" that is not open       | No pending OpenCode request r9                   |
      | answers the question "q1" without any answers   | OpenCode question request q1 requires answers    |
      | answers the approval "a1" without a decision    | OpenCode approval request a1 requires a decision |

  @backlog
  Scenario: An answer OpenCode does not take within 10 seconds is given up
    Given OpenCode asked for approval
    When the user's answer is not accepted by OpenCode within 10 seconds
    Then sending the answer is abandoned
    And the user is told the answer did not go through

  @backlog
  Scenario: A request answered once is not raised again
    Given the user answered an OpenCode approval
    When OpenCode repeats the same request after its event stream reconnects
    Then the thread does not ask again

  @backlog
  Scenario: An OpenCode slash command runs as OpenCode's own command
    Given OpenCode offers the command "/review"
    When the user sends "/review the last change" to an OpenCode thread
    Then OpenCode runs its "review" command with "the last change"

  # Upstream #29765: a custom command in a subfolder, such as "git/commit", was sent to the model as
  # plain text, because a command name could not hold a "/".
  @backlog
  Scenario: An OpenCode command from a subfolder runs as OpenCode's own command
    Given OpenCode offers the command "/git/commit" from ".opencode/command/git/commit.md"
    When the user sends "/git/commit staged changes" to an OpenCode thread
    Then OpenCode runs its "git/commit" command with "staged changes"
    And a message starting with a file path such as "/Users/me/file.ts explain" is still sent as a message

  @backlog
  Scenario Outline: A slash message OpenCode cannot run as a command is sent as a message
    Given <situation>
    When the user sends "/review the last change" to an OpenCode thread
    Then OpenCode receives it as an ordinary message

    Examples:
      | situation                                                  |
      | OpenCode offers no command named "/review"                 |
      | OpenCode does not list its commands within 10 seconds      |
      | listing OpenCode's commands fails                          |

  @backlog
  Scenario: An OpenCode command that never starts fails the turn
    Given OpenCode offers the command "/review"
    When the user sends "/review" and OpenCode does not start it within 10 seconds
    Then the turn fails saying "OpenCode command admission did not complete within 10 seconds."

  @backlog
  Scenario: Sending /compact summarizes the OpenCode session
    When the user sends "/compact" by itself to an OpenCode thread
    Then OpenCode summarizes its session
    And the work log shows "Context compacted" once

  @backlog
  Scenario: An OpenCode summary that fails fails the turn
    When the user sends "/compact" by itself and OpenCode cannot summarize the session
    Then the turn fails with OpenCode's reason

  @backlog
  Scenario: OpenCode compacting on its own is shown once per turn
    When OpenCode compacts its session by itself during a turn
    Then the work log shows "Context compacted" once for that turn

  @backlog
  Scenario Outline: OpenCode's token usage says how complete it is
    When an OpenCode turn finishes and <situation>
    Then the turn's token usage is reported as <completeness>

    Examples:
      | situation                                             | completeness |
      | every step reported its tokens                        | complete     |
      | the event stream reconnected during the turn          | partial      |
      | OpenCode reported no tokens                           | unavailable  |

  @backlog @priority-low
  Scenario: A step's tokens are counted once
    When OpenCode reports the tokens of one step several times
    Then the turn's token usage counts that step once

  @backlog
  Scenario Outline: An OpenCode turn that cannot start says why
    When <attempt>
    Then it is refused with "<message>"

    Examples:
      | attempt                                                              | message                                                                                       |
      | a turn is sent with no text and no usable attachment                 | OpenCode turns require text or at least one valid attachment                                  |
      | a turn asks for the model "sonnet"                                   | OpenCode model 'sonnet' must use provider/model format                                        |
      | a steer is sent with no text and no attachment                       | OpenCode steering requires text or an attachment                                              |
      | a turn is sent after the event stream ended                          | OpenCode event stream has ended; reconnect the provider session before starting another turn. |

  # Upstream #19319: OpenCode passes text files other than plain text to the model API, which refuses them.
  @backlog
  Scenario Outline: A text attachment OpenCode cannot pass on is given to it by path
    When the user sends an OpenCode turn with the attachment "<file>"
    Then the turn runs and the prompt names the file's path instead of attaching it
    But a plain text file is still attached as a file

    Examples:
      | file       |
      | page.html  |
      | notes.md   |
      | data.csv   |
      | style.css  |

  # Upstream #16145: OpenCode turns and steers got saved images only as paths; a local OpenCode
  # now receives them as files, with the path kept in the prompt.
  @backlog
  Scenario Outline: An image sent to a local OpenCode reaches the model as an image
    When the user <sends> with an attached image
    Then OpenCode receives the image as a file
    And the prompt still names the image's path

    Examples:
      | sends                          |
      | sends an OpenCode turn         |
      | steers a running OpenCode turn |

  # Upstream #16145: external servers and missing or unsupported files keep the path only.
  @backlog
  Scenario: An image sent to an external OpenCode server is named by its path only
    Given the OpenCode instance uses an external server
    When the user sends an OpenCode turn with an attached image
    Then the prompt names the image's path and attaches nothing

  # Upstream #16145: a Stop that lands while an image steer is being prepared keeps the turn stopped.
  @backlog @priority-low
  Scenario: Stopping while an image steer is prepared leaves the turn stopped
    Given an OpenCode turn is running
    When the user steers it with an attached image and stops the turn before the steer is sent
    Then the steer is not sent
    And the turn shows as stopped, not completed, and does not run the steer afterwards

  @backlog
  Scenario: An OpenCode server that exits says its exit code
    Given an OpenCode turn is running on a local server
    When the OpenCode server exits with code 1
    Then the turn fails saying "OpenCode server exited unexpectedly (1)."

  @backlog
  Scenario: An OpenCode failure that names no session fails every running turn
    Given two OpenCode turns are running on one server
    When OpenCode reports an error without saying which session it belongs to
    Then both turns fail with that error

  @backlog @priority-low
  Scenario: An OpenCode failure without details gets a plain message
    When OpenCode reports that a session failed without saying why
    Then the turn fails saying "OpenCode session failed without an error payload."

  # Upstream #24734: a model provider's unreadable error page showed as "<none>".
  @backlog @priority-low
  Scenario: An OpenCode failure from an error page names the page and its status
    Given an OpenCode turn is running
    When OpenCode reports a provider error with no message, status 502 and an HTML page titled "Bad gateway"
    Then the turn fails naming "Bad gateway" and status 502
    And the failure is not shown as "<none>"
    And a provider error with a message still shows that message

  @backlog
  Scenario: An OpenCode timeout without a message still fails the turn readably
    Given an OpenCode turn is running
    When the request to OpenCode times out with an error that carries no message
    Then the turn fails with a readable error instead of the MC failing to describe it

  Scenario: A stopped OpenCode turn shows as stopped, not failed
    Given an OpenCode turn is running
    When the user stops the turn and OpenCode reports it aborted
    Then the turn is shown as interrupted

  @backlog
  Scenario Outline: Stopping an OpenCode turn that OpenCode does not stop
    Given an OpenCode turn is running
    When the user stops the turn and <situation>
    Then <outcome>

    Examples:
      | situation                                             | outcome                                                    |
      | OpenCode says the turn had already finished           | the stop succeeds                                          |
      | OpenCode does not answer the stop within 10 seconds   | the stop fails and the turn is not shown as interrupted    |
      | OpenCode refuses the stop while the turn still runs   | the stop fails and the turn is not shown as interrupted    |

  @backlog @priority-low
  Scenario: Stopping OpenCode's subagents is bounded
    Given an OpenCode run started more than eight subagents
    When the user stops the run
    Then the subagents are stopped eight at a time
    And the stop gives up after 15 seconds and reports the first one that could not be stopped

  Scenario Outline: OpenCode refuses a revert it cannot carry out
    Given <situation>
    When the user <action>
    Then it is refused with a message that <says>

    Examples:
      | situation                                        | action                  | says                                                      |
      | an OpenCode turn is running                      | reverts an earlier turn | the thread cannot be rolled back while a turn is active   |
      | OpenCode no longer has the message to return to  | reverts to that turn    | the OpenCode rewind boundary is no longer available       |
      | OpenCode's rewound session kept the wrong turns  | reverts to that turn    | OpenCode did not preserve the requested rewind boundary   |

  # The MC forks a running thread from its last finished turn, and a fork names an MC
  # run, not an OpenCode turn: both rows contradict how it forks.
  @backlog
  Scenario Outline: OpenCode refuses a fork it cannot carry out
    Given <situation>
    When the user <action>
    Then it is refused with a message that <says>

    Examples:
      | situation                                        | action                  | says                                                      |
      | an OpenCode turn is running                      | forks the thread        | the thread cannot be forked while a turn is active        |
      | the turn to fork from is unknown to OpenCode     | forks from that turn    | the fork boundary turn was not found                      |

  Scenario: A reverted OpenCode thread stays reverted after a restart
    Given an OpenCode thread that was reverted to its first turn
    When the MC restarts and reads the thread back from OpenCode
    Then the turns after the first are not shown again

  # Upstream #17414: an untitled session made OpenCode run its own title model, and the
  # session list showed OpenCode's title rather than the thread's.
  Scenario: OpenCode's session carries the thread's name
    When the thread "Fix login" starts on OpenCode
    Then its OpenCode session is titled "Fix login"
    And OpenCode does not write a title of its own

  @priority-low
  Scenario: A renamed thread renames its OpenCode session at its next turn
    Given the thread "Fix login" runs on OpenCode
    When the thread is renamed "Fix the login redirect" and the user sends a message
    Then its OpenCode session is titled "Fix the login redirect" before the message reaches OpenCode
    And a turn under an unchanged name does not retitle the session
    And a title that cannot be written does not fail the turn

  @backlog
  Scenario Outline: The HAL-C2 tools are offered only to a local OpenCode
    Given OpenCode runs <where>
    When a thread starts on OpenCode
    Then the HAL-C2 tools are <offered>

    Examples:
      | where                         | offered                                   |
      | on the MC's own local server  | added to OpenCode under the name "hal-c2" |
      | on an external server         | not added                                 |

  @backlog
  Scenario: Closing a thread on an external OpenCode server stops its sessions there
    Given a thread runs on an external OpenCode server
    When the thread's OpenCode session is closed
    Then its sessions and their subagents on that server are stopped
    And the server itself keeps running
    And a session that does not stop within a second does not hold up closing

  @backlog
  Scenario Outline: Updating OpenCode uses the installer that owns it
    Given the opencode command on the MC <installed>
    When the user updates OpenCode from HAL-C2
    Then <update>

    Examples:
      | installed                                         | update                                    |
      | is OpenCode's own install under the user's home   | OpenCode's own upgrade command is run     |
      | was installed with npm                            | the opencode-ai package is updated by npm |

  @backlog
  Scenario: OpenCode's skills and commands are read for the project being worked in
    Given the project has the OpenCode skill "deploy" and the command "/review"
    When the user opens the skill and command lists in an OpenCode thread
    Then "deploy" and "/review" are offered

  @backlog @priority-low
  Scenario: OpenCode commands that do not load in 10 seconds are left out
    Given OpenCode does not answer when asked for its commands
    When 10 seconds pass
    Then the project's OpenCode skills are still offered
    And no OpenCode commands are offered

  @backlog @priority-low
  Scenario: OpenCode skills and commands that cannot be read in 20 seconds are reported
    Given the OpenCode server for the project does not answer
    When 20 seconds pass
    Then reading fails naming the project folder
    And the failure is not remembered as an empty list

  # Upstream #29535: OpenCode 2 lists a folder's skills while it scans it in the background, and a
  # $skill missing from one early read was dropped, so the model saw only the literal "$name".
  @backlog
  Scenario: A $skill sent before OpenCode finishes scanning the folder still reaches OpenCode
    Given the project has the OpenCode skill "greet"
    And OpenCode 2 was restarted and has not finished scanning the project folder
    When the user sends "$greet again please" in an OpenCode thread
    Then OpenCode receives the message with the skill "greet" attached

  # OpenCodeAdapterV2.ts: how OpenCode's own tools, permissions and to-dos read in the thread.
  Scenario Outline: OpenCode's tool calls are shown by kind
    When OpenCode <does>
    Then the thread shows <shown>

    Examples:
      | does                                                     | shown                                    |
      | runs a shell command                                     | a command with its output and exit code  |
      | edits, writes or patches a file                          | a file change with the file and its diff |
      | fetches a web page or searches the web                   | a web search with what it looked for     |
      | reads a file, searches files or asks the language server | a file search with what it looked for    |
      | uses any other tool                                      | a tool call with its input and output    |

  # Upstream #29824: OpenCode reports a shell command that exits non-zero as completed, so a failing
  # test run was stored, and read by agents, as a command that succeeded.
  @priority-high
  Scenario: An OpenCode command that exits non-zero is shown as failed
    When OpenCode runs "vp test" and it exits with code 1
    Then the thread shows the command as failed with exit code 1
    And an agent reading the thread is told the command failed

  # Upstream #21507: OpenCode's native reads render without their XML envelopes
  @backlog
  Scenario: An OpenCode file read shows the file, not OpenCode's wrapping
    When OpenCode reads a file or a folder with its own read tool
    Then the expanded call shows the numbered lines or the folder's entries
    And OpenCode's notices about where the read stopped are kept
    And output from other tools is shown as it came

  @backlog
  Scenario Outline: OpenCode's approval kind follows the permission it asks for
    Given the thread runs OpenCode in approval required
    When OpenCode asks for permission to <action>
    Then the user is asked to approve <kind>

    Examples:
      | action                          | kind          |
      | edit, write or patch a file     | a file change |
      | read or search files            | a file read   |
      | work outside the project folder | a file read   |
      | do anything else                | a command     |

  @backlog
  Scenario: An OpenCode approval says which permission and patterns it covers
    Given the thread runs OpenCode in approval required
    When OpenCode asks for the "bash" permission for "npm test" and "npm run build"
    Then the approval is titled "bash"
    And it lists "npm test" and "npm run build" on separate lines

  @backlog
  Scenario: An OpenCode approval without patterns names only the permission
    Given the thread runs OpenCode in approval required
    When OpenCode asks for the "bash" permission without saying what for
    Then the approval's text is "bash"

  @backlog
  Scenario Outline: An OpenCode question with blanks is still readable
    When OpenCode asks a question whose <part> is blank
    Then <shown>

    Examples:
      | part               | shown                                                |
      | heading            | the question is headed by its position, "Question 1" |
      | text               | the heading is shown as the question                 |
      | option label       | the option reads "Option"                            |
      | option description | the option's label is shown as its description       |

  Scenario: OpenCode's to-do list is shown and finishes with its last item
    When OpenCode updates its to-do list with one item in progress and one done
    Then the thread shows a "Todo list" with one step running and one done
    And the list is finished only once every item is done

  # Upstream #22938: a cancelled OpenCode to-do was shown as pending, so the list never finished.
  @backlog
  Scenario: A cancelled OpenCode to-do is left out and the list can finish
    When OpenCode updates its to-do list with two items done and one cancelled
    Then the thread's "Todo list" shows the two done steps
    And the list is finished
    And a list whose every item was cancelled is finished too

  @backlog @priority-low
  Scenario: An OpenCode to-do without text is numbered
    When OpenCode's second to-do has no text
    Then it reads "Todo 2"

  @backlog
  Scenario: Text OpenCode marks as not for the user is never shown
    When OpenCode adds text to its conversation that it marks as generated for itself or to be ignored
    Then the thread does not show that text
    And it is still left out when the conversation is read back from OpenCode

  @backlog
  Scenario: An OpenCode subagent's thread opens with its task and names its model
    When OpenCode starts a subagent with a task
    Then a child thread opens once OpenCode names the subagent's session
    And its first message is the task the subagent was given
    And it shows the model the subagent ran with, or the parent's when OpenCode names none

  @backlog
  Scenario: A failure inside an OpenCode subagent fails only that subagent
    Given an OpenCode run with a subagent at work
    When OpenCode reports an error for the subagent's session
    Then the subagent's turn fails with that error
    And the parent thread's OpenCode session is not marked as failed

  @backlog
  Scenario Outline: OpenCode requests that cannot be carried out say why
    When <problem>
    Then the request fails with "<message>"

    Examples:
      | problem                                                 | message                                               |
      | a steer reaches OpenCode after the turn "t1" has ended  | OpenCode turn t1 is not active                        |
      | a turn starts on a session "s1" the MC no longer tracks | OpenCode session s1 is not registered                 |
      | OpenCode answers creating a session with nothing at all | OpenCode session.create returned no response payload. |

  @backlog @priority-low
  Scenario: OpenCode's protocol log records the shape of events, never their content
    Given protocol logging is on
    When OpenCode streams text, tool input and tool output
    Then the protocol log records each event's direction, kind and structure
    And it holds none of the text, input or output

  @backlog @priority-low
  Scenario: A protocol log that cannot be written does not disturb the OpenCode turn
    Given protocol logging is on and the log cannot be written
    When an OpenCode turn runs
    Then the turn runs normally
    And the MC logs the warning "Failed to write native OpenCode event log."

  # OpenCodeDriver.ts: a status check starts an OpenCode server, so it runs only when asked for.
  @backlog @priority-low
  Scenario: OpenCode's status is checked when asked, not on the background interval
    Given OpenCode is enabled and the background health check interval is on
    When the interval passes, or the user changes an OpenCode setting
    Then no OpenCode status check is run and no OpenCode server is started for one
    But OpenCode's status is checked when the user refreshes provider status

  # features/settings/subagents.feature: the setting is not wired for OpenCode yet.
  @backlog @mc
  Scenario: OpenCode's own subagent tool is turned off when agents use HAL-C2 workers
    Given the subagents setting is HAL-C2 workers
    When an OpenCode session is started
    Then its task permission is denied, through the config OpenCode is started with

  # HalC2.Plugins.Kinds: another instance runs with its own settings, home and account,
  # so its turn needs its own agent rather than the first instance's.
  Scenario: A turn on another instance of OpenCode starts its own agent
    Given OpenCode is installed and enabled
    And the user sends a message to OpenCode
    And a second instance "opencode-work" of it with a binary of its own
    When the next message goes to "opencode-work"
    Then a process of "opencode-work" runs that turn in place of the first instance's
    And another message to "opencode-work" stays in that process

  # Upstream #29326: OpenCode's binary path was used as written, so "~/.local/bin/opencode" failed
  # to start; Codex and Claude already expanded it.
  @backlog @priority-low
  Scenario: An OpenCode binary path starting with "~" is found in the user's home
    Given OpenCode's binary path is set to "~/.local/bin/opencode", a wrapper in a home folder with spaces in its name
    When the MC checks OpenCode
    Then OpenCode is ready, with its version and models
    And its turns run that wrapper

  # Upstream #13651: OpenCode 2.x prints "server listening on <url>", not the 1.x line.
  @backlog @mc @plugin-opencode @priority-low
  Scenario: OpenCode counts as started when it prints either listening line
    Given OpenCode prints "server listening on http://127.0.0.1:4096" when it starts
    When the MC starts an OpenCode server
    Then the MC uses http://127.0.0.1:4096 and does not time out waiting for it

  @backlog @shared @priority-low
  Scenario: A blank reasoning label shows Default
    Given OpenCode reports a default variant its reasoning menu does not list
    When no explicit choice is saved
    Then the reasoning label reads Default rather than blank

  @backlog @mc @plugin-opencode @priority-low
  Scenario: A thread's HAL-C2 tools reach OpenCode however long the thread id is
    Given a delegated child thread whose id would make the server's name longer than OpenCode allows
    When an OpenCode turn starts in it
    Then the HAL-C2 tool server is registered under a shorter name that is the same on every turn
    And the thread can use the HAL-C2 tools

  # Upstream #16796: each OpenCode 2 turn adds the HAL-C2 tool server again, since OpenCode drops it with an idle project.
  @backlog @priority-low
  Scenario: A thread keeps its HAL-C2 tools after OpenCode 2 forgets an idle project
    Given a thread on OpenCode 2 whose project OpenCode evicted while it sat idle
    When the user sends the thread another message
    Then the HAL-C2 tool server is added to OpenCode again before the turn
    And the thread can use the HAL-C2 tools

  # Upstream #16796: a failed registration drops the tools from that turn's instructions but runs the turn.
  @backlog @priority-low
  Scenario: A turn whose HAL-C2 tools could not be added still runs without them
    Given a thread on OpenCode 2
    And adding the HAL-C2 tool server fails for the next turn
    When the user sends the thread a message
    Then the turn runs
    And the agent is not told about the HAL-C2 tools for that turn

  # OpenCode 2 runs background subagents; when one reports back, OpenCode replies on its own
  # and HAL-C2 shows that reply as a continuation turn.
  @backlog @mc @plugin-opencode @priority-low
  Scenario: Each OpenCode 2 continuation shows its own background reply
    Given an OpenCode 2 turn started two background subagents
    And each one's report woke a reply, first "A" and then "B"
    When only the continuation for "B" runs
    Then that turn shows reply "B", not "A"
    And no reply is left waiting

  @backlog @mc @plugin-opencode @priority-low
  Scenario: An OpenCode 2 continuation ends after a reconnect lost a stop's end
    Given an OpenCode 2 turn with a background subagent was stopped and its stop timed out
    And the event stream dropped before the stopped turn's end arrived
    When the subagent's report wakes a continuation turn
    Then the continuation turn completes

  # Upstream #17134: steering a running subagent joins its run, and OpenCode sends one
  # report for both calls; the second call stayed "Running" until a restart.
  @backlog @mc @plugin-opencode @priority-low
  Scenario: Steering a running OpenCode 2 subagent finishes with the run it joined
    Given an OpenCode 2 turn started the background subagent "A"
    When the agent steers "A" while it is still running
    And "A" reports back once
    Then both the subagent call and the steer show "A"'s report
    And the thread is no longer waiting on background work

  @backlog @mc @plugin-opencode @priority-low
  Scenario: A steer that joins a background run waits for its report
    Given an OpenCode 2 background subagent "A" is running
    When the agent steers "A" without asking for it to run in the background
    And the turn ends before "A" reports back
    Then the steer stays running until "A"'s report arrives

  @backlog @mc @plugin-opencode @priority-low
  Scenario: A finished OpenCode 2 subagent asked again waits for its new run
    Given the OpenCode 2 subagent "A" finished its run
    When the agent calls "A" again and the old report arrives late
    Then the old report settles only the first call
    And the new call waits for the report of its own run

  # Upstream #21979: a failed OpenCode background subagent no longer leaves its thread working
  @backlog @priority-low
  Scenario: A failed OpenCode 2 background subagent stops counting as background work
    Given the OpenCode 2 subagent "A" runs in the background
    When the turn of "A" fails
    Then the call to "A" ends as failed
    And the thread no longer shows an agent working in the background

  # Upstream #21460: background work an OpenCode 2 subagent queued while the root turn ended was
  # lost behind the session's newer idle state.
  @backlog @priority-high
  Scenario: A subagent's queued background continuation still runs after the root turn ends
    Given an OpenCode 2 subagent queued a background continuation of its nested work
    When the root turn ends
    Then the thread still shows an agent working in the background
    And the continuation runs and its result reaches the subagent's caller

  # Upstream #18561: an upgraded CLI kept being reported at the running server's old version.
  @backlog
  Scenario: An OpenCode update is checked against the installed CLI
    Given OpenCode was upgraded on disk to 1.5.0 while its running server still reports 1.4.0
    When the user checks for provider updates
    Then OpenCode is shown as 1.5.0 and up to date
    And the running server is not restarted to find out

  # Upstream #27779: an OpenCode upgraded from 1.x to 2 while the MC ran kept being opened as 1.x,
  # so every new session failed until the provider status was refreshed.
  @backlog @priority-high
  Scenario: An OpenCode upgraded in place from 1.x to 2 opens its sessions as OpenCode 2
    Given the MC started with OpenCode 1.18 installed
    And OpenCode is upgraded in place to 2.2
    When the user sends a message in a new OpenCode thread
    Then the session opens through OpenCode 2
    And an OpenCode already seen as 2 is not checked again
