defmodule HalC2.ProviderUpdates do
  @moduledoc """
  Whether a provider CLI is behind its latest release (`versionAdvisory` on its
  `ServerProvider` entry), and updating it (`server.updateProvider`).

  The latest version is the npm registry's, read in the background at most hourly
  unless the user turned off `enableProviderUpdateChecks`; providers are
  re-announced when it arrives. The update runs whatever installed
  the CLI, told apart by where its executable really lives: Homebrew, a global npm
  prefix, or Claude Code's own `claude update`. Anything else is reported without
  an update command.

  Updates through one installer run one at a time; a provider waiting its turn,
  running or finished shows it in its `updateState`. An update checks that the
  installer is still the one the providers were last reported with, and afterwards
  that the provider is no longer behind.
  """

  @packages %{"codex" => "@openai/codex", "claudeAgent" => "@anthropic-ai/claude-code"}
  @names %{"codex" => "Codex", "claudeAgent" => "Claude"}
  @ttl :timer.hours(1)

  @doc "The `versionAdvisory` for a provider whose executable is at `path`."
  def advisory(driver, path, current) do
    latest =
      if HalC2.Settings.settings()["enableProviderUpdateChecks"] != false, do: latest(driver)

    update = update_command(driver, path)
    # What the user was shown; an update checks the installation still matches it.
    if :persistent_term.get({__MODULE__, driver, :offered}, nil) != update,
      do: :persistent_term.put({__MODULE__, driver, :offered}, update)

    %{
      "status" =>
        cond do
          latest == nil or current in [nil, "unknown"] -> "unknown"
          newer?(latest, current) -> "behind_latest"
          true -> "current"
        end,
      "currentVersion" => if(current in [nil, "unknown"], do: nil, else: current),
      "latestVersion" => latest,
      "updateCommand" => update && Enum.join(update, " "),
      "canUpdate" => update != nil,
      "canInstallVersion" => targeted(update, "0.0.0") != nil,
      "checkedAt" => checked_at(driver),
      "message" => nil
    }
  end

  @doc """
  `server.updateProvider`: runs the provider's updater, then reports providers again.
  A `targetVersion` installs that exact release instead of the latest, which only
  npm installs can do (`canInstallVersion`).
  """
  def update(%{"provider" => driver} = input) do
    target = input["targetVersion"]

    with {:path, path} when is_binary(path) <- {:path, executable(driver)},
         {:command, [_ | _] = command} <- {:command, update_command(driver, path)},
         {:target, true} <- {:target, target == nil or targeted(command, target) != nil} do
      locked(lock_key(command), driver, fn -> run(driver, target) end)
    else
      {:path, _} -> error(driver, "#{@names[driver] || driver} is not installed on this machine.")
      {:command, _} -> error(driver, "This installation cannot be updated from here.")
      {:target, _} -> error(driver, "This installation cannot install v#{target}.")
    end
  rescue
    exception -> failed(driver, nil, Exception.message(exception))
  end

  @doc "Adds the provider's `updateState` to its entry, once it has been updated."
  def put_state(%{"driver" => driver} = entry) do
    case :persistent_term.get({__MODULE__, driver, :state}, nil) do
      nil -> entry
      state -> Map.put(entry, "updateState", state)
    end
  end

  # One installer runs one update at a time; the others wait their turn, queued.
  defp locked(key, driver, fun) do
    lock = {{__MODULE__, key}, self()}

    unless :global.set_lock(lock, [node()], 0) do
      put_state(driver, "queued", nil, "Waiting for another provider update to finish.")
      true = :global.set_lock(lock, [node()])
    end

    try do
      fun.()
    after
      :global.del_lock(lock, [node()])
    end
  end

  defp lock_key(["brew" | _]), do: "homebrew"
  defp lock_key([_npm, "install", "-g", "--prefix", prefix | _]), do: "npm-global:" <> prefix
  defp lock_key([path | _]), do: "self:" <> path

  defp run(driver, target) do
    started = HalC2.Orchestration.Entities.now()
    put_state(driver, "running", started, "Updating provider.")
    offered = :persistent_term.get({__MODULE__, driver, :offered}, nil)
    path = executable(driver)
    command = path && update_command(driver, path)

    cond do
      command == nil or (offered != nil and offered != command) ->
        failed(driver, started, "Provider installation changed. Refresh and try again.")

      true ->
        [program | args] = if target, do: targeted(command, target), else: command

        case System.cmd(program, args, stderr_to_stdout: true) do
          {output, 0} ->
            verify(driver, started, output, target)

          {output, _} ->
            failed(driver, started, output |> String.trim() |> String.slice(-500, 500))
        end
    end
  end

  # "Succeeded" needs the provider to be installed and no longer behind, or at the
  # version that was asked for.
  defp verify(driver, started, output, target) do
    forget_version(driver)
    entry = Enum.find(HalC2.Environment.providers(), &(&1["driver"] == driver))

    {status, message} =
      cond do
        entry == nil or entry["version"] in [nil, "unknown"] ->
          {"unchanged",
           "Update command completed, but HAL-C2 could not verify the provider version."}

        target != nil and entry["version"] != target ->
          {"unchanged", "Install completed, but the provider does not report v#{target}."}

        target == nil and entry["versionAdvisory"]["status"] == "behind_latest" ->
          {"unchanged",
           "Update command completed, but HAL-C2 still detects an outdated provider version."}

        true ->
          {"succeeded", "Provider updated."}
      end

    put_state(driver, status, started, message, output)
    {:ok, %{"providers" => HalC2.Environment.providers()}}
  end

  defp failed(driver, started, reason) do
    put_state(driver, "failed", started, if(reason == "", do: "The update failed.", else: reason))
    error(driver, reason)
  end

  defp put_state(driver, status, started, message, output \\ nil) do
    finished =
      if status in ["succeeded", "failed", "unchanged"], do: HalC2.Orchestration.Entities.now()

    :persistent_term.put({__MODULE__, driver, :state}, %{
      "status" => status,
      "startedAt" => started,
      "finishedAt" => finished,
      "message" => message,
      "output" => output && String.slice(output, -10_000, 10_000)
    })

    HalC2.Settings.notify_providers()
  end

  defp error(driver, reason),
    do:
      {:error,
       %{
         "_tag" => "ServerProviderUpdateError",
         "provider" => driver,
         "reason" => if(reason == "", do: "The update failed.", else: reason),
         "message" => reason
       }}

  # The updater for an executable, as argv, or nil.
  defp update_command(driver, path) do
    real = real_path(path)
    package = @packages[driver]

    cond do
      String.contains?(real, "/Caskroom/") ->
        [
          "brew",
          "upgrade",
          "--cask",
          real |> String.split("/Caskroom/") |> Enum.at(1) |> first_segment()
        ]

      String.contains?(real, "/Cellar/") ->
        ["brew", "upgrade", real |> String.split("/Cellar/") |> Enum.at(1) |> first_segment()]

      String.contains?(real, "/lib/node_modules/") and package != nil ->
        prefix = real |> String.split("/lib/node_modules/") |> hd()
        npm = Path.join([prefix, "bin", "npm"])

        [
          if(File.exists?(npm), do: npm, else: "npm"),
          "install",
          "-g",
          "--prefix",
          prefix,
          package <> "@latest"
        ]

      driver == "claudeAgent" and String.contains?(real, "/claude/") ->
        [path, "update"]

      true ->
        nil
    end
  end

  # The npm install of `command` pinned to `version`, or nil when the installer
  # cannot pin one (Homebrew and self-updaters only reach the latest).
  defp targeted([_npm, "install", "-g", "--prefix", _prefix, package] = command, version) do
    if Regex.match?(~r/^\d+\.\d+\.\d+$/, version),
      do: List.replace_at(command, 5, String.replace_suffix(package, "@latest", "@" <> version))
  end

  defp targeted(_command, _version), do: nil

  defp first_segment(rest), do: rest |> String.split("/") |> hd()

  defp real_path(path) do
    case :file.read_link_all(path) do
      {:ok, target} -> real_path(Path.expand(to_string(target), Path.dirname(path)))
      _ -> path
    end
  end

  defp executable(driver) when driver in ["codex", "claudeAgent"] do
    key = if driver == "codex", do: :codex_command, else: :claude_command
    default = [if(driver == "codex", do: "codex", else: "claude")]

    case HalC2.Settings.instance_command(driver, Application.get_env(:hal_c2, key, default)) do
      [command | _] -> System.find_executable(command)
      _ -> nil
    end
  end

  defp executable(_), do: nil

  # Provider entries cache their version; an update makes it stale.
  defp forget_version("codex"), do: :persistent_term.erase({HalC2.Codex.Provider, :version})

  defp forget_version("claudeAgent"),
    do: :persistent_term.erase({HalC2.Claude.Provider, :version})

  defp forget_version(_), do: :ok

  # The latest release as last read, starting a read when it is missing or stale.
  defp latest(driver) do
    case :persistent_term.get({__MODULE__, driver}, nil) do
      {version, read_at} ->
        if System.monotonic_time(:millisecond) - read_at > @ttl, do: refresh(driver)
        version

      nil ->
        refresh(driver)
        nil
    end
  end

  defp checked_at(driver), do: :persistent_term.get({__MODULE__, driver, :checked_at}, nil)

  defp refresh(driver) do
    package = @packages[driver]
    key = {__MODULE__, driver, :reading}

    if package && Application.get_env(:hal_c2, :provider_update_checks, true) &&
         :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Task.start(fn ->
        try do
          if version = registry_latest(package) do
            :persistent_term.put(
              {__MODULE__, driver},
              {version, System.monotonic_time(:millisecond)}
            )

            :persistent_term.put(
              {__MODULE__, driver, :checked_at},
              HalC2.Orchestration.Entities.now()
            )

            HalC2.Settings.notify_providers()
          end
        after
          :persistent_term.put(key, false)
        end
      end)
    end
  end

  defp registry_latest(package) do
    url = ~c"https://registry.npmjs.org/#{String.replace(package, "/", "%2F")}/latest"

    case :httpc.request(
           :get,
           {url, []},
           [timeout: 4_000, ssl: :httpc.ssl_verify_host_options(true)],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        case JSON.decode(body) do
          {:ok, %{"version" => version}} when is_binary(version) -> version
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp newer?(latest, current) do
    with {:ok, latest} <- Version.parse(latest),
         {:ok, current} <- Version.parse(current) do
      Version.compare(latest, current) == :gt
    else
      _ -> false
    end
  end
end
