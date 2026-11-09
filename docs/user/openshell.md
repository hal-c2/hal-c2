# Sandboxes for code reviews (OpenShell)

HAL-C2 runs the agent of a code review of an untrusted pull request inside a
sandbox, so that the code under review cannot reach your files, your credentials or
the rest of your machine. For now no pull request is trusted, so every review runs
in one. The sandboxes come from [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell).
This page sets up its gateway: the MC installs it at a version HAL-C2 has checked,
runs it as a service of your own user, and talks to it only over mutual TLS.

> **A review needs the gateway.** On an MC without it, a review of an untrusted
> pull request fails and says to install it; it never runs on your machine instead.
> [Code review](code-review.md#reviews-in-a-sandbox) covers what a sandboxed review
> can reach and how it ends.

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
`DOCKER_HOST` is not read; name the socket in `HAL_C2_OPENSHELL_DOCKER_SOCKET`. A
socket that Podman answers on is used as Podman. Docker Desktop for Linux is refused,
since its daemon runs as root in its VM.

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
If the gateway is running but cannot say which sandboxes it holds
(`sandboxes-unknown`), they wait too; `--force` goes ahead anyway and ends any that
run. If the gateway's service does not stop (`gateway-stop-failed`), or its files
cannot be backed up first (`backup-failed`), nothing is changed and the service
keeps running.

One OpenShell command runs at a time on an MC. Another `install`, `rotate`,
`reuse`, `uninstall` or `check` started meanwhile stops at once (`busy`) and
changes nothing; run it again once the first finishes. `status` always answers.

A gateway started with `mise run openshell` must be stopped before you update,
rotate or uninstall it (`gateway-running`). After a rotation, start it again to use
the new certificates.

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

A reused gateway has no reaper of this home's (see below), so the MC runs no review
sandbox there until you run `install`.

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
- The API key reaches the sandbox only through a provider profile HAL-C2 adds to the
  gateway, `hal-c2-claude` or `hal-c2-codex`, which sends it to nothing but the
  model's API. If the gateway already has a profile by that id that differs, the
  review does not start: delete that profile from the gateway and HAL-C2 adds its own.
- A review's token budget counts everything the model reads, cached prompts and
  subagents included.
- A review sandbox has 2 GiB for the checkout (`/sandbox`) and 512 MiB for `/tmp`,
  held in memory. It needs OpenShell's Podman or Docker driver, the ones that can
  bound it, and a gateway that leaves its disk unbounded gets no review.
- A review sandbox is deleted once its time limit has passed, even while the MC is
  not running: `install` adds a timer beside the gateway's service that runs
  `hal-c2-service openshell reap` every minute. When the MC starts, it deletes the
  review sandboxes it left behind. Each HAL-C2 home on the machine has a timer of its
  own, which deletes only that home's sandboxes. If the timer's log shows
  `reaper-wrong-home`, run `install` again from that home. When the gateway would not
  delete a sandbox or its provider in time, the log names each one left behind, and
  the next run tries again. Without the timer the MC starts no review sandbox.

## When status reports a problem

`status` prints a code with each problem and what to do about it:

| Code                                                                                                                       | What to do                                                                                              |
| -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `not-installed`                                                                                                            | Run `install`.                                                                                          |
| `update-available`, `version-mismatch`                                                                                     | Run `install` to move to the version this MC pins.                                                      |
| `service-missing`, `service-outdated`                                                                                      | Run `install` to rewrite the gateway's service.                                                         |
| `service-not-ours`                                                                                                         | The service under this home's name runs another HAL-C2 home's gateway. Uninstall OpenShell there first. |
| `home-moved`                                                                                                               | Installed when this home was at another path, whose service is still there. Remove it, run `install`.   |
| `service-stopped`, `gateway-unreachable`                                                                                   | Read the gateway's log (`status` prints where), then run `install`.                                     |
| `gateway-shared`                                                                                                           | Another HAL-C2 environment uses this gateway. Give each one its own.                                    |
| `intel-mac`, `unsupported-os`, `unsupported-arch`                                                                          | This machine cannot run OpenShell.                                                                      |
| `glibc-too-old`, `kernel-too-old`, `landlock-missing`                                                                      | Update the system, or enable Landlock in the kernel's `lsm=` boot parameter.                            |
| `podman-missing`, `podman-too-old`, `runtime-not-rootless`, `root-docker`, `docker-desktop-linux`, `docker-socket-missing` | Set up rootless Podman 5, or a rootless Docker daemon.                                                  |
| `docker-desktop-missing`, `docker-too-old`, `podman-on-mac`                                                                | Install and start Docker Desktop 28 or later.                                                           |
| `runtime-unreachable`                                                                                                      | Start the container runtime.                                                                            |
