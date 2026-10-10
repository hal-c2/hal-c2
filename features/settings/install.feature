# Sources:
#   docs/user/install.md
#   docs/user/background-service.md (hal-c2 update, hal-c2 uninstall, macOS Full Disk Access)
#   apps/server/src/cli (hal-c2, hal-c2 serve, hal-c2 update, hal-c2 uninstall, hal-c2 app)
#   apps/server/src/bin.ts
#   apps/server-ex/rel/overlays/bin/hal-c2-service
#   scripts/install.sh, scripts/install.ps1 (checksum, channels, platform checks, shim, progress)
#   scripts/install.test.ts (download progress and failure behaviour)
#   packages/shared/src/cliRelease.ts (platform keys, channel of a version, mirror variable)

Feature: Installing and uninstalling
  The user installs the server with one command, tries it without installing,
  keeps it current from the command line, and can remove it without losing
  their data.

  # Blocked: how does a release reach the user's machine? The install script and the
  # `hal-c2 update` and `hal-c2 uninstall` commands belong to the legacy CLI.
  @backlog @blocked @mc
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
  @dropped @mc
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
  @backlog @blocked @mc
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
  @backlog @blocked @mc
  Scenario: Declining the restart leaves the old server running
    When the user runs "hal-c2 update" and declines the restart
    Then the old version keeps running until the user restarts the service

  # Blocked: how does a release reach the user's machine? The install script and the
  # `hal-c2 update` and `hal-c2 uninstall` commands belong to the legacy CLI.
  @backlog @blocked @mc
  Scenario: Uninstalling keeps the user's data
    When the user runs "hal-c2 uninstall"
    Then the user is shown everything that will be removed and asked once
    And after confirming hal-c2 and its service are removed
    But the user's threads and settings are kept

  # Blocked: how does a release reach the user's machine? The install script and the
  # `hal-c2 update` and `hal-c2 uninstall` commands belong to the legacy CLI.
  @backlog @blocked @mc
  Scenario: An Intel Mac has no prebuilt server
    Given an Intel Mac
    When the user runs the install script
    Then the user is told to build the server from source

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  # The MC's updater carries this as "A bundle that does not match its checksum is refused" (mc/platform/upgrades.feature).
  @dropped @mc
  Scenario: The install script refuses an archive that does not match its published checksum
    Given the release archive does not match the SHA-256 published for it
    When the user runs the install script
    Then the installer refuses the archive
    And nothing is installed

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  # The MC's updater carries this as "A download cut off midway leaves no half-installed version" (mc/platform/upgrades.feature).
  @dropped @mc
  Scenario: A download that fails or is cancelled part way leaves nothing installed
    Given the release archive download fails or is cancelled part way
    When the user runs the install script
    Then the installer reports the failure
    And no version is recorded as installed
    And the hal-c2 command is left as it was

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  # The MC's updater carries this as "A bundle is taken from the MC's own cache first" (mc/platform/upgrades.feature).
  @dropped @mc
  Scenario: Running the install script again for an installed version downloads nothing
    Given version "1.2.3" is already installed
    When the user runs the install script for "1.2.3"
    Then nothing is downloaded
    And the hal-c2 command runs "1.2.3"

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  # The MC's updater carries this as "Two installs of one version never run side by side" (mc/platform/upgrades.feature).
  @dropped @mc
  Scenario: A newer install keeps the older version and moves the hal-c2 command to the new one
    Given version "1.2.3" is installed
    When the user runs the install script for "1.3.0"
    Then the hal-c2 command runs "1.3.0"
    And "1.2.3" is still installed

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  @dropped @mc
  Scenario: A stable install never picks up a nightly or preview build
    Given the newest nightly and preview builds are newer than the newest stable release
    When the user runs the install script with no options
    Then the installer installs the newest stable release

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  @dropped @mc
  Scenario Outline: A preview build is installed only when the user asks for it by channel or version
    When the user runs the install script <options>
    Then the installer warns that preview builds can be broken and receive no fixes
    And the installer <result>

    Examples:
      | options                     | result                              |
      | on the preview channel      | installs the newest preview build   |
      | pinned to a preview version | installs that version               |

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  @dropped @mc
  Scenario: An unknown release channel is refused before anything downloads
    When the user runs the install script on the "beta" channel
    Then the installer says the channel must be stable, nightly or preview
    And nothing is downloaded

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  @dropped @mc
  Scenario: A pinned version with no archive for this machine says how to install it another way
    Given release "1.2.3" has no archive for this machine
    When the user pins "1.2.3" with the install script
    Then the installer stops and names "npm install -g hal-c2@1.2.3" as the other way to install it

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  @dropped @mc
  Scenario Outline: A machine HAL-C2 has no command-line server for is refused
    Given the machine runs <system>
    When the user runs the install script
    Then the installer stops and <result>

    Examples:
      | system         | result                                             |
      | FreeBSD        | says to use the desktop app or npm instead         |
      | 32-bit Linux   | says the architecture is not supported             |
      | 32-bit Windows | says the architecture is not supported             |

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  # The MC's updater carries this as "The bundle location can be overridden" (mc/platform/upgrades.feature).
  @dropped @mc
  Scenario: An operator installs from a mirror of the release downloads
    Given the release downloads are mirrored at "https://mirror.example/hal-c2"
    When the user pins "1.2.3" and runs the install script with that mirror
    Then the archive and its checksums come from the mirror

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  @dropped @mc
  Scenario: On Windows the hal-c2 command is a shim that runs the installed version
    Given the user runs the Windows install script
    When the install finishes
    Then a hal-c2 command in the user's local bin folder runs the installed version

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  @dropped @mc
  Scenario: The background service reuses a version the install script already downloaded
    Given the install script downloaded version "1.2.3"
    When the user installs the background service on that machine
    Then the service runs "1.2.3" without downloading it again

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  @dropped @mc
  Scenario: A download shows how much of the archive has arrived
    When the user runs the install script in a terminal
    Then the download shows a percentage and the megabytes received out of the total

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  @dropped @mc
  Scenario: Output that is not a terminal is plain lines with no progress bar
    When the user runs the install script with its output going to a file
    Then each step is printed on a line of its own
    And no progress bar is written

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  @dropped @mc
  Scenario Outline: The install script stops when a tool it needs is missing
    Given the machine has no <tool>
    When the user runs the install script
    Then the installer stops and says "<tool> is required"

    Examples:
      | tool                |
      | tar                 |
      | sha256sum or shasum |
      | curl or wget        |

  # Dropped: scripts/install.sh and install.ps1 are gone and no release publishes what they
  # installed; releases ship only the single-file MC bundle (.github/workflows/release-mc.yml).
  @dropped @mc
  Scenario: An old home named in HAL_C2_HOME is not installed into
    Given HAL_C2_HOME is set to the T3 Code home "~/.t3"
    When the user runs the install script
    Then the CLI is installed in the default data directory instead

  @backlog @desktop
  Scenario: The user opens a folder in the desktop app from the terminal
    Given the desktop app is running
    When the user runs "hal-c2 app ~/code/api"
    Then the desktop app opens a new thread for "api", adding the project if needed
    But if the desktop app cannot be reached the command fails with an error

  @backlog @mc
  Scenario: The background service on macOS needs Full Disk Access for protected folders
    Given the background service runs on macOS without Full Disk Access
    And a project lives in the user's Documents folder
    When an agent works in that project
    Then the agent cannot read the project
    When the user grants Full Disk Access to the hal-c2 executable the service runs
    Then the agent can work in the project
