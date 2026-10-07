# HAL-C2 MC (Elixir)

The Elixir/OTP backend. Each machine runs one MC with its own SQLite event log;
MCs on your machines join a cluster over mutually authenticated TLS and share one
sidebar, so a client connected to any MC sees threads on all of them.

Clients speak orchestration protocol 3 (`HalC2.Web.Protocol`): shape subscriptions over
one WebSocket, resumed from an offset. `packages/client-runtime/src/v3` adapts it to
the existing client state, so an MC pairs and appears like any other environment.

## Run

```sh
mix deps.get
mix hal_c2.import ~/path/to/snapshot/state.sqlite   # optional: a VACUUM INTO copy of a Node server's state
mix hal_c2.server                                    # prints ws://127.0.0.1:3780/ws?token=...
mix hal_c2.pair                                      # one-time pairing URL for Settings → Connections
```

During development the MC keeps its files in the XDG `hal-c2-dev` profile, in the
`elixir` directory of each kind (`~/.local/share/hal-c2-dev/elixir`,
`~/.local/state/hal-c2-dev/elixir/logs`), apart from the installed app's, whichever checkout
or worktree it runs from. It ignores `HAL_C2_HOME`; set `HAL_C2_MC_HOME` to put them
elsewhere. The MC
listens on loopback port 3780 from a checkout and 3790 as a release; `HAL_C2_MC_PORT` and
`HAL_C2_MC_HOST` (a LAN or tailnet address, for pairing other devices; `HAL_C2_HOST` also
works) change that.

## Release

```sh
MIX_ENV=prod mix release        # _build/prod/rel/hal_c2, about 80 MB with ERTS
_build/prod/rel/hal_c2/bin/hal_c2 start # foreground; data in ~/.local/share/hal-c2/elixir
```

A release shares the XDG directories with the Node server
([where HAL-C2 keeps its files](../../docs/user/install.md#where-hal-c2-keeps-its-files)) and
keeps its own files one `elixir` level down in each, such as `~/.local/share/hal-c2/elixir`
for its database and `~/.local/state/hal-c2/elixir/logs`; `HAL_C2_HOME` moves all four under
one root. `HAL_C2_MC_HOME` is a root for the MC alone, with no `elixir` level, and
outranks `HAL_C2_HOME`. On first start with no data, an MC copies its files once from an old
home's `elixir` directory (`T3CODE_HOME` or `T3_HOME`, else `~/.hal-c2`, else `~/.t3`), turning
`t3.sqlite` into `hal-c2.sqlite`, and never reads the old home again
([storage-migration.feature](../../features/mc/platform/storage-migration.feature)).

The release carries the Cursor sidecar (`packages/cursor-acp`, bundled with its
dependencies for the build machine's platform), so building one needs `npm` and the JS
workspace installed (`vp i`, for its esbuild), and running Cursor needs Node 22+ on the
machine. The desktop app runs it on its own
Electron binary instead (`HAL_C2_NODE_COMMAND`).

Run it as a service with `bin/hal-c2-service` (under launchd, systemd, or a terminal): it
is `bin/hal_c2 start`, started again when the MC restarts to finish an update.
`bin/hal-c2-service install` registers it as a systemd user unit (Linux) or launch agent
(macOS) that starts on login; `status` and `uninstall` inspect and remove it.

A machine without Elixir or Erlang runs the single-file MC published beside each bundle,
`hal-c2-mc-<version>-<platform>`: a shell script with the bundle appended
(`rel/hal-c2-mc.sh`). Its first run unpacks the release into `release/` in the MC's data
directory; every run then starts `bin/hal-c2-service` there with the file's arguments, so
`hal-c2-mc-… install` registers the unpacked release as the service. Upgrades install into
that same release, and running the file again starts whatever version the MC last moved to.
A file of a version not yet installed moves the MC to it.

## Upgrades

An MC carries the HAL-C2 version (`apps/server/package.json`, or `HAL_C2_MC_VERSION` for a
build of its own), and clients offer to update it like any server. It moves to the
new version in place when it can: the running code is replaced module by module and
nothing reconnects. A version that changes only HAL-C2's own code takes nothing else
from its bundle, so it keeps the Erlang runtime and dependencies the MC already runs
and installs from a bundle built for any platform. A new OTP release, dependency,
configuration or supervision tree needs a restart instead, which
`bin/hal-c2-service` provides from this platform's bundle (`HalC2.Upgrade` has the rules).

MCs get a version's bundle from a cluster peer that has it, or else from the
`mc-v<version>` GitHub release (`.github/workflows/release-mc.yml`; set
`HAL_C2_UPGRADE_URL` to publish elsewhere). From a checkout:

```sh
HAL_C2_MC_VERSION=0.0.43-mine mix hal_c2.upgrade hal_c2@host     # build a release, send it, update
mise run mc:reload                                  # compile, reload changes into `mise run mc`
mise run mc:reload --release                        # build a release, update the installed MC on this machine
mise run mc:update-cluster olafura@ai-beast         # the same commit and a reload on other machines, over SSH
mix hal_c2.upgrade --dev hal_c2_a@my-mac hal_c2_b@my-mac        # MCs run with `mix run`: reload changes
MIX_ENV=prod mix hal_c2.bundle                        # just pack _build/prod/rel/hal_c2 and its single file
```

A process that holds state across an upgrade migrates it: OTP processes in
`code_change/3`, and `HalC2.Web.Socket` (whose processes belong to Bandit) at its next
callback.

## Cluster your machines

```sh
bin/hal-c2-service cluster invite            # on a member: prints a link, good once for 5 minutes
bin/hal-c2-service cluster join LINK         # on the new machine
bin/hal-c2-service cluster                   # this machine and the members it is connected to
bin/hal-c2-service cluster remove LABEL      # no member admits that machine any more
```

From a checkout, `mix hal_c2.cluster` takes the same arguments. The desktop app (Settings →
Cluster) and the terminal client (settings and the command palette) do the same through the
MC's `cluster.*` RPCs. Every MC boots ready to
cluster (`rel/env.sh.eex`, `mise run mc`): it has its own certificate, and members pin
each other's and talk Erlang distribution over mutual TLS on port 4370
([cluster.feature](../../features/connections/cluster.feature)). The joining machine has to
reach the inviting MC's HTTP address, so start that one with `HAL_C2_MC_HOST` set to
its LAN or tailnet address, or invite with `--tailscale`.

Members find each other at the addresses they report, then at those a discovery strategy
lists: the tailnet (`HalC2.Cluster.Tailscale`) and `HAL_C2_PEERS=host[:port],...`
(`HalC2.Cluster.Static`), or modules of your own in the `:cluster_strategies` config.

## Test

`mix test` runs the suite. `--include codex` / `--include claude` drive the real
CLIs; `--include parity` compares sidebar rows with the Node server's
(see `test/hal_c2/projection/shell_parity_test.exs`).

What this MC serves, what it still lacks, and why anything was dropped is written as
Gherkin under the repository's `features/` tree: `features/parity/rpc.feature` and
`features/parity/commands.feature` hold a row per RPC method and orchestration command,
and `features/mc/` describes the behaviour a client sees over the socket.
`test/hal_c2/scenarios_test.exs` drives the subset of those scenarios that run today.
