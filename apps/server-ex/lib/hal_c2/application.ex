defmodule HalC2.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.fetch_env!(:hal_c2, :start_mc) do
        :ok = HalC2.Desktop.configure()
        :ok = lock_home()
        :ok = prepare_files()
        children()
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
  The MC's services in start order. A hot update starts the ones the running MC
  does not have yet (`HalC2.Upgrade`).
  """
  def children do
    [
      # Boot took the home's lock (`lock_home/0`); an MC updated in place takes it here.
      HalC2.HomeLock,
      # Distribution starts here, before anything reads `node()`.
      HalC2.Cluster,
      # Before anything starts or resumes a provider: kills the programs an MC
      # that died left running, so no thread gets a second agent, and records
      # every program started from here on. It needs only its files, which
      # `prepare_files/0` already made.
      HalC2.Subprocess.Orphans,
      {HalC2.Store, path: HalC2.Store.home_path()},
      HalC2.Auth,
      HalC2.Settings,
      HalC2.Streams,
      HalC2.Shell,
      # The other members' files, as folders on this machine.
      HalC2.MachineFiles,
      # Turns this MC was running when it stopped end as interrupted.
      %{id: :recovery, start: {HalC2.Orchestration.Recovery, :start_link, []}},
      HalC2.Orchestration.TurnWatch,
      # The recorded side effects of accepted commands, replayed or cancelled
      # for what the last boot left unfinished.
      HalC2.Orchestration.Effects,
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
      # Dev servers on another MC, reached from this machine's browser.
      HalC2.PreviewForward,
      HalC2.PreviewAutomation,
      HalC2.LocalServers,
      HalC2.Devices,
      HalC2.Diagnostics,
      HalC2.PullRequests.Refreshes,
      HalC2.PullRequests.Discovery,
      HalC2.PullRequests.Sync,
      HalC2.PullRequests.Wakes,
      HalC2.Orchestration.Settlement,
      # Agent alerts to the phones, through their UnifiedPush distributors.
      HalC2.Push,
      # Threads stopped on a usage limit resume at the reset, where the user asked.
      HalC2.Orchestration.LimitRecovery,
      HalC2.Usage,
      HalC2.Mcp,
      HalC2.Plugins,
      # The Slack connection plugins borrow, made again from the stored tokens.
      HalC2.Slack,
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
      Supervisor.child_spec({Task, &HalC2.Codex.Provider.boot/0}, id: :codex_models),
      Supervisor.child_spec({Task, &HalC2.Claude.Provider.load/0}, id: :claude_models),
      Supervisor.child_spec({Task, &HalC2.ModelManifest.refresh/0}, id: :model_manifest),
      {Registry, keys: :unique, name: HalC2.Acp.Registry},
      {Registry, keys: :unique, name: HalC2.Pi.Registry},
      {Registry, keys: :unique, name: HalC2.Muse.Registry},
      HalC2.Acp.UrlAuth,
      HalC2.Acp.Antigravity.Installation,
      # Owns the table of live Antigravity runtime temp directories.
      HalC2.Acp.Antigravity.SessionFiles,
      Supervisor.child_spec({Task, &HalC2.Acp.load/0}, id: :acp_models),
      HalC2.Web,
      # server-runtime.json, once the listener is bound; removed first on the way down.
      HalC2.RuntimeRecord,
      # Turns the restart cut off go on, where the user asked for that.
      Supervisor.child_spec({Task, &HalC2.Orchestration.Recovery.continue/0}, id: :continue),
      # Projects that ask for it are brought up to date.
      Supervisor.child_spec({Task, &HalC2.Projects.auto_pull/0}, id: :auto_pull),
      # Members of this machine's cluster are connected once everything is up.
      HalC2.Cluster.Discovery
    ]
  end

  # The exit status of an MC that found its HAL-C2 home in use. The desktop app's host
  # (apps/desktop-qt/host/elixirMc.ts) then uses the MC already running there.
  @home_in_use 73

  # One MC per home (`HalC2.HomeLock`). A background service waits its turn, since
  # its supervisor would only start it again; anything else stops at once. The release
  # service's wrapper says so with HAL_C2_SERVICE, a unit run from a checkout with
  # HAL_C2_WAIT_FOR_HOME (`HalC2.Service`).
  defp lock_home do
    HalC2.Paths.mkdir_private!(HalC2.Paths.data_dir())
    wait = "1" in [System.get_env("HAL_C2_SERVICE"), System.get_env("HAL_C2_WAIT_FOR_HOME")]

    case HalC2.HomeLock.acquire(wait: wait) do
      :ok ->
        :ok

      {:error, :held} ->
        IO.puts(:stderr, "Another MC is already running on #{HalC2.Paths.data_dir()}.")
        System.halt(@home_in_use)
    end
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
    # The tokens of the environments an MC linked to outside its cluster, before MCs
    # connected only by clustering.
    HalC2.Secrets.delete("environment-links")
    forget_connect()
  end

  # HAL-C2 Connect, the relay MCs once linked to, is gone. A linked MC left its
  # credentials, replay guards and sign-in behind, every one a `cloud-*` secret, and
  # its relay client (cloudflared) in the cache.
  defp forget_connect do
    HalC2.Secrets.delete_prefixed("cloud-")
    File.rm_rf(Path.join([HalC2.Paths.cache_dir(), "tools", "cloudflared"]))
    :ok
  end
end
