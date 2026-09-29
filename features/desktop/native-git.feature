# Sources:
#   apps/desktop-qt/src/native/GitController.cpp (the header's git actions, their toasts and dialogs)
#   apps/desktop-qt/src/native/ToastController.cpp (the progress toast updated in place)
#   apps/desktop-qt/qml/HalC2/Bricks/GitActions.qml (the git pill, its menu and the publish dialog)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/server-ex/lib/hal_c2/git_actions.ex (gitAction events and result toasts)
#   apps/server-ex/lib/hal_c2/vcs.ex (vcs.pull, vcs.init)
#   apps/server-ex/lib/hal_c2/source_control.ex (sourceControl.publishRepository)
#   apps/server-ex/lib/hal_c2/links.ex (a linked environment's requests, and the error while its link is down)
#   Shared domain: source-control/git-actions.feature, push-pull-and-default-branch.feature and
#   commit-and-generated-messages.feature own what the actions do; this file owns that the Qt
#   shell runs them itself and reports each outcome.

Feature: The desktop shell runs the thread's git actions itself
  The header's git actions go to the node from the shell. A running action shows what it is
  doing, every failure is reported, and each result offers the next step.

  Background:
    Given a connected environment with a thread in the git project "shop" with the remote "origin"
    And the user has changed "src/cart.ts" and "src/tax.ts"

  Rule: A running action shows what it is doing

    @desktop
    Scenario: The progress toast names the stage and the hook's last line
      Given the pre-commit hook prints "lint ok" and waits
      When the user starts committing with the message "Add tax"
      Then the user sees a "loading" toast "Committing..." saying "lint ok"
      When the hook finishes
      Then the toast "Committing..." is gone
      And the user sees a "success" toast "Committed abc0001" saying "Add tax"

    @desktop
    Scenario: A failed action is reported
      Given the node fails the action with "pre-commit hook failed"
      When the user starts committing with the message "Add tax"
      Then the user sees an "error" toast "Action failed" saying "pre-commit hook failed"

  Rule: Each result offers the next step

    @desktop
    Scenario: A commit offers to push it
      When the user commits with the message "Add tax"
      And the user chooses "Push" on the toast "Committed abc0001"
      Then the node is asked to push

    @desktop
    Scenario: A new pull request can be viewed from its result
      Given the checkout has uncommitted changes on a feature branch with a remote
      When the user runs the recommended action
      And the user chooses "View PR" on the toast "Created PR #42"
      Then the browser opens "https://github.com/acme/shop/pull/42"

    @desktop
    Scenario: An action with nothing to do says why
      Given the checkout is up to date with nothing to do
      When the user runs the recommended action
      Then the user sees an "info" toast "Commit" saying "Branch is up to date. No action needed."

  Rule: Pulling

    @desktop
    Scenario: A refused pull is reported
      Given "feature/tax" is 2 commits behind its upstream and has no local commits
      And the node refuses to pull with "Cannot fast-forward."
      When the user pulls
      Then the user sees an "error" toast "Pull failed" saying "Cannot fast-forward."

  Rule: A folder that is not a repository

    @desktop
    Scenario: Initializing Git
      Given the checkout is not a repository
      And the git actions offer to initialize Git
      When the user initializes Git
      Then the checkout is a repository

    @desktop
    Scenario: A refused initialization is reported
      Given the checkout is not a repository
      And the node refuses to initialize Git with "Permission denied"
      When the user initializes Git
      Then the user sees an "error" toast "Git initialization failed" saying "Permission denied"

  Rule: Publishing a repository without a remote

    Background:
      Given the checkout has commits and no remote

    @desktop
    Scenario: Publishing pushes the branch to the new repository
      When the user runs the recommended action
      Then the publish dialog is open
      When the user publishes "acme/shop" as a private GitHub repository
      Then the node published "acme/shop" to "origin" as private on github
      And the publish dialog is closed
      And the user sees a "success" toast "Published acme/shop" saying "Pushed feature/tax to origin."
      When the user chooses "Open repository" on the toast "Published acme/shop"
      Then the browser opens "https://github.com/acme/shop"

    @desktop
    Scenario: A refused publish keeps the dialog open with the reason
      Given the node refuses to publish with "Repository already exists"
      When the user runs the recommended action
      And the user publishes "acme/shop" as a public GitHub repository
      Then the publish dialog says "Repository already exists"

    @desktop
    Scenario: A repository name needs its owner
      When the user runs the recommended action
      And the user publishes "shop" as a private GitHub repository
      Then the publish dialog says "Name the repository as owner/name."
      And nothing is published

    @desktop
    Scenario: Cancelling the dialog publishes nothing
      When the user runs the recommended action
      And the user cancels publishing
      Then the publish dialog is closed
      And nothing is published

  Rule: Threads the node reaches through a link

    @desktop
    Scenario: A git action on a linked environment runs through the link
      Given the node is linked to "env-c"
      And "env-c" has the thread "t7" titled "Deploy" in "shop" on the branch "feature/tax"
      When the user goes to "env-c:t7"
      And the user commits with the message "Add tax"
      Then the action ran on "env-c"
      And a commit "Add tax" holds both files

    @desktop
    Scenario: A link that is down says why its git actions cannot run
      Given the node is linked to "env-c"
      And "env-c" has the thread "t7" titled "Deploy" in "shop" on the branch "feature/tax"
      And "env-c" becomes unreachable
      When the user goes to "env-c:t7"
      Then the git actions say "env-c cannot be reached."
      When "env-c" is reachable again
      Then the git actions are available again
