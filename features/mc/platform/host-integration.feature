# Sources:
#   apps/server-ex/lib/hal_c2/editors.ex (availableEditors, shell.openInEditor)
#   apps/server-ex/lib/hal_c2/local_servers.ex (subscribeDiscoveredLocalServers)
#   apps/server-ex/lib/hal_c2/projects.ex (filesystem.browse)
#   apps/server-ex/lib/hal_c2/paths.ex (symlink resolution)
#   apps/server-ex/lib/hal_c2/subprocess.ex (line framing, pipe backpressure)
#   apps/server-ex/lib/hal_c2/git.ex (use_gh_for_github: GitHub over the GitHub CLI's sign-in)
#   packages/contracts/src/editor.ts (EDITORS, launch styles, ExternalLauncher errors)
#   apps/server/src/processRunner.ts (timeout, output limit, truncation, exit status, spawn errors)
#   apps/server/src/process/externalLauncher.ts (Windows and WSL reveal, Linux folder-handler probe,
#     editor discovery cache, default browser launch)
#   packages/contracts/src/shell.ts
#   packages/contracts/src/rpc.ts (shell.openInEditor, filesystem.browse, subscribeDiscoveredLocalServers)
#   docs/internals/composer-editors.md
#   Shared domain: files/ owns opening files from the explorer; preview/ owns server suggestions.

Feature: The MC working with its host machine
  An MC opens editors on its own machine, lists folders for adding projects, finds
  web servers running on the host for previews, and reaches GitHub as its user does.

  Background:
    Given a running MC

  @mc
  Scenario: The server config lists editors installed on the host
    Given Cursor and Zed are installed on the host
    When a client reads the MC's server config
    Then the available editors include Cursor and Zed
    And the file manager is listed last

  @mc
  Scenario Outline: Opening a location in an editor uses that editor's style
    When a client opens "src/app.ts" at line 12 column 4 in <editor>
    Then the MC launches <editor> the way it takes a line and column
    And it does not wait for the editor to exit

    Examples:
      | editor   |
      | VS Code  |
      | Cursor   |
      | Zed      |
      | IntelliJ |

  @mc
  Scenario: The user's default text editor is offered first
    Given the host's default text editor is Neovim
    When a client reads the MC's server config
    Then the default editor is listed first

  @mc
  Scenario: Opening a location in the default editor opens the file
    Given the host's default text editor is Neovim
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then the MC launches Neovim's desktop entry on "src/app.ts"

  @mc
  Scenario: On a Mac the default editor is the one macOS opens text in
    Given the MC runs on macOS
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then macOS opens "src/app.ts" in its default text editor

  @mc
  Scenario: A default editor installed in a vendor folder is found by its id
    Given the host's default text editor is "acme-editor.desktop", installed as "acme/editor.desktop"
    When a client reads the MC's server config
    Then the default editor is listed first

  @mc
  Scenario: An empty DISPLAY is no display
    Given the host's default text editor is Neovim
    And DISPLAY is set but empty and there is no Wayland display
    When a client reads the available editors
    Then the default editor is not offered
    And the file manager is not offered

  @mc
  Scenario: A hung default editor lookup does not hold up the server config
    Given the host's xdg-mime never answers
    When a client reads the MC's server config
    Then the default editor is not offered

  @mc
  Scenario: A host without a default text editor does not offer one
    Given a Linux host with no display
    When a client reads the available editors
    Then the default editor is not offered

  @mc
  Scenario: Revealing a folder in the file manager
    When a client opens a project folder in the file manager
    Then the host's file manager shows that folder

  @mc
  Scenario: Opening the file manager on a host without one fails
    Given a Linux host with no display
    When a client opens a folder in the file manager
    Then the MC fails saying the file manager is unsupported

  @mc
  Scenario: On a Mac the file manager reveals the item
    Given the MC runs on macOS
    When a client reveals a file in the file manager
    Then Finder shows the file selected in its folder

  @mc
  Scenario: An unknown editor is refused
    When a client opens a folder in an editor id the MC does not know
    Then the MC fails saying the editor is unknown

  @mc
  Scenario: An editor that is not installed is refused
    Given Zed is not installed on the host
    When a client opens a folder in Zed
    Then the MC fails naming the command it could not find

  @mc
  Scenario: A headless Linux host offers no file manager
    Given a Linux host with no display
    When a client reads the available editors
    Then the file manager is not offered

  @backlog @mc
  Scenario Outline: A Linux host offers the file manager only when something can open folders
    Given a Linux host with a display and xdg-open installed
    And <handler state>
    When a client reads the available editors
    Then the file manager is not offered

    Examples:
      | handler state                                       |
      | no application is registered to open folders        |
      | xdg-mime is not installed                           |
      | the query for the folder handler fails              |

  @backlog @mc
  Scenario: A folder handler lookup that stalls drops only the file manager
    Given a Linux host with a display whose folder handler lookup never answers
    When a client reads the MC's server config
    Then the server config arrives with the editors that were found
    And the file manager is not offered

  @backlog @mc
  Scenario: On Windows the file manager selects the file in Explorer
    Given the MC runs on Windows with PowerShell available
    When a client reveals a file in the file manager
    Then Explorer shows the file selected in its folder

  @backlog @mc
  Scenario: On Windows without PowerShell revealing a file is not offered
    Given the MC runs on Windows without PowerShell
    When a client reads the available editors
    Then the file manager is still offered for folders
    But revealing a file in it is not offered

  @backlog @mc
  Scenario: On WSL a file is revealed in Windows Explorer through its Windows path
    Given the MC runs inside WSL with Explorer and PowerShell reachable from it
    When a client reveals a file in the file manager
    Then Windows Explorer shows that file selected under the distro's network path

  @backlog @mc
  Scenario Outline: On WSL a reveal that Windows cannot do falls back to the Linux file manager
    Given the MC runs inside WSL and <situation>
    When a client reveals a file in the file manager
    Then the Linux file manager opens the folder that holds the file

    Examples:
      | situation                                                    |
      | PowerShell is not reachable from the distro                  |
      | the Explorer bridge is not installed                         |
      | Explorer cannot select the path the file lives under         |

  @backlog @mc
  Scenario: Editors found outside the PATH are launched from where they are installed
    Given Cursor is installed in an application folder that is not on the PATH
    When a client opens a folder in Cursor
    Then the MC launches Cursor from its installed location

  @backlog @mc
  Scenario: An application folder that holds no launcher does not hide an editor on the PATH
    Given an editor application folder exists but contains no usable launcher
    And the editor's command is on the PATH
    When a client reads the available editors
    Then the editor is offered launched through the PATH command

  @backlog @mc
  Scenario: Installing an editor shows up in the server config within a minute
    Given a client read the server config a moment ago
    When an editor is installed on the host
    Then the next read within a minute may still omit it
    But a read after a minute offers the new editor

  @backlog @mc
  Scenario: A client that disconnects during an editor scan does not break the next one
    Given a client disconnects while the MC is scanning for editors
    When another client reads the server config
    Then the MC scans again and the server config lists the available editors

  @backlog @mc
  Scenario: The host's default browser opens a link for the MC
    Given the MC needs the user to sign in through a browser
    When the MC opens the link on its host
    Then the host's default browser opens that link
    And the MC does not wait for the browser to close

  @backlog @mc
  Scenario: A host with no way to open a browser says which command it could not run
    Given the host has no command that opens a browser
    When the MC opens a link on its host
    Then the MC fails naming the link and the command it tried

  @mc
  Scenario: Browsing folders to add a project
    Given the home folder has a dev folder holding api, tests, tools, .tmp, .trash and a file todo.txt
    When a client browses "~/dev/t"
    Then the MC lists folders in "~/dev" whose names start with "t"
    And hidden folders are left out

  @mc
  Scenario: Browsing a folder lists everything in it
    Given the home folder has a dev folder holding api, tests, tools, .tmp, .trash and a file todo.txt
    When a client browses "~/dev/"
    Then the MC lists every folder in "~/dev", hidden ones included

  @mc
  Scenario: Browsing a folder that does not exist
    When a client browses a path whose parent does not exist
    Then the MC fails without listing anything

  @mc
  Scenario: The MC finds web servers running on the host
    Given a development server is serving HTML on port 5173
    When a client follows the host's local servers
    Then port 5173 is listed

  @mc
  Scenario: Ports that do not serve HTML are not listed
    Given a database is listening on port 5432
    When a client follows the host's local servers
    Then port 5432 is not listed

  @mc
  Scenario: A server that stops is removed from the list
    Given a client follows the host's local servers with port 5173 listed
    When that server stops
    Then port 5173 is removed from the list

  @mc
  Scenario: The MC only scans for servers while someone watches
    Given nobody follows the host's local servers
    Then the MC does not scan the host's ports

  @mc
  Scenario: A symlink loop is reported rather than followed forever
    Given a project path that loops through symlinks
    When the MC resolves it
    Then it fails as a symlink loop

  @mc
  Scenario: A chatty subprocess is slowed down rather than buffered without end
    Given a provider process writing output faster than the MC reads it
    Then the MC applies backpressure through the process's pipe
    And its memory stays bounded

  @backlog @mc
  Scenario: A command the MC runs for a client that never finishes is stopped
    Given a client asks the MC to run a command that never exits
    When the command has run for a minute
    Then the MC stops it
    And the client is told the command timed out after the time it was given

  @backlog @mc
  Scenario: A command that writes more than the MC will hold is stopped
    Given a client asks the MC to run a command that prints more than 8 MiB
    When the output passes the limit
    Then the MC stops the command without waiting for it to finish
    And the client is told which stream went over the limit and what the limit is

  @backlog @mc
  Scenario: A command whose output may be long is cut at the limit instead of failing
    Given the MC runs a command for a view that can show a partial result
    When the command prints more than the view's limit
    Then the view receives the output up to the limit followed by a marker that it was cut
    And the command is reported as having succeeded or failed by its own exit code

  @backlog @mc
  Scenario: A command that exits with an error is a result and not a failure of the MC
    Given a client asks the MC to run a command that exits with status 1 and prints a message
    When the command finishes
    Then the client receives the exit status, the output and the error output

  @backlog @mc
  Scenario: A command that cannot start says which command and where
    Given a client asks the MC to run a command that is not installed
    Then the client is told the command could not be started and in which folder it was tried

  @backlog @mc
  Scenario: Output that is not valid text is passed on and marked
    Given a command prints bytes that are not valid UTF-8
    When the command finishes
    Then the output is returned with the bad bytes replaced
    And the result says the output was not valid UTF-8

  @mc
  Scenario: Git the MC starts reaches GitHub with the GitHub CLI's sign-in
    Given the GitHub CLI on the host is signed in to github.com
    When the MC sets up the git it starts
    Then git fetches "git@github.com:acme/shop.git" over HTTPS
    And the GitHub CLI answers git's request for a GitHub credential

  @mc
  Scenario: Without the GitHub CLI's sign-in git reaches GitHub as configured
    Given the GitHub CLI on the host is not signed in
    When the MC sets up the git it starts
    Then git fetches "git@github.com:acme/shop.git" over SSH

  @mc
  Scenario Outline: A sign-in or sign-out reaches git already running at the next hot update
    Given the GitHub CLI on the host is <before>
    And the MC sets up the git it starts
    And an agent's git is already running
    When the GitHub CLI <change> and the MC is hot-updated
    Then the agent's git fetches "git@github.com:acme/shop.git" over <transport>

    Examples:
      | before                  | change                  | transport |
      | not signed in           | signs in to github.com  | HTTPS     |
      | signed in to github.com | signs out               | SSH       |
