# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/providers-antigravity.md
#   docs/internals/providers.md (isolated profiles, installer leases, sign-in owned by the initiating session, reject revert before touching files)
#   apps/server/src/provider/Layers/AntigravityProvider.ts, apps/server/src/provider/AntigravityAuth.ts
#   apps/server/src/provider/antigravityAuthSupport.ts, apps/server/src/provider/antigravityCallback.ts
#   apps/server/src/provider/AntigravityInstallation.ts, apps/server/src/provider/antigravityRelease.ts
#   apps/server/src/provider/acp/AntigravityAcpSupport.ts, apps/server/src/provider/acp/AntigravityProtocol.ts
#   apps/server/src/orchestration-v2/Adapters/AntigravityAdapterV2.ts (open execute tools complete with the turn)
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex (open items close with the turn)
#   apps/web/src/components/settings/ProviderSetupSection.tsx
#   packages/contracts/src/rpc.ts (provider.install.start, provider.install.cancel, provider.install.remove, provider.install.subscribe, provider.auth.complete)
#   packages/contracts/src/providerSetup.ts (ProviderInstallState)

@plugin-antigravity @node
Feature: Antigravity
  Antigravity runs Google's official Antigravity ACP agent. The node downloads and
  verifies the runtime itself, keeps a private Google profile for each instance, and
  finishes browser sign-in even when the browser is on another device.

  Background:
    Given a connected environment with the project "shop"
    And Antigravity is enabled on that environment

  Scenario: Installing the Antigravity runtime shows its progress
    Given the Antigravity runtime is not installed
    When the user installs the Antigravity runtime
    Then the user sees the download progress in megabytes
    And then that it is extracting and then checking the runtime
    And finally that Antigravity is installed

  Scenario: Installation continues when the user leaves settings or reconnects
    Given the Antigravity runtime is downloading
    When the client disconnects and reconnects
    Then the download progress is still shown

  Scenario: Cancelling an installation keeps the previous runtime
    Given an older Antigravity runtime is installed and a new one is downloading
    When the user cancels the installation
    Then the user is told the previous runtime is unchanged

  Scenario: A download that does not match its checksum is rejected
    Given the downloaded runtime does not match the published checksum
    When the installation checks the download
    Then the installation fails
    And the previous runtime is unchanged

  Scenario: A failed installation can be retried
    Given the Antigravity installation failed for lack of disk space
    When the user frees space and retries the installation
    Then the runtime is installed

  Scenario: Removing the downloaded runtime keeps the Google sign-in
    Given the Antigravity runtime is installed and the user is signed in
    And no Antigravity session is running
    When the user removes the downloaded runtime and confirms
    Then the runtime is removed
    And the Google sign-in and thread history are kept

  Scenario: The runtime cannot be removed while it is in use
    Given an Antigravity session is running
    When the user tries to remove the downloaded runtime
    Then the removal is refused until the sessions and sign-ins stop

  Scenario: An unsupported platform cannot install the runtime
    Given the environment runs on an Intel Mac
    When the user opens Antigravity setup
    Then the user is told Google does not publish a runtime for this platform
    And is offered to set a binary path or use another environment

  Scenario: A manual installation is used through the binary path
    Given the user extracted the Antigravity executable and its helper into one folder
    When the user sets the binary path to that executable
    Then Antigravity uses that installation
    And the managed installer leaves it alone

  Scenario: A manual installation missing its helper is explained
    Given the binary path points to an Antigravity executable without its helper
    When the user refreshes provider status
    Then the user is told the executable or its helper is missing

  Scenario: Signing in with a Google account in the browser
    Given the Antigravity runtime is installed
    When the user signs in with a Google account and finishes in the browser
    Then Antigravity confirms access and loads the account's models

  Scenario: Finishing sign-in from another device by pasting the return address
    Given the user started sign-in from a phone connected to a remote environment
    And the final Google page failed to load
    When the user pastes the full return address into the sign-in
    Then Antigravity confirms access

  Scenario: A return address from another sign-in is rejected
    Given the user started sign-in on one client
    When a return address from a different sign-in attempt is pasted
    Then the user is told the address does not belong to the current sign-in

  Scenario: A successful callback page alone does not mean the user is signed in
    Given the Google page says sign-in succeeded
    When Antigravity cannot confirm account access
    Then Antigravity is not shown as signed in
    And the user is told why

  Scenario: An Antigravity sign-in expires after five minutes
    Given the user started Google sign-in
    When five minutes pass without finishing
    Then the user is told Google sign-in expired

  Scenario Outline: Antigravity sign-in methods
    When the user chooses the sign-in method <method> and provides <credentials>
    Then Antigravity connects with that method

    Examples:
      | method                     | credentials                                  |
      | Google account             | a browser sign-in                            |
      | Gemini Enterprise          | a browser sign-in, GCP project and location  |
      | Gemini API key             | an API key                                   |
      | Agent Platform             | an API key, or a GCP project and location    |

  Scenario: Ambient Google credentials do not override the instance's method
    Given the environment has a Gemini API key in its variables
    And the Antigravity instance uses a Google account
    When a thread runs on Antigravity
    Then the Google account is used

  Scenario: Changing the sign-in method stops the instance's sessions
    Given an Antigravity session is running
    When the user changes the sign-in method
    Then the instance's sessions stop

  Scenario: Signing out removes the saved Google login and keeps history
    Given the user is signed in to Antigravity
    When the user signs out
    Then the instance's sessions stop and its saved Google login is removed
    And thread history is kept

  Scenario: Sending logout in a thread signs out its instance
    When the user sends "/logout" by itself in an Antigravity thread
    Then that instance is signed out

  Scenario: An older runtime that cannot sign out asks for an update
    Given the Antigravity runtime does not support sign-out
    When the user signs out
    Then the user is told to update the provider

  Scenario: Disabling Antigravity keeps the sign-in
    Given the user is signed in to Antigravity
    When the user disables Antigravity
    Then its sessions stop
    And the Google sign-in is kept for when it is enabled again

  Scenario: Each Google account is its own instance
    Given two Antigravity instances "work" and "personal"
    When the user signs in to each with a different Google account
    Then each instance uses its own account and the downloaded runtime is shared

  Scenario: A server restart keeps the Google sign-in
    Given the user is signed in to Antigravity
    When the node restarts
    Then Antigravity still shows the saved account

  Scenario: Reverting an Antigravity thread is not offered
    Given an Antigravity thread with two turns
    When the user tries to revert to the first turn
    Then the revert is refused before any file is touched

  Scenario: Plan mode is not offered for Antigravity
    When the user opens the mode picker in an Antigravity thread
    Then plan mode is not offered

  Scenario Outline: Antigravity attachment limits
    When the user attaches <attachment> to an Antigravity message
    Then the attachment is <outcome>

    Examples:
      | attachment                    | outcome  |
      | a 900 KiB text file           | accepted |
      | a 2 MiB text file             | rejected |
      | a 12 MiB image                | rejected |
      | a 15 MiB audio clip           | accepted |
      | files totalling 60 MiB        | rejected |
      | an unsupported file format    | rejected |

  @backlog
  Scenario: Antigravity reads a file of a kind it does not recognise by its path
    Given the project has a file whose kind Antigravity does not recognise
    When Antigravity asks for that file by its path
    Then Antigravity receives the file's contents

  @backlog
  Scenario: Antigravity cannot leave the workspace
    Given an Antigravity thread works in the project's folder
    When Antigravity asks for a path outside that folder
    Then the request is refused

  Scenario: Antigravity reads project skills from its skill folders in order
    Given the project has the skill "deploy" in both .gemini/skills and .agents/skills
    When the user opens the skill list in an Antigravity thread
    Then "deploy" is offered once, from .gemini/skills

  Scenario: Antigravity subagents are grouped into batches
    When Antigravity starts subagents
    Then their activity is shown as a subagent batch

  Scenario: A model the account lost is explained on resume
    Given an Antigravity thread uses a model the account can no longer use
    When the user sends a message
    Then the user is asked to pick another available model

  Scenario: Antigravity account restrictions are passed on
    When Google reports that a subscription is required
    Then the thread shows Google's message and any retry time

  Scenario: Signing in from the mobile app once the runtime is installed
    Given the Antigravity runtime is installed on the environment
    When the user signs in from the mobile app's provider accounts
    Then Antigravity confirms access

  # Antigravity completes the commands a turn left open, and its subagent batches
  # finish inside the turn, so nothing outlives it.
  Scenario: A command Antigravity leaves running ends with its turn
    When Antigravity ends a turn with a command still running
    Then the command it left running ends with the turn
