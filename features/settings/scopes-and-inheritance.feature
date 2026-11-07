# Sources:
#   https://github.com/pingdotgg/t3code/pull/24472
#   https://github.com/pingdotgg/t3code/pull/23672
#   https://github.com/pingdotgg/t3code/pull/16581
#   https://github.com/pingdotgg/t3code/pull/18503
#   https://github.com/pingdotgg/t3code/pull/18582
#   https://github.com/pingdotgg/t3code/pull/17370
#   https://github.com/pingdotgg/t3code/pull/18334
#   https://github.com/pingdotgg/t3code/pull/17879
#   apps/web/src/components/settings/scopedSettings.ts (planScopedSettingsPatch)
#   apps/web/src/components/settings/settingsScope.ts
#   apps/web/src/components/settings/settingsScopeAxis.ts
#   apps/web/src/components/settings/settingsScopeNavigation.ts
#   apps/web/src/components/settings/SettingsScopeContext.tsx
#   apps/web/src/components/settings/SettingsScopeSentence.tsx
#   apps/web/src/components/settings/SettingsScopeNotice.tsx
#   apps/desktop/src/settings/DesktopClientSettings.ts, apps/desktop/src/ipc/methods/clientSettings.ts (the desktop's own client settings file)
#   apps/web/src/components/settings/SettingInheritance.tsx
#   apps/web/src/components/settings/ScopedSwitch.tsx
#   apps/web/src/components/settings/useScopedSettings.ts
#   apps/web/src/components/settings/useScopedModelAvailability.ts
#   apps/web/src/components/settings/useSettingsProjectGroups.ts
#   packages/contracts/src/settings.ts (ServerSettings, ProjectSettingsOverrides, ServerSettingsPatch)
#   apps/server-ex/lib/hal_c2/settings.ex (versioned put, project resolution, watchers)
#   apps/server-ex/lib/hal_c2/rpc.ex (hal-c2.readSettings, hal-c2.writeSettings)
#   apps/server/src/serverSettings.ts (the settings file: sparse writes, unreadable file kept, retired values, folded project fields, secrets)
#   apps/server-ex/lib/hal_c2/web/socket.ex (config.settings)
#   https://github.com/pingdotgg/t3code/pull/28005
#   https://github.com/pingdotgg/t3code/pull/23669
#   https://github.com/pingdotgg/t3code/pull/23450
#   https://github.com/pingdotgg/t3code/pull/23678

Feature: Settings scopes and inheritance
  Settings apply to all environments, one environment, one project, or one checkout of a
  project. A narrower scope overrides a wider one, and the user can see where each value
  comes from and clear an override to inherit again.

  Background:
    Given the user has environments "Laptop" and "Build box"
    And the project "hal-c2" has a checkout on each environment

  Rule: The MC stores one versioned settings document

    @mc
    Scenario: A write at the version the client read is saved
      Given a client has read the settings at their current version
      When the client writes a changed settings document at that version
      Then the MC saves the document
      And the MC answers with the next version

    @mc
    Scenario: A stale write is refused instead of overwriting another editor
      Given two clients have read the settings at the same version
      And the first client has saved a change
      When the second client writes its change at the old version
      Then the MC refuses the write as stale settings
      And the first client's change is kept

    @mc
    Scenario: Connected clients receive every saved change
      Given a client is subscribed to this MC's settings
      When another client saves a settings change
      Then the subscribed client receives the new settings document

    @mc
    Scenario: A project sees its overrides over the environment's values
      Given the environment's default runtime mode is full access
      And the project "hal-c2" overrides the default runtime mode to approval required
      When the MC resolves the settings for "hal-c2"
      Then the default runtime mode is approval required
      And settings the project does not override keep the environment's values

    @mc
    Scenario: A project cannot override an environment-wide setting
      Given the project "hal-c2" has an override for an environment-wide setting
      When the MC resolves the settings for "hal-c2"
      Then that setting keeps the environment's value

    @mc
    Scenario: A project model override on a disabled provider falls back to the environment's
      Given the project "hal-c2" overrides the default model with a model from "Codex"
      And the "Codex" provider is disabled on this environment
      When the MC resolves the settings for "hal-c2"
      Then the default model is the environment's default model

    # Upstream #16581: a project's new model kept the previous model's options.
    @backlog @mc @desktop
    Scenario: A project's new model does not keep the old model's options
      Given the project "hal-c2" overrides the default model with "gpt-6-astra" at extra high effort
      When the user changes the project's default model to "gpt-6-luna"
      Then the project's default model is "gpt-6-luna" with its own default options
      And no effort is saved for it from "gpt-6-astra"

    # Upstream #17879. A project's provider switch overrides the environment's, and the MC
    # checks the project's value wherever a turn can start.
    @mc
    Scenario Outline: A project turns a provider on or off apart from its environment
      Given the "Codex" provider is <environment> on this environment
      And the project "hal-c2" <project>
      When a turn on "Codex" starts in "hal-c2"
      Then the turn <result>

      Examples:
        | environment | project                              | result                             |
        | enabled     | turns "Codex" off                    | is refused because "Codex" is off  |
        | disabled    | turns "Codex" on                     | starts                             |
        | disabled    | has no provider switch of its own    | is refused because "Codex" is off  |
        | enabled     | has no provider switch of its own    | starts                             |

    @mc
    Scenario Outline: Every way a turn starts honours the project's provider switch
      Given the project "hal-c2" turns "Codex" off
      When <how> on "Codex" in "hal-c2"
      Then no "Codex" turn starts

      Examples:
        | how                                               |
        | the user starts a new thread                      |
        | the user sends a message                          |
        | a queued message comes up                         |
        | a delegated task sends its follow-up              |
        | an agent starts a child thread or delegates by MCP |
        | a scheduled task runs                             |

    @mc
    Scenario: A running turn finishes when its project turns the provider off
      Given a "Codex" turn is running on a thread in "hal-c2" for a delegated task
      When the project "hal-c2" turns "Codex" off
      Then the running turn finishes
      And the delegated task's result still reaches its parent thread

    # Upstream #23669: a prepared turn could still be retried or released after its project
    # turned the provider off.
    @mc @priority-high
    Scenario Outline: A prepared turn does not start once its project turns the provider off
      Given a "Codex" thread in "hal-c2" is preparing its worktree
      And <when>
      When the project "hal-c2" turns "Codex" off
      And the prepared turn is <next>
      Then no "Codex" turn starts
      But a retry or release accepted before "Codex" was turned off is answered as before

      Examples:
        | when                             | next     |
        | its preparation failed           | retried  |
        | its preparation is still running | released |

    @mc
    Scenario: A provider off on the environment keeps running for a project that turned it on
      Given the "Codex" provider is disabled on this environment
      And the project "hal-c2" turns "Codex" on
      Then "Codex" stays available for turns in "hal-c2"
      And other projects still cannot start "Codex" turns

    @mc
    Scenario: Writing in a project falls back when the project turned the writer's provider off
      Given titles and commit messages are written by "Codex"
      And the project "hal-c2" turns "Codex" off
      When a title is written for a thread in "hal-c2"
      Then it is written by the next usable provider
      And titles in other projects are still written by "Codex"

    # Upstream #23672: stacked git actions from a draft thread resolve its project before picking a writer.
    @mc
    Scenario: A draft thread's commit message honours its project's provider switch from a subfolder
      Given commit messages are written by "Codex"
      And the project "hal-c2" turns "Codex" off
      And a draft thread in "hal-c2" works in a folder below the project root
      When the user commits and opens a pull request from that thread
      Then the commit message and pull request text are written by the next usable provider

    @mc
    Scenario: Deleting a project drops its provider switches
      Given the project "hal-c2" turns "Codex" off
      When the project "hal-c2" is deleted
      Then the settings keep no provider switch for "hal-c2"

    # Upstream #24472: a client older than its MC erased project overrides it did not know about.
    @backlog @mc @priority-high
    Scenario: A project edit from an older client keeps the overrides it does not know
      Given the project "hal-c2" overrides the thread title instructions
      And a client built before that setting existed
      When the user changes the project's auto-pull from that client
      Then the project keeps its thread title instructions override
      But resetting a setting the client knows still removes that override

    # Upstream #24472
    @mc
    Scenario: An MC older than its settings file keeps project overrides it does not know
      Given the settings file holds a project override written by a newer MC
      When an older MC loads it and the user edits that project
      Then the newer override is still in the settings file

    @mc
    Scenario: A settings file edited by hand reaches connected clients
      Given a client is connected to the MC
      When the user changes a setting in settings.json with a text editor
      Then the client receives the changed settings without the MC restarting

    @mc
    Scenario: A hand edit that is not valid JSON is ignored until it is fixed
      Given the MC is running with its settings
      When the user saves a settings.json that is not valid JSON
      Then the MC keeps using the settings it had
      And connected clients are not sent broken settings

    # Upstream #18582: a client's save no longer reverts a hand edit to settings.json the server had not read yet.
    @mc
    Scenario: A client's save keeps a hand edit the MC has not noticed yet
      Given the user edited settings.json by hand a moment ago
      When a client saves a different setting before the MC has read the edit
      Then settings.json holds both the hand edit and the client's change

    # Upstream #18582: the hand edit kept may sit inside an object the client changed too.
    @mc
    Scenario: A client's save to one provider keeps a hand edit to another
      Given the user edited one provider's settings in settings.json by hand a moment ago
      When a client saves another provider's setting before the MC has read the edit
      Then settings.json holds both providers' changes

    # Upstream #18582: a save over a settings.json that is not valid JSON is refused.
    @mc
    Scenario: A save over a settings file that is not valid JSON is refused and leaves it unchanged
      Given settings.json holds a hand edit that is not valid JSON
      When a client saves a setting
      Then the save is refused
      And settings.json still holds the user's text for them to fix

    @mc
    Scenario: A settings file that cannot be read at startup is kept for repair
      Given settings.json is not valid JSON
      When the MC starts
      Then the MC runs with the default settings
      And settings.json is left on disk unchanged
      And later settings changes do not overwrite it until it is repaired

    # Legacy: apps/desktop/src/settings/DesktopClientSettings.ts (readClientSettings), apps/desktop/src/ipc/methods/clientSettings.ts
    @backlog @desktop
    Scenario Outline: A client settings file that is missing is not an error but one that is damaged is
      Given the desktop app's client settings file <state>
      When the desktop app reads the client settings
      Then <outcome>

      Examples:
        | state                           | outcome                                                          |
        | does not exist                  | the app uses the default client settings                         |
        | cannot be decoded as settings   | the read fails and the damaged file is left on disk unchanged    |
        | cannot be opened                | the read fails and the user's saved choices are not overwritten  |

    @mc
    Scenario: The settings file is private to its owner and replaced in one step
      When a client saves a setting
      Then settings.json is readable only by the user the MC runs as
      And it is replaced in one step so a crash never leaves half a file

    @backlog @mc
    Scenario: Only settings that differ from the defaults are written
      Given the user changed one setting
      When the MC saves the settings
      Then settings.json holds only that setting
      And a setting the user never changed follows a newer version's default

    @backlog @mc @priority-low
    Scenario Outline: A retired streaming mode becomes the nearest current one
      Given settings.json sets the response streaming mode to "token"<where>
      When the MC reads the settings
      Then the streaming mode is "paragraph"
      And every other setting is as it was written

      Examples:
        | where                         |
        |                               |
        | for the project "shop" only   |

    @backlog @mc
    Scenario: An optional provider that threads already used stays available after an upgrade
      Given settings.json has no choice recorded for Grok
      And threads of this MC ran on Grok
      When the MC reads the settings
      Then Grok is enabled

    @backlog @mc
    Scenario: A provider the user turned off stays off even if threads used it
      Given settings.json turns Grok off
      And threads of this MC ran on Grok
      When the MC reads the settings
      Then Grok is not enabled

    @backlog @mc
    Scenario: A fresh install leaves the optional providers off
      Given no thread has run on Grok, Cursor or OpenCode
      When the MC reads the settings
      Then those providers are not enabled

    @backlog @mc
    Scenario: Settings kept per project by an older version are carried over once
      Given settings.json holds settings an older version kept on each project
      When the MC reads the settings for the first time
      Then those settings are kept as that project's overrides
      And they are not carried over again after the user changes the overrides

    @backlog @mc
    Scenario: A provider secret is not kept when the settings cannot be saved
      Given the MC's settings cannot be written
      When a client saves a provider instance with a new secret value
      Then the save is refused
      And the secret store holds the earlier value

  Rule: The user chooses where settings apply

    @desktop
    Scenario: The page states the project and environment being edited
      When the user opens settings
      Then the page says it is applying settings for all projects across all environments

    @desktop
    Scenario Outline: Changing one axis of the scope keeps the other
      Given the user is editing settings for "hal-c2" on "Laptop"
      When the user chooses <choice>
      Then settings apply to <result>

      Examples:
        | choice                        | result                                |
        | the environment "Build box"   | "hal-c2" on "Build box"               |
        | all environments              | "hal-c2" across all checkouts         |
        | all projects                  | every project on "Laptop"             |

    @desktop
    Scenario: Offline environments are marked when choosing one
      Given "Build box" is offline
      When the user chooses which environment settings apply to
      Then "Build box" is listed as offline

    # Upstream #18503: with one environment chosen, the project picker lists only projects that
    # have a checkout there; all environments still lists every project.
    @backlog @desktop
    Scenario: Choosing a project on one environment offers only projects checked out there
      Given "notes" has a checkout only on "Build box"
      And the user is editing settings on "Laptop"
      When the user chooses which project settings apply to
      Then "notes" is not offered
      And with all environments chosen "notes" is offered again

    @backlog @desktop
    Scenario Outline: A scope that no longer exists explains why and saves nothing
      Given the user opened a settings link for <target>
      When the settings page loads
      Then the page says "<message>"
      And no change the user makes is saved anywhere

      Examples:
        | target                               | message                                                                        |
        | a checkout without a project         | Select a project to choose one of its checkouts.                               |
        | an environment that was removed      | This environment is no longer available.                                       |
        | a project that was removed           | This project is no longer available.                                           |
        | a checkout that was removed          | This checkout is no longer available in the selected project and environment. |

    @backlog @desktop @priority-low
    Scenario: A section with nothing to change at this scope offers where to go instead
      Given the user is editing settings for the project "hal-c2"
      When the user opens a section that only has environment-wide settings
      Then the page offers each environment the section can be changed on

    @backlog @desktop @priority-low
    Scenario: Environments that share a name are told apart by address
      Given two environments are both named "Development"
      When the user chooses which environment settings apply to
      Then each is listed as "Development" followed by its address
      And when an environment has no address its id is used instead

    @backlog @desktop @priority-low
    Scenario: A renamed environment no longer needs its address shown
      Given two environments were both named "Development"
      When one is renamed "Production"
      Then each is listed by its name alone

    @backlog @desktop @priority-low
    Scenario: An older settings link for a project and environment still opens it
      Given the user opens a settings link that names a project and a machine from before checkouts existed
      When the settings page loads
      Then settings apply to that project across that environment's checkouts
      And the page does not widen the scope to all environments

    @backlog @desktop
    Scenario: A project spanning several checkouts lists them all
      Given "hal-c2" has two checkouts on "Laptop" and one on "Build box"
      When the user edits settings for the project "hal-c2"
      Then every checkout is a target of the change
      And choosing one checkout narrows the scope to exactly that one

  Rule: Writes go to every environment in the scope

    @desktop
    Scenario: An environment-wide change is saved on every connected environment
      Given the user is editing settings across all environments
      When the user changes an environment-wide setting
      Then the change is saved on "Laptop" and on "Build box"

    @desktop
    Scenario: A project change is saved as an override for that project
      Given the user is editing settings for the project "hal-c2"
      When the user changes the default model
      Then "hal-c2" overrides the default model on each environment with a checkout of it
      And other projects keep the environment's default model

    @desktop
    Scenario: A device preference is saved on this device only
      Given the user is editing settings for the project "hal-c2"
      When the user changes a preference that belongs to this device
      Then the preference is saved on this device
      And no environment is changed

    @desktop
    Scenario: Saving on some environments but not others is reported
      Given the user is editing settings across all environments
      And saving on "Build box" fails
      When the user changes a setting
      Then the user is told the setting saved on some environments and could not update "Build box"

    @backlog @desktop @mobile @priority-low
    Scenario: A setting an environment refuses names that environment and those that saved it
      Given the user is editing settings across "Laptop" and "Build box"
      And this device's session on "Build box" may not change settings
      When the user changes a setting
      Then the user is told "Build box" refused the change for lack of permission
      And the user is told "Laptop" saved it

    @desktop
    Scenario: A setting cannot be changed while its environment is disconnected
      Given the user is editing settings for "Build box"
      And "Build box" is disconnected
      When the user looks at an environment setting
      Then the setting cannot be changed
      And the user is told to reconnect the selected environment to change it

    @desktop
    Scenario: An environment-wide setting cannot be changed at project scope
      Given the user is editing settings for the project "hal-c2"
      When the user looks at an environment-wide setting
      Then the setting cannot be changed
      And the user is told to select an environment to change it

    @backlog @desktop
    Scenario: A project override cannot be saved on an environment that is too old
      Given "Build box" runs a server without project overrides
      And the user is editing settings for the project "hal-c2" on "Build box"
      When the user looks at a project setting
      Then the setting cannot be changed
      And the user is told to update that environment

    @backlog @desktop @priority-low
    Scenario: Changing one field of a project's writing style keeps the other fields
      Given "hal-c2" overrides the writing style with custom instructions "Keep it short."
      When the user changes only the custom instructions to "Be terse."
      Then the project's writing style keeps its mode and its other fields

    @backlog @desktop
    Scenario Outline: Clearing a project's value keeps or drops its override as the setting allows
      Given "hal-c2" overrides <setting>
      When the user clears <setting> for the project
      Then <result>

      Examples:
        | setting              | result                                                            |
        | the default thread mode | the override is removed and the environment's value applies  |
        | the default model    | the project keeps an explicit "no default model" override        |

    @backlog @desktop @priority-low
    Scenario: Clearing the last override of a project removes its entry
      Given "hal-c2" overrides only the default model
      When the user resets the default model for the project
      Then "hal-c2" has no overrides left on that environment

    @backlog @desktop @priority-low
    Scenario: Clearing one override leaves the project's other overrides
      Given "hal-c2" overrides the default model and auto pull
      When the user resets the default model for the project
      Then "hal-c2" still overrides auto pull

    @backlog @desktop
    Scenario: Device access is chosen per project while device hosts are environment-wide
      Given the user is editing settings for the project "hal-c2"
      When the user looks at agent device access and device hosts
      Then agent device access can be changed for the project
      And device hosts can only be changed at environment scope

    # Upstream #17879. The provider switch on the Providers page used to change the whole
    # environment even with a project chosen.
    @backlog @shared
    Scenario: A provider switched off for a project stays on for the rest of the environment
      Given the user is editing settings for the project "hal-c2" on "Laptop"
      When the user turns the "Codex" provider off
      Then "Codex" is off for every checkout of "hal-c2" on "Laptop"
      And "Codex" stays on for the other projects on "Laptop"

    @backlog @shared
    Scenario: A project's provider switch can be reset to the environment's value
      Given the project "hal-c2" turned "Codex" off while the environment has it on
      When the user resets the "Codex" switch for "hal-c2"
      Then "Codex" follows the environment's value for "hal-c2" again

    @backlog @shared
    Scenario: Model pickers in a project leave out providers the project turned off
      Given the project "hal-c2" turned "Codex" off
      When the user picks a model for a thread in "hal-c2"
      Then no "Codex" model can be chosen

  Rule: The user can see and clear where a value comes from

    @desktop
    Scenario: The inheritance chain shows which layer wins
      Given the user is editing settings for the project "hal-c2"
      And "hal-c2" does not override the default model
      When the user asks where the default model comes from
      Then the project, environment, repository file and built-in default layers are listed in that order
      And the environment layer is marked as the one in effect

    @desktop
    Scenario: Resetting a project override inherits the environment's value again
      Given "hal-c2" overrides the default model
      And the user is editing settings for the project "hal-c2"
      When the user resets the default model to the inherited value
      Then "hal-c2" no longer overrides the default model
      And the default model shows the environment's value

    @desktop
    Scenario: The environment view lists and clears project overrides
      Given "hal-c2" overrides the default model on "Laptop"
      And the user is editing settings for "Laptop"
      When the user asks where the default model comes from
      Then "hal-c2" is listed as overriding it
      When the user resets the override for "hal-c2"
      Then "hal-c2" uses the value from "Laptop"

    @desktop
    Scenario: A value that differs between environments shows as mixed
      Given the default model differs between "Laptop" and "Build box"
      And the user is editing settings across all environments
      When the user looks at the default model
      Then it shows as mixed across the selected environments
      When the user chooses one model
      Then every environment uses that model

    # Upstream #28005: two environments on automatic defaults were read as one default, showing
    # one environment's model and an effort the other could not take.
    @backlog @desktop
    Scenario: Automatic defaults that resolve to different models show as mixed
      Given "Laptop" and "Build box" both leave the default model on automatic
      And "Laptop" resolves it to a Codex model and "Build box" to a Claude model
      And the user is editing settings across all environments
      When the user looks at the default model
      Then it reads "Automatic (mixed)"
      And the user is told to select one environment or choose a model they share
      And no effort can be chosen until the model is the same on every selected environment

    @desktop
    Scenario: A model missing on one environment cannot be applied to all of them
      Given the model "opus" is only available on "Laptop"
      And the user is editing settings across all environments
      When the user tries to choose "opus" as the default model
      Then the user is told the model is unavailable on "Build box"
      And is told to select that environment to choose its model separately

    # Legacy: apps/web/src/components/settings/useScopedModelAvailability.ts
    @backlog @desktop
    Scenario Outline: A model also needs its provider to be usable on every selected environment
      Given the user is editing settings across "Laptop" and "Build box"
      And <situation>
      When the user tries to choose "opus" as the default model
      Then the user is told the model is unavailable on "Build box"

      Examples:
        | situation                                                                  |
        | the provider instance is turned off on "Build box"                         |
        | the provider instance is not available on "Build box"                      |
        | "Build box" has an instance with that id that belongs to another provider  |
        | "Build box" lists "opus" as unavailable                                    |

    # Legacy: apps/web/src/components/settings/settingsLayout.tsx (inheritance summary)
    @backlog @desktop @priority-low
    Scenario Outline: A setting says in one line where its value comes from
      Given <situation>
      When the user looks at the setting
      Then it says "<summary>"

      Examples:
        | situation                                                        | summary                                    |
        | the environments hold different values                           | Mixed across selected environments         |
        | the project overrides it                                         | Overridden for this project                |
        | the repository's hal-c2.json provides it                         | Inherited from the repository's hal-c2.json |
        | the user edits a project on "Laptop" and "Laptop" sets it        | Inherited from Laptop                      |
        | the user edits a project across environments and they set it     | Inherited from environment                 |
        | the environment sets it and no project is picked                 | Set on the environment                     |
        | nothing sets it                                                  | Built-in default                           |

    # Legacy: apps/web/src/components/settings/SettingInheritance.tsx (formatValue)
    @backlog @desktop @priority-low
    Scenario Outline: A layer with no value reads in the setting's own words
      Given no layer sets "<setting>"
      When the user asks where it comes from
      Then the unset layers read "<reading>"

      Examples:
        | setting                       | reading                |
        | Pull request merge method     | Last selected          |
        | Auto-settle after days        | Never                  |
        | Default model                 | Automatic              |
        | Source control writer model   | Text generation model  |
        | Default thread mode           | Inherit                |
        | Worktree submodules           | Inherit                |

    @backlog @desktop @priority-low
    Scenario Outline: A layer's value reads in the setting's own words
      Given the <layer> layer sets "<setting>" to <value>
      When the user asks where it comes from
      Then the <layer> layer reads "<reading>"

      # Upstream #23450: background activity layers all read "Custom".
      Examples:
        | layer       | setting             | value                   | reading     |
        | environment | Background activity | the Performance profile | Performance |
        | Default     | Background activity | the Balanced profile    | Balanced    |

      # Upstream #23678: cleanup modes read with the writing-style labels.
      Examples:
        | layer       | setting                    | value         | reading |
        | environment | Automatic worktree cleanup | a custom rule | Custom  |
        | environment | Automatic worktree cleanup | off           | Off     |

    # Legacy: apps/web/src/components/settings/SettingInheritance.tsx (overridingProjects)
    @backlog @desktop @priority-low
    Scenario: Projects overriding a value can be opened or reset together
      Given "hal-c2" and "docs" both override the default model on "Laptop"
      And the user is editing settings for "Laptop"
      When the user asks where the default model comes from
      Then "hal-c2" and "docs" are listed with the model each uses
      When the user opens "docs" from the list
      Then the default model is shown for the project "docs"
      When the user resets all the overrides
      Then neither project overrides the default model

    # Legacy: apps/web/src/components/settings/SettingInheritance.tsx (chains per target)
    @backlog @desktop @priority-low
    Scenario: Across several environments the chain is listed once for each
      Given the user is editing settings across "Laptop" and "Build box"
      When the user asks where the default model comes from
      Then the layers are listed under "Laptop" and again under "Build box"
      And the layer in effect is marked on each

    @backlog @shared @priority-low
    Scenario: An environment that accepts a setting but does not keep it is named
      Given the user is editing settings across "Laptop" and "Build box"
      And "Build box" runs a build that does not know the setting being changed
      When the user changes that setting
      Then the change is saved on "Laptop"
      And the user is told it could not be saved on "Build box", which does not support the setting and needs updating
      But a value the environment kept with surrounding spaces trimmed counts as saved
