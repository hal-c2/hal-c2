# Sources:
#   apps/mobile/src/lib/layout.ts (split view thresholds, pane widths)
#   apps/mobile/src/features/layout/ (sidebar, inspector pane, maximize content)
#   apps/mobile/src/lib/useHoverGesture.ts, components/RowPressable.tsx (hover highlight for mouse and stylus)
#   apps/mobile/src/features/threads/useThreadHeaderOptions.tsx (new task from the thread's header in a split layout)
#   apps/mobile/src/features/keyboard/ (hardware keyboard commands, iPad command palette)
#   apps/mobile/app.config.ts (supportsTablet)
#   apps/mobile/plugins/withAndroidTabletOrientation
#   apps/mobile/modules/hal-c2-composer-editor/ios/HalC2ComposerEditorView.swift (send keys named in the Cmd-hold list)
#   apps/mobile-qt/qml/HalC2/Mobile/MobileShell.qml (the desktop's layout from 736 by 480, the phone's below)
#   docs/internals/mobile-qt.md (one root, two layouts)
#   apps/mobile/src/lib/adaptive-navigation.ts, layout.ts (thread and file selection beside the list, sidebar and inspector widths, reading width)
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

  @backlog @mobile
  Scenario: The thread's header starts a new task beside the thread
    Given the layout is split
    And the user is reading "Fix checkout"
    When the user chooses to start a new task from the thread's header
    Then the new task opens

  @backlog @mobile
  Scenario: The thread sidebar cannot be hidden on the home screen
    Given the layout is split
    And the user is on the home screen
    Then the thread sidebar is shown
    When the user presses Cmd-\\
    Then the thread sidebar is still shown

  @backlog @mobile
  Scenario: Searching the threads shows a hidden sidebar
    Given the layout is split
    And the user maximized the content so the thread sidebar is hidden
    When the user presses Cmd-F
    Then the thread sidebar is shown
    And the user can search the thread list

  @backlog @mobile
  Scenario: A tablet with no environment connected offers to add one
    Given the layout is split
    And no environment is paired
    Then the detail pane says no environments are connected
    And the user is offered to add an environment

  @backlog @mobile
  Scenario: Choosing the thread already shown does nothing
    Given the layout is split
    And the user is reading "Fix checkout"
    When the user chooses "Fix checkout" in the thread list
    Then "Fix checkout" is still shown
    And going back does not stay on "Fix checkout"

  @backlog @mobile
  Scenario: Choosing another thread closes the thread's files pane
    Given the layout is split and the thread's files are shown beside "Fix checkout"
    When the user chooses "Add search" in the thread list
    Then "Add search" is shown
    And the files pane is not shown beside it

  @backlog @mobile
  Scenario: The files pane and the thread's other side pane keep their own widths
    Given the layout is split
    And the user made the thread's files pane wider
    When the thread's other side pane is shown
    Then it has the width it had before the files pane was widened

  @backlog @mobile
  Scenario: A screen reader can widen and narrow the side pane
    Given the layout shows an inspector pane
    And a screen reader is on
    When the screen reader user adjusts the pane's divider up
    Then the pane becomes wider by a small step
    When the screen reader user adjusts the pane's divider down
    Then the pane becomes narrower by a small step
    And the divider tells the screen reader how wide the pane is

  @backlog @mobile
  Scenario: Panes open and close without sliding when the system asks for reduced motion
    Given the user turned on reduced motion
    And the layout is split
    When the user hides and shows the thread sidebar and the inspector
    Then the panes appear and disappear without animating

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

  @mobile
  Scenario: A project action on a phone says why it does not run
    Given a hardware keyboard is attached to a phone
    And the user is in the thread "Tax line"
    When the user asks for a project action
    Then the user is told a screen this small has no terminal for it

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

  @backlog @mobile
  Scenario: Cmd and a number past the end of the list does nothing
    Given a hardware keyboard is attached to a tablet
    And the sidebar lists "A", "B" and "C" in that order
    And "A" is shown
    When the user presses Cmd-7
    Then "A" is still shown

  @backlog @mobile
  Scenario: Cmd and a number follows the list as the user sees it
    Given a hardware keyboard is attached to a tablet
    And the sidebar lists "A", "B" and "C" in that order
    And the user has narrowed the list to "B" and "C"
    When the user presses Cmd-1
    Then "B" is shown

  @backlog @mobile
  Scenario: Cmd and a number counts threads and not the headings between them
    Given a hardware keyboard is attached to a tablet
    And the sidebar lists a heading, then "A", then another heading, then "B"
    When the user presses Cmd-2
    Then "B" is shown

  @backlog @mobile
  Scenario Outline: Thread commands do nothing away from the thread list and a thread
    Given a hardware keyboard is attached
    And the user is on the settings screen
    When the user presses <keys>
    Then the settings screen is still shown

    Examples:
      | keys        |
      | Cmd-1       |
      | Cmd-Shift-F |
      | Cmd-Shift-T |
      | Cmd-Shift-R |
      | Cmd-Shift-C |

  @backlog @mobile
  Scenario Outline: A key for a screen that is already shown does nothing
    Given a hardware keyboard is attached
    And the user is looking at the thread's <screen>
    When the user presses <keys>
    Then the thread's <screen> is still shown
    And no second copy of it is opened

    Examples:
      | screen   | keys        |
      | files    | Cmd-Shift-F |
      | terminal | Cmd-Shift-T |
      | review   | Cmd-Shift-R |

  @backlog @mobile
  Scenario: Back does nothing on the home screen when there is nowhere to go
    Given a hardware keyboard is attached
    And the user is on the home screen and has opened nothing before it
    When the user presses Cmd-[
    Then the home screen is still shown

  @backlog @mobile
  Scenario: Copying a reference says what was copied
    Given a hardware keyboard is attached
    And the user is in a thread with an open pull request
    When the user presses Cmd-Shift-C
    Then the user is told the pull request link was copied and sees the link
    And the confirmation goes away by itself after three seconds

  @backlog @mobile
  Scenario: A reference that could not be copied says to try again
    Given a hardware keyboard is attached
    And the user is in a thread
    And the phone does not let the app write to the clipboard
    When the user presses Cmd-Shift-C
    Then the user is told the reference could not be copied and to try again

  @backlog @mobile
  Scenario: Copying a reference is not offered while the terminal is shown
    Given a hardware keyboard is attached
    And the user is looking at the thread's terminal
    When the user presses Cmd-Shift-C
    Then nothing is copied
    And the terminal receives the key

  @backlog @mobile
  Scenario: Arrow keys in the command palette wrap around at the ends
    Given the command palette is open
    When the user presses Up on the first entry
    Then the last entry is highlighted
    When the user presses Down on the last entry
    Then the first entry is highlighted

  @backlog @mobile
  Scenario: Thread actions are in the command palette only inside a thread
    Given a hardware keyboard is attached to a tablet
    When the user opens the command palette from the home screen
    Then it lists no action for a thread's files, terminal, review or pull request link
    When the user opens a thread and opens the command palette
    Then it lists an action for the thread's files, terminal, review and pull request link or thread id

  # iPadOS draws that list for an app's key commands; there is no iOS build, and Android has no such list.
  @backlog @mobile
  Scenario: Holding Cmd lists the available keyboard commands
    Given a hardware keyboard is attached to an iPad
    When the user holds Cmd
    Then the available keyboard commands are listed

  @backlog @mobile
  Scenario Outline: The keyboard command list names what the send keys will do now
    Given a hardware keyboard is attached to an iPad
    And the agent is working and the follow-up setting is <setting>
    When the user holds Cmd in the composer
    Then the list names the send keys "<entry>"
    And a plain Return and Shift-Return are listed according to the Return key setting

    Examples:
      | setting | entry         |
      | queue   | Queue Message |
      | steer   | Steer Message |

  @backlog @mobile
  Scenario: The command list offers no send keys while the composer cannot send
    Given a hardware keyboard is attached to an iPad
    And the composer is read only or the user is still composing a word
    When the user holds Cmd in the composer
    Then no send or new line keys are listed

  # The phone layout shows one screen at a time and the desktop's has one keymap, so no two screens share a key yet.
  @backlog @mobile
  Scenario: The screen opened last handles a keyboard command both screens use
    Given the user opened a screen over the thread that also handles Cmd-F
    When the user presses Cmd-F
    Then the screen opened last handles it
    And the thread screen does not

  @backlog @mobile
  Scenario: Choosing another thread beside the list swaps the thread without stacking screens
    Given the layout is split
    And the user is reading "Fix checkout"
    When the user chooses "Add search" in the thread list
    Then "Add search" is shown beside the list
    When the user goes back
    Then the user does not return to "Fix checkout"

  @backlog @mobile
  Scenario: Choosing a thread from the home screen keeps the home screen under it
    Given the layout is split and the user is on the home screen
    When the user chooses "Fix checkout" in the thread list
    Then "Fix checkout" is shown
    When the user narrows the window until the layout is one at a time
    And the user goes back
    Then the home screen is shown

  @backlog @mobile
  Scenario: Choosing a thread while a sheet is open closes the sheet
    Given the layout is split and a sheet is open over the thread
    When the user chooses another thread in the thread list
    Then the sheet closes
    And the chosen thread is shown beside the list

  @backlog @mobile
  Scenario: Choosing a file beside the thread leaves one step back to the thread
    Given the app window is 1024 wide and the files browser is beside the thread
    When the user chooses "src/cart.ts" and then "src/cart.test.ts"
    Then "src/cart.test.ts" is shown
    When the user goes back
    Then the thread is shown

  @backlog @mobile
  Scenario: The sidebar steps aside when the inspector would leave the thread too narrow
    Given the app window is wide enough for the inspector but not for the list, the thread and the inspector together
    When the user shows the inspector
    Then the thread list is hidden
    And the thread and the inspector are shown
    When the user hides the inspector
    Then the thread list is shown again

  @backlog @mobile
  Scenario: Reading text in a thread stays a comfortable width on a wide window
    Given the app window is wider than the thread's reading width
    When the user reads a thread
    Then the thread's text is centred
    And its lines do not stretch across the whole window

  @backlog @mobile
  Scenario Outline: A row under a mouse or stylus is highlighted and one under a finger is not
    When the user rests <pointer> on a row of a list
    Then the row <effect>

    Examples:
      | pointer    | effect                |
      | a mouse    | is highlighted        |
      | a stylus   | is highlighted        |
      | a finger   | is not highlighted    |

  @backlog @mobile
  Scenario: Hovering a row does not get in the way of tapping or scrolling it
    Given a mouse rests on a row of a list
    When the user taps the row
    Then the row opens
    When the user scrolls the list
    Then the list scrolls
