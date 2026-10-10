defmodule HalC2.Connect.RelayClient do
  @moduledoc """
  The relay client (`cloudflared`) a managed HAL-C2 Connect tunnel runs through:
  where it is (`cloud.getRelayClientStatus`) and installing the pinned release
  into the HAL-C2 home (`cloud.installRelayClient`).

  It is found, in order, at `HAL_C2_CLOUDFLARED_PATH`, at the MC's managed
  install, then on the `PATH`. Installs from several clients, or several MCs on
  one home, take turns through a lock file next to the managed binary.

  Tests replace the host through app env: `:relay_client_env` (a map standing in
  for the process environment), `:relay_client_target` (`{platform, arch}`),
  `:relay_client_assets` (target → asset) and `:relay_client_lock`
  (`[retries: n, delay: ms]`).
  """

  @version "2026.5.2"
  @override_env "HAL_C2_CLOUDFLARED_PATH"
  @stale_lock_ms 5 * 60 * 1_000

  @assets %{
    "darwin-arm64" => %{
      "url" =>
        "https://github.com/cloudflare/cloudflared/releases/download/2026.5.2/cloudflared-darwin-arm64.tgz",
      "sha256" => "ba94054c9fd4297645093d59d51442e5e546d07bb0516120e694a13d5b216d38",
      "archive" => "tgz"
    },
    "darwin-x64" => %{
      "url" =>
        "https://github.com/cloudflare/cloudflared/releases/download/2026.5.2/cloudflared-darwin-amd64.tgz",
      "sha256" => "7240f709506bc2c1eb9da4d89cf2555499c60280ecb854b7d80e8f17d4b7903d",
      "archive" => "tgz"
    },
    "linux-arm64" => %{
      "url" =>
        "https://github.com/cloudflare/cloudflared/releases/download/2026.5.2/cloudflared-linux-arm64",
      "sha256" => "5a4e8ce2701105271412059f44b6a0bf1ae4542b4d98ff3180c0c019443a5815",
      "archive" => "binary"
    },
    "linux-x64" => %{
      "url" =>
        "https://github.com/cloudflare/cloudflared/releases/download/2026.5.2/cloudflared-linux-amd64",
      "sha256" => "5286698547f03df745adb2355f04c12dde52ef425491e81f433642d695521886",
      "archive" => "binary"
    },
    "win32-x64" => %{
      "url" =>
        "https://github.com/cloudflare/cloudflared/releases/download/2026.5.2/cloudflared-windows-amd64.exe",
      "sha256" => "20b9638f685333d623798e733effbad2487093f15ba592f6c7752360ff3b7ab7",
      "archive" => "binary"
    }
  }

  def version, do: @version

  @doc "`RelayClientStatus`: available (with where from), missing, or unsupported."
  def resolve do
    {platform, arch} = target()

    cond do
      override = env(@override_env) ->
        if executable?(override), do: available(override, "override"), else: missing()

      executable?(managed_path()) ->
        available(managed_path(), "managed")

      found = on_path() ->
        available(found, "path")

      asset() ->
        missing()

      true ->
        %{
          "status" => "unsupported",
          "platform" => platform,
          "arch" => arch,
          "version" => @version
        }
    end
  end

  @doc "The executable to run, or nil when there is none."
  def executable do
    case resolve() do
      %{"status" => "available", "executablePath" => path} -> path
      _ -> nil
    end
  end

  @doc """
  Installs the pinned release unless one is already available. `report` gets each
  `RelayClientInstallProgressEvent` stage as it starts. `{:ok, status}` or
  `{:error, %{"reason" => reason, "message" => message}}` (`RelayClientInstallFailedError`).
  """
  def install(report \\ fn _ -> :ok end) do
    stage = &report.(%{"type" => "progress", "stage" => &1})
    stage.("checking")

    case resolve() do
      %{"status" => "available"} = status ->
        {:ok, status}

      _ ->
        cond do
          env(@override_env) ->
            failure("override_missing", "#{@override_env} does not point to an executable file.")

          asset() == nil ->
            {platform, arch} = target()

            failure(
              "unsupported_platform",
              "HAL-C2 does not provide a managed relay client binary for #{platform}-#{arch}."
            )

          true ->
            install_managed(asset(), stage)
        end
    end
  end

  @doc """
  `cloud.installRelayClient` off the caller: sends `pid` `{:hal_c2_relay_client_install, mc, event}`
  for each progress event, then `complete` with the status, or `{:error, detail}`.
  """
  def start_install(pid) do
    Task.start(fn ->
      event =
        case install(&send(pid, {:hal_c2_relay_client_install, node(), &1})) do
          {:ok, status} -> %{"type" => "complete", "status" => status}
          {:error, detail} -> {:error, detail}
        end

      send(pid, {:hal_c2_relay_client_install, node(), event})
    end)

    :ok
  end

  defp install_managed(asset, stage) do
    dir = Path.dirname(managed_path())
    lock = managed_path() <> ".lock"

    with :ok <- write_step(File.mkdir_p(dir), "Could not create the relay client tool directory."),
         stage.("waiting_for_lock"),
         :ok <- acquire(lock, lock_setting(:retries, 100)) do
      try do
        case resolve() do
          %{"status" => "available"} = status -> {:ok, status}
          _ -> install_locked(asset, dir, stage)
        end
      after
        File.rm(lock)
      end
    end
  end

  defp install_locked(asset, dir, stage) do
    staging = Path.join(dir, ".install-#{System.unique_integer([:positive])}")
    binary = Path.join(staging, executable_name())

    try do
      with :ok <-
             write_step(
               File.mkdir_p(staging),
               "Could not create the relay client tool directory."
             ),
           {:ok, bytes} <- download(asset, stage),
           stage.("installing"),
           :ok <- unpack(asset, bytes, staging, binary),
           stage.("validating"),
           :ok <- validate(binary),
           stage.("activating"),
           :ok <- activate(binary) do
        {:ok, available(managed_path(), "managed")}
      end
    after
      File.rm_rf(staging)
    end
  end

  defp download(asset, stage) do
    stage.("downloading")

    case :httpc.request(:get, {String.to_charlist(asset["url"]), []}, http_options(),
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, bytes}} ->
        stage.("verifying")

        if Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == asset["sha256"],
          do: {:ok, bytes},
          else:
            failure(
              "invalid_checksum",
              "Downloaded relay client checksum did not match the pinned release."
            )

      _ ->
        failure("download_failed", "Could not download the relay client.")
    end
  end

  defp unpack(%{"archive" => "tgz"}, bytes, staging, _binary) do
    archive = Path.join(staging, "cloudflared.tgz")

    with :ok <-
           write_step(File.write(archive, bytes), "Could not write the relay client download.") do
      case :erl_tar.extract(String.to_charlist(archive), [
             :compressed,
             {:cwd, String.to_charlist(staging)}
           ]) do
        :ok -> make_executable(Path.join(staging, executable_name()))
        _ -> failure("write_failed", "Could not extract the relay client.")
      end
    end
  end

  defp unpack(_asset, bytes, _staging, binary) do
    with :ok <-
           write_step(File.write(binary, bytes), "Could not write the relay client download."),
         do: make_executable(binary)
  end

  defp make_executable(binary) do
    if windows?(),
      do: :ok,
      else: write_step(File.chmod(binary, 0o755), "Could not make the relay client executable.")
  end

  defp validate(binary) do
    case System.cmd(binary, ["version"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> failure("validation_failed", "The downloaded relay client binary did not run.")
    end
  rescue
    _ -> failure("validation_failed", "The downloaded relay client binary did not run.")
  end

  defp activate(binary) do
    staged = "#{managed_path()}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- write_step(File.rename(binary, staged), "Could not stage the relay client.") do
      case File.rename(staged, managed_path()) do
        :ok ->
          :ok

        error ->
          File.rm(staged)
          write_step(error, "Could not activate the relay client.")
      end
    end
  end

  # Taken by creating the lock file; one older than five minutes was left by a
  # crashed install and is broken.
  defp acquire(_lock, 0),
    do: failure("install_locked", "Another relay client installation is still in progress.")

  defp acquire(lock, retries) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)
        :ok

      {:error, :eexist} ->
        now = System.os_time(:second)

        case File.stat(lock, time: :posix) do
          {:ok, %{mtime: mtime}} when (now - mtime) * 1_000 > @stale_lock_ms ->
            File.rm(lock)
            acquire(lock, retries)

          _ ->
            receive do
            after
              lock_setting(:delay, 100) -> acquire(lock, retries - 1)
            end
        end

      {:error, _} ->
        failure("write_failed", "Could not acquire the relay client installation lock.")
    end
  end

  defp write_step(:ok, _message), do: :ok
  defp write_step({:error, _}, message), do: failure("write_failed", message)

  defp failure(reason, message), do: {:error, %{"reason" => reason, "message" => message}}

  defp available(path, source),
    do: %{
      "status" => "available",
      "executablePath" => path,
      "source" => source,
      "version" => @version
    }

  defp missing, do: %{"status" => "missing", "version" => @version}

  defp managed_path do
    {platform, arch} = target()

    Path.join([
      HalC2.Paths.cache_dir(),
      "tools",
      "cloudflared",
      @version,
      "#{platform}-#{arch}",
      executable_name()
    ])
  end

  defp on_path do
    separator = if windows?(), do: ";", else: ":"

    (env("PATH") || "")
    |> String.split(separator)
    |> Enum.map(&(&1 |> String.trim() |> String.trim("\"")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.join(&1, executable_name()))
    |> Enum.find(&executable?/1)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> windows?() or Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp asset do
    {platform, arch} = target()
    Map.get(Application.get_env(:hal_c2, :relay_client_assets, @assets), "#{platform}-#{arch}")
  end

  defp target do
    Application.get_env(:hal_c2, :relay_client_target) || host_target()
  end

  defp host_target do
    platform =
      case :os.type() do
        {:win32, _} -> "win32"
        {:unix, :darwin} -> "darwin"
        {:unix, os} -> Atom.to_string(os)
      end

    arch =
      case :erlang.system_info(:system_architecture) |> to_string() do
        "aarch64" <> _ -> "arm64"
        "arm64" <> _ -> "arm64"
        "x86_64" <> _ -> "x64"
        other -> other |> String.split("-") |> hd()
      end

    {platform, arch}
  end

  defp windows?, do: elem(target(), 0) == "win32"
  defp executable_name, do: if(windows?(), do: "cloudflared.exe", else: "cloudflared")

  defp env(name) do
    value =
      case Application.get_env(:hal_c2, :relay_client_env) do
        %{} = env -> Map.get(env, name)
        nil -> System.get_env(name)
      end

    case value && String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp lock_setting(key, default),
    do: Keyword.get(Application.get_env(:hal_c2, :relay_client_lock, []), key, default)

  defp http_options do
    [
      timeout: :timer.minutes(5),
      connect_timeout: 15_000,
      autoredirect: true,
      ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 4]
    ]
  end
end
