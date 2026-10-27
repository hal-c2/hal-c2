defmodule HalC2.Acp.Antigravity.Protocol do
  @moduledoc """
  Antigravity's corners of the ACP protocol, ported from upstream T3 Code's
  `AntigravityProtocol.ts` (pingdotgg/t3code#2829): approvals that offer only
  the choices the agent gave, questions carried on the permission method,
  native command fields, and bounds on tool data before it is stored.

  Tool text keeps its last 8,000 characters under a truncation marker, one
  tool report keeps at most 512 entries and 64,000 characters, and inline
  image data is dropped. What the agent writes as its answer is not touched:
  only tool calls pass through here.
  """

  @text_limit 8_000
  @truncated "[Earlier output truncated]\n\n"
  @label_limit 512
  @warning_limit 512
  @warning_key "agy.security.warning"

  @image_extensions ~w(.avif .bmp .gif .ico .jpeg .jpg .png .svg .tif .tiff .webp)

  # --- permissions and questions ---------------------------------------------------

  @doc "Whether a permission request is one of Antigravity's questions for the user."
  def user_input?(params) do
    id = get_in(params || %{}, ["toolCall", "toolCallId"])
    is_binary(id) and String.starts_with?(id, "interaction_")
  end

  @doc """
  The approval choices a request offers: only the decisions the agent gave an
  option for, plus cancel. An allow-always option's security warning rides on
  its choice, cut to 512 characters.
  """
  def approval_options(params) do
    options = (params || %{})["options"] || []

    with_kind = fn kind ->
      Enum.find(options, &(&1["kind"] == kind and filled?(&1["optionId"])))
    end

    []
    |> add(with_kind.("allow_once"), %{"decision" => "accept", "label" => "Allow once"})
    |> add_always(with_kind.("allow_always"))
    |> add(with_kind.("reject_once"), %{"decision" => "decline", "label" => "Deny"})
    |> Kernel.++([%{"decision" => "cancel", "label" => "Cancel"}])
  end

  defp add(list, nil, _choice), do: list
  defp add(list, _option, choice), do: list ++ [choice]

  defp add_always(list, nil), do: list

  defp add_always(list, option) do
    choice = %{"decision" => "acceptForSession", "label" => "Allow for this thread"}

    list ++
      [
        case security_warning(option) do
          nil -> choice
          warning -> Map.put(choice, "warning", warning)
        end
      ]
  end

  defp security_warning(option) do
    warning = get_in(option || %{}, ["_meta", @warning_key])

    text =
      if is_map(warning),
        do: filled(warning["message"]) || filled(warning["title"])

    case text do
      nil -> nil
      text -> cut(text, @warning_limit)
    end
  end

  @doc """
  The question a request asks, as one `OrchestrationV2UserInputQuestion`, or
  nil when its options cannot be told apart (an id shared or missing), so the
  user is never shown a question they cannot answer unambiguously.
  """
  def question(params) do
    options = (params || %{})["options"] || []
    call = (params || %{})["toolCall"] || %{}
    ids = Enum.map(options, & &1["optionId"])

    if options == [] or Enum.any?(ids, &(not filled?(&1))) or
         length(Enum.uniq(ids)) != length(ids) do
      nil
    else
      text = filled(call["title"]) || "Choose an option."

      %{
        "id" => call["toolCallId"],
        "header" => "Question",
        "question" => cut(text, @text_limit),
        "multiSelect" => false,
        "allowCustomAnswer" => false,
        "options" =>
          for option <- options do
            label = question_label(option)
            %{"label" => label, "description" => label}
          end
      }
    end
  end

  @doc """
  The agent's answer for `answers` (by question id): an option picked by its
  id, or by a label only it carries. Nil keeps the question open.
  """
  def answer(params, answers) when is_map(answers) do
    call = (params || %{})["toolCall"] || %{}
    options = (params || %{})["options"] || []

    value =
      case answers[call["toolCallId"]] do
        value when is_binary(value) -> value
        [value] when is_binary(value) -> value
        _ -> nil
      end

    with value when is_binary(value) <- value,
         %{} = question when not is_nil(question) <- question(params),
         option when not is_nil(option) <-
           Enum.find(options, &(&1["optionId"] == value)) ||
             unique_label(options, value) do
      %{"outcome" => %{"outcome" => "selected", "optionId" => option["optionId"]}}
    else
      _ -> nil
    end
  end

  def answer(_params, _answers), do: nil

  defp unique_label(options, value) do
    case Enum.filter(options, &(question_label(&1) == value)) do
      [option] -> option
      _ -> nil
    end
  end

  defp question_label(option) do
    label = filled(option["name"]) || option["optionId"] || ""
    cut(label, @label_limit)
  end

  # --- native tool fields -----------------------------------------------------------

  @command_keys ~w(CommandLine command_line commandLine command)
  @cwd_keys ~w(Cwd WorkingDirectory working_dir workingDir cwd)

  @doc """
  What a tool call's native input and output say: its command line, working
  folder, combined output, exit code and local image, under whichever names
  Antigravity used.
  """
  def native_fields(call) do
    input = if is_map(call["rawInput"]), do: call["rawInput"], else: %{}
    output = if is_map(call["rawOutput"]), do: call["rawOutput"], else: %{}

    command =
      first_filled(input, @command_keys) || first_filled(output, ~w(commandLine command_line))

    %{
      command: command && bound(command),
      cwd: first_filled(input, @cwd_keys) || first_filled(output, ~w(workingDir working_dir)),
      output: output["combinedOutput"] || output["combined_output"],
      exit_code: integer(output["exitCode"] || output["exit_code"]),
      image_path: local_image_path(output["imagePath"])
    }
    |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
    |> then(fn fields ->
      if is_binary(fields[:output]),
        do: Map.put(fields, :output, bound(fields.output)),
        else: fields
    end)
  end

  defp first_filled(map, keys) do
    Enum.find_value(keys, fn key ->
      case map[key] do
        value when is_binary(value) -> filled(value)
        _ -> nil
      end
    end)
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  @doc "A tool result's local image file, offered as a preview; web and remote files are not."
  def local_image_path(path) when is_binary(path) and byte_size(path) <= @text_limit do
    path = String.trim(path)

    cond do
      path == "" ->
        nil

      String.downcase(Path.extname(path)) not in @image_extensions ->
        nil

      Regex.match?(~r/^file:\/\//i, path) ->
        case URI.parse(path) do
          %URI{host: host, path: pathname} when host in [nil, "", "localhost"] ->
            pathname = URI.decode(pathname || "")

            case pathname do
              "/" <> <<letter, ":/", _::binary>> = windows
              when letter in ?a..?z or letter in ?A..?Z ->
                String.slice(windows, 1..-1//1)

              _ ->
                pathname
            end

          _ ->
            nil
        end

      Regex.match?(~r/^[a-z][a-z0-9+.-]*:/i, path) and
          not Regex.match?(~r/^[a-z]:[\\\/]/i, path) ->
        nil

      true ->
        path
    end
  end

  def local_image_path(_path), do: nil

  # --- bounding tool data --------------------------------------------------------------

  @doc """
  A tool update with its data bounded for storage: title, raw input and
  output, content and `_meta` sanitized (see `sanitize/1`).
  """
  def normalize_update(%{"sessionUpdate" => kind} = update)
      when kind in ["tool_call", "tool_call_update"] do
    update
    |> bound_field("title")
    |> sanitize_field("rawInput")
    |> sanitize_field("rawOutput")
    |> sanitize_content()
    |> sanitize_meta()
  end

  def normalize_update(update), do: update

  defp bound_field(update, key) do
    case update[key] do
      value when is_binary(value) -> Map.put(update, key, bound(value))
      _ -> update
    end
  end

  defp sanitize_field(update, key) do
    if Map.has_key?(update, key),
      do: Map.put(update, key, sanitize(update[key])),
      else: update
  end

  defp sanitize_meta(update) do
    case Map.fetch(update, "_meta") do
      {:ok, meta} ->
        case sanitize(meta) do
          %{} = clean -> Map.put(update, "_meta", clean)
          _ -> Map.put(update, "_meta", nil)
        end

      :error ->
        update
    end
  end

  defp sanitize_content(update) do
    case update["content"] do
      content when is_list(content) ->
        budget = %{nodes: 512, text: 32_000}

        {kept, _budget} =
          Enum.map_reduce(content, budget, fn entry, budget ->
            {clean, budget} = sanitize_value(entry, budget, 0)
            {clean, budget}
          end)

        Map.put(update, "content", Enum.reject(kept, &(&1 == :drop)))

      _ ->
        update
    end
  end

  @doc """
  Bounds one tool payload: at most 512 entries and 64,000 characters of text
  (each text keeping its last 8,000), no inline image data, nothing deeper
  than twelve levels.
  """
  def sanitize(payload) do
    {clean, _budget} = sanitize_value(payload, %{nodes: 512, text: 64_000}, 0)
    if clean == :drop, do: nil, else: clean
  end

  defp sanitize_value(_value, budget, depth) when depth > 12 or budget.nodes <= 0,
    do: {:drop, budget}

  defp sanitize_value(value, budget, _depth) when is_binary(value) do
    budget = %{budget | nodes: budget.nodes - 1}

    cond do
      Regex.match?(~r/^data:image\//i, value) ->
        {:drop, budget}

      budget.text <= 0 ->
        {:drop, budget}

      true ->
        text = bound(value, min(@text_limit, budget.text))
        {text, %{budget | text: budget.text - String.length(text)}}
    end
  end

  defp sanitize_value(values, budget, depth) when is_list(values) do
    budget = %{budget | nodes: budget.nodes - 1}

    {kept, budget} =
      Enum.reduce_while(values, {[], budget}, fn value, {kept, budget} ->
        if budget.nodes <= 0 do
          {:halt, {kept, budget}}
        else
          case sanitize_value(value, budget, depth + 1) do
            {:drop, budget} -> {:cont, {kept, budget}}
            {clean, budget} -> {:cont, {kept ++ [clean], budget}}
          end
        end
      end)

    {kept, budget}
  end

  defp sanitize_value(%{} = value, budget, depth) do
    budget = %{budget | nodes: budget.nodes - 1}

    {entries, budget} =
      Enum.reduce_while(value, {[], budget}, fn {key, entry}, {entries, budget} ->
        cond do
          budget.nodes <= 0 ->
            {:halt, {entries, budget}}

          drop_entry?(value, key, entry) ->
            {:cont, {entries, budget}}

          true ->
            case sanitize_value(entry, budget, depth + 1) do
              {:drop, budget} -> {:cont, {entries, budget}}
              {clean, budget} -> {:cont, {entries ++ [{key, clean}], budget}}
            end
        end
      end)

    {Map.new(entries), budget}
  end

  defp sanitize_value(value, budget, _depth), do: {value, %{budget | nodes: budget.nodes - 1}}

  defp drop_entry?(value, key, entry) do
    (value["type"] == "image" and key in ["data", "blob"]) or
      (key == "blob" and is_binary(value["mimeType"]) and
         String.starts_with?(value["mimeType"], "image/")) or
      (key in ["formatted_output", "formattedOutput"] and
         (entry == value["combinedOutput"] or entry == value["combined_output"]))
  end

  @doc "The last `limit` characters of `text`, under the truncation marker when cut."
  def bound(text, limit \\ @text_limit) do
    if String.length(text) <= limit,
      do: text,
      else: @truncated <> String.slice(text, -limit..-1//1)
  end

  # --- text helpers ---------------------------------------------------------------------

  defp cut(text, limit) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit - 3) <> "...",
      else: text
  end

  defp filled?(value), do: filled(value) != nil

  defp filled(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp filled(_value), do: nil
end
