defmodule HalC2.Mcp.Bridge.Http do
  @moduledoc """
  The real HTTP transport for `HalC2.Mcp.Bridge` and `HalC2.Mcp.OverAcp`:
  one POST per message, answering `{status, headers}` and emitting each
  JSON payload — the single JSON body, or each `data:` event of an SSE
  body in order. Notification acknowledgements (202/204) emit none.
  """

  @doc "POSTs `body`, emitting each decoded payload. See `HalC2.Mcp.Bridge`."
  def post(endpoint, headers, body, emit) do
    # A forwarded call may wait as long as the MCP tool itself may
    # (`delegate_task` mode=wait, `hal_c2_thread_wait`): Req's 15s default
    # receive timeout would sever exactly the long calls the bridge exists for.
    timeout = HalC2.Mcp.tool_timeout_ms()

    case Req.post(endpoint,
           headers: Map.to_list(headers),
           body: body,
           decode_body: false,
           receive_timeout: timeout
         ) do
      {:ok, %{status: status, headers: resp_headers, body: text}} ->
        if status not in [202, 204] and is_binary(text) and String.trim(text) != "" do
          text
          |> String.split(~r/\r?\n\r?\n/)
          |> Enum.each(&emit_event(&1, emit))
        end

        {:ok, status, flatten(resp_headers)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @doc "DELETEs the endpoint (ending an MCP session): `{:ok, status}` or `{:error, term}`."
  def delete(endpoint, headers) do
    case Req.delete(endpoint,
           headers: Map.to_list(headers),
           receive_timeout: HalC2.Mcp.tool_timeout_ms()
         ) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp emit_event(event, emit) do
    data =
      event
      |> String.split(~r/\r?\n/)
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&(String.slice(&1, 5..-1//1) |> String.trim_leading()))
      |> Enum.join("\n")

    text = if data == "", do: String.trim(event), else: data

    case JSON.decode(text) do
      {:ok, payload} -> emit.(payload)
      _ -> :ok
    end
  end

  defp flatten(headers) do
    Map.new(headers, fn {key, values} -> {String.downcase(key), List.first(values)} end)
  end
end
