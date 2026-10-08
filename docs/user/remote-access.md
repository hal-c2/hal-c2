# Remote access

Connect a phone, browser, or another desktop app to HAL-C2 running on a different
machine. That machine must stay running and reachable while you work.

## HAL-C2 Connect

HAL-C2 Connect makes an environment available to your other devices without setting
up router forwarding. It runs through a relay you host yourself; there is no
public HAL-C2 relay. Deploy one as described in
[HAL-C2 Connect setup](../operations/connect-setup.md), then point the server at it
with `HAL_C2_RELAY_URL` (for example `https://relay.hal-c2.example`, a placeholder for
your own domain) and set `HAL_C2_HOSTED_APP_URL` to the web app that completes
sign-in for headless hosts (placeholder `https://app.hal-c2.example`).

In the desktop app on the host, open **Settings →
Connections**, sign in, and enable **HAL-C2 Connect** for that environment.

For a command-line host, run:

```bash
hal-c2 connect
```

Follow the sign-in instructions. Setup offers a
[background service](./background-service.md); if you decline it, start the
server with `hal-c2 serve`. Saving your sign-in alone does not make the machine
reachable.

On your other device, sign in to the same HAL-C2 Connect account and choose the
environment. Over SSH, the CLI prints a browser link and a short code. Open the
link on any device, confirm the code matches, and approve. The CLI continues on
its own, so you do not need to forward an OAuth callback port.

HAL-C2 Connect renews access credentials when needed without disconnecting a healthy
connection. Pull request diffs and provider settings keep working after the
previous credential expires. A failed renewal affects that request; it does not
disconnect an otherwise healthy conversation.

## Pair over a LAN or private network

Use direct pairing when the other device can reach the host's network address.

On a desktop host, open **Settings → Connections**, enable **Network access**,
then create a pairing link using an address the other device can reach. Changing
network access restarts the desktop app. You can turn it off in the same place.

For a command-line host, replace `<private-ip>` with the host's LAN or tailnet
address:

```bash
hal-c2 serve --host <private-ip>
```

If a server is already running, generate a fresh link without restarting it:

```bash
hal-c2 pair
```

Scan the QR code on your phone or paste the pairing URL into **Add environment**
in the receiving app. Connection settings are under **Settings → Connections**
on web and desktop; the phone's own pairing is under **Settings → Pairing**. A loopback address
such as `127.0.0.1` reaches only the device opening the link, so Settings shows
no QR code for one.

When your machines are [clustered](#cluster-your-machines), **Settings →
Connections** asks which machine the link is for. A phone reaches the whole
cluster through the machine it paired with, and loses it when that machine
sleeps, so pair it with one that stays on rather than the laptop you are sitting
at. **Create over Tailscale** publishes the chosen machine on your tailnet and
makes the link for that address. A phone's own camera can read the code too: it
opens a page on that machine that hands the link to the HAL-C2 app.

Pairing authorizes that device for future connections. Use a fresh one-time link
for each new device; you do not need the original token to reconnect. Links
created in Settings can only be copied from the client that created them while
its Connections page stays open. If you leave or reload that page, create
another link to share.

## Cluster your machines

Machines that run HAL-C2 can join one cluster. A client connected to any of them then
shows every machine's projects and threads in one sidebar, and threads can move between
them.

On a machine already in the cluster (or the first one), open **Settings → Cluster** in
the desktop app and make an invite. On the machine that joins, open the same page and
paste the link. In the terminal client the command palette has **Invite a machine to this
cluster** and **Join another machine's cluster…**. The link works once, for five minutes,
and the joining machine has to reach the address in it: a LAN or tailnet address, not a
loopback one. From a command line:

```bash
hal-c2-service cluster invite      # prints the link
hal-c2-service cluster join LINK   # on the machine that joins
```

Every machine of a cluster runs the same HAL-C2 version. A machine on another version
stays listed but does not connect until it is updated. Removing a machine from the
Cluster page stops every member from admitting it, and its projects and threads leave
the sidebar.

### Move a thread to another machine

Choose **Move to another machine** in a thread's menu or the command palette, then the
machine. The thread keeps its conversation, attachments and checkpoints, and continues in
that machine's checkout of the same repository; a thread working in a worktree gets a
worktree there. HAL-C2 asks which project to use when several fit, and tells you what
stays behind when none is the same repository.

A thread whose agent is working is stopped first, if you agree. While it moves it says
where it is going and takes no messages. A move that is cut off leaves the thread where it
was; if the other machine had already started taking it, the thread stays read-only until
that machine is reachable again and says whether it has it. Once moved, the agent continues its own session
when the provider can carry it, and otherwise gets the conversation handed over as after a
[provider switch](./portable-handoffs.md). Running terminals stay on the machine the thread
left and are closed. Notifications from before the move open the thread where it lives now,
and so do links to it in the desktop app.

To copy a thread between machines that are not in one cluster, see
[Copying a thread to another machine](./thread-migration.md#copying-a-thread-to-another-machine).

### Balance new threads across machines

Load balancing is off by default. Once the cluster has two or more machines, turn it on
in **Settings → Connections → Load balancing** in the desktop app, or with **Turn on load
balancing** in the terminal client's command palette.
Each machine starts at **Normal**. Choose **Prefer** to favor it when it has CPU and
memory available, **Less often** to reduce its share, or **Manual only** to exclude
it from automatic selection. These are preferences, not fixed traffic percentages.
They are saved on the machine your client is connected to, so every client connected to
it balances the same way, and turning load balancing off keeps them.

When you send a new thread's first message, HAL-C2 starts it on the machine with the most
free CPU and memory among those that have a checkout of the project's repository and the
chosen provider signed in. A machine that is offline, nearly out of CPU or memory, or slow
to answer is passed over, and the thread starts where you picked when no other machine has
more room. Choosing a branch or worktree for the draft keeps it on that machine. Existing
threads stay where they are; [move one](#move-a-thread-to-another-machine) yourself.
Mobile keeps its manual environment selection.

### Tailscale HTTPS

Join both devices to the same tailnet. In the desktop app, enable **Tailscale
HTTPS** in **Settings → Connections**. Turn it off there to remove that route.

To start a command-line server with Tailscale HTTPS:

```bash
hal-c2 serve --tailscale-serve
```

For an already-running server:

```bash
hal-c2 pair --tailscale
```

The pairing link uses an address such as `https://machine.tailnet.ts.net/`.
The mapping created by `pair --tailscale` persists across restarts. Remove its
default-port mapping with:

```bash
tailscale serve --https=443 off
```

If that port is already in use, choose another with
`--tailscale-serve-port`. See `hal-c2 pair --help` for other pairing options.

### Hosted web app

A hosted copy of the web app (`app.hal-c2.example` stands in for wherever you host it)
needs an HTTPS endpoint. It connects directly
to your server; a hosted pairing link does not make an unreachable backend
reachable or convert HTTP to HTTPS.

For a plain HTTP LAN endpoint, use the direct pairing URL in a browser that can
open it, or pair from the desktop app. On mobile, an IP address entered without a
scheme uses HTTP, so include `https://` when your server uses HTTPS.

## Desktop-managed SSH

In the desktop app, open **Settings → Connections → Add environment**, choose
**SSH**, and enter a host or SSH alias such as `user@example.com`. HAL-C2 starts
or reuses a server there and opens the port forward for you. Projects, provider
credentials, and agent work stay on the remote machine.

The remote host must be Linux or an Apple Silicon Mac with `curl` or `wget`,
`tar`, `sha256sum` or `shasum`, and [provider setup](./install.md#providers).
The first launch downloads HAL-C2's server into its data directory on the host
(`~/.local/share/hal-c2/runtime` unless the host sets `XDG_DATA_HOME`), so it
takes longer than later ones.
Provider CLIs must be on the `PATH` of a non-interactive login shell there;
check with:

```bash
ssh user@example.com 'sh -lc "command -v claude codex"'
```

If SSH reconnecting fails after an app update, retry the launch once. Removing
the connection stops a server that HAL-C2 launched; a server that was already
running is left alone.

For Antigravity's Google callback on a remote host, see
[remote sign-in](./providers-antigravity.md#sign-in-from-a-remote-device).

## Manage or revoke access

On the host, **Settings → Connections** lets authorized administrators create
pairing links and revoke client sessions. Revoking an unused link prevents new
pairings; revoke a device's session to remove its existing access. Command-line
management is available through `hal-c2 auth --help`.

A session with an open connection stays listed after its access credential
expires.

To remove an environment from HAL-C2 Connect, open your account menu's **HAL-C2 Connect**
page, or **Settings → HAL-C2 Connect** on mobile, and choose **Deregister**. This
revokes its cloud access and frees its host space even when the environment is
offline or has been wiped.

On a command-line host, `hal-c2 connect unlink` disables exposure while retaining
your login; `hal-c2 connect logout` also clears that login. Background-service
[removal](./background-service.md#manage-the-service) is separate.

Treat pairing URLs and authorization codes as passwords. Do not include them in
screenshots, logs, or bug reports.

## HAL-C2 Connect troubleshooting

Run `hal-c2 connect status` on the host to inspect saved authorization and link
configuration. It is not a live reachability check. If the environment appears
offline, run `hal-c2 service status` and read the displayed log. If it disappears
when SSH closes, see [background-service troubleshooting](./background-service.md#troubleshooting).

| Error                                                     | Recovery                                                                                                                                                |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `environment_link_limit_exceeded` or managed tunnel limit | Deregister an unused environment, then restart HAL-C2 on the host.                                                                                      |
| `auth_invalid` or `invalid_bearer`                        | Run `hal-c2 connect login`. If credentials were revoked, run `hal-c2 connect logout`, then `hal-c2 connect` again. Restart the server after signing in. |
| Expired or invalid link proof                             | Check the host's date and time, update HAL-C2, then restart it.                                                                                         |
| HTTP 403 without a recognized error                       | Check relay access, proxies, and firewall rules. Keep any Cloudflare Ray ID for a bug report.                                                           |
| HTTP 408, 429, or 5xx                                     | Check network and relay availability. Startup retries temporary failures for up to ten minutes.                                                         |

After fixing a permanent rejection, restart the host's server. On Linux, use
`systemctl --user restart hal-c2.service` for the background service. For a
foreground server, stop it and run `hal-c2 serve` again with your usual options.
Include the diagnostic message and trace ID when reporting a persistent failure.

For a connection that still fails after linking, check the date and time on both
devices. For server version warnings, follow [Updating HAL-C2](./updating.md).

## Using the Desktop App as a Remote Only

If a computer should only drive work running elsewhere, turn off its local environment. In the
desktop app, open **Settings → Connections** and switch off **Local
environment**. HAL-C2 restarts without a local server: no local agents or terminals run, WSL
backends stay off, and other devices can no longer connect to this computer. Your projects,
history, and saved connections are kept, and you keep working through pairing, HAL-C2 Connect, or SSH.

Switch **Local environment** back on in the same place to restart with your previous local
settings.
