defmodule T3.Steps.Platform.BackgroundAndCleanup do
  @moduledoc "Steps for features/node/platform/background-and-cleanup.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.BackgroundPolicy
  alias T3.Test.Node
  alias T3.Test.Node.World

  @presets %{
    "performance" => %{fetch: 15_000, health: 60_000},
    "balanced" => %{fetch: 30_000, health: 300_000},
    "battery-saver" => %{fetch: 0, health: 900_000}
  }
  @pause_flags ~w(pauseWhenHostLocked pauseWhenHostLowPower pauseWhenClientLowPower pauseWhenOnBattery)

  # --- helpers ---------------------------------------------------------------------

  # The policy, with the test process told of each change (`await_policy/2`).
  defp policy(context) do
    Node.ensure(T3.Settings)
    Node.ensure(BackgroundPolicy)

    if context[:following_policy] do
      context
    else
      {:ok, _} = BackgroundPolicy.subscribe(self())
      Map.put(context, :following_policy, true)
    end
  end

  # The first policy satisfying `fun`: the current one, or the next change that does.
  defp await_policy(fun, timeout \\ 2_000) do
    snapshot = BackgroundPolicy.snapshot()
    if fun.(snapshot), do: snapshot, else: await_policy_change(fun, timeout, snapshot)
  end

  defp await_policy_change(fun, timeout, last) do
    receive do
      {:t3_background_policy, _node, snapshot} ->
        if fun.(snapshot), do: snapshot, else: await_policy_change(fun, timeout, snapshot)
    after
      timeout -> flunk("the background policy did not change as expected: #{inspect(last)}")
    end
  end

  defp profile(profile),
    do: World.merge_settings(%{"backgroundActivity" => %{"profile" => profile}})

  defp scope(cwd), do: %{"type" => "vcs-status", "cwd" => cwd}

  # Reports a client's activity over socket `name` and waits until its lease holds `fields`.
  defp report(context, fields, name \\ "default") do
    context = policy(context)

    lease =
      Map.merge(
        %{
          "clientId" => "tab-1",
          "clientKind" => "web",
          "visible" => true,
          "focused" => true,
          "recentlyInteracted" => false,
          "appState" => "active",
          "scopes" => [scope("/repo")],
          "observedAt" => World.iso_from_now(0)
        },
        fields
      )

    {_, context} = World.call!(context, "server.reportClientActivity", lease, name)
    expected = Map.drop(lease, ["observedAt", "ttlMs"])

    await_policy(fn %{"leases" => leases} ->
      Enum.any?(leases, &(Map.take(&1, Map.keys(expected)) == expected))
    end)

    context
  end

  defp host_power(context, fields) do
    snapshot =
      Map.merge(
        %{
          "source" => "electron-main",
          "idle" => "false",
          "idleSeconds" => 0,
          "locked" => "false",
          "suspended" => false,
          "onBattery" => "false",
          "lowPowerMode" => "false",
          "thermalState" => "nominal",
          "stale" => false,
          "updatedAt" => World.iso_from_now(0)
        },
        fields
      )

    {_, context} = World.call!(policy(context), "server.reportHostPowerState", snapshot)
    await_policy(&(&1["hostPower"] == snapshot))
    context
  end

  defp duration("never"), do: 0

  defp duration(text) do
    case Regex.run(~r/^(\d+)? ?(second|minute|hour)s?$/, text) do
      [_, "", unit] -> unit_ms(unit)
      [_, n, unit] -> String.to_integer(n) * unit_ms(unit)
      _ -> flunk("unknown duration #{inspect(text)}")
    end
  end

  defp unit_ms("second"), do: 1_000
  defp unit_ms("minute"), do: 60_000
  defp unit_ms("hour"), do: 3_600_000

  # A checkout with an origin and a second clone that pushes to it, watched by the
  # node (`T3.Vcs.Watch`) for the test process.
  defp watched_checkout(context) do
    for {name, spec} <- [
          {T3.Vcs.Registry, {Registry, keys: :unique, name: T3.Vcs.Registry}},
          {T3.Vcs.Supervisor,
           {DynamicSupervisor, name: T3.Vcs.Supervisor, strategy: :one_for_one}}
        ],
        do: Node.ensure(Supervisor.child_spec(spec, id: name))

    seed = World.git_repo(context, "seed")
    origin = Path.join(Node.tmp_dir(context.node, "origin"), "repo.git")
    World.git!(seed, ["clone", "-q", "--bare", seed, origin])
    checkout = Path.join(Node.tmp_dir(context.node, "checkout"), "repo")
    pusher = Path.join(Node.tmp_dir(context.node, "pusher"), "repo")
    World.git!(seed, ["clone", "-q", origin, checkout])
    World.git!(seed, ["clone", "-q", origin, pusher])
    World.git!(pusher, ~w(config user.email t3@example.com))
    World.git!(pusher, ~w(config user.name T3))

    %{"_tag" => "snapshot"} = T3.Vcs.Watch.subscribe(checkout, self())
    [{watch, _}] = Registry.lookup(T3.Vcs.Registry, checkout)
    Map.put(context, :checkout, %{path: checkout, pusher: pusher, watch: watch})
  end

  # Someone pushes to the checkout's origin; the node's next fetch would see it.
  defp push_upstream(%{checkout: %{pusher: pusher}}) do
    File.write!(Path.join(pusher, "upstream.txt"), "new\n")
    World.git!(pusher, ~w(add upstream.txt))
    World.git!(pusher, ~w(commit -q -m upstream))
    World.git!(pusher, ~w(push -q origin main))
    World.git!(pusher, ~w(rev-parse HEAD))
  end

  # Fires the watcher's fetch timer now, as if its interval had passed, and waits
  # until the watcher has handled it.
  defp fire_fetch(%{checkout: %{watch: watch}}) do
    send(watch, :fetch)
    _ = :sys.get_state(watch)
    :ok
  end

  defp artifacts_dir(context) do
    dir = Path.join(context.node.home, "browser-artifacts")
    File.mkdir_p!(dir)
    dir
  end

  defp artifact(context, name, days_old) do
    path = Path.join(artifacts_dir(context), name)
    File.write!(path, "png")
    File.touch!(path, System.os_time(:second) - days_old * 86_400)
    path
  end

  defp cleanup_timer_ms do
    ref = :sys.get_state(T3.StorageCleanup).timer
    assert is_reference(ref), "no sweep is scheduled"
    Process.read_timer(ref)
  end

  defp fire_sweep do
    send(T3.StorageCleanup, :tick)
    _ = :sys.get_state(T3.StorageCleanup)
    :ok
  end

  # --- presets -----------------------------------------------------------------------

  step "the background activity profile is {string}", %{args: [name]} = context do
    context = policy(context)
    profile(name)
    assert BackgroundPolicy.settings()["profile"] == name
    context
  end

  step "a custom background profile based on {string} with git fetch every minute",
       %{args: [base]} = context do
    context = policy(context)

    World.merge_settings(%{
      "backgroundActivity" => %{
        "profile" => "custom",
        "baseProfile" => base,
        "overrides" => %{"automaticGitFetchInterval" => 60_000}
      }
    })

    Map.put(context, :base_profile, base)
  end

  # The watcher of a checkout schedules its next fetch this far ahead.
  step ~r/^git fetches run every (?<every>.+)$/, %{args: [every]} = context do
    ms = duration(every)
    assert BackgroundPolicy.settings()["automaticGitFetchInterval"] == ms

    if ms > 0 do
      context = watched_checkout(context)
      left = Process.read_timer(:sys.get_state(context.checkout.watch).timer)
      assert left <= ms and left > ms - 2_000
      context
    else
      context
    end
  end

  step ~r/^provider health refreshes every (?<every>.+)$/, %{args: [every]} = context do
    assert T3.ProviderUsageLimits.interval() == duration(every)
    context
  end

  # Each constraint alone, with a client in front wanting a checkout's status.
  step ~r/^background work pauses when (?<when>.+)$/, %{args: [pauses]} = context do
    expected =
      case pauses do
        "the host is locked" ->
          [:host_locked]

        "the host is locked or low on power, or the client is low power" ->
          [:host_locked, :host_low_power, :client_low_power]

        "locked, low power on either side, or on battery" ->
          [:host_locked, :host_low_power, :client_low_power, :host_battery, :client_unplugged]
      end

    conditions = [
      none: {%{}, %{}},
      host_locked: {%{"locked" => "true"}, %{}},
      host_low_power: {%{"lowPowerMode" => "true"}, %{}},
      host_battery: {%{"onBattery" => "true"}, %{}},
      client_low_power: {%{}, %{"lowPowerMode" => "true"}},
      client_unplugged: {%{}, %{"batteryState" => "unplugged"}}
    ]

    Enum.reduce(conditions, context, fn {name, {host, client}}, context ->
      context =
        context
        |> host_power(host)
        |> report(Map.merge(%{"lowPowerMode" => "false", "batteryState" => "charging"}, client))

      assert BackgroundPolicy.run_scope_work?(scope("/repo")) == name not in expected,
             "with #{name}, work should #{if name in expected, do: "pause", else: "run"}"

      context
    end)
  end

  step "the other values come from {string}", %{args: [base]} = context do
    settings = BackgroundPolicy.settings()
    assert settings["profile"] == base
    assert T3.ProviderUsageLimits.interval() == @presets[base].health

    base_settings = BackgroundPolicy.settings(%{"backgroundActivity" => %{"profile" => base}})
    assert Map.take(settings, @pause_flags) == Map.take(base_settings, @pause_flags)
    refute settings["automaticGitFetchInterval"] == @presets[base].fetch
    context
  end

  # --- leases ---------------------------------------------------------------------------

  step "a client in front reports it shows a checkout's status", context do
    context = watched_checkout(context)
    report(context, %{"scopes" => [scope(context.checkout.path)]})
  end

  step "the node refreshes that checkout's git status periodically", context do
    path = context.checkout.path
    assert Process.read_timer(:sys.get_state(context.checkout.watch).timer) > 0
    pushed = push_upstream(context)
    fire_fetch(context)
    assert_receive {:t3_vcs, ^path, %{"_tag" => "remoteUpdated", "remote" => remote}}
    assert remote["behindCount"] == 1
    assert World.git!(path, ~w(rev-parse origin/main)) == pushed
    context
  end

  step "no client reports it shows a checkout", context do
    context = context |> policy() |> watched_checkout()
    assert BackgroundPolicy.snapshot()["leases"] == []
    context
  end

  step "the node does not poll that checkout's git status", context do
    path = context.checkout.path
    before = World.git!(path, ~w(rev-parse origin/main))
    push_upstream(context)
    fire_fetch(context)
    assert World.git!(path, ~w(rev-parse origin/main)) == before
    refute_received {:t3_vcs, ^path, %{"_tag" => "remoteUpdated"}}
    context
  end

  # Time moves on by shifting the lease's clock back; the policy reads the wall clock.
  step "a client reported activity with the default lease 46 seconds ago and did not renew it",
       context do
    context = report(context, %{})
    assert BackgroundPolicy.run_scope_work?(scope("/repo"))

    :sys.replace_state(BackgroundPolicy, fn state ->
      leases =
        Map.new(state.leases, fn {key, lease} ->
          {key,
           %{lease | expires_ms: lease.expires_ms - 46_000, updated_ms: lease.updated_ms - 46_000}}
        end)

      %{state | leases: leases}
    end)

    context
  end

  step "the node treats that client as gone for background work", context do
    refute BackgroundPolicy.run_scope_work?(scope("/repo"))
    snapshot = BackgroundPolicy.snapshot()
    assert snapshot["leases"] == []
    assert snapshot["activeForegroundLeaseCount"] == 0
    context
  end

  step "a client reports activity with a ten-minute lease", context do
    report(context, %{"ttlMs" => 600_000})
  end

  step "the node holds the lease for two minutes at most", context do
    [lease] = BackgroundPolicy.snapshot()["leases"]
    {:ok, updated, _} = DateTime.from_iso8601(lease["updatedAt"])
    {:ok, expires, _} = DateTime.from_iso8601(lease["expiresAt"])
    assert DateTime.diff(expires, updated, :millisecond) == 120_000
    context
  end

  step "one connection reports activity for twenty different client views", context do
    Enum.reduce(1..20, context, &report(&2, %{"clientId" => "view-#{&1}"}))
  end

  step "the node holds at most sixteen leases for it", context do
    leases = BackgroundPolicy.snapshot()["leases"]
    assert length(leases) == 16
    assert leases |> Enum.map(& &1["rpcClientId"]) |> Enum.uniq() |> length() == 1
    # The newest views stay.
    assert Enum.any?(leases, &(&1["clientId"] == "view-20"))
    context
  end

  step "a client holds activity leases", context do
    context
    |> report(%{"clientId" => "tab-1"})
    |> report(%{"clientId" => "tab-2", "scopes" => [scope("/other")]})
  end

  step "its socket closes", context do
    client = World.client(context)
    :ok = Mint.HTTP.close(client.conn) |> then(fn {:ok, _} -> :ok end)
    Map.update!(context, :clients, &Map.delete(&1, "default"))
  end

  step "its leases end at once", context do
    await_policy(&(&1["leases"] == []), 1_000)
    refute BackgroundPolicy.run_scope_work?(scope("/repo"))
    context
  end

  step "a client in the background shows a checkout", context do
    report(context, %{
      "visible" => false,
      "focused" => false,
      "appState" => "background"
    })
  end

  step "the node still refreshes that checkout", context do
    assert BackgroundPolicy.snapshot()["activeForegroundLeaseCount"] == 0
    assert BackgroundPolicy.run_scope_work?(scope("/repo"))
    context
  end

  step "the host reports it is locked", context do
    context =
      report(context, %{"scopes" => [scope("/repo"), %{"type" => "provider-status"}]})

    assert BackgroundPolicy.run_scope_work?(scope("/repo"))
    assert T3.ProviderUsageLimits.wanted?()
    host_power(context, %{"locked" => "true"})
  end

  step "the node pauses periodic git and provider refreshes", context do
    refute BackgroundPolicy.run_scope_work?(scope("/repo"))
    refute T3.ProviderUsageLimits.wanted?()
    refute BackgroundPolicy.snapshot()["shouldRunOpportunisticWork"]
    context
  end

  # --- reading and following the policy ------------------------------------------------

  step "a client asks for the background policy", context do
    context = report(context, %{})
    {policy, context} = World.call!(context, "server.getBackgroundPolicy")
    Map.put(context, :policy, policy)
  end

  step "it receives the host's power state, the active client leases and whether background work may run",
       context do
    assert %{
             "hostPower" => %{"source" => "unknown", "onBattery" => "unknown"},
             "leases" => [%{"clientId" => "tab-1", "expiresAt" => _}],
             "activeForegroundLeaseCount" => 1,
             "activeScopeKeys" => ["vcs-status:/repo"],
             "shouldRunOpportunisticWork" => true
           } = context.policy

    context
  end

  step "a client follows the background policy", context do
    context = policy(context)
    shape = %{"type" => "backgroundPolicy", "node" => Atom.to_string(node())}
    client = Node.sub(World.client(context), 31, shape)
    {frame, client} = Node.await(client, &(&1["t"] == "backgroundPolicy" and &1["id"] == 31))
    assert frame["policy"]["hostPower"]["onBattery"] == "unknown"
    World.put_client(context, client)
  end

  step "the host goes onto battery", context do
    host_power(context, %{"onBattery" => "true"})
  end

  step "the client receives the new policy", context do
    {frame, client} =
      Node.await(
        World.client(context),
        &(&1["t"] == "backgroundPolicy" and &1["policy"]["hostPower"]["onBattery"] == "true")
      )

    assert frame["id"] == 31
    assert frame["policy"]["hostPower"]["source"] == "electron-main"
    World.put_client(context, client)
  end

  # A Linux host whose power supplies are fake: mains "AC" (online) and battery "BAT0".
  step "a node started without the desktop app", context do
    dir = Node.tmp_dir(context.node, "power_supply")

    for {name, type, online} <- [{"AC", "Mains", "1"}, {"BAT0", "Battery", nil}] do
      File.mkdir_p!(Path.join(dir, name))
      File.write!(Path.join([dir, name, "type"]), type <> "\n")
      if online, do: File.write!(Path.join([dir, name, "online"]), online <> "\n")
    end

    World.put_app_env(:power_supply_dir, dir)
    World.put_app_env(:os_type, {:unix, :linux})
    context = policy(context)

    await_policy(&match?(%{"source" => "node-linux", "onBattery" => "false"}, &1["hostPower"]))
    Map.put(context, :power_supply_dir, dir)
  end

  # The node reads its power supplies every 30 seconds; the read is fired now.
  step "the laptop it runs on switches to battery", context do
    File.write!(Path.join([context.power_supply_dir, "AC", "online"]), "0\n")
    send(BackgroundPolicy, :probe_power)
    context
  end

  step "the node's background policy sees the host on battery", context do
    await_policy(&match?(%{"source" => "node-linux", "onBattery" => "true"}, &1["hostPower"]))
    # Under battery-saver that pauses background work.
    profile("battery-saver")
    context = report(context, %{})
    refute BackgroundPolicy.run_scope_work?(scope("/repo"))
    context
  end

  # --- sweeps --------------------------------------------------------------------------

  step "it sweeps storage after about a minute", context do
    World.provider_services()
    World.merge_settings(%{"storageCleanup" => %{"browserArtifactsAfterDays" => 3}})
    old = artifact(context, "old.png", 4)
    Node.ensure(T3.StorageCleanup)

    left = cleanup_timer_ms()
    assert left > 55_000 and left <= 60_000
    assert File.exists?(old)

    fire_sweep()
    refute File.exists?(old)
    context
  end

  step "again every hour", context do
    left = cleanup_timer_ms()
    assert left > 3_595_000 and left <= 3_600_000
    old = artifact(context, "older.png", 5)
    fire_sweep()
    refute File.exists?(old)
    assert cleanup_timer_ms() > 3_595_000
    context
  end

  step "the user changes the storage cleanup settings", context do
    World.storage_cleanup()
    old = artifact(context, "old.png", 4)
    fresh = artifact(context, "fresh.png", 1)
    World.merge_settings(%{"storageCleanup" => %{"browserArtifactsAfterDays" => 3}})
    # The settings change reached the cleaner before this call did.
    _ = :sys.get_state(T3.StorageCleanup)
    Map.put(context, :artifacts, %{old: old, fresh: fresh})
  end

  step "the node sweeps with the new settings", context do
    refute File.exists?(context.artifacts.old)
    assert File.exists?(context.artifacts.fresh)
    context
  end

  step ~r/^worktree cleanup removes worktrees (?<rule>after 7 idle days|once merged|once their thread is deleted|when unchanged from default)$/,
       %{args: [rule]} = context do
    Node.ensure(T3.Settings)

    rules =
      case rule do
        "after 7 idle days" -> %{"worktreeAfterDays" => 7}
        "once merged" -> %{"worktreeOnMerge" => true}
        "once their thread is deleted" -> %{"worktreeOnDelete" => true}
        "when unchanged from default" -> %{"worktreeUnchanged" => true}
      end

    World.merge_settings(%{"storageCleanup" => rules})
    context
  end

  step "the thread keeps its branch and path", context do
    %{thread: title, branch: branch, path: path, repo: repo} = context.worktree
    thread = World.thread(context, title)
    assert thread["branch"] == branch
    assert thread["worktreePath"] == path
    assert World.git!(repo, ["rev-parse", "--verify", "--quiet", branch]) != ""
    context
  end

  # With a control worktree, idle as long and nothing else, that the same sweep removes.
  step ~r/^a thread's worktree idle for 8 days (?<reason>.+)$/, %{args: [reason]} = context do
    context = World.worktree_thread(context, "main")
    main = context.worktree
    context = World.worktree_thread(context, "control")
    context = Map.merge(context, %{worktree: main, control: context.worktree.path})

    context =
      case reason do
        "is used by two threads" ->
          fields = %{"branch" => main.branch, "worktreePath" => main.path}

          context
          |> World.create_thread("second", nil, fields)
          |> World.backdate_thread("second", World.days(8))

        "has uncommitted changes" ->
          File.write!(Path.join(main.path, "README.md"), "changed\n")
          context

        "has ignored files other than node_modules" ->
          File.write!(Path.join([main.repo, ".git", "info", "exclude"]), ".env\nnode_modules/\n")
          File.write!(Path.join(main.path, ".env"), "SECRET=1\n")
          context

        "has a terminal open in it" ->
          World.provider_services()

          {_, context} =
            World.call!(context, "terminal.open", %{
              "threadId" => World.thread_id(context, "main"),
              "terminalId" => "default",
              "cwd" => main.path
            })

          context

        "has a running provider session" ->
          context = context |> World.fake_codex() |> World.send_message("main", "hello")
          World.await_run(context, "main", &(&1["status"] == "completed"))
          assert [_] = Registry.lookup(T3.Codex.Registry, World.thread_id(context, "main"))
          context

        "belongs to a thread that is running" ->
          World.add_run(context, "main", "running")

        "is another project's root" ->
          World.create_project(context, "nested", %{"workspaceRoot" => main.path})
      end

    context
    |> World.backdate_thread("main", World.days(8))
    |> World.backdate_thread("control", World.days(8))
  end

  step "worktree cleanup is on for the environment", context do
    Node.ensure(T3.Settings)
    World.merge_settings(%{"storageCleanup" => %{"worktreeAfterDays" => 7}})
    context
  end

  step "one project overrides it to off", context do
    context = World.worktree_thread(context, "kept", "api")
    kept = context.worktree
    context = World.worktree_thread(context, "control", "web")
    control = context.worktree.path

    World.merge_settings(%{
      "projectSettingsOverrides" => %{
        World.project(context, "api").id => %{"worktreeCleanup" => %{"mode" => "off"}}
      }
    })

    context
    |> Map.merge(%{worktree: kept, control: control})
    |> World.backdate_thread("kept", World.days(8))
    |> World.backdate_thread("control", World.days(8))
  end

  step "that project's worktrees are kept", context do
    assert File.dir?(context.worktree.path)
    refute File.exists?(context.control), "the other project's idle worktree should go"
    context
  end

  # A `git` first on PATH pauses the sweep at its first look at the worktree's
  # ignored files until the test lets it go (over a local TCP port).
  step "a worktree qualified for removal when the sweep began", context do
    Node.ensure(T3.Settings)
    World.merge_settings(%{"storageCleanup" => %{"worktreeAfterDays" => 7}})
    context = World.worktree_thread(context, "main")
    main = context.worktree
    context = World.worktree_thread(context, "control")

    context =
      context
      |> Map.merge(%{worktree: main, control: context.worktree.path})
      |> World.backdate_thread("main", World.days(8))
      |> World.backdate_thread("control", World.days(8))

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    bin = Node.tmp_dir(context.node, "git-bin")
    git = System.find_executable("git")
    {real_path, 0} = System.cmd("realpath", [main.path])

    File.write!(Path.join(bin, "git"), """
    #!/bin/bash
    if [ "$1" = ls-files ] && [[ " $* " == *" --ignored "* ]] && [ "$(pwd -P)" = "#{String.trim(real_path)}" ] && mkdir "#{bin}/paused" 2>/dev/null; then
      exec 3<>/dev/tcp/127.0.0.1/#{port}
      echo paused >&3
      read -r _ <&3
      exec 3>&-
    fi
    exec #{git} "$@"
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    World.put_os_env("PATH", bin <> ":" <> System.get_env("PATH", ""))
    World.storage_cleanup()
    Map.put(context, :pause, listen)
  end

  step "a terminal opened in it during the sweep", context do
    sweep = Task.async(fn -> T3.StorageCleanup.sweep() end)
    {:ok, git} = :gen_tcp.accept(context.pause, 10_000)
    assert {:ok, "paused\n"} = :gen_tcp.recv(git, 0, 10_000)

    {_, context} =
      World.call!(context, "terminal.open", %{
        "threadId" => World.thread_id(context, "main"),
        "terminalId" => "default",
        "cwd" => context.worktree.path
      })

    :ok = :gen_tcp.send(git, "go\n")
    assert :ok = Task.await(sweep, 30_000)
    context
  end

  step "the sweep removed a thread's worktree", context do
    context = World.fake_codex(context)
    World.merge_settings(%{"storageCleanup" => %{"worktreeUnchanged" => true}})
    context = World.worktree_thread(context, "main")
    World.storage_cleanup()
    :ok = T3.StorageCleanup.sweep()
    refute File.exists?(context.worktree.path)
    context
  end

  step "the user continues the thread", context do
    context = World.send_message(context, "main", "carry on")
    World.await_run(context, "main", &(&1["status"] == "completed"))
    context
  end

  step "the worktree can be recreated from the thread's branch", context do
    %{path: path, branch: branch} = context.worktree
    assert File.dir?(path)
    assert World.git!(path, ~w(rev-parse --abbrev-ref HEAD)) == branch
    assert World.thread(context, "main")["worktreePath"] == path
    context
  end

  step "browser artifacts are kept for 3 days", context do
    World.storage_cleanup()
    World.merge_settings(%{"storageCleanup" => %{"browserArtifactsAfterDays" => 3}})

    Map.put(context, :artifacts, %{
      old: artifact(context, "old.png", 4),
      fresh: artifact(context, "fresh.png", 2)
    })
  end

  step "artifacts older than 3 days are removed", context do
    refute File.exists?(context.artifacts.old)
    context
  end

  step "newer ones stay", context do
    assert File.exists?(context.artifacts.fresh)
    context
  end
end
