# Sources:
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

@plugin-opencode @node
Feature: OpenCode
  OpenCode reaches the models of every upstream provider it is connected to. The node
  runs OpenCode locally, or connects to an OpenCode server the user already runs.

  Background:
    Given a connected environment with the project "shop"

  Scenario: OpenCode does nothing until the user enables it
    Given OpenCode is installed but not enabled
    When the node starts
    Then no OpenCode process is started

  Scenario: OpenCode lists the models of its connected providers
    Given OpenCode is connected to OpenAI and Anthropic
    When the user enables OpenCode
    Then the model picker offers the OpenAI and Anthropic models through OpenCode
    And each model is grouped under its upstream provider

  Scenario: OpenCode is only offered when the opencode command is installed
    Given the opencode command is not installed on the node
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

  Scenario: OpenCode Go limits are shown for a local OpenCode
    Given OpenCode is signed in to OpenCode Go and runs locally
    When the user opens the limits view
    Then OpenCode Go shows its session, weekly and monthly windows

  Scenario: OpenCode Go limits are unsupported on an external server
    Given the OpenCode instance uses an external server
    When the user opens the limits view
    Then OpenCode's limits are shown as unsupported

  Scenario: An existing thread keeps its OpenCode model when it leaves the catalog
    Given an OpenCode thread uses a model that OpenCode no longer lists
    When the user opens the thread
    Then the thread still shows its model
    And if OpenCode rejects the model the user can pick another and retry

  Scenario: An OpenCode older than the supported range is flagged as known broken
    Given OpenCode 1.14.10 is installed
    When the node checks its providers
    Then OpenCode is reported as a known broken version for this HAL-C2 release
    And the user is told to use OpenCode 1.14.19 or newer

  Scenario: OpenCode in the supported range carries no compatibility warning
    Given OpenCode 1.14.19 is installed
    When the node checks its providers
    Then OpenCode carries no compatibility warning
