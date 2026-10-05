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
    * Gemini CLI (the ACP registry's `gemini`): one chat file per session,
      `<GEMINI_CLI_HOME or ~>/.gemini/tmp/<project>/chats/session-<time>-<id, 8
      characters>.json`, where `<project>` is the SHA-256 of the project's path, or the
      name `projects.json` gives that path. The file records the project it belongs to.
    * OpenCode: a store of its own, read with `opencode export <id>` and written with
      `opencode import <file>` run in the destination project.
    * A provider plugin that declares `native_sessions` says itself, with its
      `session_files/2` and `place_session/3` (`HalC2.Plugins.ProviderAdapter`).

  A copy never replaces a file already there: the machine keeps the copy it had, and
  since the destination branches a new session, no two sessions share an id. Gemini
  cannot branch a session, it loads one by its id, so where the destination already
  holds that session nothing is placed and the thread gets the handoff.
  """

  require Logger
  alias HalC2.StreamState

  @drivers ~w(claudeAgent codex pi)

  @doc "Whether a provider driver's sessions can be carried."
  def carries?(driver),
    do: driver in @drivers or plugin(driver) != nil or gemini?(driver) or opencode?(driver)

  @doc """
  The session a thread carries: `%{driver, instanceId, providerThreadId, nativeId,
  cwd, files}` with each file as `{name, path on this machine}`, or `{name, {:data,
  bytes}}` for what a provider's own export printed, or nil when the thread's agent
  has no session this machine can carry.
  """
  def export(state, thread, cwd) do
    with %{} = provider_thread <- provider_thread(state, thread),
         driver = provider_thread["driver"],
         instance = provider_thread["providerInstanceId"] || driver,
         {native_id, [{_, main} | _] = found} <-
           session_files(driver, instance, provider_thread, cwd),
         true <- held?(main) do
      %{
        "driver" => driver,
        "instanceId" => instance,
        "providerThreadId" => provider_thread["id"],
        "nativeId" => native_id,
        "cwd" => recorded_cwd(provider_thread, cwd),
        "files" => Enum.filter(found, fn {_name, source} -> held?(source) end)
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
      gemini?(session["instanceId"] || driver) -> place_gemini(session, root, archive)
      opencode?(session["instanceId"] || driver) -> place_opencode(session, root, archive)
      true -> {nil, []}
    end
  end

  def place(_session, _root, _archive), do: {nil, []}

  # A session's file is where the provider keeps it, or was handed over by the
  # provider's own export.
  defp held?({:data, data}), do: is_binary(data)
  defp held?(path), do: is_binary(path) and File.regular?(path)

  # A carried file's bytes, for a session that is placed as a whole.
  defp bytes(%{"data" => data}), do: {:ok, data}
  defp bytes(%{"path" => path}), do: File.read(path)
  defp bytes(_file), do: :error

  # --- OpenCode ----------------------------------------------------------------------

  @opencode_file "opencode-session.json"

  defp opencode?(instance), do: is_binary(instance) and HalC2.Acp.driver(instance) == "opencode"

  # `{session id, [{name, {:data, export}}]}`: what `opencode export <id>` prints.
  defp opencode_source(instance, provider_thread, cwd) do
    with id when is_binary(id) <-
           get_in(provider_thread, ["nativeThreadRef", "nativeId"]) ||
             get_in(provider_thread, ["carriedSession", "nativeId"]),
         {:ok, export} <- opencode_export(instance, id, cwd) do
      {id, [{@opencode_file, {:data, export}}]}
    else
      _ -> nil
    end
  end

  defp opencode_export(instance, id, cwd) do
    with {out, 0} <- opencode(instance, ["export", id], cwd),
         {:ok, %{"info" => %{"id" => ^id}}} <- JSON.decode(out) do
      {:ok, out}
    else
      _ -> :error
    end
  end

  # OpenCode keeps sessions in a store of its own, so its own import puts the copy
  # there, run in the destination project so the session belongs to it. A session the
  # destination already has is its own copy: it stays, and nothing is carried.
  defp place_opencode(%{"files" => [file | _]} = session, root, archive) do
    instance = session["instanceId"] || session["driver"]
    id = session["nativeId"]

    with {:ok, data} <- bytes(file),
         {:ok, %{"info" => %{"id" => ^id}} = export} <- JSON.decode(data),
         :error <- opencode_export(instance, id, root),
         :ok <- opencode_import(instance, rehome(export, session["cwd"], root), root) do
      {%{
         "providerThreadId" => session["providerThreadId"],
         "carriedSession" => %{
           "driver" => session["driver"],
           "instanceId" => instance,
           "nativeId" => id,
           "path" => nil,
           "from" => get_in(archive, ["thread", "machine"])
         }
       }, []}
    else
      _ -> {nil, []}
    end
  end

  defp opencode_import(instance, export, root) do
    file =
      Path.join(System.tmp_dir!(), "hal-c2-opencode-#{System.unique_integer([:positive])}.json")

    try do
      File.write!(file, JSON.encode!(export))
      File.chmod(file, 0o600)

      case opencode(instance, ["import", file], root) do
        {_out, 0} -> :ok
        _ -> :error
      end
    after
      File.rm(file)
    end
  end

  # The directories the export records (the session's, and each message's) move with it.
  defp rehome(export, from, to) when is_binary(from) and from != to do
    path = fn
      %{} = path ->
        Map.new(path, fn {key, value} -> {key, moved(value, from, to)} end)

      other ->
        other
    end

    export
    |> update_in(["info"], &Map.replace_lazy(&1, "directory", fn dir -> moved(dir, from, to) end))
    |> Map.update("messages", [], fn messages ->
      for message <- messages do
        case message do
          %{"info" => %{"path" => _} = info} ->
            %{message | "info" => Map.update!(info, "path", path)}

          other ->
            other
        end
      end
    end)
  end

  defp rehome(export, _from, _to), do: export

  # Runs the instance's `opencode` with `args` in `cwd`: `{stdout, status}`, or nil
  # when it cannot be run or does not come back (the thread then moves with the handoff).
  defp opencode(instance, args, cwd) do
    [program | rest] =
      case Application.get_env(:hal_c2, :acp_commands, %{})[instance] do
        [_ | _] = command -> command
        _ -> [HalC2.Acp.binary_path(instance)]
      end

    env = HalC2.Acp.instance_env(instance)

    parent = self()
    ref = make_ref()

    # With nothing to read, so it never waits for input; and in a process of its own,
    # so one that never answers can be killed.
    {pid, monitor} =
      spawn_monitor(fn ->
        argv = ["-c", ~s(exec "$@" </dev/null), "sh", program | rest ++ args]
        send(parent, {ref, System.cmd("sh", argv, cd: cwd, env: env)})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _, _} ->
        nil
    after
      30_000 ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        nil
    end
  end

  # --- Gemini CLI --------------------------------------------------------------------

  # An instance of the ACP registry's Gemini CLI.
  defp gemini?(instance) when is_binary(instance) do
    case (HalC2.Settings.settings()["providerInstances"] || %{})[instance] do
      %{"driver" => "acpRegistry", "config" => %{"agentId" => "gemini"}} -> true
      _ -> false
    end
  end

  defp gemini?(_instance), do: false

  @doc "The Gemini CLI home (the folder holding `.gemini`) an instance keeps its chats in."
  def gemini_home(instance),
    do: Path.join(home(instance, "GEMINI_CLI_HOME", ""), ".gemini")

  @doc "Gemini CLI's folder for the chats of the project at `root` under `gemini`."
  def gemini_folder(gemini, root) do
    named =
      with {:ok, text} <- File.read(Path.join(gemini, "projects.json")),
           {:ok, %{"projects" => %{^root => name}}} when is_binary(name) <- JSON.decode(text),
           do: name

    project = if is_binary(named), do: named, else: project_hash(root)
    Path.join([gemini, "tmp", project, "chats"])
  end

  defp project_hash(root), do: :crypto.hash(:sha256, root) |> Base.encode16(case: :lower)

  # `{session id, [{file name, path}]}`: the chat file named after the id that holds it.
  defp gemini_source(instance, provider_thread) do
    with id when is_binary(id) <-
           get_in(provider_thread, ["nativeThreadRef", "nativeId"]) ||
             get_in(provider_thread, ["carriedSession", "nativeId"]),
         [path | _] <-
           gemini_home(instance)
           |> Path.join("tmp/*/chats/session-*-#{String.slice(id, 0, 8)}.json")
           |> Path.wildcard()
           |> Enum.filter(&gemini_chat?(&1, id)) do
      {id, [{Path.basename(path), path}]}
    else
      _ -> nil
    end
  end

  defp gemini_chat?(path, id) do
    with {:ok, text} <- File.read(path), {:ok, %{"sessionId" => ^id}} <- JSON.decode(text) do
      true
    else
      _ -> false
    end
  end

  # Gemini loads a session by its id from the project's chats, so the copy goes there
  # under its own name, saying it belongs to the destination's project. A chat already
  # there is the machine's own copy of that session: it stays, and nothing is carried.
  defp place_gemini(%{"files" => [%{"fileName" => name} = file | _]} = session, root, archive) do
    instance = session["instanceId"] || session["driver"]
    path = Path.join(gemini_folder(gemini_home(instance), root), name)

    with true <- safe?(name) and Path.basename(name) == name,
         false <- File.exists?(path),
         {:ok, data} <- bytes(file),
         {:ok, %{} = chat} <- JSON.decode(data) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(Map.put(chat, "projectHash", project_hash(root))))
      File.chmod(path, 0o600)

      {%{
         "providerThreadId" => session["providerThreadId"],
         "carriedSession" => %{
           "driver" => session["driver"],
           "instanceId" => instance,
           "nativeId" => session["nativeId"],
           "path" => path,
           "from" => get_in(archive, ["thread", "machine"])
         }
       }, []}
    else
      _ -> {nil, []}
    end
  end

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

      gemini?(instance) ->
        gemini_source(instance, provider_thread)

      opencode?(instance) ->
        opencode_source(instance, provider_thread, cwd)

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
