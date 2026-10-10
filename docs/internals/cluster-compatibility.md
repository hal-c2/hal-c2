# Cluster compatibility

A HAL-C2 release number identifies a build, not its distributed API. Machines may
run different builds while sharing a sidebar and moving threads. `HalC2.Cluster.protocol/0`
is the wire protocol epoch, covering member gossip and every distributed consumer,
including shell replication, thread transfer, plugins and upgrade bundle exchange.
Keep it unchanged for compatible additions. Bump it when an existing peer cannot
interpret a message, RPC argument, reply or transferred state safely. A client WebSocket
protocol change alone does not change this epoch unless it changes inter-MC behaviour.

Admission checks the advertised epoch. The distribution cookie carries the epoch,
so incompatible machines cannot execute distributed calls even if their saved membership
predates the change. The cookie is public; pinned mutual TLS certificates authorize
members. Removing or re-admitting a machine still follows the membership timestamps.

Release changes refresh and gossip metadata without disconnecting peers. An epoch
change replaces the cookie and disconnects existing peers before rediscovery. Settings
shows release differences as an update prompt; it never updates another machine on
its own. The explicit developer cluster deployment command remains a separate operation.
Old releases with release-specific cookies need a one-time update to join this scheme.

Hot reload and wire compatibility are separate decisions. The current loader migrates
OTP process state through `code_change/3`, but does not apply OTP release instructions.
Its code-only restriction cannot safely be relaxed for dependency, configuration or
supervision changes without defining their migration order and failure behaviour.
A fuller release upgrade should use `.appup` instructions and a generated `.relup`,
with `release_handler` applying the ordered changes. Runtime or native-library changes
may still need a restart. Neither path should require compatible peers to update in
lockstep. See `HalC2.Upgrade.plan/2` and `HalC2.Hot.reload/2` for the current limits.
