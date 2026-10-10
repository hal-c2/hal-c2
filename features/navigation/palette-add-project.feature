# Sources:
#   apps/web/src/components/CommandPalette.tsx (add project flow)
#   apps/web/src/components/CommandPalette.logic.ts
#   Command palette entries: action:add-project, action:add-project:wsl-folder
#   apps/web/src/wslPaths.ts (WSL UNC paths mapped to the WSL environment's Linux path)
#   apps/desktop/src/wsl/wslPathParsing.ts (where the folder chooser starts inside a distro, distro named by a UNC path)
#   apps/web/src/lib/utils.ts (getLocalFileManagerName: Finder, File Explorer, Files)
#   packages/client-runtime/src/operations/projects.ts (sortAddProjectProviderSources: ready first, then by label)
#   packages/client-runtime/src/operations/projects.ts (getCloneDirectoryName, remote source readiness)
#   apps/desktop-qt/src/native/ProjectController.cpp (Add project, Local folder, where browsing starts)
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

  @desktop
  Scenario: The user chooses which environment receives the project
    Given two environments are connected and one is disconnected
    When the user runs "Add project"
    Then the palette lists "This device" and the other connected environment
    And the disconnected environment cannot be chosen

  @desktop
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

  @desktop
  Scenario: Browsing starts in the home folder
    When the user adds a project from a local folder
    Then browsing starts at "~/"

  @desktop
  Scenario: A clone's destination starts in the add project base directory
    Given the add project base directory is "~/code"
    When the user adds a project from a Git URL
    Then the destination offered is "~/code/shop"

  @desktop
  Scenario: A folder that does not exist yet can be created
    Given the user is browsing for a project folder
    When the user types a path that does not exist
    Then the palette says "Press Enter to create this folder and add it as a project."

  @desktop
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
      | registration          | Failed to add project      |

    @backlog
    Examples:
      | stage                 | message                    |
      | opening the project   | Failed to open project     |
      | opening the folder    | Failed to open folder      |
      | a WSL folder          | Could not add WSL project  |

  @desktop
  Scenario: The folder browser names what Enter does
    Given the user is browsing for a project folder
    When the user types a folder path while adding a project
    Then the palette offers "Add" with "Enter"

  @desktop
  Scenario: A folder that does not exist is created and added
    Given the user is browsing for a project folder
    When the user types a path that does not exist
    Then the palette offers "Create & Add" with "Enter"

  @desktop
  Scenario Outline: A highlighted folder is added with mod+Enter
    Given the user is on <platform>
    And the user is browsing for a project folder
    And a folder is highlighted
    Then the palette offers "Add" with "<keys>"

    Examples:
      | platform | keys       |
      | Linux    | Ctrl+Enter |
      | macOS    | ⌘Enter     |

  @desktop
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

  @backlog @desktop
  Scenario Outline: The folder chooser is named after the host's file manager
    Given the desktop app runs on <platform>
    And the user is browsing for a project folder on this device
    When the user looks at the palette's footer
    Then it offers "Open in <name>"

    Examples:
      | platform | name          |
      | macOS    | Finder        |
      | Windows  | File Explorer |
      | Linux    | Files         |

  @backlog @desktop
  Scenario: The host's folder chooser starts in the folder being browsed
    Given the user is browsing "~/code/" for a project folder on this device
    When the user chooses to open the folder in the file manager
    Then the host's folder chooser opens at "~/code"
    And the folder it returns is added as a project

  # Legacy: apps/desktop/src/wsl/wslPathParsing.ts (resolveWslPickFolderDefaultPath), apps/desktop/src/ipc/methods/window.ts
  @backlog @desktop
  Scenario Outline: The host's folder chooser for a WSL environment starts inside the distro
    Given the user is browsing for a project folder inside the WSL environment "Ubuntu"
    And the distro's home is "/home/sam"
    When the user chooses to open the folder in the file manager from "<browsing>"
    Then the host's folder chooser opens at "<opens>"

    Examples:
      | browsing        | opens                            |
      | ~               | \\wsl.localhost\Ubuntu\home\sam  |
      | ~/shop          | \\wsl.localhost\Ubuntu\home\sam\shop |
      | /srv/work       | \\wsl.localhost\Ubuntu\srv\work  |
      | nothing typed   | \\wsl.localhost\Ubuntu\home      |

  @backlog @desktop
  Scenario: A WSL folder chooser still opens when the distro's home cannot be read
    Given the user is browsing "~/shop" inside the WSL environment "Ubuntu"
    And the distro's home cannot be read
    When the user chooses to open the folder in the file manager
    Then the host's folder chooser opens at the distro's "home" folder joined with "shop"

  @backlog @desktop
  Scenario: A folder chosen in one distro is read by that distro
    Given the desktop app runs the WSL environment "Ubuntu"
    When the user chooses the folder "\\wsl.localhost\Debian\home\sam\shop" for the environment "Debian"
    Then the folder is understood as "/home/sam/shop" by "Debian", not by "Ubuntu"

  @backlog @desktop
  Scenario: Closing the host's folder chooser leaves the palette as it was
    Given the host's folder chooser is open from the palette
    When the user closes it without choosing a folder
    Then the palette is still open
    And nothing is added

  @backlog @desktop
  Scenario: The host's folder chooser is not offered for another machine's filesystem
    Given the user is browsing for a project folder on another machine
    When the user looks at the palette's footer
    Then it does not offer the file manager

  @backlog @desktop
  Scenario: A folder chooser for a WSL environment waits until that environment is known
    Given the user is browsing for a project folder inside a WSL environment
    And the desktop app has not yet resolved that environment's backend
    When the user looks at the palette's footer
    Then it does not offer the file manager
    And no Windows folder can be added against the WSL environment by mistake

  @backlog @desktop
  Scenario Outline: The submit action says whether the folder will be created
    Given the user is <step>
    When the typed path <existence>
    Then the palette's submit action reads "<label>"

    Examples:
      | step                                | existence          | label          |
      | choosing a folder to add            | already exists     | Add            |
      | choosing a folder to add            | does not exist yet | Create & Add   |
      | choosing where to clone a repository | already exists     | Clone          |
      | choosing where to clone a repository | does not exist yet | Create & Clone |

  @backlog @desktop
  Scenario: A highlighted folder is submitted with the primary modifier
    Given the user is browsing for a project folder
    And a folder is highlighted
    When the user looks at the submit hint
    Then it reads "Cmd Enter" on macOS and "Ctrl Enter" elsewhere
    And with no folder highlighted it reads "Enter"

  @backlog @desktop
  Scenario: A clone's destination is the chosen folder with the repository's name inside
    Given the user is choosing where to clone "acme/shop"
    When the user chooses the folder "~/code"
    Then the destination becomes "~/code/shop"
    And the folder list is titled "Select where to clone"

  @backlog @desktop
  Scenario: Going up from a clone destination keeps the repository's name
    Given the clone destination is "~/code/work/shop"
    When the user goes up one folder
    Then the destination becomes "~/code/shop"

  @backlog @desktop
  Scenario: A pasted clone URL names its destination folder after the repository
    Given the user pasted "https://example.com/acme/shop.git" as the repository
    When the user reaches the destination step
    Then the destination folder is named "shop"

  @backlog @desktop
  Scenario: Add project sources list the local folder first and set up providers before the rest
    Given GitHub is set up and GitLab is not
    When the user lists the sources for a new project
    Then the order is local folder, Git URL, GitHub repository, then GitLab repository
    And the provider that is not set up is marked "Setup Required"

  @backlog @desktop
  Scenario: A repository source asks for a repository, then looks it up
    Given the user chose the Git URL source
    When the user looks at the input
    Then its action reads "Continue"
    And for a hosted repository source the action reads "Lookup"

  @backlog @desktop
  Scenario: The shortcut to copy a thread reference works from inside the palette
    Given the command palette is open
    And a thread is active
    When the user presses the shortcut to copy a thread's reference
    Then the palette closes
    And the thread's reference is copied

  @backlog @desktop
  Scenario: The shortcut to copy a thread reference does nothing without a thread
    Given the command palette is open
    And no thread is active
    When the user presses the shortcut to copy a thread's reference
    Then the palette stays open

