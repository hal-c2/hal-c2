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

  require Logger

  @uuid4 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

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

    case File.mkdir_p(dir) do
      :ok ->
        live_add(dir)
        {:ok, dir}

      _ ->
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

  defp live, do: :persistent_term.get({__MODULE__, :live}, MapSet.new())

  defp live_add(dir), do: :persistent_term.put({__MODULE__, :live}, MapSet.put(live(), dir))

  defp live_remove(dir),
    do: :persistent_term.put({__MODULE__, :live}, MapSet.delete(live(), dir))

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
