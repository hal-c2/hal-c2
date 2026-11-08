# Sandboxes for code reviews (OpenShell)

HAL-C2 can run the agents of a code review inside sandboxes, so a review of
untrusted code cannot reach your files, your credentials or the rest of your
machine. The sandboxes come from [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell):
the MC installs OpenShell's gateway at a version HAL-C2 has checked, runs it as a
service of your own user, and talks to it only over mutual TLS.

## What your machine needs

| Machine                       | Container runtime                                       |
| ----------------------------- | ------------------------------------------------------- |
| Linux on x86_64 or aarch64    | Podman 5 or later, rootless, as your own user (default) |
| glibc 2.28+, Linux 6.2+, with | or a rootless Docker daemon, named in                   |
| Landlock enabled              | `HAL_C2_OPENSHELL_DOCKER_SOCKET`                        |
| macOS on Apple Silicon        | Docker Desktop 28 or later                              |

Intel Macs are not supported, and neither is an MC running under Rosetta. On Linux,
start Podman's socket with `systemctl --user enable --now podman.socket`.

A Docker daemon that runs as root is always refused, even when you name its socket:
whatever holds that socket controls the machine. Use rootless Podman, or set up
rootless Docker (`dockerd-rootless-setuptool.sh`) and name its socket.

## Set it up

On the machine that runs the MC:

| Task                                  | Command                              |
| ------------------------------------- | ------------------------------------ |
| Install, update or repair the gateway | `hal-c2-service openshell install`   |
| See what is installed and what to fix | `hal-c2-service openshell status`    |
| Run the gateway's checks again        | `hal-c2-service openshell check`     |
| Replace the gateway's certificates    | `hal-c2-service openshell rotate`    |
| Remove it                             | `hal-c2-service openshell uninstall` |

From a checkout, `mise exec -- mix hal_c2.openshell <command>` in `apps/server-ex`
does the same, and `mise run openshell` runs the gateway in the foreground instead
of as a service.

`install` checks the machine before it downloads anything, and after it starts the
gateway it checks that the gateway is the version HAL-C2 pinned, refuses
connections without TLS, gives the MC no operator rights, and keeps a sandbox from
reaching the gateway or the container runtime. If an update fails those checks, the
previous gateway, its certificates and its data are put back.

An update, a rotation or an uninstall waits while this MC has sandboxes running.
Add `--drain` to delete them first. Only the sandboxes this MC created are touched.

### A machine without internet access

`install` downloads the gateway from OpenShell's GitHub release. Without access to
GitHub, download the archive for your machine elsewhere and pass it with
`--archive FILE`; it must match the checksum HAL-C2 pinned. The gateway also pulls
OpenShell's container images from `ghcr.io` and `nvcr.io` the first time a sandbox
starts.

### Use a gateway you already run

`hal-c2-service openshell reuse https://HOST:PORT --ca FILE --cert FILE --key FILE`
points the MC at an OpenShell gateway you run yourself, with that gateway's CA and
a client certificate it trusts. The address must use `https`, and the gateway must
pass the same checks as an installed one. `uninstall` then only makes the MC forget
it; the gateway and its sandboxes are left alone.

### One gateway for each HAL-C2 environment

OpenShell 0.1.7 does not keep one client's sandboxes from another's, so two HAL-C2
environments must not share a gateway. `reuse` refuses a gateway that holds sandboxes
of another HAL-C2 environment (`shared-gateway`). If a gateway you reuse comes to hold
them later, `status` and `check` report `gateway-shared` and this MC makes no new
sandboxes there. The other environment's sandboxes are never touched. Give each
environment a gateway of its own with `install`, or run a second gateway for it.

## What to know

- Telemetry is off: the gateway sends no usage data and exports no traces or logs.
- A review sandbox reaches only the model's API and this MC. It cannot download
  packages, so a review uses the tools its image already has.
- Claude in a sandbox needs an Anthropic API key. A Claude subscription sign-in does
  not work there.

## When status reports a problem

`status` prints a code with each problem and what to do about it:

| Code                                                                      | What to do                                                                   |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `not-installed`                                                           | Run `install`.                                                               |
| `update-available`, `version-mismatch`                                    | Run `install` to move to the version this MC pins.                           |
| `service-missing`, `service-outdated`                                     | Run `install` to rewrite the gateway's service.                              |
| `service-stopped`, `gateway-unreachable`                                  | Read the gateway's log (`status` prints where), then run `install`.          |
| `gateway-shared`                                                          | Another HAL-C2 environment uses this gateway. Give each one its own.         |
| `intel-mac`, `unsupported-os`, `unsupported-arch`                         | This machine cannot run OpenShell.                                           |
| `glibc-too-old`, `kernel-too-old`, `landlock-missing`                     | Update the system, or enable Landlock in the kernel's `lsm=` boot parameter. |
| `podman-missing`, `podman-too-old`, `runtime-not-rootless`, `root-docker` | Set up rootless Podman 5, or a rootless Docker daemon.                       |
| `docker-desktop-missing`, `docker-too-old`                                | Install and start Docker Desktop 28 or later.                                |
| `runtime-unreachable`                                                     | Start the container runtime.                                                 |
