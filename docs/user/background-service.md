# Running HAL-C2 in the background

On Linux and macOS, HAL-C2 can run as a service for your user so you do not need
to keep a terminal open.

## Manage the service

Install the `hal-c2` CLI first ([Install HAL-C2](./install.md#command-line)), then
run these commands on the machine that will host HAL-C2:

| Task                            | Command                    |
| ------------------------------- | -------------------------- |
| Install and start               | `hal-c2 service install`   |
| Inspect status and log location | `hal-c2 service status`    |
| Move to a newer release         | `hal-c2 update`            |
| Restart                         | `hal-c2 service restart`   |
| Stop and remove from startup    | `hal-c2 service uninstall` |

Uninstalling the service leaves your projects, threads, and settings intact.
Running `hal-c2 service install` again repairs a service that `hal-c2 service status`
reports as broken.

`hal-c2 update` downloads the newest release on your channel and switches `hal-c2`
and the service to it. Restarting interrupts running agent turns, terminals,
and remote clients, so it asks first; answer no and the service keeps running
the old version until you run `hal-c2 service restart`. Pass `--yes` from a
script. A server you started by hand is left running; stop and start it again
to pick up the new version. Wait for any remote update already in progress
before updating; to match a remote client's version, follow
[Updating HAL-C2](./updating.md).

Pass an exact version (`hal-c2 update 0.0.42`) to pin one, `--channel nightly` to
switch trains, or `--allow-downgrade` to move backwards. `preview` is a
maintainers' test train: its builds can be broken and are never offered as
updates, so the installer and `hal-c2 update` ask for confirmation before
installing one.

`hal-c2 uninstall` removes the background service, the `hal-c2` launcher, and the
downloaded versions after showing you the list and asking once. Your projects,
threads, and settings under `~/.hal-c2/userdata` are kept. Pass `--yes` from a
script.

## Platform support

Linux needs systemd user services. Setup enables lingering so HAL-C2 starts at
boot and keeps running after logout. If this needs administrator permission,
setup prints a recovery command before changing the service.

macOS starts the service when you log in and stops it when you log out. Keep the
Mac logged in and awake for unattended remote access. Installing over SSH while
nobody is logged in at the Mac's screen can fail at the final start step; the
service is still installed and will start at the next login.

Windows background services are not supported.

HAL-C2 Connect can offer service installation during setup, but the two are managed
separately. Signing out of HAL-C2 Connect does not stop or uninstall the service.

## Troubleshooting

Start with `hal-c2 service status` on the host. It prints the log path and, on Linux,
checks whether the installed service is running, enabled, and allowed to survive
logout.

If it stops when your SSH session closes, check for `linger-disabled`. An
administrator can enable lingering with:

```sh
sudo loginctl enable-linger "$(id -un)"
```

Over SSH, allow sudo to prompt:

```sh
ssh -t your-server 'sudo loginctl enable-linger "$(id -un)"'
```

Then retry service setup as your normal user. Run only the `loginctl` command
with sudo; running HAL-C2 as root creates a separate installation and Connect
identity. Without administrator access, run `hal-c2 serve` in a terminal and keep
that session open.

| Status problem                          | Next step                                                                                                                      |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `linger-unavailable`                    | Run `loginctl show-user "$(id -un)" --property=Linger` and check that systemd-logind is available.                             |
| `user-manager-unavailable`              | Run `systemctl --user status` in a login session for the service user; check your distribution's systemd user-session support. |
| `service-disabled` or `service-stopped` | Read the log and `systemctl --user status hal-c2.service`, then use the repair command printed by HAL-C2.                      |
| `restart-pending`                       | A newer version is installed but the service still runs the previous one. Run `hal-c2 service restart`.                        |

On macOS, check **System Settings → General → Login Items** if the service no
longer starts at login. If agent work cannot access Desktop, Documents, or
Downloads, it may need Full Disk Access for the `hal-c2` executable listed in
`ProgramArguments` in
`~/Library/LaunchAgents/io.github.halc2.halc2.service.plist`.

For failures after signing in to HAL-C2 Connect, see
[connection troubleshooting](./remote-access.md#hal-c2-connect-troubleshooting).
