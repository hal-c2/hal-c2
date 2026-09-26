# HAL-C2 node (Elixir)

The Elixir/OTP backend. Each machine runs one node with its own SQLite event log;
nodes on your machines join a cluster over mutually authenticated TLS and share one
sidebar, so a client connected to any node sees threads on all of them.

Clients speak orchestration protocol 3 (`HalC2.Web.Protocol`): shape subscriptions over
one WebSocket, resumed from an offset. `packages/client-runtime/src/v3` adapts it to
the existing client state, so a node pairs and appears like any other environment.

## Run

```sh
mix deps.get
mix hal_c2.import ~/path/to/snapshot/state.sqlite   # optional: a VACUUM INTO copy of a Node server's state
mix hal_c2.server                                    # prints ws://127.0.0.1:3780/ws?token=...
mix hal_c2.pair                                      # one-time pairing URL for Settings → Connections
```

State lives in the repo's `.hal-c2/elixir` during development; set `HALC2_NODE_HOME` to put
it elsewhere. The node listens on loopback port 3780; `HALC2_NODE_PORT` and
`HALC2_NODE_HOST` (a LAN or tailnet address, for pairing other devices; `HALC2_HOST` also
works) change that.

## Release

```sh
MIX_ENV=prod mix release        # _build/prod/rel/hal_c2, about 80 MB with ERTS
_build/prod/rel/hal_c2/bin/hal_c2 start # foreground; state in ~/.hal-c2/elixir
```

A release keeps its state in the `elixir` directory of the HAL-C2 home it shares with
the Node server (`HALC2_HOME`, default `~/.hal-c2`), or in `HALC2_NODE_HOME` when that is
set. An install from before the rename keeps using `~/.t3/elixir`, and `T3_HOME` and
`T3CODE_HOME` are still read (`rel/env.sh.eex`).

The release carries the Cursor sidecar (`packages/cursor-acp`, bundled with its
dependencies for the build machine's platform), so building one needs `pnpm`, and
running Cursor needs Node 22+ on the machine. The desktop app runs it on its own
Electron binary instead (`HALC2_NODE_COMMAND`).

A machine that has joined a cluster boots clustered: joining writes
`cluster/vm.args` in its state directory, which the release reads at start.

Run it as a service with `bin/hal-c2-service` (under launchd, systemd, or a terminal): it
is `bin/hal_c2 start`, started again when the node restarts to finish an update.
`bin/hal-c2-service install` registers it as a systemd user unit (Linux) or launch agent
(macOS) that starts on login; `status` and `uninstall` inspect and remove it.

## Upgrades

A node carries the HAL-C2 version (`apps/server/package.json`, or `HALC2_NODE_VERSION` for a
build of its own), and clients offer to update it like any server. It moves to the
new version in place when it can: the running code is replaced module by module and
nothing reconnects. A new Erlang runtime, native library, configuration or
supervision tree needs a restart instead, which `bin/hal-c2-service` provides
(`HalC2.Upgrade` has the rules).

Nodes get a version's bundle from a cluster peer that has it, or else from the
`node-v<version>` GitHub release (`.github/workflows/release-node.yml`; set
`HALC2_UPGRADE_URL` to publish elsewhere). From a checkout:

```sh
HALC2_NODE_VERSION=0.0.43-mine mix hal_c2.upgrade hal_c2@host     # build a release, send it, update
mix hal_c2.upgrade --dev halc2a@my-mac halc2b@my-mac        # nodes run with `mix run`: reload changes
MIX_ENV=prod mix hal_c2.bundle                        # just pack _build/prod/rel/hal_c2
```

A process that holds state across an upgrade migrates it: OTP processes in
`code_change/3`, and `HalC2.Web.Socket` (whose processes belong to Bandit) at its next
callback.

## Cluster your machines

```sh
mix hal_c2.cluster init 100.x.y.z                    # first machine: its Tailscale IP
mix hal_c2.cluster invite 100.a.b.c bundle           # on a member, for the new machine
mix hal_c2.cluster join bundle                       # on the new machine; then delete the bundle
elixir --erl "$(mix hal_c2.cluster vm-args)" -S mix hal_c2.server
```

Nodes find each other on the tailnet (`HalC2.Cluster.Tailscale`) or through
`HALC2_PEERS=hal_c2@host,...`, and only connect when both certificates come from the
cluster's CA.

## Test

`mix test` runs the suite. `--include codex` / `--include claude` drive the real
CLIs; `--include parity` compares sidebar rows with the Node server's
(see `test/hal_c2/projection/shell_parity_test.exs`).

What this node serves, what it still lacks, and why anything was dropped is written as
Gherkin under the repository's `features/` tree: `features/parity/rpc.feature` and
`features/parity/commands.feature` hold a row per RPC method and orchestration command,
and `features/node/` describes the behaviour a client sees over the socket.
`test/hal_c2/scenarios_test.exs` drives the subset of those scenarios that run today.
