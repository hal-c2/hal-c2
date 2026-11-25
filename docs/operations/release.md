# Releases

> For maintainers. Using HAL-C2? See [docs/user](../user/).

HAL-C2 ships the MC, the Qt desktop, the desktop on Ljós (`apps/desktop-ljos`) and the TUI.

## Building one locally

```sh
mise run release:mc            # release/hal-c2-mc-<version>-<platform>: the single-file MC, and its .tar.gz upgrade bundle
mise run release:linux         # the same, plus release/hal-c2-qt-<version>-linux-x64.AppImage
mise run release:macos         # the same, plus release/hal-c2-qt-<version>-darwin-<arch>.zip, holding HAL-C2.app
mise run release:desktop-ljos  # the same, plus release/hal-c2-ljos-<version>-<platform>/, laid out as it is installed
```

The macOS apps are signed ad hoc, not with a Developer ID: they run on the Mac that built them, and
Gatekeeper refuses them on a Mac that downloaded them.

The Ljós desktop's QML is compiled into `hal-c2-ljos`. It is built with `HAL_C2_RELEASE` set, which
makes it read the bundled MC and Node (for the MC's sidecars) from `share/hal-c2` beside its `bin/`
(`Resources/hal-c2` in the macOS bundle) instead of the checkout — its desktop host is in process — and gives its window the app id `hal-c2-ljos`, so it does
not take desktop-qt's `hal-c2` entry. On Linux CEF's runtime sits beside the binary; the macOS bundle
does not carry CEF yet, so its browser tabs show no pages ([README](../../apps/desktop-ljos/README.md#browser-pages)). The build ends with `hal-c2-ljos --check`,
which fails when a QML file of the checkout is missing from the binary.

A local build is versioned `<package version>-local.<commit time>.g<commit>` unless
`HAL_C2_MC_VERSION` names one, so machines that build the same commit run the same version. A
checkout with uncommitted changes under `apps/server-ex`, `packages` or `native` gets
`-local.<UTC timestamp>` instead, since a single-file MC only unpacks a version it has not
installed before. Machines cluster whatever versions they run.

## Installing it for your user

```sh
mise run release:install               # all of the below this machine builds, the MC release built once
mise run release:install:mc            # the MC, as the background service
mise run release:install:desktop-qt    # ~/.local/bin/hal-c2 with hal-c2.desktop (x86_64 Linux), ~/Applications/HAL-C2.app (macOS)
mise run release:install:desktop-ljos  # ~/.local/bin/hal-c2-ljos with hal-c2-ljos.desktop (Linux), ~/Applications/HAL-C2 Ljós.app (macOS)
```

Each builds only what it installs. The MC becomes the systemd user unit `hal-c2.service`, or on
macOS the launch agent `io.github.halc2.service`
([Running HAL-C2 in the background](../user/background-service.md)),
unpacked into `~/.local/share/hal-c2/elixir/release`. It listens on 3790, and for cluster
members on 4380, and keeps its files in the `hal-c2` profile, so the dev MC (3780 and 4370,
`hal-c2-dev`) can stay up beside it. The Ljós desktop on Linux is a directory,
`~/.local/lib/hal-c2-ljos`, which `~/.local/bin/hal-c2-ljos` links to. Both desktops carry an MC
but use the service's when it runs, because that MC already runs on the same files; on one home
they are one app to a later launch, so a folder opened while either runs goes to that window.

The TUI and the phone app have no install yet ([#1631](https://github.com/hal-c2/hal-c2/issues/1631),
[#1632](https://github.com/hal-c2/hal-c2/issues/1632)).

The installed MC's cluster is managed through
`~/.local/share/hal-c2/elixir/release/bin/hal-c2-service cluster` (`invite`, `join LINK`,
`remove MEMBER`), as `mise run mc:cluster` does for the dev MC.

Once the service runs, `mise run mc:reload --release` builds this checkout and moves the service to
it, in place when the change allows and through a restart when it does not.

### In a container

`mise run mc:container` builds this checkout's MC into an image (`apps/server-ex/rel/Containerfile`,
on Ubuntu 24.04 like the published bundles, so it can still update itself) and runs it as the
container `hal-c2-mc` under Podman, or Docker with `--engine docker`. It publishes on
`127.0.0.1:3790` (`--host`, `--port`) and keeps everything on the `hal-c2-mc` volume: the MC's
files, and a home for provider CLIs and their logins, which the image does not carry. Install a
provider with `podman exec -it hal-c2-mc npm install -g <package>` (or its own installer) and log in
the same way; SSH keys for git remotes go in the container's `~/.ssh`. The container sees only
directories named with `--workspace <dir>`, mounted at the same path, so projects outside them must
be cloned into the MC; it runs without SELinux separation, so they need no relabelling. It runs as
you, under an account the image gives your uid, and rootless Podman keeps mounted files yours; under
Podman it comes back after a reboot only with `systemctl --user enable podman-restart.service`.

Running the task again rebuilds and replaces the container, keeping the volume. `pair` prints a link
for the published address (on `--host 0.0.0.0`, name the address another machine reaches: `mise run
mc:container pair http://<address>:3790`), and other commands such as `cluster` run the MC's own
command inside it (`mise run mc:container pair -- --ttl 1h`). `doctor` stops the MC, checks its
store from a container of its own and starts it again. Importing threads finds nothing, since the
container has no T3 Code or older HAL-C2 install to read. `status`, `logs`, `restart` and
`uninstall` manage the container; uninstall leaves the volume, which `podman volume rm hal-c2-mc`
deletes. Cluster traffic is not published, so a containerised MC does not cluster yet.

## MC

`.github/workflows/release-mc.yml` publishes the bundles MCs update from (`HalC2.Upgrade`):
`hal-c2-mc-<version>-<platform>.tar.gz` and its `.sha256` for `darwin-arm64`, `linux-x64` and
`linux-arm64`, on an `mc-v<version>` prerelease. Push a `mc-v<version>` tag, or dispatch it with
a `version` (defaulting to `apps/server-ex/VERSION`). MCs fetch from that release unless
`HAL_C2_UPGRADE_URL` names another host, and pass bundles on to their cluster peers. See the
[MC README](../../apps/server-ex/README.md#upgrades) for building and sending one by hand.

## Qt desktop

`.github/workflows/desktop-qt.yml` builds and tests an unsigned Linux AppImage on every change to
`main` and every pull request that touches the desktop, and keeps it as a workflow artifact. The
macOS app bundle (`apps/desktop-qt/scripts/package-macos.sh`, as `release:macos` builds it) is
built only when the workflow is dispatched by hand with `macos` checked, since
macOS runners are expensive. Nothing publishes either yet.
