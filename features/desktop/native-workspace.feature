# Sources:
#   apps/desktop-qt/src/native/WorkspaceController.cpp (the header and context strip from the node)
#   apps/desktop-qt/src/native/ShellStore.cpp (the thread and project rows it reads)
#   apps/desktop-qt/qml/HalC2/Bricks/Workspace.qml (the header: title, rename, editor, actions)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (the context strip: checkout, machine, branch)
#   apps/web/src/hooks/useThreadBranchSelection.ts (the switch and create flow this ports)
#   apps/web/src/hooks/useRenameThread.ts
#   apps/web/src/components/BranchToolbar.logic.ts (mode, branch and machine rules)
#   apps/web/src/shell/shellRenameRequest.ts (rename from the page's thread menu)
#   apps/desktop-qt/src/ShellBridge.cpp (openExternal: the system browser)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   Shared domain: threads/titles.feature, source-control/refs-and-branches.feature,
#   source-control/worktrees-and-setup-scripts.feature and files/project-scripts-and-actions.feature
#   own what these do; this file owns that the Qt shell does them against its node.

Feature: The desktop shell runs the workspace header against its node
  The header over a thread and the strip under its composer come from the node: the thread and
  its project are the node's rows, the branch its checkout's status, the editors its machine's.
  The shell renames, switches and creates branches, opens editors, runs actions, starts new
  threads and opens the checkout's pull request itself.

  Background:
    Given a connected environment with a thread in the git project "shop" on the branch "feature/tax"

  @desktop
  Scenario: The header's new thread button opens a draft in the thread's project
    When the user starts a new thread from the header
    Then the window shows a new draft in "shop"

  @desktop
  Scenario: The header opens the checkout's pull request in the browser
    Given the checkout's pull request is "https://github.com/acme/shop/pull/7"
    When the user opens the pull request from the header
    Then the browser opens "https://github.com/acme/shop/pull/7"

  @desktop
  Scenario: The header shows the route's thread from the node
    Then the header shows the thread "Tax line" in "shop" on "feature/tax"

  @desktop
  Scenario: Leaving the thread clears the header
    When the user leaves the thread
    Then the header shows no thread

  @desktop
  Scenario: Opening the thread in an editor the user picks
    Given the environment has the editors "VS Code" and "Zed"
    When the user opens the thread in "Zed"
    Then "Zed" opens "/work/shop"
    And "Zed" is the editor offered first

  @desktop
  Scenario: Opening the thread without picking uses the first editor the machine has
    Given the environment has the editors "VS Code" and "Zed"
    When the user opens the thread in their editor
    Then "VS Code" opens "/work/shop"

  @desktop
  Scenario: A switch that fails keeps the branch and says why
    Given the node cannot switch the checkout: "Your local changes would be overwritten"
    When the user switches the thread to "main"
    Then the user sees an "error" toast "Failed to switch ref." saying "Your local changes would be overwritten"
    And the checkout is on "feature/tax"
    And the thread's branch reads "feature/tax"

  @desktop
  Scenario: Renaming from the thread list starts editing the title in the header
    Given the node has the thread "t2" titled "Cart totals" in "shop"
    When the user picks Rename for "env-a:t2" in the thread list
    And the user goes to "env-a:t2"
    Then the header starts editing the title of "env-a:t2"

  @desktop
  Scenario: A new thread can run on another machine's checkout of the project
    Given the node is clustered with "node-b", which serves "env-b"
    And "env-b" has a checkout of "shop" at "/srv/shop"
    And the user is writing the first message of a new thread in "shop"
    Then "env-b" is offered to run the new thread on
    When the user runs the new thread on "env-b"
    Then the new thread will start on "env-b" in "/srv/shop"
    When the user runs the new thread on "env-a"
    Then the new thread will start on "env-a" in "/work/shop"

  @desktop
  Scenario: A thread on an environment the node is linked to has its header
    Given the node is linked to "env-c"
    And "env-c" has the thread "t7" titled "Deploy" in "ops" on the branch "main"
    When the user goes to "env-c:t7"
    Then the header shows the thread "Deploy" in "ops" on "main"

  @desktop
  Scenario: A linked thread's header lists its environment's editors
    Given the node is linked to "env-c"
    And "env-c" has the editors "VS Code" and "Zed"
    And "env-c" has the thread "t7" titled "Deploy" in "ops" on the branch "main"
    When the user goes to "env-c:t7"
    Then the header lists the editors "VS Code" and "Zed"

  @desktop
  Scenario: A linked thread's header says so while its environment is unreachable
    Given the node is linked to "env-c"
    And "env-c" has the thread "t7" titled "Deploy" in "ops" on the branch "main"
    And the user goes to "env-c:t7"
    When "env-c" becomes unreachable
    Then the header says the thread is offline
    And the header shows the thread "Deploy" in "ops" on "main"
    When "env-c" is reachable again
    Then the header no longer says the thread is offline
