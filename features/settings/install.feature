# Sources:
#   docs/user/install.md
#   docs/user/background-service.md (t3 update, t3 uninstall, macOS Full Disk Access)
#   apps/server/src/cli (t3, t3 serve, t3 update, t3 uninstall, t3 app)
#   apps/server/src/bin.ts
#   apps/server-ex/rel/overlays/bin/t3-service

Feature: Installing and uninstalling
  The user installs the server with one command, tries it without installing,
  keeps it current from the command line, and can remove it without losing
  their data.

  @backlog @node
  Scenario Outline: The install script puts t3 on the machine
    When the user runs the install script <options>
    Then t3 <result> is installed in the user's local bin folder
    And the user is told how to add it to their PATH if it is missing

    Examples:
      | options                 | result                 |
      | with no options         | from the stable channel |
      | on the nightly channel  | from the nightly channel |
      | pinned to "1.3.0"       | at version "1.3.0"     |

  @backlog @node
  Scenario Outline: The user starts the server
    When the user runs "<command>"
    Then the server starts <how>

    Examples:
      | command         | how                           |
      | t3              | and opens the web app          |
      | t3 serve        | without opening anything       |
      | npx t3@latest   | without installing it          |

  @backlog @node
  Scenario Outline: The user updates from the command line
    When the user runs "<command>"
    Then <result>

    Examples:
      | command                            | result                                             |
      | t3 update                          | the user is asked before the service restarts      |
      | t3 update --yes                    | the service restarts on the new version unasked    |
      | t3 update 1.2.0 --allow-downgrade  | the server moves back to version 1.2.0             |
      | t3 update --channel preview        | the user is asked to confirm the preview channel   |

  @backlog @node
  Scenario: Declining the restart leaves the old server running
    When the user runs "t3 update" and declines the restart
    Then the old version keeps running until the user restarts the service

  @backlog @node
  Scenario: Uninstalling keeps the user's data
    When the user runs "t3 uninstall"
    Then the user is shown everything that will be removed and asked once
    And after confirming t3 and its service are removed
    But the user's threads and settings are kept

  @backlog @node
  Scenario: An Intel Mac has no prebuilt server
    Given an Intel Mac
    When the user runs the install script
    Then the user is told to build the server from source

  @backlog @desktop
  Scenario: The user opens a folder in the desktop app from the terminal
    Given the desktop app is running
    When the user runs "t3 app ~/code/api"
    Then the desktop app opens a new thread for "api", adding the project if needed
    But if the desktop app cannot be reached the command fails with an error

  @backlog @node
  Scenario: The background service on macOS needs Full Disk Access for protected folders
    Given the background service runs on macOS without Full Disk Access
    And a project lives in the user's Documents folder
    When an agent works in that project
    Then the agent cannot read the project
    When the user grants Full Disk Access to the t3 executable the service runs
    Then the agent can work in the project
