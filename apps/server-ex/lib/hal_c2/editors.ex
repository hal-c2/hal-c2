defmodule HalC2.Editors do
  @moduledoc """
  Editors this host can open a workspace in (`availableEditors`), and opening one
  (`shell.openInEditor`). The ids and launch styles mirror `EDITORS` in
  `packages/contracts/src/editor.ts`. The list only says how each editor takes a line;
  whatever the user set as their default text editor is offered too, as `default`.
  """

  require Logger

  # {id, commands, base args, how a `path:line:column` target is passed}
  @editors [
    {"cursor", ["cursor"], ["--classic"], :goto},
    {"trae", ["trae"], [], :goto},
    {"kiro", ["kiro"], ["ide"], :goto},
    {"vscode", ["code"], [], :goto},
    {"vscode-insiders", ["code-insiders"], [], :goto},
    {"vscodium", ["codium"], [], :goto},
    {"zed", ["zed", "zeditor"], [], :direct_path},
    {"antigravity", ["agy"], [], :goto},
    {"idea", ["idea"], [], :line_column},
    {"aqua", ["aqua"], [], :line_column},
    {"clion", ["clion"], [], :line_column},
    {"datagrip", ["datagrip"], [], :line_column},
    {"dataspell", ["dataspell"], [], :line_column},
    {"goland", ["goland"], [], :line_column},
    {"phpstorm", ["phpstorm"], [], :line_column},
    {"pycharm", ["pycharm"], [], :line_column},
    {"rider", ["rider"], [], :line_column},
    {"rubymine", ["rubymine"], [], :line_column},
    {"rustrover", ["rustrover"], [], :line_column},
    {"webstorm", ["webstorm"], [], :line_column}
  ]

  @doc "The ids of the editors installed here: the host's default first, the file manager last."
  def available do
    installed =
      for {id, commands, _, _} <- @editors, Enum.any?(commands, &System.find_executable/1), do: id

    if(default_editor(), do: ["default"], else: []) ++
      installed ++ if(file_manager(), do: ["file-manager"], else: [])
  end

  @doc "Opens `cwd` (optionally `path:line[:column]`) in an editor, without waiting for it."
  def open(%{"cwd" => target, "editor" => "file-manager"} = input) do
    case {file_manager(), input["reveal"]} do
      {nil, _} ->
        {:error,
         %{"_tag" => "ExternalLauncherUnsupportedEditorError", "editor" => "file-manager"}}

      {"open", true} ->
        launch("open", ["-R", target])

      # xdg-open has no way to select a file, and opening the file would start whatever
      # the desktop maps its type to; showing the folder is what "reveal" means here.
      {"xdg-open", true} ->
        launch("xdg-open", [if(File.dir?(target), do: target, else: Path.dirname(target))])

      {command, _} ->
        launch(command, [target])
    end
  end

  # The default editor is handed a path alone: there is no common way to say a line.
  def open(%{"cwd" => target, "editor" => "default"}) do
    case default_editor() do
      nil ->
        {:error, %{"_tag" => "ExternalLauncherUnsupportedEditorError", "editor" => "default"}}

      {command, args} ->
        launch(command, with_file(args, Regex.replace(~r/:\d+(?::\d+)?$/, target, "")))
    end
  end

  def open(%{"cwd" => target, "editor" => id}) do
    case List.keyfind(@editors, id, 0) do
      nil ->
        {:error, %{"_tag" => "ExternalLauncherUnknownEditorError", "editor" => id}}

      {_, commands, base, style} ->
        case Enum.find_value(commands, &System.find_executable/1) do
          nil ->
            {:error,
             %{
               "_tag" => "ExternalLauncherCommandNotFoundError",
               "editor" => id,
               "command" => hd(commands)
             }}

          command ->
            launch(command, base ++ args(style, target))
        end
    end
  end

  # The default editor's arguments with `file` in them: where the registered command line
  # puts it (`{:file, "--open=%1"}`, from Windows), else last. Only the placeholders that
  # stand for the file (`%1`, `%L`, `%l`, `%*`) decide that: an argument holding only
  # other parameters (`%S`, `%2`) is no place for the file, so it still goes last. An
  # argument that is left empty (a bare `%2`, which the shell fills with the extra
  # parameter there is none of) is dropped, as the shell's command line parsing drops it.
  # A quoted bare placeholder (`"%2"`) drops too, where the shell would pass one empty
  # argument instead: quoting is already lost by the split, so this is a deliberate
  # small divergence from the shell.
  defp with_file(args, file) do
    substituted =
      Enum.flat_map(args, fn
        {:file, template} ->
          case String.replace(template, file_placeholder(), &placeholder_value(&1, file)) do
            "" -> []
            arg -> [arg]
          end

        arg ->
          [arg]
      end)

    if Enum.any?(args, &file_argument?/1), do: substituted, else: substituted ++ [file]
  end

  # Whether the argument names the file, which is what decides against appending it last.
  defp file_argument?({:file, template}), do: String.match?(template, ~r/%[1lL*]/)
  defp file_argument?(_), do: false

  # The shell parameters of a registered command line. `%1`, `%L` and `%l` stand for the
  # file, and so does `%*` (all arguments), as the file is the only one given. The others
  # get what the shell gives a program started without them: `%S` the show command
  # (normal), `%H` and `%I` no window or DDE handle, `%W` the working directory (there is
  # none per call) and `%2` to `%9` the extra parameters (there are none). The values are
  # put in by a function because a replacement string would read the backslashes of a
  # Windows path (`\\2`) as group references.
  defp file_placeholder, do: ~r/%[1lL*SHIW2-9]/

  defp placeholder_value("%S", _file), do: "1"
  defp placeholder_value("%" <> parameter, _file) when parameter in ["H", "I"], do: "0"

  defp placeholder_value("%" <> parameter, _file) when parameter in ["W" | ~w(2 3 4 5 6 7 8 9)],
    do: ""

  defp placeholder_value(_file_parameter, file), do: file

  defp args(style, target) do
    case {style, Regex.run(~r/^(.*?):(\d+)(?::(\d+))?$/, target)} do
      {:goto, [_ | _]} -> ["--goto", target]
      {:line_column, [_, path, line]} -> ["--line", line, path]
      {:line_column, [_, path, line, column]} -> ["--line", line, "--column", column, path]
      _ -> [target]
    end
  end

  # How to launch the user's default text editor, or nil without one. On Linux that is the
  # desktop entry `xdg-mime` names for text/plain, run through `gio launch`, which also
  # opens a terminal for terminal editors such as Neovim. On macOS it is `open -t`, on
  # Windows the program registered for `.txt`.
  defp default_editor do
    case Application.get_env(:hal_c2, :os_type, :os.type()) do
      {:unix, :darwin} ->
        {"open", ["-t"]}

      {:win32, _} ->
        windows_text_editor()

      _ ->
        with true <- display?(),
             xdg_mime when xdg_mime != nil <- System.find_executable("xdg-mime"),
             gio when gio != nil <- System.find_executable("gio"),
             entry when entry != nil <- desktop_entry(text_plain_handler(xdg_mime)) do
          {gio, ["launch", entry]}
        else
          _ -> nil
        end
    end
  end

  # The program Windows opens `.txt` files with, from the registry through `reg query`: the
  # user's choice, else the class registered for the extension, and that class's
  # `shell\open\command`. Nil without one. A Store app's class names no command line (it
  # activates through `DelegateExecute`), and `reg` then prints the localized text
  # "(value not set)" as the data, so the program must resolve to an executable: that also
  # drops an association to an uninstalled editor, and a command line whose program is an
  # unquoted path with spaces (`C:\Program Files\Editor\e.exe %1` splits to program
  # `C:\Program`, which counts as no editor unless that first word itself resolves — on
  # Windows the lookup also tries executable extensions, so a planted `C:\Program.exe`
  # would still win; fuller handling is tracked in #409). Prefix matching stays out on
  # purpose: if it is ever added it must try the longest join of leading words first,
  # never CreateProcess's shortest-first order, which runs a planted `C:\Program.exe`.
  # Two more divergences from Explorer: the `UserChoice`
  # `Hash` is not validated (Windows ignores a choice whose hash does not match) and
  # `UserChoiceLatest` is not read, so the MC can name an editor Explorer would not use.
  # Like xdg-mime, it runs while a client waits for the server config, so the three queries
  # share one 2 s deadline (`lookup/2`). On timeout the task is killed, which closes its
  # port but may leave a hung `reg.exe` to exit on its own: the deadline protects the
  # client, not the process table.
  defp windows_text_editor, do: lookup(&registered_text_editor/0, nil)

  # Runs `fun` in a task for at most 2 s: a lookup that hangs, raises (a program path that
  # is not valid UTF-8, a vanished executable) or exits counts as `default`, and never
  # takes the caller down with it.
  defp lookup(fun, default) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          _ -> default
        catch
          _, _ -> default
        end
      end)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      _ -> default
    end
  end

  defp registered_text_editor do
    explorer = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts"

    # The `UserChoice` ProgId is taken as it stands (see `windows_text_editor/0`).
    with reg when reg != nil <- System.find_executable("reg"),
         editor when editor != nil <- windows_editor(reg, explorer) do
      editor
    else
      _ -> nil
    end
  end

  # The editor that opens `.txt` files: the `shell\open\command` of the class the
  # user's choice names, else the class registered for the extension. A choice naming
  # a class with no usable command (a Store app's `DelegateExecute` class, an
  # uninstalled editor) falls through to the extension's class, as Explorer discards
  # an invalid choice. Nil without either.
  defp windows_editor(reg, explorer) do
    with nil <-
           editor_of_class(
             reg,
             reg_class(reg, [explorer <> "\\.txt\\UserChoice", "/v", "ProgId"])
           ) do
      editor_of_class(reg, reg_class(reg, ["HKCR\\.txt", "/ve"]))
    end
  end

  # The class a registry value names, or nil.
  defp reg_class(reg, args) do
    case reg_value(reg, args) do
      {_, class} -> class
      nil -> nil
    end
  end

  # The editor a registry class opens text files in, or nil. Only `REG_EXPAND_SZ`
  # command data holds `%VAR%` for the shell to expand; a `REG_SZ` command line keeps
  # its percent signs literally, as the shell leaves them.
  defp editor_of_class(_reg, nil), do: nil

  defp editor_of_class(reg, class) do
    case reg_value(reg, ["HKCR\\#{class}\\shell\\open\\command", "/ve"]) do
      nil ->
        nil

      {type, line} ->
        line = if type == "REG_EXPAND_SZ", do: expand_variables(line), else: line

        with [program | args] <- command_words(line),
             command when command != nil <- System.find_executable(program) do
          {command,
           for arg <- args do
             if String.match?(arg, file_placeholder()), do: {:file, arg}, else: arg
           end}
        else
          _ -> nil
        end
    end
  end

  # The `{type, data}` of the value `reg query` prints for `args`, or nil. `reg` writes
  # in the console's code page, so a path with characters outside ASCII can come back
  # as invalid UTF-8, which counts as no value (no editor offered); a PowerShell query
  # or `chcp 65001` would read it.
  defp reg_value(reg, args) do
    with {out, 0} <- System.cmd(reg, ["query" | args], stderr_to_stdout: true),
         [_, type, data] <- Regex.run(~r/^\s+\S.*?\s+(REG_[A-Z_]+)\s+(\S.*?)\s*$/m, out),
         true <- String.valid?(data) do
      {type, data}
    else
      _ -> nil
    end
  end

  # `%SystemRoot%` and the like, as REG_EXPAND_SZ data holds them; `%1` is not one.
  defp expand_variables(line) do
    Regex.replace(~r/%([A-Za-z_][A-Za-z0-9_()]*)%/, line, fn all, name ->
      System.get_env(name) || all
    end)
  end

  # A Windows command line split into arguments by the MSVC CRT rules (not
  # `CommandLineToArgvW`, which toggles quoting on a doubled quote instead): white space
  # separates arguments outside quotes, and a quote starts or ends quoted text inside an
  # argument (`--dir="C:\My Data"` is one argument). The CRT reading is the useful one
  # here because the editor's own runtime re-parses the final command line. Backslashes
  # only count before a quote: 2n of them give n backslashes and the quote opens or
  # closes quoted text, 2n+1 give n backslashes and a literal quote. Inside quoted text
  # a doubled quote is one literal quote and the text stays quoted (`"a""b"` is `a"b`).
  @doc false
  def command_words(line), do: split_words(line, nil, false, [])

  defp split_words("", nil, _quoted, words), do: Enum.reverse(words)
  defp split_words("", word, _quoted, words), do: Enum.reverse([word | words])

  defp split_words(<<c, rest::binary>>, word, false, words) when c in [?\s, ?\t],
    do: split_words(rest, nil, false, if(word, do: [word | words], else: words))

  defp split_words(<<?\\, _::binary>> = line, word, quoted, words) do
    [slashes] = Regex.run(~r/^\\+/, line)
    count = byte_size(slashes)
    rest = binary_part(line, count, byte_size(line) - count)

    case rest do
      <<?", after_quote::binary>> ->
        word = (word || "") <> String.duplicate("\\", div(count, 2))

        if rem(count, 2) == 1,
          do: split_words(after_quote, word <> ~s("), quoted, words),
          else: split_words(after_quote, word, not quoted, words)

      _ ->
        split_words(rest, (word || "") <> slashes, quoted, words)
    end
  end

  defp split_words(<<?", ?", rest::binary>>, word, true, words),
    do: split_words(rest, (word || "") <> ~s("), true, words)

  defp split_words(<<?", rest::binary>>, word, quoted, words),
    do: split_words(rest, word || "", not quoted, words)

  defp split_words(<<c, rest::binary>>, word, quoted, words),
    do: split_words(rest, (word || "") <> <<c>>, quoted, words)

  # The desktop entry id xdg-mime names for text/plain, or "". It runs while a client
  # waits for the server config, so a hung xdg-mime (a broken D-Bus or desktop session)
  # counts as no default after 2 s; killing the task takes xdg-mime with it.
  defp text_plain_handler(xdg_mime) do
    lookup(
      fn ->
        Exile.stream!([xdg_mime, "query", "default", "text/plain"], stderr: :disable)
        |> Enum.join()
      end,
      ""
    )
    |> String.trim()
  end

  # The file of desktop entry `id`, searched for as the XDG base directory spec says: a
  # variable that is unset, empty or relative falls back to its default. An entry in a
  # subfolder has the folders in its id (`vendor/editor.desktop` is `vendor-editor.desktop`),
  # so a folder without the file by name is searched for one with that id.
  defp desktop_entry(""), do: nil

  defp desktop_entry(id) do
    home = xdg_dirs("XDG_DATA_HOME", Path.join(System.user_home!(), ".local/share"))
    dirs = xdg_dirs("XDG_DATA_DIRS", "/usr/local/share:/usr/share")

    Enum.find_value(home ++ dirs, fn dir ->
      applications = Path.join(dir, "applications")
      direct = Path.join(applications, id)

      if File.regular?(direct) do
        direct
      else
        applications
        |> Path.join("*/**/*.desktop")
        |> Path.wildcard()
        |> Enum.find(&(Path.relative_to(&1, applications) |> String.replace("/", "-") == id))
      end
    end)
  end

  defp xdg_dirs(name, default) do
    case (System.get_env(name) || "") |> String.split(":") |> Enum.filter(&absolute?/1) do
      [] -> String.split(default, ":")
      dirs -> dirs
    end
  end

  defp absolute?(path), do: Path.type(path) == :absolute

  defp display?, do: Enum.any?(["DISPLAY", "WAYLAND_DISPLAY"], &(System.get_env(&1, "") != ""))

  # `config :hal_c2, os_type:` stands in for `:os.type()` in tests.
  defp file_manager do
    case Application.get_env(:hal_c2, :os_type, :os.type()) do
      {:unix, :darwin} ->
        "open"

      {:win32, _} ->
        "explorer"

      _ ->
        if display?() && System.find_executable("xdg-open"), do: "xdg-open"
    end
  end

  # Editor CLIs hand off to the app and return; nothing waits on them. On Unix the app is
  # started detached: in a session of its own and with its standard streams on /dev/null,
  # so it outlives the MC and shares no pipe with it. Without that, a program that does
  # not exit on its own (`xdg-open` starting a terminal editor with no terminal) kept the
  # MC's end of the pipe open, and the process and its port stayed until the MC stopped.
  # The shell returns as soon as it has started the program, so this does not wait on it.
  defp launch(command, args) do
    case Application.get_env(:hal_c2, :os_type, :os.type()) do
      {:win32, _} ->
        launch_detached(command, args)

      _ ->
        script = ~s("$@" </dev/null >/dev/null 2>&1 &)
        System.cmd("/bin/sh", ["-c", script, "sh" | new_session() ++ [command | args]])
    end

    {:ok, nil}
  end

  # On Windows the editor is spawned detached: no standard streams, and the port is
  # closed as soon as the program starts, so nothing waits on it and nothing it writes
  # is buffered. A default editor can be a GUI program that stays open until the user
  # closes it; `System.cmd` in a task pinned a task and a port for that whole lifetime.
  # A program that cannot be found or started counts as launched, as it did in the task;
  # a start that raises is logged and counts as launched too, so a click that starts
  # nothing still answers `:ok` (the caller has no channel for the failure).
  # Two more accepted divergences from Explorer, unverified on a real Windows host
  # (tracked in #397): `:spawn_executable` is CreateProcess-backed and cannot run
  # `.cmd`/`.bat` shims (those need `%ComSpec% /c`), so a default resolving to one
  # starts nothing; and `:hide` with `:nouse_stdio` suits a GUI program, while a
  # registered console editor gets no console and no standard streams.
  defp launch_detached(command, args) do
    with path when path != nil <- System.find_executable(command) do
      port = Port.open({:spawn_executable, path}, [:binary, :nouse_stdio, :hide, args: args])
      Port.close(port)
    end
  rescue
    error ->
      Logger.warning("default editor failed to start: #{inspect(command)}: #{inspect(error)}")
      nil
  end

  # The program that puts what it runs in a session of its own, so the desktop stopping
  # the MC's process group does not take the editor with it. Linux has `setsid`; stock
  # macOS does not, but ships perl. With neither, the program only loses the MC's pipes.
  defp new_session do
    cond do
      setsid = System.find_executable("setsid") ->
        [setsid]

      perl = System.find_executable("perl") ->
        [perl, "-MPOSIX", "-e", "POSIX::setsid(); exec @ARGV or die"]

      true ->
        []
    end
  end
end
