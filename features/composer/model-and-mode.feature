# Sources:
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

  @desktop
  Scenario: The chosen model is shown with its provider
    When the user chooses the model "gpt-5-codex"
    Then the composer shows "gpt-5-codex" marked as a Codex model

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

  @desktop
  Scenario: Ultrathink prefixes the prompt
    Given the thread runs on Claude
    When the user turns on Ultrathink and sends "design the cache"
    Then the agent receives "Ultrathink: design the cache"

  # Legacy: packages/shared/src/model.ts (applyClaudePromptEffortPrefix)
  # Likely already implemented: apps/server-ex/lib/hal_c2/claude/provider.ex (prompt/2)
  @backlog @mc
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

  @desktop @mobile @backlog-mobile
  Scenario: A thread's provider is locked once it has started
    Given the thread has already run a turn on Codex
    When the user looks through the models
    Then only Codex models can be chosen

  @desktop @tui @mobile @backlog-mobile
  Scenario: The last model used with each provider is remembered
    Given the user last used "gpt-5" with Codex
    When the user starts a new thread on Codex
    Then "gpt-5" is chosen
    But a model set for the project takes precedence

  @desktop @tui @mobile @backlog-mobile
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

  @desktop
  Scenario: A new thread can run on a machine that has other projects
    Given "laptop" has the project "shop" and the connected machine "server" has only "scratch"
    And the user has typed a prompt for a new thread in "shop"
    When the user chooses "server · scratch" as the machine the thread runs on
    Then the new thread is in "scratch" on "server"
    And the prompt is still there

  @backlog @desktop
  Scenario: The user lets a new thread's machine be picked automatically
    Given the project exists on two connected machines and load balancing is on
    When the user chooses "Auto balance" as the machine a new thread runs on
    Then the thread starts on the machine with the most room when the first message is sent

  @backlog @desktop
  Scenario: Auto balance says when it cannot check the machines
    Given the user chose "Auto balance" for a new thread
    When checking the machines' free resources fails
    Then the picker shows "Auto balance unavailable"

  @backlog @desktop
  Scenario: The user takes a new thread off Auto balance
    Given the user chose "Auto balance" for a new thread
    When the user chooses the machine "laptop" instead
    Then the thread starts on "laptop"

  @backlog @desktop
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

  @backlog @desktop
  Scenario: Auto balance is refused while the draft has attachments
    Given the draft of a new thread has an attached file
    When the user chooses "Auto balance" as the machine the thread runs on
    Then the user is told "Keep attachments on this machine" and to remove them first
    And the thread still runs on the machine it was on

  @backlog @desktop
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

  @backlog @desktop
  Scenario: The only connected machine is still shown when it is a remote one
    Given the project runs on a remote machine "server" and no other machine is connected
    When the user looks at a new thread's composer
    Then the machine "server" is shown
    And it cannot be changed

  @backlog @desktop
  Scenario: The machine is left out when it is the only one and it is this one
    Given the project runs on the machine being used and no other machine is connected
    When the user looks at a new thread's composer
    Then no machine is shown

  @backlog @desktop
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

  @backlog @desktop
  Scenario: The model picker opens on the favourites when there are any
    Given the user has marked "claude-opus" as a favourite
    When the user opens the model picker
    Then the favourites are listed first, each under its own provider's name
    But in a thread that has already run a turn the picker opens on the thread's provider

  @backlog @desktop
  Scenario: A provider's older models are folded away until asked for
    Given Codex lists two current models and three it calls legacy
    When the user looks through Codex's models
    Then the two current models are listed above "Legacy models" marked "3 models"
    When the user opens "Legacy models"
    Then the three older models are listed
    And the section is already open when the thread runs on one of them

  @backlog @desktop
  Scenario: Searching the models finds a provider's older models too
    Given Codex lists the legacy model "gpt-4.1"
    When the user searches the models for "4.1"
    Then "gpt-4.1" is listed without opening "Legacy models"

  @backlog @desktop
  Scenario: A search that matches no model says so
    When the user searches the models for "zzz"
    Then the user is told "No models found"

  @backlog @desktop
  Scenario: A model the provider has just added is marked as new
    Given Codex reports "gpt-6" as a new model
    When the user looks through Codex's models
    Then "gpt-6" is marked as new

  @backlog @desktop
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

  @backlog @desktop
  Scenario: A provider that needs setting up offers its setup from the model picker
    Given Cursor is not installed and HAL-C2 can install it
    When the user looks through Cursor's models
    Then the picker says why Cursor cannot be used and offers "Open provider setup"
    When the user chooses it
    Then the picker closes and the setup for Cursor opens

  @backlog @desktop
  Scenario: Another provider says why it cannot be chosen once the thread has started
    Given Claude is enabled
    And the thread has already run a turn on Codex
    When the user rests on Claude in the model picker
    Then the user reads "Claude is unavailable in this thread. Start a new thread to switch providers."

  @backlog @desktop
  Scenario: The model cannot be changed while a message is on its way
    Given the user has sent a message the MC has not taken yet
    Then the model picker cannot be opened
    And it can be opened again once the MC takes the message

  @backlog @desktop
  Scenario: The model picker waits for the provider list before it can be used
    Given the environment has not yet reported its providers
    Then the composer shows the thread's model and the model picker cannot be opened
    When the providers arrive
    Then the model picker can be opened

  @backlog @desktop
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

  @backlog @desktop
  Scenario: A saved model its provider no longer lists is kept and marked unavailable
    Given the thread runs on OpenCode with the model "kimi-k2"
    And OpenCode no longer lists "kimi-k2"
    When the user looks at the composer
    Then the model reads "kimi-k2 (Unavailable)"
    And the thread's model is not changed to another one

  @backlog @desktop
  Scenario: Several models are chosen for a new thread with Shift
    Given the project is a Git repository
    And the user is starting a new thread with "gpt-5-codex" chosen
    When the user chooses "opus" and "sonnet" with Shift held
    Then the composer names its models as "gpt-5-codex, opus, 1 more"
    When the user chooses "opus" and "sonnet" with Shift held again
    Then only "gpt-5-codex" is chosen and the thread starts on it alone

  @backlog @desktop
  Scenario: Choosing a model without Shift goes back to one model
    Given the user has chosen "gpt-5-codex" and "opus" for a new thread
    When the user chooses "sonnet"
    Then only "sonnet" is chosen

  @backlog @desktop
  Scenario: A thread that has started takes one model only
    Given the thread has already run a turn on Codex
    When the user chooses a model with Shift held
    Then that model replaces the thread's model
    And no second model is chosen

  @backlog @desktop
  Scenario: Planning and building are toggled on the desktop only when plan mode is on
    Given the plan mode setting is on
    Then the composer offers to switch between "Build" and "Plan"
    When the user turns the plan mode setting off
    Then the composer offers no such switch
    And the next turn builds

  @backlog @desktop
  Scenario: Only the permissions the provider supports are offered
    Given the thread's provider supports only Supervised and Full access
    When the user opens the permissions
    Then only Supervised and Full access are offered, each with a line saying what it allows

  @backlog @desktop
  Scenario: A thread whose saved permissions its provider no longer offers is shown as Supervised
    Given the thread was saved with Auto-accept edits
    And its provider now supports only Supervised and Full access
    When the user looks at the composer
    Then the permissions read "Supervised"
    And the thread's saved permissions are unchanged until the user chooses

  @backlog @desktop
  Scenario Outline: The model's options are summed up beside the model
    Given the thread runs on a model with <options>
    Then the composer sums the model's options up as "<summary>"

    Examples:
      | options                                  | summary             |
      | high effort and thinking on              | High · Thinking On  |
      | high effort and fast mode on             | High                |
      | fast mode on and nothing else to set     | Fast                |
      | fast mode off and nothing else to set    | Normal              |

  @backlog @desktop
  Scenario: Fast mode is marked beside the model's other options
    Given the thread runs on a model set to high effort with fast mode on
    Then the summary of the model's options is marked as fast mode on

  @backlog @desktop
  Scenario: Each option's default is marked
    When the user opens the model's options
    Then the provider's default effort is marked "Default"

  @backlog @desktop
  Scenario: Choosing another effort takes Ultrathink off the prompt
    Given the thread runs on Claude
    And the user turned on Ultrathink and typed "design the cache"
    When the user sets the effort to high
    Then the draft reads "design the cache" without "Ultrathink:"
    And the next turn runs with high effort

  @backlog @desktop
  Scenario: A prompt that says ultrathink in its own words fixes the effort
    Given the thread runs on Claude
    And the user has typed "please ultrathink about the cache"
    When the user opens the model's options
    Then the effort reads "Ultrathink" and cannot be changed
    And the user is told "Your prompt contains "ultrathink" in the text. Remove it to change this option."

  @backlog @desktop
  Scenario: Each model keeps the options the user last gave it
    Given the user set "opus" to high effort and "sonnet" to low effort
    When the user switches from "opus" to "sonnet" and back
    Then "sonnet" was offered with low effort and "opus" is back at high effort

  @backlog @desktop
  Scenario: An unavailable model shows the options saved with it without letting them change
    Given the thread runs on OpenCode with a model OpenCode no longer lists, saved with high effort
    When the user opens the model's options
    Then high effort is shown and cannot be changed

  @backlog @desktop
  Scenario: OpenCode's plan agent is offered only when plan mode is on
    Given the thread runs on OpenCode
    And the plan mode setting is off
    When the user opens the model's options
    Then the agent "plan" is not offered
    And a thread saved with the agent "plan" sends its next turn without it
