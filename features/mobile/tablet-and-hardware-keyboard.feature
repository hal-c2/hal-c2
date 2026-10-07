# Sources:
#   apps/mobile/src/lib/layout.ts (split view thresholds, pane widths)
#   apps/mobile/src/features/layout/ (sidebar, inspector pane, maximize content)
#   apps/mobile/src/features/keyboard/ (hardware keyboard commands, iPad command palette)
#   apps/mobile/app.config.ts (supportsTablet)
#   apps/mobile/plugins/withAndroidTabletOrientation
#   apps/mobile-qt/qml/HalC2/Mobile/MobileShell.qml (the desktop's layout from 736 by 480, the phone's below)
#   docs/internals/mobile-qt.md (one root, two layouts)
# Keybinding ids and the desktop command palette are specified in features/navigation/.
# This file covers the tablet layout and hardware keyboards attached to phones and tablets.

Feature: Tablet layout and hardware keyboards
  On a wide enough screen the app shows the thread list, the thread and an inspector side
  by side. A hardware keyboard reaches the common actions without touching the screen.

  # Side by side is the desktop's layout, which needs 736 by 480: its thread list beside its
  # thread. The React Native app split from 720 by 600.
  @mobile
  Scenario Outline: The layout splits only when the screen is large enough
    Given the app window is <width> wide and <height> tall
    Then the thread list and the thread are shown <arrangement>

    Examples:
      | width | height | arrangement     |
      | 1024  | 768    | side by side    |
      | 736   | 480    | side by side    |
      | 720   | 600    | one at a time   |
      | 844   | 390    | one at a time   |
      | 390   | 844    | one at a time   |

  # The desktop's layout has no empty detail pane: with no thread it lands on a new thread's draft.
  @backlog @mobile
  Scenario: An empty detail pane tells the user what to do
    Given the layout is split
    And no thread is selected
    Then the user is told to choose a thread from the sidebar or start a new task

  @mobile
  Scenario: The user hides and shows the thread sidebar
    Given the layout is split
    When the user maximizes the content
    Then the thread sidebar is hidden
    When the user shows the thread sidebar
    Then the thread sidebar is shown

  # These three need the scenarios' MC to serve a thread's files, which the phone's runner does not yet.
  # The last also needs a decision: the desktop's layout keeps the panel beside the thread at any width.
  @backlog @mobile
  Scenario: The user resizes the inspector pane within limits
    Given the layout shows an inspector pane
    When the user makes the pane wider as far as it goes
    Then the pane stops at its widest size
    When the user makes the pane narrower as far as it goes
    Then the pane stops at its narrowest size

  @backlog @mobile
  Scenario: The files browser sits beside the thread on a large tablet
    Given the app window is 1024 wide
    When the user opens the thread's files
    Then the files browser is shown beside the thread

  @backlog @mobile
  Scenario: The files browser opens full screen on a narrower window
    Given the app window is 760 wide
    When the user opens the thread's files
    Then the files browser replaces the thread

  @mobile
  Scenario: Rotating the tablet keeps the selected thread
    Given the user is reading "Fix checkout" side by side with the list
    When the user rotates the tablet to a narrow window
    Then "Fix checkout" is still shown

  @mobile
  Scenario: Resizing the window keeps the thread and what the user typed
    Given the app window is 1280 wide and 800 tall
    And the user has typed "half a thought"
    When the window narrows to a phone's width
    Then "Tax line" is still shown
    And the composer still reads "half a thought"
    When the window widens again
    Then "Tax line" is shown side by side with the list
    And the composer still reads "half a thought"

  @mobile
  Scenario: A finger scrolls the thread list beside the thread
    Given the layout is split
    And the thread list is longer than the window
    When the user drags a finger up the thread list
    Then the list scrolls

  @mobile
  Scenario: A mouse arranges the threads a finger scrolls
    Given the layout is split
    And the thread list is longer than the window
    When the user drags the mouse up the thread list
    Then the thread is picked up to be arranged

  @mobile
  Scenario Outline: A thread's menu opens beside the thread for a finger and for a mouse
    Given the layout is split
    When the user <asks> "Tax line" in the list
    Then the thread's menu opens where it was asked for

    Examples:
      | asks              |
      | holds a finger on |
      | right-clicks      |

  @mobile
  Scenario: A mouse resting on a thread offers the thread's actions
    Given the layout is split
    When the user rests the mouse on "Tax line" in the list
    Then the thread's actions are offered on its row

  @mobile
  Scenario: A tablet paired with an empty environment is walked through setting it up
    Given the environment has no projects yet
    When the user pairs a tablet with it
    Then the user is walked through setting it up

  @mobile
  Scenario: A phone paired with an empty environment says where projects are added
    Given the environment has no projects yet
    When the user pairs a phone with it
    Then the user is told projects are added on the environment's machine

  # The terminal is left out of a build with -DHAL_C2_TERMINAL=OFF (apps/mobile-qt/cmake/Terminal.cmake).
  @mobile
  Scenario: A build without the terminal offers none
    Given the app was built without the terminal
    And the layout is split
    Then the thread has no terminal to open
    And the terminal's key does nothing
    And the command palette lists no terminal command

  # The terminal wants a keyboard and room (docs/internals/mobile-qt.md); the phone layout draws none.
  @mobile
  Scenario: A phone with a keyboard has no terminal to open
    Given a hardware keyboard is attached to a phone
    And the user is in the thread "Tax line"
    Then the terminal's key does nothing

  # The Android package lets every device rotate, as Android asks of apps on large screens;
  # nothing holds a phone in portrait.
  @backlog @mobile
  Scenario Outline: Tablets rotate freely while phones stay in portrait
    Given the user is on <device>
    And the system allows auto-rotation
    When the user turns the device to landscape
    Then the app <result>

    Examples:
      | device                  | result                   |
      | an iPad                 | follows the rotation     |
      | an Android tablet       | follows the rotation     |
      | an iPhone               | stays in portrait        |
      | an Android phone        | stays in portrait        |

  @backlog @mobile
  Scenario: Unfolding a foldable unlocks rotation and folding it locks it again
    Given the user is on a folded Android foldable
    When the user unfolds it to tablet size
    Then the app follows the rotation
    When the user folds it again
    Then the app stays in portrait

  # The keys are the desktop's keymap (features/navigation/keybindings.feature), not these: a new
  # thread is Cmd-N and back is Cmd-[, but the sidebar is Cmd-B, the terminal Cmd-J, and the
  # thread's files and review have no key of their own.
  @backlog @mobile
  Scenario Outline: Hardware keyboard commands reach common actions
    Given a hardware keyboard is attached
    And the user is in a thread
    When the user presses <keys>
    Then <outcome>

    Examples:
      | keys        | outcome                                        |
      | Cmd-N       | a new task opens                               |
      | Cmd-F       | the user can search the thread list            |
      | Cmd-[       | the previous screen is shown                   |
      | Cmd-Shift-F | the thread's files open                        |
      | Cmd-Shift-T | the thread's terminal opens                    |
      | Cmd-Shift-R | the thread's review opens                      |
      | Cmd-Shift-C | the pull request link or thread id is copied   |
      | Cmd-\\      | the thread sidebar is toggled                  |

  @mobile
  Scenario: Cmd-K opens the command palette on a tablet
    Given a hardware keyboard is attached to a tablet
    When the user presses Cmd-K
    Then the command palette opens

  @mobile
  Scenario: Cmd-K searches threads on a phone
    Given a hardware keyboard is attached to a phone
    When the user presses Cmd-K
    Then the user can search the thread list

  @mobile
  Scenario: The command palette is driven by arrows and closed with Escape
    Given the command palette is open
    When the user presses Down and then Return
    Then the second entry runs
    When the user opens the palette again and presses Escape
    Then the command palette is closed

  @mobile
  Scenario: Typing a greater-than sign narrows the palette to actions
    Given the command palette is open
    When the user types ">"
    Then only actions are listed

  @mobile
  Scenario Outline: Cmd and a number jump to a thread in list order on a tablet
    Given a hardware keyboard is attached to a tablet
    And the sidebar lists "A", "B" and "C" in that order
    When the user presses Cmd-<n>
    Then "<thread>" is shown

    Examples:
      | n | thread |
      | 1 | A      |
      | 3 | C      |

  # iPadOS draws that list for an app's key commands; there is no iOS build, and Android has no such list.
  @backlog @mobile
  Scenario: Holding Cmd lists the available keyboard commands
    Given a hardware keyboard is attached to an iPad
    When the user holds Cmd
    Then the available keyboard commands are listed

  # The phone layout shows one screen at a time and the desktop's has one keymap, so no two screens share a key yet.
  @backlog @mobile
  Scenario: The screen opened last handles a keyboard command both screens use
    Given the user opened a screen over the thread that also handles Cmd-F
    When the user presses Cmd-F
    Then the screen opened last handles it
    And the thread screen does not
