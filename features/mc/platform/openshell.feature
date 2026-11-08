# Sources:
#   https://github.com/hal-c2/hal-c2/issues/1411
#   https://github.com/hal-c2/hal-c2/issues/1417 (the MC's client certificate comes from a CA of its own)
#   https://github.com/hal-c2/hal-c2/issues/1418 (one gateway per HAL-C2 environment)
#   https://github.com/hal-c2/hal-c2/pull/1421 (Copilot review 5819948882: homes, probe cleanup, Docker)
#   apps/server-ex/lib/hal_c2/open_shell.ex (where the gateway's files live, the owner label)
#   apps/server-ex/lib/hal_c2/open_shell/install.ex (install, update, rollback, drain, rotate, reuse, smoke, status, uninstall)
#   apps/server-ex/lib/hal_c2/open_shell/platform.ex (the support matrix, rootless runtimes only)
#   apps/server-ex/lib/hal_c2/open_shell/manifest.ex (the pinned release and its hashes)
#   apps/server-ex/lib/hal_c2/open_shell/config.ex (mTLS only, telemetry off, the pids limit)
#   apps/server-ex/lib/hal_c2/open_shell/service.ex (the gateway's systemd user unit and launchd agent)
#   apps/server-ex/lib/hal_c2/open_shell/client.ex (openshell.v1 over mTLS)
#   apps/server-ex/lib/hal_c2/open_shell/command.ex, apps/server-ex/lib/mix/tasks/hal_c2.openshell.ex
#   apps/server-ex/rel/overlays/bin/hal-c2-service (hal-c2-service openshell ...)
#   mise-tasks/openshell/_default (the dev run)
#   docs/user/openshell.md
#   docs/operations/openshell.md

Feature: The OpenShell gateway review sandboxes run in
  An MC installs NVIDIA OpenShell's gateway at a version HAL-C2 pinned, runs it as the
  user's own service on loopback, and talks to it only over mutual TLS with a client
  identity that is not an operator. It refuses machines it cannot run it safely on, puts
  the previous gateway back when an update fails its check, and touches only the
  sandboxes it labelled as its own. A gateway belongs to one HAL-C2 environment: the MC
  refuses one that holds another environment's sandboxes, and leaves those alone. Each
  HAL-C2 home on a machine runs a gateway of its own, under a service of its own.

  Background:
    Given a Linux machine with rootless Podman

  @mc
  Scenario: Installing runs the gateway as the user's own service
    When the user installs OpenShell
    Then the gateway runs as a service of the user's, on loopback
    And its keys are readable by the user alone, and the CA's key is gone
    And the gateway accepts only mutual TLS, with no operator identity
    And the gateway sends no telemetry

  @mc
  Scenario: The gateway trusts the MC's client certificate and not its own
    When the user installs OpenShell
    Then the MC's client certificate comes from a CA that is not the gateway's
    And the gateway is set to trust only that CA's certificates as clients
    And no CA's key is left

  @mc
  Scenario Outline: A machine OpenShell cannot run on safely is refused before anything is fetched
    Given a machine that <machine>
    When the user installs OpenShell
    Then the install is refused because "<problem>"
    And no gateway is installed

    Examples:
      | machine                                 | problem              |
      | is an Intel Mac                         | intel-mac            |
      | is Linux on riscv64                     | unsupported-arch     |
      | is Linux without Landlock               | landlock-missing     |
      | has no Podman                           | podman-missing       |
      | runs Podman as root                     | runtime-not-rootless |
      | names the root Docker daemon's socket   | root-docker          |

  @mc
  Scenario: A gateway archive that is not the pinned one is refused
    When the user installs OpenShell from an archive whose hash is not the pinned one
    Then the install is refused because "hash-mismatch"
    And no gateway is installed

  @mc
  Scenario: An archive holding anything but the gateway is refused
    When the user installs OpenShell from an archive that also holds another file
    Then the install is refused because "bad-archive"
    And no gateway is installed

  @mc
  Scenario: A gateway whose configuration fails its preflight is not installed
    Given the gateway rejects its configuration
    When the user installs OpenShell
    Then the install is refused because the preflight failed
    And no gateway is installed

  @mc
  Scenario: An update whose new gateway fails its check puts the previous one back
    Given OpenShell 0.1.6 is installed and has a database
    When the user updates to OpenShell 0.1.7 and the new gateway fails its check
    Then the user is told the previous gateway is back in place
    And OpenShell 0.1.6 runs with its database, certificates and service as they were

  @mc
  Scenario: An update waits for this MC's sandboxes, and a drain removes only those
    Given an OpenShell gateway this MC runs, with a sandbox of this MC's and one of someone else's
    When the user updates OpenShell
    Then the update is refused because "sandboxes-running"
    When the user updates OpenShell with a drain
    Then the update succeeds
    And only the other sandbox remains

  @mc
  Scenario: An update whose gateway will not stop changes nothing
    Given OpenShell 0.1.6 is installed and has a database
    And the gateway's service will not stop
    When the user updates to OpenShell 0.1.7
    Then the install is refused because "gateway-stop-failed"
    And OpenShell 0.1.6 runs with its database, certificates and service as they were

  @mc
  Scenario: An update waits while this MC's sandboxes cannot be counted, unless forced
    Given an OpenShell gateway this MC runs that does not answer the MC, with a sandbox of this MC's and one of someone else's
    When the user updates OpenShell with a drain
    Then the update is refused because "sandboxes-unknown"
    When the user updates OpenShell with force
    Then the update succeeds

  @mc
  Scenario: The dev run's gateway is not changed while it runs
    Given a developer has staged the gateway with the dev run, and it is running
    When the user rotates the gateway's certificates
    Then the MC refuses because "gateway-running"
    And the gateway has its old certificates

  @mc
  Scenario: Rotating the certificates restarts the gateway on new ones
    Given OpenShell is installed
    When the user rotates the gateway's certificates
    Then the gateway has new certificates, and the CA's key is gone
    And the gateway's service restarted

  @mc
  Scenario: Rotating the certificates replaces the client certificate's CA too
    Given OpenShell is installed
    When the user rotates the gateway's certificates
    Then the MC's client certificate comes from a new CA of its own
    And no CA's key is left

  @mc
  Scenario: A rotation whose gateway fails its check keeps the old certificates
    Given OpenShell is installed
    When the user rotates the gateway's certificates and the gateway fails its check
    Then the user is told the previous certificates are back in place
    And the gateway has its old certificates

  @mc
  Scenario: The check after start keeps a sandbox from reaching the gateway or the runtime
    Given a gateway whose sandboxes can reach the container runtime's socket
    When the MC checks the gateway
    Then the check fails because "sandbox-not-isolated"
    And the probe sandbox is deleted

  @mc
  Scenario: The check after start refuses an operator identity
    Given a gateway that gives the MC an operator's identity
    When the MC checks the gateway
    Then the check fails because "operator-identity"

  @mc
  Scenario: A check whose probe sandbox cannot be deleted fails
    Given a gateway that does not delete the check's sandboxes
    When the MC checks the gateway
    Then the check fails because "probe-cleanup-failed"
    And the probe sandbox is left, labelled as the check's

  @mc
  Scenario: A probe sandbox an earlier check left is deleted before the next check
    Given a gateway with a probe sandbox an earlier check left
    When the MC checks the gateway
    Then the check passes
    And the probe sandbox is deleted

  @mc
  Scenario: A gateway the user runs is used once it passes the checks
    Given a gateway the user runs, with its CA and a client certificate
    When the user points the MC at it
    Then the MC uses that gateway without running one of its own
    When the user uninstalls OpenShell
    Then the MC forgets the gateway and leaves its sandboxes alone

  @mc
  Scenario: A gateway that holds another HAL-C2 environment's sandboxes is refused
    Given a gateway the user runs, with another HAL-C2 environment's sandbox on it
    When the user points the MC at it
    Then the MC refuses because "shared-gateway"
    And no gateway is installed
    And the MC made no sandbox there and left the other environment's alone

  @mc
  Scenario: A refused gateway leaves the one the MC already uses
    Given a gateway the user runs, with its CA and a client certificate
    And the user points the MC at it
    And a second gateway with another HAL-C2 environment's sandbox on it
    When the user points the MC at the second gateway
    Then the MC refuses because "shared-gateway"
    And the MC still uses the first gateway

  @mc
  Scenario: A gateway that becomes shared later is reported and gets no new sandboxes
    Given a gateway the user runs, with its CA and a client certificate
    And the user points the MC at it
    When another HAL-C2 environment makes a sandbox on that gateway
    And the user asks for OpenShell's status
    Then the status says "gateway-shared"
    And the MC connects but makes no sandbox there, and leaves the other environment's alone

  @mc
  Scenario: A gateway without TLS is never used
    When the user points the MC at a plaintext gateway
    Then the MC refuses because "plaintext-refused"
    And no gateway is installed

  @mc
  Scenario: Status names what needs attention
    When the user asks for OpenShell's status
    Then the status says "not-installed"
    Given OpenShell is installed
    When the user asks for OpenShell's status
    Then the status says "gateway-unreachable"

  @mc
  Scenario: The dev run runs the gateway in the foreground, not as a service
    Given OpenShell is installed as a service
    When a developer starts the gateway with the dev run
    Then the gateway runs in the foreground without telemetry it inherited
    And no service of the gateway's is left

  @mc
  Scenario: Two HAL-C2 homes on one machine each run a gateway of their own
    Given OpenShell is installed
    And another HAL-C2 home on this machine has installed OpenShell
    When the other home updates its OpenShell and then uninstalls it
    Then the other home never asked the service manager about this home's service
    And this home's gateway, service and certificates are as they were

  @mc
  Scenario: A service under this home's name that another home wrote is left alone
    Given OpenShell is installed
    And the service under this home's name runs another HAL-C2 home's gateway
    When the user installs OpenShell
    Then the install is refused because "unit-not-ours"
    And the service manager was asked nothing
    When the user asks for OpenShell's status
    Then the status says "service-not-ours"

  @mc
  Scenario: Uninstalling removes the gateway and its files
    Given OpenShell is installed
    When the user uninstalls OpenShell
    Then no gateway is installed
    And the gateway's service is gone

  # https://github.com/hal-c2/hal-c2/issues/1420: an RPC for the status, then each client's settings.
  @mc @shared @backlog
  Scenario: Settings shows whether review sandboxes can run, and what to fix
    Given a machine that is an Intel Mac
    When the user opens the sandbox settings
    Then they read that OpenShell does not run on an Intel Mac
