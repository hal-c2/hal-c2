defmodule HalC2.Test.Storage do
  @moduledoc """
  The scenario's user and their HAL-C2 directories, for
  `features/mc/platform/storage-layout.feature`, `storage-migration.feature` and
  the storage scenarios of `mc-startup.feature`.

  `user/2` makes the scenario's `/home/sam` (`HalC2.Test.Mc.Host`) the user's home
  and clears every XDG, HAL-C2 and old-home variable, so the MC resolves its
  directories as a release would for that user and never reaches the real user's
  files. `start/2` then starts the MC as a release (or a checkout) starts it,
  migrating on the way, and refuses to start if any directory it could write or
  read is outside the scenario.
  """

  import ExUnit.Assertions

  alias HalC2.Paths
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.{Host, World}

  @env ~w(XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR
          HAL_C2_HOME HAL_C2_MC_HOME HALC2_HOME T3CODE_HOME T3_HOME HAL_C2_NO_MIGRATE
          APPDATA LOCALAPPDATA)

  @doc """
  A `platform` ("Linux", "macOS" or "Windows") user with no XDG variables and no
  HAL-C2 home; idempotent. Captures the MC's log (info and up, from the test
  process, where the migration runs).
  """
  def user(context, platform \\ "Linux")
  def user(%{storage_user: _} = context, _platform), do: context

  def user(context, platform) do
    for name <- @env, do: World.put_os_env(name, nil)
    home = Host.home(context)
    World.put_app_env(:migrate, true)
    World.put_app_env(:home, Application.get_env(:hal_c2, :home))
    World.put_app_env(:service_user_home, home)

    World.put_app_env(
      :service_platform,
      if(platform == "macOS", do: {:unix, :darwin}, else: {:unix, :linux})
    )

    context = World.capture_log(context)
    log_info()
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({HalC2.Environment, :id}) end)
    mc = Map.merge(context.mc, %{spec: nil, migration: [copy_file: &copy/2]})
    Map.merge(context, %{storage_user: %{platform: platform, home: home}, mc: mc})
  end

  # Migration reports at info, below the test config's level: the scenario's log
  # takes info while the console stays at warning.
  defp log_info do
    %{level: primary} = :logger.get_primary_config()
    {:ok, %{level: console}} = :logger.get_handler_config(:default)
    :ok = :logger.update_handler_config(:default, :level, :warning)
    :ok = :logger.update_primary_config(%{level: :info})

    ExUnit.Callbacks.on_exit(fn ->
      :logger.update_primary_config(%{level: primary})
      :logger.update_handler_config(:default, :level, console)
    end)
  end

  @doc """
  Where a feature's path really is: `%APPDATA%` and `%LOCALAPPDATA%` are the
  Windows user's, a drive path stays as it is, the rest is `Host.path/2`.
  """
  def path(_context, "%APPDATA%" <> rest), do: "C:\\Users\\sam\\AppData\\Roaming" <> rest
  def path(_context, "%LOCALAPPDATA%" <> rest), do: "C:\\Users\\sam\\AppData\\Local" <> rest
  def path(_context, <<drive, ":\\", _::binary>> = path) when drive in ?A..?Z, do: path
  def path(context, path), do: Host.path(context, path)

  @doc """
  Where the MC keeps a feature's path in HAL-C2's own directories: the MC's
  files are under an `elixir` level in each kind (`HalC2.Paths`), so
  `~/.local/state/hal-c2/migrated-from.json` is the MC's
  `~/.local/state/hal-c2/elixir/migrated-from.json`.
  """
  def mc_path(context, feature_path) do
    real = path(context, feature_path)
    app = app_dirs()

    Enum.find_value([:config, :data, :state, :cache], real, fn kind ->
      base = Map.fetch!(app, kind)

      case Path.relative_to(real, base) do
        ^real -> nil
        "." -> nil
        "elixir" <> _ -> real
        rest -> Path.join([base, "elixir", rest])
      end
    end)
  end

  @doc "HAL-C2's own directories for the MC's current `:home` and environment."
  def app_dirs do
    env = System.get_env()

    case Application.get_env(:hal_c2, :home) do
      {:root, dir} -> Paths.app_dirs(dir, env, Paths.user_home())
      :dev -> Paths.app_dirs(nil, env, Paths.user_home(), Paths.platform(), "hal-c2-dev")
      _ -> Paths.app_dirs(nil, env, Paths.user_home())
    end
  end

  @doc "The `:hal_c2` config an MC boots with in `env` (`:dev` a checkout, `:prod` a release)."
  def boot_config(env, project_dir \\ project_dir()) do
    config = Path.join(project_dir, "config")
    base = Config.Reader.read!(Path.join(config, "config.exs"), env: env, target: :host)
    runtime = Config.Reader.read!(Path.join(config, "runtime.exs"), env: env, target: :host)
    Config.Reader.merge(base, runtime)[:hal_c2]
  end

  @doc "This app's directory (`apps/server-ex`)."
  def project_dir, do: Path.dirname(Mix.Project.project_file())

  @doc "The `:home` a release boots with in the current environment."
  def release_spec, do: boot_config(:prod)[:home]

  @doc """
  Starts the MC as `boot` (`:release`, or a `boot_config/2` keyword list) would
  start it, as the scenario's user: migrating if the build allows, then the MC's
  services. The scenario's files are snapshotted first (once) so steps can tell
  what the MC wrote.
  """
  def start(context, boot \\ :release) do
    context = user(context)
    boot = if boot == :release, do: boot_config(:prod), else: boot
    Application.put_env(:hal_c2, :migrate, Keyword.get(boot, :migrate, true))
    spec = boot[:home]
    guard!(context, spec)
    context = Map.put_new_lazy(context, :baseline, fn -> snapshot(fs(context)) end)
    Process.put({__MODULE__, :copies}, [])
    mc = Mc.restart(%{context.mc | spec: spec})
    %{context | mc: mc, clients: %{}}
  end

  @doc "`start/2` for an MC that has no data directory of its own yet."
  def first_start(context, boot \\ :release) do
    context = user(context)
    refute File.exists?(app_dirs().data), "HAL-C2 already has a data directory"
    start(context, boot)
  end

  @doc "Restarts the MC on the same `:home`; the copies list starts over."
  def restart(context) do
    Process.put({__MODULE__, :copies}, [])
    %{context | mc: Mc.restart(context.mc), clients: %{}}
  end

  # Every directory the MC may write to or migrate from is inside the scenario.
  defp guard!(context, spec) do
    fs = fs(context) <> "/"
    home = Paths.user_home()
    assert String.starts_with?(home, fs), "HOME is #{home}"
    env = System.get_env()

    for dir <- Map.values(Paths.mc_dirs(spec, env, home)) ++ Paths.legacy_candidates(env, home),
        do: assert(String.starts_with?(dir, fs), "#{dir} is outside the scenario")
  end

  @doc "The scenario's filesystem root (`/` of `Host.path/2`)."
  def fs(context), do: Path.join(context.mc.home, "fs")

  @doc "The migration's file copy: records each source, then copies."
  def copy(from, to) do
    Process.put({__MODULE__, :copies}, [from | Process.get({__MODULE__, :copies}, [])])
    File.copy!(from, to)
    :ok
  end

  @doc "Every file the migration copied since the MC last started, oldest first."
  def copies, do: Enum.reverse(Process.get({__MODULE__, :copies}, []))

  @doc """
  Every file and directory under `dir` as `relative path => {type, mode, sha256}`,
  without following links; unreadable files are `:unreadable`.
  """
  def snapshot(dir) do
    if File.dir?(dir), do: walk(dir, dir, %{}), else: %{}
  end

  defp walk(root, dir, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, acc, fn name, acc ->
          path = Path.join(dir, name)
          %File.Stat{type: type, mode: mode} = File.lstat!(path)
          rel = Path.relative_to(path, root)

          case type do
            :directory ->
              walk(root, path, Map.put(acc, rel, {:directory, mode}))

            :regular ->
              hash =
                case File.read(path) do
                  {:ok, bytes} -> :crypto.hash(:sha256, bytes)
                  {:error, _} -> :unreadable
                end

              Map.put(acc, rel, {:regular, mode, hash})

            other ->
              Map.put(acc, rel, {other, mode})
          end
        end)

      {:error, _} ->
        acc
    end
  end

  @doc "The part of the scenario's first snapshot under `real` (a path under the scenario)."
  def baseline(context, real) do
    prefix = Path.relative_to(real, fs(context))

    for {rel, entry} <- context[:baseline] || %{},
        rel == prefix or String.starts_with?(rel, prefix <> "/"),
        rel != prefix,
        into: %{},
        do: {Path.relative_to(rel, prefix), entry}
  end

  @doc """
  Runs `fun` against an MC with every file in `dir` (the layout tests use), as an
  old install or an already running HAL-C2 left it. The scenario's MC is stopped
  meanwhile and stays stopped; threads and projects `fun` makes stay known by title.
  """
  def seed_mc(context, dir, fun) do
    old_spec = Application.get_env(:hal_c2, :home)
    Mc.stop(context.mc)
    :persistent_term.erase({HalC2.Environment, :id})
    seeded = Mc.start(dir) |> Map.put(:home, context.mc.home)
    seed = fun.(%{context | mc: seeded, clients: %{}})
    Mc.stop(seeded)
    :persistent_term.erase({HalC2.Environment, :id})
    Application.put_env(:hal_c2, :home, old_spec)
    Map.merge(context, Map.take(seed, [:projects, :threads, :worktree, :fakes]))
  end

  @doc "Asserts `real` is as the scenario left it before the MC started (or absent)."
  def assert_untouched(context, real) do
    case context[:baseline] do
      nil ->
        refute File.exists?(real) and snapshot(real) != %{}, "#{real} was written to"

      baseline ->
        rel = Path.relative_to(real, fs(context))

        if Map.has_key?(baseline, rel),
          do: assert(snapshot(real) == baseline(context, real)),
          else: refute(File.exists?(real), "#{real} was created")
    end
  end

  @doc """
  Starts the MC from a checkout of this app (its config files, as a developer's
  checkout has them) under the user's home, as `mix hal_c2.server` starts it there:
  the main checkout (`:checkout`) or a linked worktree of it (`:worktree`).
  """
  def start_checkout(context, kind) do
    context = user(context)
    main = path(context, "~/code/hal-c2")

    checkout = if kind == :worktree, do: path(context, "~/code/hal-c2-feature"), else: main

    File.mkdir_p!(main)
    World.git!(main, ~w(init -q -b main))

    World.git!(
      main,
      ~w(-c user.email=dev@example.com -c user.name=Dev commit -q --allow-empty -m init)
    )

    if kind == :worktree,
      do: World.git!(main, ["worktree", "add", "-q", "-b", "feature", checkout])

    config = Path.join(checkout, "apps/server-ex/config")
    File.mkdir_p!(config)

    for file <- Path.wildcard(Path.join([project_dir(), "config", "*.exs"])),
        do: File.cp!(file, Path.join(config, Path.basename(file)))

    boot = boot_config(:dev, Path.dirname(config))
    context |> Map.put(:checkout, checkout) |> start(boot)
  end

  # --- background services ---------------------------------------------------------

  @doc """
  systemctl, loginctl and launchctl stand-ins on PATH (`fake_service_manager/1`).
  Returns their call log.
  """
  def service_manager(%{service_tools: log} = _context), do: log

  def service_manager(context) do
    bin = Mc.tmp_dir(context.mc, "service-bin")
    log = fake_service_manager(bin)
    World.put_os_env("PATH", bin <> ":" <> System.get_env("PATH"))
    log
  end

  @doc """
  Writes systemctl, loginctl and launchctl stand-ins into `bin` and returns the file
  they log each call that changes something to. Read-only questions (the user
  manager's environment, linger, is-enabled, is-active) are answered from state
  files beside them and not logged: `enabled`, `active` and `linger` follow what
  the service manager was asked to do, and `service_state/3` can set or clear
  them, or `no-user-manager` and `no-logind` to make those questions fail.
  """
  def fake_service_manager(bin) do
    log = Path.join(bin, "calls.log")

    File.write!(Path.join(bin, "systemctl"), """
    #!/bin/sh
    state="#{bin}"
    case "$2" in
      show-environment) [ -f "$state/no-user-manager" ] && exit 1; exit 0 ;;
      is-enabled) [ -f "$state/enabled" ] && { echo enabled; exit 0; }; echo disabled; exit 1 ;;
      is-active) [ -f "$state/active" ] && { echo active; exit 0; }; echo inactive; exit 3 ;;
    esac
    echo "systemctl $*" >> "#{log}"
    case "$2" in
      enable) touch "$state/enabled" ;;
      restart) touch "$state/active" ;;
      stop) rm -f "$state/active" ;;
      disable) rm -f "$state/enabled" "$state/active" ;;
    esac
    exit 0
    """)

    File.write!(Path.join(bin, "loginctl"), """
    #!/bin/sh
    state="#{bin}"
    case "$1" in
      show-user)
        [ -f "$state/no-logind" ] && exit 1
        [ -f "$state/linger" ] && echo yes || echo no
        exit 0 ;;
    esac
    echo "loginctl $*" >> "#{log}"
    case "$1" in
      enable-linger) touch "$state/linger" ;;
    esac
    exit 0
    """)

    File.write!(Path.join(bin, "launchctl"), """
    #!/bin/sh
    echo "launchctl $*" >> "#{log}"
    exit 0
    """)

    for tool <- ["systemctl", "loginctl", "launchctl"],
        do: File.chmod!(Path.join(bin, tool), 0o755)

    log
  end

  @doc "Sets (`true`) or clears a state file of the service manager stand-ins."
  def service_state(log, name, on?) do
    path = Path.join(Path.dirname(log), name)
    if on?, do: File.write!(path, ""), else: File.rm(path)
    log
  end

  @doc "What the service manager stand-ins were asked, one line each."
  def service_calls(log) do
    case File.read(log) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  @doc """
  Runs `hal-c2 service <command>` as the scenario's user would from an installed
  release: the unit goes under their home, and the MC resolves its directories
  from the environment. The output is `context.service_output`.
  """
  def service(context, command) do
    context = user(context)
    log = service_manager(context)
    {:ok, text} = as_release(fn -> HalC2.Service.command([command]) end)
    Map.merge(context, %{service_output: text, service_tools: log})
  end

  @doc "Runs `fun` with the MC's directories resolved as an installed release's."
  def as_release(fun) do
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, release_spec())

    try do
      fun.()
    after
      Application.put_env(:hal_c2, :home, previous)
    end
  end

  @doc "The unit a service is defined by, systemd's or launchd's, for `name`."
  def unit_path(context, :systemd, name),
    do: Host.path(context, "~/.config/systemd/user/#{name}")

  def unit_path(context, :launchd, label),
    do: Host.path(context, "~/Library/LaunchAgents/#{label}.plist")

  @doc "The environment a unit sets, as `[{name, value}]` (PATH left out)."
  def unit_env(text) do
    systemd =
      for [_, name, value] <- Regex.scan(~r/^Environment=([A-Z0-9_]+)=(.*)$/m, text),
          do: {name, String.trim(value, "\"")}

    launchd =
      for [_, name, value] <-
            Regex.scan(~r{<key>([A-Z0-9_]+)</key>\s*<string>([^<]*)</string>}, text),
          do: {name, value}

    Enum.reject(systemd ++ launchd, &(elem(&1, 0) == "PATH"))
  end
end
