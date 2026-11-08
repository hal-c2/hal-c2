defmodule HalC2.Codex.Home do
  @moduledoc """
  Where a Codex instance keeps its files.

  An instance's `homePath` is its Codex home. With a `shadowHomePath` too, the
  instance is another account on the same home: Codex runs in the shadow home, whose
  entries are links into the shared home, so every such account sees the same
  sessions, settings, skills and plugins. Only the login and the model cache
  (`auth.json`, `models_cache.json`) are the shadow home's own files, and Codex's
  logs, memories and scratch stay local to it.
  """

  require Logger

  # Created in the shared home when missing, so an account that starts first links them.
  # `thread-writer-locks` is shared on purpose: Codex keeps one writer per thread
  # through it, which only holds when every account on the home sees the same locks.
  @shared_directories ~w(sessions archived_sessions sqlite shell_snapshots worktrees skills
                         plugins cache logs mcp-oauth-locks thread-writer-locks)
  # `auth.lock` guards the account's own login, so it is the shadow home's own too.
  @private ~w(auth.json models_cache.json auth.lock)
  @local ~w(log memories tmp)
  # Runtime directories Codex may have made in the shadow home before it was linked,
  # and its sqlite maintenance lock, which the shared home's replaces.
  @replaceable ~w(mcp-oauth-locks .sqlite-maintenance.lock)

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
      # A ChatGPT account connected through HAL-C2 signs in in a shadow home of
      # the instance's own (`HalC2.Codex.ChatGpt.home/1`), over the home Codex
      # would use, an instance `CODEX_HOME` included: so its threads are the CLI
      # account's threads too, and the CLI's own login is never touched.
      managed?(instance) ->
        shared = shared(instance) || default_home()
        shadow = HalC2.Codex.ChatGpt.home(instance)
        with :ok <- link(shared, shadow), do: {:ok, [{"CODEX_HOME", shadow}]}

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

  @doc """
  The instance's own variables for Codex (`HalC2.Settings.instance_env/1`), as a
  list to follow `env/1`'s. A managed instance's `CODEX_HOME` is left out: it
  names the shared home its shadow is made over, and Codex must run in the shadow.
  """
  @spec instance_env(String.t()) :: [{String.t(), String.t()}]
  def instance_env(instance) do
    env = Enum.to_list(HalC2.Settings.instance_env(instance))
    if managed?(instance), do: Enum.reject(env, &match?({"CODEX_HOME", _}, &1)), else: env
  end

  # A connected account's login lives in the MC-owned home (`ChatGpt.home/1`), which
  # `ChatGpt.adopt/3` and `move/1` read and write: a `shadowHomePath` set before the
  # account was connected does not take its place.
  defp managed?(instance), do: HalC2.Codex.ChatGpt.managed?(instance)

  @doc """
  The home shared by every account of `instance`'s Codex home, or nil for the
  default. A `CODEX_HOME` set only in the instance's environment variables is
  its home too: two instances pointing it at different folders are different
  homes, however their home settings read.
  """
  def shared(instance) do
    case HalC2.Settings.instance_env(instance)["CODEX_HOME"] do
      home when is_binary(home) and home != "" ->
        expand(home)

      _ ->
        case HalC2.Settings.instance_setting(instance, "homePath") do
          nil -> nil
          home -> expand(home)
        end
    end
  end

  # Codex's own default: `$CODEX_HOME`, else `~/.codex`.
  defp default_home do
    case System.get_env("CODEX_HOME") do
      home when is_binary(home) and home != "" -> expand(home)
      _ -> Path.join(HalC2.Paths.user_home(), ".codex")
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

  # The homes are the instance's own `homePath`/`shadowHomePath` settings, which only the
  # operator sets; the entry names are the shared home's own listing or fixed names here.
  # sobelow_skip ["Traversal.FileModule"]
  defp link(shared, shadow) do
    File.mkdir_p!(shadow)
    for directory <- @shared_directories, do: File.mkdir_p!(Path.join(shared, directory))

    # Finder metadata in the shadow home is not the account's data: it goes, so a
    # folder a user browsed to is set up as if it were empty.
    File.rm(Path.join(shadow, ".DS_Store"))

    # A model cache that is a link would be the shared home's: it goes. So does a
    # linked `auth.lock`: the login lock is each account's own. A login that is a
    # link refuses the home instead: removing it could lose the account's own.
    if symlink?(Path.join(shadow, "models_cache.json")),
      do: File.rm!(Path.join(shadow, "models_cache.json"))

    if symlink?(Path.join(shadow, "auth.lock")),
      do: File.rm!(Path.join(shadow, "auth.lock"))

    if symlink?(Path.join(shadow, "auth.json")) do
      throw(
        {:shadow_home,
         "Codex shadow home private entry 'auth.json' at '#{Path.join(shadow, "auth.json")}' must be a real file, not a symlink."}
      )
    end

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
  catch
    {:shadow_home, message} -> {:error, message}
  end

  # As `link/2`: both paths are below the operator's configured homes.
  # sobelow_skip ["Traversal.FileModule"]
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

      # A shadow home's own writer locks are replaced only once none is held: a
      # lock still there may belong to a live writer, so the folder stays (with
      # a warning) until a later preparation finds it empty.
      {:error, _not_a_link} when name == "thread-writer-locks" ->
        case File.ls(link) do
          {:ok, []} ->
            File.rm_rf!(link)
            File.ln_s!(target, link)
            :ok

          _ ->
            Logger.warning(
              "codex shadow home #{link} kept: it still holds thread writer locks; " <>
                "it joins the shared home's locks once they are gone"
            )

            :ok
        end

      {:error, _not_a_link} when name in @replaceable ->
        File.rm_rf!(link)
        File.ln_s!(target, link)
        :ok

      {:error, _not_a_link} ->
        {:error,
         "Cannot create Codex shadow home entry '#{name}' because '#{link}' already exists and is not a symlink."}
    end
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
end
