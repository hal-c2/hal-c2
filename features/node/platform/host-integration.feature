# Sources:
#   apps/server-ex/lib/t3/editors.ex (availableEditors, shell.openInEditor)
#   apps/server-ex/lib/t3/local_servers.ex (subscribeDiscoveredLocalServers)
#   apps/server-ex/lib/t3/projects.ex (filesystem.browse)
#   apps/server-ex/lib/t3/paths.ex (symlink resolution)
#   apps/server-ex/lib/t3/subprocess.ex (line framing, pipe backpressure)
#   packages/contracts/src/editor.ts (EDITORS, launch styles, ExternalLauncher errors)
#   packages/contracts/src/shell.ts
#   packages/contracts/src/rpc.ts (shell.openInEditor, filesystem.browse, subscribeDiscoveredLocalServers)
#   docs/internals/composer-editors.md
#   Shared domain: files/ owns opening files from the explorer; preview/ owns server suggestions.

Feature: The node working with its host machine
  A node opens editors on its own machine, lists folders for adding projects, and finds
  web servers running on the host for previews.

  Background:
    Given a running node

  @node
  Scenario: The server config lists editors installed on the host
    Given Cursor and Zed are installed on the host
    When a client reads the node's server config
    Then the available editors include Cursor and Zed
    And the file manager is listed last

  @node
  Scenario Outline: Opening a location in an editor uses that editor's style
    When a client opens "src/app.ts" at line 12 column 4 in <editor>
    Then the node launches <editor> the way it takes a line and column
    And it does not wait for the editor to exit

    Examples:
      | editor   |
      | VS Code  |
      | Cursor   |
      | Zed      |
      | IntelliJ |

  @node
  Scenario: Revealing a folder in the file manager
    When a client opens a project folder in the file manager
    Then the host's file manager shows that folder

  @node
  Scenario: Opening the file manager on a host without one fails
    Given a Linux host with no display
    When a client opens a folder in the file manager
    Then the node fails saying the file manager is unsupported

  @node
  Scenario: On a Mac the file manager reveals the item
    Given the node runs on macOS
    When a client reveals a file in the file manager
    Then Finder shows the file selected in its folder

  @node
  Scenario: An unknown editor is refused
    When a client opens a folder in an editor id the node does not know
    Then the node fails saying the editor is unknown

  @node
  Scenario: An editor that is not installed is refused
    Given Zed is not installed on the host
    When a client opens a folder in Zed
    Then the node fails naming the command it could not find

  @node
  Scenario: A headless Linux host offers no file manager
    Given a Linux host with no display
    When a client reads the available editors
    Then the file manager is not offered

  @node
  Scenario: Browsing folders to add a project
    Given the home folder has a dev folder holding api, tests, tools, .tmp, .trash and a file todo.txt
    When a client browses "~/dev/t"
    Then the node lists folders in "~/dev" whose names start with "t"
    And hidden folders are left out

  @node
  Scenario: Browsing a folder lists everything in it
    Given the home folder has a dev folder holding api, tests, tools, .tmp, .trash and a file todo.txt
    When a client browses "~/dev/"
    Then the node lists every folder in "~/dev", hidden ones included

  @node
  Scenario: Browsing a folder that does not exist
    When a client browses a path whose parent does not exist
    Then the node fails without listing anything

  @node
  Scenario: The node finds web servers running on the host
    Given a development server is serving HTML on port 5173
    When a client follows the host's local servers
    Then port 5173 is listed

  @node
  Scenario: Ports that do not serve HTML are not listed
    Given a database is listening on port 5432
    When a client follows the host's local servers
    Then port 5432 is not listed

  @node
  Scenario: A server that stops is removed from the list
    Given a client follows the host's local servers with port 5173 listed
    When that server stops
    Then port 5173 is removed from the list

  @node
  Scenario: The node only scans for servers while someone watches
    Given nobody follows the host's local servers
    Then the node does not scan the host's ports

  @node
  Scenario: A symlink loop is reported rather than followed forever
    Given a project path that loops through symlinks
    When the node resolves it
    Then it fails as a symlink loop

  @node
  Scenario: A chatty subprocess is slowed down rather than buffered without end
    Given a provider process writing output faster than the node reads it
    Then the node applies backpressure through the process's pipe
    And its memory stays bounded
