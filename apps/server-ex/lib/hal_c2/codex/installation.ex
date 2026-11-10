defmodule HalC2.Codex.Installation do
  @moduledoc """
  The Codex this MC installs itself (`provider.install.*` for a Codex instance), and
  which Codex an instance runs (`command/2`).

  The managed Codex is OpenAI's release package for this host at the version the MC
  pins, under `<cache>/tools/codex/<version>` with `active.json` naming the one in
  use. One install runs at a time, in a linked worker: download with progress, size
  and SHA-256 check, extraction of the package's safe entries, a check of the
  package's layout and that `codex --version` names the pinned release, then
  activation. A cancelled or failed install leaves the previous Codex active.
  Subscribers get `{:hal_c2_provider_install, instance, state}`
  (`ProviderInstallState`) on every change.

  An instance with a `binaryPath` runs that. Otherwise it runs the `codex` on the
  MC's PATH, unless that is a native binary without its `codex-code-mode-host`
  beside it, whose every Code Mode call would fail: then the managed Codex, when
  one is installed. Launchers (scripts, version-manager shims) find their own
  payloads and are run as they are.

  At boot, a managed Codex older than the pin is updated in the background, unless
  the PATH's Codex is the one in use. Threads keep running on the installed Codex
  until the new one is verified and active; a failed update leaves it in place.

  Test seams (application env): `:codex_release` (a release map, or `:none`) and
  `:codex_download_timeout_ms` (45 minutes).
  """

  use GenServer

  require Logger

  alias HalC2.ProviderInstall

  @version "0.166.0"
  # OpenAI's release packages (github.com/openai/codex, `rust-v<version>`).
  @releases %{
    {"darwin", "arm64"} => %{
      target: "aarch64-apple-darwin",
      sha256: "55a440cb579f970abe7c79ab181e54b0ea4c419be99f333bbd868eebac9c21f0",
      archive_bytes: 165_951_869
    },
    {"darwin", "x64"} => %{
      target: "x86_64-apple-darwin",
      sha256: "1cb65690230be5982c654ba2655e3a3b594dce9c55b780e78bfdfeff829d7ad9",
      archive_bytes: 180_076_524
    },
    {"linux", "arm64"} => %{
      target: "aarch64-unknown-linux-musl",
      sha256: "7821b77dda2e6283fb1f63f3165177a271da8833e857cf673c6ca1c9db3bfcc6",
      archive_bytes: 187_370_368
    },
    {"linux", "x64"} => %{
      target: "x86_64-unknown-linux-musl",
      sha256: "1d44b28bc4ac9937d7d3532264baa68a507ce364956a0d4ebb856f331cdee254",
      archive_bytes: 199_694_962
    },
    {"win32", "arm64"} => %{
      target: "aarch64-pc-windows-msvc",
      sha256: "9383152a72f97bb5dd148493c8214e4fed38d805aa2c3297cb3739f7f130becf",
      archive_bytes: 187_024_318
    },
    {"win32", "x64"} => %{
      target: "x86_64-pc-windows-msvc",
      sha256: "d559bb88e74d471265857b93b7f19bc250dae527673b9191b33534478093f6bc",
      archive_bytes: 202_589_789
    }
  }

  @disk "Could not install Codex. Check disk space and directory access, then try again."
  @connection "Check your internet connection"
  # Launchers that dispatch by their own name to a Codex they install elsewhere.
  @launchers ~w(volta-shim mise aqua-proxy)

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # --- which Codex runs --------------------------------------------------------------

  @doc """
  The command instance `instance` runs Codex with: `default` (`codex app-server`
  unless `:codex_command` says otherwise) or its `binaryPath`, with the managed
  Codex in place of a PATH `codex` that lacks its Code Mode host.
  """
  def command(instance, default \\ nil) do
    default = default || Application.get_env(:hal_c2, :codex_command, ["codex", "app-server"])
    cmd = HalC2.Settings.instance_command(instance, default)

    if HalC2.Settings.instance_setting(instance, "binaryPath") == nil,
      do: pick(cmd),
      else: cmd
  end

  defp pick([exe | args] = cmd) do
    if Path.basename(exe, ".exe") == "codex" and not local_usable?(exe) do
      case active() do
        {:ok, found} -> [found.executable | args]
        _ -> cmd
      end
    else
      cmd
    end
  end

  defp pick(cmd), do: cmd

  # The PATH's Codex can run Code Mode: a launcher, or a native binary with its host.
  defp local_usable?(exe) do
    with path when is_binary(path) <- System.find_executable(exe) do
      real = real_path(path)

      not String.starts_with?(real, managed_dir() <> "/") and
        (Path.basename(real, ".exe") in @launchers or launcher?(real) or
           ProviderInstall.executable?(
             Path.join(Path.dirname(real), "codex-code-mode-host" <> Path.extname(real))
           ))
    else
      _ -> false
    end
  end

  # A script (`#!`), or on Windows anything but an `.exe`, finds its own Codex. Reads
  # two bytes of the PATH's own `codex`.
  # sobelow_skip ["Traversal.FileModule"]
  defp launcher?(path) do
    if match?({"win32", _}, platform()) do
      Path.extname(path) != ".exe"
    else
      case File.open(path, [:read, :binary], &IO.binread(&1, 2)) do
        {:ok, "#!"} -> true
        _ -> false
      end
    end
  end

  defp real_path(path) do
    case :file.read_link_all(path) do
      {:ok, target} -> real_path(Path.expand(to_string(target), Path.dirname(path)))
      _ -> path
    end
  end

  @doc "The active managed Codex: `{:ok, %{executable, version, dir}}`, `:none` or `{:error, detail}`."
  # `active.json` is the MC's own, and the version it names must look like one, so it
  # cannot point outside the managed directory.
  # sobelow_skip ["Traversal.FileModule"]
  def active do
    with {:ok, body} <- File.read(active_path()),
         {:ok, %{"version" => version}} when is_binary(version) <- JSON.decode(body),
         true <- version =~ ~r/\A\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?\z/,
         {:ok, found} <- completed(version) do
      {:ok, found}
    else
      {:error, :enoent} -> :none
      _ -> {:error, "The managed Codex runtime is incomplete. Remove it and reinstall."}
    end
  end

  @doc "Whether `path` is inside the managed Codex installation."
  def managed?(path) when is_binary(path),
    do: String.starts_with?(real_path(Path.expand(path)), managed_dir() <> "/")

  def managed?(_path), do: false

  # --- release and layout ------------------------------------------------------------

  @doc "OpenAI's Codex package for this host at the pinned version, or nil where none is published."
  def release do
    case Application.get_env(:hal_c2, :codex_release) do
      :none ->
        nil

      %{} = release ->
        release

      nil ->
        with %{target: target} = release <- @releases[platform()] do
          Map.merge(release, %{
            version: @version,
            url:
              "https://github.com/openai/codex/releases/download/rust-v#{@version}/codex-package-#{target}.tar.gz"
          })
        end
    end
  end

  defp platform, do: ProviderInstall.host_platform()

  @doc "Where the managed Codex lives on this MC."
  def managed_dir, do: Path.join([HalC2.Paths.cache_dir(), "tools", "codex"])

  defp active_path, do: Path.join(managed_dir(), "active.json")
  defp staging(op), do: Path.join(managed_dir(), ".staging-#{op}")

  # Paths under the managed directory, which the MC owns and names itself.
  # sobelow_skip ["Traversal.FileModule"]
  defp clear(dir), do: File.rm_rf(dir)
  defp exe, do: if(match?({"win32", _}, platform()), do: ".exe", else: "")

  # A completed release: its record names it and the package beside it is whole.
  defp completed(version) do
    dir = Path.join(managed_dir(), version)

    with {:ok, record} <- read_json(Path.join(dir, ".install-complete.json")),
         %{"version" => ^version, "target" => target} when is_binary(target) <- record do
      package(dir, version, target)
    else
      _ -> {:error, :incomplete}
    end
  end

  # The package's manifest names the release, and its programs are there to run.
  defp package(dir, version, target) do
    with {:ok, manifest} <- read_json(Path.join(dir, "codex-package.json")),
         %{"layoutVersion" => 1, "version" => ^version, "target" => ^target} <- manifest,
         true <- manifest["entrypoint"] == "bin/codex" <> exe(),
         true <-
           Enum.all?(
             ["bin/codex", "bin/codex-code-mode-host", "codex-path/rg"],
             &usable?(Path.join(dir, &1 <> exe()))
           ) do
      {:ok, %{executable: Path.join(dir, "bin/codex" <> exe()), version: version, dir: dir}}
    else
      _ -> {:error, :incomplete}
    end
  end

  defp usable?(path) do
    match?({:ok, %{size: size}} when size > 0, File.stat(path)) and
      ProviderInstall.executable?(path)
  end

  # Records inside the managed directory, read with a size bound.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_json(path) do
    with {:ok, %{size: size}} when size <= 8192 <- File.stat(path),
         {:ok, body} <- File.read(path),
         do: JSON.decode(body),
         else: (_ -> {:error, :invalid})
  end

  # --- RPCs --------------------------------------------------------------------------

  @doc "`provider.install.start`."
  def start(%{"instanceId" => instance}) do
    with :ok <- require_instance(instance, "install", true),
         do: GenServer.call(__MODULE__, {:start, instance})
  end

  @doc "`provider.install.cancel`."
  def cancel(%{"instanceId" => instance} = input) do
    with :ok <- require_instance(instance, "cancel-install", false),
         do: GenServer.call(__MODULE__, {:cancel, instance, input["operationId"]})
  end

  @doc "`provider.install.remove`."
  def remove(%{"instanceId" => instance}) do
    with :ok <- require_instance(instance, "remove-install", true),
         do: GenServer.call(__MODULE__, {:remove, instance}, 60_000)
  end

  @doc "Adds `pid` as a subscriber under `ref`; it gets `{:hal_c2_provider_install, instance, state}`."
  def subscribe(instance, pid, ref \\ nil) do
    with :ok <- require_instance(instance, "observe-install", false),
         do: GenServer.call(__MODULE__, {:subscribe, instance, pid, ref})
  end

  def unsubscribe(instance, pid, ref \\ nil),
    do: GenServer.cast(__MODULE__, {:unsubscribe, instance, pid, ref})

  @doc "The current `ProviderInstallState`."
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "Whether `instance` is a Codex instance, whose installation this is."
  def instance?(instance), do: HalC2.Settings.known_instance?(instance, "codex")

  defp require_instance(instance, operation, managed_only) do
    cond do
      not instance?(instance) ->
        ProviderInstall.error(
          instance,
          operation,
          "Managed installation is not available for this provider instance."
        )

      managed_only and HalC2.Settings.instance_setting(instance, "binaryPath") != nil ->
        ProviderInstall.error(
          instance,
          operation,
          "This instance uses a custom executable. Clear its binary path to manage installation in HAL-C2."
        )

      true ->
        :ok
    end
  end

  # --- server ------------------------------------------------------------------------

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    release = release()
    # What an install the MC stopped in the middle of left behind.
    for dir <- Path.wildcard(Path.join(managed_dir(), ".staging-*"), match_dot: true),
        do: clear(dir)

    {installed, failed} =
      case active() do
        {:ok, found} -> {found.version, nil}
        :none -> {nil, nil}
        {:error, detail} -> {nil, detail}
      end

    state = %{
      "driver" => "codex",
      "operationId" => nil,
      "phase" => if(failed, do: "failed", else: "idle"),
      "downloadedBytes" => 0,
      "totalBytes" => release && release.archive_bytes,
      "version" => release && release.version,
      "installedVersion" => installed,
      "canRemove" => File.dir?(managed_dir()),
      "message" => failed
    }

    # A raised pin reaches an installation in use: update it in the background.
    default = Application.get_env(:hal_c2, :codex_command, ["codex", "app-server"])

    if release && installed && older?(installed, release.version) && managed?(hd(pick(default))),
      do: send(self(), :update)

    {:ok, %{state: state, watchers: %{}, op: nil}}
  end

  defp older?(installed, pinned) do
    with {:ok, a} <- Version.parse(installed),
         {:ok, b} <- Version.parse(pinned),
         do: Version.compare(a, b) == :lt,
         else: (_ -> false)
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.state, state}

  def handle_call({:subscribe, instance, pid, ref}, _from, state),
    do: {:reply, {:ok, state.state}, ProviderInstall.subscribe(state, instance, pid, ref)}

  def handle_call({:start, _instance}, _from, %{op: %{}} = state),
    do: {:reply, {:ok, state.state}, state}

  def handle_call({:start, instance}, _from, state) do
    case begin(state) do
      {:ok, state} ->
        {:reply, {:ok, state.state}, state}

      :unpublished ->
        {:reply,
         ProviderInstall.error(
           instance,
           "install",
           "OpenAI does not publish a Codex runtime for #{platform_name()}. Use a supported remote environment or a custom executable."
         ), state}
    end
  end

  def handle_call({:cancel, instance, op_id}, _from, state) do
    case state.op do
      %{id: ^op_id, pid: pid} ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        clear(staging(op_id))

        state =
          ProviderInstall.publish(%{state | op: nil}, %{
            "phase" => "cancelled",
            "message" => "Installation cancelled. The previous runtime is unchanged."
          })

        {:reply, {:ok, state.state}, state}

      _ ->
        {:reply,
         ProviderInstall.error(
           instance,
           "cancel-install",
           "This installation is no longer current. Refresh its status before cancelling."
         ), state}
    end
  end

  def handle_call({:remove, instance}, _from, state) do
    cond do
      state.op != nil or Registry.count(HalC2.Codex.Registry) > 0 ->
        {:reply,
         ProviderInstall.error(
           instance,
           "remove-install",
           "Stop Codex sessions before removing its managed runtime."
         ), state}

      Enum.any?(["codex" | HalC2.Settings.instances_of("codex")], fn id ->
        managed?(HalC2.Settings.instance_setting(id, "binaryPath"))
      end) ->
        {:reply,
         ProviderInstall.error(
           instance,
           "remove-install",
           "A provider instance uses a custom path inside managed Codex. Clear that path before removing it."
         ), state}

      true ->
        File.rm_rf!(managed_dir())
        HalC2.Settings.notify_providers()

        state =
          ProviderInstall.publish(state, %{
            "operationId" => nil,
            "phase" => "idle",
            "downloadedBytes" => 0,
            "installedVersion" => nil,
            "canRemove" => false,
            "message" => nil
          })

        {:reply, {:ok, state.state}, state}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, instance, pid, ref}, state),
    do: {:noreply, ProviderInstall.unsubscribe(state, instance, pid, ref)}

  @impl true
  def handle_info(:update, %{op: nil} = state) do
    case begin(state) do
      {:ok, state} -> {:noreply, state}
      :unpublished -> {:noreply, state}
    end
  end

  def handle_info({:install_progress, op, patch}, %{op: %{id: op}} = state),
    do: {:noreply, ProviderInstall.publish(state, patch)}

  def handle_info({:install_done, op, result}, %{op: %{id: op}} = state) do
    state = %{state | op: nil}
    clear(staging(op))

    state =
      case result do
        {:ok, version} ->
          HalC2.Settings.notify_providers()

          ProviderInstall.publish(state, %{
            "phase" => "succeeded",
            "installedVersion" => version,
            "canRemove" => true,
            "message" => nil
          })

        {:error, detail} ->
          ProviderInstall.publish(state, %{"phase" => "failed", "message" => detail})
      end

    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{op: %{pid: pid, id: op}} = state)
      when reason != :normal do
    Logger.warning("Codex install failed: #{inspect(reason)}")
    clear(staging(op))

    {:noreply,
     ProviderInstall.publish(%{state | op: nil}, %{"phase" => "failed", "message" => @disk})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, ProviderInstall.down(state, pid)}

  def handle_info(_message, state), do: {:noreply, state}

  # Starts the install of the pinned release in a linked worker.
  defp begin(state) do
    case release() do
      nil ->
        :unpublished

      release ->
        op = HalC2.Environment.uuid4()
        server = self()

        worker =
          spawn_link(fn -> send(server, {:install_done, op, install(release, server, op)}) end)

        {:ok,
         ProviderInstall.publish(%{state | op: %{id: op, pid: worker}}, %{
           "operationId" => op,
           "phase" => "downloading",
           "downloadedBytes" => 0,
           "totalBytes" => release.archive_bytes,
           "version" => release.version,
           "message" => "Downloading Codex."
         })}
    end
  end

  defp platform_name do
    {os, arch} = platform()
    "#{os}-#{arch}"
  end

  # --- the install -------------------------------------------------------------------

  # Every path is under the managed directory, named by the pinned release and the op.
  # sobelow_skip ["Traversal.FileModule"]
  defp install(release, server, op) do
    report = fn patch -> send(server, {:install_progress, op, patch}) end
    File.mkdir_p!(managed_dir())
    report.(%{"canRemove" => true})
    target = Path.join(managed_dir(), release.version)

    if File.dir?(target) do
      report.(%{"phase" => "verifying", "message" => "Checking Codex."})

      with {:ok, found} <- completed(release.version) |> or_detail(),
           {:ok, %{"sha256" => sha, "target" => built_for}} <-
             read_json(Path.join(target, ".install-complete.json")),
           true <-
             (sha == release.sha256 and built_for == release.target) ||
               {:error,
                "The existing managed Codex release differs from the official package. Remove it and reinstall."},
           :ok <- validate(found.executable, release.version),
           do: activate(release.version)
    else
      staging = staging(op)
      archive = Path.join(staging, "download.tar.gz")
      runtime = Path.join(staging, "runtime")
      File.rm_rf!(staging)
      File.mkdir_p!(runtime)

      with :ok <- download(release, archive, report),
           :ok <- verify(archive, release),
           _ <- report.(%{"phase" => "extracting", "message" => "Extracting Codex."}),
           :ok <- extract(archive, runtime),
           _ <- report.(%{"phase" => "verifying", "message" => "Checking Codex."}),
           {:ok, found} <- package(runtime, release.version, release.target) |> or_detail(),
           :ok <- validate(found.executable, release.version) do
        File.write!(
          Path.join(runtime, ".install-complete.json"),
          JSON.encode!(%{
            "version" => release.version,
            "target" => release.target,
            "sha256" => release.sha256
          })
        )

        File.rename!(runtime, target)
        activate(release.version)
      end
    end
  rescue
    error in [File.Error, File.RenameError] ->
      Logger.warning("Codex install failed: #{Exception.message(error)}")
      {:error, @disk}
  end

  defp or_detail({:error, :incomplete}),
    do: {:error, "The managed Codex package is incomplete. Reinstall Codex."}

  defp or_detail(other), do: other

  defp download(release, archive, report) do
    timeout = Application.get_env(:hal_c2, :codex_download_timeout_ms, :timer.minutes(45))

    case ProviderInstall.fetch(
           release.url,
           archive,
           release.archive_bytes,
           &report.(%{"downloadedBytes" => &1}),
           deadline_ms: timeout
         ) do
      :ok ->
        :ok

      {:error, {:status, status}} ->
        {:error,
         "The Codex download server returned HTTP #{status}. #{@connection}, then try again later."}

      {:error, {:disk, reason}} ->
        {:error, "The Codex download could not be saved (#{:file.format_error(reason)})."}

      {:error, :timeout} ->
        {:error, "The Codex download timed out. #{@connection}, then retry installation."}

      {:error, _interrupted_or_stalled} ->
        interrupted()
    end
  end

  defp interrupted,
    do: {:error, "The Codex download was interrupted. #{@connection}, then retry installation."}

  defp verify(archive, release) do
    case File.stat!(archive).size do
      # A body that ended early is a connection that dropped, not a bad package.
      size when size < release.archive_bytes ->
        interrupted()

      size ->
        if size == release.archive_bytes and ProviderInstall.sha256(archive) == release.sha256,
          do: :ok,
          else:
            {:error,
             "The Codex download failed its size or SHA-256 check. Nothing was installed."}
    end
  end

  # Only regular files and directories under relative, plain names are extracted.
  defp extract(archive, dir) do
    unsafe = {:error, "The Codex archive contains unsafe entries."}
    archive = String.to_charlist(archive)

    with {:ok, entries} <- :erl_tar.table(archive, [:compressed, :verbose]),
         true <- (length(entries) <= 10_000 and Enum.all?(entries, &safe_entry?/1)) || unsafe,
         :ok <- :erl_tar.extract(archive, [:compressed, {:cwd, String.to_charlist(dir)}]) do
      :ok
    else
      {:error, detail} when is_binary(detail) -> {:error, detail}
      _ -> unsafe
    end
  end

  defp safe_entry?({name, type, _size, _mtime, _mode, _uid, _gid})
       when type in [:regular, :directory] do
    name = to_string(name)
    parts = name |> String.trim_trailing("/") |> String.split("/")

    name != "" and not String.starts_with?(name, "/") and not String.contains?(name, "\\") and
      not Enum.any?(parts, &(&1 in ["", ".", ".."] or String.contains?(&1, ":")))
  end

  defp safe_entry?(_entry), do: false

  # The program starts here and names the release it should be. `executable` is the
  # package's own `bin/codex`, just extracted and checked against its SHA-256.
  # sobelow_skip ["CI.System"]
  defp validate(executable, version) do
    task = Task.async(fn -> System.cmd(executable, ["--version"], stderr_to_stdout: true) end)

    case Task.yield(task, 90_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} ->
        if String.trim(out) == "codex-cli #{version}",
          do: :ok,
          else: {:error, "The downloaded Codex executable has the wrong version."}

      _ ->
        {:error, "The downloaded Codex runtime could not start."}
    end
  catch
    :exit, _ -> {:error, "The downloaded Codex runtime could not start."}
  end

  # `active.json` is replaced in one rename; the Codex's check is then read again.
  # sobelow_skip ["Traversal.FileModule"]
  defp activate(version) do
    temporary = Path.join(managed_dir(), ".active-#{System.unique_integer([:positive])}.json")
    File.write!(temporary, JSON.encode!(%{"version" => version}))
    File.rename!(temporary, active_path())
    HalC2.Codex.Provider.load()
    {:ok, version}
  end
end
