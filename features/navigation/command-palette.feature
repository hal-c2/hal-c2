# Sources:
#   https://github.com/pingdotgg/t3code/pull/24032
#   https://github.com/pingdotgg/t3code/pull/25133
#   https://github.com/pingdotgg/t3code/pull/24709
#   https://github.com/pingdotgg/t3code/pull/24343
#   https://github.com/pingdotgg/t3code/pull/19055
#   https://github.com/pingdotgg/t3code/pull/15940
#   https://github.com/pingdotgg/t3code/pull/8513
#   https://github.com/pingdotgg/t3code/pull/10158
#   https://github.com/pingdotgg/t3code/pull/25315
#   docs/user/keyboard-focus.md
#   docs/user/appearance.md (Change theme, Change appearance)
#   apps/web/src/components/CommandPalette.tsx
#   apps/web/src/components/CommandPalette.logic.ts
#   packages/shared/src/keybindings.ts (commandPalette.toggle, filePicker.toggle, projectSearch.toggle)
#   apps/tui/src/commands.ts (filterCommands)
#   apps/tui/src/keymap.ts (^K palette)
#   apps/desktop-qt/src/native/CommandPaletteController.cpp
#   apps/desktop-qt/qml/HalC2/Bricks/CommandPalette.qml
#   apps/desktop-qt/tests/tst_CommandPalette.qml
#   Command palette entries: action:new-thread, action:new-thread-in, action:copy-thread-reference,
#   action:link-pull-request, action:open-thread-pull-requests, action:open-file-picker,
#   action:search-project-contents, action:add-project, action:add-project:wsl-folder,
#   action:change-theme, action:change-appearance, action:theme-editor, action:pull-requests,
#   action:usage, action:settings, action:project-settings, setting:<id>, theme:<id>, appearance:<mode>

Feature: Command palette
  The command palette is one keyboard-driven place to run actions, jump to threads,
  projects and settings, and find files and text in the project.

  Background:
    Given the user has a project "hal-c2" with threads
    And the user is looking at a thread in that project

  Rule: Opening and closing

    @shared @backlog-mobile @priority-low
    Scenario: The palette opens from its shortcut
      When the user presses the command palette shortcut
      Then the command palette is open
      And the search field has keyboard focus

    @shared @backlog-mobile @priority-low
    Scenario: The palette closes from its shortcut
      Given the command palette is open
      When the user presses the command palette shortcut
      Then the command palette is closed

    @desktop
    Scenario: Closing the palette returns focus to the composer
      Given the command palette is open
      When the user dismisses the command palette
      Then the composer has keyboard focus

    @desktop
    Scenario Outline: The palette opens in each mode from its own shortcut
      When the user presses the <mode> shortcut
      Then the command palette is open in <mode> mode
      And no other palette mode is open

      Examples:
        | mode           |
        | command        |
        | go to file     |
        | project search |

    @desktop
    Scenario Outline: Pressing a mode's shortcut again closes that mode
      Given the command palette is open in <mode> mode
      When the user presses the <mode> shortcut
      Then the command palette is closed

      Examples:
        | mode           |
        | go to file     |
        | project search |

    @desktop
    Scenario Outline: Escape in a secondary mode returns to command mode
      Given the command palette is open in <mode> mode
      When the user presses Escape
      Then the command palette is open in command mode

      Examples:
        | mode           |
        | go to file     |
        | project search |

    @desktop
    Scenario: Reopening the palette starts from the root list
      Given the command palette is open
      And the user types "qqqqqq"
      When the user dismisses the command palette
      And the user opens the command palette
      Then the search field is empty
      And the palette shows an "Actions" group

  Rule: The root list

    @desktop
    Scenario: With no query the palette shows actions and recent threads
      When the user opens the command palette
      Then the palette shows an "Actions" group
      And the palette shows a "Recent Threads" group of at most 12 threads

    @desktop
    Scenario: Archived threads are not offered
      Given the thread "Old spike" is archived
      When the user opens the command palette
      Then "Old spike" is not listed

    @desktop
    Scenario: A thread entry names its project and branch
      Given the thread "Fix login" is on branch "auth-fix"
      When the user opens the command palette
      Then "Fix login" is described with the project "hal-c2" and "#auth-fix"

    @desktop
    Scenario: The current thread is marked
      When the user opens the command palette
      Then the thread the user is looking at is described as "Current thread"

  Rule: Searching

    @desktop
    Scenario: Typing a query adds projects, settings and threads and hides recent threads
      Given the command palette is open
      When the user types "theme"
      Then matching actions, projects, settings and threads are listed in their own groups
      And the "Recent Threads" group is hidden

    @desktop
    Scenario: Exact matches rank above prefix matches, and prefix above substring
      Given threads titled "Deploy", "Deploy docs" and "Fix deploy"
      When the user searches the palette for "deploy"
      Then "Deploy" is listed before "Deploy docs"
      And "Deploy docs" is listed before "Fix deploy"

    # Upstream #24343: one score rates each word of a match, then weighs it by use.
    # Replaces the scenario above once the desktop and the phone carry it.
    @backlog @desktop @mobile
    Scenario: A whole word ranks above a word's start, words run together, a typo and a match inside a word
      Given threads titled "Fix vs code", "VSCodeium setup", "vscode launch", "Fix vscdoe" and "Revscode"
      When the user searches the palette for "vscode"
      Then "vscode launch" is listed first
      And "VSCodeium setup", "Fix vs code", "Fix vscdoe" and "Revscode" follow in that order

    @desktop
    Scenario: Equal thread matches are ordered by most recent activity
      Given two threads titled "Refactor" and "Refactor" with the second updated more recently
      When the user searches the palette for "refactor"
      Then the more recently updated thread is listed first

    # Upstream #24343: use counts, but never beats a better match.
    # Replaces the scenario above once the desktop and the phone carry it.
    @backlog @desktop @mobile
    Scenario: Threads the user writes in and opens lately rank higher among equal matches
      Given two threads titled "Refactor", the second written in and opened more lately
      And a thread titled "Refactor notes" the user opens every day
      When the user searches the palette for "refactor"
      Then the second "Refactor" is listed first, then the other, then "Refactor notes"

    # Upstream #25133: a thread shown before its details had loaded was never counted as
    # opened, so it did not rise in search.
    @backlog @mc @desktop @mobile @priority-low
    Scenario: A thread opened before its details load still counts as opened
      Given the user opens "Refactor" from a link before its details have loaded
      When its details arrive
      Then the environment is told "Refactor" was opened, once
      And "Refactor" ranks as opened lately in search on every device

    @backlog @mc @desktop @mobile @priority-low
    Scenario: A query the user picked a thread from before puts that thread first
      Given the user searched for "cart" and opened "Ship checkout" from the results last week
      When the user searches the palette for "cart" on any of their devices
      Then "Ship checkout" is listed first among the threads matching "cart"

    # Upstream #24032: subagent threads crowded thread search and the recent threads; forks are
    # the user's own threads and stay.
    @backlog @desktop @mobile
    Scenario: Subagent threads are not offered
      Given "Fix checkout" started the subagent thread "Checkout tests"
      And "Checkout fork" is a fork of "Fix checkout"
      When the user searches the palette for "checkout"
      Then "Fix checkout" and "Checkout fork" are listed and "Checkout tests" is not
      And "Checkout tests" is not among the recent threads either

    @backlog @desktop @mobile
    Scenario Outline: A thread row says why it matched
      Given a thread whose <field> contains "zebra" and whose title does not
      When the user searches the palette for "zebra"
      Then its row says "<says>"

      Examples:
        | field               | says           |
        | branch              | Branch: zebra  |
        | linked pull request | PR: #42        |

    @desktop
    Scenario Outline: Threads are found by more than their title
      Given a thread whose <field> contains "zebra"
      When the user searches the palette for "zebra"
      Then that thread is listed

      Examples:
        | field               |
        | title               |
        | linked pull request |
        | project name        |
        | branch              |
        | id                  |
        | message content     |

    @desktop
    Scenario Outline: Threads on other machines are found and opened
      Given the thread "Remote fix" is on <where>
      When the user searches the palette for "remote fix"
      And the user moves the highlight to "Remote fix" and presses Enter
      Then the thread "Remote fix" opens
      And the command palette is closed

      Examples:
        | where                     |
        | another MC of the cluster |

      # MCs join only by clustering (connections/links.feature).
      @dropped
      Examples:
        | where                |
        | a linked environment |

    @desktop
    Scenario: Message content search reports while it runs
      Given the command palette is open
      When the user searches for text that only appears inside messages
      Then the palette says "Searching thread messages…" until the results arrive

    # Upstream #24343: late message results were mixed in with title matches, so rows jumped.
    # Replaces the scenario above once the desktop and the phone carry it.
    @backlog @desktop @mobile
    Scenario: Message matches come below thread matches and never move them
      Given the user searched the palette for "zebra" and the thread matches are listed
      When the matches inside messages arrive
      Then they are listed under "In messages", below "Threads"
      And the rows above and the highlight stay where they were
      And the footer said "Searching messages…" until they arrived, without the palette changing height

    @backlog @desktop @mobile
    Scenario: Choosing a message match opens the thread at that message
      Given the palette lists a match for "zebra" inside an older message of "Fix checkout"
      When the user chooses it
      Then "Fix checkout" opens at that message with "zebra" found

    @desktop
    Scenario: A leading ">" limits the palette to actions
      Given the command palette is open
      When the user types ">new"
      Then only actions are listed

    @desktop
    Scenario: No matching actions
      Given the command palette is open
      When the user types ">qqqqqq"
      Then the palette says "No matching actions."

    @desktop
    Scenario: No matches at all
      Given the command palette is open
      When the user types "qqqqqq"
      Then the palette says "No matching commands, projects, or threads."

    # As the web's filterCommandPaletteGroups: the groups keep their order, actions,
    # projects, settings, then threads, however well each entry matches.
    @desktop
    Scenario: Settings are listed after actions and projects and before threads
      Given a thread titled "Appearance"
      When the user searches the palette for "appearance"
      Then "Change appearance" is listed before the "Appearance" setting
      And the "Appearance" setting is listed before the thread "Appearance"

    # The web's settings search lists each keybinding command as a secondary entry.
    @desktop
    Scenario: Shortcut entries sort after the settings they mirror
      When the user searches the palette for "model"
      Then the "Default model" setting is listed before the "Model Picker" shortcut

    @tui
    Scenario: The terminal palette ranks title prefix, then substring, then keyword, then subsequence
      Given the palette commands "New thread", "Renew token" and "Toggle terminal"
      When the user types "new" into the palette
      Then "New thread" is listed before "Renew token"
      And commands that only match by subsequence are listed last

  Rule: Choosing entries

    @shared @backlog-mobile @backlog-tui @priority-high
    Scenario: Enter runs the highlighted entry
      Given the command palette lists "Open settings"
      When the user moves the highlight to "Open settings" and presses Enter
      Then settings open
      And the command palette is closed

    @desktop
    Scenario: Choosing a project opens its latest thread
      Given the project "docs-site" has the threads "Write intro" and "Fix links"
      When the user searches the palette for "docs-site"
      And the user moves the highlight to "docs-site" and presses Enter
      Then the thread "Fix links" opens

    @desktop
    Scenario: Choosing a project with no threads starts a new thread in it
      When the user searches the palette for "theme-lab"
      And the user moves the highlight to "theme-lab" and presses Enter
      Then a new thread starts in "theme-lab"
      And the command palette is closed

    @desktop
    Scenario: Entries that appear under a resting pointer are not highlighted
      Given the pointer rests where the palette's entries appear
      When the user types a folder path while adding a project
      Then no entry is highlighted until the pointer moves
      And Enter adds the folder typed

    @desktop
    Scenario: A number shortcut runs the Nth entry
      Given the command palette is open
      When the user presses mod+3
      Then the third listed entry runs

    @desktop
    Scenario: Backspace on an empty query leaves a submenu
      Given the palette shows the "Change theme" submenu
      And the search field is empty
      When the user presses Backspace
      Then the palette shows the root list again

    # Upstream #15940: going back from a submenu or a search cleared the search that led there.
    @backlog @desktop @priority-low
    Scenario Outline: Going back in the palette brings back the search that led there
      Given the user typed "<query>" in the palette and opened <view> from it
      When the user goes back with <key>
      Then the palette shows the root list searched for "<query>"

      Examples:
        | query      | view                       | key       |
        | theme      | the "Change theme" submenu | Backspace |
        | go to file | go to file mode            | Escape    |
        | >search    | project search mode        | Escape    |

    # Upstream #15940: closing the palette forgets the searches it went through.
    @backlog @desktop @priority-low
    Scenario: A palette opened again forgets where the user went back from
      Given the user typed "theme" in the palette and opened the "Change theme" submenu
      When the user closes the palette and opens it again
      Then the palette shows the root list with an empty search

    # Upstream #24709: the palette's search matched only top-level rows, so "new thread in shop"
    # found nothing.
    @backlog @desktop @tui
    Scenario Outline: Searching the palette suggests options inside its submenus
      When the user types "<query>" in the palette
      Then "<suggestion>" is suggested first
      And at most three suggestions are shown

      Examples:
        | query              | suggestion              |
        | new thread in shop | New thread in shop      |
        | dracula            | Change theme: Dracula   |
        | dark               | Change appearance: Dark |

    # Upstream #24709
    @backlog @desktop @tui @priority-low
    Scenario: A query that only names a submenu suggests none of its options
      When the user types "change theme" in the palette
      Then "Change theme" is listed
      And none of its themes are suggested

    # Upstream #24709
    @backlog @desktop @tui
    Scenario: A submenu search with no match searches everything
      Given the palette shows the "New thread in..." submenu
      When the user types "add project"
      Then "Add project" is offered

    @desktop
    Scenario: A command that fails says so
      Given an action that will fail
      When the user runs it from the palette
      Then the user is told "Unable to run command"

    @desktop
    Scenario: Copying the thread's ID names the thread, never shows the ID
      Given the command palette is open
      Then "Copy thread ID" is described by the title of the thread the user is looking at

    @desktop
    Scenario Outline: Every palette action does its job
      Given the command palette is open
      When the user runs "<title>"
      Then <outcome>

      Examples:
        | entry                            | title                       | outcome                                                        |
        | action:usage                     | Open usage                  | the usage page opens                                           |
        | action:settings                  | Open settings               | settings open                                                  |
        | action:new-thread                | New thread in hal-c2        | a new thread starts in "hal-c2"                                |
        | action:new-thread-in             | New thread in...            | the palette lists projects with the current project first      |
        | action:copy-thread-reference     | Copy thread ID              | the thread id is on the clipboard                              |
        | action:link-pull-request         | Link pull request to thread | the user is asked which pull request to link to the thread     |
        | action:open-file-picker          | Go to file                  | the palette is in go to file mode                              |
        | action:search-project-contents   | Search project contents     | the palette is in project search mode                          |
        | action:add-project               | Add project                 | the palette asks where the project comes from                  |
        | action:change-theme              | Change theme                | the palette lists themes with the current one marked "Current" |
        | action:change-appearance         | Change appearance           | the palette offers System, Light and Dark                      |
        | action:theme-editor              | Toggle theme editor         | the theme editor opens                                         |
        | action:pull-requests             | Open pull requests          | the pull request list opens                                    |
        | action:project-settings          | Project settings            | the current project's settings open                            |

      @backlog
      Examples:
        | entry                            | title                       | outcome                                                        |
        | action:open-thread-pull-requests | Show linked pull requests   | the palette lists the thread's linked pull requests            |
        | action:add-project:wsl-folder    | Open WSL folder             | the palette asks for a folder inside WSL                       |

    @desktop
    Scenario: A thread with a linked pull request copies the link instead of the id
      Given the thread has a linked pull request
      When the user runs "Copy PR link" from the palette
      Then the pull request URL is on the clipboard

    # Upstream #8513: the entry showed chat.new's key, which opens the project picker instead.
    @backlog @desktop @priority-low
    Scenario: The new thread entry shows the key that starts a thread in the current project
      Given "chat.new" is bound to "mod+shift+o" and "chat.newLocal" to "mod+shift+n"
      When the user opens the command palette in the project "hal-c2"
      Then "New thread in hal-c2" shows "mod+shift+n"

    @desktop
    Scenario: Linked pull requests are unavailable when the thread has none
      Given the thread has no linked pull request
      When the user opens the command palette
      Then "Show linked pull requests" cannot be run

    @desktop
    Scenario: Pull requests are only offered where the environment supports them
      Given the environment has no source control provider for pull requests
      When the user opens the command palette
      Then "Open pull requests" is not listed

    @desktop
    Scenario: Linking a pull request to the thread from the palette
      When the user runs "Link pull request to thread" from the palette
      And the user gives pull request 42
      Then pull request 42 is linked to the thread

    @desktop
    Scenario: Linking is not offered where the environment cannot link pull requests
      Given the thread's environment cannot link pull requests to threads
      When the user opens the command palette
      Then "Link pull request to thread" is not listed

    @desktop
    Scenario: Open pull requests shows the pull requests page as the user left it
      Given the user last filtered the pull requests page to their own open pull requests
      When the user runs "Open pull requests" from the palette
      Then the pull requests page opens filtered to the user's own open pull requests

    @desktop
    Scenario: Open pull requests is offered when any environment supports pull requests
      Given one connected environment supports pull requests and another does not
      When the user opens the command palette
      Then "Open pull requests" is listed

    @desktop
    Scenario: Add project walks the user to a new project
      When the user runs "Add project" from the palette
      And the user chooses a local folder "~/code/shop"
      Then "shop" is added as a project
      And the user can start a thread in it

    @desktop
    Scenario: Adding a project while the list is scoped moves the scope to it
      Given the thread list is scoped to the project "docs"
      When the user runs "Add project" from the palette
      And the user chooses a local folder "~/code/shop"
      Then "shop" is added as a project
      And the sidebar is scoped to "shop"

    @desktop
    Scenario: Threads linked to a pull request include archived ones
      Given a pull request is linked to an archived thread
      When the user searches the palette for that pull request
      Then the archived thread is listed as "Archived thread"
      And live threads are listed as "Linked thread"

    @desktop
    Scenario Outline: Picking a sub-item applies it
      Given the palette shows the "<submenu>" submenu
      When the user chooses "<item>"
      Then <outcome>

      Examples:
        | submenu           | item      | outcome                            |
        | Change theme      | Nord      | the active theme is "Nord"         |
        | Change appearance | Dark      | the app appearance is dark         |
        | New thread in...  | docs-site | a new thread starts in "docs-site" |

    # Upstream #25315: the new-thread shortcut opened the submenu with the keyboard on its Back
    # button, so typing did not pick a project.
    @backlog @desktop
    Scenario: The new-thread shortcut opens the project chooser ready for typing
      Given the user has several projects and none is in scope
      When the user presses the new-thread shortcut
      Then the palette shows the "New thread in..." submenu with its search field focused
      When the user types "docs" and presses Enter
      Then a new thread starts in "docs-site"

    @desktop
    Scenario: A settings result opens that setting
      When the user searches the palette for "word wrap" and chooses the setting
      Then settings open with the word wrap setting highlighted

    # Upstream #19055: new-thread shortcuts run while the open command palette lists them;
    # shortcuts of entries the search filtered out, and keys typed during IME composition, do not.
    @backlog @desktop
    Scenario: A new-thread shortcut the palette lists runs while the palette is open
      Given the command palette is open and lists "New thread" with its shortcut
      When the user presses that shortcut
      Then a new thread starts
      And the command palette is closed

    # Upstream #19055: a shortcut whose entry the search filtered out stays unavailable.
    @backlog @desktop
    Scenario: A shortcut of an entry the search hid does nothing in the palette
      Given the user searched the command palette so that "New thread" is not listed
      When the user presses the new-thread shortcut
      Then no thread is started
      And the command palette stays open
