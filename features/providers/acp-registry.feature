# Sources:
#   docs/user/providers-acp.md
#   apps/server-ex/lib/hal_c2/acp.ex (acpRegistry driver, entries, probes, commandPath override)
#   apps/server-ex/lib/hal_c2/acp/catalog.ex (search, prepare, uninstall, cache, checksums, runners)
#   apps/server-ex/lib/hal_c2/acp/auth.ex (sign-in methods, terminal login, verification)
#   apps/server-ex/lib/hal_c2/acp/url_auth.ex (agent URL sign-in)
#   apps/server-ex/lib/hal_c2/acp/sessions.ex (native sessions, model providers, logout)
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex (initialize, session/new, resume, permissions, cancel, rollback)
#   apps/web/src/components/settings/AcpRegistrySearchStep.tsx, apps/web/src/components/settings/AcpSessionManagementSection.tsx
#   apps/web/src/components/settings/ProviderWizardAuthenticationStep.tsx
#   packages/contracts/src/rpc.ts (server.searchAcpRegistry, server.prepareAcpRegistryAgent, server.uninstallAcpRegistryManagedBinary,
#     server.listAcpRegistrySessions, server.importAcpRegistrySession, server.deleteAcpRegistrySession,
#     server.listAcpRegistryProviders, server.setAcpRegistryProvider, server.disableAcpRegistryProvider,
#     server.logoutAcpRegistry, server.acceptAcpRegistryUrlAuth)

@plugin-acp-registry @node
Feature: ACP registry agents
  Any agent in the official ACP registry can run on a node. The node installs the exact
  version the registry publishes under its own home, runs it on the node's machine, and
  talks to it over ACP. The agent brings its own models, tools and sign-in.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Searching the registry lists only agents that can run here
    When the user searches the ACP registry for "agent"
    Then matching agents are listed, best match first, at most 20
    And agents without a build for this platform are left out

  Scenario: An empty search lists every compatible agent
    When the user opens the registry search without a query
    Then every compatible agent is listed

  Scenario: Adding a registry agent installs its published version
    When the user installs the registry agent "acme"
    Then "acme" is installed under the node's tools folder at the registry's version
    And an instance of "acme" is created and enabled

  Scenario: Adding an agent that is already configured is not offered twice
    Given an instance of "acme" exists
    When the user searches the registry for "acme"
    Then "acme" is shown as already added

  Scenario: An agent that runs through npx needs npm on the node
    Given the registry agent "acme" runs through npx
    And npm is not installed on the node
    When the user adds "acme"
    # Only npx agents need a runner here, and the node (like TS) names npm alone.
    Then the user is told to install npm to use this agent

  Scenario: A download that does not match the registry checksum is rejected
    Given the registry lists a checksum for "acme"
    When the downloaded archive does not match it
    Then adding "acme" fails with a checksum error
    And nothing is installed

  Scenario: A broken archive is rejected
    When the archive downloaded for "acme" cannot be unpacked
    Then adding "acme" fails saying the archive is invalid

  Scenario: The registry cannot be reached and nothing is cached
    Given the node has never fetched the registry
    And the registry cannot be reached
    When the user searches the registry
    Then the user is told the registry is unavailable

  Scenario: The registry is refreshed at most daily unless the user searches
    Given the node fetched the registry an hour ago
    When the node needs registry data without a search
    Then the cached copy is used

  Scenario: Removing the last instance of an agent removes its downloaded files
    Given one instance of "acme" exists
    When the user deletes that instance
    Then the downloaded files for "acme" are removed

  Scenario: An executable override runs a local copy of the agent
    Given the instance of "acme" has an executable override
    When the user sends a message on that instance
    Then the local executable runs with the registry's arguments and environment

  Scenario: An agent that needs sign-in says so
    Given the agent "acme" refuses new sessions until the user signs in
    When the node checks "acme"
    Then "acme" is shown as signed out with "Sign in to use this agent."

  Scenario: Signing in with a terminal method runs the agent's login in a terminal
    Given "acme" offers a terminal sign-in
    When the user signs in to "acme"
    Then the agent's login runs in a terminal on the node that the user can type into
    And "acme" is shown as signed in once a fresh session succeeds

  Scenario: The sign-in terminal follows the size of the user's view
    Given a terminal sign-in for "acme" is running
    When the user resizes the sign-in view
    Then the sign-in terminal is resized to match

  Scenario: Signing in with credentials asks for the fields the agent needs
    Given "acme" signs in with an API key
    When the user signs in and enters the key
    Then the key is passed to the agent and "acme" is checked again

  Scenario: The user chooses among several sign-in methods
    Given "acme" offers a browser method and a terminal method
    When the user picks the terminal method
    Then the terminal sign-in starts

  Scenario: A browser sign-in waits for the user's consent before the agent proceeds
    Given "acme" signs in through a browser page
    When the user starts sign-in
    Then the page link is shown to the user
    And the agent is told to proceed only after the user opens or copies the link

  Scenario: Every client of the node sees the same sign-in
    Given two clients are connected to the node
    When the user starts signing in to "acme" on one client
    Then the other client shows the same sign-in in progress

  Scenario: A sign-in that is not finished in five minutes times out
    Given a sign-in for "acme" has been waiting for five minutes
    When the time runs out
    Then the sign-in fails as timed out and can be retried

  Scenario: Cancelling a sign-in leaves the agent signed out
    Given a sign-in for "acme" is in progress
    When the user cancels it
    Then "acme" stays signed out

  Scenario: A sign-in URL the agent asks for mid-session reaches every client
    Given a thread is running on "acme"
    When "acme" asks the user to open a sign-in URL
    Then every client is offered the URL
    And answering on one client clears it on the others

  Scenario: A newer sign-in URL request replaces the older one
    Given "acme" is waiting for the user to open a sign-in URL
    When "acme" asks for a different sign-in URL
    Then only the newer request is offered

  Scenario: Signing out of an agent that supports it
    Given "acme" supports signing out and the user is signed in
    When the user signs out of "acme"
    Then "acme" is checked again and shown as signed out

  Scenario: A full-access thread approves agent permission requests itself
    Given the thread runs "acme" with full access
    When "acme" asks permission to edit a file
    Then the request is approved without asking the user

  Scenario: An approval-required thread asks the user
    Given the thread runs "acme" with approval required
    When "acme" asks permission to run a command
    Then the user is asked to approve it

  Scenario: Stopping an agent turn cancels it in the agent
    Given a turn is running on "acme"
    When the user stops the turn
    Then "acme" is told to cancel the turn

  Scenario: The next turn after a rollback starts a fresh agent session
    Given an "acme" thread with three turns
    When the user rolls back to the first turn
    Then the files are restored to the first turn
    And the next message starts a new agent session without the later conversation

  Scenario: Switching models inside an agent thread
    Given "acme" offers two models
    When the user switches the thread to the other model
    Then the agent's session uses the new model for the next turn

  Scenario: Agent file and terminal requests are refused
    When "acme" asks the client to read a file or run a terminal
    Then the request is refused rather than left waiting

  Scenario: Registry instances are not used for text generation
    When the user picks a provider for thread titles
    Then registry instances are not offered

  Scenario: Configuring an agent's model provider routing
    Given "acme" lists its model providers
    When the user sets the base URL and headers for one of them
    Then "acme" uses that routing
    And the headers are never shown back to the user

  Scenario: Disabling one of an agent's model providers
    Given "acme" lists an optional model provider "openrouter"
    When the user disables "openrouter"
    Then "openrouter" is shown as disabled

  Scenario: Headers that are not a JSON object of strings are rejected
    When the user saves model provider headers that are not a JSON object of strings
    Then the save is refused with a message about the header format

  @backlog
  Scenario: Agent slash commands and skills appear in the composer
    Given a running "acme" session offers the command "/review" and the skill "$deploy"
    When the user types a slash
    Then "/review" is offered under the provider's commands
    And "$deploy" is offered in the skill menu

  Scenario: Agent plans and context usage are shown
    When "acme" reports a plan and its context usage during a turn
    Then the task list and the context meter follow the agent's reports

  @backlog
  Scenario: Agent-owned terminals are shown read-only
    When an ACP v2 agent runs a command in its own terminal
    Then the command, its output and exit status are shown
    And the user cannot type into that terminal

  Scenario: Custom model ids can be added for a registry agent
    Given "acme" reports no models
    When the user adds the custom model "acme-large"
    Then "acme-large" is offered in the model picker

  Scenario: Models and options that change during a session update the picker
    When "acme" reports a new model while a session runs
    Then the model picker offers it without a provider refresh

  @backlog
  Scenario: Agent plan and build modes follow HAL-C2's plan toggle
    Given "acme" has its own plan mode
    When the user switches the thread to plan mode
    Then "acme" runs in its plan mode

  Scenario: Images and audio the client cannot render show as placeholders
    When "acme" returns an image resource in its answer
    Then the answer shows a placeholder for the image instead of dropping it
