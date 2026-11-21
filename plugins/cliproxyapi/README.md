# CLIProxyAPI

Runs [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (MIT) on the
machine, or connects to one already running, and routes Claude and Codex through
it: "Claude via CLIProxyAPI" and "Codex via CLIProxyAPI" appear in Settings →
Providers, and their agents use the accounts signed in to the proxy, taking turns,
or the API keys given to it. Its page signs accounts in, shows what each account
and model used, the proxy's log and the upstream API keys. How to use it is in
[docs/user/plugins.md](../../docs/user/plugins.md#cliproxyapi); what it does,
scenario by scenario, is in
[features/plugins/cliproxyapi.feature](../../features/plugins/cliproxyapi.feature).

It is an ordinary MC plugin and needs nothing from this repository but the plugin
API: copy the folder into an MC's `plugins` folder to install it.

## The package

- `plugin.json`: the `providers:configure` permission and why, the settings (run or
  connect, the binary, the port, and the address and management key to connect to)
  and the page.
- `mc/`: the MC part.
  - `cliproxyapi.ex` runs or connects, drains the proxy's management API on one
    timer into the topics, and answers the page's calls.
  - `proxy.ex` runs `cli-proxy-api` through a Port: restarts it after a backoff,
    stops it by the OS pid it started (and one a dead MC left behind, by its
    pidfile), never by name.
  - `release.ex` is the pinned release, 8.0.79: its download for this machine,
    checked against the release's checksums. A newer release is announced on the
    page, never installed.
  - `instances.ex` is what the two provider instances hold and when they are put.
  - `usage.ex` sums the proxy's usage per day, account and model, 30 days at most.
  - `api.ex` is the management API's HTTP client.
- `ui/CliProxyApiPage.qml`: the **CLIProxyAPI** page. The desktop shows it; the phone
  does not yet (its scenarios are `@backlog-mobile`).
- `test/tst_CliProxyApiPage.qml`: the page against a fake MC part; its header has
  the command that runs it.

## What it keeps

All of it is in the plugin's data folder, never `~/.cli-proxy-api`:
`management.key` and `client.key`, `config.yaml` (bound to 127.0.0.1,
`allow-remote: false`, the auth dir below), `auths/` (the accounts),
`upstream-keys.json` (the proxy's upstream keys, for its next start), `claude/` (the
Claude home its instance runs with), the downloaded release, `usage.json`, and
`providers.json`, the ledger of the instances it added. The keys, config and
ledgers are written `0600`.

## The provider instances

- **Claude** gets `ANTHROPIC_BASE_URL` (the proxy), `ANTHROPIC_AUTH_TOKEN` (the
  plugin's client key), an empty `ANTHROPIC_API_KEY`, and a Claude home of its own,
  so the user's own `claude` login is neither used nor touched.
- **Codex** gets `-c model_provider=cliproxyapi` and that provider's table on its
  command line (the proxy's `/v1`, `wire_api=responses`), and its key in
  `CLIPROXYAPI_API_KEY`. The user's `~/.codex` config stays as it is.

The plugin puts an instance when it first adds it and again only when what it owns
changes (the port, the key, the address). A rename, a colour, switching it off and
variables of the user's own are kept. One the user deletes stays deleted until they
add it back from the page. Off or removed, the plugin's instances leave with the
user's changes to them; on again, they come back as first added. An instance of the
user's under one of the plugin's ids stays theirs: the host refuses the put, and the
page shows why. Instances on other MCs of a cluster are not touched: each MC runs
its own plugin.

## Signing in from another device

The proxy's sign-in ends on a localhost page on the MC's machine. The page shows the
sign-in address; open it anywhere, sign in, and paste the address the browser ended
on (which does not load off that machine) back into the page. The MC hands it to
the proxy.

## Topics

`status`, `accounts` (with the sign-in under way), `usage` (the last 7 days),
`keys` (masked) and `logs` (the last 100 lines). Each is published only when it
changed; the page asks `status` once and then follows them.
