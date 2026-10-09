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
        launch(command, args ++ [Regex.replace(~r/:\d+(?::\d+)?$/, target, "")])
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
  # opens a terminal for terminal editors such as Neovim.
  defp default_editor do
    case Application.get_env(:hal_c2, :os_type, :os.type()) do
      {:unix, :darwin} ->
        {"open", ["-t"]}

      {:win32, _} ->
        nil

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
  # variable that is unset, empty or relative falls back to its default.
  defp desktop_entry(""), do: nil

  defp desktop_entry(id) do
    home = xdg_dirs("XDG_DATA_HOME", Path.join(System.user_home!(), ".local/share"))
    dirs = xdg_dirs("XDG_DATA_DIRS", "/usr/local/share:/usr/share")

    (home ++ dirs)
    |> Enum.map(&Path.join([&1, "applications", id]))
    |> Enum.find(&File.regular?/1)
  end

  defp xdg_dirs(name, default) do
    case (System.get_env(name) || "") |> String.split(":") |> Enum.filter(&absolute?/1) do
      [] -> String.split(default, ":")
      dirs -> dirs
    end
  end

  defp absolute?(path), do: Path.type(path) == :absolute

  defp display?, do: (System.get_env("DISPLAY") || System.get_env("WAYLAND_DISPLAY")) != nil

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
