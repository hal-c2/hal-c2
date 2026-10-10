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
