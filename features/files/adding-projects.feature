# Sources:
#   docs/user/project-settings.md
#   apps/server-ex/lib/hal_c2/projects.ex (project.create, browse)
#   apps/server-ex/lib/hal_c2/project_clones.ex (projectClone.start, retry, cancel, progress)
#   apps/server-ex/lib/hal_c2/source_control.ex (lookup, remote, clone)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (projectClones stream)
#   apps/web/src/components/CommandPalette.tsx (Add project, Local folder, clone flow)
#   apps/web/src/components/NoProjectsHero.tsx
#   apps/web/src/components/ProjectCloneToastCoordinator.tsx
#   apps/web/src/shell/useShellFolderDrop.ts
#   apps/desktop-qt/qml/HalC2/Bricks/ProjectFolderDrop.qml
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (Add project)
#   apps/desktop-qt/src/ShellBridge.cpp (project.folder.open, localDirectoryPath)
#   apps/desktop-qt/src/native/ProjectController.cpp (opens a local folder through projects.mutate)
#   apps/tui/src/components/AddProjectOverlay.tsx
#   apps/tui/src/components/ChatView.tsx (add project flow)
#   apps/mobile/src/features/projects/AddProjectScreen.tsx
#   packages/client-runtime/src/operations/projects.ts (resolveAddProjectPath, remote source readiness)
#   packages/contracts/src/project.ts (ProjectMutation project.create)
#   packages/contracts/src/projectClone.ts
#   packages/contracts/src/filesystem.ts (filesystem.browse)
#   packages/contracts/src/rpc.ts (projects.mutate, filesystem.browse, projectClone.start, projectClone.retry, projectClone.cancel, subscribeProjectClones, sourceControl.lookupRepository, sourceControl.cloneRepository;
#     projects.add is an unrouted name, dropped in parity/rpc.feature)

Feature: Adding projects
  A project is a folder on an environment. The user adds one by picking a folder on that
  machine, dropping a folder on the desktop app, or cloning a repository into a new folder.
  Adding never moves or deletes files.

  Background:
    Given a connected environment "laptop"

  Rule: Adding a local folder

    # Delivered natively (Sidebar's empty list, ThreadView's "Add a project to start"); no desktop test yet.
    @desktop @tui @backlog-desktop
    Scenario: A user with no projects is invited to add one
      Given "laptop" has no projects
      When the user opens the app
      Then the user is asked what they should work on
      And the user is offered to add a project

    @backlog @mobile
    Scenario: A phone user with no projects is invited to add one
      Given "laptop" has no projects
      When the user opens the app on a phone
      Then the user is offered to add a project

    @tui
    Scenario: Adding a folder registers it and starts a thread there
      Given the folder "/home/sam/shop" exists on "laptop"
      When the user adds the local folder "/home/sam/shop"
      Then the project "shop" is listed for "laptop"
      And a draft thread opens in "shop"

    @desktop @mobile @backlog-mobile
    Scenario: Adding a folder from the desktop and mobile apps registers it and starts a thread
      Given the folder "/home/sam/shop" exists on "laptop"
      When the user adds the local folder "/home/sam/shop"
      Then the project "shop" is listed for "laptop"
      And a draft thread opens in "shop"

    @desktop @mobile @backlog-mobile
    Scenario: A folder the environment refuses to add says why
      Given the folder "/home/sam/shop" exists on "laptop"
      And the environment refuses to change projects with "Disk is read-only"
      When the user adds the local folder "/home/sam/shop"
      Then the user sees an "error" toast "Could not open folder" saying "Disk is read-only"
      And the desktop keeps 0 drafts

    @node
    Scenario: A new project is titled after its folder
      When a client creates a project at "~/code/shop" without a title
      Then the project is titled "shop"
      And its workspace folder is the expanded home path ending in "code/shop"

    @tui
    Scenario: Browsing for a folder lists only the folders under the typed path
      Given "/home/sam" holds the folders "shop" and "Shared" and the file "notes.txt"
      When the user types "/home/sam/sh" while adding a local folder
      Then the folders "Shared" and "shop" are offered
      And "notes.txt" is not offered

    @node
    Scenario Outline: Browsing shows hidden folders only when asked for
      Given "/home/sam" holds the folders "shop" and ".config"
      When a client browses "<partial path>"
      Then ".config" <shown>

      Examples:
        | partial path | shown           |
        | /home/sam/   | is listed       |
        | /home/sam/.c | is listed       |
        | /home/sam/s  | is not listed   |

    @node
    Scenario: Browsing a folder the user cannot read lists nothing
      Given "/root" cannot be read by the node
      When a client browses "/root/"
      Then an empty list is returned without an error

    @tui
    Scenario: Adding a folder that is already a project opens it instead
      Given "shop" is already a project on "laptop"
      When the user adds the local folder of "shop" again
      Then no second project is created
      And the user is told the project was already added

    @desktop @mobile @backlog-mobile
    Scenario: Adding an existing project from the desktop and mobile apps opens its latest thread
      Given "shop" is already a project on "laptop" with an unsettled thread "Fix checkout"
      When the user adds the local folder of "shop" again
      Then no second project is created
      And the thread "Fix checkout" opens

    @node
    Scenario: A folder that does not exist is refused unless the client asks to create it
      When a client creates a project at "/home/sam/missing" without asking to create the folder
      Then the node answers that "/home/sam/missing" does not exist on this machine
      And no project is created

    @node
    Scenario: A folder is created for a new project when the client asks for it
      When a client creates a project at "/home/sam/fresh" and asks to create the folder
      Then the folder "/home/sam/fresh" exists
      And the project "fresh" is listed for "laptop"

    @tui
    Scenario Outline: A project path the environment cannot use is refused before anything is sent
      Given "laptop" runs <platform>
      When the user adds the local folder "<path>"
      Then the user is told "<message>"

      Examples:
        | platform                        | path          | message                                                           |
        | Linux                           | C:\code\shop  | Windows-style paths are only supported on Windows environments.  |
        | Linux with no active project    | ./shop        | Relative paths require an active project in this environment.    |
        | Linux                           |               | Enter a project path.                                             |

    @dropped @node
    Scenario: The standalone project list, add and remove methods are not carried
      When a client calls the projects list, add or remove method
      Then the node answers that the method is not served
      And projects are listed from the shell stream and changed through project mutations

  Rule: Dropping a folder on the desktop app

    @desktop @backlog-desktop
    Scenario: Dragging a single local folder over the window offers to open it as a project
      Given the desktop app is connected to its own local environment
      When the user drags the folder "/home/sam/shop" over the window
      Then the user is told the folder opens as a project
      And the user is told no files will be moved or deleted

    @desktop @backlog-desktop
    Scenario Outline: Drops that are not a single local folder are refused
      Given the desktop app is connected to its own local environment
      When the user drags <items> over the window
      Then the drop is refused

      Examples:
        | items                       |
        | a file                      |
        | two folders                 |
        | a link to a remote location |

    @desktop @backlog-desktop
    Scenario: Folder drops are refused when the app shows a remote environment
      Given the desktop app shows an environment on another machine
      When the user drags a local folder over the window
      Then the drop is refused

    @desktop
    Scenario: Dropping a folder adds it as a project and starts a thread
      Given the desktop app is connected to its own local environment
      When the user drops the folder "/home/sam/shop" on the window
      Then the project "shop" is listed for "laptop"
      And a draft thread opens in "shop"

    @desktop
    Scenario: Dropping a folder while the environment is disconnected reports a failure
      Given the local environment is disconnected
      When the user drops the folder "/home/sam/shop" on the window
      Then the user is told the folder could not be opened
      And no project is created

  Rule: Cloning a repository into a new project

    @node
    Scenario: Starting a clone adds the project at once and clones in the background
      When a client starts cloning "https://example.com/acme/shop.git" into "/home/sam/shop"
      Then the project "shop" is listed for "laptop" immediately
      And the clone is reported as running at the "connecting" stage

    @node
    Scenario Outline: Clone progress follows git's own stages
      Given a clone of "acme/shop" is running
      When git reports "<git line>"
      Then the clone is at the "<stage>" stage with <percent> percent done

      Examples:
        | git line                              | stage     | percent |
        | remote: Counting objects:  40% (4/10) | counting  | 40      |
        | Receiving objects:  45% (45/100)      | receiving | 45      |
        | Resolving deltas: 100% (3/3), done.   | resolving | 100     |
        | Updating files:  80% (8/10)           | checkout  | 80      |

    @backlog @desktop @mobile
    Scenario: Clone progress is shown while the user keeps working
      Given a clone of "acme/shop" is receiving objects at 45 percent
      When the user looks at the app
      Then the user sees "Cloning acme/shop" with "Receiving objects · 45%"
      And the user can cancel the clone

    @node
    Scenario: A finished clone is forgotten after a short while
      Given a clone of "acme/shop" finished
      When half a minute passes
      Then the clone is no longer reported
      And the project "shop" stays with its files

    @backlog @desktop @mobile
    Scenario: A finished clone offers to open its project
      Given a clone of "acme/shop" finished
      When the user looks at the app
      Then the user sees "Cloned acme/shop" with its destination folder
      And the user can open the project

    @node
    Scenario: A failed clone keeps its error until it is retried
      Given a clone of "acme/shop" failed with "Repository not found."
      Then the clone is reported as failed with "Repository not found."
      And the project "shop" stays, pointing at its empty folder

    @node
    Scenario: Retrying a failed clone starts it again with the same repository and folder
      Given a clone of "acme/shop" failed
      When the user retries the clone
      Then the clone is reported as running at the "connecting" stage
      And it clones into the same folder

    @node
    Scenario: Retrying a clone that is still running changes nothing
      Given a clone of "acme/shop" is running
      When the user retries the clone
      Then the node answers that nothing was applied

    @node
    Scenario: Cancelling a running clone stops git and marks the clone cancelled
      Given a clone of "acme/shop" is running
      When the user cancels the clone
      Then the clone is reported as cancelled
      And git stops cloning

    @node
    Scenario: A cancelled clone can be retried
      Given a clone of "acme/shop" was cancelled
      When the user retries the clone
      Then the clone is reported as running

    @backlog @desktop @mobile
    Scenario: A failed or cancelled clone offers to remove the project it created
      Given a clone of "acme/shop" failed
      When the user removes the project from the clone's failure notice
      Then the project "shop" is no longer listed

    @node
    Scenario: A restart forgets clones in flight but keeps their projects
      Given a clone of "acme/shop" is running
      When the node restarts
      Then no clone is reported
      And the project "shop" is still listed with its folder

    @tui
    Scenario: The terminal client clones a Git URL and then adds the project
      When the user adds a project from the Git URL "https://example.com/acme/shop.git"
      And chooses "/home/sam/shop" as the destination
      Then the repository is cloned into "/home/sam/shop"
      And the project "shop" is listed for "laptop"

    @tui
    Scenario: A repository name is looked up on a signed-in host before cloning
      Given the user is signed in to GitHub on "laptop"
      When the user adds a project from the GitHub repository "acme/shop"
      Then the user is asked where to clone the repository
      And a destination folder named "shop" is suggested

    @tui
    Scenario: A host the user is not signed in to cannot be chosen as a source
      Given the user is not signed in to GitLab on "laptop"
      When the user adds a project from a repository
      Then GitLab is marked as needing setup
      And the user is pointed to source control settings

    @node
    Scenario Outline: Repositories on other hosts can be looked up
      Given the user is signed in to <host> on "laptop"
      When the user looks up the repository "acme/shop" on <host>
      Then the repository's clone address is returned

      Examples:
        | host              |
        | Forgejo / Gitea   |
        | Bitbucket         |
        | Azure DevOps      |

    @node
    Scenario: A repository that cannot be found fails the lookup
      When the user looks up the GitHub repository "acme/missing"
      Then the lookup fails with the host's message
      And no project is created
