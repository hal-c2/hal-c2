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

@mc
Feature: OpenCode
  OpenCode reaches the models of every upstream provider it is connected to. The MC
  runs OpenCode locally, or connects to an OpenCode server the user already runs.

  Background:
    Given a connected environment with the project "shop"

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
      | OpenCode Go       | (blank)      | OpenCode · opencode-go                      | opencode-go  |


  Scenario: An OpenCode title that never comes back fails within three minutes
    Given OpenCode is picked for text generation
    And OpenCode accepts the request but never answers it
    When a new thread needs a title
    Then within three minutes the title fails with "OpenCode did not finish generating in time."
    And OpenCode is told to stop generating it

  # Upstream #23598: the interrupt after a timeout had no deadline of its own.

  Scenario: An OpenCode generation that times out is not held up by a stalled interrupt
    Given an OpenCode title generation reached its three-minute limit
    And OpenCode does not answer the request to stop it
    When five more seconds pass
    Then the title has failed with "OpenCode did not finish generating in time."

  # Upstream #23591: a reconnect mid-reply replaced the text already streamed with what came after.

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

  Scenario: A cancelled OpenCode title or commit message stops OpenCode generating it
    Given OpenCode is writing a commit message
    When the user cancels it
    Then OpenCode stops generating it
    And another generation on the same server still finishes

  # Upstream #29877: a failed OpenCode 1.x generation copied the model provider's raw text into
  # its error, sometimes only "<none>"; known failures now get fixed explanations.

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


  Scenario: A steer keeps the OpenCode turn's agent, variant and instructions
    Given an OpenCode turn is running with the agent "reviewer" and the "high" variant in plan mode
    When the user steers the OpenCode turn with "check the tests too"
    Then the rest of the turn still runs with the agent "reviewer" and the "high" variant
    And OpenCode still has HAL-C2's plan mode instructions


  Scenario: OpenCode Go limits come back after a usage read times out at startup
    Given OpenCode is signed in to OpenCode Go and runs locally
    And reading its Go usage timed out when OpenCode started
    When the next health check comes round
    Then the Go usage is read again without restarting OpenCode
    And OpenCode Go shows its session, weekly and monthly windows

  # Upstream #26165: a Go key replaced in OpenCode 2 lived only in its credential store, so usage used the old key.

  Scenario: OpenCode Go limits are read through a connected Console API key
    Given a local OpenCode runs Go through a connected Console API key
    And its separate OpenCode Go key has expired
    When the user opens the limits view
    Then OpenCode Go shows its windows read through the Console API key

  # Upstream #19636: a probe timeout cached an empty command list for good.

  Scenario: Deleting a thread whose OpenCode turn was interrupted before its message was sent
    Given the user sent a message to an OpenCode thread
    And the turn was interrupted before OpenCode received the message
    When the user deletes the thread
    Then the thread is deleted
    And the user can start a new thread straight away


  Scenario: An OpenCode event stream that ends fails the turn
    Given an OpenCode turn is streaming
    When the event stream ends unexpectedly
    Then the turn fails saying OpenCode exited unexpectedly
    And the thread takes the next message

  # Upstream #30201: a server that accepted the event request but never answered it held the session
  # open for about five minutes, since the 45-second silence limit starts only after an answer.

  Scenario: An OpenCode subagent works under the thread's access mode
    Given the thread runs OpenCode in approval required
    When an OpenCode subagent wants to edit a file
    Then the user is asked for approval in the parent thread
    And the subagent keeps the limits its own agent adds


  Scenario: A request from a subagent OpenCode has not announced yet is not lost
    Given an OpenCode subagent asks for approval before OpenCode says which run it belongs to
    When OpenCode names the subagent's parent shortly after
    Then the approval reaches the thread that started the subagent


  Scenario: An OpenCode slash command runs as OpenCode's own command
    Given OpenCode offers the command "/review"
    When the user sends "/review the last change" to an OpenCode thread
    Then OpenCode runs its "review" command with "the last change"

  # Upstream #29765: a custom command in a subfolder, such as "git/commit", was sent to the model as
  # plain text, because a command name could not hold a "/".

  Scenario: An OpenCode command from a subfolder runs as OpenCode's own command
    Given OpenCode offers the command "/git/commit" from ".opencode/command/git/commit.md"
    When the user sends "/git/commit staged changes" to an OpenCode thread
    Then OpenCode runs its "git/commit" command with "staged changes"
    And a message starting with a file path such as "/Users/me/file.ts explain" is still sent as a message


  Scenario Outline: A slash message OpenCode cannot run as a command is sent as a message
    Given <situation>
    When the user sends "/review the last change" to an OpenCode thread
    Then OpenCode receives it as an ordinary message

    Examples:
      | situation                                                  |
      | OpenCode offers no command named "/review"                 |
      | OpenCode does not list its commands within 10 seconds      |
      | listing OpenCode's commands fails                          |


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

  Scenario Outline: An image sent to a local OpenCode reaches the model as an image
    When the user <sends> with an attached image
    Then OpenCode receives the image as a file
    And the prompt still names the image's path

    Examples:
      | sends                          |
      | sends an OpenCode turn         |
      | steers a running OpenCode turn |

  # Upstream #16145: external servers and missing or unsupported files keep the path only.

  Scenario: An OpenCode failure without details gets a plain message
    When OpenCode reports that a session failed without saying why
    Then the turn fails saying "OpenCode session failed without an error payload."

  # Upstream #24734: a model provider's unreadable error page showed as "<none>".

  Scenario: OpenCode's skills and commands are read for the project being worked in
    Given the project has the OpenCode skill "deploy" and the command "/review"
    When the user opens the skill and command lists in an OpenCode thread
    Then "deploy" and "/review" are offered


  Scenario: An OpenCode subagent's thread opens with its task and names its model
    When OpenCode starts a subagent with a task
    Then a child thread opens once OpenCode names the subagent's session
    And its first message is the task the subagent was given
    And it shows the model the subagent ran with, or the parent's when OpenCode names none


  Scenario: A failure inside an OpenCode subagent fails only that subagent
    Given an OpenCode run with a subagent at work
    When OpenCode reports an error for the subagent's session
    Then the subagent's turn fails with that error
    And the parent thread's OpenCode session is not marked as failed


  Scenario: A blank reasoning label shows Default
    Given OpenCode reports a default variant its reasoning menu does not list
    When no explicit choice is saved
    Then the reasoning label reads Default rather than blank


  Scenario: A thread's HAL-C2 tools reach OpenCode however long the thread id is
    Given a delegated child thread whose id would make the server's name longer than OpenCode allows
    When an OpenCode turn starts in it
    Then the HAL-C2 tool server is registered under a shorter name that is the same on every turn
    And the thread can use the HAL-C2 tools

  # Upstream #16796: each OpenCode 2 turn adds the HAL-C2 tool server again, since OpenCode drops it with an idle project.

  Scenario: A thread keeps its HAL-C2 tools after OpenCode 2 forgets an idle project
    Given a thread on OpenCode 2 whose project OpenCode evicted while it sat idle
    When the user sends the thread another message
    Then the HAL-C2 tool server is added to OpenCode again before the turn
    And the thread can use the HAL-C2 tools
