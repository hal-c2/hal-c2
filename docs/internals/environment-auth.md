# Environment authentication

The environment issues its own sessions and enforces their capabilities. Cloud
identity and relay credentials belong to a separate trust boundary, described in
[HAL-C2 Connect](./hal-c2-connect.md). A relay token is never an environment login.

## Authority survives transport changes

Pairing delegates a set of scopes. Exchanging a bootstrap credential can narrow
that grant but cannot widen it. Ordinary pairing does not grant access-management
or relay-management authority. Creating another pairing link requires both
`access:write` and every scope being delegated. The
[auth handlers](../../apps/server-ex/lib/hal_c2/auth.ex) enforce this at issuance;
client labels and device metadata have no authorization role.

The access read model contains pairing metadata, never recoverable pairing
secrets. Only the creation response returns the raw credential. Otherwise read
access to the connections list would become a way to acquire another client's
authority.

Bearer tokens and DPoP tokens adapt the same scoped session model. DPoP binds a token to a client's proof key; an invalid proof must fail
rather than fall back to bearer authentication. The OAuth token-exchange
vocabulary gives these grants a familiar meaning, but the environment does not
implement a general-purpose OAuth authorization server.

Clients obtain short-lived WebSocket tickets through authenticated
HTTP so long-lived tokens stay out of socket URLs. A successful handshake grants no
extra authority: [every RPC declares a required
scope](../../apps/server-ex/lib/hal_c2/rpc.ex).

Desktop restarts forget the previous local bearer token, so its reusable
bootstrap grant replaces earlier sessions for the same subject and method.
Revocation and insertion share one database
transaction; a failed replacement must leave the old credential usable. Pairing
sessions do not follow this replacement rule.

### Reusable dev credential

A development MC can accept one `HAL_C2_DEV_AUTH_TOKEN` across worktrees. The
token grants administrative access. Desktop and non-development MCs ignore it. See
the [development runbook](../operations/development.md#reusable-dev-credential)
for setup.

Each environment hashes the value and seeds its own database record at startup.
MCs do not share SQLite data, signing keys, environment IDs, session
records, pairing grants, or revocation state. Local revocation persists after
restart and does not affect another worktree. Removing or rotating the value
and restarting invalidates the old credential and its WebSocket tickets.

Normal credentials keep precedence. A rejected normal credential never falls
back to the reusable credential. OAuth exchanges create ordinary local bearer
or DPoP children with normal expiry and revocation.

## The environment is the filesystem boundary

Projects are organizational boundaries, not filesystem sandboxes.
`orchestration:read` permits reading files the server account can read, including
absolute paths outside a project. This lets clients display artifacts that an
agent writes in a temporary directory. Relative paths and writes still follow
the [workspace path rules](../../apps/server-ex/lib/hal_c2/workspace.ex).

Signed asset URLs are bearer credentials. A URL for media on the host grants
access to one canonical file and its device/inode identity, not its containing directory.
[Asset access](../../apps/server-ex/lib/hal_c2/attachments.ex) rechecks the opened
file's identity when serving it, so atomic replacement requires a new URL while
editing the same file in place does not. An HTML file authorized this way cannot
load sibling assets; directory-scoped workspace previews are a separate grant.
Clients should share the authored file reference so they do not disclose the
temporary URL's credential.

Host videos can change in place. Their [HTTP
responses](../../apps/server-ex/lib/hal_c2/attachments.ex) omit cache validators because file
metadata cannot prove byte-for-byte identity for `If-Range`. Adding weak
validators would turn native-player seeks into full downloads.
