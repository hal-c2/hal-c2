defmodule T3.FeaturesBacklogTest do
  @moduledoc """
  What clients do against the Node server that this node cannot serve yet, as
  Given/when/then scenarios. Each scenario is a skipped test until the node
  serves it; `node_parity_test.exs` points its `:backlog` rows here.

  `node_sources` are the Node server and contract files that implement or type
  the capability; `client_sources` are where a client depends on it. Both are
  checked to exist, so a moved file fails here instead of leaving a dead link.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  @node_roots ~w(apps/server/src/ packages/contracts/src/)
  @client_roots ~w(apps/web/src/ apps/mobile/src/ apps/tui/src/ apps/desktop-qt/)
  @scenario ~r/^Given .+, when .+, then .+\.$/

  @gaps [
    %{
      id: "provider-install",
      area: "Providers",
      node_capabilities: [
        "RPC provider.install.start",
        "RPC provider.install.cancel",
        "RPC provider.install.subscribe",
        "RPC provider.install.remove"
      ],
      node_sources: [
        "packages/contracts/src/rpc.ts",
        "apps/server/src/provider/providerInstallation.ts",
        "apps/server/src/ws.ts"
      ],
      client_sources: ["apps/web/src/components/settings/ProviderSetupSection.tsx"],
      scenarios: [
        "Given a provider CLI missing on the node, when the user starts its install from Settings, then install progress streams until the provider reports ready.",
        "Given a provider install in progress, when the user cancels it, then the install stops and the provider stays not installed.",
        "Given a provider the node installed, when the user removes it, then its managed binary is deleted and the provider list shows it as not installed."
      ]
    },
    %{
      id: "t3-connect-relay-client",
      area: "T3 Connect",
      node_capabilities: ["RPC cloud.getRelayClientStatus", "RPC cloud.installRelayClient"],
      node_sources: [
        "packages/contracts/src/rpc.ts",
        "apps/server/src/cloud/ManagedEndpointRuntime.ts",
        "apps/server/src/ws.ts"
      ],
      client_sources: [
        "apps/web/src/cloud/relayClientInstallDialog.ts",
        "apps/web/src/components/cloud/RelayClientInstallDialog.tsx"
      ],
      scenarios: [
        "Given a node without the relay client, when the user opens T3 Connect for it, then the node reports the relay client as not installed.",
        "Given the relay client is missing, when the user installs it from the dialog, then install stages stream and the node reports the client as ready."
      ]
    },
    %{
      id: "t3-connect-linking",
      area: "T3 Connect",
      node_capabilities: [
        "HTTP POST /api/connect/link-proof",
        "HTTP POST /api/connect/relay-config",
        "HTTP GET /api/connect/link-state",
        "HTTP POST /api/connect/unlink",
        "HTTP POST /api/connect/preferences",
        "HTTP POST /api/connect/mint-credential",
        "HTTP POST /api/t3-connect/health",
        "HTTP POST /api/t3-connect/mint-credential"
      ],
      node_sources: [
        "packages/contracts/src/environmentHttp.ts",
        "apps/server/src/cloud/http.ts"
      ],
      client_sources: [
        "apps/web/src/cloud/linkEnvironment.ts",
        "apps/web/src/components/settings/ConnectionsSettings.tsx",
        "apps/mobile/src/features/cloud/T3ConnectProfilePage.tsx"
      ],
      scenarios: [
        "Given a user signed in to T3 Connect, when they link this node, then the node proves its identity and joins their environment list.",
        "Given a linked node, when the user unlinks it, then the relay stops reaching it and the link state reads unlinked.",
        "Given a linked node, when T3 Connect checks its health, then the node answers once per nonce and refuses a replayed request."
      ]
    },
    %{
      id: "terminal-list",
      area: "Terminals",
      node_capabilities: ["RPC terminal.list"],
      node_sources: ["packages/contracts/src/rpc.ts", "apps/server/src/terminal/Manager.ts"],
      client_sources: ["apps/tui/src/connection.ts", "apps/tui/src/terminalTabs.ts"],
      scenarios: [
        "Given a thread whose terminals outlived the TUI session, when the TUI opens the thread, then its tabs list every terminal the node kept.",
        "Given a terminal the user closed, when the TUI lists the thread's terminals again, then the closed terminal is gone."
      ]
    },
    %{
      id: "hosted-web-app",
      area: "Web app hosting",
      node_capabilities: [
        "HTTP GET the built web app",
        "HTTP POST /api/auth/browser-session"
      ],
      node_sources: [
        "apps/server/src/http.ts",
        "apps/server/src/auth/http.ts",
        "packages/contracts/src/environmentHttp.ts"
      ],
      client_sources: ["apps/web/src/environments/primary/auth.ts"],
      scenarios: [
        "Given a node started for a local browser, when the browser opens the node's origin, then it loads the T3 Code web app instead of a pairing help page.",
        "Given the web app served by the node, when it exchanges its bootstrap credential, then the node sets a browser session cookie and the app connects without pairing.",
        "Given a browser session, when the user revokes that client from Connections, then the browser's next request is refused."
      ]
    },
    %{
      id: "client-trace-forwarding",
      area: "Observability",
      node_capabilities: ["HTTP POST /api/observability/v1/traces"],
      node_sources: [
        "apps/server/src/http.ts",
        "apps/server/src/observability/BrowserTraceCollector.ts"
      ],
      client_sources: ["apps/web/src/observability/clientTracing.ts"],
      scenarios: [
        "Given client tracing is on, when the web app exports spans to its primary node, then the node accepts them instead of answering not found.",
        "Given an OTLP collector configured on the node, when client spans arrive, then the node forwards them to the collector."
      ]
    },
    %{
      id: "project-favicon-assets",
      area: "Assets",
      node_capabilities: ["asset resource project-favicon"],
      node_sources: [
        "packages/contracts/src/assets.ts",
        "apps/server/src/assets/AssetAccess.ts"
      ],
      client_sources: [
        "apps/web/src/components/ProjectFavicon.tsx",
        "apps/mobile/src/components/ProjectFavicon.tsx"
      ],
      scenarios: [
        "Given a project with a favicon in its repository, when the sidebar asks for the project's icon, then the node serves that favicon.",
        "Given a project without a favicon, when the sidebar asks for its icon, then the node answers not found and the sidebar shows its default icon."
      ]
    },
    %{
      id: "native-app-icon-assets",
      area: "Assets",
      node_capabilities: ["asset resource native-app-icon"],
      node_sources: [
        "packages/contracts/src/assets.ts",
        "apps/server/src/assets/AssetAccess.ts"
      ],
      client_sources: [
        "apps/web/src/components/chat/MessagesTimeline.tsx",
        "apps/mobile/src/features/threads/thread-work-log.tsx"
      ],
      scenarios: [
        "Given a work log entry that opened a desktop app, when the timeline renders it, then the node serves that app's icon.",
        "Given an app the node cannot find, when the timeline asks for its icon, then the node answers not found and the entry keeps its text."
      ]
    },
    %{
      id: "github-media-assets",
      area: "Assets",
      node_capabilities: ["asset resource github-media"],
      node_sources: [
        "packages/contracts/src/assets.ts",
        "apps/server/src/assets/AssetAccess.ts",
        "apps/server/src/http.ts"
      ],
      client_sources: [
        "apps/web/src/components/ChatMarkdown.tsx",
        "apps/web/src/components/pullRequest/PullRequestMarkdown.tsx"
      ],
      scenarios: [
        "Given a pull request body with an image uploaded to GitHub, when the review panel renders it, then the node proxies the image with its GitHub credentials.",
        "Given media from a private repository, when a paired client asks for it, then the node fetches it and the client never receives the GitHub token."
      ]
    }
  ]

  test "the backlog catalog is well formed and its sources exist" do
    ids = Enum.map(@gaps, & &1.id)
    assert ids -- Enum.uniq(ids) == [], "duplicate gap ids"

    scenarios = Enum.flat_map(@gaps, & &1.scenarios)
    assert scenarios -- Enum.uniq(scenarios) == [], "duplicate scenarios"

    for gap <- @gaps do
      for field <- [:id, :area], do: assert(String.trim(gap[field]) not in ["", nil])

      for field <- [:node_capabilities, :node_sources, :client_sources, :scenarios] do
        values = Map.fetch!(gap, field)
        assert values != [], "#{gap.id}: #{field} is empty"
        assert values -- Enum.uniq(values) == [], "#{gap.id}: duplicate #{field}"
      end

      for capability <- gap.node_capabilities,
          do: assert(capability == String.trim(capability) and capability != "")

      for {field, roots} <- [node_sources: @node_roots, client_sources: @client_roots],
          path <- Map.fetch!(gap, field) do
        assert String.starts_with?(path, roots), "#{gap.id}: #{path} is not a #{field} path"
        assert File.exists?(Path.join(@root, path)), "#{gap.id}: #{path} does not exist"
      end

      for scenario <- gap.scenarios,
          do: assert(scenario =~ @scenario, "#{gap.id}: not Given/when/then: #{scenario}")
    end
  end

  for gap <- @gaps do
    describe "#{gap.area} (#{gap.id})" do
      for scenario <- gap.scenarios do
        @tag skip: "backlog: #{gap.id}"
        test scenario do
          flunk("not served by this node yet")
        end
      end
    end
  end
end
