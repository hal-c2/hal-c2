# Sources:
#   docs/user/install.md
#   docs/user/background-service.md (hal-c2 update, hal-c2 uninstall, macOS Full Disk Access)
#   apps/server/src/cli (hal-c2, hal-c2 serve, hal-c2 update, hal-c2 uninstall, hal-c2 app)
#   apps/server/src/bin.ts
#   apps/server-ex/rel/overlays/bin/hal-c2-service

Feature: Installing and uninstalling
  The user installs the server with one command, tries it without installing,
  keeps it current from the command line, and can remove it without losing
  their data.

  # Blocked: how does a release reach the user's machine? The install script and the
  # `hal-c2 update` and `hal-c2 uninstall` commands belong to the legacy CLI.
  @backlog @blocked @node
  Scenario Outline: The install script puts hal-c2 on the machine
    When the user runs the install script <options>
    Then hal-c2 <result> is installed in the user's local bin folder
    And the user is told how to add it to their PATH if it is missing

    Examples:
      | options                 | result                 |
      | with no options         | from the stable channel |
      | on the nightly channel  | from the nightly channel |
      | pinned to "1.3.0"       | at version "1.3.0"     |

  # Dropped: a release runs under the operating system's service manager
  # (background-service.feature) and a checkout under a mise daemon. There is no web app
  # to open and no npm package to run.
  @dropped @node
  Scenario Outline: The user starts the server
    When the user runs "<command>"
    Then the server starts <how>

    Examples:
      | command         | how                           |
      | hal-c2              | and opens the web app          |
      | hal-c2 serve        | without opening anything       |
      | npx hal-c2@latest   | without installing it          |

  # Blocked: how does a release reach the user's machine? The install script and the
  # `hal-c2 update` and `hal-c2 uninstall` commands belong to the legacy CLI.
  @backlog @blocked @node
  Scenario Outline: The user updates from the command line
    When the user runs "<command>"
    Then <result>

    Examples:
      | command                            | result                                             |
      | hal-c2 update                          | the user is asked before the service restarts      |
      | hal-c2 update --yes                    | the service restarts on the new version unasked    |
      | hal-c2 update 1.2.0 --allow-downgrade  | the server moves back to version 1.2.0             |
      | hal-c2 update --channel preview        | the user is asked to confirm the preview channel   |

  # Blocked: how does a release reach the user's machine? The install script and the
  # `hal-c2 update` and `hal-c2 uninstall` commands belong to the legacy CLI.
  @backlog @blocked @node
  Scenario: Declining the restart leaves the old server running
    When the user runs "hal-c2 update" and declines the restart
    Then the old version keeps running until the user restarts the service

  # Blocked: how does a release reach the user's machine? The install script and the
  # `hal-c2 update` and `hal-c2 uninstall` commands belong to the legacy CLI.
  @backlog @blocked @node
  Scenario: Uninstalling keeps the user's data
    When the user runs "hal-c2 uninstall"
    Then the user is shown everything that will be removed and asked once
    And after confirming hal-c2 and its service are removed
    But the user's threads and settings are kept

  # Blocked: how does a release reach the user's machine? The install script and the
  # `hal-c2 update` and `hal-c2 uninstall` commands belong to the legacy CLI.
  @backlog @blocked @node
  Scenario: An Intel Mac has no prebuilt server
    Given an Intel Mac
    When the user runs the install script
    Then the user is told to build the server from source

  @backlog @desktop
  Scenario: The user opens a folder in the desktop app from the terminal
    Given the desktop app is running
    When the user runs "hal-c2 app ~/code/api"
    Then the desktop app opens a new thread for "api", adding the project if needed
    But if the desktop app cannot be reached the command fails with an error

  @backlog @node
  Scenario: The background service on macOS needs Full Disk Access for protected folders
    Given the background service runs on macOS without Full Disk Access
    And a project lives in the user's Documents folder
    When an agent works in that project
    Then the agent cannot read the project
    When the user grants Full Disk Access to the hal-c2 executable the service runs
    Then the agent can work in the project
