defmodule HalC2.ProjectEnvironment do
  @moduledoc """
  The variables a terminal in a checkout would have, for the agent sessions started
  there: what the checkout's mise config, direnv `.envrc` or a dotenv file declares,
  so a `.mcp.json` that expands `${SOME_URL}` works in an app-launched session too.

  It is off unless a project turns it on (the project-scoped `projectEnvironment`
  setting: `"off"`, `"auto"` or `"dotenv"`), because loading runs the checkout's own
  configuration. `"auto"` loads mise when a mise config applies to the thread's
  working directory and mise is installed, then direnv when an `.envrc` applies and
  direnv is installed, direnv's variables over mise's. `"dotenv"` reads
  `projectEnvironmentFile` (`.env` by default), relative to the working directory.
  The working directory is the thread's worktree, not the project root, since a
  worktree's config can differ. The managers' own trust still applies: an `.envrc`
  that is not `direnv allow`ed or a mise config that is not `mise trust`ed is reported,
  never bypassed.

  Precedence, lowest first: the MC's own environment, the project's, then the
  launch environment the adapter built (the provider instance's variables and those
  HAL-C2 sets for the session). The project never sets a `HAL_C2_*` variable, nor one
  the launch command removes with `env -u`.

  Loading runs under a timeout and never fails a launch: a manager that fails, is not
  trusted or runs too long leaves the session with its usual environment and a
  notice on the thread saying why. Values are secrets-adjacent, so they are never
  logged or sent to a client; the log names the loader and how many variables it set.
  """

  alias HalC2.{Orchestration, StreamState}
  alias HalC2.Orchestration.Entities

  require Logger

  @type env :: [{String.t(), String.t()}]

  @timeout_ms 10_000
  @max_output 4_000_000
  @default_file ".env"

  # The files that make a mise config apply to a directory, looked for in it and
  # every directory above it.
  @mise_files ~w(mise.toml mise.local.toml .mise.toml .mise.local.toml .config/mise.toml
                 .config/mise/config.toml mise/config.toml .mise/config.toml .tool-versions)
  # direnv's state from an MC started in a direnv shell would make it export a diff
  # against that directory instead of this one's variables.
  @direnv_state ~w(DIRENV_DIR DIRENV_FILE DIRENV_DIFF DIRENV_WATCHES)

  @doc """
  `env`, the launch environment an adapter built for a session of `context` (a turn:
  `:cwd`, `:project_id` and, to show a notice on its run, `:ids`), with the project
  environment under it. `command` is the launch command, whose `env -u` names stay
  unset. A failure to load is a notice on the run and a log line, never an error.
  """
  @spec for_turn(map, env, [String.t()]) :: env
  def for_turn(context, env, command \\ []) do
    project = Map.get(context, :project_id)
    cwd = Map.get(context, :cwd)

    if is_binary(project) and is_binary(cwd) do
      {loaded, warnings} = load(HalC2.Settings.for_project(project), cwd)
      if warnings != [], do: notice(context, warnings)
      merge(env, loaded, unset_by(command))
    else
      env
    end
  end

  @doc """
  The project environment for `cwd` under the resolved `settings`, as
  `{variables, warnings}`: nothing and no warning when it is off.
  """
  @spec load(map, Path.t()) :: {env, [String.t()]}
  def load(settings, cwd) do
    case source(settings) do
      "auto" ->
        [&mise/1, &direnv/1]
        |> Enum.map(& &1.(cwd))
        |> Enum.reduce({[], []}, fn
          :skip, acc -> acc
          {:ok, env}, {vars, warnings} -> {overlay(vars, env), warnings}
          {:error, warning}, {vars, warnings} -> {vars, warnings ++ [warning]}
        end)

      "dotenv" ->
        case dotenv(cwd, file(settings)) do
          {:ok, env} -> {env, []}
          {:partial, env, warning} -> {env, [warning]}
          {:error, warning} -> {[], [warning]}
        end

      _off ->
        {[], []}
    end
  end

  @doc "The project's `projectEnvironment` setting, `\"off\"` unless it is a known source."
  def source(settings) do
    case settings["projectEnvironment"] do
      source when source in ["auto", "dotenv"] -> source
      _ -> "off"
    end
  end

  defp file(settings) do
    case settings["projectEnvironmentFile"] do
      file when is_binary(file) ->
        if String.trim(file) == "", do: @default_file, else: String.trim(file)

      _ ->
        @default_file
    end
  end

  @doc """
  `launch` with the `project` variables it does not set under it: each name once,
  the launch's value winning, and never a `HAL_C2_*` name or one in `unset`.
  """
  @spec merge(env, env, [String.t()]) :: env
  def merge(launch, project, unset \\ []) do
    taken = MapSet.new(Enum.map(launch, &elem(&1, 0)) ++ unset)

    kept =
      project
      |> Enum.reject(fn {name, _} ->
        MapSet.member?(taken, name) or String.starts_with?(name, "HAL_C2_")
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    kept ++ launch
  end

  @doc "The names a launch command removes from its environment with `env -u NAME`."
  def unset_by([env | args]) when is_binary(env) do
    if Path.basename(env) == "env", do: unset_names(args), else: []
  end

  def unset_by(_command), do: []

  defp unset_names(["-u", name | rest]), do: [name | unset_names(rest)]
  defp unset_names(["--unset=" <> name | rest]), do: [name | unset_names(rest)]
  defp unset_names(_rest), do: []

  # `top`'s variables over `base`'s, each name once.
  defp overlay(base, top) do
    names = MapSet.new(top, &elem(&1, 0))
    Enum.reject(base, &MapSet.member?(names, elem(&1, 0))) ++ top
  end

  # --- mise --------------------------------------------------------------------------

  defp mise(cwd) do
    with config when is_binary(config) <- applies(cwd, @mise_files),
         path when is_binary(path) <- executable("mise") do
      case run([path, "env", "--json"], cwd) do
        {:ok, out} ->
          decoded("mise", out, cwd)

        {:failed, _status, err} ->
          if err =~ "not trusted",
            do:
              {:error,
               "mise does not trust #{config}, so its variables were not loaded. Run `mise trust` there to load them."},
            else:
              {:error,
               "mise could not load the environment of #{cwd}. Run `mise env` there to see why."}

        {:error, reason} ->
          {:error, "mise #{reason}, so the project environment was not loaded."}
      end
    else
      _ -> :skip
    end
  end

  # --- direnv ------------------------------------------------------------------------

  defp direnv(cwd) do
    with envrc when is_binary(envrc) <- applies(cwd, [".envrc"]),
         path when is_binary(path) <- executable("direnv") do
      argv =
        case for {name, _} <- System.get_env(), name in @direnv_state, do: name do
          [] ->
            [path, "export", "json"]

          state ->
            [System.find_executable("env") | Enum.flat_map(state, &["-u", &1])] ++
              [path, "export", "json"]
        end

      case run(argv, cwd, [{"DIRENV_LOG_FORMAT", ""}]) do
        {:ok, out} ->
          decoded("direnv", out, cwd)

        {:failed, _status, err} ->
          if err =~ "is blocked" or err =~ "not allowed",
            do:
              {:error,
               "direnv is not allowed to load #{envrc}, so its variables were not loaded. Run `direnv allow` there to load them."},
            else:
              {:error,
               "direnv could not load the environment of #{cwd}. Run `direnv export json` there to see why."}

        {:error, reason} ->
          {:error, "direnv #{reason}, so the project environment was not loaded."}
      end
    else
      _ -> :skip
    end
  end

  # direnv writes nothing when there is nothing to change. A `null` is a variable
  # direnv unsets, which a launch cannot express over the MC's environment: it is left.
  defp decoded(loader, out, cwd) do
    case String.trim(out) do
      "" ->
        report(loader, cwd, [])

      text ->
        case JSON.decode(text) do
          {:ok, %{} = vars} ->
            report(
              loader,
              cwd,
              for({name, value} when is_binary(value) <- vars, do: {name, value})
            )

          _ ->
            {:error, "#{loader} printed something other than variables, so they were not loaded."}
        end
    end
  end

  defp report(loader, cwd, env) do
    Logger.info("project environment: #{loader} set #{length(env)} variables for #{cwd}")
    {:ok, env}
  end

  # The nearest of `names` in `cwd` or a directory above it.
  defp applies(cwd, names) do
    cwd
    |> Path.expand()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while(nil, fn dir, _ ->
      found =
        Enum.find_value(names, &if(File.regular?(Path.join(dir, &1)), do: Path.join(dir, &1)))

      cond do
        found -> {:halt, found}
        Path.dirname(dir) == dir -> {:halt, nil}
        true -> {:cont, nil}
      end
    end)
  end

  # `:project_environment_commands` stands in for a manager (tests).
  defp executable(name) do
    case Application.get_env(:hal_c2, :project_environment_commands, %{})[name] do
      nil -> System.find_executable(name)
      path -> path
    end
  end

  defp run(argv, cwd, env \\ []) do
    timeout = Application.get_env(:hal_c2, :project_environment_timeout_ms, @timeout_ms)

    case HalC2.Git.within(timeout, fn -> collect(argv, cwd, env) end) do
      {:ok, {:ok, 0, out, _err}} -> {:ok, out}
      {:ok, {:ok, status, _out, err}} -> {:failed, status, err}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, _reason} -> {:error, "stopped while loading"}
      :timeout -> {:error, "took longer than #{div(timeout, 1000)} s"}
    end
  end

  defp collect(argv, cwd, env) do
    argv
    |> Exile.stream(cd: cwd, env: env, stderr: :consume, ignore_epipe: true)
    |> Enum.reduce_while({[], 0, [], nil}, fn
      {:stdout, data}, {out, size, err, status} ->
        size = size + byte_size(data)

        if size > @max_output,
          do: {:halt, :too_much},
          else: {:cont, {[out, data], size, err, status}}

      {:stderr, data}, {out, size, err, status} ->
        {:cont, {out, size, [err, data], status}}

      {:exit, {:status, code}}, {out, size, err, _} ->
        {:cont, {out, size, err, code}}

      {:exit, _signal}, {out, size, err, _} ->
        {:cont, {out, size, err, 1}}
    end)
    |> case do
      :too_much ->
        {:error, "printed too much"}

      {out, _size, err, status} ->
        {:ok, status || 1, IO.iodata_to_binary(out), IO.iodata_to_binary(err)}
    end
  rescue
    _ -> {:error, "could not be started"}
  catch
    :exit, _reason -> {:error, "did not exit"}
  end

  # --- dotenv ------------------------------------------------------------------------

  defp dotenv(cwd, file) do
    path = Path.expand(file, cwd)

    case File.read(path) do
      {:ok, text} ->
        {env, bad} = parse_dotenv(text)
        Logger.info("project environment: #{file} set #{length(env)} variables for #{cwd}")

        if bad == [],
          do: {:ok, env},
          else:
            {:partial, env,
             "#{file} has lines that are not variables (line #{Enum.join(bad, ", ")}); the rest were loaded."}

      {:error, :enoent} ->
        {:error, "#{file} was not found in #{cwd}, so no project environment was loaded."}

      {:error, reason} ->
        {:error, "#{file} in #{cwd} could not be read (#{:file.format_error(reason)})."}
    end
  end

  @doc """
  The variables of a dotenv file and the numbers of the lines that are not one.
  `NAME=value`, optionally after `export`; `#` starts a comment line, or a comment
  after an unquoted value and a space. Single quotes are literal; double quotes take
  `\\n`, `\\r`, `\\t`, `\\"` and `\\\\`; either may span lines. Nothing is expanded.
  """
  @spec parse_dotenv(String.t()) :: {env, [pos_integer]}
  def parse_dotenv(text) do
    text
    |> String.replace("\r\n", "\n")
    |> parse_lines(1, [], [])
  end

  defp parse_lines("", _line, env, bad), do: {Enum.reverse(env) |> dedupe(), Enum.reverse(bad)}

  defp parse_lines(text, line, env, bad) do
    {current, rest} = split_line(text)
    trimmed = String.trim(current)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        parse_lines(rest, line + 1, env, bad)

      match = Regex.run(~r/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/s, trimmed) ->
        [_, name, value] = match

        case value(value, rest) do
          {:ok, value, rest, lines} ->
            parse_lines(rest, line + 1 + lines, [{name, value} | env], bad)

          :error ->
            parse_lines(rest, line + 1, env, [line | bad])
        end

      true ->
        parse_lines(rest, line + 1, env, [line | bad])
    end
  end

  defp split_line(text) do
    case String.split(text, "\n", parts: 2) do
      [current, rest] -> {current, rest}
      [current] -> {current, ""}
    end
  end

  # A value and what is left after it: a quoted one may run on into later lines,
  # counted in `lines`.
  defp value("'" <> quoted, rest), do: quoted(quoted, rest, "'", &Function.identity/1)
  defp value("\"" <> quoted, rest), do: quoted(quoted, rest, "\"", &unescape/1)

  defp value(plain, rest) do
    value = plain |> String.split(~r/\s+#/, parts: 2) |> hd() |> String.trim()
    {:ok, value, rest, 0}
  end

  defp quoted(start, rest, quote, decode) do
    case closing(start, quote) do
      {:ok, inner, tail} ->
        if comment_or_blank?(tail), do: {:ok, decode.(inner), rest, 0}, else: :error

      :open ->
        case rest do
          "" ->
            :error

          _ ->
            {next, after_next} = split_line(rest)

            case quoted(start <> "\n" <> next, after_next, quote, decode) do
              {:ok, value, left, lines} -> {:ok, value, left, lines + 1}
              :error -> :error
            end
        end
    end
  end

  defp comment_or_blank?(tail) do
    tail = String.trim(tail)
    tail == "" or String.starts_with?(tail, "#")
  end

  # The text up to the first unescaped `quote` (escapes only count in double quotes).
  defp closing(text, quote), do: closing(text, quote, "")

  defp closing("", _quote, _acc), do: :open

  defp closing("\\" <> <<c::utf8, rest::binary>>, "\"", acc),
    do: closing(rest, "\"", acc <> "\\" <> <<c::utf8>>)

  defp closing(<<c::utf8, rest::binary>>, quote, acc) when <<c::utf8>> == quote,
    do: {:ok, acc, rest}

  defp closing(<<c::utf8, rest::binary>>, quote, acc),
    do: closing(rest, quote, acc <> <<c::utf8>>)

  defp unescape(text) do
    Regex.replace(~r/\\(.)/s, text, fn _, c ->
      case c do
        "n" -> "\n"
        "r" -> "\r"
        "t" -> "\t"
        other -> other
      end
    end)
  end

  # A name set twice keeps its last value, as a shell sourcing the file would.
  defp dedupe(env) do
    env
    |> Enum.reverse()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.reverse()
  end

  # --- the notice --------------------------------------------------------------------

  # One notice per run, on the run whose session was launched; a launch outside a run
  # (a rewind) is only logged.
  defp notice(context, warnings) do
    message = Enum.join(warnings, " ")
    Logger.warning("project environment not fully loaded: #{message}")

    with %{thread: thread, run: run} = ids when is_binary(run) <- Map.get(context, :ids) do
      id = "turn-item:project-environment:#{run}"

      HalC2.Streams.transact(thread, :thread, fn stream ->
        if StreamState.get(stream, "turn-item")[id] do
          {[], :ok}
        else
          item =
            Entities.turn_item(
              ids,
              id,
              "system_notice",
              Orchestration.next_ordinal(stream),
              "completed",
              Entities.now(),
              %{"title" => "Project environment not loaded", "message" => message}
            )

          {[Orchestration.create("turn-item", id, item)], :ok}
        end
      end)
    end

    :ok
  rescue
    error ->
      Logger.warning("project environment notice not written: #{Exception.message(error)}")
      :ok
  end
end
