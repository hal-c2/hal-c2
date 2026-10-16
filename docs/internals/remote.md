# Remote architecture

Each connection joins a client to one environment over HTTP and WebSocket. The
environment owns providers, execution, files, and durable state. Direct access,
Tailscale, and HAL-C2 Connect change how the client reaches that MC; they do
not introduce another execution model. See
[remote access](../user/remote-access.md) for setup.

## Identity is independent of the route

An environment keeps its ID across restarts and endpoint changes. Saved
connections are local to a client profile; the MC's identity and state are
not. A repository identity can correlate clones across environments, but never
routes work between them. A project and its threads belong to one environment.

[The environment ID](../../apps/server-ex/lib/hal_c2/environment.ex) is generated once and
kept in the data directory (`environment-id`). Deleting that file as stray state gives the
MC a new identity, and every client then treats it as a different environment.

Advertised endpoints are reachability hints. Only the connecting device can
prove that a route works. In particular, a host's loopback address refers to a
different machine when another device opens it. Endpoint selection must not
silently fall back to loopback when a shareable endpoint is unavailable.

A dev server a thread starts on another cluster member listens on that machine's
loopback. [`preview.forward`](../../apps/server-ex/lib/hal_c2/preview_forward.ex) carries it
over the cluster's distribution link, as `ssh -L` would: the client asks the MC it is
connected to, which binds its own loopback; the thread's MC dials
its dev server, and only for a port one of the thread's browser tabs names, never its own
or the cluster's ports. That lands on the user's machine only when the client's MC runs
there, so a client must not ask for a forward of an MC on another machine. The bytes share
the distribution link with every other message between the two MCs, which is why each
connection's chunks are capped and acked rather than sent as fast as the socket reads.

## Access and process ownership are different

Tailscale supplies an endpoint for ordinary pairing, so it needs no separate
environment type. `mix hal_c2.pair --tailscale`
([`HalC2.TailscaleServe`](../../apps/server-ex/lib/hal_c2/tailscale_serve.ex)) maps the machine's
MagicDNS name to the local listener and the MC uses it as the pairing endpoint.
Authentication remains the environment's responsibility for every route. See
[environment authentication](./environment-auth.md) and the
[HAL-C2 Connect trust boundary](./hal-c2-connect.md).

MCs outlive several client releases. Clients must use advertised capabilities
(the `capabilities` map of the environment descriptor) and handle their
absence, rather than assume their own version describes the MC. Process
replacement belongs to the MC's [update protocol](./server-updates.md); the
connection layer handles the resulting disconnect.

## Another machine's files are a folder here

A client opens a cluster member's file with this machine's own apps by asking its MC
where that file is here (`files.localPath`). The MC mounts the members under its state
directory, one folder per member mirroring its absolute paths
([`HalC2.MachineFiles`](../../apps/server-ex/lib/hal_c2/machine_files.ex)). The kernel's
requests reach the MC as 9P2000.L from a small FUSE helper
([`native/machine-files`](../../native/machine-files)) on the port's stdin and stdout, and
the MC answers each one by calling
[`Share`](../../apps/server-ex/lib/hal_c2/machine_files/share.ex) on the member over the
cluster's Erlang distribution. That keeps the helper free of policy and of credentials:
the link is the cluster's mTLS one, what is shared (a member's project roots and thread
worktrees, nothing above or beside them) is decided on the member, and nothing is started
or listened on for it. Every call has a timeout and runs in a process of its own, so a
member that stops answering fails that request with EHOSTDOWN and never blocks the kernel
or the other folders (`proof/models/machine_files.maude`). The mount is never
`allow_other` and sits in a 0700 directory: the files are as reachable as the member's
MC, so only the user the MC runs as may see them. A helper killed outright leaves a mount
that answers ENOTCONN; the MC lazily unmounts it before mounting again. There are no change
notices, so the helper keeps attribute and entry caches to about a second.
