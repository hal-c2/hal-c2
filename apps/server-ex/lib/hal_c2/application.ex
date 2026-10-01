defmodule HalC2.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.fetch_env!(:hal_c2, :start_mc) do
        :ok = HalC2.Desktop.configure()
        :ok = prepare_files()

        [
          # Distribution starts here, before anything reads `node()`.
          HalC2.Cluster,
          {HalC2.Store, path: HalC2.Store.home_path()},
          HalC2.Auth,
          HalC2.Settings,
          HalC2.Streams,
          HalC2.Shell,
          # Turns this MC was running when it stopped end as interrupted.
          %{id: :recovery, start: {HalC2.Orchestration.Recovery, :start_link, []}},
          HalC2.Orchestration.TurnWatch,
          Supervisor.child_spec({Task, &HalC2.Search.backfill/0}, id: :search_backfill),
          {Registry, keys: :unique, name: HalC2.Codex.Registry},
          {Registry, keys: :unique, name: HalC2.Claude.Registry},
          {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
          {Registry, keys: :unique, name: HalC2.Terminal.Registry},
          {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one},
          HalC2.Terminal.Hub,
          # Moves a restart or a lost machine cut off are settled.
          HalC2.ThreadMove,
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
          # Environments outside the cluster this MC was paired with.
          {Registry, keys: :unique, name: HalC2.Links.Registry},
          {DynamicSupervisor, name: HalC2.Links.Supervisor, strategy: :one_for_one},
          HalC2.Links,
          HalC2.Web,
          # server-runtime.json, once the listener is bound; removed first on the way down.
          HalC2.RuntimeRecord,
          # HAL-C2 Connect: the managed tunnel, the startup link, activity publishing.
          HalC2.Connect.Supervisor,
          # Turns the restart cut off go on, where the user asked for that.
          Supervisor.child_spec({Task, &HalC2.Orchestration.Recovery.continue/0}, id: :continue),
          # Projects that ask for it are brought up to date.
          Supervisor.child_spec({Task, &HalC2.Projects.auto_pull/0}, id: :auto_pull),
          # Members of this machine's cluster are connected once everything is up.
          HalC2.Cluster.Discovery
        ]
      else
        []
      end

    # The services are independent, so one stall that times several out at once (a
    # machine deep in swap) must not spend the default budget of 3 and stop the MC.
    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: HalC2.Supervisor,
      max_restarts: 20,
      max_seconds: 10
    )
  end

  @doc """
  Readies the MC's directories before anything opens a file in them: migrates from
  an old home the first time (`HalC2.Migration`), unless `:migrate` is false (a
  checkout) or the MC keeps everything in one directory (tests), then creates the
  directories that are missing. `opts` go to `HalC2.Migration.run/1`.
  """
  def prepare_files(opts \\ []) do
    if Application.get_env(:hal_c2, :migrate, true) and
         not is_binary(Application.get_env(:hal_c2, :home)),
       do: HalC2.Migration.run(opts)

    HalC2.Paths.ensure!()
  end
end
