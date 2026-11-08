defmodule HalC2.OpenShell.Install do
  @moduledoc """
  Installs, updates, rotates and removes the OpenShell gateway this MC runs, or
  points the MC at one the user already runs (`reuse/2`).
  `hal-c2-service openshell ...` and `mix hal_c2.openshell ...` drive it
  (`HalC2.OpenShell.Command`).

  Everything new is staged before the running gateway is touched. The archive is
  fetched, or read from `:archive` on a machine without egress, and must match
  `HalC2.OpenShell.Manifest`'s SHA-256. It must hold the gateway binary and
  nothing else. A fresh install's certificates are issued, and the new
  configuration must pass the gateway's own preflight. Only then does the old
  gateway stop. Its database, certificates, configuration and unit are copied to
  `backups/<version>/`, and the new gateway starts and must pass `smoke/2`. If it
  does not, the backup goes back, the old gateway starts again, and the error
  says why.

  Updating or rotating refuses while this MC's sandboxes exist, since their
  gateway is about to stop (`drain: true` deletes them first), and while they
  cannot be counted on a gateway that still listens (`force: true` goes ahead).
  A gateway run as a service must stop before anything of it is copied or
  replaced. One the dev run started is that shell's process, which the MC cannot
  stop: nothing changes under it while it listens. Reuse and uninstall never
  touch a sandbox this MC did not label.
  """

  require Logger

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Client
  alias HalC2.OpenShell.Config
  alias HalC2.OpenShell.Manifest
  alias HalC2.OpenShell.Platform
  alias HalC2.OpenShell.Service

  # How long a gateway that was just (re)started has to answer.
  @start_timeout 30_000
  # How long the isolation check's sandbox has to become ready: the first one
  # pulls the pinned images.
  @sandbox_timeout 300_000
  @archive_limit 512 * 1024 * 1024

  # --- install and update -----------------------------------------------------------

  @doc """
  Installs the pinned gateway, or updates or repairs the one installed, and
  returns `{:ok, state}` (`HalC2.OpenShell.state/0`) or `{:error, message}`.
  Options: `:archive` (a local copy of the pinned archive), `:drain`, `:force`, and
  `service: false`, which stages everything but leaves starting the gateway to
  `foreground_command/0` (the dev run, `mise run openshell`).
  """
  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  def install(opts \\ []) do
    previous = OpenShell.state()
    mode = if Keyword.get(opts, :service, true), do: "managed", else: "foreground"

    with :ok <- not_external(previous),
         :ok <- Service.owned(),
         :ok <- Service.moved(previous),
         :ok <- foreground_stopped(previous),
         {:ok, platform} <- platform(),
         {:ok, release} <- release(platform.target, opts) do
      staging(fn staging ->
        state = %{
          "mode" => mode,
          "version" => release.version,
          "port" => (previous && previous["port"]) || free_port(),
          "driver" => platform.driver,
          "socket" => platform.socket,
          "previous" => previous && previous["version"],
          "instance" => OpenShell.instance()
        }

        state = Map.put(state, "endpoint", "https://127.0.0.1:#{state["port"]}")
        config = Path.join(staging, "gateway.toml")

        with :ok <- stage_release(release, staging, opts),
             :ok <- ensure_pki(state["version"]),
             :ok <- File.write(config, Config.render(atomize(state))),
             :ok <- preflight(state["version"], config),
             :ok <- drained(previous, opts) do
          switch(previous, state, opts, fn -> File.cp(config, OpenShell.config_path()) end)
        end
      end)
    end
  end

  @doc """
  Issues new certificates and restarts the gateway on them, which closes every
  connection made with the old ones. A dev run's gateway must be stopped first,
  and uses them once started again. Options: `:drain`, `:force`.
  """
  def rotate(opts \\ []) do
    case OpenShell.state() do
      %{"mode" => mode} = state when mode in ["managed", "foreground"] ->
        staging(fn staging ->
          pki = Path.join(staging, "pki")

          with :ok <- Service.owned(),
               :ok <- Service.moved(state),
               :ok <- foreground_stopped(state),
               :ok <- issue(state["version"], pki),
               :ok <- drained(state, opts) do
            rotated = Map.put(state, "instance", OpenShell.instance())
            switch(state, rotated, opts, fn -> replace_dir(pki, OpenShell.pki_dir()) end)
          end
        end)

      %{"mode" => "external"} ->
        {:error,
         "[external] This MC uses a gateway it does not run; rotate its certificates there."}

      nil ->
        {:error, not_installed()}
    end
  end

  # Stops `previous`, backs it up, applies `prepare`, starts `state` and checks it;
  # puts the backup back if any of that fails.
  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  defp switch(previous, state, opts, prepare) do
    with {:ok, backup} <- stop_and_backup(previous) do
      result =
        with :ok <- prepare.(),
             :ok <- File.chmod(OpenShell.config_path(), 0o600),
             :ok <- start(state, opts) do
          :ok
        end

      # A gateway that no longer runs as a service must not start again at login.
      result =
        if result == :ok and match?(%{"mode" => "managed"}, previous) and
             state["mode"] != "managed",
           do: Service.uninstall(),
           else: result

      case result do
        :ok ->
          OpenShell.put_state(state)
          prune(state)
          {:ok, state}

        {:error, reason} ->
          {:error, rollback(previous, state, backup, opts, message(reason))}
      end
    end
  end

  # Stops `previous` and copies what it runs on (nil: nothing of it to keep). Its
  # database is only copied, or written over, once it has stopped.
  defp stop_and_backup(%{"mode" => "managed"} = previous) do
    with :ok <- service_stopped(), do: {:ok, backup(previous)}
  end

  defp stop_and_backup(%{"mode" => "foreground"} = previous) do
    with :ok <- foreground_stopped(previous), do: {:ok, backup(previous)}
  end

  defp stop_and_backup(_previous), do: {:ok, nil}

  # The gateway's service stops before any of its files change.
  defp service_stopped do
    case Service.stop() do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         "[gateway-stop-failed] The gateway did not stop, so nothing was changed: #{message(reason)}"}
    end
  end

  # Undoes a `switch/4` to `state` that failed, back to `previous` and its backup.
  # A new gateway that will not stop keeps its files: nothing goes back under it.
  defp rollback(previous, state, backup, opts, reason) do
    stopped = if state["mode"] == "managed", do: Service.stop(), else: :ok

    case stopped do
      :ok ->
        put_back(previous, state, backup, opts, reason)

      {:error, stop} ->
        kept = if backup, do: " The previous gateway's backup is in #{backup}.", else: ""

        "#{reason} Stopping the new gateway failed too, so nothing was put back: #{message(stop)}.#{kept}"
    end
  end

  defp put_back(previous, state, backup, opts, reason) do
    managed = state["mode"] == "managed"

    if backup do
      restore(backup)
      if managed and previous["mode"] != "managed", do: Service.uninstall()

      case start(previous, opts) do
        :ok ->
          "#{reason} The previous gateway (#{previous["version"]}) is back in place."

        {:error, again} ->
          "#{reason} Restoring the previous gateway (#{previous["version"]}) failed too: #{message(again)} Its backup is in #{backup}."
      end
    else
      if managed, do: Service.uninstall()
      # The failed gateway may have created its database; the next install starts clean.
      for {"openshell.db" <> _, path} <- backup_files(), do: File.rm_rf!(path)
      "#{reason} Nothing was installed. The gateway's log: #{OpenShell.log_path()}"
    end
  end

  # An update or rotation of a gateway this MC runs is not rolled back for who else
  # uses it; `status` and `check` report that. The gateway started is checked for
  # the version it was started at: the one going back after a failed update is the
  # previous one.
  defp smoke_fun(opts),
    do: Keyword.get(opts, :smoke, &smoke(&1, shared: false, version: &1["version"]))

  # A foreground gateway is started, and checked, by whoever runs it.
  defp start(%{"mode" => "foreground"}, _opts), do: :ok

  defp start(state, opts) do
    with :ok <- Service.install(state), do: smoke_fun(opts).(state)
  end

  @doc """
  The gateway `install(service: false)` staged, as one `exec` line for a POSIX
  shell: the dev run executes it, so the gateway is the shell's own process and
  stops with it.
  """
  def foreground_command do
    case OpenShell.state() do
      %{"mode" => "foreground", "version" => version} ->
        argv = Config.command(OpenShell.gateway_bin(version))

        {:ok,
         "cd #{shell_quote(OpenShell.root())} && exec #{Enum.map_join(argv, " ", &shell_quote/1)}"}

      %{"mode" => mode} ->
        {:error,
         "[#{mode}] This MC's OpenShell runs as a #{mode} gateway, not in the foreground."}

      nil ->
        {:error, not_installed()}
    end
  end

  defp not_external(%{"mode" => "external", "endpoint" => endpoint}),
    do:
      {:error,
       "[external] This MC uses the gateway at #{endpoint}. Run `hal-c2-service openshell uninstall` first to install one of its own."}

  defp not_external(_), do: :ok

  defp platform do
    case Platform.check(Platform.facts()) do
      {:ok, platform} -> {:ok, platform}
      {:error, problems} -> {:error, Enum.map_join(problems, "\n", &problem_line/1)}
    end
  end

  defp problem_line(code), do: "[#{code}] #{Platform.problem_message(code)}"

  # The archive to install. `:release` replaces the manifest's, for tests only.
  defp release(target, opts) do
    case Keyword.get(opts, :release) || Manifest.gateway(target) do
      nil ->
        {:error, problem_line("unsupported-arch")}

      artifact ->
        {:ok, Map.put_new(artifact, :version, Manifest.version())}
    end
  end

  # --- the archive ------------------------------------------------------------------

  # Fetches (or copies) the archive, checks its hash, and unpacks the one binary in
  # it into `releases/<version>/`.
  defp stage_release(release, staging, opts) do
    archive = Path.join(staging, release.name)

    with :ok <- fetch(release, archive, opts[:archive]),
         :ok <- verify(archive, release.sha256),
         {:ok, bin} <- extract(archive, Path.join(staging, "release")) do
      dir = OpenShell.release_dir(release.version)
      HalC2.Paths.mkdir_private!(Path.dirname(dir))
      replace_dir(Path.dirname(bin), dir)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp fetch(_release, archive, local) when is_binary(local) do
    case File.cp(local, archive) do
      :ok -> :ok
      {:error, reason} -> {:error, "Cannot read #{local}: #{:file.format_error(reason)}"}
    end
  end

  defp fetch(release, archive, nil) do
    Logger.info("openshell: downloading #{release.url}")

    case :httpc.request(
           :get,
           {to_charlist(release.url), []},
           [
             timeout: 600_000,
             connect_timeout: 15_000,
             autoredirect: true,
             ssl: :httpc.ssl_verify_host_options(true)
           ],
           stream: to_charlist(archive)
         ) do
      {:ok, :saved_to_file} ->
        :ok

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "Downloading #{release.url} failed: HTTP #{status}.#{offline_hint()}"}

      {:error, reason} ->
        {:error, "Downloading #{release.url} failed: #{inspect(reason)}.#{offline_hint()}"}
    end
  end

  defp offline_hint,
    do:
      " Without network access, download it elsewhere and pass it with `--archive <file>`; it is checked against the same hash."

  @doc false
  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  def verify(path, sha256) do
    actual =
      path
      |> File.stream!(1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == sha256,
      do: :ok,
      else:
        {:error,
         "[hash-mismatch] #{Path.basename(path)} has SHA-256 #{actual}, not the pinned #{sha256}. It was not installed."}
  end

  @doc false
  # Unpacks `archive` into `dir` if it holds exactly one regular file,
  # `openshell-gateway`, and returns its path. Anything else (another entry, a
  # link, a path that leaves `dir`) refuses the whole archive.
  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  def extract(archive, dir) do
    with {:ok, entries} <- :erl_tar.table(to_charlist(archive), [:compressed, :verbose]),
         [{name, :regular, size, _mtime, _mode, _uid, _gid}] when size <= @archive_limit <-
           entries,
         ~c"openshell-gateway" <-
           name |> to_string() |> String.trim_leading("./") |> to_charlist(),
         _ <- HalC2.Paths.mkdir_private!(dir),
         :ok <-
           :erl_tar.extract(to_charlist(archive), [
             :compressed,
             cwd: to_charlist(dir),
             files: [name]
           ]),
         bin = Path.join(dir, "openshell-gateway"),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(bin),
         :ok <- File.chmod(bin, 0o755) do
      {:ok, bin}
    else
      _ ->
        {:error,
         "[bad-archive] #{Path.basename(archive)} is not the gateway archive this MC expects."}
    end
  end

  # --- certificates and configuration -----------------------------------------------

  defp ensure_pki(version) do
    if File.regular?(Path.join([OpenShell.pki_dir(), "client", "tls.key"])) and
         File.regular?(OpenShell.client_ca_path()) do
      :ok
    else
      HalC2.Paths.mkdir_private!(OpenShell.root())
      tmp = OpenShell.pki_dir() <> ".new"
      File.rm_rf!(tmp)

      case issue(version, tmp) do
        :ok ->
          replace_dir(tmp, OpenShell.pki_dir())

        error ->
          # A refused issue must not leave a CA's key behind.
          File.rm_rf!(tmp)
          error
      end
    end
  end

  # The gateway's `generate-certs` issues a CA, the gateway's certificate, a client
  # certificate and the sandbox token key into `dir`. It signs the client
  # certificate with the CA that signed its own, and the gateway trusts whatever
  # that CA signed, so the MC's client certificate comes from a second run: a CA of
  # its own, which signs nothing else (`client_authority/2`). Every key is made
  # owner-only and both CAs' keys deleted, so no further identity can be issued.
  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  defp issue(version, dir) do
    with :ok <- gateway(version, ["generate-certs", "--output-dir", dir]),
         :ok <- client_authority(version, dir) do
      File.rm!(Path.join(dir, "ca.key"))

      for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true) do
        cond do
          File.dir?(path) -> File.chmod!(path, 0o700)
          String.ends_with?(path, [".key", ".pem"]) -> File.chmod!(path, 0o600)
          true -> File.chmod!(path, 0o644)
        end
      end

      File.chmod!(dir, 0o700)

      missing =
        Enum.reject(
          [
            "ca.crt",
            "client-ca.crt",
            "server/tls.crt",
            "server/tls.key",
            "client/tls.crt",
            "client/tls.key"
          ] ++ ["jwt/signing.pem", "jwt/public.pem", "jwt/kid"],
          &File.regular?(Path.join(dir, &1))
        )

      if missing == [],
        do: :ok,
        else: {:error, "The gateway did not issue #{Enum.join(missing, ", ")}."}
    end
  end

  # Replaces the client certificate in `dir` with one from a CA of its own, and
  # keeps that CA's certificate as `client-ca.crt`. Everything else the second run
  # issues, its CA's key included, is deleted.
  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  defp client_authority(version, dir) do
    tmp = dir <> ".client"
    File.rm_rf!(tmp)

    try do
      with :ok <- gateway(version, ["generate-certs", "--output-dir", tmp]),
           :ok <- File.rename(Path.join(tmp, "ca.crt"), Path.join(dir, "client-ca.crt")),
           _ <- File.rm_rf!(Path.join(dir, "client")),
           :ok <- File.rename(Path.join(tmp, "client"), Path.join(dir, "client")) do
        :ok
      else
        {:error, reason} when is_atom(reason) ->
          {:error, "Keeping the MC's client certificate failed: #{:file.format_error(reason)}."}

        error ->
          error
      end
    after
      File.rm_rf!(tmp)
    end
  end

  defp preflight(version, config),
    do: gateway(version, ["config", "preflight", "--", "--config", config, "--db-url", db_url()])

  defp db_url, do: Config.args() |> List.last()

  # Runs the installed gateway binary for a one-off command, in the environment
  # the service gives it.
  # Runs the binary this MC verified and unpacked itself.
  # sobelow_skip ["CI.System"]
  defp gateway(version, args) do
    [env | argv] = Config.command(OpenShell.gateway_bin(version), args)
    HalC2.Paths.mkdir_private!(Path.dirname(OpenShell.db_path()))

    case System.cmd(env, argv,
           cd: OpenShell.root(),
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {out, status} ->
        {:error,
         "`openshell-gateway #{Enum.join(Enum.take(args, 2), " ")}` failed (#{status}): #{String.trim(out)}"}
    end
  end

  defp atomize(state),
    do: %{port: state["port"], driver: state["driver"], socket: state["socket"]}

  @doc false
  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # --- backup and rollback ----------------------------------------------------------

  # Stops the gateway and copies what it runs on. The database is copied with the
  # gateway stopped, so its files are consistent.
  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  defp backup(state) do
    dir = OpenShell.backup_dir(state["version"])
    File.rm_rf!(dir)
    HalC2.Paths.mkdir_private!(dir)

    for {name, from} <- backup_files(), File.exists?(from) do
      File.cp_r!(from, Path.join(dir, name))
    end

    dir
  end

  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  defp restore(dir) do
    for {name, to} <- backup_files() do
      from = Path.join(dir, name)
      File.rm_rf!(to)
      if File.exists?(from), do: File.cp_r!(from, to)
    end

    :ok
  end

  defp backup_files do
    db = OpenShell.db_path()

    [
      {"pki", OpenShell.pki_dir()},
      {"gateway.toml", OpenShell.config_path()},
      {"installed.json", OpenShell.state_path()},
      {"openshell.db", db},
      {"openshell.db-wal", db <> "-wal"},
      {"openshell.db-shm", db <> "-shm"}
    ]
  end

  # Keeps the running release and the one before it, and the backup to go back to.
  defp prune(state) do
    keep = Enum.reject([state["version"], state["previous"]], &is_nil/1)

    for kind <- ["releases", "backups"],
        dir <- Path.wildcard(Path.join([OpenShell.root(), kind, "*"])),
        Path.basename(dir) not in keep,
        do: File.rm_rf!(dir)

    :ok
  end

  # --- draining ---------------------------------------------------------------------

  # A gateway with this MC's sandboxes on it is not stopped unless they go first.
  # One with nothing on its port runs none. One that listens but whose sandboxes
  # cannot be listed is taken to have some, unless the user says `force: true`.
  defp drained(%{"mode" => mode} = previous, opts) when mode in ["managed", "foreground"] do
    if listening?(previous) do
      case Client.connect_unchecked() do
        {:ok, conn} ->
          try do
            conn |> Client.list_sandboxes(%{}, timeout: 5_000) |> drain(conn, opts)
          after
            Client.disconnect(conn)
          end

        error ->
          drain(error, nil, opts)
      end
    else
      :ok
    end
  end

  defp drained(_previous, _opts), do: :ok

  defp drain({:ok, []}, _conn, _opts), do: :ok

  # The isolation check's sandboxes run no review: they go without a drain.
  defp drain({:ok, sandboxes}, conn, opts) do
    {probes, sandboxes} = Enum.split_with(sandboxes, &probe?/1)

    with :ok <- delete_probes(conn, probes), do: drain_reviews(sandboxes, conn, opts)
  end

  defp drain({:error, reason}, _conn, opts) do
    if opts[:force],
      do: :ok,
      else:
        {:error,
         "[sandboxes-unknown] The gateway is listening, but this MC's sandboxes on it could not be listed (#{message(reason)}). Stopping it would end any that run. Try again once it answers, or pass --force to go ahead."}
  end

  defp drain_reviews([], _conn, _opts), do: :ok

  defp drain_reviews(sandboxes, conn, opts) do
    if opts[:drain],
      do: delete_all(conn, sandboxes),
      else:
        {:error,
         "[sandboxes-running] #{length(sandboxes)} of this MC's sandboxes are on the gateway. Let their reviews finish, or pass --drain to delete them."}
  end

  # The dev run's gateway is that shell's own process, which the MC cannot stop or
  # restart; nothing changes under it while it listens.
  defp foreground_stopped(%{"mode" => "foreground"} = state) do
    if listening?(state),
      do:
        {:error,
         "[gateway-running] The dev gateway is still running on port #{state["port"]}. Stop it (end `mise run openshell`), run this again, then start it again."},
      else: :ok
  end

  defp foreground_stopped(_state), do: :ok

  # Whether anything takes connections on the port of a gateway this MC runs. Only
  # a refusal says nothing does.
  defp listening?(%{"port" => port}) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, :econnrefused} ->
        false

      {:error, _} ->
        true
    end
  end

  defp delete_all(conn, sandboxes) do
    Enum.reduce_while(sandboxes, :ok, fn %{name: name}, :ok ->
      case Client.delete_sandbox(conn, name) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "Deleting sandbox #{name} failed: #{message(reason)}"}}
      end
    end)
  end

  # --- the smoke test ---------------------------------------------------------------

  @doc """
  Checks the gateway `state` names is the one this MC can trust, and returns `:ok`
  or `{:error, message}`:

    * it answers over mTLS with the credentials `state` names, healthy, at the
      pinned version (`version:` names another, as for the previous gateway a
      failed update puts back), with the expected driver
    * it takes the MC's certificate for a user that is not an operator
    * it refuses a caller with no certificate, and refuses plaintext
    * the `hal-c2` workspace exists
    * no other HAL-C2 environment has sandboxes on it (`shared: false` skips this,
      for the check after an install or update of a gateway this MC runs)
    * a workload in a fresh sandbox can reach neither the gateway nor the runtime
      socket (`isolation: false` skips this, for a gateway with no runtime yet)
  """
  def smoke(state, opts \\ []) do
    wait = if state["mode"] == "managed", do: @start_timeout, else: 0
    credentials = OpenShell.credentials(state)
    version = Keyword.get(opts, :version, Manifest.version())

    with {:ok, conn} <- connect_when_up(state["endpoint"], credentials, wait) do
      try do
        with :ok <- check_gateway(conn, state, version),
             :ok <- check_refusals(state["endpoint"], credentials[:ca]),
             :ok <- Client.ensure_workspace(conn) |> labelled("workspace"),
             :ok <- if(Keyword.get(opts, :shared, true), do: check_not_shared(conn), else: :ok),
             :ok <-
               if(Keyword.get(opts, :isolation, true),
                 do: check_isolation(conn, state),
                 else: :ok
               ) do
          :ok
        end
      after
        Client.disconnect(conn)
      end
    end
  end

  # A gateway that was just started takes a moment to listen; it gets until
  # `deadline` to answer its health check.
  defp connect_when_up(endpoint, credentials, wait),
    do: await_up(endpoint, credentials, System.monotonic_time(:millisecond) + wait)

  defp await_up(endpoint, credentials, deadline) do
    result =
      with {:ok, conn} <- Client.connect(endpoint, credentials) do
        case Client.health(conn, timeout: 3_000) do
          {:ok, _} ->
            {:ok, conn}

          error ->
            Client.disconnect(conn)
            error
        end
      end

    case result do
      {:ok, conn} ->
        {:ok, conn}

      error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(500)
          await_up(endpoint, credentials, deadline)
        else
          {:error,
           "[gateway-unreachable] The gateway did not answer: #{message(error)}. Its log: #{OpenShell.log_path()}"}
        end
    end
  end

  defp check_gateway(conn, state, version) do
    with {:ok, health} <- Client.health(conn) |> labelled("health"),
         {:ok, info} <- Client.gateway_info(conn) |> labelled("gateway info"),
         {:ok, user} <- Client.current_user(conn) |> labelled("identity") do
      cond do
        health.status != :healthy ->
          {:error, "[gateway-unhealthy] The gateway reports #{health.status}."}

        health.version != version ->
          {:error,
           "[version-mismatch] The gateway is #{health.version}; this MC needs #{version}."}

        state["driver"] != nil and state["driver"] not in info.drivers ->
          {:error,
           "[driver-mismatch] The gateway runs #{Enum.join(info.drivers, ", ")}, not #{state["driver"]}."}

        info.drivers == [] ->
          {:error, "[driver-mismatch] The gateway has no compute driver."}

        Enum.any?(user.roles, &String.contains?(String.downcase(&1), ["operator", "admin"])) ->
          {:error,
           "[operator-identity] The gateway takes this MC's certificate for an operator (#{Enum.join(user.roles, ", ")}); it must be an ordinary user."}

        true ->
          :ok
      end
    end
  end

  # Before the isolation check, which would put a sandbox on the gateway.
  defp check_not_shared(conn) do
    case Client.other_environments(conn) do
      {:ok, []} -> :ok
      {:ok, others} -> {:error, shared_message(others)}
      error -> labelled(error, "sandbox listing")
    end
  end

  @doc false
  def shared_message(others) do
    "[shared-gateway] #{length(others)} other HAL-C2 environment(s) have sandboxes on this gateway. " <>
      "OpenShell 0.1.7 does not keep one identity's sandboxes from another's, so HAL-C2 does not share a gateway: " <>
      "it makes no sandboxes on this one. Give each environment a gateway of its own " <>
      "(`hal-c2-service openshell install`); the other environment's sandboxes are left alone."
  end

  defp check_refusals(endpoint, ca) do
    anonymous =
      case Client.connect(endpoint, ca: ca, anonymous: true) do
        {:ok, conn} ->
          try do
            Client.current_user(conn, timeout: 5_000)
          after
            Client.disconnect(conn)
          end

        error ->
          error
      end

    cond do
      match?({:ok, _}, anonymous) ->
        {:error, "[anonymous-accepted] The gateway answers a caller with no certificate."}

      plaintext_answers?(endpoint) ->
        {:error, "[plaintext-accepted] The gateway answers without TLS."}

      true ->
        :ok
    end
  end

  # Whether the gateway answers an unencrypted gRPC health check (HTTP/2 with
  # prior knowledge). Any failure to get a successful answer is a refusal.
  @doc false
  def plaintext_answers?(endpoint) do
    {:ok, host, port} = Client.parse_endpoint(endpoint)
    body = [0, <<0::32>>]

    headers = [
      {"content-type", "application/grpc"},
      {"te", "trailers"}
    ]

    with {:ok, conn} <-
           Mint.HTTP2.connect(:http, host, port, mode: :passive, transport_opts: [timeout: 3_000]),
         {:ok, conn, ref} <-
           Mint.HTTP2.request(conn, "POST", "/openshell.v1.OpenShell/Health", headers, :stream),
         {:ok, conn} <- Mint.HTTP2.stream_request_body(conn, ref, body),
         {:ok, conn} <- Mint.HTTP2.stream_request_body(conn, ref, :eof) do
      answer = read_answer(conn, ref, [], 0)
      Mint.HTTP2.close(conn)
      answer
    else
      {:error, %Mint.HTTP2{} = conn, _reason} ->
        Mint.HTTP2.close(conn)
        false

      _ ->
        false
    end
  end

  defp read_answer(_conn, _ref, _acc, reads) when reads > 10, do: false

  defp read_answer(conn, ref, acc, reads) do
    case Mint.HTTP2.recv(conn, 0, 3_000) do
      {:ok, conn, responses} ->
        acc = acc ++ responses

        if Enum.any?(acc, &match?({:done, ^ref}, &1)) do
          ok_status = Enum.any?(acc, &match?({:status, ^ref, 200}, &1))

          grpc_status =
            Enum.find_value(acc, "0", fn
              {kind, ^ref, headers} when kind in [:headers] ->
                List.keyfind(headers, "grpc-status", 0) |> then(&(&1 && elem(&1, 1)))

              _ ->
                nil
            end)

          ok_status and grpc_status == "0" and Enum.any?(acc, &match?({:data, ^ref, _}, &1))
        else
          read_answer(conn, ref, acc, reads + 1)
        end

      _ ->
        false
    end
  end

  # A workload in a fresh sandbox tries the runtime's sockets and the gateway's
  # port on every address a container could reach it by, and reports what it
  # reached. The sandbox is deleted whatever the outcome, and the check passes only
  # once it is gone. Sandboxes an earlier check left go first.
  defp check_isolation(conn, state) do
    name = "halc2-smoke-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    with :ok <- clear_probes(conn) do
      result =
        try do
          probe_isolation(conn, name, state)
        catch
          kind, reason ->
            remove_probe(conn, name)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      case {result, remove_probe(conn, name)} do
        {result, :ok} -> result
        {:ok, {:error, cleanup}} -> {:error, cleanup}
        {{:error, reason}, {:error, cleanup}} -> {:error, "#{message(reason)} #{cleanup}"}
      end
    end
  end

  defp probe_isolation(conn, name, state) do
    with {:ok, _} <-
           Client.create_sandbox(conn, name, labels: probe_labels())
           |> labelled("creating a sandbox"),
         :ok <- await_ready(conn, name, System.monotonic_time(:millisecond) + @sandbox_timeout),
         {:ok, exec} <-
           Client.exec(conn, name, isolation_probe(state))
           |> labelled("isolation check") do
      case collect(exec, [], 60_000) do
        {:exit, 0, _out} ->
          :ok

        {:exit, _code, out} ->
          {:error,
           "[sandbox-not-isolated] A sandbox workload reached what it must not: #{String.trim(out)}"}

        {:error, reason} ->
          {:error, "[isolation-check-failed] #{message(reason)}"}
      end
    end
  end

  @doc false
  # The label the isolation check's sandboxes carry, beside the owner label. They
  # run no review, so an update or uninstall deletes them without a drain.
  def probe_labels, do: %{"halc2.github.io/purpose" => "openshell-check"}

  defp probe?(%{labels: labels}),
    do: Enum.all?(probe_labels(), fn {k, v} -> labels[k] == v end)

  # Deletes the sandboxes earlier isolation checks left, as when deleting one failed
  # or the MC stopped during a check.
  defp clear_probes(conn) do
    case Client.list_sandboxes(conn, probe_labels(), timeout: 5_000) do
      {:ok, probes} -> delete_probes(conn, probes)
      error -> labelled(error, "listing earlier checks' sandboxes")
    end
  end

  defp delete_probes(conn, probes) do
    Enum.reduce_while(probes, :ok, fn %{name: name}, :ok ->
      case remove_probe(conn, name) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp remove_probe(conn, name) do
    case Client.delete_sandbox(conn, name) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         "[probe-cleanup-failed] The isolation check's sandbox #{name} could not be deleted (#{message(reason)}), so the check did not pass. The next check deletes it first."}
    end
  end

  # $1 is the port; the sockets follow, then `--` and the hosts.
  @isolation_script """
  found=0
  port=$1
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    if [ -e "$1" ]; then echo "socket $1"; found=1; fi
    shift
  done
  [ "$#" -gt 0 ] && shift
  for h in "$@"; do
    if timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$h" "$port" 2>/dev/null; then
      echo "gateway via $h"
      found=1
    fi
  done
  exit $found
  """

  @doc """
  The command the isolation check runs in its sandbox: one fixed script, with the
  gateway's port, the runtime sockets and the names the gateway may answer on as
  its arguments, so no value from the state is read as shell. The names are the
  host's own and its container aliases (`host.openshell.internal` is OpenShell's),
  and the endpoint's host, which may be a name or address only a sandbox resolves.
  """
  def isolation_probe(state) do
    {:ok, host, endpoint_port} = Client.parse_endpoint(state["endpoint"])
    port = state["port"] || endpoint_port

    sockets =
      Enum.uniq(
        Enum.reject(
          [
            state["socket"],
            "/run/podman/podman.sock",
            "/var/run/docker.sock",
            "/run/docker.sock"
          ],
          &is_nil/1
        )
      )

    hosts =
      Enum.uniq([
        "127.0.0.1",
        "host.containers.internal",
        "host.docker.internal",
        "host.openshell.internal",
        host
      ])

    ["bash", "-c", @isolation_script, "isolation-probe", to_string(port)] ++
      sockets ++ ["--"] ++ hosts
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp await_ready(conn, name, deadline) do
    case Client.get_sandbox(conn, name) do
      {:ok, %{phase: :ready}} ->
        :ok

      {:ok, %{phase: phase}} when phase in [:error, :completed, :stopped, :deleting] ->
        {:error,
         "[sandbox-unavailable] The isolation check's sandbox went #{phase}. If this machine cannot reach the image registries, see the OpenShell section of the user guide."}

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1_000)
          await_ready(conn, name, deadline)
        else
          {:error, "[sandbox-unavailable] The isolation check's sandbox did not become ready."}
        end
    end
  end

  defp collect(exec, out, timeout) do
    receive do
      {:openshell_exec, ^exec, {stream, data}} when stream in [:stdout, :stderr] ->
        collect(exec, [out, data], timeout)

      {:openshell_exec, ^exec, {:exit, code}} ->
        {:exit, code, IO.iodata_to_binary(out)}

      {:openshell_exec, ^exec, {:error, reason}} ->
        {:error, reason}
    after
      timeout ->
        HalC2.OpenShell.Exec.cancel(exec)
        {:error, :timeout}
    end
  end

  defp labelled(:ok, _what), do: :ok
  defp labelled({:ok, value}, _what), do: {:ok, value}

  defp labelled({:error, reason}, what),
    do: {:error, "The gateway's #{what} failed: #{message(reason)}"}

  # --- reuse ------------------------------------------------------------------------

  @doc """
  Uses the gateway at `endpoint` (`https://host:port`), which the user runs, with
  the CA certificate and client certificate and key at `ca:`, `cert:` and `key:`.
  The credentials are copied in, owner-only. The gateway must pass `smoke/2` before
  the MC records it, and must hold no other HAL-C2 environment's sandboxes: two
  environments on one gateway would see each other's (`HalC2.OpenShell`). The MC
  will not start, stop or update it. A gateway that is refused leaves what the MC
  used before as it was.
  """
  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  def reuse(endpoint, credentials) do
    with :ok <- not_managed(OpenShell.state()),
         {:ok, _host, _port} <- Client.parse_endpoint(endpoint) |> endpoint_error() do
      previous = OpenShell.state()
      name = "pki-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

      state = %{
        "mode" => "external",
        "endpoint" => endpoint,
        "version" => Manifest.version(),
        "pki" => name
      }

      dir = OpenShell.credentials_dir(state)
      HalC2.Paths.mkdir_private!(Path.join(dir, "client"))

      # The gateway is checked with the credentials where they were staged. Only
      # then does one write of the state, naming both, reach `Client.connect/0`.
      with :ok <- copy_credentials(credentials, dir),
           :ok <- smoke(state) do
        OpenShell.put_state(state)
        prune_credentials([state, previous])
        {:ok, state}
      else
        {:error, reason} ->
          File.rm_rf!(dir)
          {:error, message(reason)}
      end
    end
  end

  # Every path is below this MC's own OpenShell directory, or a certificate the
  # local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_credentials(credentials, dir) do
    Enum.reduce_while(
      [{:ca, "ca.crt"}, {:cert, "client/tls.crt"}, {:key, "client/tls.key"}],
      :ok,
      fn {key, name}, :ok ->
        to = Path.join(dir, name)

        with path when is_binary(path) <- credentials[key],
             :ok <- File.cp(path, to),
             :ok <- File.chmod(to, if(key == :key, do: 0o600, else: 0o644)) do
          {:cont, :ok}
        else
          _ -> {:halt, {:error, "Cannot read the #{key} file #{inspect(credentials[key])}."}}
        end
      end
    )
  end

  # Removes the credentials of a user's gateway but those `keep` (states, or nil)
  # name. The ones just replaced stay until the next reuse, for a connection that
  # read the state before it changed.
  # Only credential directories in the MC's own OpenShell directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_credentials(keep) do
    keep = for state <- keep, state != nil, do: OpenShell.credentials_dir(state)

    for dir <- [OpenShell.pki_dir() | Path.wildcard(Path.join(OpenShell.root(), "pki-*"))],
        dir not in keep,
        do: File.rm_rf!(dir)

    :ok
  end

  defp not_managed(%{"mode" => mode}) when mode in ["managed", "foreground"],
    do:
      {:error,
       "[managed] This MC runs its own gateway. Run `hal-c2-service openshell uninstall` first to use another."}

  defp not_managed(_), do: :ok

  defp endpoint_error({:ok, host, port}), do: {:ok, host, port}

  defp endpoint_error({:error, :plaintext_refused}),
    do: {:error, "[plaintext-refused] The MC talks to OpenShell over TLS only (https://...)."}

  defp endpoint_error({:error, _}),
    do: {:error, "[bad-endpoint] Name the gateway as https://host:port."}

  # --- status and uninstall ---------------------------------------------------------

  @doc """
  What `hal-c2-service openshell status` shows: `%{"supported", "problems",
  "mode", "version", "endpoint", "service", "health", "sharedWith"}`
  (the other HAL-C2 environments with sandboxes on the gateway). `problems` are codes
  `HalC2.OpenShell.Command` explains; an empty list means it is ready.
  """
  def status do
    state = OpenShell.state()

    platform =
      case Platform.check(Platform.facts()) do
        {:ok, _} -> []
        {:error, problems} -> problems
      end

    service = if state && state["mode"] == "managed", do: Service.status(state)

    {health, others} =
      with %{} <- state,
           {:ok, conn} <- Client.connect_unchecked() do
        try do
          health = Client.health(conn, timeout: 3_000)
          # Who else has sandboxes there is only asked of a gateway that answers.
          {health,
           if(match?({:ok, _}, health), do: Client.other_environments(conn, timeout: 5_000))}
        after
          Client.disconnect(conn)
        end
      else
        _ -> {nil, nil}
      end

    others = with {:ok, ids} <- others, do: ids

    problems =
      cond do
        state == nil and platform != [] -> platform
        state == nil -> ["not-installed"]
        true -> platform ++ state_problems(state, service, health, others)
      end

    %{
      "supported" => platform == [],
      "problems" => problems,
      "mode" => state && state["mode"],
      "version" => state && state["version"],
      "manifestVersion" => Manifest.version(),
      "sharedWith" => if(is_list(others), do: others, else: []),
      "endpoint" => state && state["endpoint"],
      "service" => service,
      "health" =>
        case health do
          {:ok, %{status: status, version: version}} ->
            %{"status" => to_string(status), "version" => version}

          _ ->
            nil
        end
    }
  end

  defp state_problems(state, service, health, others) do
    []
    |> add(
      state["mode"] != "external" and state["version"] != Manifest.version(),
      "update-available"
    )
    |> add(service != nil and not service["installed"], "service-missing")
    |> add(service != nil and service["foreign"] == true, "service-not-ours")
    |> add(Service.moved(state) != :ok, "home-moved")
    |> add(ours?(service) and not service["current"], "service-outdated")
    |> add(ours?(service) and not service["running"], "service-stopped")
    |> add(not match?({:ok, _}, health), "gateway-unreachable")
    |> add(match?({:ok, %{status: s}} when s != :healthy, health), "gateway-unhealthy")
    |> add(
      match?({:ok, %{version: v}} when is_binary(v), health) and
        elem(health, 1).version != Manifest.version(),
      "version-mismatch"
    )
    |> add(is_list(others) and others != [], "gateway-shared")
  end

  defp ours?(service), do: service != nil and service["installed"] and not service["foreign"]

  defp add(list, true, code), do: list ++ [code]
  defp add(list, false, _code), do: list

  @doc """
  Removes the gateway this MC runs (its unit, binary, certificates, configuration
  and database), or forgets the one it reused. Refuses while this MC's sandboxes
  exist on it, unless `drain: true` (`force: true` when they cannot be listed).
  """
  def uninstall(opts \\ []) do
    case OpenShell.state() do
      nil ->
        {:error, not_installed()}

      state ->
        with :ok <- Service.owned(),
             :ok <- Service.moved(state),
             :ok <- foreground_stopped(state),
             :ok <- drained(state, opts),
             :ok <- if(state["mode"] == "managed", do: service_stopped(), else: :ok),
             :ok <- if(state["mode"] == "managed", do: Service.uninstall(), else: :ok) do
          if state["mode"] != "external" do
            File.rm_rf!(OpenShell.root())
            File.rm_rf!(Path.dirname(OpenShell.db_path()))
          else
            prune_credentials([])
            OpenShell.delete_state()
          end

          :ok
        end
    end
  end

  defp not_installed,
    do: "[not-installed] OpenShell is not installed. Run `hal-c2-service openshell install`."

  # --- files ------------------------------------------------------------------------

  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  defp staging(fun) do
    HalC2.Paths.mkdir_private!(OpenShell.root())
    dir = Path.join([OpenShell.root(), "staging", Base.encode16(:crypto.strong_rand_bytes(6))])
    HalC2.Paths.mkdir_private!(dir)

    try do
      fun.(dir)
    after
      case File.rm_rf(dir) do
        {:ok, _} ->
          :ok

        # The step is already done or undone; staging is in this home's private
        # directory, and the next run starts in a fresh one.
        {:error, reason, path} ->
          Logger.warning(
            "OpenShell: staging #{path} was not removed: #{:file.format_error(reason)}"
          )
      end
    end
  end

  # Puts directory `from` where `to` is, replacing it.
  defp replace_dir(from, to) do
    File.rm_rf!(to)
    File.rename(from, to)
  end

  defp message(reason) when is_binary(reason), do: reason
  defp message({:error, reason}), do: message(reason)
  defp message(%{status: status, message: text}), do: "#{status}: #{text}"
  defp message(reason), do: inspect(reason)
end
