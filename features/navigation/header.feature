# Sources:
#   apps/desktop-qt/src/native/WorkspaceController.cpp (the header and context strip from the node)
#   apps/desktop-qt/src/native/ShellStore.cpp (the thread and project rows it reads)
#   apps/desktop-qt/qml/HalC2/Bricks/Workspace.qml (the header: title, rename, editor, actions)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (the context strip: checkout, machine, branch)
#   apps/web/src/hooks/useRenameThread.ts
#   apps/web/src/components/BranchToolbar.logic.ts (mode, branch and machine rules)
#   apps/desktop-qt/src/ShellBridge.cpp (openExternal: the system browser)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   navigation/layout.feature owns the header's place in the window; threads/titles.feature,
#   source-control/refs-and-branches.feature and files/project-scripts-and-actions.feature own
#   what its controls do.

Feature: The thread's header on the desktop
  The header over a thread and the strip under its composer come from the node: the thread and
  its project are the node's rows, the branch its checkout's status, the editors its machine's.
  A thread on a linked environment has its header too.

  Background:
    Given a connected environment with a thread in the git project "shop" on the branch "feature/tax"

  @desktop
  Scenario: The header opens the checkout's pull request in the browser
    Given the checkout's pull request is "https://github.com/acme/shop/pull/7"
    When the user opens the pull request from the header
    Then the browser opens "https://github.com/acme/shop/pull/7"

  @desktop
  Scenario: Leaving the thread clears the header
    When the user leaves the thread
    Then the header shows no thread

  @desktop
  Scenario: Opening the thread without picking uses the first editor the machine has
    Given the environment has the editors "VS Code" and "Zed"
    When the user opens the thread in their editor
    Then "VS Code" opens "/work/shop"

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
