# Sources:
#   apps/mobile/src/lib/layout.ts (split view thresholds, pane widths)
#   apps/mobile/src/features/layout/ (sidebar, inspector pane, maximize content)
#   apps/mobile/src/features/keyboard/ (hardware keyboard commands, iPad command palette)
#   apps/mobile/app.config.ts (supportsTablet)
#   apps/mobile/plugins/withAndroidTabletOrientation
# Keybinding ids and the desktop command palette are specified in features/navigation/.
# This file covers the tablet layout and hardware keyboards attached to phones and tablets.

Feature: Tablet layout and hardware keyboards
  On a wide enough screen the app shows the thread list, the thread and an inspector side
  by side. A hardware keyboard reaches the common actions without touching the screen.

  @backlog @mobile
  Scenario Outline: The layout splits only when the screen is large enough
    Given the app window is <width> wide and <height> tall
    Then the thread list and the thread are shown <arrangement>

    Examples:
      | width | height | arrangement     |
      | 1024  | 768    | side by side    |
      | 720   | 600    | side by side    |
      | 844   | 390    | one at a time   |
      | 390   | 844    | one at a time   |

  @backlog @mobile
  Scenario: An empty detail pane tells the user what to do
    Given the layout is split
    And no thread is selected
    Then the user is told to choose a thread from the sidebar or start a new task

  @backlog @mobile
  Scenario: The user hides and shows the thread sidebar
    Given the layout is split
    When the user maximizes the content
    Then the thread sidebar is hidden
    When the user shows the thread sidebar
    Then the thread sidebar is shown

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

  @backlog @mobile
  Scenario: Rotating the tablet keeps the selected thread
    Given the user is reading "Fix checkout" side by side with the list
    When the user rotates the tablet to a narrow window
    Then "Fix checkout" is still shown

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

  @backlog @mobile
  Scenario: Cmd-K opens the command palette on a tablet
    Given a hardware keyboard is attached to a tablet
    When the user presses Cmd-K
    Then the command palette opens

  @backlog @mobile
  Scenario: Cmd-K searches threads on a phone
    Given a hardware keyboard is attached to a phone
    When the user presses Cmd-K
    Then the user can search the thread list

  @backlog @mobile
  Scenario: The command palette is driven by arrows and closed with Escape
    Given the command palette is open
    When the user presses Down and then Return
    Then the second entry runs
    When the user opens the palette again and presses Escape
    Then the command palette is closed

  @backlog @mobile
  Scenario: Typing a greater-than sign narrows the palette to actions
    Given the command palette is open
    When the user types ">"
    Then only actions are listed

  @backlog @mobile
  Scenario Outline: Cmd and a number jump to a thread in list order on a tablet
    Given a hardware keyboard is attached to a tablet
    And the sidebar lists "A", "B" and "C" in that order
    When the user presses Cmd-<n>
    Then "<thread>" is shown

    Examples:
      | n | thread |
      | 1 | A      |
      | 3 | C      |

  @backlog @mobile
  Scenario: Holding Cmd lists the available keyboard commands
    Given a hardware keyboard is attached to an iPad
    When the user holds Cmd
    Then the available keyboard commands are listed

  @backlog @mobile
  Scenario: The screen opened last handles a keyboard command both screens use
    Given the user opened a screen over the thread that also handles Cmd-F
    When the user presses Cmd-F
    Then the screen opened last handles it
    And the thread screen does not
