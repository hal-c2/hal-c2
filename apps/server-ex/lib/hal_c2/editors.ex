defmodule HalC2.Editors do
  @moduledoc """
  Editors this host can open a workspace in (`availableEditors`), and opening one
  (`shell.openInEditor`). The ids and launch styles mirror `EDITORS` in
  `packages/contracts/src/editor.ts`. The list only says how each editor takes a line;
  whatever the user set as their default text editor is offered too, as `default`.
  """

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
  # puts it (`{:file, "--open=%1"}`, from Windows), else last.
  defp with_file(args, file) do
    if Enum.any?(args, &match?({:file, _}, &1)) do
      for arg <- args do
        case arg do
          {:file, template} -> String.replace(template, file_placeholder(), fn _ -> file end)
          arg -> arg
        end
      end
    else
      args ++ [file]
    end
  end

  # `%1`, `%L` and `%l` in a registered command line stand for the file, and so does `%*`
  # (all arguments), as the file is the only one given. The file is put in by a function
  # because a replacement string would read the backslashes of a Windows path (`\\2`) as
  # group references.
  defp file_placeholder, do: ~r/%[1lL*]/

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
  # `shell\open\command`. Nil without one, and for a Store app, whose class names no command
  # line (it activates through `DelegateExecute`). Like xdg-mime, it runs while a client
  # waits for the server config, so the three queries share one 2 s deadline.
  defp windows_text_editor do
    task = Task.async(&registered_text_editor/0)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, editor} -> editor
      nil -> nil
    end
  end

  defp registered_text_editor do
    explorer = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts"

    with reg when reg != nil <- System.find_executable("reg"),
         class when class != nil <-
           reg_value(reg, [explorer <> "\\.txt\\UserChoice", "/v", "ProgId"]) ||
             reg_value(reg, ["HKCR\\.txt", "/ve"]),
         line when line != nil <-
           reg_value(reg, ["HKCR\\#{class}\\shell\\open\\command", "/ve"]),
         [command | args] <- command_words(expand_variables(line)) do
      {command,
       for arg <- args do
         if String.match?(arg, file_placeholder()), do: {:file, arg}, else: arg
       end}
    else
      _ -> nil
    end
  end

  # The data of the value `reg query` prints for `args`, or nil. `reg` writes in the
  # console's code page, so a path with characters outside ASCII can come back as invalid
  # UTF-8 and the launch then fails; a PowerShell query or `chcp 65001` would fix that.
  defp reg_value(reg, args) do
    with {out, 0} <- System.cmd(reg, ["query" | args], stderr_to_stdout: true),
         [_, data] <- Regex.run(~r/^\s+\S.*?\s+REG_[A-Z_]+\s+(\S.*?)\s*$/m, out) do
      data
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

  # A Windows command line split into arguments by the rules of `CommandLineToArgvW`: white
  # space separates arguments outside quotes, and a quote starts or ends quoted text inside
  # an argument (`--dir="C:\My Data"` is one argument). Backslashes only count before a
  # quote: 2n of them give n backslashes and the quote opens or closes quoted text, 2n+1
  # give n backslashes and a literal quote.
  defp command_words(line), do: split_words(line, nil, false, [])

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

  defp split_words(<<?", rest::binary>>, word, quoted, words),
    do: split_words(rest, word || "", not quoted, words)

  defp split_words(<<c, rest::binary>>, word, quoted, words),
    do: split_words(rest, (word || "") <> <<c>>, quoted, words)

  # The desktop entry id xdg-mime names for text/plain, or "". It runs while a client
  # waits for the server config, so a hung xdg-mime (a broken D-Bus or desktop session)
  # counts as no default after 2 s; killing the task takes xdg-mime with it.
  defp text_plain_handler(xdg_mime) do
    task =
      Task.async(fn ->
        try do
          Exile.stream!([xdg_mime, "query", "default", "text/plain"], stderr: :disable)
          |> Enum.join()
        rescue
          _ -> ""
        end
      end)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, id} -> String.trim(id)
      nil -> ""
    end
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

  # Editor CLIs hand off to the app and return; nothing waits on them.
  defp launch(command, args) do
    Task.start(fn -> System.cmd(command, args, stderr_to_stdout: true) end)
    {:ok, nil}
  end
end
