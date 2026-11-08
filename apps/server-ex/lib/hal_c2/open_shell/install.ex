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
  gateway is about to stop (`drain: true` deletes them first). Reuse and
  uninstall never touch a sandbox this MC did not label.
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
  Options: `:archive` (a local copy of the pinned archive), `:drain`, and
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
         {:ok, platform} <- platform(),
         {:ok, release} <- release(platform.target, opts) do
      staging(fn staging ->
        state = %{
          "mode" => mode,
          "version" => release.version,
          "port" => (previous && previous["port"]) || free_port(),
          "driver" => platform.driver,
          "socket" => platform.socket,
          "previous" => previous && previous["version"]
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
  connection made with the old ones. Option: `:drain`.
  """
  def rotate(opts \\ []) do
    case OpenShell.state() do
      %{"mode" => mode} = state when mode in ["managed", "foreground"] ->
        staging(fn staging ->
          pki = Path.join(staging, "pki")

          with :ok <- issue(state["version"], pki),
               :ok <- drained(state, opts) do
            switch(state, state, opts, fn -> replace_dir(pki, OpenShell.pki_dir()) end)
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
    backup = previous && previous["mode"] in ["managed", "foreground"] && backup(previous)

    result =
      with :ok <- prepare.(),
           :ok <- File.chmod(OpenShell.config_path(), 0o600),
           :ok <- start(state, opts) do
        :ok
      end

    # A gateway that no longer runs as a service must not start again at login.
    result =
      if result == :ok and match?(%{"mode" => "managed"}, previous) and state["mode"] != "managed",
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

  # Undoes a `switch/4` to `state` that failed, back to `previous` and its backup.
  defp rollback(previous, state, backup, opts, reason) do
    managed = state["mode"] == "managed"
    if managed, do: Service.stop()

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

  defp smoke_fun(opts), do: Keyword.get(opts, :smoke, &smoke/1)

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
        unset = Enum.flat_map(Config.unset_environment(), &["-u", &1])
        set = for {k, v} <- Config.environment(), do: "#{k}=#{v}"
        argv = ["env" | unset] ++ set ++ [OpenShell.gateway_bin(version) | Config.args()]

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
    if File.regular?(Path.join([OpenShell.pki_dir(), "client", "tls.key"])) do
      :ok
    else
      HalC2.Paths.mkdir_private!(OpenShell.root())
      tmp = OpenShell.pki_dir() <> ".new"
      File.rm_rf!(tmp)

      with :ok <- issue(version, tmp), do: replace_dir(tmp, OpenShell.pki_dir())
    end
  end

  # The gateway's `generate-certs` issues a CA, the gateway's certificate, the MC's
  # client certificate and the sandbox token key into `dir`. Every key is made
  # owner-only and the CA's key deleted, so no further identity can be issued.
  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  defp issue(version, dir) do
    with :ok <- gateway(version, ["generate-certs", "--output-dir", dir]) do
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
          ["ca.crt", "server/tls.crt", "server/tls.key", "client/tls.crt", "client/tls.key"] ++
            ["jwt/signing.pem", "jwt/public.pem", "jwt/kid"],
          &File.regular?(Path.join(dir, &1))
        )

      if missing == [],
        do: :ok,
        else: {:error, "The gateway did not issue #{Enum.join(missing, ", ")}."}
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
    env = Config.environment() ++ Enum.map(Config.unset_environment(), &{&1, nil})
    HalC2.Paths.mkdir_private!(Path.dirname(OpenShell.db_path()))

    case System.cmd(OpenShell.gateway_bin(version), args,
           env: env,
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
    if state["mode"] == "managed", do: Service.stop()
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

  # A running gateway with this MC's sandboxes on it is not stopped unless they go
  # first. A gateway that does not answer has none to save.
  defp drained(%{"mode" => mode}, opts) when mode in ["managed", "foreground"] do
    with {:ok, conn} <- Client.connect() do
      try do
        case Client.list_sandboxes(conn, %{}, timeout: 5_000) do
          {:ok, []} ->
            :ok

          {:ok, sandboxes} ->
            if opts[:drain],
              do: delete_all(conn, sandboxes),
              else:
                {:error,
                 "[sandboxes-running] #{length(sandboxes)} of this MC's sandboxes are on the gateway. Let their reviews finish, or pass --drain to delete them."}

          {:error, _} ->
            :ok
        end
      after
        Client.disconnect(conn)
      end
    else
      _ -> :ok
    end
  end

  defp drained(_previous, _opts), do: :ok

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

    * it answers over mTLS, healthy, at the pinned version, with the expected driver
    * it takes the MC's certificate for a user that is not an operator
    * it refuses a caller with no certificate, and refuses plaintext
    * the `hal-c2` workspace exists
    * a workload in a fresh sandbox can reach neither the gateway nor the runtime
      socket (`isolation: false` skips this, for a gateway with no runtime yet)
  """
  def smoke(state, opts \\ []) do
    wait = if state["mode"] == "managed", do: @start_timeout, else: 0

    with {:ok, conn} <- connect_when_up(state["endpoint"], wait) do
      try do
        with :ok <- check_gateway(conn, state),
             :ok <- check_refusals(state["endpoint"]),
             :ok <- Client.ensure_workspace(conn) |> labelled("workspace"),
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
  defp connect_when_up(endpoint, wait),
    do: connect_when_up(endpoint, System.monotonic_time(:millisecond) + wait, nil)

  defp connect_when_up(endpoint, deadline, _last) do
    result =
      with {:ok, conn} <- Client.connect(endpoint, OpenShell.credentials()) do
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
          connect_when_up(endpoint, deadline, error)
        else
          {:error,
           "[gateway-unreachable] The gateway did not answer: #{message(error)}. Its log: #{OpenShell.log_path()}"}
        end
    end
  end

  defp check_gateway(conn, state) do
    with {:ok, health} <- Client.health(conn) |> labelled("health"),
         {:ok, info} <- Client.gateway_info(conn) |> labelled("gateway info"),
         {:ok, user} <- Client.current_user(conn) |> labelled("identity") do
      cond do
        health.status != :healthy ->
          {:error, "[gateway-unhealthy] The gateway reports #{health.status}."}

        health.version != Manifest.version() ->
          {:error,
           "[version-mismatch] The gateway is #{health.version}; this MC needs #{Manifest.version()}."}

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

  defp check_refusals(endpoint) do
    anonymous =
      case Client.connect(endpoint, ca: OpenShell.credentials()[:ca], anonymous: true) do
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
      _ -> false
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
  # reached. The sandbox is deleted whatever the outcome.
  defp check_isolation(conn, state) do
    name = "halc2-smoke-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    try do
      with {:ok, _} <- Client.create_sandbox(conn, name) |> labelled("creating a sandbox"),
           :ok <- await_ready(conn, name, System.monotonic_time(:millisecond) + @sandbox_timeout),
           {:ok, exec} <- Client.exec(conn, name, ["bash", "-c", isolation_probe(state)]) do
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
    after
      Client.delete_sandbox(conn, name)
    end
  end

  @doc false
  def isolation_probe(state) do
    port = state["port"] || Client.parse_endpoint(state["endpoint"]) |> elem(2)

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

    """
    found=0
    for s in #{Enum.map_join(sockets, " ", &shell_quote/1)}; do
      if [ -e "$s" ]; then echo "socket $s"; found=1; fi
    done
    for h in 127.0.0.1 host.containers.internal host.docker.internal; do
      if timeout 3 bash -c "exec 3<>/dev/tcp/$h/#{port}" 2>/dev/null; then echo "gateway via $h"; found=1; fi
    done
    exit $found
    """
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
  the MC records it. The MC will not start, stop or update it.
  """
  # Every path is below this MC's own OpenShell directories, or an archive or
  # certificate the local user named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  def reuse(endpoint, credentials) do
    with :ok <- not_managed(OpenShell.state()),
         {:ok, _host, _port} <- Client.parse_endpoint(endpoint) |> endpoint_error() do
      state = %{"mode" => "external", "endpoint" => endpoint, "version" => Manifest.version()}
      tmp = OpenShell.pki_dir() <> ".new"
      File.rm_rf!(tmp)
      HalC2.Paths.mkdir_private!(Path.join(tmp, "client"))

      copied =
        Enum.reduce_while(
          [{:ca, "ca.crt"}, {:cert, "client/tls.crt"}, {:key, "client/tls.key"}],
          :ok,
          fn {key, name}, :ok ->
            to = Path.join(tmp, name)

            with path when is_binary(path) <- credentials[key],
                 :ok <- File.cp(path, to),
                 :ok <- File.chmod(to, if(key == :key, do: 0o600, else: 0o644)) do
              {:cont, :ok}
            else
              _ -> {:halt, {:error, "Cannot read the #{key} file #{inspect(credentials[key])}."}}
            end
          end
        )

      with :ok <- copied,
           :ok <- replace_dir(tmp, OpenShell.pki_dir()),
           :ok <- OpenShell.put_state(state),
           :ok <- smoke(state) do
        {:ok, state}
      else
        {:error, reason} ->
          OpenShell.delete_state()
          File.rm_rf!(OpenShell.pki_dir())
          {:error, message(reason)}
      end
    end
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
  "mode", "version", "endpoint", "service", "health"}`. `problems` are codes
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

    health =
      with %{} <- state,
           {:ok, conn} <- Client.connect() do
        try do
          Client.health(conn, timeout: 3_000)
        after
          Client.disconnect(conn)
        end
      else
        _ -> nil
      end

    problems =
      cond do
        state == nil and platform != [] -> platform
        state == nil -> ["not-installed"]
        true -> platform ++ state_problems(state, service, health)
      end

    %{
      "supported" => platform == [],
      "problems" => problems,
      "mode" => state && state["mode"],
      "version" => state && state["version"],
      "manifestVersion" => Manifest.version(),
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

  defp state_problems(state, service, health) do
    []
    |> add(
      state["mode"] != "external" and state["version"] != Manifest.version(),
      "update-available"
    )
    |> add(service != nil and not service["installed"], "service-missing")
    |> add(service != nil and service["installed"] and not service["current"], "service-outdated")
    |> add(service != nil and service["installed"] and not service["running"], "service-stopped")
    |> add(not match?({:ok, _}, health), "gateway-unreachable")
    |> add(match?({:ok, %{status: s}} when s != :healthy, health), "gateway-unhealthy")
    |> add(
      match?({:ok, %{version: v}} when is_binary(v), health) and
        elem(health, 1).version != Manifest.version(),
      "version-mismatch"
    )
  end

  defp add(list, true, code), do: list ++ [code]
  defp add(list, false, _code), do: list

  @doc """
  Removes the gateway this MC runs (its unit, binary, certificates, configuration
  and database), or forgets the one it reused. Refuses while this MC's sandboxes
  exist on it, unless `drain: true`.
  """
  def uninstall(opts \\ []) do
    case OpenShell.state() do
      nil ->
        {:error, not_installed()}

      state ->
        with :ok <- drained(state, opts),
             :ok <- if(state["mode"] == "managed", do: Service.uninstall(), else: :ok) do
          if state["mode"] != "external" do
            File.rm_rf!(OpenShell.root())
            File.rm_rf!(Path.dirname(OpenShell.db_path()))
          else
            File.rm_rf!(OpenShell.pki_dir())
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
      File.rm_rf(dir)
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
