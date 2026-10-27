defmodule HalC2.Acp.Antigravity.SessionFiles do
  @moduledoc """
  The temporary files an Antigravity process leaves in its instance's
  profile, ported from upstream T3 Code's `AntigravitySessionFiles.ts`
  (pingdotgg/t3code#2829).

  Each process unpacks into its own `run-` directory under the profile's
  temp folder, removed when the process ends; directories left by an MC
  that was killed are swept the next time a process starts. A disposable
  session's conversation files are removed with it, but only when the
  conversation stored under its id was recorded for that session's own
  folder: a conversation HAL-C2 did not create is left alone. Removal is
  best effort and never fails the session it follows.
  """

  use GenServer

  require Logger

  @uuid4 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  @live_table :hal_c2_antigravity_live_temp

  # This process only owns the live-directories table below: an ETS table
  # dies with its owner, and the processes that launch runtimes are
  # short-lived. In the MC it runs under `HalC2.Supervisor`; anywhere else
  # the first use starts it, unlinked, so a launcher never owns the table.
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    if :ets.whereis(@live_table) == :undefined,
      do: :ets.new(@live_table, [:named_table, :public, :set])

    {:ok, %{}}
  end

  @doc "The profile's temp folder, where per-process runtime directories live."
  def temp_dir(profile), do: Path.join([profile, "antigravity-acp", "tmp"])

  @doc """
  A fresh per-process runtime directory under the profile's temp folder,
  sweeping directories no live process holds first. `{:error, message}`
  when it cannot be made.
  """
  def runtime_dir(profile) do
    tmp = temp_dir(profile)
    sweep(tmp)
    dir = Path.join(tmp, "run-#{System.unique_integer([:positive])}")
    # Held before it exists, so another launch's sweep cannot take it in between.
    live_add(dir)

    case File.mkdir_p(dir) do
      :ok ->
        {:ok, dir}

      _ ->
        live_remove(dir)
        {:error, "Could not create an Antigravity runtime temp directory."}
    end
  end

  @doc "Removes a runtime directory `runtime_dir/1` made; failure is only logged."
  def release(dir) when is_binary(dir) do
    live_remove(dir)

    case File.rm_rf(dir) do
      {:ok, _} -> :ok
      _ -> Logger.warning("Could not remove an Antigravity runtime temp directory.")
    end

    :ok
  end

  def release(_dir), do: :ok

  # Runtime directories no live process of this MC holds: a killed MC's live
  # set died with it, so everything it left is swept here.
  defp sweep(tmp) do
    live = live()

    for path <- Path.wildcard(Path.join(tmp, "run-*")),
        path not in live,
        File.dir?(path) do
      case File.rm_rf(path) do
        {:ok, _} -> :ok
        _ -> Logger.warning("Could not remove leftover Antigravity runtime temp files.")
      end
    end

    :ok
  end

  # The live set is an ETS table: inserts and deletes are atomic per key, so
  # concurrent launches cannot lose each other's directories (a
  # read-modify-write set could, and the loser's runtime would be swept from
  # under its process).
  defp live do
    table()
    :ets.select(@live_table, [{{:"$1", true}, [], [:"$1"]}]) |> MapSet.new()
  end

  defp live_add(dir) do
    table()
    :ets.insert(@live_table, {dir, true})
    :ok
  end

  defp live_remove(dir) do
    table()
    :ets.delete(@live_table, dir)
    :ok
  end

  defp table do
    if :ets.whereis(@live_table) == :undefined do
      case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    @live_table
  end

  @doc """
  Removes the conversation files of a disposable session that ran in `cwd`:
  its database and `brain` folder under the profile. The conversation's own
  recorded folder must be `cwd`; anything else is left alone.
  """
  def remove_session_files(profile, session_id, cwd)
      when is_binary(session_id) and is_binary(cwd) do
    if Regex.match?(@uuid4, session_id) do
      acp = Path.join(profile, "antigravity-acp")
      base = Path.join([acp, "conversations", session_id])

      with {:ok, body} <- File.read(base <> ".meta"),
           {:ok, %{"cwd" => ^cwd}} <- JSON.decode(body) do
        results =
          for suffix <- [".db", ".db-wal", ".db-shm", ".db-journal", ".meta"],
              do: File.rm(base <> suffix)

        brain = File.rm_rf(Path.join([acp, "brain", session_id]))

        if Enum.any?(results, &match?({:error, reason} when reason != :enoent, &1)) or
             match?({:error, _, _}, brain),
           do: Logger.warning("Could not remove temporary Antigravity session files.")

        :ok
      else
        _ -> :ok
      end
    end

    :ok
  rescue
    _ ->
      Logger.warning("Could not remove temporary Antigravity session files.")
      :ok
  end

  def remove_session_files(_profile, _session_id, _cwd), do: :ok
end
