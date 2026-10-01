defmodule HalC2.Steps.Settings.Updates do
  @moduledoc """
  Steps for features/settings/updates.feature: server updates with progress (the
  release from `HalC2.Steps.Settings.HotCodeUpgrade`) and provider updates
  (`HalC2.ProviderUpdates`).

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
