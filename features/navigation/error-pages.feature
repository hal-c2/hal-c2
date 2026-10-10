# Sources:
#   apps/web/src/routes/__root.tsx (RootRouteErrorView, CopyErrorButton, errorReport, RootRouteNotFoundView)
#   Cross-domain: desktop/shell-host.feature owns failures while the app starts; this file owns
#   a view that fails once the app is running.

Feature: A view that fails says so and lets the user carry on
  When part of the app fails while it is running the user is not left with a blank window.
  The failure is named, the user can try again or reload, and can copy a report to send on.

  @backlog @desktop
  Scenario: A view that fails shows what went wrong
    When the view the user is opening fails with "Cannot read thread"
    Then the window says "Something went wrong." with "Cannot read thread"
    And it offers "Try again", "Reload app" and "Copy error"

  @backlog @desktop
  Scenario: A failure without a message still says something
    When the view the user is opening fails without a message
    Then the window says "An unexpected router error occurred."

  @backlog @desktop
  Scenario: Trying again loads the view once more without restarting the app
    Given the window says "Something went wrong."
    When the user chooses "Try again" and the view now loads
    Then the view is shown and the app was not restarted

  @backlog @desktop
  Scenario: Reloading the app starts its views afresh
    Given the window says "Something went wrong."
    When the user chooses "Reload app"
    Then the app's views are loaded again from the start

  @backlog @desktop
  Scenario: The error report names the build, the place, the time and the causes
    When a view fails with an error that was caused by another error
    Then the report shown lists the app's name and version, the view that failed and the time
    And it lists the error's details followed by each cause, at most five deep

  @backlog @desktop
  Scenario: The error report leaves out anything after the view's address
    Given the user followed a link that carried a pairing token
    When the view fails
    Then the report names the view without the token

  @backlog @desktop
  Scenario: Copying the error report confirms for a moment
    Given the window says "Something went wrong."
    When the user chooses "Copy error"
    Then the whole report is on the clipboard
    And the control reads "Copied" for a moment

  @backlog @desktop
  Scenario: A link to a page that does not exist offers the way home
    When the user follows a link that does not point to a page in HAL-C2
    Then the window says "Page not found" and that the link does not point to a page in HAL-C2
    When the user chooses "Go home"
    Then the window shows home and going back does not return to the missing page
