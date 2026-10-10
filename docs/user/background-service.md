# Running HAL-C2 in the background

On Linux and macOS, HAL-C2 can run as a service for your user so you do not need
to keep a terminal open.

## Manage the service

Download the MC file first ([Install HAL-C2](./install.md#command-line)), then run
these commands on the machine that will host HAL-C2. `<mc>` stands for
`./hal-c2-mc-<version>-<platform>`:

| Task                            | Command          |
| ------------------------------- | ---------------- |
| Install and start               | `<mc> install`   |
| Inspect status and log location | `<mc> status`    |
| Restart                         | `<mc> restart`   |
| Stop and remove from startup    | `<mc> uninstall` |

Uninstalling the service leaves your projects, threads, and settings intact.
Running `<mc> install` again repairs a service that `<mc> status` reports as
broken.

A service installed by T3 Code or an earlier HAL-C2 release still shows up in
`<mc> status` and can be removed with `<mc> uninstall`. On its
next start it copies your data once, as described in
[Coming from T3 Code](./install.md#coming-from-t3-code), and then runs from the new
directories. Run `<mc> install` to rewrite it for the current release.
A new service uses the [usual directories](./install.md#where-hal-c2-keeps-its-files)
and names `HAL_C2_MC_HOME` or `HAL_C2_HOME` only if one was set when you installed the service.

An MC moves to a newer version from the client's update notice, which installs it
and restarts the service when it has to. Restarting interrupts running agent
turns, terminals, and remote clients. Follow [Updating HAL-C2](./updating.md) to
match a remote client's version.

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

Start with `<mc> status` on the host. It prints the log path and, on Linux,
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
identity. Without administrator access, run the MC file in a terminal and keep
that session open.

| Status problem                          | Next step                                                                                                                      |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `linger-unavailable`                    | Run `loginctl show-user "$(id -un)" --property=Linger` and check that systemd-logind is available.                             |
| `user-manager-unavailable`              | Run `systemctl --user status` in a login session for the service user; check your distribution's systemd user-session support. |
| `service-disabled` or `service-stopped` | Read the log and `systemctl --user status hal-c2.service`, then use the repair command printed by HAL-C2.                      |
| `restart-pending`                       | A newer version is installed but the service still runs the previous one. Run `<mc> restart`.                                  |

On macOS, check **System Settings → General → Login Items** if the service no
longer starts at login. If agent work cannot access Desktop, Documents, or
Downloads, it may need Full Disk Access for the executable listed in
`ProgramArguments` in
`~/Library/LaunchAgents/io.github.halc2.service.plist`.

The service has no SSH agent, so an SSH key with a passphrase cannot reach your
remotes from it. GitHub still works when the GitHub CLI is signed in
(`gh auth login`): HAL-C2 and its agents reach `git@github.com:` remotes over HTTPS
with that sign-in. Signing in or out later takes effect when HAL-C2 next starts or
updates.

For failures after signing in to HAL-C2 Connect, see
[connection troubleshooting](./remote-access.md#hal-c2-connect-troubleshooting).
