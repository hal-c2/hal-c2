defmodule HalC2.Acp.Antigravity.Installation do
  @moduledoc """
  Installs Google's Antigravity runtime on this node (`provider.install.*`) and
  keeps the node's Antigravity instances in step with their settings.

  One install runs at a time, in a linked worker: download with progress, size
  and SHA-256 check, extraction of exactly the executable and its helper, a
  check that the result starts and identifies as the expected Google release,
  then activation (`active.json`). A cancelled or failed install leaves the
  previous runtime active. Subscribers get `{:halc2_provider_install, state}`
  (`ProviderInstallState`) on every change; the install goes on without them.

  The runtime can be removed only while no Antigravity session or sign-in uses it,
  and never from under an instance whose custom executable lives inside it.

  When an instance's sign-in method, credentials, executable or enabled flag
  change, its sessions stop so the next message starts with the new settings.

  Test seams (application env): `:antigravity_fetch` (`fn url, dest, progress ->
  :ok | {:error, detail}`, `progress.(bytes)` as bytes arrive) and
  `:antigravity_free_space` (`fn dir -> bytes`).
  """

  use GenServer

  require Logger

  alias HalC2.Acp.Antigravity

  @margin 256 * 1024 * 1024

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # --- RPCs ------------------------------------------------------------------------

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

  @doc "Adds `pid` as a subscriber; it gets `{:halc2_provider_install, instance, state}`."
  def subscribe(instance, pid) do
    with :ok <- require_instance(instance, "observe-install", false),
         do: GenServer.call(__MODULE__, {:subscribe, instance, pid})
  end

  def unsubscribe(instance, pid), do: GenServer.cast(__MODULE__, {:unsubscribe, instance, pid})

  @doc "The current `ProviderInstallState`."
  def state, do: GenServer.call(__MODULE__, :state)

  defp require_instance(instance, operation, managed_only) do
    cond do
      HalC2.Acp.driver(instance) != "antigravity" ->
        error(
          instance,
          operation,
          "Managed installation is not available for this provider instance."
        )

      managed_only and Antigravity.config(instance)["binaryPath"] != nil ->
        error(
          instance,
          operation,
          "This instance uses a custom executable. Clear its binary path to manage installation in HAL-C2."
        )

      true ->
        :ok
    end
  end

  # --- server ----------------------------------------------------------------------

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    HalC2.Settings.watch(self())
    {:ok, %{state: initial(), watchers: %{}, op: nil, seen: seen(HalC2.Settings.settings())}}
  end

  defp initial do
    release = Antigravity.release()
    managed = File.dir?(Antigravity.managed_dir())

    installed =
      with {:ok, body} <- File.read(Antigravity.active_path()),
           {:ok, %{"releaseId" => id}} <- JSON.decode(body),
           {:ok, found} <- Antigravity.completed(id) do
        {:ok, found.version}
      else
        {:error, :enoent} -> nil
        _ -> :incomplete
      end

    %{
      "driver" => "antigravity",
      "operationId" => nil,
      "phase" => "idle",
      "downloadedBytes" => 0,
      "totalBytes" => release && release.archive_bytes,
      "version" => release && release.version,
      "installedVersion" => with({:ok, v} <- installed, do: v, else: (_ -> nil)),
      "canRemove" => managed,
      "message" => nil
    }
    |> then(fn state ->
      if installed == :incomplete,
        do:
          Map.merge(state, %{
            "phase" => "failed",
            "message" => "The managed Antigravity runtime is incomplete. Remove it and reinstall."
          }),
        else: state
    end)
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.state, state}

  def handle_call({:subscribe, instance, pid}, _from, state) do
    key = {pid, instance}
    watchers = Map.put_new_lazy(state.watchers, key, fn -> Process.monitor(pid) end)
    {:reply, {:ok, state.state}, %{state | watchers: watchers}}
  end

  def handle_call({:start, _instance}, _from, %{op: %{}} = state),
    do: {:reply, {:ok, state.state}, state}

  def handle_call({:start, instance}, _from, state) do
    case Antigravity.release() do
      nil ->
        {:reply,
         error(
           instance,
           "install",
           "Google does not publish an Antigravity runtime for #{Antigravity.platform_name()}. Use a supported remote environment or a custom executable."
         ), state}

      release ->
        op = HalC2.Environment.uuid4()
        server = self()

        worker =
          spawn_link(fn -> send(server, {:install_done, op, install(release, server, op)}) end)

        state =
          publish(%{state | op: %{id: op, pid: worker}}, %{
            "operationId" => op,
            "phase" => "downloading",
            "downloadedBytes" => 0,
            "totalBytes" => release.archive_bytes,
            "version" => release.version,
            "message" => "Downloading Google's official Antigravity runtime."
          })

        {:reply, {:ok, state.state}, state}
    end
  end

  def handle_call({:cancel, instance, op_id}, _from, state) do
    case state.op do
      %{id: ^op_id, pid: pid} ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        File.rm_rf(staging(op_id))

        state =
          publish(%{state | op: nil}, %{
            "phase" => "cancelled",
            "message" => "Installation cancelled. The previous runtime is unchanged."
          })

        {:reply, {:ok, state.state}, state}

      _ ->
        {:reply,
         error(
           instance,
           "cancel-install",
           "This installation is no longer current. Refresh its status before cancelling."
         ), state}
    end
  end

  def handle_call({:remove, instance}, _from, state) do
    cond do
      state.op != nil or in_use?() ->
        {:reply,
         error(
           instance,
           "remove-install",
           "Stop Antigravity sessions and sign-in flows before removing its managed runtime."
         ), state}

      protected?() ->
        {:reply,
         error(
           instance,
           "remove-install",
           "A provider instance has a custom path inside this managed runtime. Clear that path before removing it."
         ), state}

      true ->
        File.rm_rf!(Antigravity.managed_dir())

        state =
          publish(state, %{
            "operationId" => nil,
            "phase" => "idle",
            "downloadedBytes" => 0,
            "installedVersion" => nil,
            "canRemove" => false,
            "message" => nil
          })

        for id <- HalC2.Acp.instances(), HalC2.Acp.driver(id) == "antigravity", do: HalC2.Acp.forget(id)
        HalC2.Settings.notify_providers()
        {:reply, {:ok, state.state}, state}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, instance, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, {pid, instance})
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info({:install_progress, op, patch}, %{op: %{id: op}} = state),
    do: {:noreply, publish(state, patch)}

  def handle_info({:install_done, op, result}, %{op: %{id: op}} = state) do
    state = %{state | op: nil}
    File.rm_rf(staging(op))

    state =
      case result do
        {:ok, version} ->
          for id <- HalC2.Acp.instances(), HalC2.Acp.driver(id) == "antigravity", do: HalC2.Acp.forget(id)
          HalC2.Settings.notify_providers()

          publish(state, %{
            "phase" => "succeeded",
            "installedVersion" => version,
            "canRemove" => true,
            "message" => nil
          })

        {:error, detail} ->
          publish(state, %{"phase" => "failed", "message" => detail})
      end

    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{op: %{pid: pid, id: op}} = state)
      when reason != :normal do
    Logger.warning("Antigravity install failed: #{inspect(reason)}")
    File.rm_rf(staging(op))

    {:noreply,
     publish(%{state | op: nil}, %{
       "phase" => "failed",
       "message" => "The Antigravity installation failed. Try again."
     })}
  end

  def handle_info({:halc2_settings, _node, settings}, state) do
    seen = seen(settings)

    changed =
      for {id, value} <- seen, Map.get(state.seen, id) not in [nil, value], do: id

    if changed != [] do
      # Off this process: a session may take a moment to stop.
      Task.start(fn ->
        for id <- changed do
          Antigravity.stop_sessions(id)
          HalC2.Acp.forget(id)
        end

        HalC2.Settings.notify_providers()
      end)
    end

    {:noreply, %{state | seen: seen}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _}, state) do
    {:noreply, %{state | watchers: Map.reject(state.watchers, fn {_key, r} -> r == ref end)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # What of each Antigravity instance's settings decides how its sessions run.
  defp seen(_settings) do
    for id <- HalC2.Acp.instances(), HalC2.Acp.driver(id) == "antigravity", into: %{} do
      {id, {HalC2.Acp.enabled?(id), Antigravity.config(id)}}
    end
  end

  # --- the install -------------------------------------------------------------------

  defp install(release, server, op) do
    report = fn patch -> send(server, {:install_progress, op, patch}) end
    {exe, harness} = Antigravity.names()
    versions = Antigravity.versions_dir()
    File.mkdir_p!(versions)
    report.(%{"canRemove" => true})
    target = Path.join(versions, release.sha256)

    if File.dir?(target) do
      report.(%{"phase" => "verifying", "message" => "Checking the installed runtime."})

      with {:ok, found} <- Antigravity.completed(release.sha256),
           :ok <- validate(found.executable, found.harness, release),
           do: activate(release)
    else
      staging = staging(op)
      archive = Path.join(staging, "runtime.zip")
      files = Path.join(staging, "files")
      File.rm_rf!(staging)
      File.mkdir_p!(files)
      {_, exe_bytes} = release.executable
      {_, harness_bytes} = release.harness

      with :ok <- free_space(release.archive_bytes + exe_bytes + harness_bytes + @margin),
           :ok <- download(release, archive, report),
           :ok <- verify(archive, release),
           _ <-
             report.(%{"phase" => "extracting", "message" => "Extracting the verified runtime."}),
           :ok <- extract(archive, files, release),
           _ <-
             report.(%{"phase" => "verifying", "message" => "Checking the downloaded runtime."}),
           :ok <- validate(Path.join(files, exe), Path.join(files, harness), release) do
        File.write!(
          Path.join(files, ".install-complete.json"),
          JSON.encode!(%{
            "releaseId" => release.sha256,
            "version" => release.version,
            "executable" => %{"name" => exe, "bytes" => exe_bytes},
            "harness" => %{"name" => harness, "bytes" => harness_bytes}
          })
        )

        File.rename!(files, target)
        activate(release)
      end
    end
  end

  defp staging(op), do: Path.join(Antigravity.managed_dir(), ".staging-#{op}")

  defp free_space(required) do
    probe = Application.get_env(:hal_c2, :antigravity_free_space, &available/1)

    case probe.(Antigravity.managed_dir()) do
      free when is_integer(free) and free < required ->
        {:error,
         "Antigravity needs at least #{ceil(required / (1024 * 1024))} MiB of free space to install."}

      _ ->
        :ok
    end
  end

  # `df` in kilobyte blocks; an unknown answer does not stop the install.
  defp available(dir) do
    case System.cmd("df", ["-Pk", dir], stderr_to_stdout: true) do
      {out, 0} ->
        with [_header, line | _] <- String.split(out, "\n", trim: true),
             [_, _, _, avail | _] <- String.split(line),
             {kb, ""} <- Integer.parse(avail),
             do: kb * 1024,
             else: (_ -> nil)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp download(release, archive, report) do
    fetch = Application.get_env(:hal_c2, :antigravity_fetch, &http_fetch/3)
    # Monotonic time can be negative: start far enough back that the first call reports.
    last = :atomics.new(1, [])
    :atomics.put(last, 1, System.monotonic_time(:millisecond) - 1_000)

    progress = fn bytes ->
      now = System.monotonic_time(:millisecond)

      if bytes >= release.archive_bytes or now - :atomics.get(last, 1) > 250 do
        :atomics.put(last, 1, now)
        report.(%{"downloadedBytes" => min(bytes, release.archive_bytes)})
      end
    end

    fetch.(release.url, archive, progress)
  end

  # Google's download, streamed to disk.
  defp http_fetch(url, dest, progress) do
    {:ok, file} = File.open(dest, [:write, :binary])

    try do
      {:ok, ref} =
        :httpc.request(:get, {String.to_charlist(url), []}, [timeout: :infinity], [
          {:sync, false},
          {:stream, :self}
        ])

      receive_body(ref, file, 0, progress)
    after
      File.close(file)
    end
  end

  defp receive_body(ref, file, bytes, progress) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        receive_body(ref, file, bytes, progress)

      {:http, {^ref, :stream, chunk}} ->
        IO.binwrite(file, chunk)
        bytes = bytes + byte_size(chunk)
        progress.(bytes)
        receive_body(ref, file, bytes, progress)

      {:http, {^ref, :stream_end, _headers}} ->
        :ok

      {:http, {^ref, {{_, status, _}, _headers, _body}}} ->
        {:error, "The Antigravity download failed (HTTP #{status})."}

      {:http, {^ref, {:error, _reason}}} ->
        {:error, "The Antigravity download failed. Check the connection and try again."}
    after
      120_000 -> {:error, "The Antigravity download stalled. Try again."}
    end
  end

  defp verify(archive, release) do
    hash =
      File.stream!(archive, 1024 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if File.stat!(archive).size == release.archive_bytes and hash == release.sha256,
      do: :ok,
      else:
        {:error,
         "The Antigravity download failed its size or SHA-256 check. Nothing was installed."}
  end

  defp extract(archive, dir, release) do
    {exe, exe_bytes} = release.executable
    {harness, harness_bytes} = release.harness
    expected = %{exe => exe_bytes, harness => harness_bytes}

    with {:ok, [_comment | entries]} <- :zip.list_dir(String.to_charlist(archive)),
         true <-
           length(entries) == 2 ||
             {:error,
              "The archive must contain exactly the Antigravity executable and its harness."},
         true <-
           Enum.all?(entries, fn {:zip_file, name, info, _, _, _} ->
             expected[to_string(name)] == elem(info, 1)
           end) ||
             {:error, "The archive contains an unexpected, unsafe, or incorrectly sized member."},
         {:ok, _} <- :zip.extract(String.to_charlist(archive), cwd: String.to_charlist(dir)) do
      for name <- [exe, harness], do: File.chmod!(Path.join(dir, name), 0o755)
      :ok
    else
      {:error, detail} when is_binary(detail) -> {:error, detail}
      _ -> {:error, "The archive contains an unexpected, unsafe, or incorrectly sized member."}
    end
  end

  # The runtime starts here and says it is the release it should be.
  defp validate(executable, harness, release) do
    home = Path.join(System.tmp_dir!(), "hal-c2-agy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    env = [
      {"GEMINI_HOME", home},
      {"TMPDIR", home},
      {"ANTIGRAVITY_HARNESS_PATH", harness},
      {"AGY_ACP_FORCE_FILE_STORAGE", "1"},
      {"PYTHONUNBUFFERED", "1"}
    ]

    args = if elem(Antigravity.platform(), 0) == "linux", do: ["--uid="], else: []

    try do
      case HalC2.JsonRpc.Connection.start_link(
             cmd: [executable | args],
             handler: self(),
             cd: home,
             env: env,
             dialect: :v2
           ) do
        {:ok, conn} ->
          try do
            case HalC2.JsonRpc.Connection.call(
                   conn,
                   "initialize",
                   HalC2.Acp.initialize_params(),
                   60_000
                 ) do
              {:ok, init} ->
                if expected?(init, release),
                  do: :ok,
                  else:
                    {:error,
                     "The downloaded runtime did not identify as the expected Google Antigravity release."}

              {:error, _} ->
                {:error,
                 "The downloaded Antigravity runtime could not start in this environment."}
            end
          after
            HalC2.JsonRpc.Connection.stop(conn)
          end

        {:error, _} ->
          {:error, "The downloaded Antigravity runtime could not start in this environment."}
      end
    after
      File.rm_rf(home)
    end
  end

  defp expected?(init, release) do
    caps = init["agentCapabilities"] || %{}

    get_in(init, ["agentInfo", "name"]) == "antigravity-acp" and
      get_in(init, ["agentInfo", "version"]) == release.version and
      init["protocolVersion"] in [1, 2] and caps["loadSession"] == true and
      is_map(get_in(caps, ["sessionCapabilities", "resume"])) and
      is_map(get_in(caps, ["auth", "logout"])) and
      Enum.any?(init["authMethods"] || [], &(&1["id"] == "oauth-personal"))
  end

  defp activate(release) do
    File.write!(Antigravity.active_path(), JSON.encode!(%{"releaseId" => release.sha256}))
    {:ok, release.version}
  end

  # --- leases ------------------------------------------------------------------------

  # Sessions and sign-ins of any Antigravity instance hold the runtime.
  defp in_use? do
    Enum.any?(HalC2.Acp.instances(), fn id ->
      HalC2.Acp.driver(id) == "antigravity" and
        (Antigravity.sessions(id) != [] or HalC2.ProviderAuth.signing_in?(id))
    end)
  end

  defp protected? do
    managed = Antigravity.managed_dir()

    Enum.any?(HalC2.Acp.instances(), fn id ->
      path = HalC2.Acp.driver(id) == "antigravity" && Antigravity.config(id)["binaryPath"]
      is_binary(path) and String.starts_with?(Path.expand(path), managed <> "/")
    end)
  end

  defp publish(state, patch) do
    state = %{state | state: Map.merge(state.state, patch)}

    for {{pid, instance}, _} <- state.watchers,
        do: send(pid, {:halc2_provider_install, instance, state.state})

    state
  end

  defp error(instance, operation, detail) do
    {:error,
     %{
       "_tag" => "ProviderSetupError",
       "instanceId" => instance,
       "operation" => operation,
       "detail" => detail,
       "message" => detail
     }}
  end
end
