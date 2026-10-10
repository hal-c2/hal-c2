# Releases

> For maintainers. Using HAL-C2? See [docs/user](../user/).

HAL-C2 ships the MC, the Qt desktop and the TUI.

## Building one locally

```sh
mise run release:mc      # release/hal-c2-mc-<version>-<platform>: the single-file MC, and its .tar.gz upgrade bundle
mise run release:linux   # the same, plus release/hal-c2-qt-<version>-linux-x64.AppImage
mise run release:macos   # the same, plus release/hal-c2-qt-<version>-darwin-<arch>.zip, holding HAL-C2.app
```

The macOS app is signed ad hoc, not with a Developer ID: it runs on the Mac that built it, and
Gatekeeper refuses it on a Mac that downloaded it.

A local build is versioned `<package version>-local.<commit time>.g<commit>` unless
`HAL_C2_MC_VERSION` names one, so machines that build the same commit run the same version and
can join one cluster. A checkout with uncommitted changes gets `-local.<UTC timestamp>` instead:
a single-file MC only unpacks a version it has not installed before, and that build clusters with
no other.

`mise run release:install` builds and installs it for your user. The MC becomes the systemd user
unit `hal-c2.service`, or on macOS the launch agent `io.github.halc2.service`
([Running HAL-C2 in the background](../user/background-service.md)),
unpacked into `~/.local/share/hal-c2/elixir/release`. It listens on 3790, and for cluster
members on 4380, and keeps its files in the `hal-c2` profile, so the dev MC (3780 and 4370,
`hal-c2-dev`) can stay up beside it. On x86_64 Linux the
desktop AppImage goes to `~/.local/bin/hal-c2` with a launcher entry, and on macOS the app to
`~/Applications/HAL-C2.app`. It uses the service's MC rather than starting the one it carries,
because that MC already runs on the same files.

The installed MC's cluster is managed through
`~/.local/share/hal-c2/elixir/release/bin/hal-c2-service cluster` (`invite`, `join LINK`,
`remove MEMBER`), as `mise run mc:cluster` does for the dev MC.

Once the service runs, `mise run mc:reload --release` builds this checkout and moves the service to
it, in place when the change allows and through a restart when it does not.

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

## HAL-C2 Connect relay

`.github/workflows/deploy-relay.yml` deploys Alchemy stage `prod`. It runs only when dispatched, since
the fork has no production relay yet. The relay is versioned separately from client releases.

Required repository variables:

- `CLOUDFLARE_ACCOUNT_ID`
- `PLANETSCALE_ORGANIZATION`
- `AXIOM_ORG_ID`

Required repository secrets:

- `CLOUDFLARE_API_TOKEN`
- `PLANETSCALE_API_TOKEN_ID`
- `PLANETSCALE_API_TOKEN`
- `AXIOM_TOKEN`

Required `production` environment variables:

- `RELAY_API_ZONE_NAME`
- `RELAY_TUNNEL_ZONE_NAME`
- `CLERK_PUBLISHABLE_KEY`
- `CLERK_JWT_AUDIENCE`
- `APNS_ENVIRONMENT`
- `APNS_TEAM_ID`
- `APNS_KEY_ID`
- `APNS_BUNDLE_ID`
- `RELAY_DOMAIN`, optional, when overriding the derived `relay.<RELAY_API_ZONE_NAME>` domain

Required `production` environment secrets:

- `CLERK_SECRET_KEY`
- `APNS_PRIVATE_KEY`
- `FCM_SERVICE_ACCOUNT` when Android push is enabled

The account-scoped repository credentials are consumed by Alchemy while provisioning relay stages;
they are not bound into the relay Worker. The production deployment uses an Axiom personal access
token, so `AXIOM_ORG_ID` must accompany `AXIOM_TOKEN`. The `prod` stage owns the retained PlanetScale
database. Local personal stages provision isolated branches from it. Production adopts the
configured relay API and tunnel DNS zones as retained Cloudflare resources; personal stages
reference the production-owned zones.

Developers deploy personal stages locally:

```sh
vp run --filter hal-c2-relay deploy -- --stage "$USER" --env-file .env.local
```
