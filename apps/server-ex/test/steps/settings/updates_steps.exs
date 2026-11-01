defmodule HalC2.Steps.Settings.Updates do
  @moduledoc """
  Steps for features/settings/updates.feature: server updates with progress (the
  release from `HalC2.Steps.Settings.HotCodeUpgrade`), desktop app updates
  (`HalC2.DesktopUpdate`) and provider updates (`HalC2.ProviderUpdates`).

  For a desktop app update the MC is one the desktop app started
  (`HAL_C2_DESKTOP_HOST=1`), and the app is a socket on its bootstrap session that
  listens for update control messages and answers with the reports a scenario lays
  out. A client asks with a `serverUpdate` subscription, as the clients do.

  Providers are fake CLIs under the MC's home, laid out the way each installer
  lays them out, as `HalC2.ProviderUpdatesTest` does. `--version` prints the version
  in the file beside the script; an update writes 9.9.9 there. The latest release
  is 9.9.9, as if already read from the registry.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Settings.HotCodeUpgrade
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @latest "9.9.9"
  @drivers %{"Codex" => "codex", "Claude" => "claudeAgent"}

  # A provider CLI: `--version` and Claude's own `update`.
  @cli """
  #!/bin/sh
  dir=$(dirname "$(readlink -f "$0")")
  case "$1" in
    --version) printf "$(cat "$dir/format")\\n" "$(cat "$dir/version")" ;;
    update) echo 9.9.9 > "$dir/version" ;;
  esac
  """

  # npm at a global prefix: logs its arguments and installs 9.9.9 of Codex.
  @npm """
  #!/bin/sh
  prefix=$(dirname "$(dirname "$0")")
  echo "$@" >> "$prefix/npm.log"
  echo 9.9.9 > "$prefix/lib/node_modules/@openai/codex/bin/version"
  """

  # --- server updates ----------------------------------------------------------------------

  step "the user updates the server to {string} with progress", %{args: [version]} = context do
    context = HotCodeUpgrade.cached_bundle(context, version, :hot)
    {client, id} = start_update(World.client(context), version)
    {frames, client} = collect(client, id, [])
    context |> World.put_client(client) |> Map.put(:update_frames, frames)
  end

  step "the user sees it downloading, then installing", context do
    stages =
      for %{"t" => "serverUpdate", "event" => %{"type" => "progress", "stage" => stage}} <-
            context.update_frames,
          do: stage

    assert stages == ["downloading", "installing"]
    context
  end

  step "the update ends as complete", context do
    assert [
             %{"t" => "serverUpdate", "event" => %{"type" => "complete", "result" => result}},
             %{"t" => "end"}
           ] = Enum.take(context.update_frames, -2)

    assert %{"targetVersion" => "1.4.0", "method" => "hot-upgrade"} = result
    assert HalC2.Upgrade.version() == "1.4.0"
    context
  end

  # The first update waits on a download that never answers.
  step "a server update is in progress", context do
    context = HotCodeUpgrade.running_release(context)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(listen)
    World.put_env("HAL_C2_UPGRADE_URL", "http://127.0.0.1:#{port}/{version}.tar.gz")

    {client, id} = start_update(Mc.connect(context.mc), "1.4.0")

    {_frame, client} =
      Mc.await(client, &(&1["id"] == id and &1["event"]["stage"] == "downloading"))

    context |> World.put_client("first", client) |> Map.put(:listen, listen)
  end

  step "the user starts another server update", context do
    {reply, context} = World.call(context, "server.updateServer", %{"targetVersion" => "1.4.1"})
    Map.put(context, :reply, reply)
  end

  step "the second update is refused", context do
    assert {:error, "ServerSelfUpdateError", %{"reason" => reason}} = context.reply
    assert reason =~ "already in progress"
    assert HalC2.Upgrade.version() == "1.3.0"
    context
  end

  # --- desktop app updates -------------------------------------------------------------------

  step "this server was not started by the desktop app", context do
    System.delete_env("HAL_C2_DESKTOP_HOST")
    Mc.ensure(HalC2.DesktopUpdate)
    context
  end

  # As the MC's descriptor tells clients there is nothing to drive, the request goes
  # to the service itself.
  step "a client asks for a desktop update", context do
    if context[:desktop],
      do: ask(context),
      else: Map.put(context, :reply, HalC2.DesktopUpdate.update())
  end

  # A client asks with a `serverUpdate` subscription; the desktop app answers the
  # request with its plays.
  defp ask(context) do
    {client, id} = start_update(World.client(context), "latest")
    context = World.put_client(context, client) |> Map.put(:update_id, id)
    {request, context} = control(context, "requestDesktopUpdate")
    context = Enum.reduce(context.plays, context, &play(&2, &1, request))
    {frames, client} = collect(World.client(context), id, [])
    context |> World.put_client(client) |> Map.put(:update_frames, frames)
  end

  step "the request fails saying the server cannot drive a desktop update", context do
    assert {:error, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} = context.reply
    assert reason =~ "was not started by the HAL-C2 desktop app"
    assert HalC2.Upgrade.capability() != "desktop-managed"
    context
  end

  step "the desktop app is already on the latest version", context do
    desktop_plays(context, [{:run, report("idle", %{}, %{"outcome" => "up-to-date"})}])
  end

  step "the request says the desktop app is already up to date on its version", context do
    assert failure(context) ==
             "The HAL-C2 desktop app on this machine is already up to date on 1.2.3."

    context
  end

  step ~r/^the desktop app checks, finds "(?<version>[^"]+)", downloads it and has it ready to install$/,
       %{args: [version]} = context do
    found = %{"availableVersion" => version}
    downloaded = Map.put(found, "downloadedVersion", version)

    desktop_plays(context, [
      {:run, report("checking")},
      {:run, report("available", found)},
      {:run, report("downloading", Map.put(found, "downloadPercent", 10))},
      {:run, report("downloading", Map.put(found, "downloadPercent", 60))},
      {:run, report("downloaded", downloaded)},
      {:run, report("downloaded", downloaded, %{"outcome" => "ready-to-install"})}
    ])
  end

  step "it also sends a failure that belongs to an earlier request", context do
    earlier =
      report("error", %{"message" => "an earlier failure"}, %{
        "requestId" => "desktop-update-earlier",
        "outcome" => "failed",
        "reason" => "an earlier failure"
      })

    %{context | plays: [{:as_is, earlier} | context.plays]}
  end

  step ~r/^the client is told "(?<first>\w+)" once, then "(?<second>\w+)"$/,
       %{args: [first, second]} = context do
    assert stages(context) == [first, second]
    context
  end

  step "the update's target version is {string}", %{args: [version]} = context do
    assert %{"t" => "serverUpdate", "event" => %{"type" => "complete", "result" => result}} =
             Enum.at(context.update_frames, -2)

    assert %{"targetVersion" => ^version, "method" => "desktop-app"} = result
    # A ready update is installed from the MC, for the run that prepared it.
    {commit, context} = control(context, "commitDesktopUpdate")
    assert commit == result["desktopUpdateToken"]
    context
  end

  step "the earlier request's failure is not shown", context do
    assert List.last(context.update_frames)["t"] == "end"
    refute Enum.any?(context.update_frames, &(&1["t"] == "error"))
    context
  end

  step ~r/^the desktop app reports that the update failed because "(?<reason>[^"]+)"$/,
       %{args: [reason]} = context do
    failed = report("error", %{}, %{"outcome" => "failed", "reason" => reason})
    desktop_plays(context, [{:run, report("checking")}, {:run, failed}])
  end

  step "the desktop app stops reporting before it has an outcome", context do
    desktop_plays(context, [{:run, report("checking")}, :hang_up])
  end

  step "the request fails saying {string}", %{args: [reason]} = context do
    assert failure(context) == reason
    context
  end

  step "a desktop update is in progress", context do
    context = desktop_plays(context, [{:run, report("checking")}])
    {client, id} = start_update(Mc.connect(context.mc), "latest")
    context = World.put_client(context, "first", client)
    {request, context} = control(context, "requestDesktopUpdate")
    context = play(context, {:run, report("checking")}, request)
    first = World.client(context, "first")

    {_, first} =
      Mc.await(first, &(&1["id"] == id and &1["event"]["stage"] == "downloading"), 10_000)

    context |> World.put_client("first", first) |> Map.put(:request, request)
  end

  step "a client asks for another desktop update", context do
    {reply, context} = World.call(context, "server.updateServer", %{"targetVersion" => "latest"})
    Map.put(context, :reply, reply)
  end

  step "the request fails saying a desktop app update is already in progress", context do
    assert {:error, "ServerSelfUpdateError", %{"reason" => reason}} = context.reply
    assert reason == "A desktop app update is already in progress."
    context
  end

  step "the client that asked for it goes away", context do
    Mint.HTTP.close(World.client(context, "first").conn)
    context
  end

  step "the MC tells the desktop app to cancel that update", context do
    {cancelled, context} = control(context, "cancelDesktopUpdate")
    assert cancelled == context.request
    context
  end

  step "a new desktop update can be asked for", context do
    {_client, _id} = start_update(World.client(context), "latest")
    {request, context} = control(context, "requestDesktopUpdate")
    assert request != context.request
    context
  end

  step "a desktop update was prepared and is ready to install", context do
    ready =
      report("downloaded", %{"downloadedVersion" => "1.2.4"}, %{"outcome" => "ready-to-install"})

    context = desktop_plays(context, [{:run, ready}])
    context = ask(context)
    assert List.last(context.update_frames)["t"] == "end"
    {request, context} = control(context, "commitDesktopUpdate")
    Map.put(context, :request, request)
  end

  step "a client asks for a desktop update again", context do
    {client, id} = start_update(World.client(context), "latest")
    context |> World.put_client(client) |> Map.put(:update_id, id)
  end

  step "the MC does not refuse it as already in progress", context do
    {request, context} = control(context, "requestDesktopUpdate")
    assert request != context.request
    Mc.refute_frame(World.client(context), &(&1["t"] == "error"))
    context
  end

  # Nothing is allowed any time: the deadline passes as soon as the run, or the
  # install, starts.
  step "the desktop app does not finish the update for longer than allowed", context do
    World.put_app_env(:desktop_update_timeout, 0)
    context = desktop_plays(context, [])
    ask(context)
  end

  step "a client's desktop update is committed and the app stopped its MC to install", context do
    Mc.ensure(HalC2.Settings)

    ready =
      report("downloaded", %{"downloadedVersion" => "1.2.4"}, %{"outcome" => "ready-to-install"})

    context = desktop_plays(context, [{:run, ready}])
    context = ask(context)
    {request, context} = control(context, "commitDesktopUpdate")
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    Mc.ensure(HalC2.DesktopUpdate)
    Mc.ensure(HalC2.Settings)

    assert {200, %{"access_token" => access}} =
             Mc.exchange(context.mc, "desktop-update-token", %{"client_label" => "HAL-C2 desktop"})

    desktop = Mc.sub(Mc.connect_as(context.mc, access), 1, %{"type" => "desktopUpdateControl"})
    context |> Map.put(:desktop, desktop) |> Map.put(:request, request)
  end

  step "the app reconnects and reports that the install failed because {string}",
       %{args: [reason]} = context do
    send_report(
      context,
      report("downloaded", %{}, %{
        "requestId" => context.request,
        "outcome" => "failed",
        "reason" => reason
      })
    )
  end

  step "the app relaunched and reconnects", context do
    send_report(context, report("idle"))
  end

  step "the MC's last update outcome is failed saying {string}", %{args: [reason]} = context do
    _ = HalC2.DesktopUpdate.latest()
    assert %{"status" => "failed", "reason" => ^reason} = HalC2.Upgrade.outcome()
    context
  end

  step "no install is left waiting and no failure is recorded", context do
    _ = HalC2.DesktopUpdate.latest()
    assert :sys.get_state(HalC2.DesktopUpdate).install == nil
    # An outcome is global to the VM: an earlier scenario's may still be there.
    refute match?(%{"id" => id} when id == context.request, HalC2.Upgrade.outcome())
    context
  end

  step "the MC cannot write its update state", context do
    block_upgrades_dir()
    context
  end

  step "a client's desktop update is ready to install", context do
    Mc.ensure(HalC2.Settings)

    ready =
      report("downloaded", %{"downloadedVersion" => "1.2.4"}, %{"outcome" => "ready-to-install"})

    context |> desktop_plays([{:run, ready}]) |> ask()
  end

  step "the desktop app is told to cancel and not to install", context do
    {_request, context} = control(context, "cancelDesktopUpdate")
    context
  end

  step "the MC stops being able to write its update state", context do
    block_upgrades_dir()
    config = Mc.sub(Mc.connect(context.mc), 2, %{"type" => "config", "mc" => mc()})
    {_, config} = Mc.await(config, &(&1["t"] == "config"))
    World.put_client(context, "config", config)
  end

  step "clients watching the MC's config are told it failed saying {string}",
       %{args: [reason]} = context do
    {frame, _config} =
      Mc.await(
        context.clients["config"],
        &(&1["updateOutcome"]["id"] == context.request)
      )

    assert frame["updateOutcome"]["reason"] == reason
    context
  end

  step "the MC keeps running with no install left waiting", context do
    _ = HalC2.DesktopUpdate.latest()
    assert :sys.get_state(HalC2.DesktopUpdate).install == nil
    context
  end

  step "the MC's descriptor says the desktop app updates it", context do
    context = desktop_plays(context, [])
    capabilities = HalC2.Environment.descriptor()["capabilities"]
    assert capabilities["serverSelfUpdate"] == "desktop-managed"
    assert capabilities["desktopAppUpdate"] == true
    context
  end

  step "the desktop app does not report an install for longer than allowed", context do
    World.put_app_env(:desktop_install_timeout, 0)
    Mc.ensure(HalC2.Settings)

    ready =
      report("downloaded", %{"downloadedVersion" => "1.2.4"}, %{"outcome" => "ready-to-install"})

    context = desktop_plays(context, [{:run, ready}])
    config = Mc.sub(Mc.connect(context.mc), 2, %{"type" => "config", "mc" => mc()})
    {_, config} = Mc.await(config, &(&1["t"] == "config"))
    context = World.put_client(context, "config", config)
    ask(context)
  end

  step ~r/^the update fails saying the desktop app (?<message>.+)$/,
       %{args: [message]} = context do
    reason = "The desktop app #{message}."

    case message do
      "did not finish the update in time" ->
        assert failure(context) == reason
        {cancelled, context} = control(context, "cancelDesktopUpdate")
        assert is_binary(cancelled)
        context

      "did not report an install result in time" ->
        {frame, config} = Mc.await(World.client(context, "config"), &(&1["t"] == "config.ready"))

        assert %{"status" => "failed", "reason" => ^reason, "targetVersion" => "1.2.4"} =
                 frame["updateOutcome"]

        World.put_client(context, "config", config)
    end
  end

  # --- provider updates ----------------------------------------------------------------------

  step ~r/^(?<provider>Codex|Claude) is installed with (?<installer>Homebrew|a global npm install|its own updater) and a newer version is released$/,
       %{args: [provider, installer]} = context do
    install(context, provider, installer)
  end

  step "the MC checks provider versions", context do
    check(context)
  end

  step ~r/^(?<provider>Codex|Claude) is reported behind the latest version with an update command$/,
       %{args: [provider]} = context do
    advisory = advisory(context, provider)
    assert advisory["status"] == "behind_latest"
    assert advisory["currentVersion"] == "0.1.0"
    assert advisory["latestVersion"] == @latest
    assert advisory["canUpdate"]
    assert advisory["updateCommand"] == update_command(context, provider)
    context
  end

  step "Codex is behind the latest version", context do
    context = context |> install("Codex", "a global npm install") |> check()
    assert advisory(context, "Codex")["status"] == "behind_latest"
    context
  end

  step "the MC runs Codex's update command", context do
    prefix = Path.join(context.mc.home, "npm")
    assert {:ok, %{"providers" => providers}} = context.reply

    assert File.read!(Path.join(prefix, "npm.log")) ==
             "install -g --prefix #{prefix} @openai/codex@latest\n"

    Map.put(context, :providers, providers)
  end

  step "Codex is reported current", context do
    advisory = advisory(context, "Codex")
    assert advisory["status"] == "current"
    assert advisory["currentVersion"] == @latest
    context
  end

  step "Codex is not installed", context do
    context = setup_providers(context)
    World.put_app_env(:codex_command, ["hal-c2-test-no-codex"])
    context
  end

  step "Codex was installed in a way the MC cannot update", context do
    context = setup_providers(context)
    World.put_app_env(:codex_command, [cli(context, "opt/codex", "bin/codex", "codex-cli %s")])
    context
  end

  step "the user turned off provider update checks", context do
    context =
      context
      |> install("Codex", "a global npm install")
      |> World.update_settings(%{"enableProviderUpdateChecks" => false})

    assert HalC2.Settings.settings()["enableProviderUpdateChecks"] == false
    context
  end

  step "the MC would check provider versions", context do
    check(context)
  end

  # The latest release is known here, yet not reported, nor read again.
  step "no version check is made", context do
    advisory = advisory(context, "Codex")
    assert advisory["status"] == "unknown"
    assert advisory["latestVersion"] == nil
    assert advisory["currentVersion"] == "0.1.0"
    refute :persistent_term.get({HalC2.ProviderUpdates, "codex", :reading}, false)
    context
  end

  # --- desktop app helpers -------------------------------------------------------------------

  defp mc, do: Atom.to_string(node())

  # Starts the MC as the desktop app does, and the app's socket listening for control
  # messages; `plays` is what it answers a request with.
  defp desktop_plays(%{desktop: %{}} = context, plays), do: %{context | plays: plays}

  defp desktop_plays(context, plays) do
    World.put_env("HAL_C2_DESKTOP_HOST", "1")
    Application.put_env(:hal_c2, :desktop_token, "desktop-update-token")
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :desktop_token) end)
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    Mc.ensure(HalC2.DesktopUpdate)

    assert {200, %{"access_token" => access}} =
             Mc.exchange(context.mc, "desktop-update-token", %{"client_label" => "HAL-C2 desktop"})

    desktop =
      Mc.sub(Mc.connect_as(context.mc, access), 1, %{"type" => "desktopUpdateControl"})

    context = Map.merge(context, %{desktop: desktop, plays: plays})
    # Its connect report: once answered, its subscription before it is in place.
    send_report(context, report("idle"))
  end

  defp play(context, :hang_up, _request) do
    Mint.HTTP.close(context.desktop.conn)
    context
  end

  defp play(context, {:as_is, report}, _request), do: send_report(context, report)

  defp play(context, {:run, report}, request),
    do: send_report(context, Map.put(report, "requestId", request))

  # A file where the directory goes: nothing can be written below it.
  defp block_upgrades_dir do
    dir = Path.join(HalC2.Paths.data_dir(), "upgrades")
    File.rm_rf!(dir)
    File.write!(dir, "")
  end

  defp send_report(context, report) do
    {reply, desktop} =
      Mc.call(context.desktop, context.mc.environment, "server.reportDesktopUpdateStatus", report)

    assert reply == {:ok, %{}}
    %{context | desktop: desktop}
  end

  # The next control message of `type` the desktop app is sent: its requestId.
  defp control(context, type) do
    {frame, desktop} =
      Mc.await(
        context.desktop,
        &(&1["t"] == "desktopUpdateControl" and &1["event"]["type"] == type),
        10_000
      )

    assert %{"version" => 1, "requestId" => request} = frame["event"]
    {request, %{context | desktop: desktop}}
  end

  defp report(status, fields \\ %{}, extra \\ %{}) do
    state =
      Map.merge(%{"enabled" => true, "status" => status, "currentVersion" => "1.2.3"}, fields)

    Map.merge(%{"version" => 1, "type" => "desktopUpdateStatus", "state" => state}, extra)
  end

  defp stages(context),
    do:
      for(
        %{"t" => "serverUpdate", "event" => %{"type" => "progress", "stage" => stage}} <-
          context.update_frames,
        do: stage
      )

  # Why the update the client asked for failed.
  defp failure(%{reply: reply}) do
    assert {:error, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} = reply
    reason
  end

  defp failure(context) do
    assert %{"t" => "error", "detail" => %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} =
             List.last(context.update_frames)

    reason
  end

  # --- helpers -------------------------------------------------------------------------------

  defp start_update(client, version) do
    id = System.unique_integer([:positive])

    client =
      Mc.sub(client, id, %{
        "type" => "serverUpdate",
        "mc" => Atom.to_string(node()),
        "input" => %{"targetVersion" => version}
      })

    {client, id}
  end

  # The update's frames, through its `end` or error.
  defp collect(client, id, frames) do
    {frame, client} = Mc.await(client, &(&1["id"] == id), 10_000)
    frames = frames ++ [frame]
    if frame["t"] in ["end", "error"], do: {frames, client}, else: collect(client, id, frames)
  end

  # A fresh provider state: no cached versions, the latest release already read.
  defp setup_providers(context) do
    Mc.ensure(HalC2.Settings)

    keys =
      [{HalC2.Codex.Provider, :version}, {HalC2.Claude.Provider, :version}] ++
        for driver <- Map.values(@drivers), do: {HalC2.ProviderUpdates, driver}

    Enum.each(keys, &:persistent_term.erase/1)
    ExUnit.Callbacks.on_exit(fn -> Enum.each(keys, &:persistent_term.erase/1) end)

    for driver <- Map.values(@drivers),
        do:
          :persistent_term.put(
            {HalC2.ProviderUpdates, driver},
            {@latest, System.monotonic_time(:millisecond)}
          )

    context
  end

  @doc "Installs a fake Codex or Claude CLI at 0.1.0 the way `installer` would; 9.9.9 is released."
  def install(context, provider, installer) do
    context = setup_providers(context)

    {key, path} =
      case {provider, installer} do
        {"Codex", "Homebrew"} ->
          {:codex_command,
           cli(context, "Cellar/codex/0.1.0/bin/codex", "bin/codex", "codex-cli %s")}

        {"Codex", "a global npm install"} ->
          npm = Path.join([context.mc.home, "npm", "bin", "npm"])
          File.mkdir_p!(Path.dirname(npm))
          File.write!(npm, @npm)
          File.chmod!(npm, 0o755)

          link =
            cli(
              context,
              "npm/lib/node_modules/@openai/codex/bin/codex.js",
              "npm/bin/codex",
              "codex-cli %s"
            )

          {:codex_command, link}

        {"Claude", "its own updater"} ->
          {:claude_command,
           cli(context, "claude/bin/claude", "local/bin/claude", "%s (Claude Code)")}
      end

    World.put_app_env(key, [path])
    context
  end

  # A CLI at `real` under the MC's home, found through a link at `link`.
  defp cli(context, real, link, format) do
    real = Path.join(context.mc.home, real)
    link = Path.join(context.mc.home, link)
    File.mkdir_p!(Path.dirname(real))
    File.mkdir_p!(Path.dirname(link))
    File.write!(real, @cli)
    File.chmod!(real, 0o755)
    File.write!(Path.join(Path.dirname(real), "version"), "0.1.0\n")
    File.write!(Path.join(Path.dirname(real), "format"), format)
    File.ln_s!(real, link)
    link
  end

  defp update_command(context, "Codex") do
    prefix = Path.join(context.mc.home, "npm")

    if File.dir?(prefix),
      do: "#{prefix}/bin/npm install -g --prefix #{prefix} @openai/codex@latest",
      else: "brew upgrade codex"
  end

  defp update_command(context, "Claude"),
    do: "#{Path.join([context.mc.home, "local", "bin", "claude"])} update"

  @doc "Asks the MC for Codex's status again; the providers land in `context.providers`."
  def check(context) do
    {result, context} =
      World.call!(context, "server.refreshProviders", %{"instanceId" => "codex"})

    Map.put(context, :providers, result["providers"])
  end

  @doc "The `versionAdvisory` of `provider` (\"Codex\" or \"Claude\") in `context.providers`."
  def advisory(context, provider) do
    driver = @drivers[provider]
    entry = Enum.find(context.providers, &(&1["driver"] == driver))
    assert entry, "#{provider} is not among the MC's providers"
    entry["versionAdvisory"]
  end
end
