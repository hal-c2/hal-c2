defmodule HalC2.Paths do
  @moduledoc """
  Where the node keeps its files, and path helpers that must agree across modules
  that guard the filesystem.

  The node sorts its files into four kinds (`features/node/platform/storage-layout.feature`):
  config (settings, keybindings, themes), data (what the user cannot get back),
  state (logs, the migration record) and cache (what can be downloaded again). Each
  kind is HAL-C2's directory for that kind plus an `elixir` level, so the node never
  collides with the TypeScript server that shares the root
  (`packages/shared/src/xdgDirs.ts` is the twin of `app_dirs/4`).

  The `:home` application env picks the layout:

  - `nil`: the XDG Base Directory layout, `~/.config/hal-c2/elixir` and so on.
  - `:dev`: the same layout in the development profile, `~/.config/hal-c2-dev/elixir`
    and so on, so a dev node never opens the installed app's files.
  - `{:root, dir}`: one HAL-C2 root, `<dir>/{config,data,state,cache}/elixir`
    (`HAL_C2_HOME`, a checkout's `.hal-c2`, the desktop app's home).
  - `{:node, dir}`: a root for the node alone, `<dir>/{config,data,state,cache}`
    (`HAL_C2_NODE_HOME`).
  - a directory: every kind in that one directory, the layout tests start nodes in.

  A root that is relative or names an old home (`~/.t3`, `~/.hal-c2`, or a directory
  inside one for `{:node, dir}`) is ignored: old homes are only ever read by
  `HalC2.Migration`.
  """

  @app "hal-c2"
  @dev_app "hal-c2-dev"
  @node "elixir"
  @kinds [:config, :data, :state, :cache]
  @legacy [".hal-c2", ".t3"]

  @doc "The node's settings, keybindings and themes."
  def config_dir, do: dirs().config
  @doc "The node's database, secrets, attachments, worktrees and other data it cannot get back."
  def data_dir, do: dirs().data
  @doc "The node's logs and the migration record."
  def state_dir, do: dirs().state
  @doc "The node's downloaded tools and other data it can fetch again."
  def cache_dir, do: dirs().cache

  @doc "The node's four directories under the configured `:home`, for this process."
  def dirs, do: node_dirs(Application.get_env(:hal_c2, :home), System.get_env(), user_home())

  @doc """
  Creates the node's directories that do not exist yet, and the data directory's
  `secrets`, readable only by the user.
  """
  def ensure!(dirs \\ dirs()) do
    for kind <- @kinds, do: mkdir_private!(Map.fetch!(dirs, kind))
    mkdir_private!(Path.join(dirs.data, "secrets"))
  end

  @doc """
  Creates `dir` and each missing parent with mode 0700, as the XDG specification asks.
  Directories that exist are left as they are.
  """
  def mkdir_private!(dir) do
    dir = Path.expand(dir)

    unless File.dir?(dir) do
      mkdir_private!(Path.dirname(dir))

      case File.mkdir(dir) do
        :ok -> File.chmod!(dir, 0o700)
        {:error, :eexist} -> :ok
        {:error, reason} -> raise File.Error, reason: reason, action: "make directory", path: dir
      end
    end

    :ok
  end

  @doc "The user's home directory: `HOME` when set, as the XDG specification reads it."
  def user_home, do: System.get_env("HOME") || System.user_home!()

  @doc "`:windows` or `:unix`, the path rules `node_dirs/4` and `app_dirs/4` follow."
  def platform, do: if(match?({:win32, _}, :os.type()), do: :windows, else: :unix)

  @doc """
  The node's directories for a `:home` spec (see the moduledoc), the environment
  variables `env` (a map), the user's home and the platform.
  """
  def node_dirs(spec, env, user_home, platform \\ platform())

  def node_dirs(dir, _env, _user_home, _platform) when is_binary(dir),
    do: Map.new(@kinds, &{&1, dir})

  def node_dirs({:node, dir}, env, user_home, platform) do
    if root?(dir, :node, user_home, platform),
      do: Map.new(@kinds, &{&1, join(platform, [dir, Atom.to_string(&1)])}),
      else: node_dirs(nil, env, user_home, platform)
  end

  def node_dirs(spec, env, user_home, platform) do
    app =
      case spec do
        {:root, dir} -> app_dirs(dir, env, user_home, platform)
        :dev -> app_dirs(nil, env, user_home, platform, @dev_app)
        nil -> app_dirs(nil, env, user_home, platform)
      end

    Map.new(@kinds, &{&1, join(platform, [Map.fetch!(app, &1), @node])})
  end

  @doc """
  HAL-C2's own directories, the ones every client and server shares:
  `%{config, data, state, cache, runtime}`. `root` puts them all under one directory;
  otherwise the XDG variables in `env` (only when absolute) and the platform
  defaults decide, with Windows under `APPDATA\\hal-c2\\config` and
  `LOCALAPPDATA\\hal-c2\\<kind>`; `app` swaps `hal-c2` for a profile such as
  `hal-c2-dev`. A root that is relative or an old home is ignored.
  """
  def app_dirs(root, env, user_home, platform \\ platform(), app \\ @app) do
    if root && root?(root, :root, user_home, platform) do
      state = join(platform, [root, "state"])

      %{
        config: join(platform, [root, "config"]),
        data: join(platform, [root, "data"]),
        state: state,
        cache: join(platform, [root, "cache"]),
        runtime: state
      }
    else
      xdg_dirs(env, user_home, platform, app)
    end
  end

  defp xdg_dirs(env, user_home, :windows, app) do
    app_data =
      absolute(env["APPDATA"], :windows) || join(:windows, [user_home, "AppData", "Roaming"])

    local =
      absolute(env["LOCALAPPDATA"], :windows) || join(:windows, [user_home, "AppData", "Local"])

    # Data, state and cache share one default base on Windows, so there the kind is nested
    # under the app dir. An XDG variable is a base for its kind alone and needs no nesting.
    kind = fn var, default, kind ->
      case absolute(env[var], :windows) do
        nil -> join(:windows, [default, app, kind])
        base -> join(:windows, [base, app])
      end
    end

    state = kind.("XDG_STATE_HOME", local, "state")

    %{
      config: kind.("XDG_CONFIG_HOME", app_data, "config"),
      data: kind.("XDG_DATA_HOME", local, "data"),
      state: state,
      cache: kind.("XDG_CACHE_HOME", local, "cache"),
      runtime: runtime(env, state, :windows, app)
    }
  end

  defp xdg_dirs(env, user_home, :unix, app) do
    kind = fn var, default ->
      join(:unix, [absolute(env[var], :unix) || join(:unix, [user_home | default]), app])
    end

    state = kind.("XDG_STATE_HOME", [".local", "state"])

    %{
      config: kind.("XDG_CONFIG_HOME", [".config"]),
      data: kind.("XDG_DATA_HOME", [".local", "share"]),
      state: state,
      cache: kind.("XDG_CACHE_HOME", [".cache"]),
      runtime: runtime(env, state, :unix, app)
    }
  end

  defp runtime(env, state, platform, app) do
    case absolute(env["XDG_RUNTIME_DIR"], platform) do
      nil -> state
      base -> join(platform, [base, app])
    end
  end

  @doc """
  The old homes the migration may copy from, most specific first: a `HAL_C2_HOME`
  that names an old home (services installed before wrote one), then `T3CODE_HOME`
  and `T3_HOME`, then `~/.hal-c2` and `~/.t3`. The caller keeps the first that exists.
  """
  def legacy_candidates(env, user_home, platform \\ platform()) do
    old_root =
      with root when root != nil <- absolute(env["HAL_C2_HOME"], platform),
           true <- legacy_home?(root, user_home, platform),
           do: root,
           else: (_ -> nil)

    named = [old_root, absolute(env["T3CODE_HOME"], platform), absolute(env["T3_HOME"], platform)]
    homes = for name <- @legacy, do: join(platform, [user_home, name])

    (Enum.reject(named, &is_nil/1) ++ homes)
    |> Enum.uniq_by(&normalize(&1, platform))
  end

  @doc "True when `dir` is `~/.hal-c2` or `~/.t3`: a migration source, never a root."
  def legacy_home?(dir, user_home, platform \\ platform()) do
    dir = normalize(dir, platform)
    Enum.any?(@legacy, &(normalize(join(platform, [user_home, &1]), platform) == dir))
  end

  @doc "A trimmed absolute path, or nil: the XDG specification ignores relative values."
  def absolute(nil, _platform), do: nil

  def absolute(value, platform) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      platform == :windows and value =~ ~r/^([A-Za-z]:)?[\\\/]/ -> value
      platform == :unix and String.starts_with?(value, "/") -> value
      true -> nil
    end
  end

  @doc """
  Whether `dir` may be a root of `kind` (`:root` for `HAL_C2_HOME`, `:node` for
  `HAL_C2_NODE_HOME`): absolute, and not an old home. A node root inside one is
  refused too, since a node home from before was `~/.t3/elixir` or `~/.hal-c2/elixir`.
  """
  def root?(dir, kind, user_home, platform \\ platform()) do
    case absolute(dir, platform) do
      nil ->
        false

      dir ->
        normalized = normalize(dir, platform)
        sep = if platform == :windows, do: "\\", else: "/"

        not Enum.any?(@legacy, fn name ->
          legacy = normalize(join(platform, [user_home, name]), platform)

          legacy == normalized or
            (kind == :node and String.starts_with?(normalized, legacy <> sep))
        end)
    end
  end

  defp join(:unix, parts), do: Path.join(parts)

  defp join(:windows, [first | rest]),
    do: Enum.reduce(rest, first, &(String.trim_trailing(&2, "\\") <> "\\" <> &1))

  defp normalize(dir, :unix), do: dir |> Path.expand() |> String.trim_trailing("/")

  defp normalize(dir, :windows),
    do: dir |> String.replace("/", "\\") |> String.trim_trailing("\\") |> String.downcase()

  @doc """
  The path with every symlink resolved, `{:ok, real}` when it exists, or
  `{:error, reason}`. For containment checks: compare real paths, never the
  requested ones.
  """
  def real(path), do: resolve(Path.split(Path.expand(path)), "/", 0)

  defp resolve(_parts, _acc, links) when links > 40, do: {:error, :eloop}

  defp resolve([], acc, _links) do
    if File.exists?(acc), do: {:ok, acc}, else: {:error, :enoent}
  end

  defp resolve(["/" | rest], acc, links), do: resolve(rest, acc, links)

  defp resolve([part | rest], acc, links) do
    next = Path.join(acc, part)

    case :file.read_link_all(next) do
      {:ok, target} ->
        resolve(Path.split(Path.expand(to_string(target), acc)) ++ rest, "/", links + 1)

      {:error, :einval} ->
        resolve(rest, next, links)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
