defmodule HalC2.Acp.Catalog do
  @moduledoc """
  The official ACP Registry: searching it, and installing its agents into the MC's
  tools directory so `acpRegistry` provider instances can run them.

  The index is cached in `<home>/cache/acp-registry/registry.json`, refreshed on
  every search and otherwise once a day. An agent installs under
  `<home>/tools/<id>/<version>/`: a binary archive (checked against the registry's
  sha256 when it lists one) is extracted into `<platform>/`, an npx package goes to
  `npm/` through `npm install --global` with that prefix, and a uvx package to
  `python/` through `uv tool install`. Sessions run the installed executable, never
  `npx` or `uvx`, so a turn does not wait on a package manager.

  Failures are `AcpRegistryOperationError` details, which clients decode.
  """

  require Logger

  @url "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
  @max_index_bytes 1_048_576
  @max_agents 512
  @max_results 20
  @stale_ms 24 * 60 * 60 * 1000
  @search_stale_ms 5 * 60 * 1000
  @install_timeout 20 * 60 * 1000
  @id ~r/^[a-z0-9][a-z0-9._-]{0,127}$/
  @version ~r/^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/

  # --- RPCs ------------------------------------------------------------------------

  @doc "`server.searchAcpRegistry`: agents matching a query, best first."
  def search(%{} = input) do
    query = input["query"] |> to_string() |> String.trim() |> String.downcase()

    with {:ok, agents} <- index(:search) do
      found =
        for agent <- agents,
            dist = distribution(agent, "auto"),
            runner_available?(dist),
            rank = rank(agent, query),
            do: {rank, String.downcase(agent["name"]), agent, dist}

      {:ok,
       %{
         "agents" =>
           found
           |> Enum.sort_by(fn {rank, name, agent, _} -> {rank, name, agent["id"]} end)
           |> Enum.take(@max_results)
           |> Enum.map(fn {_, _, agent, dist} -> summary(agent, dist) end)
       }}
    end
  end

  @doc "`server.prepareAcpRegistryAgent`: installs an agent's current version."
  def prepare(%{"agentId" => id}) do
    with {:ok, agent} <- agent(id, true),
         {:ok, dist} <- pick(agent, "auto"),
         {:ok, _exe} <- install(agent, dist) do
      {:ok,
       %{
         "agentId" => id,
         "version" => agent["version"],
         "distribution" => dist.kind,
         "prepared" => true
       }}
    end
  end

  @doc """
  `server.uninstallAcpRegistryManagedBinary`: removes an agent's installs, unless a
  provider instance still uses it.
  """
  def uninstall(%{"agentId" => id}) do
    cond do
      not (is_binary(id) and Regex.match?(@id, id)) ->
        error(
          "agent_not_found",
          "ACP Registry managed binary uninstall received an invalid agent ID."
        )

      referenced?(id) ->
        {:ok, %{"agentId" => id, "removed" => false}}

      true ->
        {:ok, %{"agentId" => id, "removed" => remove_binaries(Path.join(tools_dir(), id))}}
    end
  end

  # Only the downloaded binaries are the MC's to remove; what a package
  # manager installed under `npm/` or `python/` stays.
  defp remove_binaries(dir) do
    removed =
      for version <- list_dir(dir),
          sub <- list_dir(Path.join(dir, version)),
          sub not in ["npm", "python"],
          File.dir?(Path.join([dir, version, sub])) do
        File.rm_rf!(Path.join([dir, version, sub]))
        true
      end

    for version <- list_dir(dir), list_dir(Path.join(dir, version)) == [] do
      File.rmdir(Path.join(dir, version))
    end

    if File.dir?(dir) and list_dir(dir) == [], do: File.rmdir(dir)
    removed != []
  end

  defp list_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  defp referenced?(id) do
    HalC2.Settings.settings()
    |> Map.get("providerInstances", %{})
    |> Enum.any?(fn {_, instance} ->
      is_map(instance) and instance["driver"] == "acpRegistry" and
        get_in(instance, ["config", "agentId"]) == id
    end)
  end

  # --- running ---------------------------------------------------------------------

  @doc """
  The command and environment that start an `acpRegistry` instance's agent, from its
  settings `config`, installing the agent's current version first when needed.
  """
  def command(%{} = config) do
    with {:ok, agent} <- agent(config["agentId"], false),
         {:ok, dist} <- pick(agent, config["distribution"] || "auto"),
         {:ok, exe} <- executable(agent, dist, config["commandPath"]) do
      # The installed command's own folder leads its PATH, so helpers the
      # package installed beside it win over same-named commands elsewhere.
      rest = dist.env["PATH"] || System.get_env("PATH") || ""
      env = Map.put(dist.env, "PATH", Enum.join([Path.dirname(exe), rest], ":"))
      {:ok, [exe | dist.args], Enum.to_list(env)}
    end
  end

  defp executable(agent, _dist, path) when is_binary(path) and path != "" do
    case System.find_executable(path) do
      nil ->
        error(
          "runner_unavailable",
          "ACP Registry agent #{agent["id"]} requires '#{path}', but it is not available on this provider instance's PATH."
        )

      exe ->
        {:ok, exe}
    end
  end

  defp executable(agent, dist, _path), do: install(agent, dist)

  @doc "The registry entry's name and version, for an instance's provider snapshot."
  def describe(agent_id) do
    case agent(agent_id, false) do
      {:ok, agent} -> %{name: agent["name"], version: agent["version"], website: agent["website"]}
      _ -> nil
    end
  end

  # --- index -----------------------------------------------------------------------

  defp agent(id, refresh) do
    with {:ok, agents} <- index(refresh) do
      case Enum.find(agents, &(&1["id"] == id)) do
        nil -> error("agent_not_found", "#{inspect(id)} is not in the ACP Registry.")
        agent -> {:ok, agent}
      end
    end
  end

  @doc """
  The registry's agents, from memory, disk, or the network, as HAL-C2 runs them
  (`HalC2.Acp.Kimi.registry_entry/1`). Memory keeps the registry's own entries, so an
  MC that loads new code runs the new entries without waiting out the cache.
  """
  def index(refresh \\ false) do
    with {:ok, agents} <- cached_index(refresh),
         do: {:ok, Enum.map(agents, &HalC2.Acp.Kimi.registry_entry/1)}
  end

  # The cache is `{fetched_at, agents, fresh}`: `fresh` is false once a fetch
  # failed and the cached copy served instead, so a search tries again.
  defp current_cache do
    case :persistent_term.get({__MODULE__, :index}, nil) || read_cache() do
      {at, agents} -> {at, agents, true}
      {at, agents, fresh} -> {at, agents, fresh}
      nil -> nil
    end
  end

  defp usable?(_cached, true), do: false

  defp usable?({at, _agents, fresh}, mode) do
    age = System.system_time(:millisecond) - at

    case mode do
      :search -> fresh and age >= 0 and age < @search_stale_ms
      _ -> age >= 0 and age < @stale_ms
    end
  end

  defp cached_index(mode) do
    case current_cache() do
      {_, agents, _} = cached ->
        if usable?(cached, mode), do: {:ok, agents}, else: fetch_index(mode)

      nil ->
        fetch_index(mode)
    end
  end

  # One fetch at a time: a caller that waited re-reads the cache first, so
  # searches made at the same moment share the winner's fetch.
  defp fetch_index(mode) do
    :global.trans(
      {{__MODULE__, :fetch}, self()},
      fn ->
        case current_cache() do
          {_, agents, _} = cached ->
            if usable?(cached, mode), do: {:ok, agents}, else: do_fetch(cached)

          nil ->
            do_fetch(nil)
        end
      end,
      [node()]
    )
  end

  defp do_fetch(cached) do
    case fetch() do
      {:ok, text, agents} ->
        write_cache(text)

        :persistent_term.put(
          {__MODULE__, :index},
          {System.system_time(:millisecond), agents, true}
        )

        {:ok, agents}

      {:error, _} = error ->
        case cached do
          {at, agents, _} ->
            :persistent_term.put({__MODULE__, :index}, {at, agents, false})
            {:ok, agents}

          nil ->
            error
        end
    end
  end

  defp fetch do
    url = registry_url()

    case get(url, 30_000) do
      {:ok, text} ->
        parse_index(text)

      {:error, {:http_status, _status}} ->
        unavailable("Could not fetch ACP Registry index from #{url}.")

      {:error, :timeout} ->
        unavailable("Timed out fetching ACP Registry index.")

      {:error, {:failed_connect, _}} ->
        unavailable("The ACP Registry could not be loaded.")

      {:error, _} ->
        unavailable("Could not read ACP Registry response body.")
    end
  end

  defp parse_index(text) do
    cond do
      byte_size(text) > @max_index_bytes ->
        unavailable("ACP Registry index exceeds #{@max_index_bytes} bytes.")

      not String.valid?(text) ->
        unavailable("ACP Registry index is not valid UTF-8.")

      true ->
        case JSON.decode(text) do
          {:ok, %{"agents" => agents}} when is_list(agents) and length(agents) <= @max_agents ->
            {:ok, text, registry(agents)}

          {:ok, _} ->
            unavailable("ACP Registry returned an invalid index.")

          {:error, _} ->
            unavailable("ACP Registry returned invalid JSON.")
        end
    end
  end

  defp unavailable(message), do: error("registry_unavailable", message)

  defp read_cache do
    with {:ok, %{mtime: mtime}} <- File.stat(cache_path(), time: :posix),
         {:ok, text} <- File.read(cache_path()),
         {:ok, %{"agents" => agents}} when is_list(agents) <- JSON.decode(text) do
      cached = {mtime * 1000, registry(agents), true}
      :persistent_term.put({__MODULE__, :index}, cached)
      cached
    else
      _ -> nil
    end
  end

  defp write_cache(text) do
    path = cache_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path <> ".tmp", text)
    File.rename!(path <> ".tmp", path)
  end

  # Ids and versions become directory names; commands must stay inside the install.
  defp valid?(%{"id" => id, "name" => name, "version" => version, "distribution" => %{}} = agent)
       when is_binary(id) and is_binary(name) and is_binary(version) do
    Regex.match?(@id, id) and Regex.match?(@version, version) and
      String.trim(name) != "" and
      is_binary(agent["description"] || "") and
      Enum.all?(Map.values(get_in(agent, ["distribution", "binary"]) || %{}), &valid_target?/1) and
      pinned?(agent, "npx") and pinned?(agent, "uvx")
  end

  defp valid?(_), do: false

  # A package distribution the registry lists must pin the exact version to
  # install: `name@1.2.3` for npx, `name==1.2.3` (or `name@1.2.3`) for uvx.
  @exact_version ~r/\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/

  defp pinned?(agent, kind) do
    case get_in(agent, ["distribution", kind]) do
      nil ->
        true

      %{"package" => package} when is_binary(package) ->
        not String.contains?(package, [" ", "^", "~", "*", ">", "<"]) and
          case kind do
            "npx" -> not String.contains?(package, "==") and at_pinned?(package)
            "uvx" -> Regex.match?(~r/==\d/, package) or at_pinned?(package)
          end

      _ ->
        false
    end
  end

  defp at_pinned?(package) do
    case String.split(package, "@") do
      [_] -> false
      parts -> Regex.match?(@exact_version, List.last(parts))
    end
  end

  defp registry(agents), do: Enum.filter(agents, &valid?/1)

  # Archives come over HTTPS; plain HTTP only from this machine (a local mirror, tests).
  # The command path is checked when the agent is prepared, before any download.
  defp valid_target?(%{"archive" => archive, "cmd" => cmd})
       when is_binary(archive) and is_binary(cmd) do
    uri = URI.parse(archive)

    (uri.scheme == "https" or (uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost"])) and
      uri.userinfo == nil
  end

  defp valid_target?(_), do: false

  defp relative_segments(path) do
    normalized = path |> String.trim() |> String.replace("\\", "/") |> String.trim_leading("./")
    segments = String.split(normalized, "/", trim: true)

    if segments != [] and not String.starts_with?(normalized, "/") and
         not Regex.match?(~r/^[a-zA-Z]:/, normalized) and
         not Enum.any?(segments, &(&1 in [".", ".."])),
       do: segments
  end

  # --- search ----------------------------------------------------------------------

  defp rank(_agent, ""), do: 100

  defp rank(agent, query) do
    id = String.downcase(agent["id"])
    name = String.downcase(agent["name"])
    authors = (agent["authors"] || []) |> Enum.join(" ") |> String.downcase()
    description = String.downcase(agent["description"] || "")
    terms = String.split(query)
    tokens = String.split("#{id} #{name}", ~r/[^a-z0-9]+/, trim: true)

    cond do
      id == query or name == query -> 0
      String.starts_with?(id, query) or String.starts_with?(name, query) -> 10
      Enum.all?(terms, fn t -> Enum.any?(tokens, &String.starts_with?(&1, t)) end) -> 20
      Enum.all?(terms, &(String.contains?(id, &1) or String.contains?(name, &1))) -> 30
      Enum.all?(terms, &String.contains?(authors, &1)) -> 40
      Enum.all?(terms, &String.contains?("#{id} #{name} #{authors} #{description}", &1)) -> 50
      true -> nil
    end
  end

  defp summary(agent, dist) do
    %{
      "id" => agent["id"],
      "name" => agent["name"],
      "version" => agent["version"],
      "description" => String.slice(agent["description"] || "", 0, 1024),
      "authors" => Enum.take(agent["authors"] || [], 16),
      "license" => agent["license"],
      "website" => agent["website"],
      "repository" => agent["repository"],
      "icon" => agent["icon"],
      "distribution" => dist.kind,
      "integrity" =>
        if(dist.kind == "binary" and dist.target["sha256"], do: "sha256", else: "registry")
    }
  end

  # --- distributions ---------------------------------------------------------------

  defp pick(agent, preference) do
    case distribution(agent, preference) do
      nil ->
        error(
          "unsupported_platform",
          "#{agent["name"]} has no distribution for #{platform() || "this platform"}."
        )

      dist ->
        {:ok, dist}
    end
  end

  defp distribution(agent, preference) do
    dists = agent["distribution"]
    kinds = if preference in ["binary", "npx", "uvx"], do: [preference], else: ~w(binary npx uvx)

    Enum.find_value(kinds, fn
      "binary" ->
        case binary_target(dists) do
          {platform, target} -> dist("binary", target, target, platform)
          nil -> nil
        end

      kind ->
        if is_binary(get_in(dists, [kind, "package"])), do: dist(kind, dists[kind], nil, nil)
    end)
  end

  # Windows on ARM runs x64 builds, so one serves when no ARM build is published.
  defp binary_target(dists) do
    platforms =
      case platform() do
        "windows-aarch64" -> ["windows-aarch64", "windows-x86_64"]
        other -> [other]
      end

    Enum.find_value(platforms, fn platform ->
      target = platform && get_in(dists, ["binary", platform])
      if target, do: {platform, target}
    end)
  end

  defp dist(kind, spec, target, platform) do
    %{
      kind: kind,
      target: target,
      platform: platform,
      package: spec["package"],
      args: Enum.filter(spec["args"] || [], &is_binary/1),
      env: for({k, v} <- spec["env"] || %{}, is_binary(v), into: %{}, do: {k, v})
    }
  end

  # Search only offers agents this machine can run: a package agent whose
  # package manager is missing cannot be installed here.
  defp runner_available?(%{kind: "npx"}), do: System.find_executable("npm") != nil
  defp runner_available?(%{kind: "uvx"}), do: System.find_executable("uv") != nil
  defp runner_available?(_dist), do: true

  @doc "The registry's name for this machine, such as `darwin-aarch64`."
  def platform do
    case Application.get_env(:hal_c2, :acp_platform, :auto) do
      :auto -> machine_platform()
      override -> override
    end
  end

  defp machine_platform do
    os =
      case :os.type() do
        {:unix, :darwin} -> "darwin"
        {:unix, :linux} -> "linux"
        {:win32, _} -> "windows"
        _ -> nil
      end

    arch =
      case :erlang.system_info(:system_architecture) |> to_string() do
        "aarch64" <> _ -> "aarch64"
        "arm64" <> _ -> "aarch64"
        "x86_64" <> _ -> "x86_64"
        "amd64" <> _ -> "x86_64"
        _ -> nil
      end

    if os && arch, do: "#{os}-#{arch}"
  end

  # --- installs --------------------------------------------------------------------

  # One install per agent at a time; a second caller waits and finds it done.
  defp install(agent, %{kind: "binary", target: target} = dist) do
    # Refused before anything is downloaded.
    if relative_segments(target["cmd"]) do
      locked_install(agent, dist)
    else
      error(
        "archive_invalid",
        "ACP Registry agent #{agent["id"]} declares an unsafe command path '#{target["cmd"]}'."
      )
    end
  end

  defp install(agent, dist), do: locked_install(agent, dist)

  defp locked_install(agent, dist) do
    lock = {{__MODULE__, agent["id"]}, self()}

    :global.trans(
      lock,
      fn ->
        case installed(agent, dist) do
          nil -> do_install(agent, dist)
          result -> result
        end
      end,
      [node()]
    )
  end

  defp version_dir(agent),
    do: Path.join([tools_dir(), agent["id"], URI.encode_www_form(agent["version"])])

  defp binary_root(agent, dist), do: Path.join(version_dir(agent), dist.platform || platform())

  # An installed binary is checked again every time it is used: what is there
  # now may not be what the install put there.
  defp installed(agent, %{kind: "binary"} = dist) do
    root = binary_root(agent, dist)
    exe = Path.join([root | relative_segments(dist.target["cmd"])])

    case File.lstat(exe) do
      {:ok, _} ->
        case check_command(agent, root, exe, dist.target["cmd"]) do
          :ok -> {:ok, exe}
          {:error, _} = error -> error
        end

      _ ->
        nil
    end
  end

  defp installed(agent, dist) do
    case package_executable(agent, dist) do
      {:ok, exe} -> {:ok, exe}
      _ -> nil
    end
  end

  defp check_command(agent, root, exe, cmd) do
    case File.lstat(exe) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        case resolved_inside?(exe, root) do
          true ->
            :ok

          false ->
            archive_error(
              "ACP Registry archive command resolves outside its installation directory."
            )
        end

      {:ok, _} ->
        archive_error("ACP Registry archive command is not a regular executable file.")

      _ ->
        archive_error(
          "ACP Registry archive for #{agent["id"]} did not contain '#{Path.join(relative_segments(cmd))}'."
        )
    end
  end

  defp resolved_inside?(exe, root) do
    with {:ok, resolved} <- :file.read_link_all(to_charlist(exe)) do
      resolved = Path.expand(to_string(resolved))
      root = Path.expand(root)
      (resolved == root or String.starts_with?(resolved, root <> "/")) and File.regular?(resolved)
    else
      _ -> false
    end
  end

  defp archive_error(message), do: error("archive_invalid", message)

  defp do_install(agent, %{kind: "binary", target: target} = dist) do
    root = binary_root(agent, dist)
    tmp = "#{root}.tmp-#{System.unique_integer([:positive])}"
    archive = Path.join(tmp <> ".download", archive_name(target["archive"]))

    try do
      File.mkdir_p!(Path.dirname(archive))
      File.mkdir_p!(tmp)

      with :ok <- download(agent, target["archive"], archive),
           :ok <- verify(archive, target["sha256"]),
           :ok <- check_archive(agent, archive),
           :ok <- extract(archive, tmp, target["cmd"]),
           exe = Path.join([tmp | relative_segments(target["cmd"])]),
           :ok <- check_command(agent, tmp, exe, target["cmd"]) do
        File.chmod!(exe, 0o755)
        File.rm_rf!(root)
        File.rename!(tmp, root)
        installed(agent, dist)
      end
    rescue
      _ in File.Error ->
        error(
          "download_failed",
          "Could not save ACP Registry agent #{agent["id"]} #{agent["version"]}."
        )
    after
      File.rm_rf(tmp)
      File.rm_rf(tmp <> ".download")
    end
  end

  defp do_install(agent, %{kind: kind, package: package} = dist) do
    {manager, args} =
      if kind == "npx",
        do: {"npm", ["install", "--global", package]},
        else: {"uv", ["tool", "install", "--force", package]}

    with {:ok, path} <- runner(manager, agent),
         dir = package_dir(agent, kind),
         :ok <- File.mkdir_p(dir),
         {:ok, _} <- run([path | args], package_env(agent, kind)) do
      case package_executable(agent, dist) do
        {:ok, exe} ->
          {:ok, exe}

        :error ->
          error(
            "install_failed",
            "ACP Registry installed #{package}, but could not resolve its global command."
          )
      end
    end
  end

  defp runner("uv", agent) do
    case System.find_executable("uv") do
      nil ->
        error(
          "runner_unavailable",
          "ACP Registry agent #{agent["id"]} requires 'uv', but it is not available on this environment's PATH."
        )

      path ->
        {:ok, path}
    end
  end

  defp runner(manager, _agent) do
    case System.find_executable(manager) do
      nil -> error("runner_unavailable", "Install #{manager} to use this agent.")
      path -> {:ok, path}
    end
  end

  # No entry of an archive may land outside the folder it is unpacked into.
  defp check_archive(agent, archive) do
    names =
      case Path.basename(archive) do
        "agent.tar.gz" ->
          case :erl_tar.table(to_charlist(archive), [:compressed]) do
            {:ok, names} -> Enum.map(names, &to_string/1)
            _ -> nil
          end

        "agent.zip" ->
          case :zip.list_dir(to_charlist(archive)) do
            {:ok, entries} ->
              for {:zip_file, name, _, _, _, _} <- entries, do: to_string(name)

            _ ->
              nil
          end

        "agent.tar.bz2" ->
          case System.cmd("tar", ["-tjf", archive], stderr_to_stdout: true) do
            {out, 0} -> String.split(out, "\n", trim: true)
            _ -> nil
          end

        _ ->
          []
      end

    cond do
      names == nil ->
        archive_error("The archive could not be extracted: it could not be listed.")

      Enum.any?(names, &unsafe_entry?/1) ->
        archive_error("ACP Registry agent #{agent["id"]} archive contains an unsafe path.")

      true ->
        :ok
    end
  end

  defp unsafe_entry?(name) do
    normalized = String.replace(name, "\\", "/")

    String.starts_with?(normalized, "/") or Regex.match?(~r/^[a-zA-Z]:/, normalized) or
      Enum.member?(String.split(normalized, "/"), "..")
  end

  defp package_dir(agent, "npx"), do: Path.join(version_dir(agent), "npm")
  defp package_dir(agent, "uvx"), do: Path.join(version_dir(agent), "python")

  defp package_env(agent, "npx"), do: [{"npm_config_prefix", package_dir(agent, "npx")}]

  defp package_env(agent, "uvx") do
    dir = package_dir(agent, "uvx")
    [{"UV_TOOL_DIR", dir}, {"UV_TOOL_BIN_DIR", Path.join(dir, "bin")}]
  end

  # npm names its commands in the package manifest; uv puts them in the bin dir.
  defp package_executable(agent, %{kind: "npx", package: package}) do
    name = package_name(package)
    root = Path.join([package_dir(agent, "npx"), "lib", "node_modules" | String.split(name, "/")])

    with {:ok, text} <- File.read(Path.join(root, "package.json")),
         {:ok, %{"bin" => bin} = manifest} <- JSON.decode(text),
         true <- manifest["version"] in [nil, pinned_version(package)],
         command when is_binary(command) <- bin_command(bin, agent["id"], name),
         exe = Path.join([package_dir(agent, "npx"), "bin", command]),
         true <- File.exists?(exe) do
      {:ok, exe}
    else
      _ -> :error
    end
  end

  defp package_executable(agent, %{kind: "uvx", package: package}) do
    bin = Path.join(package_dir(agent, "uvx"), "bin")
    names = [agent["id"], package_name(package)]

    with {:ok, [_ | _] = entries} <- File.ls(bin) do
      command = Enum.find(names, &(&1 in entries)) || Enum.min(entries)
      {:ok, Path.join(bin, command)}
    else
      _ -> :error
    end
  end

  defp package_name(package) do
    case String.split(package, "==") do
      [name, _] ->
        name

      _ ->
        {name, _} = package |> String.split("@") |> Enum.split(-1)
        Enum.join(name, "@")
    end
  end

  defp pinned_version(package) do
    case String.split(package, "==") do
      [_, version] -> version
      _ -> package |> String.split("@") |> List.last()
    end
  end

  defp bin_command(bin, _agent_id, name) when is_binary(bin),
    do: name |> String.split("/") |> List.last()

  # The agent's command is the one named for the agent or the package; failing
  # that, the only command, or the first by name of several that all lead to
  # the same file. Commands that cannot be told apart resolve to none.
  defp bin_command(%{} = bin, agent_id, name) when map_size(bin) > 0 do
    short = name |> String.split("/") |> List.last()

    cond do
      Map.has_key?(bin, agent_id) -> agent_id
      Map.has_key?(bin, short) -> short
      map_size(bin) == 1 -> bin |> Map.keys() |> hd()
      bin |> Map.values() |> Enum.uniq() |> length() == 1 -> bin |> Map.keys() |> Enum.min()
      true -> nil
    end
  end

  defp bin_command(_, _, _), do: nil

  defp archive_name(url) do
    path = URI.parse(url).path |> to_string() |> String.downcase()

    cond do
      String.ends_with?(path, [".tar.gz", ".tgz"]) -> "agent.tar.gz"
      String.ends_with?(path, [".tar.bz2", ".tbz2"]) -> "agent.tar.bz2"
      String.ends_with?(path, ".zip") -> "agent.zip"
      true -> "agent.bin"
    end
  end

  defp verify(_archive, nil), do: :ok

  defp verify(archive, sha256) do
    digest =
      File.stream!(archive, 1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if digest == String.downcase(sha256),
      do: :ok,
      else: error("checksum_mismatch", "The downloaded archive does not match its sha256.")
  end

  # erl_tar and zip refuse entries that would land outside `dir`.
  defp extract(archive, dir, cmd) do
    result =
      case Path.basename(archive) do
        "agent.tar.gz" ->
          :erl_tar.extract(to_charlist(archive), [:compressed, cwd: to_charlist(dir)])

        "agent.zip" ->
          with {:ok, _} <- :zip.extract(to_charlist(archive), cwd: to_charlist(dir)), do: :ok

        "agent.tar.bz2" ->
          case System.cmd("tar", ["-xjf", archive, "-C", dir], stderr_to_stdout: true) do
            {_, 0} -> :ok
            {out, _} -> {:error, out}
          end

        "agent.bin" ->
          dest = Path.join([dir | relative_segments(cmd)])
          File.mkdir_p!(Path.dirname(dest))
          File.cp(archive, dest)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        error("archive_invalid", "The archive could not be extracted: #{inspect(reason)}")
    end
  end

  # --- processes and HTTP ----------------------------------------------------------

  defp run(cmd, env) do
    trapping = Process.flag(:trap_exit, true)

    task =
      Task.async(fn ->
        Exile.stream(cmd, env: env, stderr: :redirect_to_stdout, ignore_epipe: true)
        |> Enum.reduce({[], nil}, fn
          {:exit, status}, {out, _} -> {out, status}
          data, {out, status} when is_binary(data) -> {[out, data], status}
          _, acc -> acc
        end)
      end)

    result = Task.yield(task, @install_timeout) || Task.shutdown(task, :brutal_kill)
    Process.flag(:trap_exit, trapping)

    case result do
      {:ok, {out, {:status, 0}}} ->
        {:ok, IO.iodata_to_binary(out)}

      {:ok, {out, {:status, code}}} ->
        text = out |> IO.iodata_to_binary() |> String.trim() |> String.slice(-1000, 1000)
        text = if text == "", do: "", else: ": #{text}"

        error(
          "install_failed",
          "ACP Registry install command '#{hd(cmd)}' exited with code #{code}#{text}"
        )

      {:ok, {_out, _other}} ->
        error("install_failed", "Could not run ACP Registry install command '#{hd(cmd)}'.")

      {:exit, _reason} ->
        error("install_failed", "Could not run ACP Registry install command '#{hd(cmd)}'.")

      nil ->
        error("install_failed", "Timed out running ACP Registry install command '#{hd(cmd)}'.")
    end
  rescue
    _ in Exile.Stream.AbnormalExit ->
      error("install_failed", "Could not run ACP Registry install command '#{hd(cmd)}'.")
  end

  defp get(url, timeout) do
    case :httpc.request(:get, {to_charlist(url), headers()}, http_options(timeout),
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _, _body}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp download(agent, url, path) do
    case :httpc.request(:get, {to_charlist(url), headers()}, http_options(@install_timeout),
           stream: to_charlist(path)
         ) do
      {:ok, :saved_to_file} ->
        :ok

      other ->
        Logger.warning("ACP agent download failed: #{inspect(other)}")

        error(
          "download_failed",
          "Could not download ACP Registry agent #{agent["id"]} #{agent["version"]}."
        )
    end
  end

  defp headers, do: [{~c"user-agent", ~c"hal-c2"}]

  defp http_options(timeout) do
    [
      timeout: timeout,
      connect_timeout: 15_000,
      autoredirect: true,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 4,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp error(reason, message),
    do:
      {:error, %{"_tag" => "AcpRegistryOperationError", "reason" => reason, "message" => message}}

  defp registry_url, do: Application.get_env(:hal_c2, :acp_registry_url, @url)

  @doc false
  def cache_path, do: Path.join([HalC2.Paths.cache_dir(), "acp-registry", "registry.json"])
  defp tools_dir, do: Path.join(HalC2.Paths.cache_dir(), "tools")
end
