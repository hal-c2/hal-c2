# Updating HAL-C2

The app you use and the MC running your agents can be on different machines.
When an MC is behind your app, an update notice names it. In the terminal app it
appears at the top and under **Updates** in the command palette (`Ctrl+K`).
Update the machine named in that notice.

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

## If an update fails

Keep the client open until it reconnects or reports a failure. A release that fails its
checksum is not installed, and one that cannot boot is replaced by the version that ran
before. If the update still fails:

1. Retry the offered action once.
2. Check that you updated the MC's machine, not only the device you are using.
3. For an MC started by hand, stop it and run the MC file for the version shown in the notice
   ([Install HAL-C2](./install.md#command-line)).
