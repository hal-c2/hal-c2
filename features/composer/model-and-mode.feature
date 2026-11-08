# Sources:
#   https://github.com/pingdotgg/t3code/pull/27859
#   https://github.com/pingdotgg/t3code/pull/25511
#   https://github.com/pingdotgg/t3code/pull/28044
#   https://github.com/pingdotgg/t3code/pull/28409
#   https://github.com/pingdotgg/t3code/pull/28076
#   https://github.com/pingdotgg/t3code/pull/28057
#   https://github.com/pingdotgg/t3code/pull/20886
#   https://github.com/pingdotgg/t3code/pull/22242
#   https://github.com/pingdotgg/t3code/pull/19900
#   https://github.com/pingdotgg/t3code/pull/24205
#   https://github.com/pingdotgg/t3code/pull/11933
#   https://github.com/pingdotgg/t3code/pull/14961
#   https://github.com/pingdotgg/t3code/pull/19928
#   https://github.com/pingdotgg/t3code/pull/18494
#   https://github.com/pingdotgg/t3code/pull/16069
#   https://github.com/pingdotgg/t3code/pull/13590
#   https://github.com/pingdotgg/t3code/pull/13555
#   https://github.com/pingdotgg/t3code/pull/25609
#   https://github.com/pingdotgg/t3code/pull/21404
#   https://github.com/pingdotgg/t3code/pull/21406
#   https://github.com/pingdotgg/t3code/pull/23957
#   https://github.com/pingdotgg/t3code/pull/25869
#   https://github.com/pingdotgg/t3code/pull/27114
#   docs/user/composer.md (custom models, remembered model defaults)
#   docs/user/permission-modes.md
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (model, effort, permissions, Build and Plan, context strip)
#   apps/web/src/components/BranchToolbar.logic.ts (Run on: every connected machine's projects)
#   apps/tui/src/models.ts (flattened model list, unavailable providers skipped)
#   apps/tui/src/components/ChatView.tsx (plan toggle, access, model and effort shortcuts)
#   apps/server-ex/lib/hal_c2/orchestration.ex (thread.runtime-mode.set, thread.interaction-mode.set, thread.model-selection.set)
#   apps/web/src/components/chat/TraitsPicker.tsx
#   apps/web/src/components/chat/ProviderModelPicker.tsx (trigger: provider icon and model name)
#   apps/web/src/components/chat/ModelPickerContent.tsx (search, favourites, disabled reasons, jump keys)
#   apps/web/src/components/chat/ModelPickerSidebar.tsx (provider rail, unavailable providers)
#   apps/web/src/components/chat/ModelListRow.tsx
#   apps/web/src/components/chat/modelPickerSearch.ts, apps/web/src/components/chat/modelPickerKeys.ts
#   apps/web/src/modelOrdering.ts (favourites first, user model order)
#   apps/web/src/composerDraftStore.ts (sticky model selection per provider)
#   apps/web/src/modelSelection.ts, apps/web/src/providerModels.ts, apps/web/src/components/chat/composerProviderState.tsx
#   (which model and options a composer resolves to, saved models a provider no longer lists)
#   packages/shared/src/keybindings.ts (modelPicker.toggle, modelPicker.previousProvider, modelPicker.nextProvider, modelPicker.jump.1-9, composer.effort, composer.mode, composer.host, composer.workspace, composer.branch, composer.previousWorktree)
#   packages/contracts/src/settings.ts (planModeEnabled, favorites, providerModelPreferences)
#   packages/shared/src/model.ts (applyClaudePromptEffortPrefix: Ultrathink and slash commands)
#   apps/web/src/components/BranchToolbarEnvironmentSelector.tsx, apps/web/src/components/ChatView.tsx (Run on, Auto balance labels)
#   apps/web/src/components/chat/useAutoBalanceUpdateBanner.tsx (one update notice for balanced machines)
#   apps/web/src/components/BranchToolbar.logic.ts (resolveEnvironmentOptionLabel, shouldShowEnvironmentIndicator)
#   Auto balance is desktop and terminal only; phones pick the machine by hand (settings/load-balancing.feature).
#   https://github.com/pingdotgg/t3code/pull/23448
#   https://github.com/pingdotgg/t3code/pull/23493
#   https://github.com/pingdotgg/t3code/pull/30275
#   https://github.com/pingdotgg/t3code/pull/29789

Feature: Choosing the model, effort, permissions and workspace for a turn
  Before sending, the user decides which model runs the turn, how hard it
  thinks, what it may do without asking, and where it works. Changes apply to
  the next turn and are remembered for the thread.

  Background:
    Given a project with an open thread on Codex

  @desktop @tui
  Scenario: The user switches the model for the next turn
    When the user chooses the model "gpt-5-codex"
    Then the next turn runs on "gpt-5-codex"

  @desktop @tui
  Scenario: Models from unavailable providers cannot be chosen
    Given the Cursor provider is not installed
    When the user looks through the models
    Then Cursor's models cannot be chosen

  @desktop
  Scenario: Models are grouped by provider
    Given Claude and a second Codex instance "Codex Work" are enabled
    When the user looks through the models
    Then Codex, "Codex Work" and Claude each list only their own models
    And a provider that is turned off in settings is not listed

  # Upstream #25511: a second instance showed the default instance's draft model, whose slug its
  # own catalog lacks, so its effort control vanished and sending asked for a model it had disabled.
  @shared @backlog-mobile @backlog-tui
  Scenario: A second instance with no draft model of its own uses its own default
    Given the draft picked "Kimi K3.1 Pro" on the default OpenCode instance
    When the user switches the draft to a second OpenCode instance "Kimi" without picking a model
    Then the composer shows "Kimi"'s own default model with its effort choices
    And sending asks "Kimi" only for a model in its own catalog

  @desktop
  Scenario: The chosen model is shown with its provider
    When the user chooses the model "gpt-5-codex"
    Then the composer shows "gpt-5-codex" marked as a Codex model

  # Upstream #24205: the model button repeated what the provider icon says ("Claude Opus 5.5" beside
  # the Claude icon), and aggregator catalogs added a vendor ("NVIDIA: Nemotron 3 Super").
  @shared @backlog-mobile @backlog-tui
  Scenario Outline: The model button shows the name the user would say
    When the user chooses the <provider> model "<full>"
    Then the model button reads "<short>"
    And the full name "<full>" is shown in its tooltip and in the model picker

    Examples:
      | provider | full                     | short            |
      | Claude   | Claude Opus 5.5          | Opus 5.5         |
      | Codex    | GPT-5.5                  | GPT-5.5          |
      | OpenCode | NVIDIA: Nemotron 3 Super | Nemotron 3 Super |

  # A bare version keeps its family prefix ("GPT-5.5" above): "5.5" alone would not say which
  # family it belongs to. Upstream #24205's own modelShortName test pins this; an earlier row
  # here said "5.5", which upstream never did.

  # Upstream #24205
  @shared @backlog-mobile @backlog-tui @priority-low
  Scenario: A short name the model manifest gives wins over the worked-out one
    Given the model manifest names "Claude Opus 5.5" "Opus" for short
    When the user chooses "Claude Opus 5.5"
    Then the model button reads "Opus"

  @desktop
  Scenario Outline: Searching the models matches provider and model names
    Given Claude is enabled
    When the user searches the models for "<query>"
    Then "<found>" is listed
    And "<missing>" is not listed

    Examples:
      | query  | found       | missing     |
      | opus   | opus        | gpt-5-codex |
      | claude | sonnet      | gpt-5-codex |
      | codex  | gpt-5-codex | opus        |

  @desktop @priority-low
  Scenario: Search results keep the provider's newest-first order
    Given Claude lists "Opus 5.5", "Opus 5", "Opus 4.8" and "Opus 4.5" in that order
    When the user searches the models for "opus"
    Then the models are listed as "Opus 5.5", "Opus 5", "Opus 4.8" and "Opus 4.5"
    And a shorter name is not listed ahead of a newer model

  @desktop
  Scenario: A model that cannot be used says why and cannot be chosen
    Given the model "gpt-5.5" cannot be used because "Start a new thread to use this model."
    When the user looks through the models
    Then "gpt-5.5" shows "Start a new thread to use this model."
    And "gpt-5.5" cannot be chosen

  @desktop
  Scenario: Unavailable providers stay listed with the reason
    Given the Cursor provider is not installed
    When the user looks through the models
    Then Cursor is listed with the reason it is unavailable
    And Cursor's models cannot be chosen

  @desktop
  Scenario: The user chooses a model with the keyboard
    When the user opens the model picker
    And the user moves to the next model and confirms it
    Then the next turn runs on that model

  @desktop
  Scenario: The user moves between providers with the keyboard
    Given Claude is enabled
    When the user opens the model picker
    And the user moves to the next provider
    Then Claude's models are listed

  @desktop
  Scenario: The user jumps to a model by its number
    When the user opens the model picker
    And the user presses the shortcut for the second model
    Then the next turn runs on the second model listed

  @desktop
  Scenario: The model picker shortcut opens and closes the model picker
    When the user presses the model picker shortcut
    Then the model picker is open
    When the user presses the model picker shortcut again
    Then the model picker is closed

  @desktop @tui
  Scenario Outline: The user sets the reasoning effort for the next turn
    When the user sets the effort to <effort>
    Then the next turn runs with <effort> effort

    Examples:
      | effort |
      | low    |
      | medium |
      | high   |

  @mc @desktop @tui
  Scenario Outline: The user sets what the agent may do without asking
    When the user sets the permissions to <mode>
    Then the next turn runs in <mode>

    Examples:
      | mode                 |
      | Supervised           |
      | Auto-accept edits    |
      | Auto                 |
      | Full access          |

  @mc @tui
  Scenario: Planning and building can be toggled for the next turn
    Given the thread is building
    When the user toggles to planning
    Then the next turn plans instead of making changes
    When the user toggles back
    Then the next turn builds again

  # Upstream #21406: the phone hid Ultrathink and Ultracode.
  @desktop @mobile @backlog-mobile
  Scenario: Ultrathink prefixes the prompt
    Given the thread runs on Claude
    When the user turns on Ultrathink and sends "design the cache"
    Then the agent receives "Ultrathink: design the cache"

  # Legacy: packages/shared/src/model.ts (applyClaudePromptEffortPrefix)
  @mc @priority-high
  Scenario Outline: Ultrathink is left off a message it would break
    Given the thread runs on Claude with Ultrathink turned on
    When the user sends "<message>"
    Then the agent receives "<received>"

    Examples:
      | message                  | received                 |
      | /review the cache        | /review the cache        |
      | /plugin:skill            | /plugin:skill            |
      | Ultrathink: the cache    | Ultrathink: the cache    |
      | /home/sam/app.ts is odd  | Ultrathink: /home/sam/app.ts is odd |

  @desktop @mobile @backlog-mobile
  Scenario: Favourite models are listed first and can be unfavourited
    When the user marks "claude-opus" as a favourite
    Then "claude-opus" is listed among the favourites
    When the user removes it from the favourites
    Then it is no longer listed among the favourites

  # Upstream #14961: the model picker offers every saved custom model, not just the first 32
  @backlog @shared
  Scenario: Every saved custom model is offered
    Given the user has saved 40 custom models for Codex
    When the user opens the model picker
    Then all 40 custom models are offered
    And a thread set to the 40th custom model shows that model as chosen

  @desktop @mobile @backlog-mobile @priority-high
  Scenario: A started thread can move to another provider
    Given the thread has already run a turn on Codex
    When the user chooses the model "claude-opus"
    Then the next turn moves the thread to Claude before it runs on "claude-opus"

  # Upstream #20886: a model picked earlier in a draft kept overriding a change made elsewhere.
  @backlog @shared @mobile
  Scenario: A draft follows a model change made on another client
    Given the user picked "gpt-5" in the draft of a thread on this client
    And then changed the thread to "claude-opus" on another client
    When the user returns to the thread here
    Then the draft is on "claude-opus"
    But an unsent pick in another thread's draft is kept

  @desktop @tui @mobile @backlog-mobile @priority-high
  Scenario: The last model used with each provider is remembered
    Given the user last used "gpt-5" with Codex
    When the user starts a new thread on Codex
    Then "gpt-5" is chosen
    But a model set for the project takes precedence

  @desktop @tui @mobile @backlog-mobile @priority-high
  Scenario: New threads start with the default permissions
    Given the default permissions for new threads are Supervised
    When the user starts a new thread
    Then the thread runs in Supervised
    But a project that overrides the default uses its own permissions

  @desktop
  Scenario: The user chooses which environment runs a new thread
    Given two environments are connected
    When the user starts a new thread on the second environment
    Then the thread is created in the second environment

  @desktop
  Scenario: The user chooses to work in the current checkout or a new worktree
    Given the project is a Git repository
    When the user chooses to work in a new worktree from branch "main"
    Then the first turn works in a new worktree based on "main"

  # Upstream #27114: at the default chat width a project on several machines showed only the
  # machine's name, with the checkout or worktree choice hidden in its menu.
  @backlog @desktop @priority-low
  Scenario: At the default chat width the machine, workspace and branch each have their own control
    Given the project can run on more than one machine
    When the user starts a new thread at the default chat width
    Then the composer shows the machine, whether it works locally or in a new worktree, and the branch as separate controls
    And only a phone-width composer folds the machine and workspace into one control

  # Upstream #21404: the phone could inherit new-worktree mode for a plain folder and then
  # refuse to start on a branch that cannot exist.
  @backlog @shared
  Scenario: A project that is not a Git repository starts its thread in its folder
    Given the project is a plain folder with no Git repository
    And the last thread was started in a new worktree, or a saved draft asked for one
    When the user starts a new thread in the project
    Then the thread works in the project's folder
    And no branch or worktree can be chosen

  @desktop
  Scenario: A branch that does not exist is created when chosen
    Given the project has no branch "feature/cache"
    When the user searches for "feature/cache" and confirms it
    Then the thread works on a new branch "feature/cache"

  @desktop
  Scenario: New worktree mode needs a base branch before sending
    Given the user chose to work in a new worktree
    And no base branch is chosen
    When the user tries to send the first message
    Then the user is asked to select a base branch

  # Upstream #13590: a thread whose worktree is still being checked out is in worktree mode.
  @desktop @backlog
  Scenario: A thread still preparing its worktree says "New worktree" until checkout finishes
    Given the user started a thread in a new worktree
    And the worktree is still being checked out
    Then the workspace label reads "New worktree"
    When the checkout finishes
    Then the workspace label reads "Worktree"

  # Upstream #13555: the collapsed bar's labels must not flip while the user scrolls.
  # Upstream #25869: dropped with the collapsing composer.
  @desktop @dropped
  Scenario: The collapsed composer bar keeps its labels steady while the user scrolls
    Given the user has collapsed the composer bar on a thread with a long branch name
    When the user scrolls the thread
    Then the bar keeps the same labels and does not switch between labels and icons

  @desktop
  Scenario: A new thread can run on a machine that has other projects
    Given "laptop" has the project "shop" and the connected machine "server" has only "scratch"
    And the user has typed a prompt for a new thread in "shop"
    When the user chooses "server · scratch" as the machine the thread runs on
    Then the new thread is in "scratch" on "server"
    And the prompt is still there

  # Upstream #22242: reverted #15636, which listed every checkout as its own row; checkouts of
  # one repository are grouped as one project again.
  @backlog @desktop
  Scenario: Checkouts of one repository are one project in the new-thread picker
    Given "shop" has checkouts on "laptop" and "server"
    When the user opens the project picker for a new thread
    Then "shop" is listed once
    And both machines are offered under it

  @backlog @desktop
  Scenario: The user lets a new thread's machine be picked automatically
    Given the project exists on two connected machines and load balancing is on
    When the user chooses "Auto balance" as the machine a new thread runs on
    Then the thread starts on the machine with the most room when the first message is sent

  @backlog @desktop @priority-low
  Scenario: Auto balance says when it cannot check the machines
    Given the user chose "Auto balance" for a new thread
    When checking the machines' free resources fails
    Then the picker shows "Auto balance unavailable"

  @backlog @desktop @priority-low
  Scenario: The user takes a new thread off Auto balance
    Given the user chose "Auto balance" for a new thread
    When the user chooses the machine "laptop" instead
    Then the thread starts on "laptop"

  @backlog @desktop @priority-low
  Scenario: Auto balance says it is checking until a machine is picked
    Given the user chose "Auto balance" for a new thread
    When the machines' free resources are still being checked
    Then the picker shows "Checking machines…"

  @backlog @desktop
  Scenario Outline: A first message waits for Auto balance to pick a machine
    Given the user chose "Auto balance" for a new thread
    And <situation>
    When the user sends the first message
    Then the user is told "<notice>" and that a machine can be chosen in the composer
    And nothing is sent and the draft stays

    Examples:
      | situation                               | notice                       |
      | the machines are still being checked    | Checking machine resources   |
      | no machine has room for another thread  | Choose a machine to continue |

  @backlog @desktop @priority-low
  Scenario: Auto balance is refused while the draft has attachments
    Given the draft of a new thread has an attached file
    When the user chooses "Auto balance" as the machine the thread runs on
    Then the user is told "Keep attachments on this machine" and to remove them first
    And the thread still runs on the machine it was on

  @backlog @desktop @priority-low
  Scenario Outline: A machine is named the way its owner would know it
    Given the machine is <machine> and its own name is "<own>" and the user named it "<saved>"
    When the user opens the choice of machine for a new thread
    Then the machine reads "<label>"

    Examples:
      | machine             | own      | saved     | label       |
      | the one being used  | laptop   | Work Mac  | laptop      |
      | the one being used  | local    | Work Mac  | Work Mac    |
      | the one being used  |          |           | This device |
      | another one         | server   | Rack      | server      |
      | another one         |          | Rack      | Rack        |

  @backlog @desktop @priority-low
  Scenario: The only connected machine is still shown when it is a remote one
    Given the project runs on a remote machine "server" and no other machine is connected
    When the user looks at a new thread's composer
    Then the machine "server" is shown
    And it cannot be changed

  # Upstream #19900: a started thread offered other machines, and picking one did nothing.
  @backlog @desktop @priority-low
  Scenario: A started thread names its machine without offering others
    Given a thread has started on the machine "server" in a project on several machines
    When the user looks at the thread's composer
    Then the machine "server" is shown
    And no other machine is offered, by the menu or by the machine shortcut

  @backlog @desktop @priority-low
  Scenario: The machine is left out when it is the only one and it is this one
    Given the project runs on the machine being used and no other machine is connected
    When the user looks at a new thread's composer
    Then no machine is shown

  @backlog @desktop @priority-low
  Scenario Outline: Updates for every balanced machine are gathered in one notice
    Given the user chose "Auto balance" for a new thread
    And <state>
    When the user looks at the composer
    Then one notice reads "<notice>"
    And opening it lists each machine and its update

    Examples:
      | state                                      | notice                            |
      | "laptop" and "server" both have an update  | Update available for 2 machines   |
      | "server" is updating                       | Updating 1 machine                |
      | the update of "server" failed              | Could not update 1 machine        |

  @desktop
  Scenario: The model picker opens on the favourites when there are any
    Given the user has marked "claude-opus" as a favourite
    When the user opens the model picker
    Then the favourites are listed first, each under its own provider's name
    But in a thread that has already run a turn the picker opens on the thread's provider

  # Upstream #28076: the folded "Legacy models" section became a "Show more" row, so this is
  # replaced by "A provider's older models are shown in place from the end of the list".
  @dropped @desktop
  Scenario: A provider's older models are folded away until asked for
    Given Codex lists two current models and three it calls legacy
    When the user looks through Codex's models
    Then the two current models are listed above "Legacy models" marked "3 models"
    When the user opens "Legacy models"
    Then the three older models are listed
    And the section is already open when the thread runs on one of them

  # Upstream #11933: a favourited legacy model was hidden in the folded "Legacy models" section.
  @desktop
  Scenario: A favourite older model is listed outside the folded section
    Given Codex lists the legacy model "gpt-4.1" and the user marked it as a favourite
    When the user looks through Codex's models
    Then "gpt-4.1" is listed above Codex's current models without choosing "Show more"
    When the user removes it from the favourites
    Then "gpt-4.1" is back among the older models behind "Show more"

  @desktop
  Scenario: Searching the models finds a provider's older models too
    Given Codex lists the legacy model "gpt-4.1"
    When the user searches the models for "4.1"
    Then "gpt-4.1" is listed without choosing "Show more"

  @desktop
  Scenario: A search that matches no model says so
    When the user searches the models for "zzz"
    Then the user is told "No models found"

  # Upstream #23493: Enter or Escape that confirmed or cancelled input-method text closed the picker.
  @backlog @desktop
  Scenario: Confirming input-method text in the model search keeps the picker open
    Given the user is searching the models with a Japanese input method
    When the user presses Enter to confirm the composed text, or Escape to cancel it
    Then the picker stays open with the search text as the input method left it
    But Enter outside composition still chooses the highlighted model, and Escape closes the picker

  @desktop
  Scenario: A model the provider has just added is marked as new
    Given Codex reports "gpt-6" as a new model
    When the user looks through Codex's models
    Then "gpt-6" is marked as new

  # Upstream #25609: the new mark comes from the model's release date and lasts seven days.
  @backlog @mc @desktop
  Scenario Outline: A model is marked new for seven days after its release
    Given "gpt-6" was released <age>
    When the user looks through Codex's models
    Then "gpt-6" <mark>

    Examples:
      | age               | mark                  |
      | six days ago      | is marked as new      |
      | eight days ago    | is not marked as new  |

  @desktop @priority-high
  Scenario Outline: A provider that cannot be used says why in the model picker
    Given the provider instance "Codex Work" <state>
    When the user rests on "Codex Work" in the model picker
    Then the user reads "<reason>"

    Examples:
      | state                                         | reason                                   |
      | is turned off in settings                     | Codex Work — Disabled in settings.       |
      | failed its check with "codex not found"       | Codex Work — Unavailable. codex not found |
      | reports the warning "Signed out"              | Codex Work — Limited. Signed out         |
      | has not finished its check                    | Codex Work — Not ready.                  |

  @desktop
  Scenario: A provider that needs setting up offers its setup from the model picker
    Given Cursor is not installed and HAL-C2 can install it
    When the user looks through Cursor's models
    Then the picker says why Cursor cannot be used and offers "Open provider setup"
    When the user chooses it
    Then the picker closes and the setup for Cursor opens

  # Every provider on the MC takes a handoff (features/mc/orchestration/provider-handoff.feature),
  # so no started thread is held to its provider.
  @dropped @desktop
  Scenario: Another provider says why it cannot be chosen once the thread has started
    Given Claude is enabled
    And the thread has already run a turn on Codex
    When the user rests on Claude in the model picker
    Then the user reads "Claude is unavailable in this thread. Start a new thread to switch providers."

  @desktop @priority-high
  Scenario: The model cannot be changed while a message is on its way
    Given the user has sent a message the MC has not taken yet
    Then the model picker cannot be opened
    And it can be opened again once the MC takes the message

  @desktop @priority-low
  Scenario: The model picker waits for the provider list before it can be used
    Given the environment has not yet reported its providers
    Then the composer shows the thread's model and the model picker cannot be opened
    When the providers arrive
    Then the model picker can be opened

  @desktop @priority-high
  Scenario Outline: A composer with no usable provider says so in place of the model
    Given no provider can run a turn
    And <setup>
    When the user looks at the composer
    Then the composer shows "<shown>" where the model would be
    And no message can be sent

    Examples:
      | setup                                   | shown                  |
      | one of the providers can be set up      | Open provider settings |
      | none of the providers can be set up     | No provider available  |

  @desktop @priority-high
  Scenario: A saved model its provider no longer lists is kept and marked unavailable
    Given the thread runs on OpenCode with the model "kimi-k2"
    And OpenCode no longer lists "kimi-k2"
    When the user looks at the composer
    Then the model reads "kimi-k2 (Unavailable)"
    And the thread's model is not changed to another one

  @backlog @desktop @priority-low
  Scenario: Several models are chosen for a new thread with Shift
    Given the project is a Git repository
    And the user is starting a new thread with "gpt-5-codex" chosen
    When the user chooses "opus" and "sonnet" with Shift held
    Then the composer names its models as "gpt-5-codex, opus, 1 more"
    When the user chooses "opus" and "sonnet" with Shift held again
    Then only "gpt-5-codex" is chosen and the thread starts on it alone

  # Upstream #23448: registry agents lost their own logos once several models were chosen.
  @backlog @desktop @priority-low @plugin-acp-registry
  Scenario: Several registry agents chosen together keep their own logos
    Given the user is starting a new thread with a model of the registry agent "Goose" chosen
    When the user chooses a model of the registry agent "Amp" with Shift held
    Then the composer shows the logos of "Goose" and "Amp"

  @backlog @desktop @priority-low
  Scenario: Choosing a model without Shift goes back to one model
    Given the user has chosen "gpt-5-codex" and "opus" for a new thread
    When the user chooses "sonnet"
    Then only "sonnet" is chosen

  @backlog @desktop @priority-low
  Scenario: A thread that has started takes one model only
    Given the thread has already run a turn on Codex
    When the user chooses a model with Shift held
    Then that model replaces the thread's model
    And no second model is chosen

  @desktop @priority-high
  Scenario: Planning and building are toggled on the desktop only when plan mode is on
    Given the plan mode setting is on
    Then the composer offers to switch between "Build" and "Plan"
    When the user turns the plan mode setting off
    Then the composer offers no such switch
    And the next turn builds

  @desktop @priority-high
  Scenario: Only the permissions the provider supports are offered
    Given the thread's provider supports only Supervised and Full access
    When the user opens the permissions
    Then only Supervised and Full access are offered, each with a line saying what it allows

  @desktop @priority-high
  Scenario: A thread whose saved permissions its provider no longer offers is shown as Supervised
    Given the thread was saved with Auto-accept edits
    And its provider now supports only Supervised and Full access
    When the user looks at the composer
    Then the permissions read "Supervised"
    And the thread's saved permissions are unchanged until the user chooses
    And the next turn runs in Supervised

  # Upstream #21406: the phone sums the options up too, beside both model controls.
  @backlog @desktop @mobile
  Scenario Outline: The model's options are summed up beside the model
    Given the thread runs on a model with <options>
    Then the composer sums the model's options up as "<summary>"

    Examples:
      | options                                  | summary             |
      | high effort and thinking on              | High · Thinking On  |
      | high effort and fast mode on             | High                |
      | fast mode on and nothing else to set     | Fast                |
      | fast mode off and nothing else to set    | Normal              |

  # Upstream #25869: the composer names the effort as a word after the model, such as
  # "Opus 5.5 Extra High", and a bolt after it when Fast is on. Settings › Appearance ›
  # Effort display shows the level as rising bars instead; Max, Ultracode and Ultrathink stay words.
  @backlog @shared
  Scenario Outline: The composer names the model's effort as the user chose to see it
    Given the thread runs on "Opus 5.5" with <effort> effort
    And the effort display is set to "<display>"
    When the user looks at the composer
    Then the model reads "Opus 5.5" followed by <shown>

    Examples:
      | effort     | display | shown                     |
      | Extra High | Words   | "Extra High"              |
      | Extra High | Bars    | four bars                 |
      | Low        | Bars    | one bar                   |
      | Max        | Bars    | "Max"                     |

  # Upstream #25869: the composer names the permissions only when they are not the user's
  # default; they change from the effort menu or the permissions key.
  @shared @backlog-mobile @priority-high
  Scenario: The composer names the permissions only when they differ from the default
    Given the default permissions are Supervised
    And the open thread runs in Supervised
    When the user looks at the composer
    Then the composer does not name the permissions
    When the user sets the thread's permissions to Full access from the effort menu
    Then the composer names "Full access" beside the model

  # The phone's system back steps out of the model control's permissions menu
  # before it leaves the control (MobileShell.stepBack). The steps are in
  # apps/mobile-qt/tests/features/ComposerPermissionsSteps.cpp, not yet run.
  @backlog @mobile
  Scenario: The phone's back leaves the permissions menu before the model control
    When the user opens the permissions in the model control
    And the user presses the system's back
    Then the permissions menu closes and the model control stays open
    When the user presses the system's back
    Then the model control closes

  # Upstream #25869: a new thread always says which permissions its first message will use,
  # and choosing them there opens the permissions as the permissions key does.
  # Upstream #30275: choosing them opens the permissions menu directly, not the model list first.
  @shared @backlog-mobile @priority-high
  Scenario: A new thread says which permissions its first message uses
    Given the default permissions are Full access
    When the user starts a new thread
    Then the draft says it will run in "Full access"
    When the user chooses the permissions it names
    Then the user can pick other permissions for the thread

  # Upstream #28057: the model and its effort were two touching targets that read as one label;
  # now one control opens the model list with the chosen model's efforts beside it.
  @backlog @shared
  Scenario: One control chooses the model and then its effort
    When the user opens the model control in the composer
    Then the models are listed with the chosen model's efforts beside them, and speed and permissions below
    When the user picks a model that has efforts
    Then the picker stays open on that model's current effort
    And picking a model without efforts chooses it at once

  # Upstream #28057: the effort and permissions keys open the same control at their part.
  @backlog @desktop @priority-low
  Scenario Outline: A key opens the model control at its part
    When the user presses <keys>
    Then the model control opens on <part>
    And pressing it while the control is open moves there

    Examples:
      | keys        | part                   |
      | mod+shift+e | the current effort     |
      | mod+shift+a | the permissions        |

  # Upstream #28076: picks kept closing the picker at odd times; a pick now leaves it open.
  @backlog @shared @priority-low
  Scenario: The model control stays open until the user leaves it
    Given the user opened the model control
    When the user picks an effort, turns fast mode on or changes the permissions
    Then the control stays open with the focus in it
    And Escape or a click outside closes it

  # Upstream #28076: "Legacy models" became a "Show more" row at the end of the list. Replaces
  # "A provider's older models are folded away until asked for" once the clients carry it.
  @backlog @shared @priority-low
  Scenario: A provider's older models are shown in place from the end of the list
    Given Codex lists two current models and three it calls legacy
    When the user chooses "Show more" at the end of Codex's models
    Then the three older models are listed in place and the row reads "Show less"
    And the list scrolls inside the picker

  # Upstream #28409: an agent's own options stretched the control and its effort column.
  @backlog @shared
  Scenario: An agent's own options do not crowd the model control
    Given an ACP agent offers a long model name, a session mode, auto-approve and its own thinking levels
    When the user opens the model control
    Then the agent's thinking levels are the efforts, shown as rising bars
    And each other option is one row naming its value, opening its choices beside it, and an on or off option is a switch
    And the composer names only the model, cut short when long, with its effort, fast mode and context window
    And the picker keeps one height while the user moves between providers

  # Upstream #28409: Grok listed its levels from strongest to weakest.
  @backlog @shared @priority-low
  Scenario: Grok's efforts are listed from lowest to highest
    When the user opens the model control on a Grok model
    Then its efforts run from the lowest to the highest

  # Upstream #28044: Ultrathink is a word in the prompt, not a setting, so the effort choices
  # leave it out. Replaces turning on Ultrathink above once the clients carry it.
  @backlog @shared @priority-low
  Scenario: Ultrathink is typed, not picked
    Given the thread runs on Claude
    When the user opens the effort choices or steps the effort
    Then Ultrathink is not offered
    When the user types "Ultrathink: design the cache" and sends it
    Then the effort reads "Ultrathink" and the turn runs at Ultrathink

  @backlog @desktop
  Scenario: Fast mode is marked beside the model's other options
    Given the thread runs on a model set to high effort with fast mode on
    Then the summary of the model's options is marked as fast mode on

  @desktop
  Scenario: Each option's default is marked
    When the user opens the model's options
    Then the provider's default effort is marked "Default"

  @desktop @priority-low
  Scenario: Choosing another effort takes Ultrathink off the prompt
    Given the thread runs on Claude
    And the user turned on Ultrathink and typed "design the cache"
    When the user sets the effort to high
    Then the draft reads "design the cache" without "Ultrathink:"
    And the next turn runs with high effort

  @desktop @priority-low
  Scenario: A prompt that says ultrathink in its own words fixes the effort
    Given the thread runs on Claude
    And the user has typed "please ultrathink about the cache"
    When the user opens the model's options
    Then the effort reads "Ultrathink" and cannot be changed
    And the user is told "Your prompt contains "ultrathink" in the text. Remove it to change this option."

  # Upstream #19928: two commands step the composer's effort one level without opening the picker.
  @desktop @tui
  Scenario Outline: The user steps the effort from the keyboard without leaving the prompt
    Given the thread runs on a model whose efforts are low, medium and high
    And the effort is <from> and the user is typing a draft
    When the user steps the effort <direction>
    Then the effort is <to>
    And the draft and where the user was typing are unchanged
    And the effort picker stays closed

    Examples:
      | from   | direction | to   |
      | medium | up        | high |
      | high   | up        | low  |
      | medium | down      | low  |
      | low    | down      | high |

  # Upstream #19928: stepping into Ultrathink follows the same rules as choosing it.
  # Upstream #28044: stepping no longer reaches Ultrathink, which is only typed.
  @dropped @desktop @tui
  Scenario: Stepping the effort into Ultrathink adds its prefix and keeps the caret in place
    Given the thread runs on Claude at the effort just below Ultrathink
    And the user has typed "design the cache" with the caret before "cache"
    When the user steps the effort up
    Then the effort reads "Ultrathink"
    And the draft reads "Ultrathink: design the cache"
    And the caret is still before "cache"

  # Upstream #19928: slash commands never get the Ultrathink prefix, so stepping skips it.
  # Upstream #28044: stepping never reaches Ultrathink now, so there is nothing to skip.
  @dropped @desktop @tui
  Scenario: Stepping the effort skips Ultrathink for a slash command
    Given the thread runs on Claude at the effort just below Ultrathink
    And the user has typed "/review the cache"
    When the user steps the effort up
    Then the effort wraps past Ultrathink to Claude's lowest effort
    And the draft reads "/review the cache"

  # Upstream #19928: writing "ultrathink" in the prompt locks effort for the step as for the picker.
  @desktop @tui @priority-low
  Scenario: Stepping the effort does nothing while the prompt says ultrathink in its own words
    Given the thread runs on Claude
    And the user has typed "please ultrathink about the cache"
    When the user steps the effort up
    Then the effort still reads "Ultrathink"

  # Upstream #19928: a level the provider reports outside the model's list (OpenCode's "default")
  # steps from the model's default instead of doing nothing.
  @desktop @tui @priority-low
  Scenario: An effort outside the model's levels steps from the model's default
    Given the provider reports an effort the model does not list
    And the model's default effort is medium
    When the user steps the effort up
    Then the effort is high

  # Upstream #19928: stepping saves the same options as the picker, so Cursor's Fast stays off.
  @backlog @desktop @tui @plugin-cursor @priority-low
  Scenario: Stepping the effort leaves Cursor's Fast mode off unless the user chose it
    Given the thread runs on a Cursor model whose default turns Fast mode on
    And the user has not chosen Fast mode
    When the user steps the effort up
    Then the next turn runs without Fast mode

  # Upstream #19928: the step stands down whenever something else owns the composer.
  # The TUI stands down on every row but cannot edit a queued message, so that row cannot run there.
  @desktop @tui @backlog-tui
  Scenario Outline: Stepping the effort does nothing while the composer is taken
    Given <situation>
    When the user steps the effort up
    Then the effort is unchanged

    Examples:
      | situation                                            |
      | an approval is waiting for the user                  |
      | the agent's question is waiting for an answer        |
      | the user is editing a queued message                 |
      | no provider is available                             |
      | the user is holding the step key down after one step |

  # Upstream #21406: the phone previewed different options from those it saved.
  @desktop @backlog-mobile @priority-high
  Scenario: Each model keeps the options the user last gave it
    Given the user set "opus" to high effort and "sonnet" to low effort
    When the user switches from "opus" to "sonnet" and back
    Then "sonnet" was offered with low effort and "opus" is back at high effort

  # Upstream #21406: an existing thread on the phone hid accounts it could move to.
  @backlog @desktop @mobile
  Scenario: An existing thread offers every account its conversation can continue on
    Given the thread runs on one Codex account and a second Codex account can continue its conversation
    When the user opens the thread's model picker
    Then both Codex accounts are offered for the thread

  @backlog @desktop @priority-low
  Scenario: An unavailable model shows the options saved with it without letting them change
    Given the thread runs on OpenCode with a model OpenCode no longer lists, saved with high effort
    When the user opens the model's options
    Then high effort is shown and cannot be changed

  @backlog @desktop @priority-low
  Scenario: OpenCode's plan agent is offered only when plan mode is on
    Given the thread runs on OpenCode
    And the plan mode setting is off
    When the user opens the model's options
    Then the agent "plan" is not offered
    And a thread saved with the agent "plan" sends its next turn without it

  @backlog @shared @priority-low
  Scenario: The traits trigger names reasoning and speed in text
    Given Fast is on with high reasoning
    When the user looks at the traits trigger
    Then it reads "High Fast" with the reasoning icon, and Fast off still shows the icon

  # Upstream #23957: a fallback to another instance of the same provider dropped the picked effort.
  @shared @backlog-mobile @backlog-tui @priority-high
  Scenario: A composer that falls back to another account keeps the effort picked for the model
    Given new threads default to Claude Opus at extra high effort on the account "Claude Personal"
    And "Claude Personal" is turned off and the account "Claude Team" is ready
    When the user starts a new thread
    Then the composer shows Claude Opus at extra high effort on "Claude Team"
    And the first turn is sent at extra high effort

  # Upstream #23957: options belong to the model they were picked with.
  @shared @backlog-mobile @backlog-tui
  Scenario Outline: A fallback account takes no options that were not picked for what it shows
    Given new threads default to Claude Opus at extra high effort on the account "Claude Personal"
    And "Claude Personal" is turned off and <fallback> is ready
    When the user starts a new thread
    Then the composer shows <shown>

    Examples:
      | fallback                                       | shown                                       |
      | "Claude Team", with high effort of its own     | "Claude Team" at its own high effort        |
      | only a Codex account                           | the Codex model at its default effort       |

  # Upstream #27859: a thread saved under a model alias such as "5.4" lost its effort when the
  # composer fell back to another account.
  @shared @backlog-mobile @backlog-tui
  Scenario: A fallback keeps the effort of a model saved under an alias
    Given a thread saved on the account "Codex Personal" with the model "5.4" at high effort
    And "Codex Personal" is turned off and the account "Codex Work" is ready
    When the user opens the thread
    Then the composer shows "gpt-5.4" on "Codex Work" at high effort
    But a custom model named "5.4" on "Codex Personal" is not taken for "gpt-5.4"

  # Upstream #29789: picking a custom model whose name matched a built-in Codex alias stored the
  # built-in model, and its effort was saved under the built-in model too.
  @shared @backlog-mobile @backlog-tui @priority-high
  Scenario: A custom model named like a Codex alias stays the model the user picked
    Given the Codex account "Codex Proxy" has the custom model "gpt-5-codex"
    When the user picks "gpt-5-codex" on "Codex Proxy" at high effort and sends a message
    Then the turn runs on the custom model "gpt-5-codex", not on a built-in model it is an alias of
    And picking "gpt-5-codex" again offers high effort
