defmodule HalC2.ProviderInstall do
  @moduledoc """
  What the MC's managed provider installers share (`HalC2.Acp.Antigravity.Installation`,
  `HalC2.Codex.Installation`): the host's platform, the streamed download with its
  progress, the SHA-256 of what arrived, the subscribers of an install's
  `ProviderInstallState`, and the `ProviderSetupError` an install RPC answers with.

  An installer's server state is a map with `state` (the `ProviderInstallState`) and
  `watchers` (`{pid, instance} => HalC2.Watchers` entry); `subscribe/4`,
  `unsubscribe/4`, `down/2` and `publish/3` keep those.
  """

  @doc "This host's OS and CPU as `{\"linux\" | \"darwin\" | \"win32\", \"x64\" | \"arm64\"}`."
  def host_platform, do: {os(), arch(to_string(:erlang.system_info(:system_architecture)))}

  defp os do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:win32, _} -> "win32"
      {:unix, name} -> to_string(name)
    end
  end

  defp arch("x86_64" <> _), do: "x64"
  defp arch("amd64" <> _), do: "x64"
  defp arch("aarch64" <> _), do: "arm64"
  defp arch("arm64" <> _), do: "arm64"
  defp arch(other), do: other |> String.split("-") |> hd()

  @doc """
  Streams `url` to `dest`, calling `progress.(bytes)` as bytes arrive, at most every
  250 ms and once all `total` have. `:ok` once the body ended, else `{:error,
  {:status, code}}` for a reply other than 200, `{:error, :interrupted}` for a
  connection that failed or closed early, `{:error, :stalled}` when nothing arrived
  for `:stall_ms` (default two minutes) and `{:error, :timeout}` when the whole
  download took longer than `:deadline_ms` (default none).
  """
  # `dest` is the installer's own staging path.
  # sobelow_skip ["Traversal.FileModule"]
  def fetch(url, dest, total, progress, opts \\ []) do
    stall = Keyword.get(opts, :stall_ms, 120_000)
    deadline = make_ref()

    timer =
      case Keyword.get(opts, :deadline_ms, :infinity) do
        :infinity -> nil
        ms -> Process.send_after(self(), deadline, ms)
      end

    {:ok, file} = File.open(dest, [:write, :binary])
    report = throttled(total, progress)

    try do
      case :httpc.request(
             :get,
             {String.to_charlist(url), []},
             [timeout: :infinity, ssl: :httpc.ssl_verify_host_options(true)],
             [{:sync, false}, {:stream, :self}]
           ) do
        {:ok, ref} ->
          result = receive_body(ref, deadline, stall, file, 0, report)
          if result != :ok, do: :httpc.cancel_request(ref)
          result

        {:error, _reason} ->
          {:error, :interrupted}
      end
    after
      File.close(file)
      if timer, do: Process.cancel_timer(timer)

      receive do
        ^deadline -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp receive_body(ref, deadline, stall, file, bytes, report) do
    receive do
      ^deadline ->
        {:error, :timeout}

      {:http, {^ref, :stream_start, _headers}} ->
        receive_body(ref, deadline, stall, file, bytes, report)

      {:http, {^ref, :stream, chunk}} ->
        IO.binwrite(file, chunk)
        bytes = bytes + byte_size(chunk)
        report.(bytes)
        receive_body(ref, deadline, stall, file, bytes, report)

      {:http, {^ref, :stream_end, _headers}} ->
        :ok

      {:http, {^ref, {{_, status, _}, _headers, _body}}} ->
        {:error, {:status, status}}

      {:http, {^ref, {:error, _reason}}} ->
        {:error, :interrupted}
    after
      stall -> {:error, :stalled}
    end
  end

  @doc "`progress` called at most every 250 ms, and always once `total` bytes have arrived."
  def throttled(total, progress) do
    # Monotonic time can be negative: start far enough back that the first call reports.
    last = :atomics.new(1, [])
    :atomics.put(last, 1, System.monotonic_time(:millisecond) - 1_000)

    fn bytes ->
      now = System.monotonic_time(:millisecond)

      if bytes >= total or now - :atomics.get(last, 1) > 250 do
        :atomics.put(last, 1, now)
        progress.(min(bytes, total))
      end
    end
  end

  @doc "The lowercase hex SHA-256 of the file at `path`."
  # sobelow_skip ["Traversal.FileModule"]
  def sha256(path) do
    File.stream!(path, 1024 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "Whether `path` is an executable regular file (of `bytes`, when given)."
  def executable?(path, bytes \\ nil) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size, mode: mode}} ->
        (bytes == nil or size == bytes) and Bitwise.band(mode, 0o111) != 0

      _ ->
        false
    end
  end

  @doc "The `ProviderSetupError` an install RPC refuses with."
  def error(instance, operation, detail) do
    {:error,
     %{
       "_tag" => "ProviderSetupError",
       "instanceId" => instance,
       "operation" => operation,
       "detail" => detail,
       "message" => detail
     }}
  end

  # --- subscribers ------------------------------------------------------------------

  @doc "Adds `pid` under `ref` as a watcher of `instance`'s install state."
  def subscribe(state, instance, pid, ref) do
    key = {pid, instance}

    watchers =
      Map.put(state.watchers, key, HalC2.Watchers.add_entry(state.watchers[key], pid, ref))

    %{state | watchers: watchers}
  end

  def unsubscribe(state, instance, pid, ref) do
    key = {pid, instance}

    case state.watchers do
      %{^key => entry} ->
        case HalC2.Watchers.remove_entry(entry, ref) do
          nil -> %{state | watchers: Map.delete(state.watchers, key)}
          entry -> %{state | watchers: Map.put(state.watchers, key, entry)}
        end

      _ ->
        state
    end
  end

  @doc "Forgets every watcher `pid` held, once it is down."
  def down(state, pid),
    do: %{state | watchers: Map.reject(state.watchers, &match?({{^pid, _}, _}, &1))}

  @doc "Merges `patch` into the install state and tells every watcher."
  def publish(state, patch) do
    state = %{state | state: Map.merge(state.state, patch)}

    for {{pid, instance}, entry} <- state.watchers,
        do: HalC2.Watchers.tell(pid, entry, {:hal_c2_provider_install, instance, state.state})

    state
  end
end
