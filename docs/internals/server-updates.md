# Server updates

An MC moves to another version through [`HalC2.Upgrade`](../../apps/server-ex/lib/hal_c2/upgrade.ex),
which `server.updateServer` calls. A version arrives as a release bundle; the MC compares its
`upgrade.json` manifest with the one it runs. If only HAL-C2's own code differs, that code is
loaded in place and nothing restarts, so sockets and provider sessions stay up. Anything else
installs the whole bundle and exits with status 75, which `bin/hal-c2-service` answers by
starting the MC again on the new version. Only a release can install a version; a checkout run
by `mise run mc` reports no `serverSelfUpdate` capability.

An MC the desktop app started (`HAL_C2_DESKTOP_HOST=1`) never installs a version itself: it
reports "desktop-managed", and [`HalC2.DesktopUpdate`](../../apps/server-ex/lib/hal_c2/desktop_update.ex)
asks the desktop app, over its `desktopUpdateControl` subscription, to update and restart both.
Only the socket that exchanged the desktop bootstrap token may hold that subscription or report
the app's updater with `server.reportDesktopUpdateStatus`; reports name the run by its
`requestId`, and a failed install after the commit becomes the outcome clients see in `ready`.

## Loading in place

[`HalC2.Hot`](../../apps/server-ex/lib/hal_c2/hot.ex) does the in-place load for both an update
and `mise run mc:reload`. The VM holds at most two versions of a module, and a process leaves the
old one only at a call by module name. OTP behaviours do that for their callbacks, but a plain
process looping in `receive` with local calls stays on the version it started on, and once a
newer load makes that version the one before last it can never be purged. The load after that is
refused, naming the process, until it or the MC restarts. A long-lived loop must therefore
recurse as `__MODULE__.loop(...)` (see the store's checkpointer); a short wait that returns is
fine. Only BEAM code loads in place: a module that loads a NIF needs a restart.

## Restart and rollback

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
