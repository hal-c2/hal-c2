# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
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
#   apps/server/src/provider/Drivers/AcpRegistryDriver.ts (readiness messages, background discovery, sign-in hints)
#   apps/server/src/provider/acp/AcpRegistrySupport.ts (index limits, trusted entries, archives, install lock,
#     managed packages, uninstall, terminal path)
#   apps/server/src/provider/acp/AcpRegistryProbe.ts, AcpRegistryAuth.ts, AcpRegistryAuthenticationState.ts,
#     AcpRegistryRuntimeCoordinator.ts (probe limits and timeouts, sign-in discovery, remembered sign-in, URL sign-in expiry)
#   apps/server/src/provider/acp/AcpSessionRuntime.ts (process containment, authentication, load and resume, option writes)
#   apps/server/src/provider/acp/AcpSessionConfig.ts, AcpRuntimeModel.ts, AcpCoreRuntimeEvents.ts, AcpStderr.ts
#   apps/server/src/provider/acp/AcpClientFs.ts, AcpClientPolicy.ts, AcpClientTerminals.ts (client-side files and terminals)
#   packages/effect-acp/src/client.ts, packages/effect-acp/src/protocol.ts, packages/effect-acp/src/compat.ts (wire generations)
#   packages/effect-acp/src/errors.ts (protocol error codes and messages)

@plugin-acp-registry @mc
Feature: ACP registry agents
  Any agent in the official ACP registry can run on an MC. The MC installs the exact
  version the registry publishes under its own home, runs it on the MC's machine, and
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
    Then "acme" is installed under the MC's tools folder at the registry's version
    And an instance of "acme" is created and enabled

  Scenario: Adding an agent that is already configured is not offered twice
    Given an instance of "acme" exists
    When the user searches the registry for "acme"
    Then "acme" is shown as already added

  Scenario: An agent that runs through npx needs npm on the MC
    Given the registry agent "acme" runs through npx
    And npm is not installed on the MC
    When the user adds "acme"
    # Only npx agents need a runner here, and the MC (like TS) names npm alone.
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
    Given the MC has never fetched the registry
    And the registry cannot be reached
    When the user searches the registry
    Then the user is told the registry is unavailable

  Scenario: The registry is refreshed at most daily unless the user searches
    Given the MC fetched the registry an hour ago
    When the MC needs registry data without a search
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
    When the MC checks "acme"
    Then "acme" is shown as signed out with "Sign in to use this agent."

  Scenario: Signing in with a terminal method runs the agent's login in a terminal
    Given "acme" offers a terminal sign-in
    When the user signs in to "acme"
    Then the agent's login runs in a terminal on the MC that the user can type into
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

  Scenario: Every client of the MC sees the same sign-in
    Given two clients are connected to the MC
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

  # Reads inside the workspace are served; the scenario above is a read outside it.
  Scenario: An agent can read a workspace file while a write waits for approval
    Given "acme" is waiting for approval to write a file
    When "acme" asks the client to read a file in the workspace
    Then the read is answered
    And the write is still waiting for approval

  Scenario: A signed-out agent cannot start a session
    Given "acme" requires sign-in and the user has not signed in
    When a thread tries to start a session with "acme"
    Then the thread fails with an authentication error
    And no session with "acme" is created

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

  Scenario: Agent slash commands and skills appear in the composer
    Given a running "acme" session offers the command "/review" and the skill "$deploy"
    When the user types a slash
    Then "/review" is offered under the provider's commands
    And "$deploy" is offered in the skill menu

  Scenario: Agent plans and context usage are shown
    When "acme" reports a plan and its context usage during a turn
    Then the task list and the context meter follow the agent's reports

  Scenario: Agent-owned terminals are shown read-only
    When an ACP v2 agent runs a command in its own terminal
    Then the command, its output and exit status are shown
    And the user cannot type into that terminal

  Scenario: Custom model ids can be added for a registry agent
    Given "acme" reports no models
    When the user adds the custom model "acme-large"
    Then "acme-large" is offered in the model picker

  Scenario: A registry agent's custom model keeps its own options
    Given "acme" reports no models
    When the user adds the custom model "acme-large" with a reasoning choice of low or high
    Then "acme-large" is offered with low and high reasoning

  Scenario: Models and options that change during a session update the picker
    When "acme" reports a new model while a session runs
    Then the model picker offers it without a provider refresh

  Scenario: Agent plan and build modes follow HAL-C2's plan toggle
    Given "acme" has its own plan mode
    When the user switches the thread to plan mode
    Then "acme" runs in its plan mode

  # The mode to go back to is kept with the thread, not only in the agent's runtime.
  Scenario: Leaving plan mode after the agent restarted returns it to its build mode
    Given "acme" has its own plan mode and the thread is in plan mode
    And the runtime of "acme" restarted
    When the user switches the thread out of plan mode
    Then "acme" runs in the mode it had before plan mode

  Scenario: Images and audio the client cannot render show as placeholders
    When "acme" returns an image resource in its answer
    Then the answer shows a placeholder for the image instead of dropping it

  @backlog
  Scenario Outline: A registry agent that cannot run yet says why
    Given the instance's registry agent <state>
    When the MC checks the instance
    Then the instance is shown with "<message>"

    Examples:
      | state                                | message                                                                        |
      | has not been chosen                  | Select an ACP Registry agent before starting a thread.                         |
      | is no longer in the registry         | ACP Registry does not contain agent 'acme'.                                    |
      | has no build for this machine        | ACP Registry agent 'acme' has no compatible distribution for this environment. |
      | needs npx and npx is not on the path | ACP Registry agent 'acme' requires 'npx' on this environment's PATH.           |
      | has not been downloaded yet          | ACP Registry agent 'acme' has not been prepared on this environment.           |

  @backlog
  Scenario: Checking an agent's readiness never waits on the network
    Given the MC holds a cached copy of the registry and the registry cannot be reached
    When the MC checks the instance of "acme"
    Then the readiness of "acme" is read from the cached copy
    And with no cached copy the check fails at once instead of fetching the registry

  @backlog
  Scenario: A registry that cannot be reached falls back to the cached copy
    Given the MC holds a cached copy of the registry
    And the registry cannot be reached
    When the user searches the registry
    Then agents from the cached copy are listed

  @backlog
  Scenario Outline: A registry answer that cannot be used is refused
    When the registry answers with <answer>
    Then the fetch fails with "<message>"
    And a cached copy is used if the MC has one

    Examples:
      | answer                      | message                                   |
      | text that is not JSON       | ACP Registry returned invalid JSON.       |
      | JSON that is not a registry | ACP Registry returned an invalid index.   |
      | an index larger than 1 MB   | ACP Registry index exceeds 1048576 bytes. |
      | nothing within 30 seconds   | Timed out fetching ACP Registry index.    |

  @backlog
  Scenario: One bad registry entry does not hide the others
    Given the registry lists "acme" correctly and another agent with a malformed entry
    When the user searches the registry
    Then "acme" is listed
    And the malformed entry is left out

  @backlog
  Scenario Outline: A registry entry that cannot be trusted is left out
    Given the registry lists an agent whose <part>
    When the user searches the registry
    Then that agent is not offered

    Examples:
      | part                                               |
      | download address is not HTTPS                      |
      | download address carries a user name or password   |
      | npx or uvx package does not pin an exact version   |

  @backlog
  Scenario: A registry listing more than 512 agents is refused
    Given the registry lists more than 512 agents
    When the MC reads the registry
    Then the index is refused as invalid

  @backlog
  Scenario: An agent whose package manager is missing is not offered in search
    Given the registry agent "acme" only runs through uvx
    And uv is not installed on the MC
    When the user searches the registry for "acme"
    Then "acme" is not offered

  @backlog
  Scenario: An agent that runs through uvx needs uv on the MC
    Given the instance of "acme" is set to run through uvx
    And uv is not installed on the MC
    When the MC prepares "acme"
    Then it fails with "ACP Registry agent acme requires 'uv', but it is not available on this environment's PATH."

  @backlog
  Scenario Outline: The way an agent is distributed follows the instance's preference
    Given the registry publishes "acme" as <published>
    And the instance prefers <preference>
    When the MC prepares "acme"
    Then "acme" <outcome>

    Examples:
      | published        | preference | outcome                                                    |
      | a binary and npx | automatic  | is installed from the binary                               |
      | npx and uvx      | automatic  | runs through npx                                           |
      | uvx only         | automatic  | runs through uvx                                           |
      | a binary only    | npx        | is refused for having no npx distribution for this machine |

  @backlog
  Scenario: Search results are ranked by how closely they match
    Given the registry lists agents matching "gem" by id, by the start of their name, by author and by description
    When the user searches the registry for "gem"
    Then the exact id or name match comes first
    And matches at the start of a name come before matches inside it, then authors, then descriptions
    And equal matches are ordered by name

  @backlog
  Scenario: A search result says how its download is checked
    When the user searches the registry
    Then each agent says whether its download is checked against a published SHA-256 or trusted from the registry alone
    And each agent carries its version, authors, license, website and repository

  @backlog
  Scenario: An agent without a published checksum can still be installed
    Given the registry lists no checksum for "acme"
    When the user installs "acme"
    Then "acme" is installed

  @backlog
  Scenario Outline: A download that is too large or too slow is given up
    When the download of "acme" <problem>
    Then adding "acme" fails with "<message>"
    And nothing is installed

    Examples:
      | problem                        | message                                                   |
      | is larger than 1 GB            | ACP Registry agent acme archive exceeds 1073741824 bytes. |
      | is not answered in 20 minutes  | Timed out downloading ACP Registry agent acme 1.2.0.      |
      | stalls while being read        | Timed out reading ACP Registry agent acme download.       |

  @backlog
  Scenario Outline: An archive that could write or run outside its own folder is rejected
    Given the registry entry or archive for "acme" <problem>
    When the user installs "acme"
    Then adding "acme" fails with "<message>"
    And nothing is installed

    Examples:
      | problem                                                | message                                                                   |
      | names a command path that leaves the install folder    | ACP Registry agent acme declares an unsafe command path '../bin/acme'.    |
      | holds a file path that leaves the install folder       | ACP Registry agent acme archive contains an unsafe path.                  |
      | does not hold the command the registry names           | ACP Registry archive for acme did not contain 'bin/acme'.                 |
      | links its command to a file outside the install folder | ACP Registry archive command resolves outside its installation directory. |
      | names a command that is not an executable file         | ACP Registry archive command is not a regular executable file.            |

  @backlog
  Scenario: An unsafe command path is refused before anything is downloaded
    Given the registry entry for "acme" names a command path that leaves the install folder
    When the user installs "acme"
    Then nothing is downloaded

  @backlog
  Scenario: Two clients adding the same agent install it once
    Given two clients are connected to the MC
    When both add the registry agent "acme" at the same moment
    Then "acme" is downloaded and installed once
    And the second client finds the finished install

  @backlog
  Scenario: An install does not wait forever on another install
    Given another install of "acme" holds the install lock and makes no progress
    When the user installs "acme" and 30 seconds pass
    Then adding "acme" fails saying it timed out waiting for the install lock
    And a lock left behind for more than five minutes is taken over

  @backlog
  Scenario: Package agents are installed under the MC's own folder
    Given the registry agent "acme" runs through npx
    When the MC prepares "acme"
    Then the package is installed at its exact version under the MC's tools folder
    And the machine's own global packages are not changed

  @backlog
  Scenario: A package agent already installed at the right version is not installed again
    Given the package of "acme" is already installed at the registry's version
    When the MC prepares "acme"
    Then the existing install is used and nothing is downloaded

  @backlog
  Scenario: A same-named command on the path is not used in place of the registry's binary
    Given a command named like the binary of "acme" is on the MC's path
    When the MC prepares "acme"
    Then the registry's binary is downloaded and used
    And only an executable override makes the MC run a local copy

  @backlog
  Scenario: An executable override that cannot be found is explained
    Given the instance of "acme" has the executable override "my-acme"
    And "my-acme" is not on the instance's path
    When the user sends a message on that instance
    Then it fails with "ACP Registry agent acme requires 'my-acme', but it is not available on this provider instance's PATH."

  @backlog
  Scenario: An instance with an executable override reports no agent version
    Given the instance of "acme" has an executable override
    When the MC checks the instance
    Then the instance is ready and its version is unknown

  @backlog
  Scenario: Runners are looked up in the instance's own environment
    Given npx is only on the path set in the environment variables of the "acme" instance
    When the MC checks the instance
    Then "acme" is found ready to run through npx

  @backlog
  Scenario: Removing an agent's downloaded files keeps what package managers installed
    Given "acme" was installed as a binary and "beta" through npx
    When the MC uninstalls both
    Then the downloaded files of "acme" are removed
    And the package of "beta" is kept

  @backlog
  Scenario: Uninstalling an agent that is not installed succeeds
    Given nothing is installed for "acme"
    When the MC is asked to uninstall "acme"
    Then the uninstall succeeds and nothing changes

  @backlog
  Scenario: An agent another client just prepared is not removed by a waiting uninstall
    Given one client is uninstalling "acme"
    When another client prepares "acme" before the uninstall runs
    Then the files prepared for "acme" are kept

  @backlog
  Scenario: Installed agents can be run from HAL-C2's terminals
    Given the registry agent "acme" is installed
    When the user opens a terminal in HAL-C2
    Then the command of "acme" is found on the terminal's path

  @backlog
  Scenario: An installed agent is usable while its sign-in, models and commands are still being read
    Given the registry agent "acme" is installed
    When the MC checks the instance
    Then the instance is listed as ready at once with "Checking ACP authentication, models, and commands in the background..."
    And its sign-in state, models and commands follow when the agent has answered

  @backlog
  Scenario: A check that fails on an installed agent is a warning, not an error
    Given the registry agent "acme" is installed
    When the test session the MC opens to read its models fails
    Then the instance stays usable and shows the failure as a warning

  @backlog
  Scenario: An agent that does not start a test session in 60 seconds is reported
    Given "acme" takes more than 60 seconds to start
    When the MC checks the instance
    Then the instance shows "The ACP agent did not resolve and create a test session within 60 seconds. Package installation or agent startup may be slow; this check retries on the next provider refresh."

  @backlog
  Scenario: What an agent reported is reused for 15 minutes
    Given the MC read the models and commands of "acme" five minutes ago
    When the MC checks the instance again
    Then "acme" is not started for the check
    And a check that failed or found the user signed out is never reused

  @backlog
  Scenario Outline: What an agent reported is read again after a change
    Given the MC read the models and commands of "acme" five minutes ago
    When <change>
    Then the next check starts "acme" and reads them again

    Examples:
      | change                                         |
      | the registry publishes a new version of "acme" |
      | the user signs in to "acme"                    |
      | the user signs out of "acme"                   |
      | the user changes a model provider of "acme"    |

  @backlog
  Scenario: Starting a thread does not wait behind a background check
    Given the MC is reading the models of "acme" in the background
    When the user sends the first message of a thread on "acme"
    Then the background check is stopped and the thread's session starts

  @backlog
  Scenario Outline: A signed-out agent says how to sign in
    Given "acme" needs sign-in and offers <method>
    When the MC checks the instance
    Then the instance shows "<hint>"

    Examples:
      | method                                              | hint                                                                                                                                             |
      | the terminal method "Login"                         | Sign in in provider settings using "Login". The login terminal runs on this environment.                                                         |
      | a method that reads the variable ACME_API_KEY       | Set ACME_API_KEY under this instance's environment variables in provider settings. HAL-C2 will detect it on the next provider refresh.           |
      | the agent-run method "Browser"                      | Sign in in provider settings using "Browser".                                                                                                    |

  @backlog
  Scenario: An agent that answers before sign-in is not called signed in
    Given "acme" lists its models without asking for sign-in
    When the MC checks the instance
    Then the sign-in state of "acme" is shown as unknown

  @backlog
  Scenario: A confirmed sign-in is remembered across a restart
    Given the user signed in to "acme" from HAL-C2
    When the MC restarts
    Then "acme" is shown as signed in before the agent is started again

  @backlog
  Scenario Outline: A remembered sign-in is forgotten when what it was made with changes
    Given the user signed in to "acme" from HAL-C2
    When <change>
    Then "acme" is no longer shown as signed in until it is checked again

    Examples:
      | change                                                        |
      | the instance is pointed at another agent                      |
      | the instance's executable override changes                    |
      | the instance's distribution preference changes                |
      | an environment variable of the instance changes               |
      | the instance's home or profile folder changes                 |
      | a later check finds the agent signed out                      |

  @backlog
  Scenario: Renaming an instance keeps its remembered sign-in
    Given the user signed in to "acme" from HAL-C2
    When the user renames the instance
    Then "acme" is still shown as signed in

  # ACP does not say where an agent keeps its login, so the MC assumes the widest scope.
  @backlog
  Scenario: Instances of the same agent on an MC are treated as sharing one login
    Given two instances of "acme"
    When a sign-in for one of them is running
    Then no second sign-in is started for the other

  @backlog
  Scenario Outline: Sign-in that cannot start says why
    Given <situation>
    When the user starts signing in to "acme"
    Then the user is told "<message>"

    Examples:
      | situation                                                    | message                                                                     |
      | "acme" has not been installed yet                            | Prepare this ACP agent before signing in.                                   |
      | the instance of "acme" is turned off                         | Enable this provider before signing in.                                     |
      | "acme" does not list its sign-in methods within 30 seconds   | The ACP agent did not advertise sign-in methods in time.                    |
      | a thread starts on "acme" while its methods are being read   | Sign-in discovery was interrupted by an active provider session. Try again. |
      | the chosen method is gone when the agent is asked again      | The agent no longer advertises this sign-in method.                         |
      | the MC cannot open terminals                                 | Interactive provider login is unavailable on this environment.              |
      | the agent's own sign-in fails                                | The ACP agent could not complete sign-in.                                   |

  @backlog
  Scenario: Terminal sign-in methods are not offered where the MC cannot open a terminal
    Given the MC cannot open terminals
    And "acme" offers a browser method and a terminal method
    When the user opens sign-in for "acme"
    Then only the browser method is offered

  @backlog
  Scenario Outline: A terminal sign-in that did not work is reported
    Given a terminal sign-in for "acme" is running
    When <outcome>
    Then the sign-in fails with "<message>"

    Examples:
      | outcome                                                  | message                                                          |
      | the login command exits with an error                    | The provider login command did not finish successfully.          |
      | the login command succeeds but a new session is refused  | The provider could not create a session after terminal sign-in.  |
      | the user types after the terminal has closed             | The provider sign-in terminal is no longer available.            |

  @backlog
  Scenario: A client joining a terminal sign-in sees its recent output
    Given a terminal sign-in for "acme" has printed more than 16,384 characters
    When another client opens the sign-in
    Then it receives the last 16,384 characters and where they start in the output

  @backlog
  Scenario: A sign-in address that is not a web address is declined
    When "acme" asks the user to open a sign-in address that is not http or https
    Then the request is declined without being shown to the user

  @backlog
  Scenario: A sign-in address nobody opens expires after ten minutes
    Given "acme" is waiting for the user to open a sign-in URL
    When ten minutes pass
    Then the request is declined and cleared on every client
    And accepting it afterwards is refused

  @backlog
  Scenario Outline: A sign-out that does not work is reported
    When the user signs out of "acme" and <problem>
    Then the user is told "<message>"

    Examples:
      | problem                                   | message                                                                 |
      | the agent refuses or cannot sign out      | This ACP agent could not sign out. It may not advertise logout support. |
      | the agent does not finish in 60 seconds   | The ACP agent did not finish signing out in time.                       |

  @backlog
  Scenario Outline: A session or model provider request the agent does not answer in a minute times out
    When the user <action> and "acme" does not answer within 60 seconds
    Then the user is told "<message>"

    Examples:
      | action                           | message                                           |
      | lists the agent's sessions       | The ACP session list request timed out.           |
      | deletes one of its sessions      | The ACP session delete request timed out.         |
      | lists its model providers        | The ACP provider list request timed out.          |
      | changes a model provider         | The ACP provider configuration request timed out. |
      | disables a model provider        | The ACP provider disable request timed out.       |

  @backlog
  Scenario Outline: An agent that cannot manage model providers or sign out says so
    Given "acme" does not offer <feature>
    When the user <action>
    Then the user is told "<message>"

    Examples:
      | feature                      | action                          | message                                                  |
      | model provider configuration | lists its model providers       | The ACP agent does not advertise provider configuration. |
      | signing out                  | signs out from session settings | The ACP agent does not advertise logout.                 |

  @backlog
  Scenario: An agent's sessions are listed a page at a time
    Given "acme" has more sessions than it returns in one answer
    When the user lists the agent's sessions
    Then at most 256 sessions arrive with a marker for the next page
    And asking with that marker returns the sessions that follow

  @backlog
  Scenario: At most 64 model providers are listed for an agent
    Given "acme" reports more than 64 model providers
    When the user lists its model providers
    Then the first 64 are listed

  @backlog
  Scenario: What an agent advertises is bounded
    Given "acme" advertises hundreds of sign-in methods, models and commands
    When the MC checks the instance
    Then at most 32 sign-in methods, 256 models and 128 commands are kept
    And commands that differ only in letter case are listed once
    And over-long names and descriptions are cut

  @backlog
  Scenario: An agent's session options are offered with its models
    Given "acme" offers a session option "Thinking" with the choices low and high
    When the user opens the options of an "acme" model
    Then "Thinking" is offered with low and high
    And the agent's own model and plan-mode options are not repeated there

  @backlog
  Scenario: An agent that only has modes gets one "Mode" option
    Given "acme" offers the modes "ask" and "code" and no session options
    When the user opens the options of an "acme" model
    Then one option "Mode" offers "ask" and "code"
    And an agent with a single mode gets no such option

  @backlog
  Scenario: Session options are bounded
    Given "acme" offers more than 16 session options, one of them with more than 64 choices
    When the MC reads the options
    Then 16 options are kept, each with at most 64 choices
    And duplicate and empty choices are dropped

  @backlog
  Scenario: An option value the agent does not offer is refused
    Given "acme" offers the option "thinking" with the choices low and high
    When a client sets "thinking" to "extreme"
    Then it is refused with 'Invalid value "extreme" for session config option "thinking": expected one of low, high'

  @backlog
  Scenario: Setting an option to the value it already has sends nothing to the agent
    Given the session of "acme" already uses the model "acme-large"
    When the user picks "acme-large" again
    Then "acme" is not asked to change its model

  @backlog
  Scenario: A model named "Default" is offered only when the agent names none
    Given "acme" reports no models
    When the MC checks the instance
    Then one model "Default" is offered
    And for an agent that reports models, the one it is currently using is marked as the default

  @backlog
  Scenario: An agent that withdraws its commands clears the composer's list
    Given a running "acme" session offered the command "/review"
    When "acme" reports that it now offers no commands
    Then "/review" is no longer offered

  @backlog
  Scenario: A client that connects later sees the commands and options the agent last reported
    Given a running "acme" session reported its commands and options
    When another client connects
    Then that client is given the same commands and options without waiting for the agent to report again

  @backlog
  Scenario: Commands and modes an agent reports while it is starting are not lost
    When "acme" reports its commands and modes before its session has finished starting
    Then they are applied once the session has started

  @backlog
  Scenario: Registry agents are not offered an update from HAL-C2
    Given the registry agent "acme" is installed
    When the user opens the provider list
    Then no update is offered for "acme"

  @backlog
  Scenario Outline: The sign-in method an instance is set to use must be one the agent can run unattended
    Given the instance of "acme" is set to the sign-in method "<method>"
    When a thread starts a session on it
    Then the session fails with '<message>'

    Examples:
      | method   | message                                                                                                                    |
      | gone     | ACP agent did not advertise configured authentication method "gone"                                                        |
      | terminal | ACP authentication method "terminal" requires terminal authentication, which cannot run inside a headless provider session |

  @backlog
  Scenario: A session refused for sign-in is retried once after the agent signs in by itself
    Given "acme" can sign in by itself without the user
    When "acme" refuses a new session saying sign-in is required
    Then the MC asks "acme" to sign in and tries the session once more

  @backlog
  Scenario: A thread continues its agent session by whichever way the agent offers
    Given an "acme" thread whose agent process has stopped
    When the user sends another message
    Then the earlier session is loaded if "acme" can load sessions, and resumed otherwise
    And an agent that can do neither fails the turn with "ACP agent does not advertise session/load or session/resume support"

  @backlog
  Scenario: Loading a session does not repeat its history in the thread
    Given an "acme" thread whose agent process has stopped
    When the session is loaded and "acme" replays the earlier conversation
    Then the thread's timeline gains nothing from the replay

  @backlog
  Scenario: A session load the agent never confirms still completes once the replay goes quiet
    Given "acme" replays a session's history but never answers the load request
    When two seconds pass without another replayed update
    Then the session is treated as loaded and the turn starts
    And updates of other sessions and keep-alive chunks do not count as activity

  @backlog
  Scenario: A session load that never settles fails after 90 seconds
    Given "acme" neither answers the load request nor stops replaying
    When 90 seconds pass
    Then the turn fails with "session/load timed out waiting for RPC response or replay idle gap"

  @backlog
  Scenario Outline: Ending an agent session stops every process the agent started
    Given "acme" started helper processes that detached from it on <platform>
    When the session ends
    Then <outcome>

    Examples:
      | platform                                                   | outcome                                                                                  |
      | Linux where the MC may create process groups in its cgroup | every process in the session's own cgroup is asked to stop, then killed after one second |
      | Linux or macOS without that                                | every process the MC saw the agent start is asked to stop, then killed after one second  |
      | Windows                                                    | the agent's whole process tree is force-stopped                                          |

  @backlog
  Scenario: Stopping an agent never signals a process the agent did not start
    Given a helper of "acme" exited and its process id was reused by an unrelated program
    When the session ends
    Then the unrelated program is not signalled
    And neither the MC's own processes nor the system's first process are ever signalled

  @backlog
  Scenario: Agent processes that survive a stop are named in the MC's log
    Given a helper of "acme" survives being killed
    When the session ends
    Then the MC logs which processes of the agent are still running

  @backlog
  Scenario: Process groups left by a stopped MC are removed when the next agent starts
    Given an MC that was killed left empty process groups of its agents behind
    When the MC next starts an agent session
    Then the empty groups of the dead MC are removed

  @backlog
  Scenario: An agent that exits mid-turn fails the turn with its last error output
    Given a turn is running on "acme"
    When the agent process exits with an error
    Then the turn fails naming the exit code and the last 4,096 characters the agent wrote to its error output
    And requests still waiting on the agent fail instead of hanging

  @backlog
  Scenario Outline: An agent's error output is shown without secrets
    When the error output of "acme" contains <content>
    Then the failure shows <shown>

    Examples:
      | content                                                     | shown                                |
      | a path under the user's home directory                      | the path starting at "~"             |
      | a HAL-C2 pairing link                                       | "[pairing-url]" in place of the link |
      | a bearer or basic authorization value                       | "[redacted]" in place of the value   |
      | an API key header or a token that looks like a provider key | "[redacted]" in place of the value   |

  @backlog
  Scenario: Model provider headers are left out of the agent protocol log
    Given provider event logging is on
    When the user sets headers for a model provider of "acme"
    Then the logged request shows "[redacted]" in place of each header value

  @backlog
  Scenario: Long tool output keeps only its newest part
    When a tool of "acme" has produced more than 8,000 characters of output
    Then the thread keeps the last 8,000 characters under the line "[Earlier output truncated]"

  @backlog
  Scenario: A tool that reports progress very often does not flood the thread
    Given a tool of "acme" reports its output many times a second
    When the updates arrive
    Then the first update, every change of title or status, and the tool's completion are always shown
    And updates in between are shown only once 256 new characters or ten skipped updates have built up

  @backlog
  Scenario: Streamed text arrives in bounded pieces
    When "acme" sends a single piece of text longer than 65,536 characters
    Then the thread receives it cut to 65,536 characters in that update

  @backlog
  Scenario: Embedded binary content is never kept in the thread
    When "acme" sends an image, audio clip or binary resource inline
    Then the thread keeps a short placeholder naming its type and not the bytes

  @backlog
  Scenario: Content of a kind HAL-C2 does not know is shown as unsupported
    When "acme" sends content of the unknown kind "hologram"
    Then the thread shows "[Unsupported ACP content: hologram]"

  @backlog
  Scenario Outline: Context compaction by an agent is shown as a work item
    When "acme" reports that compacting the conversation <state>
    Then the thread shows the work item "Compact context" as <shown>

    Examples:
      | state         | shown       |
      | started       | in progress |
      | finished      | completed   |
      | failed        | failed      |
      | was cancelled | failed      |

  @backlog
  Scenario Outline: Every form of plan an agent sends is shown
    When "acme" <sends>
    Then the thread's plan <shows>

    Examples:
      | sends                                     | shows                                                 |
      | sends a list of plan entries              | shows each entry with its status                      |
      | sends an entry with no text               | names that entry by its position, such as "Step 2"    |
      | sends a plan written as markdown          | shows the text as one pending step                    |
      | points to a plan file                     | shows "Plan file:" and the file's address             |
      | sends a plan of a kind HAL-C2 cannot read | says the plan content is unsupported, naming its kind |
      | removes its plan                          | is emptied                                            |

  @backlog
  Scenario: Output of an agent's own terminal is capped
    Given an ACP v2 agent runs a command in its own terminal
    When the command prints more than 16 MiB
    Then the newest 16 MiB are kept
    And a malformed piece of terminal output is skipped without failing the turn

  @backlog
  Scenario: HAL-C2's own tools are recognised however the agent names them
    Given "acme" names tools of the HAL-C2 MCP server in its own style
    When "acme" calls a HAL-C2 tool
    Then the thread shows it as a HAL-C2 tool
    And a tool of another MCP server with a similar name is not shown as one

  @backlog
  Scenario: A file request with a relative path is refused
    When "acme" asks the client for the file "src/app.ts" without a full path
    Then the request is refused with "ACP fs requests require an absolute path, received 'src/app.ts'."

  @backlog
  Scenario: An agent can read part of a workspace file
    When "acme" asks the client for 20 lines of a workspace file starting at line 100
    Then it receives lines 100 to 119

  @backlog
  Scenario: A file an agent writes through the client is created with its folders
    Given the thread lets "acme" edit files
    When "acme" writes a workspace file in a folder that does not exist yet
    Then the folder and the file are created

  @backlog
  Scenario Outline: What an agent may do through the client follows the thread's mode
    Given the thread's mode <mode>
    When "acme" asks to <request>
    Then the request is <outcome>

    Examples:
      | mode                        | request                                  | outcome                |
      | only lets the agent read    | read or search files                     | allowed                |
      | only lets the agent read    | edit a file                              | denied                 |
      | lets it edit the workspace  | edit a file inside the workspace         | allowed                |
      | lets it edit the workspace  | edit a file outside the workspace        | denied                 |
      | lets it edit the workspace  | edit without saying which file           | denied                 |
      | lets it edit the workspace  | run a command or fetch from the network  | denied                 |
      | gives full access           | run a command                            | allowed                |
      | asks before acting          | edit a file                              | put to the user        |

  @backlog
  Scenario: A link that points outside the workspace does not let an agent write there
    Given the thread lets "acme" edit only the workspace
    And the workspace holds a link to a folder outside it
    When "acme" asks to edit a file through that link
    Then the request is denied

  @backlog
  Scenario Outline: An approval for a file lasts as long as the user chose
    Given the user approved an edit of a file by "acme" <choice>
    When "acme" asks to edit that file again <later>
    Then the user is <asked>

    Examples:
      | choice           | later              | asked           |
      | for this turn    | in the same turn   | not asked again |
      | for this turn    | in the next turn   | asked again     |
      | for this session | in the next turn   | not asked again |

  @backlog
  Scenario: An agent can run at most 16 client terminals at once
    Given "acme" has 16 commands running in terminals it asked the client for
    When "acme" asks for another terminal
    Then it is refused with "ACP terminal/create exceeded the limit of 16 concurrent terminals."

  @backlog
  Scenario: Output of a client terminal is capped per terminal
    Given "acme" runs a command in a terminal it asked the client for
    When the command prints more than the terminal's limit of 4 MB, or of what the agent asked for up to 8 MB
    Then the agent receives the newest output marked as truncated

  @backlog
  Scenario: A request for a terminal the client does not know is refused
    When "acme" asks for the output of the terminal "t-404" that was never created
    Then it is refused with "ACP terminal/output received an unknown terminal ID 't-404'."

  @backlog
  Scenario: A client terminal that ignores a stop is killed
    Given "acme" runs a command in a terminal it asked the client for
    When "acme" asks to kill it and the command has not exited after five seconds
    Then the command is force-killed

  @backlog
  Scenario: Client terminals end with the agent's session
    Given "acme" left commands running in terminals it asked the client for
    When the session ends
    Then those commands are stopped

  @backlog
  Scenario: The protocol generation is taken from how the agent answers, not the version it states
    Given "acme" states a protocol version that does not match the shape of its answers
    When the MC starts a session on "acme"
    Then the MC speaks the generation the agent's first answer is shaped as

  @backlog
  Scenario: A request HAL-C2 does not implement is answered rather than left waiting
    When "acme" sends the client a request "x/unknown" that HAL-C2 does not know
    Then "acme" is answered with the error "Method not found: x/unknown"

  # DevinAcp.ts: what the registry agent "devin" adds to plain ACP.
  @backlog
  Scenario: Devin's subagents get their own child threads
    Given a thread runs on the registry agent "devin"
    When Devin starts a subagent with a task
    Then the subagent appears as a child thread whose first message is the task
    And what the subagent says and does is shown in that child thread, not the parent

  @backlog
  Scenario Outline: A Devin subagent shows how it ended
    Given Devin started a subagent
    When the subagent <ends>
    Then the child thread is shown as <shown>

    Examples:
      | ends                            | shown                                     |
      | finishes with a summary         | completed, with the summary as its result |
      | reports that it did not succeed | failed                                    |

  @backlog
  Scenario: Devin's reply keeps its paragraphs when it streams several messages
    When Devin streams two messages in one turn
    Then the thread shows them as two separate messages

  @backlog
  Scenario: A Devin tool without a title is named after the tool
    When Devin calls a tool it titles only "Tool"
    Then the thread shows the tool under the name Devin gave it internally

  @backlog
  Scenario: Devin's terminal commands run through a shell
    Given the thread lets Devin run commands
    When Devin asks the client to run "npm test && npm run lint" as one command line
    Then the command line runs in a shell
    But another registry agent's command runs as a program with its arguments

  # MistralVibeAcp.ts: what the registry agent "mistral-vibe" adds to plain ACP.
  @backlog
  Scenario Outline: Mistral Vibe retrying a request shows as a retry
    Given a turn is running on the registry agent "mistral-vibe"
    When Vibe reports that it is retrying because <reason>
    Then the thread shows a retry with Vibe's explanation
    And it is classed as <class>

    Examples:
      | reason                         | class                 |
      | it was rate limited            | a usage limit         |
      | the server failed              | a connection problem  |
      | the request timed out          | a connection problem  |
      | the connection dropped         | a connection problem  |
      | of something it cannot name    | a provider error      |

  @backlog
  Scenario: A Mistral Vibe turn refused for rate limits is a usage limit
    When Vibe refuses a prompt with its rate limit error
    Then the turn fails as a usage limit with Vibe's message

  # AcpRegistryAdapterV2.ts
  @backlog
  Scenario: A prompt an agent refuses fails the turn with the agent's own words
    When "acme" refuses a prompt with the error "Model quota exhausted" and the code -32000
    Then the turn fails with "Model quota exhausted" and the code -32000
    And nothing else of the agent's answer is shown

  @backlog
  Scenario: A sign-in address request without an id is declined
    When "acme" asks the user to open a sign-in address with an empty request id
    Then the request is declined without being shown to the user

  @backlog
  Scenario: A long sign-in address request is cut down before it is shown
    When "acme" asks the user to open a sign-in address with a message longer than 1,024 characters
    Then the clients are offered the address with the first 1,024 characters of the message
    And a request id longer than 256 characters is cut to 256

  # AcpAdapterV2.ts: behaviour every ACP agent shares (registry agents, Grok, Antigravity).
  @backlog
  Scenario: A form an agent asks the user to fill becomes questions
    When "acme" asks the user for a form with a text field, a choice and a yes-or-no field
    Then the user is asked one question per field
    And the choice offers the form's options and the yes-or-no field offers "Yes" and "No"
    And a field without a title is headed by its position, such as "Question 2"

  @backlog
  Scenario Outline: An agent's form is answered, declined or dismissed
    Given "acme" asked the user to fill a form
    When the user <does>
    Then "acme" is told the form was <told>

    Examples:
      | does                    | told                       |
      | answers every question  | accepted, with the answers |
      | dismisses the questions | cancelled                  |

  @backlog
  Scenario: A request for input of a kind HAL-C2 does not know is declined
    When "acme" asks the user for input in a way that is neither a form nor an address to open
    Then "acme" is told the request was declined
    And the turn carries on

  @backlog
  Scenario Outline: An agent asking to approve a tool of an MCP server follows the thread's mode
    Given the thread runs "acme" in <mode>
    When "acme" asks through a form whether it may call a tool of an MCP server
    Then <outcome>

    Examples:
      | mode              | outcome                                 |
      | full access       | the call is approved without asking     |
      | approval required | the user is asked to approve the call   |

  @backlog
  Scenario Outline: The kind of approval follows what the agent wants to do
    When "acme" asks permission for a tool it describes as <described>
    Then the user is asked to approve <kind>

    Examples:
      | described                      | kind           |
      | running something              | a command      |
      | reading, searching or fetching | reading a file |
      | editing, deleting or moving    | a file change  |
      | something it does not name     | a command      |

  @backlog
  Scenario: Approving a tool the agent did not describe does not let it run commands through the client
    Given the user approved a tool "acme" did not describe
    When "acme" asks the client to run a command in a terminal
    Then the command is not covered by that approval

  @backlog
  Scenario Outline: A client request the thread's mode stops tells the agent what to do next
    When "acme" asks the client to <operation> and the thread's mode <stops>
    Then "acme" is answered "<answer>"

    Examples:
      | operation                | stops                | answer                                                                                                                                                       |
      | write the file "/w/a.ts" | wants the user asked | The active HAL-C2 runtime policy requires approval for fs/write_text_file for '/w/a.ts'. Request permission with session/request_permission before retrying. |
      | write the file "/w/a.ts" | forbids it           | The active HAL-C2 runtime policy does not allow fs/write_text_file for '/w/a.ts'.                                                                            |
      | read the file "/w/a.ts"  | forbids it           | The active HAL-C2 runtime policy does not allow fs/read_text_file for '/w/a.ts'.                                                                             |
      | run a command            | forbids it           | The active HAL-C2 runtime policy does not allow terminal/create.                                                                                             |

  @backlog
  Scenario: An agent that needs the user to act shows it in the work log
    When "acme" reports that it is waiting for the user to act
    Then the work log shows "Action required" with what the agent is waiting for

  @backlog
  Scenario: An update of a kind HAL-C2 does not know is shown, not dropped
    When "acme" sends a session update of the unknown kind "hologram"
    Then the work log shows "Unsupported ACP update: hologram"

  @backlog
  Scenario: An agent repeating the user's message does not show it twice
    When "acme" echoes the user's message back as part of the turn
    Then the thread shows the message once

  @backlog
  Scenario Outline: A tool the agent does not title gets a plain title
    When "acme" runs a tool of the kind <kind> without a title
    Then the thread shows it as "<title>"

    Examples:
      | kind                        | title       |
      | command                     | Command     |
      | file edit                   | File change |
      | background monitor          | Monitor     |
      | terminal                    | Terminal    |

  @backlog
  Scenario Outline: A command's exit code is shown only once it has ended
    When a command "acme" runs <state>
    Then its exit code is <shown>

    Examples:
      | state               | shown     |
      | finished            | shown     |
      | failed              | shown     |
      | is still running    | not shown |
      | was interrupted     | not shown |

  @backlog
  Scenario Outline: An ACP turn that cannot start says why
    When <attempt>
    Then the turn is refused with "<message>"

    Examples:
      | attempt                                                          | message                                           |
      | a message with an image is sent to an agent that takes no images | ACP driver did not negotiate image prompt support |
      | a message names the attachment "../x" that is not a valid id     | Invalid attachment id '../x'                      |
      | a message's attachment "a1" can no longer be read                | Failed to read attachment 'a1'                    |
      | a message with no text and no attachments is sent                | ACP turn requires non-empty text or attachments   |
      | a message is sent while the turn "turn-1" still runs natively    | ACP provider turn turn-1 is still active          |

  @backlog
  Scenario: An option the agent's session does not offer is skipped
    Given the thread asks for a reasoning effort that the session of "acme" does not offer
    When a turn starts
    Then the turn runs with the agent's own default for it
    And the MC logs which option was skipped

  @backlog
  Scenario: The model is only set when the session lets it be chosen
    Given the thread's model is "Default"
    When a turn starts on "acme"
    Then the MC does not ask "acme" to change its model

  @backlog
  Scenario: A session that can no longer be loaded does not stop the agent from starting
    Given the earlier session of an "acme" thread cannot be loaded
    When the agent is started for that thread
    Then the agent starts on a new session
    And the failure to load is reported when the thread next uses the earlier session

  @backlog
  Scenario: An agent that does not confirm a stop within 10 seconds is released
    Given a turn is running on "acme"
    When the user stops the turn and "acme" does not confirm the cancellation within 10 seconds
    Then the turn is shown as interrupted
    And the stop reports that the agent did not acknowledge cancellation before the interrupt timeout

  @backlog
  Scenario: A turn the user stops closes the tools it left open as interrupted
    Given "acme" is running a tool
    When the user stops the turn
    Then the tool is shown as interrupted, not completed

  @backlog
  Scenario Outline: An agent whose processes cannot be stopped is not used again
    Given the user stops a turn on an agent that must be killed to stop
    When <problem>
    Then the stop fails saying "<message>"
    And the thread refuses further turns on that session with the same message

    Examples:
      | problem                                            | message                                                                                  |
      | the MC has no way to end the agent's process group | ACP runtime does not expose its required process-group teardown; the session is poisoned |
      | ending the agent's process group fails             | ACP runtime process-group teardown failed; the session is poisoned                       |
      | ending a leftover agent process group fails        | ACP orphan runtime process-group teardown failed; the session is poisoned                |
      | the stop breaks off part way for another reason    | ACP hard teardown failed unexpectedly; the session is poisoned                           |

  @backlog
  Scenario: An agent killed to stop a turn is started again for the next message
    Given the user stopped a turn on an agent that must be killed to stop
    When the user sends the next message
    Then a new agent process is started and the same session is loaded into it
    And the conversation continues

  @backlog
  Scenario: Stopping twice while the agent is being killed waits for the first stop
    Given the agent is being killed to stop a turn
    When the user stops the turn again
    Then the second stop waits for the first and succeeds with it

  @backlog
  Scenario: Late output of a stopped turn is not shown
    Given the user stopped a turn on "acme"
    When "acme" still sends updates for that turn afterwards
    Then the thread does not show them
    And they do not start a new run

  @backlog
  Scenario Outline: Answering an ACP request is refused when it cannot be applied
    When a client <answers>
    Then the answer is refused with "<message>"

    Examples:
      | answers                                         | message                                     |
      | answers the request "r9" that is not open       | No pending ACP runtime request r9           |
      | answers the approval "a1" without a decision    | ACP approval request a1 requires a decision |
      | answers the request "r2" that was just answered | ACP runtime request r2 was already resolved |

  @backlog
  Scenario: A rollback whose fresh session cannot start leaves the thread as it was
    Given an "acme" thread with two turns
    When the user reverts to the first turn and "acme" cannot start the fresh session, even on a second try
    Then the revert fails
    And the thread keeps working on its original session

  @backlog
  Scenario Outline: An agent refuses a fork it cannot carry out
    When the user forks an "acme" thread <situation>
    Then the fork is refused with "<message>"

    Examples:
      | situation                         | message                                                 |
      | and "acme" cannot fork sessions   | ACP driver did not negotiate session/fork               |
      | from a turn before the latest one | ACP session/fork can only fork the current session head |

  @backlog
  Scenario: A registry agent that cannot be set up says so
    When the MC cannot set up the instance of "acme"
    Then the instance fails with "Failed to create ACP Registry adapter."

  # AcpAdapterV2.ts: how an approval is answered when the agent's own choices do not fit it.
  @backlog
  Scenario Outline: The user's answer to an approval is given to the agent as one of its own choices
    Given "acme" asks for an approval and offers the choices allow once, allow always and reject once
    When the user <answers>
    Then "acme" is told <choice>

    Examples:
      | answers                          | choice                         |
      | approves it                      | its allow once choice          |
      | approves it for the session      | its allow always choice        |
      | declines it                      | its reject once choice         |
      | cancels it                       | that the request was cancelled |

  @backlog
  Scenario Outline: An approval answered with a choice the agent did not offer is cancelled
    Given "acme" asks for an approval and offers <choices>
    When <answer>
    Then "acme" is told that the request was cancelled

    Examples:
      | choices              | answer                                       |
      | only reject once     | the user approves it                         |
      | only allow once      | the user approves it for the session         |
      | only allow once      | the user declines it                         |
      | only reject once     | the thread's mode would approve it by itself |
      | only allow once      | the thread's mode would decline it by itself |

  @backlog
  Scenario: A mode that approves by itself prefers the agent's lasting choice
    Given the thread's mode approves what "acme" asks for without asking the user
    When "acme" offers both allow once and allow always
    Then "acme" is told its allow always choice

  @backlog
  Scenario: A turn the agent cancels by itself ends as cancelled, not as stopped by the user
    Given the user did not stop the turn
    When "acme" ends its prompt saying it was cancelled
    Then the turn ends as cancelled
    And a turn the user stopped ends as interrupted instead

  @backlog
  Scenario: Tool output an agent sends as a list of byte values is shown as text
    When "acme" reports a tool's output as a list of whole numbers instead of text
    Then the output is shown as the text those bytes spell
    And its leading and trailing spaces are kept

  @backlog
  Scenario: An agent session that is no longer needed is closed with the agent
    Given "acme" says it can close sessions
    When the MC lets go of an idle "acme" session
    Then "acme" is asked to close the session
    And it is not asked while a stop or a restart of the agent is under way

  @backlog
  Scenario Outline: A thread an agent cannot hold or read says why
    When <attempt>
    Then the request is refused with "<message>"

    Examples:
      | attempt                                                                  | message                                            |
      | a thread is opened on an agent that never named a session                | ACP runtime did not produce a session id           |
      | a thread's history is asked of an agent that cannot load another session | ACP driver does not support session/load snapshots |

  # AcpRegistryDriver.ts: what a registry instance says before and around its first check.
  @backlog
  Scenario Outline: A registry instance that has not been checked says what it is waiting for
    Given the registry instance "acme" is <state> and has not been checked yet
    When the user opens the provider list
    Then "acme" is shown with a warning and "<message>"

    Examples:
      | state      | message                                      |
      | enabled    | Checking ACP Registry agent readiness...     |
      | turned off | ACP Registry is disabled in HAL-C2 settings. |

  @backlog
  Scenario: A registry agent whose install cannot be looked up says why
    Given looking up how "acme" is installed fails with the reason "registry unreadable"
    When the MC checks "acme"
    Then "acme" is shown with "Could not inspect ACP Registry agent: registry unreadable"

  @backlog
  Scenario: Asking a registry instance for a title or commit message anyway is refused
    When a thread title or a commit message is asked of the registry instance "acme"
    Then it is refused with "ACP Registry instances do not provide application text generation."

  # AcpClientFs.ts
  @backlog
  Scenario Outline: A file the client cannot read or write for an agent is answered with the path
    Given the thread lets "acme" read and edit files
    When "acme" asks the client to <operation> "/w/locked.txt" and the file system refuses
    Then "acme" is answered "<answer>"

    Examples:
      | operation | answer                                     |
      | read      | Could not read text file '/w/locked.txt'.  |
      | write     | Could not write text file '/w/locked.txt'. |

  # AcpClientPolicy.ts: what an approval the user gave covers at the client boundary.
  @backlog
  Scenario Outline: An approved command lets the agent run client terminals for as long as the user chose
    Given the thread asks before acting
    And the user approved a command of "acme" <choice>
    When "acme" asks the client to run a command in a terminal <later>
    Then the command is <outcome>

    Examples:
      | choice           | later            | outcome                             |
      | for this turn    | in the same turn | run                                 |
      | for this turn    | in the next turn | refused until the user approves one |
      | for this session | in the next turn | run                                 |

  @backlog
  Scenario: An approval that named no files covers every file for its scope
    Given the thread asks before acting
    And the user approved a file change for which "acme" named no files
    When "acme" writes any file through the client in the same turn
    Then the write is carried out without asking again
    But the approval does not let "acme" run commands through the client

  @backlog
  Scenario: An approval for a folder covers the files below it and nothing beside it
    Given the thread asks before acting
    And the user approved a change by "acme" to the folder "/w/src"
    When "acme" writes "/w/src/app/main.ts" through the client
    Then the write is carried out without asking again
    But a write to "/w/docs/readme.md" is refused until the user approves it

  @backlog
  Scenario: A file request through a link that leads nowhere is refused
    Given the thread lets "acme" edit only the workspace
    And the workspace holds a link whose target no longer exists
    When "acme" asks to write through that link
    Then the request is denied

  # AcpSessionConfig.ts
  @backlog
  Scenario: Modes an agent also offers as a session option are shown once
    Given "acme" offers the same choices as its modes and as a thinking-level session option
    When the user opens the options of an "acme" model
    Then the choices are offered once, under the session option
    And no separate "Mode" option is added

  @backlog
  Scenario: Grouped choices of a session option are offered as one list
    Given "acme" offers a session option whose choices are arranged in groups
    When the user opens the options of an "acme" model
    Then the option offers every choice of every group in one list
    And an option left without a usable choice is not offered at all

  # AcpClientTerminals.ts
  @backlog
  Scenario: An agent that never releases its client terminals is stopped at 64 of them
    Given "acme" holds 64 terminals it asked the client for and has released none, most of them already finished
    When "acme" asks for another terminal
    Then it is refused with "ACP terminal/create exceeded the limit of 64 unreleased terminals."

  @backlog
  Scenario: A client terminal the agent released is gone for the agent but its output stays in the thread
    Given "acme" ran a command in a terminal it asked the client for and showed that terminal in a tool call
    When "acme" releases the terminal
    Then the command is stopped if it was still running
    And asking for that terminal again is refused as an unknown terminal
    And the tool call in the thread still shows the command's output

  @backlog
  Scenario: Output of released client terminals is kept for the 32 newest only
    Given "acme" has released more than 32 client terminals, or their kept output exceeds 16 MiB
    When another terminal is released
    Then the output of the oldest released terminals is forgotten first

  @backlog
  Scenario: A client terminal of one session cannot be reached from another
    Given "acme" created a client terminal in one session
    When a request names that terminal from a different session
    Then it is refused as an unknown terminal

  @backlog
  Scenario: A command the client cannot start for an agent is answered with its name
    When "acme" asks the client to run "no-such-tool" in a terminal and it cannot be started
    Then "acme" is answered "Could not start terminal command 'no-such-tool'."
    And no terminal is counted for it

  @backlog
  Scenario: A client terminal ended by a signal reports the signal instead of an exit code
    Given "acme" runs a command in a terminal it asked the client for
    When the command is ended by the signal "SIGTERM"
    Then waiting for the terminal answers with no exit code and the signal "SIGTERM"

  @backlog
  Scenario: A terminal shown in a tool call that the client does not know is shown by its name
    When "acme" shows the terminal "t-9" in a tool call and the client has no such terminal
    Then the tool call shows "[terminal t-9]" in place of output

  # AcpRegistryProbe.ts
  @backlog
  Scenario Outline: A failed check says whether sign-in or the test session went wrong
    Given the registry agent "acme" is installed
    When the test session the MC opens on "acme" fails because <failure>
    Then the check reports "<message>"

    Examples:
      | failure                                                   | message                                          |
      | the agent answers that authentication is required         | The ACP agent could not complete authentication. |
      | the agent's error speaks of credentials or of logging in  | The ACP agent could not complete authentication. |
      | the agent exits or fails for any other reason             | The ACP agent could not create a test session.   |

  @backlog
  Scenario: A check waits half a second for the agent's commands
    Given "acme" announces its commands shortly after a session starts
    When the MC checks the instance
    Then commands announced within half a second of the test session starting are listed
    And the check does not wait longer than that for an agent that announces none

  @backlog
  Scenario: A terminal sign-in method comes with the command that would run it
    Given "acme" offers a terminal sign-in that adds the argument "login" and sets the variable "ACME_MODE" to "team plan"
    When the MC checks the instance
    Then the method carries the command line "ACME_MODE='team plan'" followed by the agent's command and "login"
    And a command line longer than 2,048 characters is left out

  @backlog
  Scenario: A sign-in method that reads variables names at most 16 of them and links only to web addresses
    Given "acme" offers a sign-in method that reads more than 16 variables and links to an address that is not http or https
    When the MC checks the instance
    Then the method names the first 16 variables
    And it carries no link

  @backlog
  Scenario Outline: A session or model provider request the agent fails says what could not be done
    When the user <action> and "acme" answers with an error
    Then the user is told "<message>"

    Examples:
      | action                           | message                                          |
      | deletes one of its sessions      | Could not delete the ACP session.                |
      | lists its model providers        | Could not list ACP providers.                    |
      | changes a model provider         | Could not update the ACP provider configuration. |
      | disables a model provider        | Could not update the ACP provider configuration. |

  @backlog
  Scenario: A sign-out from session settings the agent does not answer in a minute times out
    When the user signs out from session settings and "acme" does not answer within 60 seconds
    Then the user is told "The ACP logout request timed out."

  @backlog
  Scenario: A listed session without a usable id or folder is left out
    Given "acme" lists a session whose id is empty and one whose folder is padded with spaces
    When the user lists the agent's sessions
    Then neither of them is listed
    And the other sessions are listed with titles cut to 1,024 characters

  @backlog
  Scenario: A model provider's current setting is shown only when its address is a web address
    Given "acme" reports a model provider whose current base address is not http or https
    When the user lists its model providers
    Then that model provider is listed without a current setting

  # AcpRegistryAuth.ts: the steps of a sign-in that can fail before the agent is asked.
  @backlog
  Scenario Outline: A sign-in whose agent cannot be reached says which step failed
    Given <problem>
    When the user <step> "acme"
    Then the user is told "<message>"

    Examples:
      | problem                                                 | step                          | message                                                |
      | how "acme" is installed cannot be looked up             | opens sign-in for             | Could not inspect the selected ACP agent.              |
      | "acme" cannot be made ready to run                      | starts signing in to          | Could not prepare the selected ACP agent.              |
      | the process of "acme" cannot be started                 | starts signing in to          | Could not start the selected ACP agent.                |
      | "acme" does not complete its first exchange             | starts signing in to          | Could not initialize the selected ACP agent.           |
      | "acme" fails while its sign-in methods are being read   | opens sign-in for             | Could not discover this agent's sign-in methods.       |
      | the login terminal cannot be opened                     | starts a terminal sign-in for | Could not open the provider sign-in terminal.          |
      | "acme" refuses a session after a sign-in that succeeded | finishes signing in to        | The provider could not create a session after sign-in. |

  @backlog
  Scenario: Sign-in methods are read once for each version of an agent
    Given the MC read the sign-in methods of version "1.2.0" of "acme"
    When the user opens sign-in for "acme" again
    Then "acme" is not started to read them again
    But an instance that runs an executable override is asked every time

  # AcpRegistrySupport.ts: the corners of fetching the registry and installing from it.

  @backlog
  Scenario Outline: A registry that answers badly says what went wrong
    Given the MC holds no cached copy of the registry
    When the registry <problem>
    Then the fetch fails with "<message>"

    Examples:
      | problem                                   | message                                                                                                       |
      | answers with an error status              | Could not fetch ACP Registry index from https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json. |
      | breaks off while its answer is being read | Could not read ACP Registry response body.                                                                    |
      | stalls for 30 seconds while being read    | Timed out reading ACP Registry response body.                                                                 |
      | answers with bytes that are not UTF-8     | ACP Registry index is not valid UTF-8.                                                                        |

  @backlog
  Scenario: Searches made at the same moment fetch the registry once
    Given the registry can be reached
    When two clients search the registry at the same moment
    Then the registry is fetched once
    And both searches are answered from that one fetch

  @backlog
  Scenario: Starting a session with no cached registry fetches it
    Given an instance of "acme" exists and the MC holds no cached copy of the registry
    When a thread starts a session with "acme"
    Then the registry is fetched before "acme" is started

  @backlog
  Scenario Outline: A registry entry that could not be stored safely is left out
    Given the registry lists an agent whose <part>
    When the user searches the registry
    Then that agent is not offered

    Examples:
      | part                                                       |
      | name is blank                                              |
      | version is "." or ".." or holds a path separator           |
      | id holds upper-case letters, spaces or a path separator    |
      | npx package is written the way a uvx package pins versions |

  @backlog
  Scenario Outline: A downloaded agent is unpacked by the kind of file it is
    Given the registry publishes "acme" as a download ending in "<ending>"
    When the user installs "acme"
    Then the download is <handling>

    Examples:
      | ending   | handling                                       |
      | .tar.gz  | unpacked as a gzip tar archive                 |
      | .tgz     | unpacked as a gzip tar archive                 |
      | .tar.bz2 | unpacked as a bzip2 tar archive                |
      | .tbz2    | unpacked as a bzip2 tar archive                |
      | .zip     | unpacked as a zip archive                      |
      | .bin     | kept as the agent's command and made runnable  |

  @backlog
  Scenario: A zip download is unpacked on Windows without an unzip tool
    Given the MC runs on Windows and the registry publishes "acme" as a zip download
    When the user installs "acme"
    Then the archive is listed and unpacked with the system's tar

  @backlog
  Scenario: An archive that lists more files than can be checked is rejected
    Given the listing of the archive downloaded for "acme" is larger than 1 MB
    When the user installs "acme"
    Then adding "acme" fails with "ACP Registry install command 'tar' produced more output than expected."
    And nothing is unpacked

  @backlog
  Scenario Outline: A download that cannot be fetched or kept says so
    When the download of "acme" 1.2.0 <problem>
    Then adding "acme" fails with "<message>"
    And nothing is installed

    Examples:
      | problem                   | message                                           |
      | is answered with an error | Could not download ACP Registry agent acme 1.2.0. |
      | cannot be written to disk | Could not save ACP Registry agent acme 1.2.0.     |

  @backlog
  Scenario: An installed binary is checked again every time it is used
    Given the binary of "acme" was installed
    And its command was since replaced by a link to a file outside the install folder
    When a thread starts a session with "acme"
    Then the session fails with "ACP Registry archive command resolves outside its installation directory."
    And "acme" is not started

  @backlog
  Scenario Outline: A package install that fails says which command failed
    Given the registry agent "acme" runs through npx as "acme@1.2.0"
    When npm <problem> while the MC prepares "acme"
    Then preparing "acme" fails with "<message>"

    Examples:
      | problem                                             | message                                                                           |
      | exits with code 1 and prints "E404 not found"       | ACP Registry install command '/usr/bin/npm' exited with code 1: E404 not found    |
      | cannot be started                                   | Could not run ACP Registry install command '/usr/bin/npm'.                        |
      | has not finished installing after 20 minutes        | Timed out running ACP Registry install command '/usr/bin/npm'.                    |
      | does not say where it installs within 30 seconds    | Timed out running ACP Registry install command '/usr/bin/npm'.                    |
      | names an install folder that is not a single path   | ACP Registry package manager '/usr/bin/npm' returned an invalid global path.      |
      | installs the package but exposes no usable command  | ACP Registry installed acme@1.2.0, but could not resolve its global command.      |

  @backlog
  Scenario Outline: The command of an npm package is chosen among the ones it publishes
    Given the npm package "@acme/acme-acp" of the registry agent "acme" publishes <commands>
    When the MC prepares "acme"
    Then <outcome>

    Examples:
      | commands                                                 | outcome                                              |
      | one command "run-acme"                                   | "run-acme" is the command that runs the agent        |
      | the commands "acme-acp" and "helper"                     | "acme-acp" is the command that runs the agent        |
      | the commands "acme" and "helper"                         | "acme" is the command that runs the agent            |
      | two other names that both lead to the same file          | the first of them by name runs the agent             |
      | two other names that lead to different files             | preparing fails because no command can be told apart |

  @backlog
  Scenario Outline: The command of a uv tool is looked for under the agent's names
    Given the uv tool "acme-acp" of the registry agent "<agent>" exposes the command "<command>"
    When the MC prepares "<agent>"
    Then "<command>" is the command that runs the agent

    Examples:
      | agent    | command  |
      | acme     | acme     |
      | acme-cli | acme-acp |
      | other    | acme     |

  @backlog
  Scenario: A package agent whose installed files are gone or changed is installed again
    Given the package of "acme" was installed at the registry's version
    And its command was since deleted or its package replaced by another version
    When the MC prepares "acme"
    Then the package is installed again at the registry's exact version

  @backlog
  Scenario: A package agent is installed the same way when npm's own global folder belongs to the system
    Given npm on the MC is set to install global packages into a folder the MC may not write
    When the MC prepares the npx agent "acme"
    Then "acme" is installed under the MC's tools folder all the same

  @backlog
  Scenario: A package agent's own command comes first on its path
    Given the registry agent "acme" runs through npx and another "acme" command is on the MC's path
    When a thread starts a session with "acme"
    Then the command the MC installed is the one that runs
    And the folder it was installed into comes first on the agent's path

  @backlog
  Scenario: A prepared agent nobody added within 30 seconds can be uninstalled again
    Given a client prepared "acme" and no instance of "acme" was added
    When 30 seconds pass and the MC is asked to uninstall "acme"
    Then the downloaded files for "acme" are removed

  @backlog
  Scenario: Uninstalling an agent still used by an instance removes nothing
    Given an instance of "acme" exists
    When the MC is asked to uninstall "acme"
    Then the uninstall reports that nothing was removed
    And the downloaded files for "acme" are kept

  @backlog
  Scenario Outline: An uninstall that cannot be carried out says why
    When the MC is asked to uninstall <request>
    Then the uninstall fails with "<message>"

    Examples:
      | request                                        | message                                                                 |
      | an agent id that is not a valid registry id    | ACP Registry managed binary uninstall received an invalid agent ID.     |
      | "acme" while its install folder cannot be read | Could not inspect the managed binary cache for ACP Registry agent acme. |
      | "acme" while its files cannot be deleted       | Could not remove managed binaries for ACP Registry agent acme.          |

  @backlog
  Scenario: A session asked of an instance with no agent chosen is refused
    Given a registry instance has no agent chosen
    When a thread starts a session on that instance
    Then it fails with "ACP Registry provider requires a registry agent ID."

  @backlog
  Scenario: Package agents still run on a machine the registry publishes no binaries for
    Given the MC runs on a machine that is neither macOS, Linux nor Windows on arm64 or x64
    When the user searches the registry
    Then agents that run through npx or uvx are offered
    And agents published only as binaries are left out

  # AcpRuntimeModel.ts, AcpSessionRuntime.ts: how an agent's updates become the thread's timeline.
  @backlog
  Scenario Outline: An option set to a value of the wrong kind is refused
    Given "acme" offers <option>
    When a client sets it to <value>
    Then it is refused with '<message>'

    Examples:
      | option                                   | value          | message                                                                  |
      | the on/off option "web"                  | the text "yes" | Invalid value "yes" for session config option "web": expected boolean    |
      | the option "thinking" with named choices | on             | Invalid value true for session config option "thinking": expected string |

  @backlog
  Scenario: An agent's thinking is shown apart from its answer
    When "acme" streams its thoughts and then its answer in one turn
    Then the thoughts are shown as the turn's thinking
    And they are not part of the answer

  @backlog
  Scenario: What an agent writes after using a tool starts a new message
    Given "acme" wrote some text and then ran a tool
    When "acme" writes more text
    Then the thread shows the first text, the tool and the later text as three items in that order
    And text that is only spaces does not start a new message

  @backlog
  Scenario Outline: The command a tool ran is read from wherever the agent names it
    When "acme" reports a tool that <names>
    Then the tool is shown with the command "<command>"

    Examples:
      | names                                                        | command      |
      | carries the command "npm test" as text                       | npm test     |
      | carries the command as the list "npm" and "test"             | npm test     |
      | carries the program "npm" and the arguments "run" and "lint" | npm run lint |
      | carries only the program "npm"                               | npm          |
      | names the command only between backticks in its title        | npm test     |

  @backlog
  Scenario Outline: A tool is shown as the kind of work the agent says it is
    When "acme" runs a tool it describes as <described>
    Then the thread shows it as <shown>

    Examples:
      | described                   | shown         |
      | running something           | a command     |
      | editing, deleting or moving | a file change |
      | searching or fetching       | a web search  |
      | anything else, or nothing   | a tool call   |

  @backlog
  Scenario: A linked resource in an agent's answer is shown by its name and address
    When "acme" links a resource in its answer
    Then the answer shows the resource's title, or its name, or "resource" when it has neither
    And its description follows the name when it has one
    And its address is shown on the next line, unless the address carries the data itself

  @backlog
  Scenario Outline: Context usage is shown from what the agent reports and no more
    When "acme" reports <report>
    Then the context meter shows <shown>

    Examples:
      | report                                              | shown                                |
      | tokens used and a window size of 0                  | the tokens used, with no window size |
      | tokens used, a window size and a cost in a currency | the cost with its currency as well   |
      | a cost without a currency                           | no cost                              |
      | only its total tokens when it goes idle             | that total as the tokens used        |

  @backlog
  Scenario: A character split across two pieces of terminal output is kept whole
    Given an ACP v2 agent runs a command in its own terminal
    When a character of more than one byte arrives half in one piece of output and half in the next
    Then the output shows that character once and unbroken

  @backlog
  Scenario: Updates an agent sends for another of its sessions are not mixed into the thread
    Given a thread runs on one session of "acme"
    When "acme" sends updates for a session it started by itself
    Then the thread does not show them

  @backlog
  Scenario: An approval says what it is for
    When "acme" asks permission for a tool
    Then the approval names the tool's command when it has one, and its title otherwise
    And an approval for a tool with neither names the agent's session

  @backlog
  Scenario: A request to an agent whose session is closing is refused
    Given the session of "acme" is being closed
    When a client asks that session for something more
    Then the request fails with "The ACP session runtime is closed."

  # packages/effect-acp (client.ts, protocol.ts, errors.ts): what an agent sees on the wire.
  @backlog
  Scenario: The first message to an agent can be read by an agent of either protocol generation
    When the MC starts "acme"
    Then the initialization offers protocol generation 2 and still carries the older generation's client capabilities
    And HAL-C2 names itself "hal-c2" when the instance gives no client name

  @backlog
  Scenario Outline: Signing in, signing out and loading a session use the names of the agent's generation
    Given "acme" answered the initialization as generation <generation>
    When the MC <does>
    Then "acme" receives "<method>"

    Examples:
      | generation | does                   | method         |
      | 1          | signs in               | authenticate   |
      | 2          | signs in               | auth/login     |
      | 1          | signs out              | logout         |
      | 2          | signs out              | auth/logout    |
      | 1          | loads an older session | session/load   |
      | 2          | loads an older session | session/resume |

  @backlog
  Scenario Outline: A request the agent's generation does not have is refused without being sent
    Given "acme" answered the initialization as generation <generation>
    When the MC <does>
    Then the request fails with "Method not found: <method>"
    And "acme" is sent nothing

    Examples:
      | generation | does                         | method            |
      | 1          | deletes a session            | session/delete    |
      | 1          | lists model providers        | providers/list    |
      | 1          | sets a model provider        | providers/set     |
      | 1          | disables a model provider    | providers/disable |
      | 2          | sets the model the older way | session/set_model |

  @backlog
  Scenario: On the newer generation a turn ends when the agent says it is idle
    Given "acme" answered the initialization as generation 2
    When "acme" acknowledges a prompt and later reports the session idle
    Then the turn ends at the idle report, with the stop reason and usage it carries
    And an idle report that gives no stop reason ends the turn as an ordinary end of turn

  @backlog
  Scenario: A second prompt for a session that already has one is refused
    Given "acme" answered the initialization as generation 2
    And a prompt is running on the session "s1"
    When another prompt is sent to "s1"
    Then it fails with "ACP session 's1' already has an active prompt."

  @backlog
  Scenario: Stopping a turn reaches the agent as a notification that carries no id
    Given a turn is running on "acme"
    When the user stops the turn
    Then "acme" receives "session/cancel" without an id
    And a prompt sent right after the stop reaches "acme" after it, not before

  @backlog
  Scenario: A request HAL-C2 gave up waiting for is not followed by a message the agent cannot read
    Given the MC is waiting for "acme" to answer a request
    When the MC stops waiting for it
    Then "acme" is sent nothing about the abandoned request
    And an answer that arrives afterwards is ignored

  @backlog
  Scenario: An answer whose id is text does not settle a request whose id is a number
    Given the MC sent "acme" a request with the id 1
    When "acme" sends an answer with the id "1" as text
    Then the request is still waiting

  @backlog
  Scenario: A message from an agent that arrives in pieces is read whole
    When one message from "acme" arrives split across several reads, one split inside a character
    Then the MC reads it as one message with the character intact

  @backlog
  Scenario: A line from an agent that is not a protocol message ends the connection
    When "acme" writes a line to its output that is not valid JSON
    Then requests waiting on "acme" fail with "ACP protocol operation 'decode-wire-message' failed."
    And the agent's exit afterwards is not reported as a second failure

  @backlog
  Scenario: A request to an agent that has already exited says how it exited
    Given "acme" exited with code 7 between turns
    When the MC sends "acme" a request
    Then the request fails with "ACP process exited with code 7"
    And nothing is written to the agent

  @backlog
  Scenario: A session update that does not have the protocol's shape ends the connection
    Given a turn is running on "acme"
    When "acme" sends a session update whose fields are of the wrong kind
    Then the turn fails with "ACP protocol operation 'decode-notification-payload' failed for method 'session/update'."
    And the failure does not repeat the values the agent sent

  @backlog
  Scenario: A sign-in method of a kind HAL-C2 does not know is left out
    When "acme" of generation 2 advertises a sign-in method of the unknown kind "hologram"
    Then that method is not offered
    And it is not offered as the agent's own sign-in either

  @backlog
  Scenario Outline: An agent's request for input is understood under every name the protocol has used
    When "acme" sends "<method>"
    Then it is handled as <what>

    Examples:
      | method                       | what                           |
      | elicitation/create           | a request for input            |
      | session/elicitation          | a request for input            |
      | _session/elicitation         | a request for input            |
      | elicitation/complete         | the end of a request for input |
      | session/elicitation/complete | the end of a request for input |

  @backlog
  Scenario Outline: A request for input that cannot be served is refused with a protocol error
    When "acme" sends a request for input <case>
    Then "acme" is answered with the error <error>
    And the user is asked nothing

    Examples:
      | case                           | error                                                                   |
      | that is malformed              | -32602 "Invalid payload for ACP extension method 'elicitation/create'." |
      | while nothing can ask the user | -32601 "Method not found: elicitation/create"                           |

  @backlog
  Scenario Outline: An extension request HAL-C2 cannot serve is answered with a stable error
    When "acme" sends the extension request "x/thing" <case>
    Then "acme" is answered with the error <error>

    Examples:
      | case                                 | error                                                              |
      | with a payload of the wrong shape    | -32602 "Invalid payload for ACP extension method 'x/thing'."       |
      | and answering it fails inside HAL-C2 | -32603 "ACP extension request handler failed for method 'x/thing'" |

  # AcpRegistryAuthenticationState.ts: the corners of a remembered sign-in.
  @backlog
  Scenario: A damaged record of a confirmed sign-in is treated as not signed in
    Given the user signed in to "acme" from HAL-C2
    And the record of that sign-in on disk can no longer be read
    When the MC restarts
    Then "acme" is not shown as signed in until it is checked again

  @backlog
  Scenario: Signing in to one instance does not sign in another instance of the same agent
    Given two instances of "acme"
    When the user signs in to the first from HAL-C2
    Then the second is not shown as signed in

  @backlog
  Scenario: The record of a confirmed sign-in holds none of the instance's secrets
    Given an instance of "acme" with a secret environment variable
    When the user signs in to it from HAL-C2
    Then what the MC keeps on disk about the sign-in does not contain the variable's value
