# Sources:
#   apps/web/src/components/settings/SettingsPanels.tsx (GeneralSettingsPanel, LegacyFeaturesSection, AboutVersionTitle, update track)
#   apps/web/src/components/settings/ScopedSwitch.tsx
#   apps/web/src/components/ui/draft-input.tsx, apps/web/src/hooks/useCommitOnBlur.ts (typed text settings)
#   apps/desktop-qt/src/native/ProjectController.cpp (addProjectBaseDirectory: where Add project browses from)
#   apps/web/src/components/settings/SettingInheritance.tsx (reset buttons)
#   apps/web/src/components/ChatView.tsx, ChatView.logic.ts, apps/web/src/rightPanelStore.ts (when proactive panels open and what holds them back)
#   packages/contracts/src/settings.ts (sidebarProjectGroupingMode, autoResumeLimitedThreads, snoozeLimitedThreads, sidebarAutoSettleOnMerge, sidebarAutoSettleAfterDays, timestampFormat, responseStreamingMode, diffIgnoreWhitespace, diffFilesCollapsed, diffLayout, proactivePanelsEnabled, sendShortcut, followUpBehavior, continueThreadsAfterServerUpdate, newWorktreesStartFromOrigin, addProjectBaseDirectory, confirmThreadUnpin, confirmThreadArchive, confirmThreadDelete, confirmQuit, textGenerationModelSelection)
#   apps/server-ex/lib/hal_c2/settings.ex
#   apps/server-ex/lib/hal_c2/orchestration/settlement.ex (sidebarAutoSettleOnMerge, sidebarAutoSettleAfterDays)
#   apps/server-ex/lib/hal_c2/orchestration/recovery.ex (continueThreadsAfterServerUpdate)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (responseStreamingMode)
#   apps/server-ex/lib/hal_c2/mcp/tools/projects.ex (newWorktreesStartFromOrigin)
#   apps/server-ex/lib/hal_c2/environment.ex (threadRestartContinuation capability)
#   apps/server-ex/lib/hal_c2/text_generation.ex (textGenerationModelSelection)
#   apps/mobile/src/features/settings/SettingsThreadsRouteScreen.tsx (usage limits, auto-settle, defaults differ)
#   apps/mobile/src/features/settings/SettingsFollowUpRouteScreen.tsx
#   apps/mobile/src/features/settings/SettingsProjectGroupingRouteScreen.tsx
#   apps/mobile/src/features/settings/autoSettleSettingsSync.ts
#   Cross-domain: the General row enableProviderUpdateChecks is specified in settings/updates.feature.

Feature: General settings
  The General section holds the everyday behaviour of threads, the composer, diffs and
  confirmations. Rows that the MC honours apply to the environments chosen in the settings
  scope; the rest follow the user on this device. Each changed row can be reset to its default.

  Background:
    Given the user has opened the General settings

  Rule: Organization

    @desktop @mobile @backlog-mobile
    Scenario: Turning project grouping off shows each environment's projects separately
      Given project grouping combines matching repositories across environments
      When the user turns project grouping off
      Then the sidebar lists each environment's copy of a repository as its own project

    @desktop
    Scenario: Turning project grouping back on restores the grouping mode used before
      Given the user had grouped projects by repository and then turned grouping off
      When the user turns project grouping on again
      Then projects are grouped by repository again

    @desktop @mobile @backlog-mobile
    Scenario Outline: A thread stopped by a usage limit follows the limit settings
      Given "<setting>" is on for the environment
      When a thread stops because the provider's usage limit was reached
      Then the thread <result> at the reported reset time

      Examples:
        | setting                     | result                            |
        | Auto-resume limited threads | is scheduled to continue          |
        | Snooze limited threads      | is snoozed until it wakes         |

    @desktop
    Scenario: A scheduled continuation can be cancelled from the thread
      Given "Auto-resume limited threads" is on
      And a limited thread is scheduled to continue at its reset time
      When the user cancels the scheduled continuation in that thread
      Then the thread does not continue on its own

    @mc
    Scenario: A thread whose pull requests all merged settles when merge settling is on
      Given "Auto-settle merged threads" is on
      And every pull request linked to a thread has merged after the user last wrote in it
      When the MC sweeps threads
      Then the thread is settled

    @mc
    Scenario: A thread with a merged pull request stays when merge settling is off
      Given "Auto-settle merged threads" is off
      And every pull request linked to a thread has merged
      When the MC sweeps threads
      Then the thread is not settled for the merge

    @mc
    Scenario: A thread idle longer than the chosen days settles
      Given "Auto-settle inactive threads" is on with 3 days
      And a thread has had no activity for 4 days
      When the MC sweeps threads
      Then the thread is settled

    @mc
    Scenario: Turning inactive settling off keeps idle threads
      Given "Auto-settle inactive threads" is off
      And a thread has had no activity for 30 days
      When the MC sweeps threads
      Then the thread is not settled

    @desktop @mobile @backlog-mobile
    Scenario: Turning inactive settling on starts from the default number of days
      Given "Auto-settle inactive threads" is off
      When the user turns it on
      Then the number of days before settling is shown with its default
      And the user can change the number of days

    # Legacy: apps/web/src/components/settings/SettingsPanels.tsx (AutoSettleDaysInput), packages/contracts/src/settings.ts (1 to 90 days)
    @backlog @desktop
    Scenario Outline: Only whole days from 1 to 90 are kept as the inactivity limit
      Given "Auto-settle inactive threads" is on with 3 days
      When the user types <entry> as the number of days
      Then the inactivity limit <result>
      When the user leaves the field
      Then the field shows <shown>

      Examples:
        | entry | result          | shown |
        | 0     | stays at 3 days | 3     |
        | 91    | stays at 3 days | 3     |
        | 3.5   | stays at 3 days | 3     |
        | empty | stays at 3 days | 3     |
        | 90    | becomes 90 days | 90    |
        | 1     | becomes 1 day   | 1     |

    @backlog @mobile
    Scenario: Environments whose auto-settle settings differ can be brought in line
      Given "laptop" settles threads after 3 days and "server" after 7 days
      And the phone shows the settings of "laptop"
      When the user opens the thread behaviour settings on a phone
      Then the user is told the auto-settle defaults of "server" differ
      When the user applies the shown auto-settle defaults to all environments
      Then "server" settles threads after 3 days

    @desktop
    Scenario: Settling rows are hidden when a chosen environment cannot settle threads
      Given the settings scope includes an environment whose MC does not settle threads
      Then the auto-settle rows are not shown

  Rule: Behaviour

    @desktop
    Scenario Outline: The user chooses how times are written
      When the user sets the time format to "<format>"
      Then timestamps are shown <shown>

      Examples:
        | format         | shown                                   |
        | System default | the way the system clock is configured  |
        | 12-hour        | with AM and PM                          |
        | 24-hour        | on a 24-hour clock                      |

    @mc
    Scenario Outline: The MC streams replies as the chosen mode says
      Given the response streaming mode is "<mode>"
      When the agent writes a long reply
      Then the reply appears <appears>

      Examples:
        | mode      | appears                                                     |
        | paragraph | a finished paragraph or closed code block at a time          |
        | turn      | only when a boundary such as a tool call or the turn end comes |

    @desktop
    Scenario: Environments with different streaming modes read as mixed
      Given the settings scope covers two environments with different streaming modes
      Then the response streaming row reads "Mixed"
      And choosing a mode writes it to both environments

    @desktop
    Scenario Outline: Diff defaults apply when a diff opens
      When the user sets "<setting>" to "<value>"
      And the user opens a diff
      Then the diff opens <result>

      Examples:
        | setting                 | value       | result                              |
        | Hide whitespace changes | on          | without whitespace-only edits       |
        | Default diff file state | Collapsed   | with every file collapsed           |
        | Default diff file state | Expanded    | with every file expanded            |
        | Diff layout             | Split       | side by side                        |
        | Diff layout             | Stacked     | stacked                             |

    @desktop
    Scenario: Changing the layout from a diff also changes the setting
      Given the diff layout setting is "Stacked"
      When the user switches an open diff to side by side
      Then the diff layout setting reads "Split"

    @desktop
    Scenario: Proactive panels open the linked pull request first
      Given proactive panels are on
      When the user opens a thread with a linked pull request
      Then the pull request panel opens with the thread

    @desktop
    Scenario: Proactive panels open the working tree diff for large changes
      Given proactive panels are on
      When the user opens a thread whose working tree changed at least 3 files
      Then the working tree diff opens with the thread

    @desktop
    Scenario: With proactive panels off no panel opens on its own
      Given proactive panels are off
      When the user opens a thread with a linked pull request
      Then no side panel opens by itself

    @backlog @desktop
    Scenario Outline: Proactive panels open the changes of a turn that just finished only when they are large
      Given proactive panels are on and the thread has no linked pull request
      When a turn the user watched finishes having changed <files> with <lines> changed lines
      Then the diff of the working tree <outcome>

      Examples:
        | files   | lines | outcome                 |
        | 3 files | 6     | opens beside the thread |
        | 1 file  | 50    | opens beside the thread |
        | 2 files | 49    | does not open           |
        | 0 files | 0     | does not open           |

    @backlog @desktop
    Scenario: A panel the user chose during a turn is not replaced when the turn finishes
      Given proactive panels are on
      And the user opened the file explorer beside the thread while a turn was running
      When that turn finishes with large changes
      Then the file explorer stays open
      And a later turn that finishes with large changes may open the diff again

    @backlog @desktop
    Scenario: A panel the user chose in one thread does not hold back another thread
      Given proactive panels are on
      And the user closed the side panel of the thread "Cart totals"
      When the user opens another thread with a linked pull request
      Then the pull request panel opens with that thread

    @backlog @desktop
    Scenario: A thread with several pull requests opens their list
      Given proactive panels are on
      When the user opens a thread linked to pull requests 12 and 14
      Then the list of the thread's pull requests opens instead of one of them

    @backlog @desktop
    Scenario: A linked pull request keeps a finished turn's changes from opening
      Given proactive panels are on and the thread has a linked pull request
      When a turn finishes with large changes
      Then the diff does not open over the pull request

    @backlog @desktop
    Scenario Outline: Proactive panels stay closed where they would get in the way
      Given proactive panels are on
      And <situation>
      When <trigger>
      Then no side panel opens by itself

      Examples:
        | situation                                              | trigger                                             |
        | the window is so narrow the panel covers the thread    | the user opens a thread with a linked pull request  |
        | the window is so narrow the panel covers the thread    | a turn finishes with large changes                  |
        | the project folder is not a Git repository             | a turn finishes with large changes                  |

    @backlog @desktop
    Scenario: An open pull request panel follows the thread's pull request even with proactive panels off
      Given proactive panels are off
      And the pull request panel shows the thread's linked pull request 12
      When the thread becomes linked to pull request 14 instead
      Then the panel shows pull request 14
      But a panel showing anything else is left as it is

    @desktop
    Scenario Outline: Composer preferences change how the composer behaves
      When the user turns "<setting>" <state>
      Then <result>

      Examples:
        | setting                     | state | result                                                            |
        | Show skills in slash menu   | on    | skills are listed in the slash command menu as well as after a dollar sign |
        | Show skills in slash menu   | off   | skills are only listed after a dollar sign                         |
        | Rich text composer          | on    | Markdown is shown formatted while typing                           |
        | Rich text composer          | off   | the composer shows plain text                                      |
        | Collapse composer on scroll | on    | the composer of an existing thread shrinks to one line while scrolling |
        | Collapse composer on scroll | off   | the composer keeps its size while scrolling                        |

    @desktop
    Scenario Outline: The send shortcut decides what Enter does
      Given the send shortcut is "<shortcut>"
      When the user presses Enter in a <prompt> prompt
      Then the prompt <result>

      Examples:
        | shortcut                                | prompt      | result                 |
        | Enter                                   | single line | is sent                |
        | Enter                                   | multiline   | is sent                |
        | Modifier and Enter for multiline prompts | single line | is sent                |
        | Modifier and Enter for multiline prompts | multiline   | gets a new line        |
        | Modifier and Enter always               | single line | gets a new line        |

    @desktop @mobile @backlog-mobile
    Scenario Outline: Follow-up behaviour decides what a message sent during a run does
      Given the follow-up behaviour is "<mode>"
      When the user sends a message while the agent is running
      Then the message <result>

      Examples:
        | mode  | result                              |
        | Queue | waits until the run ends            |
        | Steer | is sent into the current run        |

    @mc
    Scenario: A turn cut off by a restart continues when continuation is on
      Given "Continue threads after restarts" is on for the project
      And a turn was running when the MC stopped
      When the MC starts again
      Then the thread is asked to continue where it left off

    @mc
    Scenario: A turn cut off by a restart stays stopped when continuation is off
      Given "Continue threads after restarts" is off for the project
      And a turn was running when the MC stopped
      When the MC starts again
      Then the thread stays interrupted

    @desktop
    Scenario: Restart continuation cannot be turned on for an environment that lacks it
      Given the settings scope includes an environment that cannot continue threads after restarts
      Then the continuation switch is disabled
      And it explains that every selected environment must support restart continuation

  Rule: Projects and threads

    @mc
    Scenario: New worktrees start from origin by default
      Given "Start new worktrees from origin" is on
      When an agent creates a worktree for a thread without choosing a base
      Then the worktree starts from the latest matching branch on origin

    @mc
    Scenario: New worktrees start from the local branch when origin is off
      Given "Start new worktrees from origin" is off
      When an agent creates a worktree for a thread without choosing a base
      Then the worktree starts from the local branch

    @desktop
    Scenario: The add project browser opens in the chosen base directory
      Given the add project base directory is "~/code"
      When the user starts adding a project
      Then the folder browser opens in "~/code"

    @desktop
    Scenario: An empty base directory opens the add project browser at home
      Given the add project base directory is empty
      When the user starts adding a project
      Then the folder browser opens in the home folder

  # Legacy: apps/web/src/components/ui/draft-input.tsx, apps/web/src/hooks/useCommitOnBlur.ts
  # (the base directory, provider binary paths and names, the browser profile name)
  Rule: Typed text settings

    @backlog @desktop
    Scenario: A typed setting is saved when the user presses Enter or leaves the field
      Given the add project base directory is "~/code"
      When the user types "~/src" in the base directory field
      Then the setting is still "~/code"
      When the user presses Enter
      Then the setting is "~/src"

    @backlog @desktop
    Scenario: Leaving a typed setting saves it once
      When the user types "~/src" in the base directory field and clicks elsewhere
      Then the setting is saved as "~/src" once

    @backlog @desktop
    Scenario: A typed setting that was not changed is not saved
      Given the add project base directory is "~/code"
      When the user clicks into the base directory field and leaves it again
      Then nothing is saved

    @backlog @desktop
    Scenario: A setting changed elsewhere does not replace what the user is typing
      Given the user is typing "~/sr" in the base directory field
      When the setting is reset to its default from another window
      Then the field still shows "~/sr"

    @backlog @desktop
    Scenario: Enter that confirms an input method composition does not save the field
      Given the user is composing text in the base directory field with an input method
      When the user presses Enter to confirm the composition
      Then the field stays open for editing
      And nothing is saved yet

  Rule: Confirmations

    @desktop
    Scenario Outline: A confirmation setting decides whether the user is asked first
      Given "<setting>" is <state>
      When the user <action> a thread
      Then <result>

      Examples:
        | setting                 | state | action    | result                                         |
        | Confirm thread unpinning | on    | unpins    | the user is asked before the thread is unpinned |
        | Confirm thread unpinning | off   | unpins    | the thread is unpinned straight away            |
        | Confirm thread archiving | on    | archives  | the archive action must be chosen a second time |
        | Confirm thread archiving | off   | archives  | the thread is archived straight away            |
        | Confirm thread deletion  | on    | deletes   | the user is asked before the history is deleted |
        | Confirm thread deletion  | off   | deletes   | the thread is deleted straight away             |

    @desktop
    Scenario Outline: The quit shortcut follows the chosen behaviour
      Given the quit shortcut behaviour is "<mode>"
      When the user presses the quit shortcut
      Then <result>

      Examples:
        | mode         | result                                                 |
        | direct       | the app quits at once                                  |
        | hold         | the app quits only after the shortcut is held          |
        | double-click | the app quits only after the shortcut is pressed twice |

    @desktop
    Scenario: Hold mode also quits on two quick presses
      Given the quit shortcut behaviour is "hold"
      When the user presses the quit shortcut twice quickly
      Then the app quits

  Rule: Text generation

    @mc
    Scenario: Generated text uses the chosen text generation model
      Given the text generation model is set to a model of an installed provider
      When the MC names a new thread
      Then the title is written by that model

    @desktop
    Scenario: A text generation model that cannot be saved is reported
      Given the settings scope covers an environment that does not offer the chosen model
      When the user chooses that text generation model
      Then the user is told "Text generation model not saved"
      And the previous model stays selected

    @desktop
    Scenario: Text generation is unavailable without a provider that can generate text
      Given no enabled provider in the scope can generate text
      Then the text generation model row explains why it cannot be chosen

  Rule: About and legacy features

    @backlog @desktop
    Scenario: About shows the app version and checks for updates
      When the user checks for updates from About
      Then the row shows it is checking and then "Up to Date" or the update to download

    @backlog @desktop
    Scenario: A failed update check is reported
      Given the update server cannot be reached
      When the user checks for updates from About
      Then the user is told "Could not check for updates" with the reason

    @desktop
    Scenario: Legacy features are folded away until asked for
      Then the legacy features section is folded
      When the user unfolds it
      Then the legacy plan mode, context window indicator and per-project sidebar can be turned on

    @backlog @desktop
    Scenario Outline: A legacy feature restores the retired behaviour
      When the user turns on the legacy "<feature>"
      Then <result>

      Examples:
        | feature                  | result                                                        |
        | plan mode                | Build and Plan modes, the plan commands and Shift+Tab return   |
        | context window indicator | the composer shows context use as a circular indicator         |
        | sidebar                  | the sidebar shows a thread tree per project                    |

  Rule: Resetting rows

    @desktop
    Scenario: A changed row can be reset to its default
      Given the user turned project grouping off
      When the user resets project grouping
      Then project grouping is back to its default
      And the row no longer offers a reset

    @desktop
    Scenario: A row at its default offers no reset
      Given auto-settle on merge is at its default
      Then the row offers no reset
