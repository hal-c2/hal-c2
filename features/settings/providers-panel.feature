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

    # The desktop does not know what its own session may do yet.
    @backlog @desktop
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

    @backlog @desktop
    Scenario: Providers wait for what the session may change before they can be edited
      Given the user's session has not yet been told what it may change on "Build box"
      When the user shows the providers of "Build box"
      Then the user is told the session is being checked for what it may change
      And no setting can be changed until that is known

    @backlog @desktop
    Scenario: A permissions check that fails does not lock an older environment
      Given "Build box" runs a version that does not report what a session may change
      When the user shows the providers of "Build box"
      Then the providers can be edited
      And a change the environment refuses is reported

    @backlog @desktop
    Scenario: An edit in progress survives a permissions refresh
      Given the user is typing a provider's display name
      When the session's permissions are checked again in the background
      Then the panel stays on the provider
      And the text the user typed is kept

    @backlog @desktop
    Scenario Outline: With nothing to show the panel says what is missing
      Given <state>
      When the user opens the Providers settings
      Then the user is told "<message>"

      Examples:
        | state                                    | message                                                             |
        | no environment is connected              | Connect an execution environment before configuring providers.      |
        | the environments are still being read    | Reading connected execution environments.                           |

    # Legacy: apps/web/src/components/settings/ProviderSettingsPanel.logic.ts (resolveSelectedProviderEnvironmentId)
    @backlog @desktop
    Scenario Outline: The environment shown falls back when the chosen one is gone
      Given the user chose to show the providers of "Build box"
      And <situation>
      When the Providers settings are shown
      Then the providers of "<shown>" are listed

      Examples:
        | situation                                                          | shown     |
        | "Build box" was removed and this machine is still there            | This machine |
        | "Build box" and this machine were removed and "Laptop" is left     | Laptop    |

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

    @backlog @desktop
    Scenario: An instance id may not be longer than 64 characters
      When the user enters an instance id of 65 letters and continues
      Then the user stays on the identity step and is told "Instance ID must be 64 characters or fewer."

    @backlog @desktop
    Scenario: A long label still gets a usable instance id
      Given an instance with the id suggested for a 100 character label exists
      When the user adds a "Claude" provider with that label
      Then the suggested instance id is a number-suffixed id of at most 64 characters

    @backlog @desktop
    Scenario: A provider can be added without typing anything
      When the user chooses "Claude" and adds it with the suggested label and id
      Then an instance with the id "claudeAgent" is listed
      And it is shown with the provider's own name

    @backlog @desktop
    Scenario: Jumping ahead past an invalid id stops at the identity step
      Given the instance id is invalid
      When the user jumps straight to the configuration step
      Then the user lands on the identity step
      And the problem with the id is shown

    @backlog @desktop
    Scenario: Each provider keeps its own label and accent while choosing
      Given the user typed the label "Work" for "Claude" and picked a green accent
      When the user chooses "Codex" and then "Claude" again
      Then "Claude" still has the label "Work" and the green accent

    @backlog @desktop
    Scenario: The wizard cannot be moved while an instance is being saved
      Given the user is adding a provider instance and saving has started
      When the user tries to move to another step or add it again
      Then nothing changes
      And only one instance is created

    @desktop
    Scenario: An instance that cannot be saved is reported
      Given saving settings on "Laptop" fails
      When the user adds a provider instance
      Then the user is told the provider instance could not be added

    # Legacy: apps/web/src/components/settings/providerDriverMeta.ts (badgeLabel, hasDefaultInstance)
    @backlog @desktop
    Scenario Outline: A provider still in early access is marked in the choices and on its instances
      When the user opens the choice of providers to add
      Then "<provider>" is marked "Early Access"
      And every "<provider>" instance in the list carries the same mark

      Examples:
        | provider     |
        | Pi           |
        | ACP Registry |

    # Legacy: apps/web/src/components/settings/providerDriverMeta.ts (hasDefaultInstance: false)
    @backlog @desktop
    Scenario: ACP Registry agents exist only as instances the user adds
      Given no ACP Registry agent has been added
      When the user opens the provider settings
      Then no ACP Registry instance is listed
      And ACP Registry is offered only when adding an instance

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

    @desktop
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

    @backlog @desktop
    Scenario: The registry step lists compatible agents before the user types
      When the user opens the ACP Registry step
      Then the compatible agents are listed without a search
      And the user is told how many were found

    @backlog @desktop
    Scenario: The registry is searched when typing pauses
      When the user types "gem" and keeps typing
      Then the registry is not searched on every letter
      When the user stops typing for a moment
      Then the registry is searched for "gem"
      When the user presses Enter
      Then the registry is searched at once

    @backlog @desktop
    Scenario: Searching again for the same text refreshes the results
      Given the user searched the ACP Registry for "gemini"
      When the user searches for "gemini" again
      Then the results are read again
      And the earlier results stay visible while they refresh

    @backlog @desktop
    Scenario: A registry that cannot be reached reports why
      Given the ACP Registry cannot be reached from the environment
      When the user opens the ACP Registry step
      Then the user is shown the reason the search failed

    @backlog @desktop
    Scenario Outline: An agent being prepared says what is happening
      Given the registry agent "<agent>" is distributed <distribution>
      When the user adds "<agent>"
      Then the agent shows "<progress>"
      And searching is unavailable until it is ready

      Examples:
        | agent      | distribution | progress    |
        | gemini-cli | as a binary  | Downloading |
        | other-cli  | as a package | Preparing   |

    @backlog @desktop
    Scenario: An agent that cannot be prepared says why and the user can try another
      Given preparing "gemini-cli" fails with "The agent could not be downloaded."
      When the user adds "gemini-cli"
      Then the user is shown "The agent could not be downloaded."
      And the user can search for and add another agent

    @backlog @desktop
    Scenario: Registry icons are only fetched from the official registry
      Given a registry agent has an icon outside the official registry address
      When the registry results are shown
      Then that icon is not fetched
      And the agent shows its default icon

    @backlog @desktop
    Scenario Outline: A registry icon that is not a small image is not used
      Given the registry agent's icon <problem>
      When the registry results are shown
      Then the agent shows its default icon

      Examples:
        | problem                          |
        | is larger than 512 KB            |
        | is not an image                  |
        | redirects to another address     |

    # The browser's persistent cache for registry icons has no counterpart on the native clients.
    @desktop @dropped
    Scenario: A registry icon is fetched once and kept
      Given the registry lists the same icon for several agents
      When the registry results are shown on two days
      Then the icon is fetched once and reused

  Rule: Native ACP sessions and model providers

    @backlog @desktop
    Scenario: Native sessions are listed for one project at a time
      Given the environment has the projects "hal-c2" and "shop"
      When the user lists the native sessions of the agent
      Then the sessions of the first project are listed
      When the user chooses "shop"
      Then the sessions of "shop" are listed

    @backlog @desktop
    Scenario: Native sessions need a project to import into
      Given the environment has no projects
      When the user opens an agent that lists native sessions
      Then the user is told to add a project before importing sessions

    @backlog @desktop
    Scenario: A long list of native sessions loads more on request
      Given the agent has more native sessions than it returns at once
      When the user lists the native sessions
      Then the first page is listed with an option to load more
      When the user loads more
      Then the next page is added below the first

    @backlog @desktop
    Scenario: Importing a session that was already imported says so
      Given a native session was already imported as a thread
      When the user imports that session again
      Then the user is told it was already imported
      And no second thread is created

    @backlog @desktop
    Scenario Outline: Only what the agent supports is offered for native sessions
      Given the agent <ability>
      When the user opens its native sessions
      Then <offer>

      Examples:
        | ability                         | offer                                    |
        | cannot list sessions            | no session list is offered               |
        | can list but not resume or load | sessions are listed but cannot be imported |
        | can list but not delete         | sessions are listed without delete       |

    @backlog @desktop
    Scenario: Deleting a native session asks first and names it
      Given the agent has a native session titled "Fix login"
      When the user deletes that session
      Then the user is asked to confirm permanently deleting "Fix login"
      When the user cancels
      Then the session is still listed

    @backlog @desktop
    Scenario: A session without a title is named by its id when deleting
      Given the agent has a native session with no title and the id "s-42"
      When the user deletes that session
      Then the user is asked to confirm permanently deleting "s-42"

    @backlog @desktop
    Scenario: One session operation at a time per project
      Given the user is importing a native session
      Then listing, importing, deleting and changing project are unavailable until it finishes

    @backlog @desktop
    Scenario: A failed session or provider operation is reported with its reason
      Given the agent refuses to list its sessions with "Not signed in."
      When the user lists the native sessions
      Then the user is told the sessions could not be listed and why

    @backlog @desktop
    Scenario Outline: A model provider needs an API type and a base URL before saving
      Given the agent offers a configurable model provider
      When the user leaves <missing> empty
      Then saving is not possible

      Examples:
        | missing    |
        | the API type |
        | the base URL |

    @backlog @desktop
    Scenario: A model provider's API type is chosen from what the agent supports
      Given the agent's model provider supports two API types
      When the user opens the model provider
      Then only those two API types are offered
      And a model provider already set shows its current API type and base URL

    @backlog @desktop
    Scenario: A model provider shows whether it is configured
      Given the agent has one model provider configured and one that is not
      When the user lists the agent's model providers
      Then the configured one is marked "Configured" and the other "Disabled"

    @backlog @desktop
    Scenario: Disabling a model provider asks first
      When the user disables a configured model provider
      Then the user is asked to confirm disabling it by name
      When the user cancels
      Then the model provider stays configured

    @backlog @desktop
    Scenario: Saved headers are never shown again
      Given a model provider was saved with an authorization header
      When the user lists the agent's model providers again
      Then the headers field is empty and says headers are write-only

    @backlog @desktop
    Scenario Outline: Logging out is offered only when the agent cannot be signed in from HAL-C2
      Given the agent can sign out and <sign-in>
      When the user opens the agent's native sessions
      Then logging out <result>

      Examples:
        | sign-in                         | result           |
        | signs in from its own terminal  | is offered       |
        | signs in from HAL-C2            | is not offered   |

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

    @backlog @desktop
    Scenario: Emptying a setting field removes it so the default applies
      Given an OpenCode instance has the server URL "http://127.0.0.1:4096"
      When the user empties the server URL
      Then the instance no longer stores a server URL
      And the settings the panel does not show are kept as they were

    @backlog @desktop
    Scenario Outline: A switch left at its default is not stored
      Given a provider setting that is <default> by default and currently <stored>
      When the user sets it to <chosen>
      Then <outcome>

      Examples:
        | default | stored | chosen | outcome                          |
        | off     | on     | off    | the setting is no longer stored  |
        | on      | off    | on     | the setting is no longer stored  |
        | on      | unset  | off    | the setting is stored as off     |

    @backlog @desktop
    Scenario: Providers nobody set up are not listed
      Given only Codex and Claude have been configured
      When the user opens the Providers settings
      Then Codex and Claude are listed
      And the providers that were never configured and are off are not listed

    @backlog @desktop
    Scenario Outline: A disabled provider the user configured stays listed
      Given Grok is off and <configured>
      When the user opens the Providers settings
      Then Grok is listed

      Examples:
        | configured                         |
        | the user added an instance of it   |
        | the user gave it a binary path     |

    @backlog @desktop
    Scenario: A link to a provider that was removed does not open another account
      Given the user follows a link to the instance "claudeAgent_work"
      And that instance no longer exists on this environment
      When the Providers settings open
      Then the user is told the provider instance is no longer available on this device
      And no other instance is selected or changed

    @backlog @desktop
    Scenario: A link to a provider opens that instance
      Given the user follows a link to the instance "claudeAgent_work"
      When the Providers settings open
      Then "claudeAgent_work" is shown for editing

    @backlog @desktop
    Scenario: With no providers configured the panel says so
      Given the environment has no provider instances
      When the user opens the Providers settings
      Then the user is told no providers are configured

    @backlog @desktop
    Scenario: Changing one instance leaves the others as another client saved them
      Given another client changed the display name of "claudeAgent_work" after this panel loaded
      When the user turns "codex" off in this panel
      Then only "codex" changes
      And "claudeAgent_work" keeps the name the other client saved

    @backlog @desktop
    Scenario: Resetting or deleting an instance keeps the user's model preferences
      Given the user favourited and hid models of "codex" on this device
      When the user resets "codex" to its defaults
      Then the favourite and hidden models are kept on this device

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

    @backlog @desktop @plugin-antigravity
    Scenario Outline: The runtime card says where the runtime stands
      Given <state>
      When the user opens the Antigravity instance
      Then the card says "<status>"

      Examples:
        | state                                                         | status                                              |
        | the runtime is not installed and its size is not known        | Not installed.                                      |
        | the runtime is not installed and the download is 140 MB       | 140 MB download.                                    |
        | 12.5 MB of a 140 MB download have arrived                      | Downloading 12.5 MB of 140.0 MB.                    |
        | the download is being unpacked                                | Extracting Antigravity.                             |
        | the download is being checked                                 | Checking the downloaded runtime.                    |
        | the runtime is installed                                      | Installed.                                          |
        | a custom binary path is set and nothing runs there            | The configured Antigravity runtime is unavailable.  |
        | a custom binary path is set and the instance is off           | The configured Antigravity runtime has not been checked. |

    @backlog @desktop @plugin-antigravity
    Scenario Outline: The install action names what it will do
      Given <state>
      When the user opens the Antigravity instance
      Then the install action reads "<action>"

      Examples:
        | state                                         | action                      |
        | nothing is installed                          | Install Antigravity         |
        | a managed runtime is not installed yet        | Install managed runtime     |
        | a newer runtime is available                  | Update Antigravity          |
        | the runtime is installed and current          | Reinstall Antigravity       |
        | the last installation failed                  | Retry installation          |

    @backlog @desktop @plugin-antigravity
    Scenario: Removing the runtime says what is kept
      Given the Antigravity runtime is installed on "Laptop"
      When the user removes the downloaded runtime
      Then the user is asked to confirm removing it from "Laptop"
      And the question says the Google sign-in and thread history are kept

    @backlog @desktop @plugin-antigravity
    Scenario: A custom binary path is not hidden by a managed install
      Given a managed runtime is installed
      And the instance's binary path points at a runtime that does not work
      When the user opens the Antigravity instance
      Then Antigravity is shown as unavailable
      And signing in is not offered

    @backlog @desktop @plugin-antigravity
    Scenario Outline: Antigravity setup is withheld when this session cannot use it
      Given <state>
      When the user opens the Antigravity instance
      Then the card says "<message>"
      And no installation or sign-in is started

      Examples:
        | state                                   | message                                      |
        | the session may only view providers     | Provider setup is read-only.                 |
        | the environment is too old for setup    | Update this environment to manage Antigravity. |

    @backlog @desktop @plugin-antigravity
    Scenario: Pressing sign in twice starts one sign-in
      Given Antigravity is signed out
      When the user presses sign in twice before the first start has answered
      Then one sign-in is started

    @backlog @desktop @plugin-antigravity
    Scenario Outline: Sign-in actions follow what is known about the account
      Given the account is <account>
      When the user opens the Antigravity instance
      Then the instance offers <actions>

      Examples:
        | account                                                 | actions                    |
        | signed out                                              | sign in only               |
        | unknown                                                 | sign in only               |
        | signed in, with the runtime unable to name the account  | change account and sign out |
        | signed in earlier but its credentials expired            | sign in again              |

    @backlog @desktop @plugin-antigravity
    Scenario: A sign-in is finished from the pasted address only while it is current
      Given the user pasted a return address for a sign-in that was since replaced
      When the user submits it
      Then nothing is sent to the environment
      And the sign-in state is read again

    @backlog @desktop @plugin-antigravity
    Scenario: A pasted return address shows signed in only once the environment confirms it
      Given the user submitted a return address
      When the environment has not yet verified the sign-in
      Then the card does not say "Signed in."
      When the environment confirms the sign-in
      Then the card says the user is signed in

    @backlog @desktop @plugin-antigravity
    Scenario: The same status message is shown once
      Given the runtime and the sign-in report the same problem
      When the user opens the Antigravity instance
      Then the problem is shown once

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

    # MCs join only by clustering, and a cluster member's sign-ins run from here.
    @dropped @desktop
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

    @backlog @desktop
    Scenario: Signing out says what it will stop
      Given "Gemini" is signed in from HAL-C2 on "Laptop"
      When the user signs out of "Gemini"
      Then the user is asked to confirm signing out of "Gemini" on "Laptop"
      And the question says threads sharing the sign-in are stopped and thread history is kept

    @backlog @desktop
    Scenario: A device code is shown to type in the browser
      Given "Gemini" can sign in from HAL-C2 and is signed out
      When the user signs in to "Gemini" and the agent asks for a device code
      Then the code is shown with the instruction to enter it in the browser

    @backlog @desktop
    Scenario: The sign-in link can be copied
      Given "Gemini" is waiting for the user to finish signing in in the browser
      When the user copies the sign-in link
      Then the link is on the clipboard
      When the clipboard cannot be written
      Then the user is told the link could not be copied

    @backlog @desktop
    Scenario: A sign-in page that cannot be opened offers the link
      Given "Gemini" is waiting for the user to finish signing in in the browser
      When the user opens the sign-in page and the computer cannot open it
      Then the user is told to copy the link and open it in a browser

    @backlog @desktop
    Scenario Outline: The panel says what sign-in is possible
      Given <state>
      When the user opens the instance
      Then the account row says "<message>"

      Examples:
        | state                                               | message                                                              |
        | the agent has not yet advertised its sign-in methods | Discovering sign-in methods…                                         |
        | the agent advertises no sign-in the app can run     | No in-app sign-in advertised. Follow the provider's docs to finish setup. |
        | the agent can sign in and the user is signed out    | Sign in on Laptop.                                                   |

    @backlog @desktop
    Scenario: A method the agent no longer offers is not sent
      Given the user chose the sign-in method "API key"
      And the agent stopped offering "API key"
      When the user signs in
      Then the sign-in starts with the provider's default method

    @backlog @desktop
    Scenario: A long pasted answer reaches the sign-in terminal in pieces in order
      Given the agent's login terminal waits for input
      When the user pastes 10,000 characters into the sign-in terminal
      Then the environment receives them in order, 4,096 characters at a time

    @backlog @desktop
    Scenario: A failed send to the sign-in terminal drops what was still queued
      Given the user pasted a long answer into the sign-in terminal
      When the environment rejects one piece
      Then the pieces that had not been sent are discarded
      And the user is told the input could not be sent

    @backlog @desktop
    Scenario Outline: The wizard's sign-in step can be finished or skipped
      Given the user added an agent that signs in from HAL-C2 and <state>
      When the sign-in step is shown
      Then the step offers "<action>"

      Examples:
        | state                  | action        |
        | is not signed in yet   | Skip for now  |
        | is signed in           | Done          |

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

    # Legacy: apps/web/src/components/settings/providerStatus.ts (getProviderVersionLabel)
    @backlog @desktop
    Scenario Outline: A provider's version is shown in one readable form
      Given a provider reports the version "<reported>"
      When the user looks at the provider
      Then its version reads "<shown>"

      Examples:
        | reported                        | shown      |
        | 1.2.3                           | v1.2.3     |
        | v1.2.3                          | v1.2.3     |
        | nightly-build                   | nightly-build |
        | agy_acp_server_20260818_01_RC01 | 2026-08-18 RC01 |
        | agy_acp_server_20260818_01      | 2026-08-18 |

    # Legacy: apps/web/src/components/settings/providerStatus.ts (getProviderVersionAdvisoryPresentation)
    @backlog @desktop
    Scenario Outline: A version warning without a message from the MC still says what to do
      Given the installed "OpenCode" is of limited support and the MC gave no message
      And <recommendation>
      When the user opens the version details of "OpenCode"
      Then the details say "<detail>"

      Examples:
        | recommendation                                  | detail                         |
        | "1.14.19" is the recommended version            | Use v1.14.19 for full support. |
        | the supported range is "1.14 to 1.16"           | Use 1.14 to 1.16 for full support. |
        | no version or range is recommended              | Update for full support.       |

    # Legacy: apps/web/src/components/settings/providerStatus.ts (getProviderVersionAdvisoryPresentation)
    @backlog @desktop
    Scenario Outline: A newer provider version that does not work with this release is not offered
      Given "Codex" is behind its latest release
      And the latest release is <status> for this HAL-C2 release
      When the user opens the version details of "Codex"
      Then no update is offered

      Examples:
        | status              |
        | known to be broken  |
        | unsupported         |

    # Legacy: apps/web/src/components/settings/providerStatus.ts (getProviderVersionAdvisoryPresentation)
    @backlog @desktop
    Scenario: A provider that is up to date shows no version warning
      Given "Codex" is on its latest release
      When the user opens the version details of "Codex"
      Then no update or warning is shown

  Rule: The models list

    @desktop
    Scenario: A model lists what it can do
      Given Claude reports a model with fast mode, thinking and reasoning options
      When the user opens Claude's models
      Then that model is labelled "Fast mode", "Thinking" and "Reasoning"

    @desktop
    Scenario: A long models list can be filtered and counted
      Given Codex reports twelve models, two of them favourites and one hidden
      When the user opens Codex's models
      Then the list says "12 models · 2 favorites · 1 hidden"
      When the user filters the models by "mini"
      Then only models whose name or id has "mini" are listed

    @backlog @desktop
    Scenario Outline: An empty models list says why
      Given <state>
      When the user opens the provider's models
      Then the list says "<message>"

      Examples:
        | state                                     | message                                  |
        | the provider has not reported any models  | No models reported for this provider yet. |
        | the user filtered the models by "zzz"     | No models match.                         |

    @backlog @desktop
    Scenario: Favourites come first and hidden models sink to the end
      Given Codex has the models "a", "b" and "c", "c" is a favourite and "a" is hidden
      When the user opens Codex's models
      Then the list shows "c", then "b", then "a"

    @backlog @desktop
    Scenario: Moving a model only moves it within its group
      Given "b" is the last visible model and "a" is hidden below it
      When the user moves "b" down
      Then "b" stays above "a"
      And the order is kept on this device

    @backlog @desktop
    Scenario: Every built-in model can be disabled or enabled at once
      Given Codex has built-in models "a" and "b", a custom model "mine" and a hidden entry for a model that is gone
      When the user disables all models
      Then "a" and "b" are hidden from the picker
      And "mine" is still offered
      When the user enables all models
      Then "a" and "b" are offered again
      And the hidden entry for the model that is gone is kept

    @backlog @desktop
    Scenario: A custom model cannot be hidden from the picker
      When the user looks at the picker switch of a custom model
      Then the switch is on and cannot be turned off
      And it is explained that custom models are always shown in the picker

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

    @desktop
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

    # Legacy: apps/web/src/components/settings/ProviderModelsSection.tsx (handleAdd, MAX_CUSTOM_MODEL_LENGTH)
    @backlog @desktop
    Scenario: A custom model id longer than 256 characters is refused
      When the user adds a custom model to Claude whose id has 257 characters
      Then the user is told "Model slugs must be 256 characters or less."
      And nothing is saved

    # Legacy: apps/web/src/components/settings/ProviderModelsSection.tsx (FILTER_THRESHOLD, handleAdd)
    @backlog @desktop
    Scenario: A short models list has no filter
      Given Codex reports eight models
      When the user opens Codex's models
      Then the models cannot be filtered
      When Codex reports a ninth model
      Then the models can be filtered

    # Legacy: apps/web/src/components/settings/ProviderModelsSection.tsx (handleAdd clears the filter)
    @backlog @desktop
    Scenario: A custom model added while filtering is shown at once
      Given Codex reports twelve models and the user filtered them by "mini"
      When the user adds the custom model "my-model" to Codex
      Then the filter is cleared
      And "my-model" is listed and brought into view

    # Legacy: apps/web/src/components/settings/ProviderModelsSection.tsx (driverKind antigravity)
    @backlog @desktop @plugin-antigravity
    Scenario: Antigravity's models cannot be extended with custom ones
      When the user opens Antigravity's models
      Then no custom model can be added

    @desktop
    Scenario: A custom model without options uses the provider's defaults
      When the user adds a custom model with no options
      Then the composer uses the provider's default options for it

    @backlog @desktop
    Scenario Outline: A custom option that repeats an id is named in the message
      Given the custom model "my-model" has the options <options>
      When the user saves the custom model
      Then the user is told "<message>"
      And nothing is saved

      Examples:
        | options                                            | message                                |
        | "effort" and "effort"                              | Option 2: id "effort" is used twice.   |
        | "effort" with the choices "low" and "low"          | Option 1: choice "low" is used twice.  |
        | "effort" with a choice that has no value           | Option 1 has a choice without a value. |

    @backlog @desktop
    Scenario: A custom model's name falls back to its id
      When the user adds the custom model "my-model" and leaves its name empty
      Then the model is listed as "my-model"

    @backlog @desktop
    Scenario: A custom choice without a label is shown by its value
      When the user adds a choice with the value "high" and no label to a custom option
      Then the composer lists that choice as "high"

    @backlog @desktop
    Scenario: A custom option offers the options the provider actually reads
      When the user adds an option to a custom Claude model
      Then the suggested options are reasoning, fast mode and thinking
      And an option with any other id is saved as typed

    @backlog @desktop
    Scenario: Copying options from Claude leaves out what a custom model cannot carry
      Given a built-in Claude model offers an "ultrathink" reasoning choice and a context window
      When the user copies the options of that model into a custom model
      Then the copy offers the reasoning choices except "ultrathink"
      And the copy does not offer the context window

    @backlog @desktop
    Scenario: A custom option can be a switch
      When the user adds a custom option that is on or off
      Then the composer offers it as a switch
