# Sources:
#   apps/web/src/components/CommandPalette.tsx (add project flow)
#   apps/web/src/components/CommandPalette.logic.ts
#   Command palette entries: action:add-project, action:add-project:wsl-folder
#   apps/web/src/wslPaths.ts (WSL UNC paths mapped to the WSL environment's Linux path)
#   packages/client-runtime/src/operations/projects.ts (getCloneDirectoryName, remote source readiness)
#   apps/desktop-qt/src/native/ProjectController.cpp (Add project, Local folder)
#   apps/desktop-qt/src/native/ProjectCloneController.cpp (Git URL and repository sources, repository then destination)
#   apps/desktop-qt/src/native/CommandPaletteController.cpp (browse, ask)

Feature: Adding a project from the command palette
  The palette walks the user from an environment to a folder, a Git URL or a hosted
  repository, and reports each way the flow can fail.

  Background:
    Given the command palette is open


  @backlog @desktop
  Scenario: With no environments, adding a project goes to connections
    Given no environment is connected
    When the user runs "Add project"
    Then the connections settings open

  @backlog @desktop
  Scenario: The user chooses which environment receives the project
    Given two environments are connected and one is disconnected
    When the user runs "Add project"
    Then the palette lists "This device" and the other connected environment
    And the disconnected environment cannot be chosen

  @backlog @desktop
  Scenario: An environment that goes away mid-flow is reported
    Given the user chose an environment for a new project
    When that environment disconnects before the project is added
    Then the user is told "Environment unavailable"

  @desktop
  Scenario Outline: A project can come from several sources
    When the user adds a project from <source>
    Then the project is added to the chosen environment

    Examples:
      | source                         |
      | a local folder                 |
      | a Git URL                      |
      | a repository on GitHub         |
      | a repository on GitLab         |

  @desktop
  Scenario: A repository source that is not set up points to its settings
    Given GitLab is not connected
    When the user looks at repository sources while adding a project
    Then GitLab is marked "Setup Required"
    And choosing it opens the source control settings

  @backlog @desktop
  Scenario: Browsing starts in the home folder
    When the user adds a project from a local folder
    Then browsing starts at "~/"

  @backlog @desktop
  Scenario: A folder that does not exist yet can be created
    Given the user is browsing for a project folder
    When the user types a path that does not exist
    Then the palette says "Press Enter to create this folder and add it as a project."

  @backlog @desktop
  Scenario: Relative paths need a current project
    Given no project is active
    When the user types a relative path while adding a project
    Then the palette says "Relative paths require an active project."

  @desktop
  Scenario: Cloning asks for a repository then a destination
    When the user adds a project from a Git URL
    Then the user is asked for the repository first
    And then for the destination folder

  @desktop
  Scenario Outline: Failures while adding a project are reported
    Given adding a project will fail at <stage>
    When the user adds the project
    Then the user is told "<message>"

    Examples:
      | stage                 | message                    |
      | the clone             | Clone failed               |
      | the repository lookup | Repository lookup failed   |

    @backlog
    Examples:
      | stage                 | message                    |
      | registration          | Failed to add project      |
      | opening the project   | Failed to open project     |
      | opening the folder    | Failed to open folder      |
      | a WSL folder          | Could not add WSL project  |

  @backlog @desktop
  Scenario: mod+Enter adds the highlighted folder
    Given the user is browsing for a project folder
    And a folder is highlighted
    When the user presses mod+Enter
    Then the highlighted folder is added as a project

  @backlog @desktop
  Scenario: Windows-style paths are only understood on Windows
    Given the environment runs on Linux
    When the user types "C:\code" while adding a project
    Then the path is not treated as a drive path

  @backlog @desktop
  Scenario: Open WSL folder is offered when a WSL environment runs beside Windows
    Given the desktop app on Windows also runs the WSL environment "Ubuntu"
    When the user looks at the palette's actions
    Then "Open WSL folder" is offered for "Ubuntu"

  @backlog @desktop
  Scenario: Open WSL folder is not offered without a WSL environment
    Given the desktop app runs no WSL environment
    When the user looks at the palette's actions
    Then "Open WSL folder" is not offered

  @backlog @desktop
  Scenario: A folder chosen inside WSL is added to the WSL environment
    Given the desktop app on Windows also runs the WSL environment "Ubuntu"
    When the user runs "Open WSL folder" and chooses "\\wsl$\Ubuntu\home\sam\shop"
    Then "shop" is added to "Ubuntu" at "/home/sam/shop"

  @backlog @desktop
  Scenario: A WSL folder whose environment is not running is refused
    Given the WSL environment for "Debian" is not running
    When the user chooses a folder inside "Debian"
    Then the user is told "Could not add WSL project"
    And the user is told to start the matching WSL backend and choose the folder again

