# Sources:
#   apps/desktop-qt/src/native/ProjectController.cpp (project.add, project.folder.open, project.remove through projects.mutate)
#   apps/desktop-qt/src/ShellBridge.cpp (localFolderImportEnabled, localDirectoryPath)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (Add project)
#   apps/desktop-qt/qml/HalC2/Bricks/ProjectRemovalDialog.qml (the confirmation)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/web/src/components/CommandPalette.tsx (the add-project palette a pathless add still opens)
#   Shared domain: files/adding-projects.feature and files/removing-and-listing-projects.feature
#   own what adding and removing mean; this file owns that the Qt shell does it itself.

Feature: The desktop shell adds and removes its node's projects
  The Qt shell opens a local folder as a project and removes projects through its node's
  `projects.mutate`, without the page. Adding by typing a path or cloning is still the page's
  add-project palette.

  Background:
    Given the desktop's node "node-a" serves the environment "env-a"
    And the node has the project "p1" titled "proj-1"
    And the desktop shell is connected to its node

  @desktop
  Scenario: Adding a project without a folder opens the page's palette
    When the user asks to add a project without a folder
    Then the action "project.add" reaches the page
    And no project is created

  @desktop
  Scenario: A page that may not reach local folders opens none
    Given the shell may not open local folders
    When the user drops the folder "/home/sam/shop" on the window
    Then no project is created

  @desktop
  Scenario: Cancelling the confirmation closes it
    Given the user asks to remove "proj-1"
    When the user cancels
    Then the removal confirmation is closed
    And the node receives no commands

  @desktop
  Scenario: A confirmation for a project that goes away closes
    Given the user asks to remove "proj-1"
    When the node removes the project "p1"
    Then the removal confirmation is closed
