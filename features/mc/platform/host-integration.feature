# Sources:
#   apps/server-ex/lib/hal_c2/editors.ex (availableEditors, shell.openInEditor)
#   apps/server-ex/lib/hal_c2/local_servers.ex (subscribeDiscoveredLocalServers)
#   apps/server-ex/lib/hal_c2/projects.ex (filesystem.browse)
#   apps/server-ex/lib/hal_c2/paths.ex (symlink resolution)
#   apps/server-ex/lib/hal_c2/subprocess.ex (line framing, pipe backpressure)
#   apps/server-ex/lib/hal_c2/git.ex (use_gh_for_github: GitHub over the GitHub CLI's sign-in)
#   packages/contracts/src/editor.ts (EDITORS, launch styles, ExternalLauncher errors)
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
