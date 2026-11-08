defmodule HalC2.ProviderUpdates do
  @moduledoc """
  Whether a provider CLI is behind its latest release (`versionAdvisory` on its
  `ServerProvider` entry), and updating it (`server.updateProvider`).

  The latest version is what npm on the MC's PATH says, which follows the machine's
  registry setup (the public registry's without npm) — or, for a Claude install from
  Claude's own installer, the newest its release channel offers — read in the
  background at most hourly unless the user turned off
  `enableProviderUpdateChecks`; providers are re-announced when it arrives.
  The update runs whatever installed
  the CLI, told apart by where its executable really lives: Homebrew, a global npm
  prefix, or Claude Code's own `claude update` and OpenCode's own `opencode upgrade`. Anything else is reported without
  an update command.

  Updates through one installer run one at a time; a provider waiting its turn,
  running or finished shows it in its `updateState`. An update checks that the
  installer is still the one the providers were last reported with, and afterwards
  that the provider is no longer behind.
  """

  require Logger

  @packages %{
    "codex" => "@openai/codex",
    "claudeAgent" => "@anthropic-ai/claude-code",
    "opencode" => "opencode-ai",
    "grok" => "@xai-official/grok"
  }
  @names %{
    "codex" => "Codex",
    "claudeAgent" => "Claude",
    "opencode" => "OpenCode",
    "grok" => "Grok"
  }
  @ttl :timer.hours(1)

  @doc """
  The `versionAdvisory` for instance `instance` of `driver`, whose executable is at
  `path`. Each instance has its own executable, so what it was offered and how its
  update went are kept by instance.
  """
  def advisory(driver, path, current, instance \\ nil) do
    instance = instance || driver

    update = update_command(driver, path)

    latest =
      if HalC2.Settings.settings()["enableProviderUpdateChecks"] != false,
        do: latest_for(driver, path, update, instance)

    # A command the user runs by hand (WinGet) is shown, but never run for them.
    shown = update || manual_command(driver, path)
    # What the user was shown; an update checks the installation still matches it.
    if :persistent_term.get({__MODULE__, instance, :offered}, nil) != update,
      do: :persistent_term.put({__MODULE__, instance, :offered}, update)

    %{
      "status" =>
        cond do
          latest == nil or current in [nil, "unknown"] -> "unknown"
          newer?(latest, current) -> "behind_latest"
          true -> "current"
        end,
      "currentVersion" => if(current in [nil, "unknown"], do: nil, else: current),
      "latestVersion" => latest,
      "updateCommand" => shown && Enum.join(shown, " "),
      "canUpdate" => update != nil,
      "canInstallVersion" => targeted(update, "0.0.0") != nil,
      "checkedAt" => checked_at(driver),
      "message" => nil
    }
  end

  # Claude's own installer promotes releases on its own channel (`latest` or
  # `stable`) behind npm's, so a native install is compared with the channel it
  # follows, not with npm. A Homebrew-cask Grok is compared with the version
  # that cask would install, read from its own brew. Everything else follows
  # the npm registry (for Grok, `@xai-official/grok`, what `grok update` installs).
  defp latest_for("claudeAgent", _path, [_executable, "update"], instance),
    do: channel_latest(claude_channel(instance))

  defp latest_for("grok", path, _update, _instance) when is_binary(path), do: grok_latest(path)
  defp latest_for(driver, _path, update, _instance), do: latest(driver, update)

  # The channel a native Claude install follows, from the `autoUpdatesChannel`
  # of the instance's Claude settings; `latest` when it does not say. Only that
  # fixed file under the instance's config directory is read.
  # sobelow_skip ["Traversal.FileModule"]
  defp claude_channel(instance) do
    path =
      Path.join(HalC2.Claude.Provider.config_dir(instance || "claudeAgent"), "settings.json")

    with {:ok, text} <- File.read(path),
         {:ok, %{"autoUpdatesChannel" => channel}} when channel in ["latest", "stable"] <-
           HalC2.Claude.Skills.decode_lenient(text) do
      channel
    else
      _ -> "latest"
    end
  end

  # The newest version the channel offers, as last read; a channel that does not
  # answer (or answers with something unreadable) leaves it unknown rather than
  # falling back to npm's releases.
  defp channel_latest(channel) do
    case :persistent_term.get({__MODULE__, :claude_channel, channel}, nil) do
      {version, read_at} ->
        if System.monotonic_time(:millisecond) - read_at > @ttl, do: refresh_channel(channel)
        version

      nil ->
        refresh_channel(channel)
        nil
    end
  end

  defp refresh_channel(channel) do
    key = {__MODULE__, :claude_channel, channel, :reading}

    if Application.get_env(:hal_c2, :provider_update_checks, true) &&
         :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Task.start(fn ->
        try do
          if version = channel_version(channel) do
            :persistent_term.put(
              {__MODULE__, :claude_channel, channel},
              {version, System.monotonic_time(:millisecond)}
            )

            HalC2.Settings.notify_providers()
          end
        after
          :persistent_term.put(key, false)
        end
      end)
    end
  end

  # The channel file is the version it currently offers, as plain text.
  defp channel_version(channel) do
    url = ~c"https://downloads.claude.ai/claude-code-releases/#{channel}"

    case :httpc.request(
           :get,
           {url, []},
           [timeout: 4_000, ssl: :httpc.ssl_verify_host_options(true)],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} -> parse_channel_version(body)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  def parse_channel_version(body) when is_binary(body) do
    version = body |> String.trim() |> String.trim_leading("v")

    case Version.parse(version) do
      {:ok, _} -> version
      :error -> nil
    end
  end

  # A command the MC shows but does not run: WinGet owns its Claude installs,
  # and updating one through `claude update` would fight it.
  defp manual_command("claudeAgent", path) do
    normalized = path |> String.replace("\\", "/") |> String.downcase()
    if String.contains?(normalized, "/winget/"), do: ["winget", "upgrade", "Anthropic.ClaudeCode"]
  end

  defp manual_command(_driver, _path), do: nil

  @doc """
  `server.updateProvider`: runs the provider's updater, then reports providers again.
  A `targetVersion` installs that exact release instead of the latest, which only
  npm installs can do (`canInstallVersion`). An `instanceId` updates that instance's
  executable instead of the driver's built-in one.
  """
  def update(%{"provider" => driver} = input) do
    target = input["targetVersion"]
    instance = input["instanceId"] || driver

    try do
      with {:path, path} when is_binary(path) <- {:path, executable(driver, instance)},
           {:command, [_ | _] = command} <- {:command, update_command(driver, path)},
           {:target, true} <- {:target, target == nil or targeted(command, target) != nil},
           {:idle, true} <- {:idle, claim(instance)} do
        try do
          locked(lock_key(command), instance, fn -> run(driver, instance, target) end)
        after
          release(instance)
        end
      else
        {:idle, false} ->
          error(driver, "An update is already running for this provider.")

        {:path, _} ->
          error(driver, "#{@names[driver] || driver} is not installed on this machine.")

        {:command, _} ->
          error(driver, "This installation cannot be updated from here.")

        {:target, _} ->
          error(driver, "This installation cannot install v#{target}.")
      end
    rescue
      exception -> failed(driver, instance, nil, Exception.message(exception))
    end
  end

  @doc "Adds the provider's `updateState` to its entry, once it has been updated."
  def put_state(%{"driver" => driver} = entry) do
    case :persistent_term.get({__MODULE__, entry["instanceId"] || driver, :state}, nil) do
      nil -> entry
      state -> Map.put(entry, "updateState", state)
    end
  end

  # One update per instance at a time, held from the request to its end, queued or
  # running; a second is refused, not queued behind it.
  defp claim(instance),
    do: :global.set_lock({{__MODULE__, :instance, instance}, self()}, [node()], 0)

  defp release(instance),
    do: :global.del_lock({{__MODULE__, :instance, instance}, self()}, [node()])

  # One installer runs one update at a time; the others wait their turn, queued.
  defp locked(key, instance, fun) do
    lock = {{__MODULE__, key}, self()}

    unless :global.set_lock(lock, [node()], 0) do
      put_state(instance, "queued", nil, "Waiting for another provider update to finish.")
      true = :global.set_lock(lock, [node()])
    end

    try do
      fun.()
    after
      :global.del_lock(lock, [node()])
    end
  end

  defp lock_key([program | _] = command) do
    cond do
      program == "brew" or String.ends_with?(program, "/bin/brew") ->
        "homebrew"

      match?([_, "install", "-g", "--prefix", _ | _], command) ->
        "npm-global:" <> Enum.at(command, 4)

      true ->
        "self:" <> program
    end
  end

  # The program comes only from `update_command/2`: the provider's own binary,
  # the npm beside it, or the proven `<prefix>/bin/brew`; list args, no shell.
  # sobelow_skip ["CI.System"]
  defp run(driver, instance, target) do
    started = HalC2.Orchestration.Entities.now()
    put_state(instance, "running", started, "Updating provider.")
    offered = :persistent_term.get({__MODULE__, instance, :offered}, nil)
    path = executable(driver, instance)
    command = path && update_command(driver, path)

    cond do
      command == nil or (offered != nil and offered != command) ->
        failed(driver, instance, started, "Provider installation changed. Refresh and try again.")

      refusal = refusal(driver, instance, path, command, target) ->
        failed(driver, instance, started, refusal)

      # Upstream #24763: a provider a fresh probe finds current needs no installer.
      target == nil and current?(driver, instance) ->
        put_state(instance, "succeeded", started, "Already up to date.")
        {:ok, %{"providers" => HalC2.Environment.providers()}}

      true ->
        argv = if target, do: targeted(command, target), else: command

        case command(argv, update_env(driver, instance, command)) do
          {0, output} ->
            verify(driver, instance, started, output, target)

          {:timeout, output} ->
            failed(driver, instance, started, "Update timed out.", output)

          {status, output} when is_integer(status) ->
            failed(
              driver,
              instance,
              started,
              "Update command exited with code #{status}.",
              output
            )

          {:error, reason} ->
            failed(driver, instance, started, "Failed to run update command: #{reason}")
        end
    end
  end

  # Why the release an update would install may not be installed here, or nil. A
  # chosen version must still be the one the provider's compatibility policy
  # recommends, and supported; the latest must not be broken or unsupported. The
  # policy may have changed since the user was offered the update.
  defp refusal(driver, instance, path, command, target) do
    candidate = target || latest_for(driver, path, command, instance)
    advisory = candidate && HalC2.ProviderCompatibility.for_version(driver, candidate)

    cond do
      target != nil and
          (advisory == nil or advisory["recommendedVersion"] != target or
             advisory["status"] != "supported") ->
        "This version is no longer recommended or this installer cannot install a specific version. Refresh provider settings."

      target == nil and advisory != nil and advisory["status"] in ["broken", "unsupported"] ->
        "The latest provider version is incompatible with this HAL-C2 release. Review provider settings."

      true ->
        nil
    end
  end

  # Whether the instance, its version read afresh, is installed at the latest release.
  defp current?(driver, instance) do
    forget_version(driver, instance, executable(driver, instance))
    entry = Enum.find(HalC2.Environment.providers(), &(&1["instanceId"] == instance))

    entry != nil and entry["installed"] != false and
      entry["versionAdvisory"]["status"] == "current"
  end

  # Runs an update's argv, for at most `:provider_update_timeout` (five minutes),
  # and answers its exit status (or `:timeout`) and what it printed: stderr then
  # stdout, each read up to 10,000 bytes, and of that the first 10,000 characters.
  # A command that runs too long is killed with the task that owns it.
  defp command(argv, env) do
    timeout = Application.get_env(:hal_c2, :provider_update_timeout, :timer.minutes(5))

    task =
      Task.async(fn ->
        try do
          argv
          |> Exile.stream(stderr: :consume, ignore_epipe: true, env: env)
          |> Enum.reduce({nil, "", ""}, fn
            {:stdout, data}, {status, out, err} -> {status, cap(out, data), err}
            {:stderr, data}, {status, out, err} -> {status, out, cap(err, data)}
            {:exit, {:status, status}}, {_, out, err} -> {status, out, err}
            {:exit, _}, {_, out, err} -> {1, out, err}
          end)
          |> then(fn {status, out, err} -> {status, output(out, err)} end)
        rescue
          exception -> {:error, Exception.message(exception)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:timeout, nil}
    end
  end

  defp cap(text, _data) when byte_size(text) >= 10_000, do: text

  defp cap(text, data) do
    text = text <> IO.iodata_to_binary(data)
    binary_part(text, 0, min(byte_size(text), 10_000))
  end

  defp output(out, err) do
    [err, out]
    |> Enum.map(&String.replace_invalid/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> String.trim()
    |> case do
      "" -> nil
      text -> String.slice(text, 0, 10_000)
    end
  end

  # "Succeeded" needs the provider to be installed and no longer behind, or at the
  # version that was asked for.
  defp verify(driver, instance, started, output, target) do
    forget_version(driver, instance, executable(driver, instance))
    entry = Enum.find(HalC2.Environment.providers(), &(&1["instanceId"] == instance))

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

    put_state(instance, status, started, message, output)
    {:ok, %{"providers" => HalC2.Environment.providers()}}
  end

  defp failed(driver, instance, started, reason, output \\ nil) do
    message = if reason == "", do: "The update failed.", else: reason
    put_state(instance, "failed", started, message, output)
    error(driver, reason)
  end

  defp put_state(instance, status, started, message, output \\ nil) do
    finished =
      if status in ["succeeded", "failed", "unchanged"], do: HalC2.Orchestration.Entities.now()

    :persistent_term.put({__MODULE__, instance, :state}, %{
      "status" => status,
      "startedAt" => started,
      "finishedAt" => finished,
      "message" => message,
      "output" => output
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

  # Extra environment an update runs with. Grok's own updater finds the home
  # its instance uses in the instance's environment; an npm-installed Grok's
  # nested install needs its postinstall allowed or npm 12 skips the step
  # that installs the new binary.
  defp update_env("grok", instance, [_path, "update"]) do
    HalC2.Acp.instance_env(instance) ++
      [{"npm_config_allow_scripts", "@xai-official/grok"}]
  end

  defp update_env(_driver, _instance, _command), do: []

  # The updater for an executable, as argv, or nil.
  defp update_command(_driver, nil), do: nil

  # Grok updates through `grok update`, which finds the installer that owns
  # the binary — except a Homebrew cask, which brew upgrades so no second
  # install appears beside it. A cask counts as brew's only under the prefix
  # whose own `bin/brew` sits beside its Caskroom; any other cask path is
  # left to the user. A binary that cannot be resolved is never handed to
  # an updater.
  defp update_command("grok", path) do
    real = real_path(path)

    cond do
      not File.exists?(real) ->
        nil

      String.contains?(real, "/Caskroom/") ->
        case cask(real) do
          {brew, name} when is_binary(brew) -> [brew, "upgrade", "--cask", name]
          _ -> nil
        end

      String.contains?(real, "/Cellar/") ->
        ["brew", "upgrade", real |> String.split("/Cellar/") |> Enum.at(1) |> first_segment()]

      true ->
        [path, "update"]
    end
  end

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

      # Claude's own installer puts `claude` in the user's `.local/bin`, linked to
      # the version it keeps under `.local/share/claude`; it updates itself.
      driver == "claudeAgent" and
          (String.contains?(real, "/claude/") or
             String.ends_with?(path, "/.local/bin/claude")) ->
        [path, "update"]

      # OpenCode's own installer keeps it in the user's `.opencode/bin`; it upgrades itself.
      driver == "opencode" and String.contains?(real, "/.opencode/bin/") ->
        [path, "upgrade"]

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

  @doc """
  The executable instance `instance` of `driver` updates, or nil. An OpenCode instance
  runs its `binaryPath`, else `opencode` on the PATH.
  """
  def executable(driver, instance)

  def executable(driver, instance) when driver in ["codex", "claudeAgent"] do
    key = if driver == "codex", do: :codex_command, else: :claude_command
    default = [if(driver == "codex", do: "codex", else: "claude")]

    case HalC2.Settings.instance_command(instance, Application.get_env(:hal_c2, key, default)) do
      [command | _] -> System.find_executable(command)
      _ -> nil
    end
  end

  def executable("opencode", instance) do
    case HalC2.Acp.binary_path(instance) do
      nil -> nil
      path -> if Path.type(path) == :absolute, do: path, else: System.find_executable(path)
    end
  end

  # A Grok binary that cannot be resolved updates by hand: no executable.
  def executable("grok", instance) do
    case HalC2.Acp.binary_path(instance) do
      nil -> nil
      path -> System.find_executable(path)
    end
  end

  def executable(_driver, _instance), do: nil

  # Provider entries cache the version of each executable; an update makes the
  # updated one's stale, and only that one is read again. OpenCode's is read again from
  # a throwaway session of the CLI on disk; its running sessions keep the version they
  # started with.
  defp forget_version(driver, instance, _path) when driver in ["opencode", "grok"],
    do: HalC2.Acp.reload(instance)

  defp forget_version(driver, _instance, path) do
    module = %{"codex" => HalC2.Codex.Provider, "claudeAgent" => HalC2.Claude.Provider}[driver]

    if module do
      versions = :persistent_term.get({module, :version}, %{})
      :persistent_term.put({module, :version}, Map.delete(versions, path))
    end

    :ok
  end

  # The `brew` and cask name owning an executable under a Caskroom, or nil
  # when that prefix has no brew of its own to prove it.
  defp cask(real) do
    [prefix, rest] = String.split(real, "/Caskroom/", parts: 2)
    brew = Path.join(prefix, "bin/brew")
    if File.exists?(brew), do: {brew, first_segment(rest)}
  end

  defp grok_latest(path) do
    real = real_path(path)

    if String.contains?(real, "/Caskroom/") do
      case cask(real) do
        {brew, name} -> cask_latest(brew, name)
        _ -> nil
      end
    else
      latest("grok", nil)
    end
  end

  defp cask_latest(brew, name) do
    key = {__MODULE__, {:cask, name}}

    case :persistent_term.get(key, nil) do
      {version, read_at} ->
        if System.monotonic_time(:millisecond) - read_at > @ttl,
          do: refresh_cask(brew, name)

        version

      nil ->
        refresh_cask(brew, name)
        nil
    end
  end

  # `brew` is the proven `<prefix>/bin/brew` from `cask/1`; list args, no shell.
  # sobelow_skip ["CI.System"]
  defp refresh_cask(brew, name) do
    key = {__MODULE__, {:cask, name}, :reading}

    if Application.get_env(:hal_c2, :provider_update_checks, true) &&
         :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Task.start(fn ->
        try do
          with {out, 0} <-
                 System.cmd(brew, ["info", "--cask", "--json=v2", name], stderr_to_stdout: true),
               {:ok, %{"casks" => [%{"version" => version} | _]}} <- JSON.decode(out) do
            :persistent_term.put(
              {__MODULE__, {:cask, name}},
              {version, System.monotonic_time(:millisecond)}
            )

            HalC2.Settings.notify_providers()
          end
        rescue
          _ -> nil
        after
          :persistent_term.put(key, false)
        end
      end)
    end
  end

  # The latest release as last read, starting a read when it is missing or stale. A
  # read that found nothing counts as a read: it is tried again once it is stale too.
  defp latest(driver, update) do
    case :persistent_term.get({__MODULE__, driver}, nil) do
      {version, read_at} ->
        if System.monotonic_time(:millisecond) - read_at > @ttl, do: refresh(driver, update)
        version

      nil ->
        refresh(driver, update)
        nil
    end
  end

  defp checked_at(driver), do: :persistent_term.get({__MODULE__, driver, :checked_at}, nil)

  defp refresh(driver, update) do
    package = @packages[driver]
    key = {__MODULE__, driver, :reading}

    if package && Application.get_env(:hal_c2, :provider_update_checks, true) &&
         :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Task.start(fn ->
        try do
          now = System.monotonic_time(:millisecond)

          case lookup_latest(package, update) do
            failed when failed in [nil, :npm_failed] ->
              # Keeps what an earlier read found, and when this one tried.
              {last, _} = :persistent_term.get({__MODULE__, driver}, {nil, now})
              :persistent_term.put({__MODULE__, driver}, {last, now})

              if failed == :npm_failed,
                do: Logger.warning("Configured npm version lookup failed for #{package}")

            version ->
              :persistent_term.put({__MODULE__, driver}, {version, now})

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

  # npm owns the registry, scoped auth and proxy the machine is set up with, so the
  # npm on the MC's PATH is asked, at the install's prefix when npm installed it. When
  # it cannot say, the public registry is not asked behind its back; without npm, it
  # is (`:npm_registry_url` stands in for it in tests).
  defp lookup_latest(package, update) do
    case System.find_executable("npm") do
      nil -> registry_latest(package)
      npm -> npm_latest(npm, package, update)
    end
  end

  defp npm_latest(npm, package, update) do
    prefix =
      case update do
        [_npm, "install", "-g", "--prefix", prefix, _package] -> ["--prefix", prefix]
        _ -> []
      end

    args = ["view", "--global"] ++ prefix ++ ["--json", package <> "@latest", "version"]
    task = Task.async(fn -> npm_view([npm | args]) end)

    case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, version} when is_binary(version) -> version
      _ -> :npm_failed
    end
  end

  # `npm view --json` prints the version as a JSON string, or a list of one.
  defp npm_view(argv) do
    argv
    |> Exile.stream(stderr: :disable, ignore_epipe: true)
    |> Enum.reduce({[], nil}, fn
      {:exit, status}, {out, _} -> {out, status}
      data, {out, status} when is_binary(data) -> {[out, data], status}
      _, acc -> acc
    end)
    |> case do
      {out, {:status, 0}} ->
        case out |> IO.iodata_to_binary() |> String.trim() |> JSON.decode() do
          {:ok, version} when is_binary(version) and version != "" -> version
          {:ok, [version]} when is_binary(version) and version != "" -> version
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp registry_latest(package) do
    base = Application.get_env(:hal_c2, :npm_registry_url, "https://registry.npmjs.org")
    url = ~c"#{base}/#{String.replace(package, "/", "%2F")}/latest"

    case :httpc.request(
           :get,
           {url, []},
           [timeout: 4_000] ++ ssl(url),
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

  defp ssl(~c"https://" ++ _), do: [ssl: :httpc.ssl_verify_host_options(true)]
  defp ssl(_url), do: []

  defp newer?(latest, current) do
    with {:ok, latest} <- Version.parse(latest),
         {:ok, current} <- Version.parse(current) do
      Version.compare(latest, current) == :gt
    else
      _ -> false
    end
  end
end
