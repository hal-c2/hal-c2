defmodule HalC2.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.fetch_env!(:hal_c2, :start_node) do
        :ok = HalC2.Desktop.configure()
        home = Application.fetch_env!(:hal_c2, :home)

        [
          {HalC2.Store, path: HalC2.Store.home_path()},
          HalC2.Auth,
          HalC2.Settings,
          HalC2.Streams,
          HalC2.Shell,
          # Turns this node was running when it stopped end as interrupted.
          %{id: :recovery, start: {HalC2.Orchestration.Recovery, :start_link, []}},
          Supervisor.child_spec({Task, &HalC2.Search.backfill/0}, id: :search_backfill),
          {Registry, keys: :unique, name: HalC2.Codex.Registry},
          {Registry, keys: :unique, name: HalC2.Claude.Registry},
          {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
          {Registry, keys: :unique, name: HalC2.Terminal.Registry},
          {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one},
          HalC2.Terminal.Hub,
          {Registry, keys: :unique, name: HalC2.Vcs.Registry},
          HalC2.Workspace,
          HalC2.WorktreeSetup,
          HalC2.ScheduledTasks,
          HalC2.ProjectClones,
          HalC2.Preview,
          HalC2.PreviewAutomation,
          HalC2.LocalServers,
          HalC2.Devices,
          HalC2.Diagnostics,
          HalC2.PullRequests.Refreshes,
          HalC2.PullRequests.Discovery,
          HalC2.PullRequests.Sync,
          HalC2.Orchestration.Settlement,
          # Threads stopped on a usage limit resume at the reset, where the user asked.
          HalC2.Orchestration.LimitRecovery,
          HalC2.Usage,
          HalC2.Mcp,
          HalC2.Plugins,
          HalC2.Upgrade,
          HalC2.BackgroundPolicy,
          HalC2.EnvironmentThemes,
          HalC2.ProviderUsageLimits,
          HalC2.UsageLimitSources,
          HalC2.StorageCleanup,
          HalC2.Orchestration.IdleSessions,
          {Registry, keys: :unique, name: HalC2.ProviderAuth.Registry},
          {DynamicSupervisor, name: HalC2.ProviderAuth.Supervisor, strategy: :one_for_one},
          {DynamicSupervisor, name: HalC2.Vcs.Supervisor, strategy: :one_for_one},
          Supervisor.child_spec({Task, &HalC2.Codex.Provider.load/0}, id: :codex_models),
          {Registry, keys: :unique, name: HalC2.Acp.Registry},
          {Registry, keys: :unique, name: HalC2.Pi.Registry},
          HalC2.Acp.UrlAuth,
          HalC2.Acp.Antigravity.Installation,
          Supervisor.child_spec({Task, &HalC2.Acp.load/0}, id: :acp_models),
          HalC2.Web,
          # HAL-C2 Connect: the managed tunnel, the startup link, activity publishing.
          HalC2.Connect.Supervisor,
          # Turns the restart cut off go on, where the user asked for that.
          Supervisor.child_spec({Task, &HalC2.Orchestration.Recovery.continue/0}, id: :continue),
          # Projects that ask for it are brought up to date.
          Supervisor.child_spec({Task, &HalC2.Projects.auto_pull/0}, id: :auto_pull)
        ] ++ discovery(home)
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: HalC2.Supervisor)
  end

  # Named nodes find peers listed in HAL_C2_PEERS (node names such as hal_c2@192.168.1.20);
  # nodes with cluster certificates also search the tailnet.
  @doc false
  def discovery(home) do
    static =
      case System.get_env("HAL_C2_PEERS") do
        nil -> []
        peers -> [static: [strategy: Cluster.Strategy.Epmd, config: [hosts: parse_peers(peers)]]]
      end

    tailnet =
      if HalC2.Cluster.address(home), do: [tailnet: [strategy: HalC2.Cluster.Tailscale]], else: []

    if Node.alive?() and static ++ tailnet != [],
      do: [{Cluster.Supervisor, [static ++ tailnet, [name: HalC2.ClusterSupervisor]]}],
      else: []
  end

  defp parse_peers(peers),
    do: for(p <- String.split(peers, ",", trim: true), do: p |> String.trim() |> String.to_atom())
end
