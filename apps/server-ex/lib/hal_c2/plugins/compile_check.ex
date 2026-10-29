defmodule HalC2.Plugins.CompileCheck do
  @moduledoc """
  Compiles a plugin package's `mc/` sources without enabling it, for an author or the
  user to see whether they compile (`plugins.compile`).

  Compiling runs the package's code: module bodies, macros and attributes. So it runs
  in a VM of its own, a `:peer` started without distribution and stopped when the
  check ends: nothing it loads, starts or stores (modules, processes, ETS,
  `:persistent_term`, atoms) reaches the MC, so an enabled package with modules of the
  same names keeps running as it was. Modules compile in memory, so no beams are left
  on disk. What the code does to files or the network is not undone: the check is
  something a person asks for, never part of a scan.
  """

  # As long as enabling may take to compile (`HalC2.Plugins`).
  @timeout 60_000

  @doc """
  `{:ok, %{ok, diagnostics}}` for the `mc/*.ex` `sources` of the package at `dir`,
  compiled in name order as enabling it does, `diagnostics` being
  `%{file, line, message, severity}` with `file` relative to `dir`; `{:error,
  message}` when the check could not run.
  """
  def run(_dir, []), do: {:ok, %{ok: true, diagnostics: []}}

  def run(dir, sources) do
    me = self()
    ref = make_ref()

    # The peer is linked to a process of its own, so a peer that dies takes only that.
    {pid, monitor} = spawn_monitor(fn -> send(me, {ref, check(dir, sources)}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, "The compile check stopped: #{Exception.format_exit(reason)}"}
    end
  end

  defp check(dir, sources) do
    with {:ok, peer} <- start() do
      try do
        {:ok, :peer.call(peer, __MODULE__, :compile, [dir, sources], @timeout)}
      catch
        :exit, {:timeout, _} ->
          {:ok,
           %{
             ok: false,
             diagnostics: [
               diagnostic(nil, nil, "did not finish compiling within #{div(@timeout, 1000)} s")
             ]
           }}
      after
        :peer.stop(peer)
      end
    end
  end

  defp start do
    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, exec: exec(), args: boot()})

    :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])
    {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])
    {:ok, peer}
  catch
    kind, reason ->
      {:error, "The compile check could not start: #{Exception.format(kind, reason)}"}
  end

  # The runtime's own `erl`, which a release carries, then whichever one is on the path.
  defp exec do
    erl =
      Path.join([
        :code.root_dir(),
        "erts-#{:erlang.system_info(:version)}",
        "bin",
        "erl"
      ])

    if File.exists?(erl), do: String.to_charlist(erl), else: :os.find_executable(~c"erl")
  end

  # A release has no `bin/start.boot` of the runtime's: its own clean boot loads the
  # release's applications.
  defp boot do
    with root when is_binary(root) <- System.get_env("RELEASE_ROOT"),
         vsn when is_binary(vsn) <- System.get_env("RELEASE_VSN"),
         boot = Path.join([root, "releases", vsn, "start_clean"]),
         true <- File.exists?(boot <> ".boot") do
      [~c"-boot", String.to_charlist(boot)]
    else
      _ -> []
    end
  end

  @doc false
  # Runs on the peer: each source as `HalC2.Plugins` compiles it, stopping at the first
  # that fails, then the rule that a package has one plugin module.
  def compile(dir, sources) do
    result =
      Enum.reduce_while(sources, {[], []}, fn source, {modules, diagnostics} ->
        case compile_file(dir, source) do
          {:ok, compiled, found} -> {:cont, {modules ++ compiled, diagnostics ++ found}}
          {:error, found} -> {:halt, {:error, diagnostics ++ found}}
        end
      end)

    case result do
      {:error, diagnostics} ->
        %{ok: false, diagnostics: diagnostics}

      {modules, diagnostics} ->
        case HalC2.Plugins.package_module(modules) do
          {:ok, _, _} ->
            %{ok: true, diagnostics: diagnostics}

          {:error, message} ->
            %{ok: false, diagnostics: diagnostics ++ [diagnostic(nil, nil, message)]}
        end
    end
  end

  defp compile_file(dir, file) do
    {result, diagnostics} =
      Code.with_diagnostics([log: false], fn ->
        try do
          {:ok, Code.compile_file(file)}
        rescue
          e -> {:error, e, __STACKTRACE__}
        catch
          # Thrown or exited by a module body or a macro: the code's failure, not the check's.
          kind, reason ->
            {:error, %RuntimeError{message: Exception.format_banner(kind, reason)},
             __STACKTRACE__}
        end
      end)

    found = Enum.map(diagnostics, &found(dir, file, &1))

    case result do
      {:ok, modules} ->
        {:ok, modules, found}

      # A syntax error is raised with no diagnostic of its own.
      {:error, e, stacktrace} ->
        if Enum.any?(found, &(&1.severity == "error")),
          do: {:error, found},
          else: {:error, found ++ [raised(dir, file, e, stacktrace)]}
    end
  end

  defp found(dir, file, diagnostic) do
    line =
      case diagnostic.position do
        {line, _column} -> line
        line when is_integer(line) and line > 0 -> line
        _ -> nil
      end

    %{
      file: relative(dir, diagnostic.file || file),
      line: line,
      message: diagnostic.message,
      severity: to_string(diagnostic.severity)
    }
  end

  defp raised(dir, file, e, stacktrace) do
    message =
      case e do
        %{description: description} when is_binary(description) -> description
        _ -> Exception.message(e)
      end

    line =
      if is_integer(Map.get(e, :line)) and e.line > 0,
        do: e.line,
        else: line_in(stacktrace, file)

    file = if is_binary(Map.get(e, :file)), do: e.file, else: file
    diagnostic(relative(dir, file), line, message)
  end

  # Where in `file` code run while compiling it raised, threw or exited.
  defp line_in(stacktrace, file) do
    Enum.find_value(stacktrace, fn {_, _, _, location} ->
      at = location[:file]
      line = location[:line]
      if at && is_integer(line) && Path.expand(to_string(at)) == Path.expand(file), do: line
    end)
  end

  defp diagnostic(file, line, message),
    do: %{file: file, line: line, message: message, severity: "error"}

  defp relative(_dir, nil), do: nil
  defp relative(dir, file), do: Path.relative_to(Path.expand(file), Path.expand(dir))
end
