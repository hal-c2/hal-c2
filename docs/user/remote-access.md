# Remote access

Connect a phone, the terminal app, or another desktop app to HAL-C2 running on a different
machine. That machine must stay running and reachable while you work.

Commands marked `mix` run in a source checkout, in `apps/server-ex`, as `mise exec -- mix <task>`.
The MC file you [install](./install.md#command-line) has `cluster` and `threads`
commands of its own, shown below.

## HAL-C2 Connect

HAL-C2 Connect makes an environment available to your other devices without setting
up router forwarding. It runs through a relay you host yourself; there is no
public HAL-C2 relay. Deploy one as described in
[HAL-C2 Connect setup](../operations/connect-setup.md), then point the server at it
with `HAL_C2_RELAY_URL` (for example `https://relay.hal-c2.example`, a placeholder for
your own domain) and set `HAL_C2_HOSTED_APP_URL` to the hosted page that completes
sign-in (placeholder `https://app.hal-c2.example`).

On the host, run:

```bash
mix hal_c2.connect
```

Follow the sign-in instructions: the command opens the sign-in page in a browser on the
host, and over SSH, or with `--headless`, prints a link and a short code. Open the link
on any device, confirm the code matches, and approve. The command continues on its
own, so you do not need to forward an OAuth callback port. Setup offers a
[background service](./background-service.md); if you decline it, start the
MC yourself. Saving your sign-in alone does not make the machine reachable.

On your other device, sign in to the same HAL-C2 Connect account and choose the
environment.

HAL-C2 Connect renews access credentials when needed without disconnecting a healthy
connection. Pull request diffs and provider settings keep working after the
previous credential expires. A failed renewal affects that request; it does not
disconnect an otherwise healthy conversation.

## Pair over a LAN or private network

Use direct pairing when the other device can reach the host's network address.

An MC listens on its own loopback address only, so no other device reaches it until you
tell it which address to listen on. Start the MC with `HAL_C2_MC_HOST` set to the host's LAN or
tailnet address (`<private-ip>` below); `HAL_C2_MC_PORT` changes the port.

Then create a pairing link. In the desktop app, open **Settings → Connections**, choose
which machine the device pairs with, give the device a label, and choose **Create pairing
link**. From the command line, run, with the address a device can reach:

```bash
mix hal_c2.pair http://<private-ip>:<port>
```

Scan the QR code on your phone or paste the pairing URL into the receiving app's
pairing field. A loopback address such as `127.0.0.1` reaches only the device opening
the link, so Settings shows no QR code for one.

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

Join both devices to the same tailnet. In the desktop app, choose **Create over
Tailscale** next to **Create pairing link** in **Settings → Connections**. From the command
line:

```bash
mix hal_c2.pair --tailscale
```

The pairing link uses an address such as `https://machine.tailnet.ts.net/`.
The mapping created for it persists across restarts. Remove its
default-port mapping with:

```bash
tailscale serve --https=443 off
```

If that port is already in use, choose another with
`--tailscale-serve-port`.

## Manage or revoke access

On the host, **Settings → Connections** lets authorized administrators create
pairing links and revoke client sessions. Revoking an unused link prevents new
pairings; revoke a device's session to remove its existing access. From the
command line:

```bash
mix hal_c2.auth session list
mix hal_c2.auth session revoke <session-id>
```

A session with an open connection stays listed after its access credential
expires.

To remove an environment from HAL-C2 Connect, deregister it from your account on the
hosted app. This revokes its cloud access and frees its host space even when the
environment is offline or has been wiped.

On the host, `mix hal_c2.connect unlink` disables exposure while retaining
your login; `mix hal_c2.connect logout` also clears that login. Background-service
[removal](./background-service.md#manage-the-service) is separate.

Treat pairing URLs and authorization codes as passwords. Do not include them in
screenshots, logs, or bug reports.

## HAL-C2 Connect troubleshooting

Run `mix hal_c2.connect status` on the host to inspect saved authorization and link
configuration. It is not a live reachability check. If the environment appears
offline, run the MC file's `status` command and read the displayed log. If it disappears
when SSH closes, see [background-service troubleshooting](./background-service.md#troubleshooting).

| Error                                                     | Recovery                                                                                                                                                        |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `environment_link_limit_exceeded` or managed tunnel limit | Deregister an unused environment, then restart HAL-C2 on the host.                                                                                              |
| `auth_invalid` or `invalid_bearer`                        | Run `mix hal_c2.connect login`. If credentials were revoked, run `mix hal_c2.connect logout`, then `mix hal_c2.connect` again. Restart the MC after signing in. |
| Expired or invalid link proof                             | Check the host's date and time, update HAL-C2, then restart it.                                                                                                 |
| HTTP 403 without a recognized error                       | Check relay access, proxies, and firewall rules. Keep any Cloudflare Ray ID for a bug report.                                                                   |
| HTTP 408, 429, or 5xx                                     | Check network and relay availability. Startup retries temporary failures for up to ten minutes.                                                                 |

After fixing a permanent rejection, restart the host's MC. On Linux, use
`systemctl --user restart hal-c2.service` for the background service. For a
foreground MC, stop it and start it again with your usual options.
Include the diagnostic message and trace ID when reporting a persistent failure.

For a connection that still fails after linking, check the date and time on both
devices. For version warnings, follow [Updating HAL-C2](./updating.md).
