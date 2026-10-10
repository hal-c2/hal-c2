# Sources:
#   apps/web/src/components/ConfirmDialogHost.tsx (the question and detail, Cancel and Confirm, closing)
#   apps/web/src/confirmDialog.ts (one at a time, declined when the host goes away)
#   apps/web/src/components/ui/alert-dialog.tsx (a confirmation is not dismissed by a click outside it)
#   apps/web/src/components/ui/dialog.tsx, sheet.tsx (close button, Escape, click outside)
#   apps/web/src/components/ui/menu.tsx, select.tsx, combobox.tsx, popover.tsx (@base-ui/react: Escape,
#     outside press, arrow keys that wrap, type-ahead, focus back on the trigger)
#   Shared domain: navigation/windows.feature owns the context menus the shell draws itself;
#   navigation/command-palette.feature owns the palette's own keys.

Feature: Menus, pickers and confirmations
  A menu, picker or popover closes when the user asks it to and gives focus back to what
  opened it. A confirmation is stricter: it is only answered with its own buttons or Escape,
  so a stray click never confirms or cancels a destructive action.

  Rule: Confirmations

    # The message is split at its first question: the question is the title and the rest of
    # the message is the detail. A message with no question is titled "Confirm action".
    @backlog @desktop
    Scenario: A confirmation shows its question as the title and the rest as the detail
      When the app asks "Delete this thread?" with the detail "Its history cannot be restored."
      Then the confirmation is titled "Delete this thread?"
      And it explains "Its history cannot be restored."
      And it offers Cancel and Confirm

    @backlog @desktop
    Scenario: A confirmation without a question is titled "Confirm action"
      When the app asks "Overwrite the saved layout"
      Then the confirmation is titled "Confirm action"
      And it explains "Overwrite the saved layout"

    @backlog @desktop
    Scenario Outline: A confirmation is declined with Cancel or Escape
      Given the app asked the user to confirm a destructive action
      When the user <declines>
      Then the action is not done
      And the confirmation closes

      Examples:
        | declines                  |
        | chooses Cancel            |
        | presses Escape            |

    @backlog @desktop
    Scenario: A click outside a confirmation does not answer it
      Given the app asked the user to confirm a destructive action
      When the user clicks outside the confirmation
      Then the confirmation stays open
      And the action is neither confirmed nor declined

    @backlog @desktop
    Scenario: A destructive confirmation marks its Confirm as destructive
      When the app asks the user to confirm a destructive action
      Then Confirm is shown in the destructive style
      When the app asks the user to confirm an ordinary action
      Then Confirm is shown in the ordinary style

    @backlog @desktop
    Scenario: Confirmations asked together are answered one at a time in order
      Given the app asked "Archive Fix login?" and then "Delete Add tests?"
      Then only "Archive Fix login?" is shown
      When the user chooses Confirm
      Then "Archive Fix login?" is confirmed
      And "Delete Add tests?" is shown next, not yet answered

    @backlog @desktop
    Scenario: A confirmation still waiting when the window closes is declined
      Given the app asked the user to confirm a destructive action
      When the window closes before the user answers
      Then the action is declined and never done

  Rule: Menus and pickers

    @backlog @desktop
    Scenario Outline: A menu closes without choosing anything
      Given a menu is open
      When the user <closes it>
      Then the menu closes
      And no entry is chosen
      And focus returns to what opened the menu

      Examples:
        | closes it                 |
        | presses Escape            |
        | clicks outside the menu   |

    @backlog @desktop
    Scenario: The arrow keys move through a menu and wrap at its ends
      Given a menu with the entries "Rename", "Pin" and "Delete" is open
      When the user presses the down arrow past "Delete"
      Then "Rename" is highlighted
      When the user presses the up arrow
      Then "Delete" is highlighted

    @backlog @desktop
    Scenario: Typing the start of an entry's name highlights it
      Given a menu with the entries "Rename", "Pin" and "Delete" is open
      When the user types "pi"
      Then "Pin" is highlighted
      And pressing Enter chooses "Pin"

    @backlog @desktop
    Scenario Outline: A dialog that is not a confirmation closes without a choice
      Given a dialog is open
      When the user <closes it>
      Then the dialog closes

      Examples:
        | closes it                        |
        | presses Escape                   |
        | chooses its close button         |
        | clicks outside the dialog        |
