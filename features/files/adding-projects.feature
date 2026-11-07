# Sources:
#   https://github.com/pingdotgg/t3code/pull/24915
#   https://github.com/pingdotgg/t3code/pull/30798
#   https://github.com/pingdotgg/t3code/pull/26068
#   https://github.com/pingdotgg/t3code/pull/26767
#   https://github.com/pingdotgg/t3code/pull/24698
#   https://github.com/pingdotgg/t3code/pull/23170
#   https://github.com/pingdotgg/t3code/pull/22492
#   https://github.com/pingdotgg/t3code/pull/18265
#   https://github.com/pingdotgg/t3code/pull/17379
#   https://github.com/pingdotgg/t3code/pull/22780
#   https://github.com/pingdotgg/t3code/pull/22180
#   https://github.com/pingdotgg/t3code/pull/22254
#   https://github.com/pingdotgg/t3code/pull/25819
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
#   https://github.com/pingdotgg/t3code/pull/28064
#   https://github.com/pingdotgg/t3code/pull/28243
#   https://github.com/pingdotgg/t3code/pull/23024
#   https://github.com/pingdotgg/t3code/pull/24005
#   https://github.com/pingdotgg/t3code/pull/28365
#   https://github.com/pingdotgg/t3code/pull/28460
#   https://github.com/pingdotgg/t3code/pull/24904
#   https://github.com/pingdotgg/t3code/pull/31642
#   https://github.com/pingdotgg/t3code/pull/29843

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

    @backlog @mobile @priority-high
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

    @desktop @mobile @backlog-mobile @priority-high
    Scenario: Adding a folder from the desktop and mobile apps registers it and starts a thread
      Given the folder "/home/sam/shop" exists on "laptop"
      When the user adds the local folder "/home/sam/shop"
      Then the project "shop" is listed for "laptop"
      And a draft thread opens in "shop"

    @desktop @mobile @backlog-mobile @priority-high
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

    # Upstream #31642: deleting the leading "/" or a drive letter stopped the text being a path,
    # the field was rebuilt and the caret jumped to the end.
    @backlog @shared @priority-low
    Scenario Outline: Editing the start of a typed folder path keeps the caret there
      Given the user typed "<path>" while adding a local folder
      When the user deletes "<deleted>" at the start and types "<typed>"
      Then the path reads "<result>"

      Examples:
        | path              | deleted | typed | result            |
        | /tmp/project      | /       | /     | /tmp/project      |
        | C:\Users\sam\shop | C       | D     | D:\Users\sam\shop |

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

    # Upstream #28064: a reopened folder browser showed the listing it had cached minutes before.
    @backlog @shared
    Scenario: Reopening the folder browser shows folders added or removed since
      Given the user browsed "/home/sam/code" and closed the folder browser
      And the folder "/home/sam/code/delta" was created outside HAL-C2
      When the user reopens the folder browser at "/home/sam/code" some seconds later
      Then "delta" is listed

    # Upstream #28243: Tab in the folder browser left the path field instead of completing it.
    @backlog @desktop @tui
    Scenario Outline: Tab completes the folder name being typed
      Given "/home/sam" holds the folders <folders>
      And the user is browsing for a local folder
      When the user types "<typed>" and presses Tab
      Then the path reads "<path>"
      And the user is still typing the path
      And no project is added

      Examples:
        | folders                          | typed           | path                  |
        | "Creations" and "Documents"      | ~/Creation      | ~/Creations/          |
        | "Coding" and "Codex"             | ~/Cod           | ~/Cod                 |
        | "Coding-old" and "Coding-new"    | ~/Cod           | ~/Coding-             |
        | "Creations" and "Documents"      | ~/Zz            | ~/Zz                  |

    # Upstream #28243: a highlighted folder is entered, not added.
    @backlog @desktop @tui
    Scenario: Tab enters the highlighted folder
      Given the user is browsing for a local folder at "~/"
      And the folder "Creations" is highlighted
      When the user presses Tab
      Then the path reads "~/Creations/"
      And the folders inside "Creations" are listed

    @tui
    Scenario: Adding a folder that is already a project opens it instead
      Given "shop" is already a project on "laptop"
      When the user adds the local folder of "shop" again
      Then no second project is created
      And the user is told the project was already added

    @desktop @mobile @backlog-mobile @priority-high
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

    # Upstream #28460: a path copied from Finder or Explorer arrives quoted or escaped for a shell,
    # was read as a new folder under home, and could create a junk folder and project.
    @backlog @shared
    Scenario Outline: A pasted folder path copied from a file manager names that folder
      Given "/Users/sam/Monarch Money" and "/Users/sam/Bob's Stuff" are folders
      When the user pastes <pasted> while adding a local folder
      Then the folder to add is "<folder>"
      And no folder is offered to be created

      Examples:
        | pasted                         | folder                   |
        | '/Users/sam/Monarch Money'   | /Users/sam/Monarch Money |
        | /Users/sam/Bob\\'s\\ Stuff   | /Users/sam/Bob's Stuff   |
        | "/Users/sam/Monarch Money"   | /Users/sam/Monarch Money |

    @mc
    Scenario: A folder is created for a new project when the client asks for it
      When a client creates a project at "/home/sam/fresh" and asks to create the folder
      Then the folder "/home/sam/fresh" exists
      And the project "fresh" is listed for "laptop"

    # Upstream #29843: a new named project's starter files are written with LF endings, and a git that
    # refuses LF files (core.safecrlf with CRLF conversion) failed the project and removed its folder.
    @backlog @mc
    Scenario: A new named project is created when git refuses files with LF line endings
      Given the user's git refuses to stage files whose LF endings it would convert
      When the user creates the new project "fresh" by name
      Then the project "fresh" is listed for "laptop" with its starter files staged in a new repository
      And the user's own commits still follow that git setting

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

    # Upstream #26068: the whole "project/repository" was sent as the repository name, so Azure
    # never found it.
    @backlog @mc
    Scenario: An Azure DevOps repository is looked up by its project and name
      Given the repository "app" exists in the Azure DevOps project "shop"
      When the user enters "shop/app" as an Azure DevOps repository
      Then the user is asked where to clone "shop/app"
      And a bare "app" is looked up in the project of the current checkout

    @backlog @mobile @priority-low
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

    # Upstream #25819: the path field reset whenever the chosen environment changed, so one that
    # dropped out for a moment and came back wiped what the user had typed.
    @backlog @mobile
    Scenario: A typed folder path survives its environment dropping out and returning
      Given the user typed "/home/sam/code/shop" as the local folder on "laptop"
      When "laptop" drops out for a moment and comes back
      Then the path still reads "/home/sam/code/shop"

    # Upstream #25819
    @backlog @mobile @priority-low
    Scenario: Each environment keeps the folder path typed for it
      Given the phone is paired with "laptop" and "desktop"
      And the user typed "/home/sam/code/shop" as the local folder on "laptop"
      When the user switches to "desktop" and edits its path
      And the user switches back to "laptop"
      Then the path reads "/home/sam/code/shop"

    @backlog @mobile
    Scenario: Browsing for a folder goes into a folder and back out of it
      Given "/home/sam/code" holds the folders "shop" and "docs"
      And the user is choosing a local folder starting at "/home/sam/code"
      When the user chooses "shop" in the list
      Then the path becomes "/home/sam/code/shop"
      When the user chooses to go up a level
      Then the path becomes "/home/sam/code"

    @backlog @mobile @priority-low
    Scenario: The path the user types narrows the folders listed
      Given "/home/sam/code" holds the folders "shop" and "docs"
      When the user types "/home/sam/code/sh"
      Then only "shop" is listed

    @backlog @mobile @priority-low
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

    @backlog @mobile @priority-low
    Scenario: Adding waits while a folder is being opened
      Given the user chose a folder and the phone is still reading it
      Then adding the project is not offered yet
      When the phone has read the folder
      Then adding the project is offered with the folder as its path

    @backlog @mobile @priority-low
    Scenario: Changing the environment starts the path again from that environment
      Given the phone is paired with "laptop" and "desktop"
      And the user typed a path under "laptop"
      When the user chooses "desktop"
      Then the path starts in the folder "desktop" keeps new projects in

    @backlog @mobile @priority-low
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

    @backlog @desktop @priority-low
    Scenario: A drop whose path is not absolute is refused
      Given the desktop app is connected to its own local environment
      And a project is selected
      When the dropped folder's path is relative
      Then the user is told "Drop an existing folder using its absolute local path."
      And no project is created

    @backlog @desktop @priority-low
    Scenario: A second drop while the first is still opening is ignored
      Given the desktop app is connected to its own local environment
      And a dropped folder is still being opened
      When the user drops another folder
      Then the second folder is not opened

    @backlog @desktop @priority-low
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

    @desktop @mobile @backlog-mobile @priority-high
    Scenario: Clone progress is shown while the user keeps working
      Given a clone of "acme/shop" is receiving objects at 45 percent
      When the user looks at the app
      Then the user sees "Cloning acme/shop" with "Receiving objects · 45%"
      And the user can cancel the clone

    # Upstream #22780: a clone git has gone silent on is marked stalled after 20 seconds.
    @backlog @mc
    Scenario: A clone with no progress for 20 seconds is reported as stalled
      Given a clone of "acme/shop" is receiving objects at 24 percent
      When git reports no progress for 20 seconds
      Then the clone is reported as stalled
      When git reports "Receiving objects:  25% (25/100)"
      Then the clone is no longer reported as stalled

    # Upstream #22780: a stalled clone shows "Stalled" instead of its last transfer speed.
    @backlog @desktop @mobile
    Scenario: A stalled clone says so instead of showing a frozen speed
      Given a clone of "acme/shop" stalled while receiving objects at 24 percent at 20.69 MiB/s
      When the user looks at the app
      Then the user sees "Cloning acme/shop" with "Receiving objects · 24% · Stalled"
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

    @desktop @mobile @backlog-mobile @priority-high
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

    # Upstream #23170: GitCafe, GitLab, Bitbucket and Azure DevOps clone over SSH, and a machine
    # with no SSH key for the host failed every time, Retry included.
    @backlog @mc
    Scenario: A clone whose SSH key is refused tries once more over HTTPS
      Given the host refuses this machine's SSH key but its HTTPS credentials work
      When the user clones "acme/shop" from GitLab without choosing SSH
      Then the clone succeeds over HTTPS
      And the project's remote is the HTTPS address

    # Upstream #23170: a clone that should stay on SSH, or HTTPS, is not retried over the other.
    @backlog @mc @priority-low
    Scenario Outline: A clone does not fall back to HTTPS when it should not
      Given <case>
      When the clone fails
      Then it is not tried over HTTPS

      Examples:
        | case                                                |
        | the user asked to clone over SSH                    |
        | the clone failed for a reason other than its SSH key |
        | the pasted SSH address names a custom port          |

    # Upstream #28365: a clone the MC tracked dropped the protocol the user asked for, so a clone
    # asked over SSH still fell back to HTTPS, on Retry too.
    @backlog @mc
    Scenario: A clone asked over SSH stays on SSH when it is retried
      Given the user cloned "acme/shop" over SSH and the host refused this machine's SSH key
      When the user retries the clone
      Then it is tried over SSH again
      And it is not tried over HTTPS

    # Upstream #23170: a clone that fails over SSH and then HTTPS reports both reasons.
    @backlog @mc @priority-low
    Scenario: A clone that fails over SSH and then HTTPS gives both reasons
      Given the host refuses this machine's SSH key and its HTTPS credentials
      When the user clones "acme/shop" from GitLab
      Then the failure gives the SSH refusal followed by why HTTPS failed

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

    @desktop @mobile @backlog-mobile @priority-high
    Scenario: A failed or cancelled clone offers to remove the project it created
      Given a clone of "acme/shop" failed
      When the user removes the project from the clone's failure notice
      Then the project "shop" is no longer listed

    # Upstream #24915: a client that dropped mid-remove left the failed clone's notice and its folder reserved.
    @backlog @mc @priority-high
    Scenario: Removing a failed clone's project also forgets the clone, even if the client drops
      Given a clone of "acme/shop" into "~/shop" failed
      And the client disconnects while the user removes the project
      When the user reconnects
      Then no notice says the clone failed
      And "acme/shop" can be cloned into "~/shop" again

    # Likely already implemented: apps/desktop-qt/src/native/ProjectCloneController.cpp
    @backlog @desktop @mobile @priority-high
    Scenario: A cancelled clone is announced as cancelled and can be retried from there
      Given a clone of "acme/shop" was cancelled
      When the user looks at the app
      Then the user sees "Cancelled cloning acme/shop" with its destination folder
      And the user can retry the clone or remove the project

    # Likely already implemented: apps/desktop-qt/src/native/ProjectCloneController.cpp
    @backlog @desktop @mobile @priority-high
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
    @backlog @desktop @priority-high
    Scenario: The clone notice steps aside while the user is in that project's new thread
      Given a clone of "acme/shop" is running
      When the user opens a new thread in "shop"
      Then the clone's notice is not shown because the new thread shows the same progress
      When the user leaves that new thread
      Then the clone's notice is shown again

    @backlog @desktop @priority-high
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

    @backlog @desktop @priority-high
    Scenario: A message can be sent once the clone finishes
      Given the user wrote a message in a new thread in "shop" while "acme/shop" was cloning
      When the clone finishes
      Then the message can be sent

    @backlog @desktop @mobile @priority-low
    Scenario: A finished clone's notice goes away by itself
      Given a clone of "acme/shop" finished
      When eight seconds pass
      Then the notice "Cloned acme/shop" is gone

    @backlog @desktop @mobile @priority-low
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
    @mc @priority-high
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
    @mc
    Scenario: A second clone into a folder another clone is filling is refused
      Given a clone of "acme/shop" into "/home/sam/shop" is running
      When a client starts cloning "acme/other" into "/home/sam/shop"
      Then it fails with "A clone into this destination is already in progress."
      And no second project is created

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (prepareDestination)
    @mc @priority-high
    Scenario: A clone is refused before anything is created when its folder has files
      Given the folder "/home/sam/shop" already holds files
      When a client starts cloning "https://example.com/acme/shop.git" into "/home/sam/shop"
      Then it fails with "Destination path already exists and is not empty."
      And no project is created

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (normalizeDestinationPath)
    @mc
    Scenario: A clone needs a destination folder
      When a client starts cloning "https://example.com/acme/shop.git" into a blank destination
      Then it fails with "Choose a destination path before cloning."

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (prepareDestination, normalizeDestinationPath)
    @mc
    Scenario: A clone's folder is made with its missing parents and "~" is expanded
      Given "/home/sam/work" does not exist
      When a client starts cloning "https://example.com/acme/shop.git" into "~/work/shop"
      Then the clone goes into "/home/sam/work/shop"

    # Upstream #18265: making the clone's parent tried to create the drive root itself and failed;
    # the parent is made only when it is missing.
    @mc @backlog @priority-low
    Scenario: A clone into a new folder at the top of a Windows drive goes ahead
      Given the MC runs on Windows
      When a client starts cloning "https://example.com/acme/shop.git" into "D:\shop"
      Then the clone goes into "D:\shop"

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (redactRemoteUrl, redactUrlCredentials)
    @mc @priority-high
    Scenario: Credentials in a pasted clone address never reach clients
      When a client starts cloning "https://sam:s3cret@example.com/acme/shop.git" into "/home/sam/shop"
      Then git is given the address as pasted
      And the clone reported to every client carries "https://example.com/acme/shop.git"
      And a failure's message has the credentials removed

    # Upstream #24698: git repeats the clone URL, query string included, in its error.
    @mc @backlog @priority-high
    Scenario: A token in a clone address's query never reaches clients in a failure
      When a client starts cloning "https://example.com/acme/shop.git?access_token=s3cret" into "/home/sam/shop"
      And git fails, repeating the address in its error
      Then the failure every client sees names "https://example.com/acme/shop.git" without its query
      And the rest of git's message is kept

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (cloneRepository, CLONE_ENV)
    @mc
    Scenario: A clone fails with git's own words when it would have asked for a password
      Given the repository "acme/private" needs credentials the MC does not have
      When a client starts cloning it
      Then git does not wait for a prompt
      And the clone is reported as failed with the last lines git printed

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (CLONE_TIMEOUT_MS)
    @mc @backlog @priority-low
    Scenario: A tracked clone has no deadline but a one-shot clone gives up after two minutes
      Given a clone is still transferring after two minutes
      Then a clone started in the background keeps running
      But a clone that waits for its answer fails as timed out

    # Legacy: apps/server/src/project/ProjectCloneTracker.ts (cancel), SourceControlRepositoryService.ts (discardClone)
    @mc
    Scenario: Cancelling a clone removes what git left but keeps the project's folder
      Given a clone of "acme/shop" is running and has written part of the files
      When the user cancels the clone
      Then the folder "/home/sam/shop" still exists and is empty
      And retrying the clone starts from that empty folder

    # Legacy: apps/server/src/project/ProjectCloneTracker.ts (cancel, discard)
    @mc
    Scenario: A cancel that arrives as git finishes keeps the finished checkout
      Given a clone of "acme/shop" finishes while the user's cancel is being applied
      Then the clone is reported done
      And the checkout is kept

    # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (discardClone)
    @mc @priority-high
    Scenario: Cleaning up a clone never deletes files that did not come from it
      Given a clone of "acme/shop" failed
      And the user has since put files of their own in "/home/sam/shop"
      When the user retries the clone
      Then the retry fails with "Destination path contains files that are not from the clone."
      And the user's files are untouched

    # Legacy: apps/server/src/project/ProjectCloneTracker.ts (discard)
    @mc @priority-high
    Scenario: Deleting a project stops its clone and removes the partial checkout
      Given a clone of "acme/shop" is running for the project "shop"
      When a client deletes the project "shop"
      Then the clone is stopped and no longer reported
      And the partial files are removed
      But a clone that had already finished keeps its files

    # Legacy: apps/server/src/project/gitCloneProgress.ts, ProjectCloneTracker.ts (progress)
    @mc @priority-low
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

    # Upstream #17379: a bare name stopped resolving when lookups moved off the gh CLI.
    @backlog @mc
    Scenario: A bare repository name is the signed-in account's repository
      Given the user is signed in to GitHub as "octocat"
      When the user looks up the GitHub repository " notes.git "
      Then the repository "octocat/notes" is found on the host the user is signed in to

    @backlog @mc @priority-low
    Scenario Outline: A malformed repository name is refused before GitHub is asked
      When the user looks up the GitHub repository "<name>"
      Then the lookup is refused without asking GitHub

      Examples:
        | name       |
        | me/        |
        | /notes     |
        | a/b/c/d    |
        | two words  |
        |            |

    # Upstream #23024: an owner with a trailing slash went to the lookup and failed with a generic error.
    @backlog @desktop @mobile
    Scenario: An owner without a repository name asks for the full name
      When the user looks up the GitHub repository "acme/"
      Then GitHub is not asked
      And the user reads "Repository name incomplete" and "Enter the full owner/repository name."

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
    @backlog @desktop @mobile @tui @priority-low
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

    # Upstream #24904: every clone went to "<folder for new projects>/<repo>", so a fork or a
    # second "api" clashed with the first, and ghq users typed the whole path each time.
    @backlog @mc @shared @priority-low
    Scenario Outline: Cloning into host folders proposes a folder per host and owner
      Given "laptop" keeps new projects in "/home/sam/code"
      And "Clone into host folders" is <setting>
      When the user clones "https://github.com/sam/shop.git" from <entry>
      Then the folder proposed is "<folder>"

      Examples:
        | setting | entry                         | folder                               |
        | on      | the command palette           | /home/sam/code/github.com/sam/shop   |
        | on      | a link in a prompt            | /home/sam/code/github.com/sam/shop   |
        | on      | adding it to another machine  | /home/sam/code/github.com/sam/shop   |
        | on      | adding a project on the phone | /home/sam/code/github.com/sam/shop   |
        | off     | the command palette           | /home/sam/code/shop                  |

    # Upstream #24904: the host folders a clone will make need not exist yet.
    @backlog @mobile @priority-low
    Scenario: A proposed clone folder that does not exist yet says the clone makes it
      Given "Clone into host folders" is on and "/home/sam/code/github.com" does not exist
      When the user chooses where to clone "sam/shop" on the phone
      Then the folder reads "Cloning creates it" instead of an error

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

  # Upstream #22180: "Run on" can add the project to a connected machine that lacks it, cloning
  # it there and copying the gitignored files the user picks, ".env" files checked by default.
  Rule: Adding a project to another machine

    @backlog @desktop
    Scenario: A machine without the project can be offered from "Run on"
      Given "shop" is on "laptop" and the connected machine "server" does not have it
      When the user opens "Run on" for a new thread in "shop"
      Then "Add to another machine" offers "server"

    @backlog @mc
    Scenario: A checkout lists its gitignored files, leaving out folders ignored whole
      Given the checkout of "shop" has the ignored files ".env" and ".env.local" and the ignored folder "node_modules"
      When a client asks for the checkout's ignored files
      Then ".env" and ".env.local" are listed
      And "node_modules" is not

    @backlog @desktop
    Scenario: Adding a project to another machine offers its env files to copy
      Given the checkout of "shop" on "laptop" has the ignored files ".env", ".dev.vars" and "notes.txt"
      When the user adds "shop" to "server"
      Then the user can choose SSH or HTTPS and the folder on "server"
      And ".env" is checked to copy while ".dev.vars" and "notes.txt" are offered unchecked

    # Upstream #24005: switching an Azure DevOps address between SSH and HTTPS kept the SSH host and path.
    @backlog @desktop @mc
    Scenario Outline: An Azure DevOps address switched between SSH and HTTPS is one Azure accepts
      Given the checkout of "shop" on "laptop" has the remote <from>
      When the user adds "shop" to "server" and chooses <protocol>
      Then "server" clones from <to>

      Examples:
        | from                                                    | protocol | to                                                      |
        | "git@ssh.dev.azure.com:v3/Fabrikam/Project1/fab_repo"   | HTTPS    | "https://dev.azure.com/Fabrikam/Project1/_git/fab_repo" |
        | "https://dev.azure.com/Fabrikam/Project1/_git/fab_repo" | SSH      | "git@ssh.dev.azure.com:v3/Fabrikam/Project1/fab_repo"   |

    # Upstream #30798: an SSH address whose host is a bracketed IPv6 address turned into an
    # invalid HTTPS address, split at the first colon inside the brackets.
    @backlog @desktop @mc @priority-low
    Scenario Outline: An address whose host is an IPv6 address keeps it when switched between SSH and HTTPS
      Given the checkout of "shop" on "laptop" has the remote <from>
      When the user adds "shop" to "server" and chooses <protocol>
      Then "server" clones from <to>

      Examples:
        | from                                   | protocol | to                                       |
        | "git@[2001:db8::1]:org/repo.git"       | HTTPS    | "https://[2001:db8::1]/org/repo.git"     |
        | "https://[2001:db8::1]/org/repo.git"   | SSH      | "git@[2001:db8::1]:org/repo.git"         |

    @backlog @desktop
    Scenario: The chosen files are copied once the clone on the other machine finishes
      Given the user added "shop" to "server" with ".env" chosen to copy
      When the clone on "server" finishes
      Then ".env" is on "server" in the new checkout
      And "server" is offered under "Run on" for "shop" without a reload

    @backlog @desktop @priority-low
    Scenario: Only small text files are copied to the other machine
      Given the user chose a symlink and a text file over 1 MB among the files to copy
      When the clone on "server" finishes
      Then neither is copied and the user is told which were skipped

    @backlog @mc
    Scenario: A fresh clone groups with the project's other checkouts at once
      Given "shop" has a checkout on "laptop"
      When a clone of the same repository finishes on "server"
      Then the new checkout is grouped with "shop" straight away

    # Upstream #22492: the copy clones the checkout's origin, not its upstream remote, so a fork
    # copies the fork and stays one project in the sidebar.
    @backlog @desktop @mc
    Scenario: Adding a fork to another machine clones the fork
      Given the checkout of "shop" on "laptop" has the origin "acme-fork/shop" and the upstream "acme/shop"
      When the user adds "shop" to "server"
      Then "server" clones "acme-fork/shop"
      And the sidebar shows "shop" once

    # Upstream #22254: the draft moves to the target machine at once and the clone is shown in
    # the composer, with no toasts on the way.
    @backlog @desktop
    Scenario: Adding a project to another machine moves the draft there
      Given the user typed "fix the tax" for a new thread in "shop" on "laptop"
      When the user adds "shop" to "server"
      Then the draft is for "shop" on "server" and still reads "fix the tax"
      And the composer shows the clone's progress and a way to cancel it

    # Upstream #22254: send stays blocked until both the clone and the copied files have landed.
    @backlog @desktop
    Scenario: A draft on the new machine cannot be sent until its files are copied
      Given the user added "shop" to "server" with ".env" chosen to copy
      And the clone on "server" has finished but ".env" is still being copied
      When the user tries to send the draft
      Then the message is not sent until ".env" has been copied

    # Upstream #22254: a failed file copy is a dismissible notice in the composer, not a toast.
    @backlog @desktop
    Scenario: A file that could not be copied to the new machine is called out in the composer
      Given the user added "shop" to "server" with ".env" chosen to copy
      When copying ".env" to "server" fails
      Then the composer says ".env" was not copied
      And the user can dismiss that notice

    # Upstream #22254: a clone started elsewhere does not announce itself again once the user
    # has looked at the project.
    @backlog @desktop @priority-low
    Scenario: A finished clone's notice does not come back after the user has seen the project
      Given a clone of "shop" started from the command palette finished
      And the user opened "shop"
      When the user sends a message in "shop"
      Then the clone's notice does not appear again

    # Upstream #22254: the favicon looked up while the folder was empty was kept after the clone.
    @backlog @mc
    Scenario: A freshly cloned project shows its own icon
      Given the repository "shop" has a favicon
      When a clone of "shop" finishes into an empty folder
      Then the project's icon is the repository's favicon, not a letter

  # Upstream #26767: a No project thread's folder becomes a project where it is
  @backlog
  Rule: Turning a No project thread into a project

    Background:
      Given the thread "Convert PNGs" was started with No project and works in its own scratch folder

    @mc @shared @mobile
    Scenario: Turning a No project thread into a project keeps it in its folder
      When the user chooses "Turn into project" from the thread's menu
      Then a project rooted at the thread's folder is created, without moving any file
      And "Convert PNGs" belongs to that project and its agent session carries on there
      And the user is offered to initialize Git in the new project

    @mc
    Scenario: The other threads in the folder and their scheduled tasks move with it
      Given a fork and an archived thread also work in the folder of "Convert PNGs"
      And a scheduled task is bound to "Convert PNGs"
      And another No project thread works in a different scratch folder
      When "Convert PNGs" is turned into a project
      Then the fork, the archived thread and the scheduled task belong to the new project
      And the other No project thread stays under No project

    @mc @shared @mobile
    Scenario: A thread cannot be turned into a project while work in its folder runs
      Given a subagent working in the folder of "Convert PNGs" is still running
      Then "Turn into project" is disabled for "Convert PNGs"
      And an attempt that reaches the MC changes nothing

    @mc @priority-low
    Scenario: Turning a thread into a project again finishes a move that stopped part way
      Given turning "Convert PNGs" into a project stopped after the project was created
      When the user turns "Convert PNGs" into a project again
      Then every thread in the folder belongs to that same project

    @shared @mobile
    Scenario Outline: Only a No project thread with a folder offers to become a project
      Given the thread <kind>
      Then its menu <offers> "Turn into project"

      Examples:
        | kind                                       | offers         |
        | was started with No project and has a folder | offers       |
        | was started with No project and has no folder yet | does not offer |
        | belongs to the project "shop"              | does not offer |
