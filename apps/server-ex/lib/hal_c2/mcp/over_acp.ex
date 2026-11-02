defmodule HalC2.Mcp.OverAcp do
  @moduledoc """
  MCP carried over the ACP connection itself, for agents that support it:
  the agent connects to a named MCP server through this MC, sends it
  messages, and disconnects. Only HAL-C2's own server is offered, under
  the id `"hal-c2"`; anything else is refused by name.

  Each connection forwards to the MC's HTTP endpoint with the thread's
  credential, keeping the `mcp-session-id` and protocol version the MC
  gave it, one message at a time. A session holds at most 16 connections
  and a message at most 8 MiB; refusing either leaves the connections
  that are open usable. Disconnecting ends the connection's MCP session
  on the MC (a session it no longer has is not an error), and disposing
  of the bridge — the ACP session ending — disconnects them all.

  The transport is `HalC2.Mcp.Bridge.Http` by default; tests stand in
  their own `post`/`delete` functions (see `HalC2.Mcp.Bridge`).
  """

  use GenServer

  @max_connections 16
  @max_message_bytes 8 * 1024 * 1024

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{
      endpoint: Keyword.fetch!(opts, :endpoint),
      authorization: Keyword.fetch!(opts, :authorization),
      post: Keyword.get(opts, :post, &HalC2.Mcp.Bridge.Http.post/4),
      delete: Keyword.get(opts, :delete, &HalC2.Mcp.Bridge.Http.delete/2),
      connections: %{}
    })
  end

  @doc "Opens a connection to `server_id`: `{:ok, connection_id}` or `{:error, message}`."
  def connect(pid, server_id), do: GenServer.call(pid, {:connect, server_id})

  @doc "Sends one MCP request on a connection: `{:ok, result}` or `{:error, message}`."
  def message(pid, connection_id, method, params \\ nil),
    do: GenServer.call(pid, {:message, connection_id, method, params}, 120_000)

  @doc "Sends one MCP notification on a connection: `:ok` or `{:error, message}`."
  def notification(pid, connection_id, method, params \\ nil),
    do: GenServer.call(pid, {:notification, connection_id, method, params}, 120_000)

  @doc "Closes one connection and ends its MCP session on the MC."
  def disconnect(pid, connection_id),
    do: GenServer.call(pid, {:disconnect, connection_id}, 120_000)

  @doc "Closes every connection (the ACP session ended)."
  def dispose(pid), do: GenServer.call(pid, :dispose, 120_000)

  @doc "How many connections are open."
  def connection_count(pid), do: GenServer.call(pid, :count)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:connect, server_id}, _from, state) do
    cond do
      server_id != "hal-c2" ->
        {:reply, {:error, "Unknown ACP MCP server \"#{server_id}\"."}, state}

      map_size(state.connections) >= @max_connections ->
        {:reply, {:error, "Too many MCP-over-ACP connections."}, state}

      true ->
        id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        connection = %{session_id: nil, protocol_version: nil, next_id: 0}
        {:reply, {:ok, id}, put_in(state, [:connections, id], connection)}
    end
  end

  def handle_call({:message, connection_id, method, params}, _from, state) do
    with {:ok, connection, state} <- take(state, connection_id),
         id = connection.next_id + 1,
         message = %{"jsonrpc" => "2.0", "id" => id, "method" => method},
         message = if(params == nil, do: message, else: Map.put(message, "params", params)),
         {:ok, connection, payloads} <- send(state, connection, message) do
      connection = %{connection | next_id: id}
      state = put_in(state, [:connections, connection_id], connection)

      case Enum.find(payloads, &(&1["id"] == id)) do
        %{"result" => result} -> {:reply, {:ok, result}, state}
        %{"error" => error} -> {:reply, {:error, error_message(error)}, state}
        _ -> {:reply, {:error, "MCP server did not return a matching response."}, state}
      end
    else
      {:error, message, state} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:notification, connection_id, method, params}, _from, state) do
    with {:ok, connection, state} <- take(state, connection_id),
         message = %{"jsonrpc" => "2.0", "method" => method},
         message = if(params == nil, do: message, else: Map.put(message, "params", params)),
         {:ok, connection, _payloads} <- send(state, connection, message) do
      {:reply, :ok, put_in(state, [:connections, connection_id], connection)}
    else
      {:error, message, state} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:disconnect, connection_id}, _from, state) do
    case take(state, connection_id) do
      {:ok, connection, state} ->
        state = %{state | connections: Map.delete(state.connections, connection_id)}
        {:reply, end_session(state, connection), state}

      {:error, message, state} ->
        {:reply, {:error, message}, state}
    end
  end

  def handle_call(:dispose, _from, state) do
    Enum.each(state.connections, fn {_id, connection} -> end_session(state, connection) end)
    {:reply, :ok, %{state | connections: %{}}}
  end

  def handle_call(:count, _from, state), do: {:reply, map_size(state.connections), state}

  defp take(state, connection_id) do
    case state.connections[connection_id] do
      nil -> {:error, "Unknown MCP-over-ACP connection \"#{connection_id}\".", state}
      connection -> {:ok, connection, state}
    end
  end

  # One message in flight per bridge (the GenServer serializes them), so
  # the session state a connection carries moves exactly like the wire.
  defp send(state, connection, message) do
    body = JSON.encode!(message)

    if byte_size(body) > @max_message_bytes do
      {:error, "MCP-over-ACP message exceeds 8 MiB.", state}
    else
      parent = self()
      ref = make_ref()
      emit = fn payload -> Kernel.send(parent, {ref, payload}) end

      outcome =
        try do
          state.post.(state.endpoint, headers(state, connection), body, emit)
        rescue
          error -> {:error, error}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      case outcome do
        {:ok, status, resp_headers} when status in 200..299 ->
          payloads = collect(ref)

          connection = %{
            connection
            | session_id: resp_headers["mcp-session-id"] || connection.session_id,
              protocol_version:
                Enum.find_value(payloads, &protocol_version_of/1) || connection.protocol_version
          }

          {:ok, connection, payloads}

        {:ok, status, _headers} ->
          collect(ref)
          {:error, "HAL-C2 MCP endpoint responded with HTTP #{status}.", state}

        {:error, reason} ->
          collect(ref)
          {:error, "HAL-C2 MCP bridge request failed: #{inspect(reason)}", state}
      end
    end
  end

  defp end_session(_state, %{session_id: nil}), do: :ok

  defp end_session(state, connection) do
    headers = %{
      "authorization" => state.authorization,
      "mcp-session-id" => connection.session_id
    }

    headers =
      if connection.protocol_version,
        do: Map.put(headers, "mcp-protocol-version", connection.protocol_version),
        else: headers

    case state.delete.(state.endpoint, headers) do
      {:ok, status} when status in 200..299 or status == 404 -> :ok
      {:ok, status} -> {:error, "HAL-C2 MCP endpoint rejected disconnect with HTTP #{status}."}
      {:error, reason} -> {:error, "HAL-C2 MCP bridge request failed: #{inspect(reason)}"}
    end
  end

  defp headers(state, connection) do
    %{
      "content-type" => "application/json",
      "accept" => "application/json, text/event-stream",
      "authorization" => state.authorization
    }
    |> put_header("mcp-session-id", connection.session_id)
    |> put_header("mcp-protocol-version", connection.protocol_version)
  end

  defp put_header(headers, _name, nil), do: headers
  defp put_header(headers, name, value), do: Map.put(headers, name, value)

  defp protocol_version_of(%{"result" => %{"protocolVersion" => version}})
       when is_binary(version) and version != "",
       do: version

  defp protocol_version_of(_payload), do: nil

  defp error_message(%{"message" => message}) when is_binary(message) and message != "",
    do: message

  defp error_message(_error), do: "The MCP server returned an error."

  defp collect(ref) do
    receive do
      {^ref, payload} -> [payload | collect(ref)]
    after
      0 -> []
    end
  end
end
