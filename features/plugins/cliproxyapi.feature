# Sources:
#   plugins/cliproxyapi/plugin.json (the providers:configure permission, the settings, the page)
#   plugins/cliproxyapi/mc/cliproxyapi.ex (the MC part: run or connect, the drain, the page's calls, the instances)
#   plugins/cliproxyapi/mc/proxy.ex (the cli-proxy-api process: start, restart with backoff, stop by its pid)
#   plugins/cliproxyapi/mc/release.ex (the pinned release, its download and checksum)
#   plugins/cliproxyapi/mc/instances.ex (Claude and Codex via CLIProxyAPI, and when they are put)
#   plugins/cliproxyapi/mc/usage.ex (usage summed per day, account and model)
#   plugins/cliproxyapi/ui/CliProxyApiPage.qml (the page)
#   CLIProxyAPI v8.0.79, router-for-me/CLIProxyAPI: internal/api/server_management_v8.go, config.example.yaml
#   docs/user/plugins.md (CLIProxyAPI)
#
# The MC scenarios run from apps/server-ex with
#   mise exec -- mix features plugins/cliproxyapi.feature
# against HalC2.Test.FakeCliProxyApi (the management API and the release downloads) and
# test/support/fake_cli_proxy_api.sh in place of the binary: the real one is never
# downloaded or run. The page's scenarios run in the desktop's tst_Features against a
# fake MC part (CliProxyApiSteps.cpp). Phones show no plugin pages yet (@backlog-mobile).
# The terminal client shows no plugin pages, so there are no @tui scenarios.

@plugin-cliproxyapi
Feature: CLIProxyAPI
  The CLIProxyAPI plugin runs CLIProxyAPI on the machine, or connects to one already
  running, and routes Claude and Codex through it: "Claude via CLIProxyAPI" and "Codex
  via CLIProxyAPI" appear in Settings → Providers, and their agents use the accounts
  signed in to the proxy, taking turns, or the API keys given to it. Its page signs
  accounts in, shows what each account and model used, the proxy's log and the
  upstream API keys.

  Background:
    Given a fake CLIProxyAPI

  Rule: Run starts the proxy with the MC, keeps it running, and stops it with the plugin

    @mc
    Scenario: The plugin runs the proxy on its own config, bound to this machine
      Given the CLIProxyAPI plugin is set to run the fake binary
      When the user turns the CLIProxyAPI plugin on
      Then the proxy runs with the config in the plugin's data folder
      And the config listens on 127.0.0.1 at the plugin's port, with remote management off
      And the config keeps the proxy's accounts in the plugin's data folder
      And the management key and the client key are files only the user can read
      And the proxy was given the management key and the data folder
      And the page shows the proxy "running"

    @mc
    Scenario: A proxy that exits is started again, and the page says why it exited
      Given the CLIProxyAPI plugin runs the fake binary
      When the proxy exits saying its port is taken
      Then the page shows the proxy "restarting" saying "address already in use"
      And the proxy runs again as a new process

    @mc
    Scenario: Turning the plugin off stops the proxy
      Given the CLIProxyAPI plugin runs the fake binary
      When the user turns the CLIProxyAPI plugin off
      Then the proxy's process has ended

    @mc
    Scenario: The plugin started again after a crash keeps the settings saved last
      Given the CLIProxyAPI plugin runs the fake binary
      When the user sets the CLIProxyAPI port to 18557
      And the plugin's server crashes
      Then the agent of "plugin_cliproxyapi_claude" is sent to "http://127.0.0.1:18557"

    @mc
    Scenario: A binary path that is not there says so, and runs nothing
      Given the CLIProxyAPI plugin is set to run "/nowhere/cli-proxy-api"
      When the user turns the CLIProxyAPI plugin on
      Then the page shows the proxy "failed" saying "is not a file this machine can run"
      And no proxy has run

  Rule: Without a binary of its own, the plugin downloads the pinned release and checks it first

    @mc
    Scenario: The pinned release is downloaded, checked against its checksums and run
      Given the CLIProxyAPI 8.0.79 release for this machine, with its checksums
      And the CLIProxyAPI plugin is set to run without a binary
      When the user turns the CLIProxyAPI plugin on
      Then the proxy runs from "bin/8.0.79/cli-proxy-api" in the plugin's data folder
      And the page shows the proxy "running"
      And the page shows the proxy running CLIProxyAPI 8.0.79

    @mc
    Scenario: A download that does not match the checksums is not installed
      Given the CLIProxyAPI 8.0.79 release for this machine, with a checksum that does not match it
      And the CLIProxyAPI plugin is set to run without a binary
      When the user turns the CLIProxyAPI plugin on
      Then the page shows the proxy "failed" saying "does not match the release's checksum"
      And nothing is installed in the plugin's data folder
      And no proxy has run

    @mc
    Scenario: A newer release is announced, never installed
      Given CLIProxyAPI 8.1.0 is released
      And the CLIProxyAPI plugin runs the fake binary
      Then the page offers CLIProxyAPI "8.1.0" as an update
      And the page shows the proxy running the binary it was set to, downloading nothing

    @mc
    Scenario: Switching to Connect while the release downloads connects at once
      Given the CLIProxyAPI 8.0.79 release for this machine, with its checksums
      And the fake CLIProxyAPI holds its release downloads
      And the CLIProxyAPI plugin is set to run without a binary
      When the user turns the CLIProxyAPI plugin on
      Then the page shows the proxy "downloading"
      When the user switches the CLIProxyAPI plugin to connect to it with the management key "their-secret"
      Then the page shows the proxy "connected"
      And the proxy lets agents in with the plugin's client key
      And no proxy has run

  Rule: Connect uses a proxy the user runs, with its management key

    The management key goes with every call, so Connect speaks http only to a proxy on
    this machine; one elsewhere is reached over https, its certificate checked.

    @mc
    Scenario: Connect adds the plugin's client key to the proxy's and runs nothing
      Given the fake CLIProxyAPI lets agents in with the key "their-key"
      When the user connects the CLIProxyAPI plugin to it with the management key "their-secret"
      Then the page shows the proxy "connected"
      And the proxy lets agents in with "their-key" and the plugin's client key
      And the proxy was asked with the management key "their-secret"
      And no proxy has run

    @mc
    Scenario: A management key the proxy refuses is not tried again by itself
      Given the fake CLIProxyAPI refuses every management key saying "invalid management key"
      When the user connects the CLIProxyAPI plugin to it with the management key "wrong"
      Then the page shows the proxy "blocked" saying "invalid management key"
      When the page refreshes 3 times
      Then the proxy was refused once
      When the fake CLIProxyAPI takes the management key again and the user retries
      Then the page shows the proxy "connected"

    @mc
    Scenario: A proxy that keeps no usage still lets the plugin's agents in
      Given the fake CLIProxyAPI lets agents in with the key "their-key"
      And the fake CLIProxyAPI keeps no usage, saying "usage statistics are disabled"
      When the user connects the CLIProxyAPI plugin to it with the management key "their-secret"
      Then the page shows the proxy "connected"
      And the proxy lets agents in with "their-key" and the plugin's client key
      And the page shows no usage, saying "usage statistics are disabled"

    @mc
    Scenario: Connect over http to a proxy elsewhere is refused
      Given the CLIProxyAPI plugin runs the fake binary
      When the user saves Connect to "http://192.0.2.10:8317" with the management key "their-secret"
      Then the save is refused saying "use https for one elsewhere"

    @mc
    Scenario: Connect to an address with a query is refused
      Given the CLIProxyAPI plugin runs the fake binary
      When the user saves Connect to "https://proxy.example/gateway?tenant=blue" with the management key "their-secret"
      Then the save is refused saying "without a query (?) or fragment (#)"

    @mc
    Scenario: Connect over http to a proxy elsewhere, saved while the plugin was off, is not used
      Given the user saves Connect to "http://192.0.2.10:8317" with the management key "their-secret"
      When the user turns the CLIProxyAPI plugin on
      Then the page shows the proxy "failed" saying "use https for one elsewhere"

    @mc
    Scenario: Connect over http to a proxy elsewhere, saved while the plugin was off, routes no agents there
      Given the user saves Connect to "http://192.0.2.10:8317" with the management key "their-secret"
      When the user turns the CLIProxyAPI plugin on
      Then Settings → Providers has no "plugin_cliproxyapi_claude"
      And Settings → Providers has no "plugin_cliproxyapi_codex"
      And the page shows "Claude via CLIProxyAPI" as not added, saying "use https for one elsewhere"

    @mc
    Scenario: Connect put right after it was refused routes agents through the proxy
      Given the user saves Connect to "http://192.0.2.10:8317" with the management key "their-secret"
      And the user turns the CLIProxyAPI plugin on
      When the user saves Connect to the fake CLIProxyAPI with the management key "their-secret"
      Then Settings → Providers has "plugin_cliproxyapi_claude" named "Claude via CLIProxyAPI"
      And Settings → Providers has "plugin_cliproxyapi_codex" named "Codex via CLIProxyAPI"

    @mc
    Scenario: Run put in place of a refused Connect routes agents through the proxy it runs
      Given the user saves Connect to "http://192.0.2.10:8317" with the management key "their-secret"
      And the user turns the CLIProxyAPI plugin on
      When the user switches the CLIProxyAPI plugin to run the fake binary
      Then Settings → Providers has "plugin_cliproxyapi_claude" named "Claude via CLIProxyAPI"
      And Settings → Providers has "plugin_cliproxyapi_codex" named "Codex via CLIProxyAPI"
      And the page shows the proxy "running"

    @mc
    Scenario: A proxy replaced at the same address is given the client key again
      Given the fake CLIProxyAPI lets agents in with the key "their-key"
      When the user connects the CLIProxyAPI plugin to it with the management key "their-secret"
      Then the proxy lets agents in with "their-key" and the plugin's client key
      When the fake CLIProxyAPI stops answering
      And the page refreshes
      And a fresh fake CLIProxyAPI answers in its place, letting agents in with the key "their-key"
      And the page refreshes
      Then the proxy lets agents in with "their-key" and the plugin's client key

    @mc
    Scenario: A client key the proxy did not take is added again on the next drain
      Given the fake CLIProxyAPI lets agents in with the key "their-key"
      And the fake CLIProxyAPI answers the next "PUT /config/access/api-keys" with 500 saying "config is read-only"
      When the user connects the CLIProxyAPI plugin to it with the management key "their-secret"
      Then the proxy lets agents in only with "their-key"
      When the page refreshes
      Then the proxy lets agents in with "their-key" and the plugin's client key

    @mc
    Scenario: A management key refused part way through a drain is not sent again
      Given the fake CLIProxyAPI answers the next "GET /observability/logs" with 401 saying "invalid management key"
      When the user connects the CLIProxyAPI plugin to it with the management key "their-secret"
      Then the page shows the proxy "blocked" saying "invalid management key"
      And the proxy was asked nothing after "GET /observability/logs"

  Rule: Accounts sign in through the proxy, from any device, by pasting the address the browser ends on

    The proxy signs an account in with OAuth. Its provider sends the browser back to an
    address on the machine the browser runs on, which nothing answers; the page asks
    the user to paste that address, and the proxy finishes the sign-in from it. That
    works the same from the MC's own machine, another computer or a phone.

    @mc
    Scenario: Signing in to Claude by pasting the address the browser ended on
      Given the CLIProxyAPI plugin runs the fake binary
      When the user signs in to "claude" from the page
      Then the page gives the proxy's sign-in address for "claude"
      And the sign-in is one the user finishes by pasting the address
      When the user pastes the address the browser ended on
      Then the page lists the "claude" account "user@example.com"
      And no sign-in is waiting

    @mc
    Scenario: A sign-in the provider refused says why
      Given the CLIProxyAPI plugin runs the fake binary
      When the user signs in to "codex" from the page
      And the user pastes an address the provider ended with the error "access_denied"
      Then the sign-in failed saying "access_denied"

    @mc
    Scenario: A sign-in the user cancels is cancelled on the proxy too
      Given the CLIProxyAPI plugin runs the fake binary
      When the user signs in to "claude" from the page
      And the user cancels the sign-in from the page
      Then no sign-in is waiting
      And the proxy was told to forget the sign-in

    @mc
    Scenario: A sign-in waiting on the proxy is dropped when the proxy moves
      Given the CLIProxyAPI plugin runs the fake binary
      When the user signs in to "claude" from the page
      And the user sets the CLIProxyAPI port to 18558
      Then no sign-in is waiting

    @mc
    Scenario: A sign-in address that is not a web address is not given to the page
      Given the CLIProxyAPI plugin runs the fake binary
      And the fake CLIProxyAPI hands out the sign-in address "javascript:alert(1)"
      When the user tries to sign in to "claude" from the page
      Then the page's call fails saying "not http or https"
      And no sign-in is waiting

    @mc
    Scenario: An account can be switched off and removed
      Given the CLIProxyAPI plugin runs the fake binary
      And the proxy has the "claude" account "user@example.com"
      When the user switches the account "user@example.com" off
      Then the page lists the account "user@example.com" as off
      When the user removes the account "user@example.com"
      Then the page lists no accounts

  Rule: Usage is summed per day, account and model, and kept for 30 days

    @mc
    Scenario: What the proxy handed out is summed per account and model
      Given the CLIProxyAPI plugin runs the fake binary
      And the proxy has the "claude" account "user@example.com"
      And the proxy handed out these requests today:
        | account                         | model           | input | output | failed |
        | claude-user@example.com.json    | claude-sonnet-4 | 100   | 20     | false  |
        | claude-user@example.com.json    | claude-sonnet-4 | 50    | 5      | true   |
        | codex-other.json                | gpt-5           | 10    | 1      | false  |
      When the page refreshes
      Then the page shows today's usage:
        | account          | model           | requests | failed | input | output |
        | user@example.com | claude-sonnet-4 | 2        | 1      | 150   | 25     |
        | codex-other.json | gpt-5           | 1        | 0      | 10    | 1      |

  Rule: Upstream API keys are kept on the proxy and shown masked

    @mc
    Scenario: Adding and removing an upstream key
      Given the CLIProxyAPI plugin runs the fake binary
      When the user adds the "claude" API key "sk-ant-abcdefghijklmnop" with the base URL "https://api.example.com"
      Then the page shows the "claude" key "sk-a…mnop" with the base URL "https://api.example.com"
      And the page never shows the key "sk-ant-abcdefghijklmnop"
      When the user removes the "claude" key "sk-a…mnop"
      Then the page shows no upstream keys

    @mc
    Scenario: A key the proxy refuses shows the proxy's own message
      Given the CLIProxyAPI plugin runs the fake binary
      And the fake CLIProxyAPI refuses API keys saying "claude-api-key[0]: unsupported field"
      When the user adds the "claude" API key "sk-ant-abcdefghijklmnop"
      Then the page's call fails saying "claude-api-key[0]: unsupported field"

    @mc
    Scenario: Removing a key removes that key, though another was added on the proxy since
      Given the CLIProxyAPI plugin runs the fake binary
      And the user adds the "claude" API key "sk-ant-abcdefghijklmnop" with the base URL "https://api.example.com"
      And the "claude" key "sk-ant-zyxwvutsrqpo" was added first on the proxy since
      When the user removes the "claude" key "sk-a…mnop"
      Then the proxy holds only the "claude" key "sk-ant-zyxwvutsrqpo"

    @mc
    Scenario: A key list the proxy failed to give is not taken for none
      Given the CLIProxyAPI plugin runs the fake binary
      And the user adds the "claude" API key "sk-ant-abcdefghijklmnop" with the base URL "https://api.example.com"
      And the fake CLIProxyAPI answers the next "GET /config/api-keys/claude" with 500 saying "config is being written"
      When the user adds the "claude" API key "sk-ant-zyxwvutsrqpo"
      Then the page's call fails saying "config is being written"
      And the proxy holds only the "claude" key "sk-ant-abcdefghijklmnop"

    @mc
    Scenario: A key added is kept for the proxy's next start, though the proxy did not list it
      Given the CLIProxyAPI plugin runs the fake binary
      And the user adds the "claude" API key "sk-ant-abcdefghijklmnop" with the base URL "https://api.example.com"
      And the fake CLIProxyAPI answers the next "GET /config/api-keys" with 500 saying "busy"
      When the user sets the CLIProxyAPI port to 18559
      Then the proxy starts with the "claude" key "sk-ant-abcdefghijklmnop"

  Rule: The page shows the proxy's log

    @mc
    Scenario: New log lines are shown and the log can be cleared
      Given the CLIProxyAPI plugin runs the fake binary
      When the proxy logs "POST /v1/messages 200" and the page refreshes
      Then the page shows the log line "POST /v1/messages 200"
      When the user clears the log
      Then the page shows the proxy's own output in place of the log

    @mc
    Scenario: A proxy at another address does not show the first one's log
      Given the CLIProxyAPI plugin runs the fake binary
      When the proxy logs "POST /v1/messages 200" and the page refreshes
      Then the page shows the log line "POST /v1/messages 200"
      When the user sets the CLIProxyAPI port to 18559
      Then the page shows no log lines

  Rule: Claude and Codex via CLIProxyAPI follow the proxy, and the user's edits stand

    "Claude via CLIProxyAPI" and "Codex via CLIProxyAPI" are the plugin's: it changes
    what routes them through the proxy when the port or the key changes. The rest is
    the user's to rename, switch off or delete; one the user deletes stays deleted
    until the user adds it back from the plugin's page. An instance the user already
    has under one of the plugin's ids stays the user's, and the page says so.

    @mc
    Scenario: The plugin adds Claude and Codex, routed through the proxy
      Given the CLIProxyAPI plugin runs the fake binary
      Then Settings → Providers has "plugin_cliproxyapi_claude" named "Claude via CLIProxyAPI"
      And the agent of "plugin_cliproxyapi_claude" is sent to the proxy with the plugin's client key and no API key
      And the agent of "plugin_cliproxyapi_claude" keeps its Claude home in the plugin's data folder
      And Settings → Providers has "plugin_cliproxyapi_codex" named "Codex via CLIProxyAPI"
      And the agent of "plugin_cliproxyapi_codex" uses the proxy as its model provider, with the plugin's client key

    @mc
    Scenario: A new port moves the instances to it, keeping the user's name
      Given the CLIProxyAPI plugin runs the fake binary
      And the user renamed "plugin_cliproxyapi_claude" to "Claude (pool)"
      When the user sets the CLIProxyAPI port to 18555
      Then the agent of "plugin_cliproxyapi_claude" is sent to "http://127.0.0.1:18555"
      And the agent of "plugin_cliproxyapi_codex" is sent to "http://127.0.0.1:18555/v1"
      And Settings → Providers has "plugin_cliproxyapi_claude" named "Claude (pool)"
      And the proxy runs again as a new process

    @mc
    Scenario: Turning the plugin off takes its instances out, and on again brings them back
      Given the CLIProxyAPI plugin runs the fake binary
      When the user turns the CLIProxyAPI plugin off
      Then Settings → Providers has no "plugin_cliproxyapi_claude"
      And Settings → Providers has no "plugin_cliproxyapi_codex"
      When the user turns the CLIProxyAPI plugin on
      Then Settings → Providers has "plugin_cliproxyapi_claude" named "Claude via CLIProxyAPI"
      And Settings → Providers has "plugin_cliproxyapi_codex" named "Codex via CLIProxyAPI"

    @mc
    Scenario: An instance the user deleted stays deleted until the user adds it back
      Given the CLIProxyAPI plugin runs the fake binary
      When the user deletes "plugin_cliproxyapi_codex" in Settings → Providers
      Then the page shows "Codex via CLIProxyAPI" as removed
      When the user sets the CLIProxyAPI port to 18556
      And the user turns the CLIProxyAPI plugin off and on again
      Then Settings → Providers has no "plugin_cliproxyapi_codex"
      And Settings → Providers has "plugin_cliproxyapi_claude" named "Claude via CLIProxyAPI"
      When the user adds "Codex via CLIProxyAPI" back from the page
      Then Settings → Providers has "plugin_cliproxyapi_codex" named "Codex via CLIProxyAPI"

    @mc
    Scenario: An instance the user deleted while the plugin was down stays deleted
      Given the CLIProxyAPI plugin runs the fake binary
      And the plugin's server is busy
      When the user deletes "plugin_cliproxyapi_codex" in Settings → Providers
      And the plugin's server crashes
      Then the page shows "Codex via CLIProxyAPI" as removed
      And Settings → Providers has no "plugin_cliproxyapi_codex"

    @mc
    Scenario: An instance of the user's under the plugin's id stays theirs, and the page says why
      Given the user has a Codex instance of their own as "plugin_cliproxyapi_codex" named "My Codex"
      And the CLIProxyAPI plugin runs the fake binary
      Then Settings → Providers has "plugin_cliproxyapi_codex" named "My Codex"
      And the page shows "Codex via CLIProxyAPI" as not added, saying "a provider instance of the user's"
      And Settings → Providers has "plugin_cliproxyapi_claude" named "Claude via CLIProxyAPI"

    @mc
    Scenario: Adding back an instance the user has taken the id of says so, and keeps saying it
      Given the CLIProxyAPI plugin runs the fake binary
      When the user deletes "plugin_cliproxyapi_codex" in Settings → Providers
      Then the page shows "Codex via CLIProxyAPI" as removed
      Given the user has a Codex instance of their own as "plugin_cliproxyapi_codex" named "My Codex"
      When the user adds "Codex via CLIProxyAPI" back from the page
      Then the page shows "Codex via CLIProxyAPI" as not added, saying "a provider instance of the user's"
      When the user turns the CLIProxyAPI plugin off and on again
      Then the page shows "Codex via CLIProxyAPI" as not added, saying "a provider instance of the user's"
      And Settings → Providers has "plugin_cliproxyapi_codex" named "My Codex"

  Rule: The page shows the proxy and what it holds

    @desktop @mobile @backlog-mobile
    Scenario: The page shows the proxy, its accounts, usage, keys and log
      Given the CLIProxyAPI page with the proxy running and the "claude" account "user@example.com"
      Then the page shows the proxy running CLIProxyAPI 8.0.79
      And the page lists the account "user@example.com"
      And the page shows usage for "user@example.com"
      And the page shows the "claude" key "sk-a…mnop"
      And the page shows the log line "POST /v1/messages 200"

    @desktop @mobile @backlog-mobile
    Scenario: The page says when it is connected to a proxy it did not start
      Given the CLIProxyAPI page connected to the proxy at "http://127.0.0.1:18317"
      Then the page says it is connected to the proxy at "http://127.0.0.1:18317"

    @desktop @mobile @backlog-mobile
    Scenario: The page says why a proxy gives no usage
      Given the CLIProxyAPI page with the proxy giving no usage, saying "usage statistics are off"
      Then the page says the proxy gives no usage, saying "usage statistics are off"

    @desktop @mobile @backlog-mobile
    Scenario: The page says why an instance of the plugin's was not added
      Given the CLIProxyAPI page with "Codex via CLIProxyAPI" not added, saying "a provider instance of the user's"
      Then the page shows "Codex via CLIProxyAPI" as not added, saying "a provider instance of the user's"

    @desktop @mobile @backlog-mobile
    Scenario: The page signs in by asking for the address the browser ended on
      Given the CLIProxyAPI page with the proxy running
      When the user signs in to Claude on the page
      Then the page shows the sign-in address and asks for the address the browser ended on
      When the user pastes "http://localhost:54545/callback?code=abc&state=st-1" on the page
      Then the page asked the MC to finish the sign-in with that address

    @desktop @mobile @backlog-mobile
    Scenario: The page says when the proxy refused the management key
      Given the CLIProxyAPI page with the proxy refusing the management key saying "invalid management key"
      Then the page says the proxy refused the management key "invalid management key"
      When the user retries on the page
      Then the page asked the MC to retry
