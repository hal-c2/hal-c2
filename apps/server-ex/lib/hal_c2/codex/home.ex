defmodule HalC2.Codex.Home do
  @moduledoc """
  Where a Codex instance keeps its files (`CodexHomeLayout.ts` in the Node server).

  An instance's `homePath` is its Codex home. With a `shadowHomePath` too, the
  instance is another account on the same home: Codex runs in the shadow home, whose
  entries are links into the shared home, so every such account sees the same
  sessions, settings, skills and plugins. Only the login and the model cache
  (`auth.json`, `models_cache.json`) are the shadow home's own files, and Codex's
  logs, memories and scratch stay local to it.
  """

  # Created in the shared home when missing, so an account that starts first links them.
  @shared_directories ~w(sessions archived_sessions sqlite shell_snapshots worktrees skills
                         plugins cache logs mcp-oauth-locks)
  @private ~w(auth.json models_cache.json)
  @local ~w(log memories tmp)
  # Runtime directories Codex may have made in the shadow home before it was linked.
  @replaceable ~w(mcp-oauth-locks)

  @doc """
  The variables that point Codex at `instance`'s home: `{:ok, [{"CODEX_HOME", path}]}`
  (a shadow home is brought up to date first), `{:ok, []}` for Codex's default home,
  or `{:error, message}` when the shadow home cannot be made.
  """
  @spec env(String.t() | nil) :: {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def env(instance) do
    home = HalC2.Settings.instance_setting(instance, "homePath")
    shadow = HalC2.Settings.instance_setting(instance, "shadowHomePath")

    cond do
      shadow == nil and home == nil ->
        {:ok, []}

      shadow == nil ->
        {:ok, [{"CODEX_HOME", expand(home)}]}

      true ->
        shared = if home, do: expand(home), else: Path.join(HalC2.Paths.user_home(), ".codex")
        shadow = expand(shadow)
        with :ok <- link(shared, shadow), do: {:ok, [{"CODEX_HOME", shadow}]}
    end
  end

  @doc "The home shared by every account of `instance`'s Codex home, or nil for the default."
  def shared(instance) do
    case HalC2.Settings.instance_setting(instance, "homePath") do
      nil -> nil
      home -> expand(home)
    end
  end

  defp expand(path) do
    case String.trim(path) do
      "~" -> HalC2.Paths.user_home()
      "~/" <> rest -> Path.join(HalC2.Paths.user_home(), rest)
      path -> Path.expand(path)
    end
  end

  defp link(shared, shared),
    do:
      {:error,
       "Codex shadow home path '#{shared}' must be different from the shared home path '#{shared}'."}

  defp link(shared, shadow) do
    File.mkdir_p!(shadow)
    for directory <- @shared_directories, do: File.mkdir_p!(Path.join(shared, directory))

    # A login that is a link would be the shared home's: the account keeps its own.
    for name <- @private, symlink?(Path.join(shadow, name)), do: File.rm!(Path.join(shadow, name))

    shared
    |> File.ls!()
    |> Enum.reject(&(&1 in @private or &1 in @local))
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case link_entry(Path.join(shared, name), Path.join(shadow, name), name) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  rescue
    error in File.Error ->
      {:error, "Codex shadow home could not be prepared: " <> Exception.message(error)}
  end

  defp link_entry(target, link, name) do
    case :file.read_link_all(link) do
      {:ok, existing} ->
        if Path.expand(to_string(existing), Path.dirname(link)) != target do
          File.rm!(link)
          File.ln_s!(target, link)
        end

        :ok

      {:error, :enoent} ->
        File.ln_s!(target, link)

      {:error, _not_a_link} when name in @replaceable ->
        File.rm_rf!(link)
        File.ln_s!(target, link)

      {:error, _not_a_link} ->
        {:error,
         "Cannot create Codex shadow home entry '#{name}' because '#{link}' already exists and is not a symlink."}
    end
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
end
