# Updating HAL-C2

The app you use and the MC running your agents can be on different machines.
When an MC is behind your app, an update notice names it. In the terminal app it
appears at the top and under **Updates** in the command palette (`Ctrl+K`).
In the desktop app it appears at the top of the window, and **Settings →
Connections** lists every machine of the cluster that is behind, with
**Update all**; the command palette has **Update all servers** and **Update a
server...**. Update the machine named in that notice.

A server run by the desktop app on another machine is updated by that app,
which closes and relaunches there, so HAL-C2 asks before it starts. If that desktop
app cannot update itself from here, update it on its own machine. A server started
by hand offers **Copy update command** instead: run the copied command on that
machine.

## Before you update

Server updates restart the connection and can interrupt active agents and
terminal commands. Saved threads, settings, and project files remain.

**Settings → General → Continue threads after restarts** is off by default.
Enable it to resume supported active threads after an update, crash, or machine
restart. HAL-C2 must start again on that machine;
the setting does not enable automatic startup. Terminal commands may still be
interrupted, and threads without saved provider resume state need a new message.
An agent that had left a command running in the background is told the restart
stopped it, so it can start the command again.
If you previously enabled continuation for updates, enable this setting once
to allow recovery without a connected client.

Updates from the previous orchestration system preserve conversation transcripts but cannot carry
every kind of runtime history forward. Read [Threads from older versions](./thread-migration.md)
before continuing an important older thread.

## When versions don't match

A client and server must speak the same orchestration protocol. If they do not, the connection is
refused rather than running half-upgraded:

- An app newer than the MC is blocked before connecting, with a notice telling you to update
  HAL-C2 on the machine named in the notice.
- An MC newer than your app refuses the connection with an update message.

Update the side the notice names, then reconnect.

## Update a connected MC

Choose **Update server** in the notice and keep the app open while it installs and
reconnects. The MC downloads the release (from a clustered MC that already has it,
when one does), checks its checksum, and installs it. A change that only touches
HAL-C2's own code loads in place without a restart: connections, terminals and
agent sessions stay up. Anything else restarts the MC, which
[the background service](./background-service.md) starts again on the new version.
Update the MC on every machine of a cluster; a clustered MC passes the release
to the others.

An MC you started by hand in a terminal, without the service, has nothing to start
it again. Stop it and start it again after the update, or the update is refused.
An MC running from a source checkout updates with `mix hal_c2.upgrade` instead.

After the restart the app learns whether the update committed or rolled back.

## Update the desktop app

The desktop app on Linux (the AppImage) and macOS checks for a new version by itself
shortly after it starts and every few minutes after that. The update button at the
foot of the sidebar shows where things stand: click it to download the update, and
again to restart and install it. Restarting stops running agents and terminal
commands, and the app comes back with the same windows. To check now, open the
command palette and choose **Check for Updates**.

**Settings → General** shows the installed version and switches between the Stable
and Nightly tracks. Nightly updates list what changed. Leaving Nightly can offer a
Stable release older than the build you run; installing it goes back to that version.

Builds you made yourself, or started with `HAL_C2_DISABLE_AUTO_UPDATE=1`, do not update
themselves; **Settings → General** and **Check for Updates** say why. On an Apple Silicon Mac running the
Intel build, the next update installs the Apple Silicon build.

## Update from your phone

On the phone, open **Settings → Maintenance**. It lists the MC you paired with and
the machines clustered with it, each with its HAL-C2 version.

- **Check for updates** looks for the newest release on the channel that machine
  follows (stable, preview or nightly), so a stable MC is never offered a nightly.
- **Update to** installs that release, or the version of your app when the MC is
  behind it. Keep the app open until it says the machine reconnected and on which
  version. When the update notice offers to update a machine, it opens this page.
- A machine whose MC runs inside the desktop app asks before updating, because the
  desktop app closes and relaunches there. **Update all machines** updates the others
  without waiting for that answer.
- A machine that cannot update itself offers **Copy update command** instead: run
  the copied command on that machine.
- Each machine lists its enabled providers. **Update** installs a provider's newest
  release on that machine and shows its progress until it ends; a provider behind on
  several machines can be updated on all of them at once, and each machine says
  whether its update succeeded, was already up to date, or failed and why.

Nothing can be started while the phone is offline, or when its pairing does not
allow operating the MC; the page says which.

## If an update fails

Keep the client open until it reconnects or reports a failure. A release that fails its
checksum is not installed, and one that cannot boot is replaced by the version that ran
before. If the update still fails:

1. Retry the offered action once.
2. Check that you updated the MC's machine, not only the device you are using.
3. For an MC started by hand, stop it and run the MC file for the version shown in the notice
   ([Install HAL-C2](./install.md#command-line)).

## Update providers

When a provider such as Codex or Claude has a newer release, HAL-C2 offers to update it
when it starts. Choose **Update** to run the provider's update command on the MC, or
open **Settings → Providers** when the update has to be done by hand. A dismissed offer
returns when a newer release comes out.

While an update runs, and after it finishes, a notice at the bottom of the sidebar says how
it went; choose it to open the provider settings. When the offer covers several connected
machines, each machine gets its own row and updates on its own. A machine that has not
answered after six minutes shows **Update timed out**; retry it from its row.
