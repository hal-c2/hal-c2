# Sources:
#   apps/desktop-qt/src/native/ProjectController.cpp (project.add, project.folder.open, project.remove through projects.mutate)
#   apps/desktop-qt/src/ShellBridge.cpp (localFolderImportEnabled, localFolders from the node's origin, localDirectoryPath)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (Add project)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)
#   apps/desktop-qt/src/native/CommandPaletteController.cpp (Add project, a pathless add opens it)
#   Shared domain: files/adding-projects.feature and files/removing-and-listing-projects.feature
#   own what adding and removing mean, including the removal confirmation.

Feature: The desktop shell adds and removes its node's projects
  The Qt shell opens a local folder as a project and removes projects through its node's
  `projects.mutate`, without the page. Adding by typing a path is the command palette's
  Add project; cloning is not native yet.

  Background:
    Given the desktop's node "node-a" serves the environment "env-a"
    And the node has the project "p1" titled "proj-1"
    And the desktop shell is connected to its node

  @desktop
  Scenario: Adding a project without a folder opens the palette's Add project
    When the user asks to add a project without a folder
    Then the command palette asks where the project comes from
    And no project is created

  @desktop
  Scenario: A page that may not reach local folders opens none
    Given the shell may not open local folders
    When the user drops the folder "/home/sam/shop" on the window
    Then no project is created

  @desktop
  Scenario: A node on another machine opens no local folders
    Given the shell's node runs on another machine
    When the user drops the folder "/home/sam/shop" on the window
    Then no project is created
