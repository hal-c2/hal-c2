defmodule HalC2.Acp.GrokPlan do
  @moduledoc """
  Grok writes its plan to `plan.md` in its session folder while it is in plan mode.
  The write shows as the thread's plan before Grok leaves plan mode. The file is
  recognised by where it is: under the sessions folder of a Grok home, never a
  `plan.md` of the workspace.
  """

  @home_session ~r{^(?:/home/[^/]+|/Users/[^/]+|[a-zA-Z]:/Users/[^/]+)/\.grok/sessions/(?:[^/]+/)+plan\.md$}
  @home_session_ci ~r{^(?:/home/[^/]+|/Users/[^/]+|[a-zA-Z]:/Users/[^/]+)/\.grok/sessions/(?:[^/]+/)+plan\.md$}i

  @doc """
  The sessions folders a launch's environment names: `$GROK_HOME/sessions/` and the
  `.grok/sessions/` of the home folders.
  """
  def prefixes(env) do
    env = Map.new(env)
    homes = [System.user_home(), "~", env["HOME"], env["USERPROFILE"]]
    grok_home = env["GROK_HOME"]

    for(home <- homes, root = root(home), root != nil, do: root <> "/.grok/sessions/") ++
      for(root <- [root(grok_home)], root != nil, suffix <- ["/sessions/", "/.grok/sessions/"]) do
        root <> suffix
      end
  end

  defp root(value) when is_binary(value) do
    case value |> String.trim() |> String.replace("\\", "/") |> String.trim_trailing("/") do
      "" -> nil
      root -> root
    end
  end

  defp root(_value), do: nil

  @doc "Whether `path` is the plan file of a Grok session, under one of `prefixes`."
  def plan_file?(path, prefixes) when is_binary(path) do
    win32? = match?({:win32, _}, Application.get_env(:hal_c2, :os_type, :os.type()))
    normalized = path |> String.trim() |> String.replace("\\", "/")
    haystack = if win32?, do: String.downcase(normalized), else: normalized

    normalized != "" and String.ends_with?(haystack, "/plan.md") and
      ".." not in String.split(normalized, "/") and
      (Enum.any?(prefixes, &in_session?(haystack, if(win32?, do: String.downcase(&1), else: &1))) or
         Regex.match?(if(win32?, do: @home_session_ci, else: @home_session), haystack))
  end

  def plan_file?(_path, _prefixes), do: false

  # <sessions>/<encoded cwd>/<session id>/plan.md: something sits between.
  defp in_session?(haystack, prefix) do
    if String.starts_with?(haystack, prefix) do
      rest = binary_part(haystack, byte_size(prefix), byte_size(haystack) - byte_size(prefix))
      rest != "plan.md" and String.ends_with?(rest, "plan.md")
    else
      false
    end
  end

  @doc """
  The plan a tool call writes to the plan file: `""` when it writes an empty one, nil
  when it writes none. Read from the call's raw input or from its diff blocks.
  """
  def markdown(call, prefixes) do
    input = if is_map(call["rawInput"]), do: call["rawInput"], else: %{}
    path = if is_binary(input["file_path"]), do: input["file_path"], else: input["path"]

    writes =
      [{path, input["content"]}] ++
        for %{"type" => "diff"} = block <- List.wrap(call["content"]),
            do: {block["path"], block["newText"]}

    Enum.find_value(writes, fn {path, text} ->
      if is_binary(text) and plan_file?(path, prefixes), do: String.trim(text)
    end)
  end
end
