defmodule HalC2.Steps.Platform.HostIntegration do
  @moduledoc "Steps for features/mc/platform/host-integration.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @editors %{
    "VS Code" => {"code", "vscode"},
    "Cursor" => {"cursor", "cursor"},
    "Zed" => {"zed", "zed"},
    "IntelliJ" => {"idea", "idea"}
  }

  # --- fake host programs --------------------------------------------------------------

  # A directory at the front of PATH for this scenario's fake programs.
  defp bin(context) do
    case context[:bin] do
      nil ->
        dir = Mc.tmp_dir(context.mc, "bin")
        World.put_os_env("PATH", dir <> ":" <> System.get_env("PATH"))
        Map.put(context, :bin, dir)

      _ ->
        context
    end
  end

  # Installs `name` as a program that reports its arguments to this test over TCP and
  # then stays running until the test hangs up. `file` is the name it is stored under
  # when that differs from the name it reports (a Windows editor path needs an extension).
  defp install(context, name, file \\ nil) do
    context = bin(context) |> listen()
    path = Path.join(context.bin, file || name)

    File.write!(path, """
    #!/usr/bin/env bash
    exec 3<>/dev/tcp/127.0.0.1/$HAL_C2_TEST_LAUNCH_PORT
    printf '%s\\x1f' "#{name}" "$@" >&3
    printf '\\n' >&3
    read -r -u 3 _
    """)

    File.chmod!(path, 0o755)
    context
  end

  # Like `install/2`, but also reports whether the program's standard streams lead to
  # /dev/null, then its process id and process group: `name`, the arguments, then
  # `in out err pid pgid`. Only POSIX tools, so it runs on macOS as well as Linux.
  defp install_probe(context, name) do
    context = install(context, name)

    File.write!(Path.join(context.bin, name), """
    #!/usr/bin/env bash
    exec 3<>/dev/tcp/127.0.0.1/$HAL_C2_TEST_LAUNCH_PORT
    printf '%s\\x1f' "#{name}" "$@" >&3
    for fd in 0 1 2; do
      if [ /dev/fd/$fd -ef /dev/null ]; then printf 'null ' >&3; else printf 'other ' >&3; fi
    done
    printf '%s %s\\n' "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" >&3
    read -r -u 3 _
    """)

    context
  end

  # Takes setsid off PATH, leaving what the fake programs and the perl fallback need.
  defp without_setsid(context) do
    context = bin(context)
    tools = Mc.tmp_dir(context.mc, "tools")

    for tool <- ~w(env bash ps tr perl), path = System.find_executable(tool) do
      File.ln_s!(path, Path.join(tools, tool))
    end

    World.put_os_env("PATH", context.bin <> ":" <> tools)
    context
  end

  # The ports the MC has open to the shell or the program it starts for a client; other
  # ports to external programs (the MC's own helpers) come and go on their own.
  defp program_ports do
    for p <- Port.list(),
        {:name, name} <- [Port.info(p, :name)],
        List.to_string(name) in ["/bin/sh", "/usr/bin/sh", "xdg-open"] or
          String.ends_with?(List.to_string(name), "/xdg-open"),
        do: p
  end

  defp listen(%{launches: _} = context), do: context

  defp listen(context) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(socket)
    World.put_os_env("HAL_C2_TEST_LAUNCH_PORT", Integer.to_string(port))
    Map.put(context, :launches, socket)
  end

  # The next launched program: `{connection, [name | args]}`.
  defp launched(context) do
    {:ok, conn} = :gen_tcp.accept(context.launches, 5_000)
    {:ok, line} = :gen_tcp.recv(conn, 0, 5_000)
    argv = line |> String.trim_trailing("\n") |> String.split("\x1f", trim: true)
    {conn, argv}
  end

  # Installs `name` as a program that runs `body` and exits.
  defp install_script(context, name, body) do
    context = bin(context)
    path = Path.join(context.bin, name)
    File.write!(path, "#!/usr/bin/env bash\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    context
  end

  defp with_display(context) do
    World.put_app_env(:os_type, {:unix, :linux})
    World.put_os_env("DISPLAY", ":0")
    install(context, "xdg-open")
  end

  defp headless(context) do
    World.put_app_env(:os_type, {:unix, :linux})
    World.put_os_env("DISPLAY", nil)
    World.put_os_env("WAYLAND_DISPLAY", nil)
    context
  end

  defp open(context, input) do
    {reply, context} = World.call(context, "shell.openInEditor", input)
    Map.put(context, :reply, reply)
  end

  defp refused(context, tag) do
    assert {:error, error, detail} = context.reply
    assert inspect({error, detail}) =~ tag
    context
  end

  defp server_config(context) do
    Mc.ensure(HalC2.Settings)

    client =
      World.client(context)
      |> Mc.sub(9, %{"type" => "config", "environment" => context.mc.environment})

    {frame, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == 9))
    context |> World.put_client(client) |> Map.put(:server_config, frame["config"])
  end

  # --- editors -------------------------------------------------------------------------

  step "Cursor and Zed are installed on the host", context do
    context |> install("cursor") |> install("zed") |> with_display()
  end

  step "the available editors include Cursor and Zed", context do
    editors = context.server_config["availableEditors"]
    assert "cursor" in editors and "zed" in editors
    context
  end

  step "the file manager is listed last", context do
    assert List.last(context.server_config["availableEditors"]) == "file-manager"
    context
  end

  step ~r/^a client opens the path "(?<file>[^"]+)" in the default editor$/,
       %{args: [file]} = context do
    context |> Map.put(:target, file) |> open(%{"cwd" => file, "editor" => "default"})
  end

  step ~r/^the MC runs on Windows and Notepad is registered through the variable in '(?<line>[^']+)'$/,
       %{args: [line]} = context do
    windows_host(context, [{"UserChoice", "    ProgId    REG_SZ    txtfile"}], line)
  end

  step ~r/^a client opens "(?<file>[^"]+)" at line (?<line>\d+) column (?<column>\d+) in (?!the default editor)(?<editor>.+)$/,
       %{args: [file, line, column, editor]} = context do
    {command, id} = Map.fetch!(@editors, editor)
    context = install(context, command)
    target = Path.join(Mc.tmp_dir(context.mc, "project"), file) <> ":#{line}:#{column}"
    context |> Map.put(:target, target) |> open(%{"cwd" => target, "editor" => id})
  end

  step ~r/^the MC launches (?<editor>.+) the way it takes a line and column$/,
       %{args: [editor]} = context do
    {command, _id} = Map.fetch!(@editors, editor)
    [path, _line, _column] = String.split(context.target, ":")

    expected =
      case editor do
        "VS Code" -> ["--goto", context.target]
        "Cursor" -> ["--classic", "--goto", context.target]
        "Zed" -> [context.target]
        "IntelliJ" -> ["--line", "12", "--column", "4", path]
      end

    {conn, argv} = launched(context)
    assert argv == [command | expected]
    Map.put(context, :editor_conn, conn)
  end

  step "it does not wait for the editor to exit", context do
    # The reply came back while the editor is still running, waiting on this socket.
    assert {:ok, nil} = context.reply
    assert :ok = :gen_tcp.send(context.editor_conn, "exit\n")
    :gen_tcp.close(context.editor_conn)
    context
  end

  step "the host's default text editor is Neovim", context do
    data = Mc.tmp_dir(context.mc, "xdg-data")
    entry = Path.join([data, "applications", "nvim.desktop"])
    File.mkdir_p!(Path.dirname(entry))
    File.write!(entry, "[Desktop Entry]\nName=Neovim\nExec=nvim %F\nTerminal=true\n")
    World.put_os_env("XDG_DATA_HOME", data)

    context
    |> with_display()
    |> install_script("xdg-mime", ~s([ "$*" = "query default text/plain" ] && echo nvim.desktop))
    |> install("gio")
    |> Map.put(:entry, entry)
  end

  step ~r/^the host's default text editor is "(?<id>[^"]+)", installed as "(?<file>[^"]+)"$/,
       %{args: [id, file]} = context do
    data = Mc.tmp_dir(context.mc, "xdg-data")
    entry = Path.join([data, "applications", file])
    File.mkdir_p!(Path.dirname(entry))
    File.write!(entry, "[Desktop Entry]\nName=Editor\nExec=editor %F\n")
    World.put_os_env("XDG_DATA_HOME", data)

    context
    |> with_display()
    |> install_script("xdg-mime", ~s([ "$*" = "query default text/plain" ] && echo #{id}))
    |> install("gio")
  end

  # A Windows host whose `reg` answers for the .txt association: the user's choice
  # (the ProgId in the answers, else the class registered for .txt) names `txtfile`, whose open
  # command is the `notepad` that reports to this test.
  defp windows_host(context, answers, line \\ ~s("NOTEPAD" %1), type \\ "REG_EXPAND_SZ") do
    World.put_app_env(:os_type, {:win32, :nt})
    # Stored as notepad.exe: the MC refuses an extensionless Windows path word, so the
    # fake editor needs an extension to resolve, which Linux runs fine.
    context = install(context, "notepad", "notepad.exe")
    # What a registered line can name with %...%, as %SystemRoot% is on a real host.
    World.put_os_env("HAL_C2_TEST_EDITORS", context.bin)

    command =
      "    (Default)    #{type}    " <>
        String.replace(line, "NOTEPAD", Path.join(context.bin, "notepad.exe"))

    progid =
      Enum.find_value(answers, fn {_key, value} ->
        case String.split(value) do
          ["ProgId", "REG_SZ", class] -> class
          _ -> nil
        end
      end)

    # A class the choice names has the command only when it is an application the user
    # picked: any other ProgId (`brokenfile`) names no command, so the lookup has to fall
    # through to the class registered for .txt.
    command_keys =
      if progid && String.starts_with?(progid, "Applications\\"),
        do: ["txtfile", progid],
        else: ["txtfile"]

    body =
      ~s|case "$2" in\n| <>
        Enum.map_join(answers, fn {key, value} ->
          # printf reads backslash escapes in its format, so a value holding
          # one (a ProgId like Applications\notepad.exe) doubles it.
          escaped = String.replace(value, "\\", "\\\\")
          ~s|  *'#{key}'*) printf '\\r\\nHKEY\\r\\n#{escaped}\\r\\n' ;;\n|
        end) <>
        Enum.map_join(command_keys, fn class ->
          ~s|  *'HKCR\\#{class}\\shell\\open\\command'*) printf '\\r\\nHKEY\\r\\n%s\\r\\n' '#{command}' ;;\n|
        end) <>
        ~s|  *) exit 1 ;;\nesac|

    install_script(context, "reg", body)
  end

  # The first word of an unquoted program path with spaces (`C:\Program` of
  # `C:\Program Files\...`) is a real executable here, named literally (legal on
  # Linux), so only the MC's refusal of such a word, not a failed lookup, leaves the
  # default editor unoffered. A word rooted at `/` (`/Program`) cannot be created, so it
  # is rebased into this scenario's bin directory, which keeps the leading `/`.
  step ~r/^the MC runs on Windows and Notepad is registered with the unquoted command line '(?<line>[^']+)'$/,
       %{args: [line]} = context do
    context = bin(context)
    [word | rest] = String.split(line, " ", parts: 2)
    file = word
    word = if String.starts_with?(word, "/"), do: context.bin <> word, else: word
    line = Enum.join([word | rest], " ")

    context
    |> windows_host([{"UserChoice", "    ProgId    REG_SZ    txtfile"}], line)
    |> install(file)
  end

  step "the MC runs on Windows and opens text files in Notepad", context do
    windows_host(context, [{"UserChoice", "    ProgId    REG_SZ    txtfile"}])
  end

  step "the MC runs on Windows and the user's chosen program is the application notepad.exe",
       context do
    windows_host(context, [
      {"UserChoice", "    ProgId    REG_SZ    Applications\\notepad.exe"}
    ])
  end

  step ~r/^the MC runs on Windows and Notepad is registered with the command line '(?<line>[^']+)'$/,
       %{args: [line]} = context do
    windows_host(context, [{"UserChoice", "    ProgId    REG_SZ    txtfile"}], line)
  end

  step "the MC runs on Windows and the class registered for .txt opens text files in Notepad",
       context do
    windows_host(context, [{"HKCR\\.txt", "    (Default)    REG_SZ    txtfile"}])
  end

  # The user's choice names a class with no usable command (a Store app's
  # `DelegateExecute` class answers nothing here), but the class registered for
  # .txt opens text files in Notepad.
  step "the MC runs on Windows and the chosen program names no command line but the class registered for .txt opens text files in Notepad",
       context do
    windows_host(context, [
      {"UserChoice", "    ProgId    REG_SZ    brokenfile"},
      {"HKCR\\.txt", "    (Default)    REG_SZ    txtfile"}
    ])
  end

  step ~r/^the MC runs on Windows and Notepad is registered with the (?<type>REG_SZ|REG_EXPAND_SZ) command line '(?<line>[^']+)'$/,
       %{args: [type, line]} = context do
    windows_host(context, [{"UserChoice", "    ProgId    REG_SZ    txtfile"}], line, type)
  end

  # A Store app registers no command line, so `reg query /ve` prints a placeholder as data.
  step "the MC runs on Windows and the text association names no command line", context do
    windows_host(context, [{"UserChoice", "    ProgId    REG_SZ    txtfile"}], "(value not set)")
  end

  # `path` is printf escapes: bytes that are not UTF-8 (`\377`) or a NUL (`\000`) in
  # the program of the registered command line.
  step ~r/^the MC runs on Windows and reg prints the program path "(?<path>[^"]+)"$/,
       %{args: [path]} = context do
    World.put_app_env(:os_type, {:win32, :nt})

    body =
      """
      case "$2" in
        *UserChoice*) printf '\\r\\nHKEY\\r\\n    ProgId    REG_SZ    txtfile\\r\\n' ;;
        *'HKCR\\txtfile\\shell\\open\\command'*) printf '\\r\\nHKEY\\r\\n    (Default)    REG_SZ    "#{path}" %%1\\r\\n' ;;
        *) exit 1 ;;
      esac
      """

    install_script(bin(context), "reg", body)
  end

  # The registry's answers are kept for a minute, and `reg` logs each query it gets.
  step "the MC runs on Windows and keeps the registry's answer for a minute", context do
    World.put_app_env(:windows_editor_cache_ms, 60_000)
    :persistent_term.erase({HalC2.Editors, :windows_editor})
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({HalC2.Editors, :windows_editor}) end)

    context =
      windows_host(context, [{"UserChoice", "    ProgId    REG_SZ    txtfile"}])

    log = Path.join(context.bin, "reg.log")
    script = Path.join(context.bin, "reg")
    [shebang, body] = script |> File.read!() |> String.split("\n", parts: 2)
    File.write!(script, shebang <> "\necho query >> '#{log}'\n" <> body)
    Map.put(context, :reg_log, log)
  end

  step "a client reads the MC's server config a second time", context do
    context = Map.put(context, :queries_after_first, registry_queries(context))

    client =
      World.client(context)
      |> Mc.sub(10, %{"type" => "config", "environment" => context.mc.environment})

    {_frame, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == 10))
    World.put_client(context, client)
  end

  step "the registry was not queried again", context do
    assert context.queries_after_first > 0
    assert registry_queries(context) == context.queries_after_first
    context
  end

  defp registry_queries(context) do
    case File.read(context.reg_log) do
      {:ok, log} -> log |> String.split("\n", trim: true) |> length()
      {:error, _} -> 0
    end
  end

  step "the MC runs on Windows and reg never answers", context do
    World.put_app_env(:os_type, {:win32, :nt})
    install_script(bin(context), "reg", "exec sleep 30")
  end

  step "the MC runs on Windows with no program for text files", context do
    World.put_app_env(:os_type, {:win32, :nt})
    install_script(bin(context), "reg", "exit 1")
  end

  step ~r/^Windows opens "[^"]+" in Notepad$/, context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    assert argv == ["notepad", context.target]
    :gen_tcp.close(conn)
    context
  end

  # The fake editor is still running (it waits for the hangup): a launch that
  # waits on it, or buffers what it writes, would still hold its port here.
  step ~r/^Windows opens "[^"]+" in Notepad and the MC holds no port for it$/, context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    assert argv == ["notepad", context.target]

    names =
      for port <- Port.list(),
          {:name, name} <- [Port.info(port, :name)],
          do: List.to_string(name)

    refute Enum.any?(names, &String.ends_with?(&1, "/notepad")),
           "the MC still holds a port for the running editor: #{inspect(names)}"

    :gen_tcp.close(conn)
    context
  end

  step ~r/^Windows opens "[^"]+" in Notepad with the file where the command line puts it$/,
       context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)

    assert argv == [
             "notepad",
             "--visit",
             context.target,
             "--funcall",
             "whitespace-mode",
             "--file=" <> context.target,
             "--user-data-dir=C:\\Editor Data",
             "--name=a\"b",
             "C:\\Dir\\"
           ]

    :gen_tcp.close(conn)
    context
  end

  step ~r/^Windows opens "[^"]+" in Notepad with the other parameters filled in$/, context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    # %S is "1", a bare %2 is dropped, %W is the file's directory, %H and %I are "0".
    assert argv == [
             "notepad",
             context.target,
             "1",
             "--dir=#{Path.dirname(context.target)}",
             "0",
             "0"
           ]

    :gen_tcp.close(conn)
    context
  end

  step ~r/^Windows opens "[^"]+" in Notepad with the file appended after the other parameters$/,
       context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    # %S names no file, so the file goes last even though the line holds a placeholder.
    assert argv == ["notepad", "1", context.target]
    :gen_tcp.close(conn)
    context
  end

  step ~r/^Windows opens "[^"]+" in Notepad with the quoted empty parameter dropped$/,
       context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    # A quoted "%2" drops like the bare one, where the shell would pass one empty argument.
    assert argv == ["notepad", context.target]
    :gen_tcp.close(conn)
    context
  end

  step ~r/^Windows opens "[^"]+" in Notepad with the doubled quotes read as quotes$/, context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    assert argv == ["notepad", context.target, "say \"hi\" there"]
    :gen_tcp.close(conn)
    context
  end

  step "DISPLAY is set but empty and there is no Wayland display", context do
    World.put_os_env("DISPLAY", "")
    World.put_os_env("WAYLAND_DISPLAY", nil)
    context
  end

  step "the host's xdg-mime never answers", context do
    context |> with_display() |> install_script("xdg-mime", "exec sleep 30") |> install("gio")
  end

  step "the default editor is listed first", context do
    assert hd(context.server_config["availableEditors"]) == "default"
    context
  end

  step "the default editor is not offered", context do
    refute "default" in context.server_config["availableEditors"]
    context
  end

  step ~r/^a client opens "(?<file>[^"]+)" at line (?<line>\d+) column (?<column>\d+) in the default editor$/,
       %{args: [file, line, column]} = context do
    path = Path.join(Mc.tmp_dir(context.mc, "project"), file)

    context
    |> Map.put(:target, path)
    |> open(%{"cwd" => "#{path}:#{line}:#{column}", "editor" => "default"})
  end

  step ~r/^the MC launches Neovim's desktop entry on "[^"]+"$/, context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    assert argv == ["gio", "launch", context.entry, context.target]
    :gen_tcp.close(conn)
    context
  end

  step ~r/^macOS opens "[^"]+" in its default text editor$/, context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    assert argv == ["open", "-t", context.target]
    :gen_tcp.close(conn)
    context
  end

  step "a client opens a project folder in the file manager", context do
    context = with_display(context)
    folder = Mc.tmp_dir(context.mc, "project")
    context |> Map.put(:target, folder) |> open(%{"cwd" => folder, "editor" => "file-manager"})
  end

  step "the host's file manager shows that folder", context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    assert argv == ["xdg-open", context.target]
    :gen_tcp.close(conn)
    context
  end

  step "a Linux host with a display and xdg-open installed", context do
    with_display(context)
  end

  step "the host's file manager shows the folder that holds the file", context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    assert argv == ["xdg-open", Path.dirname(context.target)]
    :gen_tcp.close(conn)
    context
  end

  step "a client opens a file in the file manager", context do
    context = install_probe(context, "xdg-open")
    file = Path.join(Mc.tmp_dir(context.mc, "project"), "README.md")
    File.write!(file, "# hi\n")
    before = program_ports()
    context = context |> Map.put(:target, file) |> Map.put(:ports_before, before)
    open(context, %{"cwd" => file, "editor" => "file-manager"})
  end

  step "the program runs in a session of its own with no input or output shared with the MC",
       context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    [_name, _file, report] = argv
    [fd0, fd1, fd2, pid, pgid] = String.split(report)
    assert [fd0, fd1, fd2] == ["null", "null", "null"]

    {mc_pgid, 0} = System.cmd("ps", ["-o", "pgid=", "-p", to_string(:os.getpid())])
    refute pgid == String.trim(mc_pgid)
    # A new session's leader is the only member of its process group.
    assert pgid == pid
    Map.put(context, :editor_conn, conn)
  end

  step "the MC holds no process or port for it", context do
    # The program is still running, waiting on this socket.
    assert program_ports() -- context.ports_before == []
    assert :ok = :gen_tcp.send(context.editor_conn, "exit\n")
    :gen_tcp.close(context.editor_conn)
    context
  end

  step "the host has no setsid program", context do
    without_setsid(context)
  end

  step "a Linux host with no display", context do
    headless(context)
  end

  step "a client opens a folder in the file manager", context do
    open(context, %{"cwd" => Mc.tmp_dir(context.mc, "project"), "editor" => "file-manager"})
  end

  step "the MC fails saying the file manager is unsupported", context do
    refused(context, "ExternalLauncherUnsupportedEditorError")
  end

  step "the MC runs on macOS", context do
    World.put_app_env(:os_type, {:unix, :darwin})
    install(context, "open")
  end

  step "a client reveals a file in the file manager", context do
    file = Path.join(Mc.tmp_dir(context.mc, "project"), "README.md")
    File.write!(file, "# hi\n")

    context
    |> Map.put(:target, file)
    |> open(%{"cwd" => file, "editor" => "file-manager", "reveal" => true})
  end

  step "Finder shows the file selected in its folder", context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    assert argv == ["open", "-R", context.target]
    :gen_tcp.close(conn)
    context
  end

  step "a client opens a folder in an editor id the MC does not know", context do
    open(context, %{"cwd" => Mc.tmp_dir(context.mc, "project"), "editor" => "notepad"})
  end

  step "the MC fails saying the editor is unknown", context do
    refused(context, "ExternalLauncherUnknownEditorError")
  end

  step "Zed is not installed on the host", context do
    World.put_os_env("PATH", Mc.tmp_dir(context.mc, "empty-bin"))
    context
  end

  step "a client opens a folder in Zed", context do
    open(context, %{"cwd" => Mc.tmp_dir(context.mc, "project"), "editor" => "zed"})
  end

  step "the MC fails naming the command it could not find", context do
    context = refused(context, "ExternalLauncherCommandNotFoundError")
    assert inspect(context.reply) =~ ~s("command" => "zed")
    context
  end

  step "a client reads the available editors", context do
    server_config(context)
  end

  step "the file manager is not offered", context do
    refute "file-manager" in context.server_config["availableEditors"]
    context
  end

  # --- browsing folders --------------------------------------------------------------

  defp browse(context, partial) do
    {reply, context} = World.call(context, "filesystem.browse", %{"partialPath" => partial})
    Map.put(context, :reply, reply)
  end

  defp entries(context) do
    assert {:ok, %{"entries" => entries, "parentPath" => parent}} = context.reply
    assert parent == Path.join(context.user_home, "dev")
    for entry <- entries, do: assert(entry["fullPath"] == Path.join(parent, entry["name"]))
    Enum.map(entries, & &1["name"])
  end

  # Under the scenario's `$HOME` (`HalC2.Test.Mc.Host`); `context.user_home` names it.
  step "the home folder has a dev folder holding api, tests, tools, .tmp, .trash and a file todo.txt",
       context do
    dev = HalC2.Test.Mc.Host.path(context, "~/dev")

    for dir <- ~w(tools tests api .tmp .trash), do: File.mkdir_p!(Path.join(dev, dir))
    File.write!(Path.join(dev, "todo.txt"), "")
    Map.put(context, :user_home, HalC2.Test.Mc.Host.home(context))
  end

  step "the MC lists folders in {string} whose names start with {string}",
       %{args: ["~/dev", "t"]} = context do
    assert entries(context) == ["tests", "tools"]
    context
  end

  step "hidden folders are left out", context do
    assert File.dir?(Path.join(context.user_home, "dev/.tmp"))
    refute Enum.any?(entries(context), &String.starts_with?(&1, "."))
    context
  end

  step "the MC lists every folder in {string}, hidden ones included",
       %{args: ["~/dev"]} = context do
    # Every folder, and only folders: `todo.txt` is not one.
    assert entries(context) == [".tmp", ".trash", "api", "tests", "tools"]
    context
  end

  step "a client browses a path whose parent does not exist", context do
    browse(context, Path.join(Mc.tmp_dir(context.mc, "user-home"), "missing/t"))
  end

  step "the MC fails without listing anything", context do
    assert {:error, error, _} = context.reply
    assert error =~ "missing"
    context
  end

  # --- local servers -----------------------------------------------------------------

  defmodule Page do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts),
      do: conn |> put_resp_content_type("text/html") |> send_resp(200, "<h1>dev</h1>")
  end

  # Servers listen on a free port; the scenario's port number names that one.
  step "a development server is serving HTML on port {int}", %{args: [named]} = context do
    {:ok, server} =
      Bandit.start_link(plug: Page, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    context |> put_in([Access.key(:ports, %{}), named], port) |> Map.put(:dev_server, server)
  end

  step "a database is listening on port {int}", %{args: [named]} = context do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    put_in(context, [Access.key(:ports, %{}), named], port)
  end

  defp follow_local_servers(context) do
    Mc.ensure(HalC2.LocalServers)
    shape = %{"type" => "localServers", "mc" => Atom.to_string(node())}
    client = World.client(context) |> Mc.sub(11, shape)
    {frame, client} = Mc.await(client, &(&1["t"] == "localServers" and &1["id"] == 11), 10_000)
    context |> World.put_client(client) |> Map.put(:servers, ports(frame))
  end

  defp ports(frame), do: Enum.map(frame["list"]["servers"], & &1["port"])

  step "a client follows the host's local servers", context do
    follow_local_servers(context)
  end

  step "port {int} is listed", %{args: [named]} = context do
    assert context.ports[named] in context.servers
    context
  end

  step "port {int} is not listed", %{args: [named]} = context do
    refute context.ports[named] in context.servers
    context
  end

  step "a client follows the host's local servers with port {int} listed",
       %{args: [named]} = context do
    {:ok, server} = Bandit.start_link(plug: Page, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    context = context |> Map.put(:ports, %{named => port}) |> Map.put(:dev_server, server)
    context = follow_local_servers(context)
    assert port in context.servers
    Map.put(context, :stopped, named)
  end

  step "port {int} is removed from the list", %{args: [named]} = context do
    port = context.ports[named]

    # The next scan (every three seconds while someone watches) pushes the new list.
    {frame, client} =
      Mc.await(
        World.client(context),
        &(&1["t"] == "localServers" and &1["id"] == 11 and port not in ports(&1)),
        10_000
      )

    refute port in ports(frame)
    World.put_client(context, client)
  end

  step "nobody follows the host's local servers", context do
    Mc.ensure(HalC2.LocalServers)
    context
  end

  step "the MC does not scan the host's ports", context do
    state = :sys.get_state(HalC2.LocalServers)
    assert state.watchers == %{}
    assert state.timer == nil
    assert state.list == nil
    context
  end

  # --- paths and pipes ---------------------------------------------------------------

  step "a project path that loops through symlinks", context do
    dir = Mc.tmp_dir(context.mc, "loop")
    File.ln_s!(Path.join(dir, "b"), Path.join(dir, "a"))
    File.ln_s!(Path.join(dir, "a"), Path.join(dir, "b"))
    Map.put(context, :path, Path.join(dir, "a/project"))
  end

  step "the MC resolves it", context do
    Map.put(context, :resolved, HalC2.Paths.real(context.path))
  end

  step "it fails as a symlink loop", context do
    assert context.resolved == {:error, :eloop}
    context
  end

  step "a provider process writing output faster than the MC reads it", context do
    {:ok, sub} = HalC2.Subprocess.start(["yes", "a line of provider output"])
    assert_receive {:subprocess_lines, reader, lines}, 5_000
    Map.merge(context, %{sub: sub, reader: reader, first: lines})
  end

  step "the MC applies backpressure through the process's pipe", context do
    # Until the owner acknowledges a batch, the reader does not read again ...
    refute_receive {:subprocess_lines, _, _}, 300
    # ... so the writer blocks on the full pipe.
    wchan = File.read!("/proc/#{HalC2.Subprocess.os_pid(context.sub)}/wchan")
    assert wchan =~ "pipe", "the writer is in #{inspect(wchan)}"
    context
  end

  step "its memory stays bounded", context do
    assert IO.iodata_length(context.first) <= 65_535
    {:memory, memory} = Process.info(context.reader, :memory)
    assert memory < 1_000_000
    # Acknowledging lets exactly the next batch through.
    HalC2.Subprocess.ack(context.sub)
    assert_receive {:subprocess_lines, _, _}, 5_000
    refute_receive {:subprocess_lines, _, _}, 100
    HalC2.Subprocess.ack(context.sub)
    HalC2.Subprocess.stop(context.sub, 1_000)
    context
  end

  # --- GitHub over the GitHub CLI ----------------------------------------------------

  step ~r/^the GitHub CLI on the host is (?<state>signed in to github.com|not signed in)$/,
       %{args: [state]} = context do
    # gh in a directory with a space, as under a home or install path that has one.
    dir = Mc.tmp_dir(context.mc, "gh cli")
    World.put_os_env("PATH", dir <> ":" <> System.get_env("PATH"))
    gh = Path.join(dir, "gh")

    File.write!(gh, """
    #!/usr/bin/env bash
    [ "$*" = "auth git-credential get" ] && printf 'username=x-access-token\\npassword=from-gh\\n'
    """)

    File.chmod!(gh, 0o755)
    config = Mc.tmp_dir(context.mc, "gh")

    if state == "signed in to github.com",
      do: File.write!(Path.join(config, "hosts.yml"), "github.com:\n    user: acme\n")

    World.put_os_env("GH_CONFIG_DIR", config)
    Map.put(context, :gh_config, config)
  end

  step "the MC sets up the git it starts", context do
    before = for {"GIT_CONFIG_" <> _ = name, value} <- System.get_env(), do: {name, value}

    ExUnit.Callbacks.on_exit(fn ->
      for {"GIT_CONFIG_" <> _ = name, _} <- System.get_env(), do: System.delete_env(name)
      System.put_env(before)
    end)

    :ok = HalC2.Git.use_gh_for_github()
    context
  end

  # What it was started with stays in an agent's git; the MC only changes its own.
  step "an agent's git is already running", context do
    Map.put(context, :agent_env, for({"GIT_CONFIG_" <> _ = n, v} <- System.get_env(), do: {n, v}))
  end

  step ~r/^the GitHub CLI (?<change>signs in to github.com|signs out) and the MC is hot-updated$/,
       %{args: [change]} = context do
    hosts = Path.join(context.gh_config, "hosts.yml")

    if change == "signs out",
      do: File.rm!(hosts),
      else: File.write!(hosts, "github.com:\n    user: acme\n")

    # As an MC that runs as one: a test MC leaves its host alone otherwise.
    World.put_app_env(:start_mc, true)
    assert {:ok, _report} = HalC2.Upgrade.reload_checkout()
    context
  end

  step ~r/^(?<who>git|the agent's git) fetches "(?<url>[^"]+)" over (?<transport>HTTPS|SSH)$/,
       %{args: [who, url, transport]} = context do
    env =
      if who == "git",
        do: [],
        # Variables the MC set after the agent started are not in the agent's.
        else:
          for({"GIT_CONFIG_" <> _ = n, _} <- System.get_env(), into: %{}, do: {n, nil})
          |> Map.merge(Map.new(context.agent_env))
          |> Map.to_list()

    {fetched, 0} =
      System.cmd("git", ["ls-remote", "--get-url", url], cd: context.mc.home, env: env)

    expected =
      if transport == "HTTPS",
        do: String.replace(url, "git@github.com:", "https://github.com/"),
        else: url

    assert String.trim(fetched) == expected
    context
  end

  step "the GitHub CLI answers git's request for a GitHub credential", context do
    {answer, 0} =
      System.cmd(
        "sh",
        ["-c", "printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill"],
        cd: context.mc.home,
        env: [{"GIT_TERMINAL_PROMPT", "0"}]
      )

    assert answer =~ "password=from-gh"
    context
  end
end
