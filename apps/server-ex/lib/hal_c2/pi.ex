defmodule HalC2.Pi do
  @moduledoc """
  Pi in its native RPC mode (`pi --mode rpc`): JSON lines of `{type, id?, ...}`
  commands on stdin, and responses and events on stdout (`HalC2.JsonRpc`'s `:pi`
  dialect). Mirrors the Node server's `PiProvider.ts`, `piHalC2McpInjection.ts` and
  `PiCommands.ts`; turns run in `HalC2.Pi.ThreadRuntime`.

  This module holds what the provider entry and the runtime share: the user's
  launch arguments (`providers.pi.launchArgs`) with the ones HAL-C2 owns refused,
  the command line and environment of a Pi process, HAL-C2's Pi extension (HAL-C2's MCP
  tools and the access-mode gate, `priv/pi/hal-c2-mcp-extension.ts`), model and command
  discovery from a throwaway session, and Pi's thinking levels.
  """

  alias HalC2.JsonRpc.Connection

  @reserved ~w(--continue -c --export --fork --help -h --list-models --mode --no-session --print -p --resume -r --session --session-id --version -v)
  @with_value ~w(--api-key --append-system-prompt --exclude-tools -xt --extension -e --model --models --name -n --prompt-template --provider --session-dir --skill --system-prompt --theme --thinking --tools -t --tui-mode --use-theme)
  @without_value ~w(--approve -a --no-approve -na --no-builtin-tools -nbt --no-context-files -nc --no-extensions -ne --no-prompt-templates -np --no-skills -ns --no-themes --no-tools -nt --offline --verbose)

  @levels ~w(off minimal low medium high xhigh max)
  @level_labels %{
    "off" => "Off",
    "minimal" => "Minimal",
    "low" => "Low",
    "medium" => "Medium",
    "high" => "High",
    "xhigh" => "Extra High",
    "max" => "Max"
  }

  # Pi's RPC `get_commands` leaves out its TUI builtins; HAL-C2 maps /compact to `compact`.
  @compact %{
    "name" => "compact",
    "description" => "Summarize the conversation and reduce context usage",
    "input" => %{"hint" => "Optional instructions"}
  }

  @doc """
  The user's launch arguments, split as a shell would, or why HAL-C2 refuses them:
  `{:ok, args} | {:error, message}`. Arguments that pick Pi's mode or session
  belong to HAL-C2; positional prompts and unknown short flags are refused.
  """
  def resolve_launch_args(text) when text in [nil, ""], do: {:ok, []}

  def resolve_launch_args(text) when is_binary(text) do
    args =
      text
      |> OptionParser.split()
      |> Enum.flat_map(fn arg ->
        case String.split(arg, "=", parts: 2) do
          [option, value] when option in @with_value -> [option, value]
          _ -> [arg]
        end
      end)

    check(args, args)
  end

  defp check([], args), do: {:ok, args}

  defp check([arg | rest], args) do
    reserved =
      Enum.find(@reserved, fn reserved ->
        arg == reserved or
          (String.starts_with?(reserved, "--") and String.starts_with?(arg, reserved <> "="))
      end)

    cond do
      reserved ->
        {:error,
         "Pi launch argument '#{reserved}' is controlled by HAL-C2 and cannot be overridden."}

      arg == "--" ->
        {:error, "Pi launch arguments cannot include positional prompts."}

      arg in @with_value ->
        case rest do
          [_value | rest] -> check(rest, args)
          [] -> {:error, "Pi launch argument '#{arg}' requires a value."}
        end

      arg in @without_value or (String.starts_with?(arg, "--") and String.contains?(arg, "=")) ->
        check(rest, args)

      # An extension's own flag takes the next word as its value.
      String.starts_with?(arg, "--") ->
        case rest do
          [value | more] ->
            if String.starts_with?(value, ["-", "@"]),
              do: check(rest, args),
              else: check(more, args)

          [] ->
            check(rest, args)
        end

      String.starts_with?(arg, "-") ->
        {:error, "Pi launch argument '#{arg}' is not supported by HAL-C2."}

      true ->
        {:error, "Pi launch arguments cannot include positional prompt '#{arg}'."}
    end
  end

  @doc """
  The command line and environment of a Pi RPC process for `instance`, or
  `{:error, message}` when its launch arguments are refused. Options:
  `:runtime_mode` (the access mode HAL-C2's extension enforces), `:mcp`
  (`HalC2.Mcp.for_agent/2`'s server), `:ephemeral` (no session file), `:bare` (no
  extensions and no tools, for a short-lived process that only copies a session),
  and `:extra` (arguments after HAL-C2's own).
  """
  def launch(instance, opts \\ []) do
    with {:ok, args} <- resolve_launch_args(HalC2.Acp.setting(instance, "launchArgs")) do
      bare = Keyword.get(opts, :bare, false)
      ephemeral = Keyword.get(opts, :ephemeral, false)
      extension = not bare and not ephemeral
      args = if bare, do: without_extensions(args), else: args

      argv =
        [HalC2.Acp.binary_path(instance), "--mode", "rpc"] ++
          if(ephemeral, do: ["--no-session"], else: []) ++
          args ++
          if(bare, do: ["--no-extensions", "--no-tools"], else: []) ++
          if(extension, do: ["--extension", extension_path()], else: []) ++
          Keyword.get(opts, :extra, [])

      mcp = if extension, do: opts[:mcp]
      mode = if opts[:runtime_mode] == "auto", do: "approval-required", else: opts[:runtime_mode]

      # A Pi child never reuses HAL-C2 credentials it inherited from the node.
      env =
        HalC2.Acp.instance_env(instance) ++
          [
            {"HALC2_MCP_URL", (mcp && mcp.url) || ""},
            {"HALC2_MCP_BEARER_TOKEN",
             (mcp && String.replace_prefix(mcp.authorization, "Bearer ", "")) || ""}
          ] ++
          if(extension && mode, do: [{"HALC2_PI_RUNTIME_MODE", mode}], else: [])

      {:ok, argv, env}
    end
  end

  defp without_extensions(args) do
    {kept, _skip} =
      Enum.reduce(args, {[], false}, fn
        _arg, {kept, true} -> {kept, false}
        arg, {kept, false} when arg in ["--extension", "-e"] -> {kept, true}
        "--extension=" <> _, acc -> acc
        arg, {kept, false} -> {[arg | kept], false}
      end)

    kept
    |> Enum.reverse()
    |> Enum.reject(&(&1 in ["--tools", "-t"]))
  end

  @doc "HAL-C2's Pi extension, written under the HAL-C2 home where Pi can load it."
  def extension_path do
    path =
      Path.join([Application.fetch_env!(:hal_c2, :home), "caches", "pi", "pi-hal-c2-mcp-extension.ts"])

    source = File.read!(Application.app_dir(:hal_c2, "priv/pi/hal-c2-mcp-extension.ts"))

    if File.read(path) != {:ok, source} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
    end

    path
  end

  @doc """
  Reads Pi's models, commands and skills from a throwaway session in `cwd`:
  `{:ok, %{models, commands, skills}}`, where `models` are Pi's own (without
  "Pi default"), or `{:error, reason}`.
  """
  def discover(instance, cwd) do
    with {:ok, argv, env} <- launch(instance, ephemeral: true),
         {:ok, conn} <-
           Connection.start_link(cmd: argv, handler: self(), cd: cwd, env: env, dialect: :pi) do
      try do
        with {:ok, state} <- Connection.call(conn, "get_state", %{}, 15_000),
             {:ok, available} <- Connection.call(conn, "get_available_models", %{}, 15_000) do
          commands =
            case Connection.call(conn, "get_commands", %{}, 15_000) do
              {:ok, data} -> data
              {:error, _} -> nil
            end

          {slash, skills} = parse_commands(commands)

          {:ok,
           %{
             models: models(available, (state || %{})["thinkingLevel"]),
             commands: [@compact | Enum.reject(slash, &(&1["name"] == "compact"))],
             skills: skills
           }}
        end
      after
        Connection.stop(conn)
      end
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp models(data, level) do
    for %{"provider" => provider, "id" => id} = model <- (data || %{})["models"] || [],
        is_binary(provider) and is_binary(id),
        uniq: true do
      slug = "#{provider}/#{id}"

      %{
        "slug" => slug,
        "name" => text(model["name"]) || slug,
        "isCustom" => false,
        "capabilities" => %{"optionDescriptors" => thinking(model, level)}
      }
    end
  end

  @doc """
  The thinking levels a Pi model offers, as a "thinking" select descriptor
  (`piThinkingCapabilities.ts`): reasoning models get off through high unless their
  `thinkingLevelMap` rules a level out, and Extra High and Max only when it names
  them. `level`, Pi's configured level, is clamped onto them as the default.
  """
  def thinking(model, level) do
    map = if is_map(model["thinkingLevelMap"]), do: model["thinkingLevelMap"], else: %{}

    levels =
      if model["reasoning"] == true do
        Enum.filter(@levels, fn l ->
          case Map.fetch(map, l) do
            {:ok, nil} -> false
            {:ok, _} -> true
            :error -> l not in ["xhigh", "max"]
          end
        end)
      else
        []
      end

    case levels do
      [] ->
        []

      levels ->
        default = clamp(level, levels)

        [
          %{
            "id" => "thinking",
            "label" => "Thinking",
            "type" => "select",
            "options" =>
              for l <- levels do
                %{"id" => l, "label" => @level_labels[l]}
                |> then(&if(l == default, do: Map.put(&1, "isDefault", true), else: &1))
              end
          }
        ]
    end
  end

  defp clamp(level, levels) do
    case Enum.find_index(@levels, &(&1 == level)) do
      nil ->
        nil

      index ->
        higher = Enum.drop(@levels, index)
        lower = @levels |> Enum.take(index) |> Enum.reverse()
        Enum.find(higher ++ lower, &(&1 in levels)) || hd(levels)
    end
  end

  @doc """
  Pi's `get_commands` as HAL-C2's slash commands and skills (`PiCommands.ts`): a
  `skill`-sourced command is the skill without its `skill:` prefix.
  """
  def parse_commands(data) do
    commands = (is_map(data) && data["commands"]) || []

    Enum.reduce(commands, {[], []}, fn command, {slash, skills} ->
      name = text(command["name"])
      info = if is_map(command["sourceInfo"]), do: command["sourceInfo"], else: %{}

      cond do
        name == nil ->
          {slash, skills}

        command["source"] == "skill" ->
          skill = String.replace_prefix(name, "skill:", "")

          entry =
            %{
              "name" => skill,
              "path" => text(info["path"]) || text(command["path"]) || "pi:skill:#{skill}",
              "enabled" => true
            }
            |> put_text("description", command["description"])
            |> put_text("scope", scope(text(info["scope"]) || text(command["location"])))
            |> put_text("displayName", command["displayName"] || info["displayName"])

          if skill == "", do: {slash, skills}, else: {slash, skills ++ [entry]}

        true ->
          {slash ++ [put_text(%{"name" => name}, "description", command["description"])], skills}
      end
    end)
  end

  defp scope(nil), do: nil

  defp scope(scope) do
    case String.downcase(scope) do
      s when s in ["global", "personal"] -> "user"
      s when s in ["workspace", "local"] -> "project"
      _ -> scope
    end
  end

  @doc """
  Pi expands skills only from leading `/skill:name` commands; HAL-C2 writes skills as
  `$name`. Every known `$name` moves to the front as Pi's command.
  """
  def expand_skills(text, []), do: text

  def expand_skills(text, names) do
    found =
      for [_, name] <- Regex.scan(~r/(?:^|\s)\$(\S+)(?=\s|$)/, text),
          name in names,
          uniq: true,
          do: name

    case found do
      [] ->
        text

      found ->
        body =
          ~r/(^|\s)\$(\S+)(?=\s|$)/
          |> Regex.replace(text, fn whole, space, name ->
            if name in found, do: space, else: whole
          end)
          |> String.split(~r/\s+/, trim: true)
          |> Enum.join(" ")

        prefix = Enum.map_join(found, " ", &"/skill:#{&1}")
        if body == "", do: prefix, else: "#{prefix} #{body}"
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil

  defp put_text(map, key, value) do
    case text(value) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end
end
