# Sources:
#   apps/web/src/components/settings/ProviderSettingsPanel.tsx
#   apps/web/src/components/settings/ProviderSettingsPanel.logic.ts
#   apps/web/src/components/settings/ProviderInstanceCard.tsx
#   apps/web/src/components/settings/AddProviderInstanceDialog.tsx
#   apps/web/src/components/settings/AddProviderInstanceDialog.logic.ts
#   apps/web/src/components/settings/AddProviderInstanceWizardSteps.tsx
#   apps/web/src/components/settings/AcpRegistrySearchStep.tsx
#   apps/web/src/components/settings/AcpSessionManagementSection.tsx
#   apps/web/src/components/settings/ProviderModelsSection.tsx (capability labels, filter, count)
#   apps/web/src/components/settings/ProviderWizardAuthenticationStep.tsx (the wizard's sign-in step)
#   apps/web/src/components/settings/CustomModelEditor.tsx
#   apps/web/src/components/settings/customModelEditor.logic.ts
#   apps/web/src/components/settings/RedactedSensitiveText.tsx
#   apps/web/src/components/settings/ProviderSetupSection.tsx (the managed Antigravity runtime)
#   apps/server-ex/lib/hal_c2/acp/antigravity/installation.ex (provider.install.start, provider.install.cancel, provider.install.remove)
#   apps/server-ex/lib/hal_c2/acp/url_auth.ex (Continue authentication, server.acceptAcpRegistryUrlAuth)
#   apps/web/src/components/settings/providerStatus.ts (version advisory titles, Update now, Install <version>)
#   apps/server-ex/lib/hal_c2/provider_updates.ex (versionAdvisory, updateCommand, canUpdate)
#   apps/server-ex/lib/hal_c2/rpc.ex (server.refreshProviders, server.updateProvider, server.searchAcpRegistry,
#     server.prepareAcpRegistryAgent, server.uninstallAcpRegistryManagedBinary, server.listAcpRegistrySessions,
#     server.importAcpRegistrySession, server.deleteAcpRegistrySession, server.listAcpRegistryProviders,
#     server.setAcpRegistryProvider, server.disableAcpRegistryProvider, server.logoutAcpRegistry)
#   apps/server-ex/lib/hal_c2/acp/catalog.ex
#   apps/server-ex/lib/hal_c2/acp/sessions.ex
#   apps/server-ex/lib/hal_c2/environment.ex (refresh_providers)
#   apps/server-ex/lib/hal_c2/web/socket.ex (config.providers)
#   apps/tui/src/features.backlog.test.ts (editable-settings, provider maintenance)
#   apps/web/src/components/settings/ProviderAuthenticationSection.tsx
#   apps/desktop-qt/src/native/ProviderSettingsController.cpp, apps/desktop-qt/qml/HalC2/Bricks/ProvidersSettings.qml
#   apps/desktop-qt/tests/tst_ProvidersSettings.qml (the account email stays hidden until asked)

Feature: Providers settings panel
  The Providers page lists the agent providers configured on one environment. The user adds
  instances, edits their settings, models and variables, keeps them updated, and manages ACP
  agents from the registry. Provider behaviour itself is specified in the providers domain.

  Background:
    Given the user has opened the Providers settings for the environment "Laptop"

  Rule: Choosing the environment and refreshing

    @desktop
    Scenario: This machine is listed first among environments
      Given the user has environments "Laptop", "Build box" and this machine
      When the user chooses which environment's providers to show
      Then this machine is listed first and the others follow by name

    @desktop
    Scenario: A session that may only view providers cannot change them
      Given the user's session may view but not operate "Build box"
      When the user shows the providers of "Build box"
      Then the providers are shown read-only
      And the user is told this session can view the providers but not change their settings

    @desktop
    Scenario: A disconnected environment cannot be configured
      Given "Build box" is disconnected
      When the user shows the providers of "Build box"
      Then the user is told to reconnect the device to set up its provider

    @desktop
    Scenario: An environment that reconnects can be configured again
      Given "Build box" is disconnected
      And the user shows the providers of "Build box"
      When "Build box" reconnects
      Then the providers of "Build box" are listed

    @desktop
    Scenario: Leaving the Providers settings stops following providers
      Given "Gemini" can sign in from HAL-C2 and is signed out
      When the user leaves the Providers settings
      Then no provider or sign-in is followed for the panel

    @mc
    Scenario: Refreshing providers reads their status and models again
      When the user refreshes provider status
      Then the MC reads each provider's installation, sign-in and models again
      And every connected client receives the new provider list

    @desktop
    Scenario: The panel says when providers were last checked
      Given Codex was checked 10 minutes ago and Claude 2 minutes ago
      Then the panel says providers were last checked by the latest of them

    # The MC already honours the interval (providers/provider-instances.feature and
    # settings/background-service.feature); only this settings row is backlog.
    @desktop
    Scenario Outline: The health check interval controls background refreshes
      When the user sets the provider health check interval to <seconds> seconds
      Then providers are refreshed in the background <frequency>

      Examples:
        | seconds | frequency           |
        | 300     | every five minutes  |
        | 0       | never               |

  # Instance ids are derived as "<driver>_<label slug>" (AddProviderInstanceDialog.tsx
  # deriveInstanceId); Claude's driver is "claudeAgent". The MC side of instances, and the
  # same id rules, are in providers/provider-instances.feature.
  Rule: Adding a provider instance

    @desktop
    Scenario: Adding a second instance of a provider
      When the user adds a "Claude" provider labelled "Work"
      Then an instance with the id "claudeAgent_work" is listed
      And the user is told the instance was added

    @desktop
    Scenario: A taken instance id gets a number
      Given an instance "claudeAgent_work" exists
      When the user adds a "Claude" provider labelled "Work"
      Then the suggested instance id is "claudeAgent_work_2"

    @desktop
    Scenario Outline: The instance id must be valid before the user moves on
      Given an instance "claudeAgent_work" exists
      When the user enters the instance id "<id>" and continues
      Then the user stays on the identity step and is told "<message>"

      Examples:
        | id          | message                                                                          |
        |             | Instance ID is required.                                                          |
        | 9lives      | Instance ID must start with a letter and use only letters, digits, '-', or '_'.   |
        | claudeAgent_work | An instance named 'claudeAgent_work' already exists.                         |

    @desktop
    Scenario: Going back in the wizard is always allowed
      Given the user is on the configuration step of adding a provider
      When the user goes back to choosing a driver
      Then the choices already made are kept

    @desktop
    Scenario: An instance that cannot be saved is reported
      Given saving settings on "Laptop" fails
      When the user adds a provider instance
      Then the user is told the provider instance could not be added

  Rule: Adding an agent from the ACP Registry

    @mc
    Scenario: Searching the ACP Registry lists compatible agents best first
      When the user searches the ACP Registry for "gemini"
      Then the compatible agents matching "gemini" are listed best first

    @desktop
    Scenario: A search with no compatible agent suggests a broader search
      When the user searches the ACP Registry for "zzzz"
      Then the user is told no compatible agents were found and to try a broader search

    @mc
    Scenario: Choosing a registry agent installs its current version
      When the user adds the registry agent "gemini-cli"
      Then the MC prepares the agent's current version for this machine

    @desktop
    Scenario: An agent already added is marked instead of offered again
      Given "gemini-cli" is already configured
      When the user searches the ACP Registry for "gemini"
      Then "gemini-cli" is marked as already added

    @desktop
    Scenario: Choosing a registry agent names the new instance after it
      When the user chooses "gemini-cli" from the ACP Registry
      Then the new instance is named "Gemini CLI" and runs "gemini-cli"

    @desktop
    Scenario: An agent prepared after its wizard was closed does not fill a new one
      Given the user chose "gemini-cli" from the ACP Registry and it is still being prepared
      When the user closes the wizard and opens it again
      And the agent finishes preparing
      Then the new wizard still asks which agent to add

    @desktop @backlog-desktop
    Scenario: A registry agent in the results shows its details
      When the user searches the ACP Registry for "gemini"
      Then each agent shows its icon and description
      And an agent with a website or repository links to it as "About <agent>"

    @desktop @backlog-desktop
    Scenario: A registry agent that signs in is signed in before the wizard closes
      Given the user added a registry agent that signs in from HAL-C2
      When the wizard saves it
      Then the wizard moves on to signing in to that agent
      And the user can finish the wizard once signed in or skip it

    @desktop
    Scenario: The registry step needs an agent or a manual setup
      When the user moves on without choosing an agent
      Then the user is asked to select an ACP or configure one manually

    @mc
    Scenario: A registry agent still in use cannot be uninstalled
      Given a provider instance uses the registry agent "gemini-cli"
      When the MC is asked to uninstall "gemini-cli"
      Then the uninstall is refused

  Rule: Native ACP sessions and model providers

    @mc @desktop
    Scenario: Importing a native session continues it as a thread
      Given the agent "gemini" has a native session for the project "hal-c2"
      When the user imports that session
      Then a thread continuing the session is created in "hal-c2"

    @mc @desktop
    Scenario: An imported session cannot be deleted before its thread
      Given a native session was imported as a thread
      When the user deletes the native session
      Then the user is told to delete the imported thread first

    @mc @desktop
    Scenario: Deleting a native session that was not imported
      Given the agent "gemini" has a native session that was not imported
      When the user deletes it and confirms
      Then the session is deleted by the agent

    @mc @desktop
    Scenario: Pointing an agent's model provider at an API and disabling it
      When the user sets the agent's model provider to "https://api.example.com" with an authorization header
      Then the agent uses that base URL
      When the user disables that model provider
      Then the agent no longer uses it

    @desktop
    Scenario Outline: Model provider headers must be a JSON object of strings
      When the user saves the headers "<headers>"
      Then the user is told "<message>"

      Examples:
        | headers             | message                                          |
        | {not json           | Headers must be valid JSON.                      |
        | {"Authorization": 1} | Headers must be a JSON object with string values. |

    @mc @desktop
    Scenario: Logging out of an ACP agent
      When the user logs out of the agent "gemini"
      Then the agent is signed out and its status is read again

  Rule: Editing an instance

    @desktop
    Scenario: Turning an instance off and on
      When the user turns off the "Claude Work" instance
      Then its models are not offered in new threads
      When the user turns it back on
      Then its models are offered again

    @desktop
    Scenario: A change that cannot be saved is reported
      Given saving settings on "Laptop" fails
      When the user turns off the "Claude Work" instance
      Then the user is told the provider settings could not be saved
      And "Claude Work" stays on

    @desktop
    Scenario: Renaming an instance changes how it is shown
      When the user renames "Claude Work" to "Claude Client"
      Then the instance is shown as "Claude Client" in the model picker

    @desktop
    Scenario: Sensitive environment variables are stored separately
      When the user adds the environment variable "API_KEY" and marks it sensitive
      Then its value is stored as a secret
      And the page shows it as a stored secret that a new value replaces

    @desktop
    Scenario: Renaming a stored secret asks for its value again
      Given the instance keeps "API_KEY" as a stored secret
      When the user renames the variable "API_KEY" to "OPENAI_KEY"
      Then "OPENAI_KEY" asks for a new value instead of showing a stored secret
      And the secret stored for "API_KEY" is forgotten

    @desktop
    Scenario: A provider's own API key can be cleared for browser sign-in
      Given a Cursor instance keeps its own "CURSOR_API_KEY"
      Then Cursor says its API key is used instead of browser sign-in
      When the user clears "CURSOR_API_KEY"
      Then the secret stored for "CURSOR_API_KEY" is forgotten
      And Cursor can be signed in from the browser again

    @desktop
    Scenario: Removing an environment variable
      Given the instance has the environment variable "API_KEY"
      When the user removes "API_KEY"
      Then the instance no longer sets "API_KEY"

    @desktop
    Scenario: Deleting an instance
      When the user deletes the "Claude Work" instance
      Then it is no longer listed

    @desktop
    Scenario: Deleting an instance whose managed files remain is reported
      Given cleaning up the instance's managed binary fails
      When the user deletes the instance
      Then the user is told the provider was deleted but managed files remain

    # The scramble is the page's own; tests/tst_ProvidersSettings.qml drives it.
    @desktop
    Scenario: The signed-in account email stays hidden until asked
      Given "Claude Work" is signed in as "ada@example.com"
      Then the account email is shown scrambled
      When the user reveals the email
      Then "ada@example.com" is shown
      When the user hides it again
      Then it is scrambled again

  # Antigravity is the one provider whose runtime the MC installs itself; the
  # MC's side is in providers/provider-setup.feature.
  Rule: The managed Antigravity runtime

    @desktop @plugin-antigravity
    Scenario: Installing the managed runtime shows its download
      Given the Antigravity runtime is not installed on the environment
      When the user installs the Antigravity runtime
      Then the download's progress is shown as the environment reports it

    @desktop @plugin-antigravity
    Scenario: A runtime download can be cancelled from the card
      Given the Antigravity runtime is downloading on the environment
      When the user cancels the installation
      Then the environment cancels that download
      And the card says the previous runtime is unchanged and offers to retry

    @desktop @plugin-antigravity
    Scenario: A downloaded runtime is removed after asking
      Given the Antigravity runtime is installed on the environment
      When the user removes the downloaded runtime and confirms
      Then the environment removes it
      And the card offers installing Antigravity again

  # Sign-in is MC-addressed (provider.auth.*), so only environments a cluster MC serves
  # sign in from the panel. Signing out is in providers/provider-setup.feature.
  Rule: Signing in

    @desktop
    Scenario: Signing in finishes in the browser
      Given "Gemini" can sign in from HAL-C2 and is signed out
      When the user signs in to "Gemini"
      Then the user is asked to finish signing in in the browser
      When the user opens the sign-in page
      Then the provider's sign-in page opens in the browser

    # An agent can ask for a sign-in page outside a sign-in (HalC2.Acp.UrlAuth).
    @desktop
    Scenario: A sign-in page an agent waits on is continued from the panel
      Given "Gemini" is waiting for the user to open a sign-in page
      When the user continues the authentication
      Then the agent's sign-in page opens in the browser
      And the environment tells "Gemini" the page was opened

    @desktop
    Scenario: Continuing a sign-in page the agent stopped waiting on says so
      Given "Gemini" is waiting for the user to open a sign-in page
      And the request has expired on the environment
      When the user continues the authentication
      Then the user is told the authentication request expired

    @desktop
    Scenario: A sign-in in progress can be cancelled and tried again
      Given "Gemini" can sign in from HAL-C2 and is signed out
      And the user signs in to "Gemini"
      When the user cancels the sign-in
      Then the sign-in is cancelled on the environment
      And the user can retry signing in to "Gemini"

    @desktop
    Scenario: A sign-in that fails says why
      Given "Gemini" can sign in from HAL-C2 and is signed out
      And the user signs in to "Gemini"
      When the sign-in fails with "The browser was closed."
      Then the user is told why the sign-in failed: "The browser was closed."
      And the user can retry signing in to "Gemini"

    @desktop
    Scenario: A sign-in answered after switching environments and back does not free a newer one
      Given "Gemini" can sign in from HAL-C2 and is signed out
      And the user signs in to "Gemini" while the environment is slow to answer
      When the user switches to another environment and back and signs in to "Gemini" again
      And the first sign-in is answered
      Then the second sign-in is still waiting on the environment

    @desktop
    Scenario: Declining to sign out keeps the account signed in
      Given "Gemini" is signed in from HAL-C2
      When the user signs out of "Gemini" and declines
      Then "Gemini" is still signed in

    @desktop
    Scenario: An environment outside the cluster is signed in from its own clients
      Given "Build box" is linked and its "Gemini" can sign in from HAL-C2
      When the user shows the providers of "Build box"
      Then the user is told to sign in from a client paired with "Build box"

    @desktop
    Scenario: Choosing how to sign in
      Given "Gemini" offers the sign-in methods "Google" and "API key"
      When the user chooses "API key" and signs in to "Gemini"
      Then the sign-in starts with the method "API key"

    @desktop
    Scenario: Signing in through the agent's login terminal
      Given "Gemini" can sign in from HAL-C2 and is signed out
      And the user signs in to "Gemini"
      When the agent's login terminal shows "Press enter to continue"
      Then the user is asked to complete sign-in in a terminal showing "Press enter to continue"
      When the user types "y" in the sign-in terminal
      Then "y" reaches the sign-in terminal on the environment

    @desktop
    Scenario: A login terminal that has gone says so
      Given "Gemini" can sign in from HAL-C2 and is signed out
      And the user signs in to "Gemini"
      And the agent's login terminal shows "Press enter to continue"
      And the environment no longer has that login terminal
      When the user types "y" in the sign-in terminal
      Then the user is told why the sign-in failed: "The provider sign-in terminal is no longer available."

    @desktop
    Scenario: Signing in with credentials
      Given "Gemini" can sign in from HAL-C2 and is signed out
      And the user signs in to "Gemini"
      When the agent asks for the credential "GEMINI_API_KEY"
      And the user enters "sk-test" for it and connects
      Then the environment receives "sk-test" as "GEMINI_API_KEY"

    @desktop
    Scenario: Pasting the final sign-in address when its page does not load
      Given "Gemini" can sign in from HAL-C2 and is signed out
      And the user signs in to "Gemini"
      And the sign-in returns to a local address
      When the user pastes "http://localhost:1455/callback?code=abc" as the final sign-in address
      Then the environment finishes the sign-in with "http://localhost:1455/callback?code=abc"

  # MC behaviour of provider updates and version advisories is owned by settings/updates.feature
  # and providers/provider-setup.feature; this rule holds what the panel adds.
  Rule: Updates

    @mc
    Scenario: Updating a provider runs its updater and reports providers again
      Given "Codex" has an update available
      When the user updates "Codex"
      Then the MC runs the Codex updater
      And the provider list is reported again

    @desktop
    Scenario: An update that cannot run offers the command to copy
      Given the update command for "Codex" cannot be started here
      When the user copies the update command
      Then the command is on the clipboard
      And the user is told to run it in a terminal when ready

    @desktop
    Scenario: A provider behind its latest release offers to update now
      Given "Codex" is behind its latest release
      When the user opens the version details of "Codex"
      Then the user is told an update is available with the latest version
      And the user can update now or copy the update command

    @desktop
    Scenario: A provider update shows as running until it finishes
      Given "Codex" is behind its latest release
      When the user updates "Codex"
      Then "Codex" is shown updating
      When the update finishes
      Then "Codex" is no longer shown updating

    @desktop
    Scenario: An update that fails is reported
      Given "Codex" is behind its latest release
      And updating "Codex" fails with "npm exited with status 1"
      When the user updates "Codex"
      Then the user is told "Codex" could not be updated

    @desktop
    Scenario Outline: A provider version outside the supported range is flagged in the panel
      Given the installed "OpenCode" is <status> for this HAL-C2 release
      When the user opens the version details of "OpenCode"
      Then the user is warned "<title>" with the version to use for full support

      Examples:
        | status              | title                |
        | of limited support  | Limited support      |
        | unsupported         | Unsupported version  |
        | known to be broken  | Known broken version |

    @desktop
    Scenario: A recommended version is installed instead of the latest
      Given the installed "OpenCode" is known to be broken
      And "1.14.19" is the recommended version
      When the user opens the version details of "OpenCode"
      Then the user is offered to install "v1.14.19" rather than update to the latest

    @desktop
    Scenario: Installing the recommended version
      Given the installed "OpenCode" is known to be broken
      And "1.14.19" is the recommended version
      When the user installs the recommended version of "OpenCode"
      Then the environment installs "1.14.19" of "OpenCode"

  Rule: The models list

    @desktop @backlog-desktop
    Scenario: A model lists what it can do
      Given Claude reports a model with fast mode, thinking and reasoning options
      When the user opens Claude's models
      Then that model is labelled "Fast mode", "Thinking" and "Reasoning"

    @desktop @backlog-desktop
    Scenario: A long models list can be filtered and counted
      Given Codex reports twelve models, two of them favourites and one hidden
      When the user opens Codex's models
      Then the list says "12 models · 2 favorites · 1 hidden"
      When the user filters the models by "mini"
      Then only models whose name or id has "mini" are listed

  Rule: Custom models

    @desktop
    Scenario: Adding a custom model with its own options
      When the user adds the custom model "my-model" with a reasoning option offering low and high
      Then "my-model" is offered in the model picker
      And the composer offers low and high reasoning for it

    @desktop
    Scenario: Copying options from a built-in model
      When the user adds a custom model and copies the options of a built-in model
      Then the custom model starts with the same options

    @desktop
    Scenario Outline: A custom option must be complete before saving
      When the user saves a custom option with <problem>
      Then the user is told the option <message>

      Examples:
        | problem                       | message                    |
        | no id                         | needs an id                |
        | no label                      | needs a label              |
        | a choice list with no choices | needs at least one choice  |
        | the same choice twice         | uses a choice twice        |

    @desktop @backlog-desktop
    Scenario Outline: A custom model id is checked before it is saved
      Given Claude already has the custom model "my-model"
      When the user adds the custom model "<slug>" to Claude
      Then the user is told "<message>"
      And nothing is saved

      Examples:
        | slug             | message                             |
        |                  | Enter a model slug.                 |
        | claude-fable-5-1 | That model is already built in.     |
        | my-model         | That custom model is already saved. |

    @desktop
    Scenario: A custom model without options uses the provider's defaults
      When the user adds a custom model with no options
      Then the composer uses the provider's default options for it
