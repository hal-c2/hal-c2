defmodule HalC2.Mcp.Schema do
  @moduledoc """
  Whether a tool call's arguments fit the tool's advertised `inputSchema`
  (`HalC2.Mcp.Tools.list/0`). The schemas are the JSON Schema subset the tool
  definitions in `priv/mcp_tools.json` and `priv/mcp_mc_tools.json` use:
  types, `anyOf`/`allOf`, objects, arrays, and the numeric, string and
  array bounds. A call outside its bounds is refused as an
  `invalid_request` before the tool runs, as the Node server's toolkits
  refused it.

  Presence, vocabularies and types are not checked on their own: the
  exported schemas call fields required that this MC's tools default when
  omitted (a missing `threadId` is the caller's own thread, a missing
  project `title` is the folder's name), the tools ignore fields they do
  not read and values of a kind they do not use (a numeric `model` narrows
  nothing), and handlers answer values outside an `enum` with their own
  errors ("Unknown action shout."). A type only picks which `anyOf` branch
  a value is measured against; what is measured must fit its bounds.
  """

  @doc "`{:error, message}` naming the first offending field, or `:ok`."
  @spec validate(map, term) :: :ok | {:error, String.t()}
  def validate(schema, value), do: check(schema, value, "arguments")

  defp check(schema, value, at) when is_map(schema) do
    with :ok <- any_of(schema, value, at),
         :ok <- all_of(schema, value, at),
         :ok <- bounds(schema, value, at),
         :ok <- object(schema, value, at),
         :ok <- items(schema, value, at),
         do: :ok
  end

  defp check(_schema, _value, _at), do: :ok

  # Only the branches written for the value's kind measure it; a value of a
  # kind no branch names is the handler's to ignore or answer.
  defp any_of(%{"anyOf" => schemas}, value, at) do
    case Enum.filter(schemas, &kind?(&1, value)) do
      [] ->
        :ok

      branches ->
        if Enum.any?(branches, &(check(&1, value, at) == :ok)),
          do: :ok,
          else: check(hd(branches), value, at)
    end
  end

  defp any_of(_schema, _value, _at), do: :ok

  defp all_of(%{"allOf" => schemas}, value, at) do
    schemas
    |> Enum.filter(&kind?(&1, value))
    |> Enum.find_value(:ok, fn schema ->
      case check(schema, value, at) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp all_of(_schema, _value, _at), do: :ok

  defp kind?(schema, value) when is_map(schema) do
    case schema["type"] do
      nil -> true
      "object" -> is_map(value)
      "array" -> is_list(value)
      "string" -> is_binary(value)
      "integer" -> is_integer(value)
      "number" -> is_number(value)
      "boolean" -> is_boolean(value)
      "null" -> value in [nil, :null]
      _other -> true
    end
  end

  defp kind?(_schema, _value), do: true

  defp bounds(schema, value, at) when is_number(value) do
    cond do
      is_number(schema["minimum"]) and value < schema["minimum"] ->
        {:error, "#{at} must be at least #{schema["minimum"]}"}

      is_number(schema["maximum"]) and value > schema["maximum"] ->
        {:error, "#{at} must be at most #{schema["maximum"]}"}

      is_number(schema["exclusiveMinimum"]) and value <= schema["exclusiveMinimum"] ->
        {:error, "#{at} must be greater than #{schema["exclusiveMinimum"]}"}

      is_number(schema["exclusiveMaximum"]) and value >= schema["exclusiveMaximum"] ->
        {:error, "#{at} must be less than #{schema["exclusiveMaximum"]}"}

      true ->
        :ok
    end
  end

  defp bounds(schema, value, at) when is_binary(value) do
    length = String.length(value)

    cond do
      is_integer(schema["minLength"]) and length < schema["minLength"] ->
        {:error, "#{at} must be at least #{schema["minLength"]} characters"}

      is_integer(schema["maxLength"]) and length > schema["maxLength"] ->
        {:error, "#{at} must be at most #{schema["maxLength"]} characters"}

      true ->
        :ok
    end
  end

  defp bounds(schema, value, at) when is_list(value) do
    cond do
      is_integer(schema["minItems"]) and length(value) < schema["minItems"] ->
        {:error, "#{at} must hold at least #{schema["minItems"]} items"}

      is_integer(schema["maxItems"]) and length(value) > schema["maxItems"] ->
        {:error, "#{at} must hold at most #{schema["maxItems"]} items"}

      true ->
        :ok
    end
  end

  defp bounds(_schema, _value, _at), do: :ok

  defp object(schema, value, at) when is_map(value) do
    properties = schema["properties"] || %{}

    with :ok <- known(properties, value, at),
         :ok <- additional(schema, properties, value, at),
         do: :ok
  end

  defp object(_schema, _value, _at), do: :ok

  defp known(properties, value, at) do
    Enum.find_value(properties, :ok, fn {field, schema} ->
      if Map.has_key?(value, field) do
        case check(schema, value[field], "#{at}.#{field}") do
          :ok -> nil
          error -> error
        end
      end
    end)
  end

  defp additional(%{"additionalProperties" => %{} = schema}, properties, value, at) do
    value
    |> Map.reject(fn {field, _} -> Map.has_key?(properties, field) end)
    |> Enum.find_value(:ok, fn {field, extra} ->
      case check(schema, extra, "#{at}.#{field}") do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp additional(_schema, _properties, _value, _at), do: :ok

  defp items(%{"items" => schema}, value, at) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {item, index} ->
      case check(schema, item, "#{at}[#{index}]") do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp items(_schema, _value, _at), do: :ok
end
