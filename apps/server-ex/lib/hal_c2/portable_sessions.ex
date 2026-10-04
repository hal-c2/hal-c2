defmodule HalC2.PortableSessions do
  @moduledoc """
  An agent's own session carried with a thread to another machine, so the agent
  picks up where it left off instead of receiving a handoff.

  `export/3` reads the files the provider keeps for the thread's native session;
  `place/3` writes a copy where the destination's instance of that provider looks
  for sessions of the destination project, with every recorded working directory
  rewritten, and returns the `carriedSession` the thread's provider thread keeps
  until its next run branches a new session from the copy (`HalC2.Orchestration.Handoff`).

  Where each provider keeps its sessions:

    * Claude Code: `<CLAUDE_CONFIG_DIR or ~/.claude>/projects/<cwd, every other
      character a dash>/<id>.jsonl`, with sub-agent transcripts and saved tool results
      in `<id>/`. Its file history (`file-history/<id>`) is not carried.
    * Codex: `<CODEX_HOME or ~/.codex>/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`,
      whose `session_meta` and `turn_context` records carry the cwd.
    * Pi: `<PI_CODING_AGENT_SESSION_DIR or <PI_CODING_AGENT_DIR or ~/.pi/agent>/sessions>
      /--<cwd, slashes as dashes>--/<file>.jsonl`, whose header records the cwd.
    * A provider plugin that declares `native_sessions` says itself, with its
      `session_files/2` and `place_session/3` (`HalC2.Plugins.ProviderAdapter`).

  A copy never replaces a file already there: the machine keeps the copy it had, and
  since the destination branches a new session, no two sessions share an id.
  """

  require Logger
  alias HalC2.StreamState

  @drivers ~w(claudeAgent codex pi)

  @doc "Whether a provider driver's sessions can be carried."
  def carries?(driver), do: driver in @drivers or plugin(driver) != nil

  @doc """
  The session a thread carries: `%{driver, instanceId, providerThreadId, nativeId,
  cwd, files}` with each file as `{name, path on this machine}`, or nil when the
  thread's agent has no session this machine can carry.
  """
  def export(state, thread, cwd) do
    with %{} = provider_thread <- provider_thread(state, thread),
         driver = provider_thread["driver"],
         instance = provider_thread["providerInstanceId"] || driver,
         {native_id, [{_, main} | _] = found} <-
           session_files(driver, instance, provider_thread, cwd),
         true <- File.regular?(main) do
      %{
        "driver" => driver,
        "instanceId" => instance,
        "providerThreadId" => provider_thread["id"],
        "nativeId" => native_id,
        "cwd" => recorded_cwd(provider_thread, cwd),
        "files" => Enum.filter(found, fn {_name, path} -> File.regular?(path) end)
      }
    else
      _ -> nil
    end
  end

  @doc """
  Places a carried session (decoded: each file's bytes under `"data"`, or the file at
  `"path"` on this machine) for the project at `root`:
  `{%{providerThreadId, carriedSession} | nil, notes}`.
  """
  def place(%{"driver" => driver, "files" => [_ | _]} = session, root, archive) do
    cond do
      module = plugin(driver) -> place_plugin(module, session, root, archive)
      driver in @drivers -> place_own(session, root, archive)
      true -> {nil, []}
    end
  end

  def place(_session, _root, _archive), do: {nil, []}

  defp place_own(%{"driver" => driver, "files" => files} = session, root, archive) do
    instance = session["instanceId"] || driver
    from = session["cwd"]
    {base, main_name} = target(driver, instance, root, session)

    written =
      for %{"fileName" => name} = file <- files, safe?(name) do
        path = Path.join(base, name)

        # The machine keeps a copy it already has: moving back never overwrites it.
        unless File.exists?(path) do
          File.mkdir_p!(Path.dirname(path))
          copy(file, path, driver, from, root)
          File.chmod(path, 0o600)
        end

        {name, path}
      end

    case List.keyfind(written, main_name, 0) do
      {_, path} ->
        native_id = if driver == "pi", do: path, else: session["nativeId"]

        {%{
           "providerThreadId" => session["providerThreadId"],
           "carriedSession" => %{
             "driver" => driver,
             "instanceId" => instance,
             "nativeId" => native_id,
             "path" => path,
             "from" => get_in(archive, ["thread", "machine"])
           }
         }, []}

      nil ->
        {nil, []}
    end
  end

  # The plugin places the copy itself; the next run continues from the id it answers.
  defp place_plugin(module, %{"driver" => driver} = session, root, archive) do
    files = for %{"fileName" => name} = file <- session["files"], safe?(name), do: file

    placed =
      plugin_call(fn ->
        HalC2.ThreadArchive.files_on_disk(files, &module.place_session(&1, session["cwd"], root))
      end)

    case placed do
      {:ok, native_id} when is_binary(native_id) ->
        {%{
           "providerThreadId" => session["providerThreadId"],
           "carriedSession" => %{
             "driver" => driver,
             "instanceId" => session["instanceId"] || driver,
             "nativeId" => native_id,
             "path" => nil,
             "from" => get_in(archive, ["thread", "machine"])
           }
         }, []}

      _ ->
        {nil, []}
    end
  end

  # A plugin that fails leaves the session behind: the thread still moves, with the handoff.
  defp plugin_call(fun) do
    fun.()
  catch
    kind, reason ->
      Logger.warning(
        "a provider plugin could not carry a session: #{Exception.format_banner(kind, reason)}"
      )

      nil
  end

  # The module of the provider plugin serving `driver` when it declares native sessions
  # and says where they live and how a copy is placed.
  defp plugin(driver) do
    with %{} = provider <- HalC2.Plugins.declared(driver),
         true <- :native_sessions in List.wrap(provider[:capabilities]),
         {:ok, _driver, module} <- HalC2.Plugins.provider(driver),
         true <- function_exported?(module, :session_files, 2),
         true <- function_exported?(module, :place_session, 3) do
      module
    else
      _ -> nil
    end
  end

  # --- source ----------------------------------------------------------------------

  # The provider thread the thread's agent runs on: the active one, else the latest.
  defp provider_thread(state, thread) do
    threads = StreamState.get(state, "provider-thread")

    threads[thread["activeProviderThreadId"]] ||
      threads
      |> Map.values()
      |> Enum.filter(&(&1["appThreadId"] == thread["id"]))
      |> Enum.max_by(&(&1["lastRunOrdinal"] || 0), fn -> nil end)
  end

  # `{native id, [{name, path}]}` with the main file first, or nil.
  defp session_files(driver, instance, provider_thread, cwd) do
    cond do
      module = plugin(driver) ->
        with id when is_binary(id) <-
               get_in(provider_thread, ["nativeThreadRef", "nativeId"]) ||
                 get_in(provider_thread, ["carriedSession", "nativeId"]),
             do: {id, plugin_call(fn -> module.session_files(id, cwd) end)}

      driver in @drivers ->
        with {id, main} when is_binary(main) <- source(driver, instance, provider_thread, cwd),
             do: {id, files(driver, instance, main)}

      true ->
        nil
    end
  end

  # `{native id, the session's main file}`: the native session the provider thread
  # ran on, or the copy it carried here and has not run on since.
  defp source(driver, instance, provider_thread, cwd) do
    case {get_in(provider_thread, ["nativeThreadRef", "nativeId"]),
          provider_thread["carriedSession"]} do
      {id, _} when is_binary(id) -> {id, locate(driver, instance, id, cwd)}
      {nil, %{"nativeId" => id, "path" => path}} -> {id, path}
      _ -> nil
    end
  end

  # A session a thread moved in with records where it was carried from.
  defp recorded_cwd(_provider_thread, cwd), do: cwd

  defp locate("pi", _instance, file, _cwd), do: file

  defp locate("codex", instance, id, _cwd) do
    codex_home(instance)
    |> Path.join("sessions/*/*/*/rollout-*-#{id}.jsonl")
    |> Path.wildcard()
    |> List.first()
  end

  defp locate("claudeAgent", instance, id, cwd) do
    projects = Path.join(claude_home(instance), "projects")
    own = Path.join([projects, claude_folder(cwd), "#{id}.jsonl"])

    if File.regular?(own),
      do: own,
      else: projects |> Path.join("*/#{id}.jsonl") |> Path.wildcard() |> List.first()
  end

  # `[{name, path}]`, the main file first; a name is relative to where `place/3` puts it.
  defp files("codex", instance, main),
    do: [{Path.relative_to(main, codex_home(instance)), main}]

  defp files("pi", _instance, main), do: [{Path.basename(main), main}]

  # A Claude session's sub-agent transcripts and saved tool results live beside it.
  defp files("claudeAgent", _instance, main) do
    folder = Path.dirname(main)
    extra = Path.rootname(main)

    [{Path.basename(main), main}] ++
      for path <- Path.wildcard(Path.join(extra, "**"), match_dot: true),
          File.regular?(path),
          do: {Path.relative_to(path, folder), path}
  end

  # --- destination -----------------------------------------------------------------

  # `{the folder names are relative to, the main file's name}`.
  defp target("codex", instance, _root, session),
    do: {codex_home(instance), main_name(session)}

  defp target("claudeAgent", instance, root, session),
    do: {Path.join([claude_home(instance), "projects", claude_folder(root)]), main_name(session)}

  defp target("pi", instance, root, session),
    do: {Path.join(pi_sessions(instance), pi_folder(root)), main_name(session)}

  defp main_name(%{"files" => [%{"fileName" => name} | _]}), do: name

  defp safe?(name),
    do: Path.type(name) == :relative and ".." not in Path.split(name) and name != ""

  # Writes a carried file to `path`, every recorded working directory under `from`
  # now pointing under `to`. A file on disk is copied a line at a time.
  defp copy(%{"fileName" => name} = file, path, driver, from, to) do
    lines? = String.ends_with?(name, ".jsonl") and is_binary(from) and from != to

    case file do
      %{"data" => data} when lines? ->
        File.write!(
          path,
          data |> String.split("\n") |> Enum.map_join("\n", &rewrite_line(driver, &1, from, to))
        )

      %{"data" => data} ->
        File.write!(path, data)

      %{"path" => source} when lines? ->
        source
        |> File.stream!()
        |> Stream.map(&rewrite_line(driver, &1, from, to))
        |> Stream.into(File.stream!(path))
        |> Stream.run()

      %{"path" => source} ->
        File.cp!(source, path)
    end
  end

  # A line keeps the newline it ended with.
  defp rewrite_line(driver, line, from, to) do
    with true <- String.contains?(line, from),
         {:ok, %{} = record} <- JSON.decode(line),
         changed when changed != record <- rewrite_record(driver, record, from, to) do
      JSON.encode!(changed) <> if(String.ends_with?(line, "\n"), do: "\n", else: "")
    else
      _ -> line
    end
  end

  defp rewrite_record("codex", %{"type" => type, "payload" => %{"cwd" => cwd} = p} = r, from, to)
       when type in ~w(session_meta turn_context),
       do: %{r | "payload" => %{p | "cwd" => moved(cwd, from, to)}}

  defp rewrite_record("claudeAgent", %{"cwd" => cwd} = record, from, to),
    do: %{record | "cwd" => moved(cwd, from, to)}

  defp rewrite_record("pi", %{"type" => "session", "cwd" => cwd} = header, from, to),
    do: %{header | "cwd" => moved(cwd, from, to)}

  defp rewrite_record(_driver, record, _from, _to), do: record

  defp moved(path, from, to) when is_binary(path) do
    cond do
      path == from -> to
      String.starts_with?(path, from <> "/") -> to <> String.replace_prefix(path, from, "")
      true -> path
    end
  end

  defp moved(path, _from, _to), do: path

  # --- homes -----------------------------------------------------------------------

  @doc "The Claude Code home an instance keeps its sessions in."
  def claude_home(instance), do: home(instance, "CLAUDE_CONFIG_DIR", ".claude")

  @doc "The Codex home an instance keeps its sessions in."
  def codex_home(instance), do: home(instance, "CODEX_HOME", ".codex")

  @doc "The folder a Pi instance keeps its sessions in."
  def pi_sessions(instance) do
    case setting(instance, "PI_CODING_AGENT_SESSION_DIR") do
      nil -> Path.join(home(instance, "PI_CODING_AGENT_DIR", ".pi/agent"), "sessions")
      dir -> Path.expand(dir)
    end
  end

  @doc "Claude Code's folder for sessions run in `cwd`."
  def claude_folder(cwd), do: String.replace(cwd, ~r/[^A-Za-z0-9]/, "-")

  @doc "Pi's folder for sessions run in `cwd`."
  def pi_folder(cwd),
    do: "--" <> (cwd |> String.trim_leading("/") |> String.replace("/", "-")) <> "--"

  defp home(instance, variable, default) do
    case setting(instance, variable) do
      nil -> Path.join(user_home(), default)
      dir -> Path.expand(dir)
    end
  end

  # The instance's own variable in settings, else the MC's.
  defp setting(instance, variable) do
    [HalC2.Settings.instance_env(instance)[variable], System.get_env(variable)]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp user_home,
    do: Application.get_env(:hal_c2, :agent_sessions_home) || System.user_home!()
end
