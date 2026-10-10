defmodule HalC2.Codex.Elicitation do
  @moduledoc """
  Codex's `mcpServer/elicitation/request`: a tool asking for access to another app
  (a ChatGPT connector, say). HAL-C2 shows it as an approval naming the app, with the
  scopes the request offers, and answers in the form the request asked for.
  """

  @doc "The app asking, and the decisions the request can take: `%{app: name, options: [...]}`."
  @spec describe(map) :: %{app: String.t(), options: [map]}
  def describe(params) do
    meta = if is_map(params["_meta"]), do: params["_meta"], else: %{}
    message = params["message"] || ""

    app =
      [
        meta["app_name"],
        meta["appName"],
        meta["app"],
        get_in(meta, ["target", "app"]),
        get_in(meta, ["target", "name"]),
        get_in(meta, ["tool_params", "app_name"]),
        get_in(meta, ["tool_params", "app"]),
        case Regex.run(~r/^Allow ChatGPT to use (.+?)\?$/i, message) do
          [_, name] -> name
          _ -> nil
        end,
        meta["connector_name"],
        meta["connectorName"],
        params["serverName"]
      ]
      |> Enum.find("", &is_binary/1)

    offered =
      for value <- List.wrap(meta["persist"]),
          is_binary(value),
          decision = persistence(value),
          into: %{},
          do: {decision, ""}

    offered =
      if meta["allowPersistentApproval"] == true,
        do: Map.put(offered, "acceptAlways", ""),
        else: offered

    offered =
      Enum.reduce(fields(params), offered, fn {key, field}, offered ->
        offered =
          Enum.reduce(choices(field), offered, fn {value, label}, offered ->
            case persistence(value) do
              nil -> offered
              decision -> Map.put(offered, decision, label || "")
            end
          end)

        if field["type"] == "boolean" and persistence_field?(key, field),
          do: Map.put(offered, "acceptAlways", field["title"] || ""),
          else: offered
      end)

    scope = fn decision, default ->
      if Map.has_key?(offered, decision) and response(params, decision)["action"] == "accept" do
        label = if offered[decision] in [nil, ""], do: default, else: offered[decision]
        [%{"decision" => decision, "label" => label}]
      else
        []
      end
    end

    %{
      app: app,
      options:
        [
          %{"decision" => "cancel", "label" => "Cancel"},
          %{"decision" => "decline", "label" => "Decline"}
        ] ++
          scope.("acceptForSession", "Always allow this session") ++
          scope.("acceptAlways", "Always allow") ++
          [%{"decision" => "accept", "label" => "Approve"}]
    }
  end

  @doc """
  The request's answer for a `ProviderApprovalDecision`. A request whose form the
  decision cannot fill (or a URL request, which has no form) is declined.
  """
  @spec response(map, String.t()) :: map
  def response(_params, decision) when decision in ["decline", "cancel"],
    do: %{"action" => decision}

  def response(%{"mode" => "url"}, _decision), do: %{"action" => "decline"}

  def response(params, decision) do
    persist =
      case decision do
        "acceptForSession" -> "session"
        "acceptAlways" -> "always"
        _ -> nil
      end

    form = form(params)

    content =
      for {key, field} <- fields(params), reduce: %{} do
        content ->
          chosen =
            Enum.find(choices(field), fn {value, _label} ->
              if persist,
                do: persistence(value) == decision,
                else: value =~ ~r/once|accept|approve|allow/i and persistence(value) == nil
            end)

          cond do
            chosen ->
              Map.put(content, key, elem(chosen, 0))

            field["type"] == "boolean" and persistence_field?(key, field) ->
              Map.put(content, key, decision == "acceptAlways")

            field["default"] != nil ->
              Map.put(content, key, field["default"])

            true ->
              content
          end
      end

    if Enum.any?(List.wrap(form && form["required"]), &(not Map.has_key?(content, &1))) do
      %{"action" => "decline"}
    else
      %{"action" => "accept"}
      |> then(&if(persist, do: Map.put(&1, "_meta", %{"persist" => persist}), else: &1))
      |> then(&if(form, do: Map.put(&1, "content", content), else: &1))
    end
  end

  defp form(%{"mode" => "url"}), do: nil
  defp form(%{"requestedSchema" => %{} = schema}), do: schema
  defp form(_params), do: nil

  defp fields(params) do
    case form(params) do
      %{"properties" => %{} = properties} ->
        for {key, %{} = field} <- Enum.sort(properties), do: {key, field}

      _ ->
        []
    end
  end

  # A field's choices as `{value, label}`.
  defp choices(%{"oneOf" => [_ | _] = options}),
    do: for(%{"const" => value} = option <- options, do: {value, option["title"]})

  defp choices(field) do
    names = field["enumNames"] || []

    for {value, index} <- Enum.with_index(field["enum"] || []),
        is_binary(value),
        do: {value, Enum.at(names, index)}
  end

  defp persistence(value) when is_binary(value) do
    value = String.downcase(value)

    cond do
      value =~ "session" -> "acceptForSession"
      value =~ ~r/always|permanent|forever|persistent/ -> "acceptAlways"
      true -> nil
    end
  end

  defp persistence(_value), do: nil

  defp persistence_field?(key, field) do
    persistence(key) != nil or String.downcase(key) == "persist" or
      persistence(field["title"] || "") != nil or persistence(field["description"] || "") != nil
  end
end
