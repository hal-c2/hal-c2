# Server updates

An MC moves to another version through [`HalC2.Upgrade`](../../apps/server-ex/lib/hal_c2/upgrade.ex),
which `server.updateServer` calls. A version arrives as a release bundle, and the MC upgrades in
place with an OTP release upgrade: `release_handler` installs a relup generated from what differs
between the running release and the new one, and makes it permanent. Nothing restarts, so sockets
and provider sessions stay up. What a relup cannot do (another OTP release or emulator flags, OTP
applications or code that loads a NIF changing) installs the whole bundle and exits with status
75, which `bin/hal-c2-service` answers by starting the MC again on the new version. Only a release
can install a version; a checkout run by `mise run mc` reports no `serverSelfUpdate` capability,
and `mise run mc:reload` upgrades it the same way from the caller's build
([`HalC2.Upgrade.Dev`](../../apps/server-ex/lib/hal_c2/upgrade/dev.ex)).

An MC the desktop app started (`HAL_C2_DESKTOP_HOST=1`) never installs a version itself: it
reports "desktop-managed", and [`HalC2.DesktopUpdate`](../../apps/server-ex/lib/hal_c2/desktop_update.ex)
asks the desktop app, over its `desktopUpdateControl` subscription, to update and restart both.
Only the socket that exchanged the desktop bootstrap token may hold that subscription or report
the app's updater with `server.reportDesktopUpdateStatus`; reports name the run by its
`requestId`, and a failed install after the commit becomes the outcome clients see in `ready`.

## Upgrading in place

[`HalC2.Upgrade.Release`](../../apps/server-ex/lib/hal_c2/upgrade/release.ex) does the install for
both an update and `mise run mc:reload`; [`Appup`](../../apps/server-ex/lib/hal_c2/upgrade/appup.ex)
generates each application's instructions from the compiled modules, so nobody writes appups by
hand. What that asks of the MC's code:

- **State that changes shape needs `code_change/3`.** A changed module of a process behaviour is
  `{update, M, {advanced, []}}`: its processes are suspended, migrate their state, and resume. A
  GenServer that keeps a new shape without a clause for the old one crashes at the upgrade.
- **The release handler finds processes through the supervision tree.** It suspends the processes
  whose child spec lists the module (`modules: [M]`, the default). A process started outside a
  supervisor, or one running a module its spec does not name, is not suspended and switches code
  at its next external call, without `code_change/3`.
- **A long-lived loop must recurse by module name.** The VM holds at most two versions of a module.
  A plain process looping in `receive` with local calls stays on the version it started on, and
  once an upgrade makes that the version before last, the next install stops before its point of
  no return, naming the process, and the MC restarts into the new version instead. So a loop
  recurses as `__MODULE__.loop(...)` (see the store's checkpointer); a short wait that returns is
  fine. A response that streams for long keeps the frames of every plug it passed through, so the
  device hub's relay is served by [`HalC2.Web.Entry`](../../apps/server-ex/lib/hal_c2/web/entry.ex)
  ahead of the router.
- **Supervisors only start children when they start.** Before the install
  [`HalC2.Upgrade.Tree`](../../apps/server-ex/lib/hal_c2/upgrade/tree.ex) keeps the specs every
  static supervisor of the MC was started from, and the relup's last step compares them with the
  new code's: new children start, removed ones stop, changed ones restart. The snapshot's
  `:persistent_term` key and shape pass from one version to the next, so they are a contract
  between versions.
- **The configuration is the running one.** The release handler reads only `sys.config`, so for the
  install the new release's `sys.config` holds the running environment with the new configuration
  and its `runtime.exs` over it; what the MC set itself (its home) survives.

A bundle built for another platform, or on another patch of the Erlang runtime, still installs in
place when only HAL-C2's own code changes
([`HalC2.Upgrade.Code`](../../apps/server-ex/lib/hal_c2/upgrade/code.ex)): its release is the
running one with that code, on the runtime this machine already has.

## Restart and rollback

An install that fails before the relup's point of no return changes nothing; one that fails after
it restarts the node on the permanent release, which is still the old one. Either way the MC
records the rollback and restarts into the new version through `bin/hal-c2-service`.
`releases/start_erl.data` names the version the next boot runs. The previous file is kept beside
it until the new version boots, and `bin/hal-c2-service` puts it back and starts the old version
if it cannot.
`HalC2.Upgrade` takes no copy of the SQLite file. A rollback restores the code, not the data, so a
migration must be written to be read by the version before it, or must not run in an update that
can fail to boot.

## Client acknowledgement

An accepted update is still pending. The outcome is written to `<data>/upgrades/outcome.json`
with an update ID and reported with the MC's next `ready`. Clients correlate that ID after
reconnecting, then check the outcome and target version. A reconnect alone cannot tell a
successful replacement from a rollback. One update runs at a time; another asked for meanwhile
is refused.

## Recovering interrupted threads

Provider processes die with the MC, so [`HalC2.Orchestration.Recovery`](../../apps/server-ex/lib/hal_c2/orchestration/recovery.ex)
ends every run still active on the MC's threads as interrupted before the MC takes requests.
Otherwise a thread would stay "running" and refuse its next message. A run the MC accepted but
never handed to its provider goes back to the front of the queue instead.

Continuing a cut-off thread is a project setting (`continueThreadsAfterServerUpdate`), and
`continue/0` runs only after the MC can start turns. A slow provider must not
delay readiness. Work a provider left running in the background after its turn dies with the
process and is ended the same way.
