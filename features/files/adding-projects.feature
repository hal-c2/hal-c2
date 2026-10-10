# Sources:
#   docs/user/project-settings.md
#   apps/server-ex/lib/hal_c2/projects.ex (project.create, browse)
#   apps/server/src/workspace/WorkspaceEntries.ts (browse: home, relative paths, prefix, errors)
#   apps/server-ex/lib/hal_c2/project_clones.ex (projectClone.start, retry, cancel, progress)
#   apps/server-ex/lib/hal_c2/source_control.ex (lookup, remote, clone)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (projectClones stream)
#   apps/web/src/components/CommandPalette.tsx (Add project, Local folder, clone flow)
#   apps/web/src/components/NoProjectsHero.tsx
#   apps/web/src/components/ProjectCloneToastCoordinator.tsx
#   apps/web/src/components/ChatView.tsx (projectCloneSendBlockReason: sending held while a project clones)
#   apps/web/src/shell/useShellFolderDrop.ts
#   apps/desktop-qt/qml/HalC2/Bricks/ProjectFolderDrop.qml
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (Add project)
#   apps/desktop-qt/qml/HalC2/Bricks/HomePage.qml
#   apps/desktop-qt/src/ShellBridge.cpp (project.folder.open, localDirectoryPath)
#   apps/desktop-qt/src/native/ProjectController.cpp (opens a local folder through projects.mutate)
#   apps/desktop-qt/src/native/ProjectCloneController.cpp (clone toasts: progress, cancel, retry, open, remove)
#   apps/tui/src/components/AddProjectOverlay.tsx
#   apps/tui/src/components/ChatView.tsx (add project flow)
#   apps/mobile/src/features/projects/AddProjectScreen.tsx
#   apps/mobile/src/features/projects/AddProjectScreen.logic.ts (the environment a requested add resolves to)
#   packages/client-runtime/src/operations/projects.ts (resolveAddProjectPath, remote source readiness)
#   packages/contracts/src/project.ts (ProjectMutation project.create)
#   packages/contracts/src/projectClone.ts
#   apps/server/src/project/ProjectCloneTracker.ts (claims, cancel, retry, discard, commands refused during a clone)
#   apps/server/src/project/gitCloneProgress.ts
#   apps/server/src/sourceControl/SourceControlRepositoryService.ts (prepareClone, discardClone, credential redaction, clone deadline)
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

    # Desktop: HomePage (apps/desktop-qt/tests/tst_HomePage.qml).
    @desktop @tui
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

    @mc
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

    @mc
    Scenario Outline: Browsing shows hidden folders only when asked for
      Given "/home/sam" holds the folders "shop" and ".config"
      When a client browses "<partial path>"
      Then ".config" <shown>

      Examples:
        | partial path | shown           |
        | /home/sam/   | is listed       |
        | /home/sam/.c | is listed       |
        | /home/sam/s  | is not listed   |

    # Legacy: apps/server/src/workspace/WorkspaceEntries.ts (resolveBrowseTarget)
    @mc @backlog
    Scenario Outline: Browsing a path the MC cannot make sense of is refused
      Given the MC runs on Linux
      When a client browses "<partial path>" <context>
      Then the MC answers "<message>"

      Examples:
        | partial path | context                              | message                                                                         |
        | C:\code      | with no current project              | Windows-style workspace path 'C:\code' is not supported on 'linux'.             |
        | ./shop       | with no current project              | A current project is required to browse relative workspace path './shop'.       |

    # Legacy: apps/server/src/workspace/WorkspaceEntries.ts (resolveBrowseTarget, browse: "~" and explicit relative paths)
    @mc @backlog
    Scenario Outline: Browsing starts from the home folder or the current project when asked to
      Given the MC's user is "sam" with the home folder "/home/sam"
      And "/home/sam" holds the folders "shop" and "Shared"
      And the current project's folder is "/home/sam/code" and holds the folder "shop-api"
      When a client browses "<partial path>" with the current project
      Then the folders <listed> are offered

      Examples:
        | partial path | listed                  |
        | ~            | "Shared" and "shop"     |
        | ~/sh         | "Shared" and "shop"     |
        | ./sh         | "shop-api"              |

    # Legacy: apps/server/src/workspace/WorkspaceEntries.ts (browse: prefix match is case-insensitive, sorted by name)
    @mc @backlog
    Scenario: Browsing matches the start of a name in any case and lists folders in name order
      Given "/home/sam" holds the folders "shop", "Shared" and "Sketches" and the file "sheet.txt"
      When a client browses "/home/sam/S"
      Then "Shared", "Sketches" and "shop" are offered in that order
      And "sheet.txt" is not offered

    # Legacy: apps/server/src/workspace/WorkspaceEntries.ts (WorkspaceEntriesReadDirectoryError)
    @mc @backlog
    Scenario: Browsing a folder that does not exist says which folder could not be read
      Given "/home/sam/nowhere" does not exist
      When a client browses "/home/sam/nowhere/"
      Then the MC answers that the folder "/home/sam/nowhere" could not be read

    @mc
    Scenario: Browsing a folder the user cannot read lists nothing
      Given "/root" cannot be read by the MC
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

    @mc
    Scenario: A folder that does not exist is refused unless the client asks to create it
      When a client creates a project at "/home/sam/missing" without asking to create the folder
      Then the MC answers that "/home/sam/missing" does not exist on this machine
      And no project is created

    @mc
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

    @dropped @mc
    Scenario: The standalone project list, add and remove methods are not carried
      When a client calls the projects list, add or remove method
      Then the MC answers that the method is not served
      And projects are listed from the shell stream and changed through project mutations

  Rule: Adding a project on the phone

    # The phone walks through source, repository and destination one screen at a time.
    @backlog @mobile
    Scenario: The phone offers a local folder and every way to clone
      Given "laptop" has a GitHub CLI and a GitLab CLI that are signed in
      When the user starts adding a project on the phone
      Then the user is offered a local folder
      And the user is offered a Git URL, a GitHub repository and a GitLab repository

    @backlog @mobile
    Scenario: A source whose tool is not ready says why and cannot be chosen
      Given "laptop" has no signed-in GitHub CLI
      When the user starts adding a project on the phone
      Then the GitHub repository source is listed with the reason it is not ready
      And choosing it does nothing

    @backlog @mobile
    Scenario: With several environments the user chooses which one receives the project
      Given the phone is paired with "laptop" and "desktop"
      When the user starts adding a project on the phone
      Then the user is asked which environment receives the project
      And "laptop" is chosen
      When the user chooses "desktop"
      Then the project will be added on "desktop"

    @backlog @mobile
    Scenario: An environment that is not connected is listed with its status and cannot be chosen
      Given the phone is paired with "laptop" and "desktop"
      And "desktop" is not connected
      When the user starts adding a project on the phone
      Then "desktop" is listed with its connection status
      And choosing "desktop" does nothing
      And "laptop" stays chosen

    @backlog @mobile
    Scenario: With no environment connected the phone offers to add one
      Given the phone is paired only with "laptop" and it is not connected
      When the user starts adding a project on the phone
      Then the user is told to start or reconnect an environment before adding a project
      And the user is offered to add an environment

    @backlog @mobile
    Scenario: An environment the user picked that has gone away is not swapped for another
      Given the phone is paired with "laptop" and "desktop"
      And the user chose "laptop" for the new project
      When "laptop" is no longer connected
      Then the user is told to start or reconnect an environment before adding a project
      And the project is not added on "desktop"

    @backlog @mobile
    Scenario: A repository on a provider is looked up before choosing where to clone it
      Given the repository "acme/shop" exists on GitHub
      When the user enters "acme/shop" as a GitHub repository
      Then the user is asked where to clone "acme/shop"
      And the repository's clone address is shown

    @backlog @mobile
    Scenario: A repository that cannot be found says why and stays on the page
      Given the repository "acme/missing" does not exist on GitHub
      When the user enters "acme/missing" as a GitHub repository
      Then the user is told why the repository could not be found
      And the user can correct the name

    @backlog @mobile
    Scenario: Nothing is looked up until something is typed
      When the user opens the GitHub repository source with nothing typed
      Then the user cannot continue

    @backlog @mobile
    Scenario: A pasted Git URL goes straight to choosing where to clone it
      When the user pastes a Git URL for "acme/shop" as the source
      Then the user is asked where to clone it without a lookup
      And the folder offered ends in "shop"

    @backlog @mobile
    Scenario: The folder offered for a project starts in the environment's folder for new projects
      Given "laptop" keeps new projects in "/home/sam/code"
      When the user starts adding a local folder on the phone
      Then the path offered starts in "/home/sam/code"

    @backlog @mobile
    Scenario: Browsing for a folder goes into a folder and back out of it
      Given "/home/sam/code" holds the folders "shop" and "docs"
      And the user is choosing a local folder starting at "/home/sam/code"
      When the user chooses "shop" in the list
      Then the path becomes "/home/sam/code/shop"
      When the user chooses to go up a level
      Then the path becomes "/home/sam/code"

    @backlog @mobile
    Scenario: The path the user types narrows the folders listed
      Given "/home/sam/code" holds the folders "shop" and "docs"
      When the user types "/home/sam/code/sh"
      Then only "shop" is listed

    @backlog @mobile
    Scenario: A clone destination keeps the repository's folder name while browsing
      Given the user is choosing where to clone "acme/shop"
      When the user browses into "/home/sam/code"
      Then the destination reads "/home/sam/code/shop"
      And every folder in "/home/sam/code" is still listed

    @backlog @mobile
    Scenario: A folder list that cannot be read says why
      Given listing "/home/sam/code" fails with "Permission denied"
      When the user browses to "/home/sam/code"
      Then the user is told "Permission denied"

    @backlog @mobile
    Scenario: Adding waits while a folder is being opened
      Given the user chose a folder and the phone is still reading it
      Then adding the project is not offered yet
      When the phone has read the folder
      Then adding the project is offered with the folder as its path

    @backlog @mobile
    Scenario: Changing the environment starts the path again from that environment
      Given the phone is paired with "laptop" and "desktop"
      And the user typed a path under "laptop"
      When the user chooses "desktop"
      Then the path starts in the folder "desktop" keeps new projects in

    @backlog @mobile
    Scenario: A clone that has not reached the phone yet says it will appear
      Given the MC accepted the clone of "acme/shop" and the project has not reached the phone
      When fifteen seconds pass
      Then the user is told the project was created but has not reached this device yet
      And the user is told it will appear in the project list once the connection catches up

  Rule: Dropping a folder on the desktop app

    @desktop
    Scenario: Dragging a single local folder over the window offers to open it as a project
      Given the desktop app is connected to its own local environment
      When the user drags the folder "/home/sam/shop" over the window
      Then the user is told the folder opens as a project
      And the user is told no files will be moved or deleted

    @desktop
    Scenario Outline: Drops that are not a single local folder are refused
      Given the desktop app is connected to its own local environment
      When the user drags <items> over the window
      Then the drop is refused

      Examples:
        | items                       |
        | a file                      |
        | two folders                 |
        | a link to a remote location |

    @desktop
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

    @backlog @desktop
    Scenario: A drop whose path is not absolute is refused
      Given the desktop app is connected to its own local environment
      And a project is selected
      When the dropped folder's path is relative
      Then the user is told "Drop an existing folder using its absolute local path."
      And no project is created

    @backlog @desktop
    Scenario: A second drop while the first is still opening is ignored
      Given the desktop app is connected to its own local environment
      And a dropped folder is still being opened
      When the user drops another folder
      Then the second folder is not opened

    @backlog @desktop
    Scenario: A drop that failed can be tried again
      Given the desktop app is connected to its own local environment
      And dropping "/home/sam/shop" failed
      When the user drops "/home/sam/shop" again
      Then the project "shop" is listed for "laptop"

  Rule: Cloning a repository into a new project

    @mc
    Scenario: Starting a clone adds the project at once and clones in the background
      When a client starts cloning "https://example.com/acme/shop.git" into "/home/sam/shop"
      Then the project "shop" is listed for "laptop" immediately
      And the clone is reported as running at the "connecting" stage

    @mc
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

    @desktop @mobile @backlog-mobile
    Scenario: Clone progress is shown while the user keeps working
      Given a clone of "acme/shop" is receiving objects at 45 percent
      When the user looks at the app
      Then the user sees "Cloning acme/shop" with "Receiving objects · 45%"
      And the user can cancel the clone

    @desktop @mobile @backlog-mobile
    Scenario: A clone on another machine of the cluster shows its progress too
      Given a clone of "acme/shop" is receiving objects at 45 percent on another machine of the cluster
      When the user looks at the app
      Then the user sees "Cloning acme/shop" with "Receiving objects · 45%"
      And the user can cancel the clone

    @mc
    Scenario: A finished clone is forgotten after a short while
      Given a clone of "acme/shop" finished
      When half a minute passes
      Then the clone is no longer reported
      And the project "shop" stays with its files

    @desktop @mobile @backlog-mobile
    Scenario: A finished clone offers to open its project
      Given a clone of "acme/shop" finished
      When the user looks at the app
      Then the user sees "Cloned acme/shop" with its destination folder
      And the user can open the project

    @mc
    Scenario: A failed clone keeps its error until it is retried
      Given a clone of "acme/shop" failed with "Repository not found."
      Then the clone is reported as failed with "Repository not found."
      And the project "shop" stays, pointing at its empty folder

    @mc
    Scenario: Retrying a failed clone starts it again with the same repository and folder
      Given a clone of "acme/shop" failed
      When the user retries the clone
      Then the clone is reported as running at the "connecting" stage
      And it clones into the same folder

    @mc
    Scenario: Retrying a clone that is still running changes nothing
      Given a clone of "acme/shop" is running
      When the user retries the clone
      Then the MC answers that nothing was applied

    @mc
    Scenario: Cancelling a running clone stops git and marks the clone cancelled
      Given a clone of "acme/shop" is running
      When the user cancels the clone
      Then the clone is reported as cancelled
      And git stops cloning

    @mc
    Scenario: A cancelled clone can be retried
      Given a clone of "acme/shop" was cancelled
      When the user retries the clone
      Then the clone is reported as running

    @desktop @mobile @backlog-mobile
    Scenario: A failed or cancelled clone offers to remove the project it created
      Given a clone of "acme/shop" failed
      When the user removes the project from the clone's failure notice
      Then the project "shop" is no longer listed

    # Likely already implemented: apps/desktop-qt/src/native/ProjectCloneController.cpp
    @backlog @desktop @mobile
    Scenario: A cancelled clone is announced as cancelled and can be retried from there
      Given a clone of "acme/shop" was cancelled
      When the user looks at the app
      Then the user sees "Cancelled cloning acme/shop" with its destination folder
      And the user can retry the clone or remove the project

    # Likely already implemented: apps/desktop-qt/src/native/ProjectCloneController.cpp
    @backlog @desktop @mobile
    Scenario Outline: A clone request the MC did not accept is reported
      Given a clone of "acme/shop" is <state>
      And the MC refuses the request
      When the user <action> from the notice
      Then the user sees an error "<told>"

      Examples:
        | state   | action            | told                   |
        | running | cancels the clone | Failed to cancel clone |
        | failed  | retries the clone | Failed to retry clone  |

    # Likely already implemented: apps/desktop-qt/src/native/ProjectCloneController.cpp
    @backlog @desktop
    Scenario: The clone notice steps aside while the user is in that project's new thread
      Given a clone of "acme/shop" is running
      When the user opens a new thread in "shop"
      Then the clone's notice is not shown because the new thread shows the same progress
      When the user leaves that new thread
      Then the clone's notice is shown again

    @backlog @desktop
    Scenario Outline: A message cannot be sent into a project whose clone has not finished
      Given a clone of "acme/shop" <state>
      And the user wrote a message in a new thread in "shop"
      Then the message cannot be sent and the reason given is "<reason>"
      And the draft can still be edited

      Examples:
        | state         | reason                |
        | is running    | Cloning repository    |
        | failed        | Repository not cloned |
        | was cancelled | Repository not cloned |

    @backlog @desktop
    Scenario: A message can be sent once the clone finishes
      Given the user wrote a message in a new thread in "shop" while "acme/shop" was cloning
      When the clone finishes
      Then the message can be sent

    @backlog @desktop @mobile
    Scenario: A finished clone's notice goes away by itself
      Given a clone of "acme/shop" finished
      When eight seconds pass
      Then the notice "Cloned acme/shop" is gone

    @backlog @desktop @mobile
    Scenario: A clone's notice goes when the MC stops tracking the clone
      Given a clone of "acme/shop" failed and its notice is shown
      When the project "shop" is removed on another device
      Then the notice for the clone is gone

    @mc
    Scenario: A restart forgets clones in flight but keeps their projects
      Given a clone of "acme/shop" is running
      When the MC restarts
      Then no clone is reported
      And the project "shop" is still listed with its folder

    # Legacy: apps/server/src/project/ProjectCloneTracker.ts (rejectCommandsDuringClone)
    @mc @backlog
    Scenario Outline: A thread cannot start in a project whose clone has not landed
      Given a clone of "acme/shop" is <state>
      When a client starts a thread in the project "shop"
      Then the MC refuses with "<message>"
      And no thread is created

      Examples:
        | state               | message                                               |
        | still running       | The repository is still being cloned.                 |
        | failed or cancelled | The repository was not cloned. Retry the clone first. |

    # Legacy: apps/server/src/project/ProjectCloneTracker.ts (start)
    @mc @backlog
    Scenario: A second clone into a folder another clone is filling is refused
      Given a clone of "acme/shop" into "/home/sam/shop" is running
      When a client starts cloning "acme/other" into "/home/sam/shop"
      Then it fails with "A clone into this destination is already in progress."
      And no second project is created

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (prepareDestination)
    @mc @backlog
    Scenario: A clone is refused before anything is created when its folder has files
      Given the folder "/home/sam/shop" already holds files
      When a client starts cloning "https://example.com/acme/shop.git" into "/home/sam/shop"
      Then it fails with "Destination path already exists and is not empty."
      And no project is created

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (normalizeDestinationPath)
    @mc @backlog
    Scenario: A clone needs a destination folder
      When a client starts cloning "https://example.com/acme/shop.git" into a blank destination
      Then it fails with "Choose a destination path before cloning."

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (prepareDestination, normalizeDestinationPath)
    @mc @backlog
    Scenario: A clone's folder is made with its missing parents and "~" is expanded
      Given "/home/sam/work" does not exist
      When a client starts cloning "https://example.com/acme/shop.git" into "~/work/shop"
      Then the clone goes into "/home/sam/work/shop"

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (redactRemoteUrl, redactUrlCredentials)
    @mc @backlog
    Scenario: Credentials in a pasted clone address never reach clients
      When a client starts cloning "https://sam:s3cret@example.com/acme/shop.git" into "/home/sam/shop"
      Then git is given the address as pasted
      And the clone reported to every client carries "https://example.com/acme/shop.git"
      And a failure's message has the credentials removed

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (cloneRepository, CLONE_ENV)
    @mc @backlog
    Scenario: A clone fails with git's own words when it would have asked for a password
      Given the repository "acme/private" needs credentials the MC does not have
      When a client starts cloning it
      Then git does not wait for a prompt
      And the clone is reported as failed with the last lines git printed

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (CLONE_TIMEOUT_MS)
    @mc @backlog
    Scenario: A tracked clone has no deadline but a one-shot clone gives up after two minutes
      Given a clone is still transferring after two minutes
      Then a clone started in the background keeps running
      But a clone that waits for its answer fails as timed out

    # Legacy: apps/server/src/project/ProjectCloneTracker.ts (cancel), SourceControlRepositoryService.ts (discardClone)
    @mc @backlog
    Scenario: Cancelling a clone removes what git left but keeps the project's folder
      Given a clone of "acme/shop" is running and has written part of the files
      When the user cancels the clone
      Then the folder "/home/sam/shop" still exists and is empty
      And retrying the clone starts from that empty folder

    # Legacy: apps/server/src/project/ProjectCloneTracker.ts (cancel, discard)
    @mc @backlog
    Scenario: A cancel that arrives as git finishes keeps the finished checkout
      Given a clone of "acme/shop" finishes while the user's cancel is being applied
      Then the clone is reported done
      And the checkout is kept

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (discardClone)
    @mc @backlog
    Scenario: Cleaning up a clone never deletes files that did not come from it
      Given a clone of "acme/shop" failed
      And the user has since put files of their own in "/home/sam/shop"
      When the user retries the clone
      Then the retry fails with "Destination path contains files that are not from the clone."
      And the user's files are untouched

    # Legacy: apps/server/src/project/ProjectCloneTracker.ts (discard)
    @mc @backlog
    Scenario: Deleting a project stops its clone and removes the partial checkout
      Given a clone of "acme/shop" is running for the project "shop"
      When a client deletes the project "shop"
      Then the clone is stopped and no longer reported
      And the partial files are removed
      But a clone that had already finished keeps its files

    # Legacy: apps/server/src/project/gitCloneProgress.ts, ProjectCloneTracker.ts (progress)
    @mc @backlog
    Scenario: Clone progress detail and errors are kept short
      Given git reports a transfer detail or an error far longer than a notice can show
      Then the reported detail and error are cut with an ellipsis within the contract's limit

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

    @mc
    Scenario Outline: Repositories on other hosts can be looked up
      Given the user is signed in to <host> on "laptop"
      When the user looks up the repository "acme/shop" on <host>
      Then the repository's clone address is returned

      Examples:
        | host              |
        | Forgejo / Gitea   |
        | Bitbucket         |
        | Azure DevOps      |

    @mc
    Scenario: A repository that cannot be found fails the lookup
      When the user looks up the GitHub repository "acme/missing"
      Then the lookup fails with the host's message
      And no project is created

    # Legacy: packages/client-runtime/src/operations/projects.ts (normalizePastedCloneUrl)
    @backlog @desktop @mobile @tui
    Scenario: A pasted owner and repository name is cloned from GitHub over HTTPS
      When the user pastes "acme/shop" as the Git URL to clone
      Then the repository is cloned from "https://github.com/acme/shop.git"
      And a pasted address that is already a URL or a local path is used as typed

    # Legacy: packages/client-runtime/src/operations/projects.ts (getDefaultCloneUrl)
    @backlog @desktop @mobile @tui
    Scenario Outline: A repository found on a provider is cloned over the provider's usual transport
      Given the user looked up "acme/shop" on <provider>
      When the user clones it
      Then the repository is cloned over <transport>

      Examples:
        | provider        | transport |
        | GitHub          | HTTPS     |
        | Forgejo / Gitea | HTTPS     |
        | GitLab          | SSH       |
        | Bitbucket       | SSH       |
        | Azure DevOps    | SSH       |

    # Legacy: packages/client-runtime/src/operations/projects.ts (getCloneDirectoryName)
    @backlog @desktop @mobile @tui
    Scenario Outline: A pasted clone address proposes the folder git would have chosen
      When the user pastes <address> as the Git URL to clone
      Then the proposed folder is named "<folder>"

      Examples:
        | address                                  | folder |
        | https://github.com/acme/shop.git         | shop   |
        | https://github.com/acme/shop/            | shop   |
        | ssh://git@host:22/acme/shop              | shop   |
        | git@github.com:acme/shop.git             | shop   |
        | https://github.com/acme/shop?tab=readme  | shop   |
        | https://dev.azure.com/org/proj/_git/shop | shop   |
        | https://host/acme/123                    | 123    |

    # Legacy: packages/client-runtime/src/operations/projects.ts (getCloneDirectoryName)
    @backlog @desktop @mobile @tui
    Scenario Outline: A pasted address that names no repository proposes no folder
      When the user pastes <address> as the Git URL to clone
      Then no folder name is proposed
      And the destination is the folder the user browsed to

      Examples:
        | address                  |
        | https://github.com       |
        | https://github.com:8443  |
        | ssh://git@host:22        |

    # Legacy: packages/client-runtime/src/operations/projects.ts (getCloneDestinationBrowsePath)
    @backlog @desktop @tui
    Scenario: Choosing a folder that already has the repository's name clones into it, not below it
      Given the user is choosing where to clone "acme/shop" and the browsed folder holds "shop"
      When the user chooses the folder "shop"
      Then the destination is that "shop" folder and not "shop/shop"
      And the match ignores case where the environment's file system does

    # Legacy: packages/client-runtime/src/operations/projects.ts (buildAddProjectRemoteSourceReadiness, sortAddProjectProviderSources)
    @backlog @desktop @tui
    Scenario: Clone sources that are ready are listed first, each unready one with its reason
      Given GitLab is signed in, GitHub is installed but signed out, and Bitbucket is not installed
      When the user chooses to clone a repository
      Then the Git URL source is always ready
      And GitLab is listed before GitHub and Bitbucket
      And GitHub says it is not authenticated and points to source control settings
      And Bitbucket gives its install hint
      And a provider the environment has not reported says to open source control settings and rescan
