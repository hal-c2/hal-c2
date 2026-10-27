defmodule HalC2.Mcp.Bridge do
  @moduledoc """
  The local command an ACP agent spawns as its `hal-c2` MCP server
  (`acp-mcp-bridge`), and the one-shot terminal call (`acp-mcp-call`).

  ACP agents must support stdio MCP servers, while HTTP support is uneven,
  so the bridge runs as a stdio server and forwards each JSON-RPC line to
  the MC's authenticated HTTP endpoint: single JSON answers and streamed
  events come back as one line each, acknowledgements without a body
  (202/204) write nothing, and the `mcp-session-id` and negotiated protocol
  version the MC gave at `initialize` ride every later request.

  Only session establishment is ordered: a request sent before its
  session's initialization has been answered is held until it finishes.
  The agent's own responses to the MC are never held — the still-open
  initialization exchange may be waiting for one.

  The transport is a function
  `post.(endpoint, headers, body, emit) :: {:ok, status, headers} | {:error, term}`,
  calling `emit.(payload)` per decoded JSON payload in arrival order
  (`HalC2.Mcp.Bridge.Http` over real HTTP); tests stand in their own.
  """

  use GenServer

  @protocol "2025-06-18"

  # --- the stdio bridge ---------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{
      endpoint: Keyword.fetch!(opts, :endpoint),
      authorization: Keyword.fetch!(opts, :authorization),
      post: Keyword.get(opts, :post, &HalC2.Mcp.Bridge.Http.post/4),
      out: Keyword.fetch!(opts, :out),
      session_id: nil,
      protocol_version: nil,
      barrier: nil,
      held: [],
      running: %{},
      last_ref: nil
    })
  end

  @doc "Feeds one line of the agent's input to the bridge."
  def line(pid, line), do: GenServer.cast(pid, {:line, line})

  @doc "Waits until every forwarded request has been answered and written out."
  def flush(pid), do: GenServer.call(pid, :flush, 30_000)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:line, line}, state) do
    {:noreply, dispatch(String.trim_trailing(line, "\n"), state)}
  end

  # Answers arrive from the forward tasks in completion order, as on the wire.
  @impl true
  def handle_info({:payload, _ref, payload}, state) do
    state = %{state | protocol_version: protocol_version_of(payload) || state.protocol_version}
    write(state, payload)
    {:noreply, state}
  end

  def handle_info({:forwarded, ref, outcome, envelope, session_id}, state) do
    state = %{state | session_id: session_id || state.session_id}

    case outcome do
      {:http_error, status} ->
        if Map.has_key?(envelope, "id") do
          write_error(
            state,
            envelope["id"],
            -32603,
            "HAL-C2 MCP endpoint responded with HTTP #{status}."
          )
        end

      {:error, reason} ->
        if Map.has_key?(envelope, "id") do
          write_error(
            state,
            envelope["id"],
            -32603,
            "HAL-C2 MCP bridge request failed: #{inspect(reason)}"
          )
        end

      :ok ->
        :ok
    end

    state = %{state | running: Map.delete(state.running, ref)}
    state = if state.barrier == ref, do: release(%{state | barrier: nil}), else: state
    {:noreply, reply_flush(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    dead = for {ref, ^pid} <- state.running, do: ref
    state = %{state | running: Map.drop(state.running, dead)}
    state = if state.barrier in dead, do: release(%{state | barrier: nil}), else: state
    {:noreply, reply_flush(state)}
  end

  @impl true
  def handle_call(:flush, from, state) do
    if state.running == %{} and state.held == [] and state.barrier == nil do
      {:reply, :ok, state}
    else
      {:noreply, Map.update(state, :flush_waiters, [from], &[from | &1])}
    end
  end

  defp reply_flush(state) do
    if state.running == %{} and state.held == [] and state.barrier == nil do
      Enum.each(Map.get(state, :flush_waiters, []), &GenServer.reply(&1, :ok))
      Map.delete(state, :flush_waiters)
    else
      state
    end
  end

  defp dispatch("", state), do: state

  defp dispatch(line, state) do
    case JSON.decode(line) do
      {:error, _} ->
        write_error(state, nil, -32700, "Parse error")
        state

      {:ok, %{} = envelope} ->
        response? =
          Map.has_key?(envelope, "id") and
            (Map.has_key?(envelope, "result") or Map.has_key?(envelope, "error"))

        handshake? = envelope["method"] in ["initialize", "notifications/initialized"]

        cond do
          response? ->
            forward(line, envelope, state)

          handshake? and state.barrier == nil ->
            state = forward(line, envelope, state)
            %{state | barrier: state.last_ref}

          handshake? ->
            %{state | held: state.held ++ [{line, envelope, :handshake}]}

          state.barrier != nil ->
            %{state | held: state.held ++ [{line, envelope, :held}]}

          true ->
            forward(line, envelope, state)
        end

      {:ok, _} ->
        state
    end
  end

  # The barrier finished: held handshakes chain one at a time, the rest go now.
  defp release(state) do
    {held, state} = {state.held, %{state | held: []}}

    Enum.reduce(held, state, fn
      {line, envelope, :handshake}, state when state.barrier == nil ->
        state = forward(line, envelope, state)
        %{state | barrier: state.last_ref}

      {line, envelope, :handshake}, state ->
        %{state | held: state.held ++ [{line, envelope, :handshake}]}

      {line, envelope, :held}, state when state.barrier != nil ->
        %{state | held: state.held ++ [{line, envelope, :held}]}

      {line, envelope, :held}, state ->
        forward(line, envelope, state)
    end)
  end

  defp forward(line, envelope, state) do
    server = self()
    headers = headers(state)
    post = state.post
    endpoint = state.endpoint
    ref = make_ref()

    {pid, _monitor} =
      spawn_monitor(fn ->
        {result, session_id} =
          try do
            case post.(endpoint, headers, line, fn payload ->
                   send(server, {:payload, ref, payload})
                 end) do
              {:ok, status, resp_headers} when status in 200..299 ->
                {:ok, resp_headers["mcp-session-id"]}

              {:ok, status, resp_headers} ->
                {{:http_error, status}, resp_headers["mcp-session-id"]}

              {:error, reason} ->
                {{:error, reason}, nil}
            end
          rescue
            error -> {{:error, error}, nil}
          catch
            kind, reason -> {{:error, {kind, reason}}, nil}
          end

        send(server, {:forwarded, ref, result, envelope, session_id})
      end)

    %{state | running: Map.put(state.running, ref, pid), last_ref: ref}
  end

  defp headers(state) do
    %{
      "content-type" => "application/json",
      "accept" => "application/json, text/event-stream",
      "authorization" => state.authorization
    }
    |> put_header("mcp-session-id", state.session_id)
    |> put_header("mcp-protocol-version", state.protocol_version)
  end

  defp put_header(headers, _name, nil), do: headers
  defp put_header(headers, name, value), do: Map.put(headers, name, value)

  defp write(state, payload) do
    line = JSON.encode!(payload) <> "\n"
    if is_function(state.out, 1), do: state.out.(line), else: send(state.out, {:bridge_out, line})
  end

  defp write_error(state, id, code, message) do
    write(state, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp protocol_version_of(%{"result" => %{"protocolVersion" => version}})
       when is_binary(version) and version != "",
       do: version

  defp protocol_version_of(_payload), do: nil

  # --- one tool call from a terminal ---------------------------------------------

  @doc """
  Calls one MCP tool through a fresh authenticated session — the terminal
  fallback for ACP agents that accept the server but fail to expose its
  tools. `{:ok, result}` or `{:error, message}`.
  """
  def call_tool(endpoint, authorization, tool, arguments, post \\ &HalC2.Mcp.Bridge.Http.post/4) do
    session = %{
      endpoint: endpoint,
      authorization: authorization,
      post: post,
      session_id: nil,
      protocol_version: nil
    }

    init_id = "hal-c2-acp-cli-initialize"
    call_id = "hal-c2-acp-cli-tool-call"

    with {:ok, session, payloads} <-
           exchange(session, %{
             "jsonrpc" => "2.0",
             "id" => init_id,
             "method" => "initialize",
             "params" => %{
               "protocolVersion" => @protocol,
               "capabilities" => %{},
               "clientInfo" => %{"name" => "hal-c2-acp-cli", "version" => "0.0.0"}
             }
           }),
         %{"id" => ^init_id} = initialized <- Enum.find(payloads, &(&1["id"] == init_id)),
         false <- Map.has_key?(initialized, "error"),
         {:ok, session, _} <-
           exchange(session, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}),
         {:ok, _session, payloads} <-
           exchange(session, %{
             "jsonrpc" => "2.0",
             "id" => call_id,
             "method" => "tools/call",
             "params" => %{"name" => tool, "arguments" => arguments}
           }) do
      case Enum.find(payloads, &(&1["id"] == call_id)) do
        %{"result" => result} -> {:ok, result}
        %{"error" => error} -> {:error, "HAL-C2 MCP tool call failed: #{JSON.encode!(error)}"}
        _ -> {:error, "HAL-C2 MCP tool call failed."}
      end
    else
      {:error, {:http, status}} -> {:error, "HAL-C2 MCP endpoint responded with HTTP #{status}."}
      {:error, reason} -> {:error, "HAL-C2 MCP bridge request failed: #{inspect(reason)}"}
      _ -> {:error, "HAL-C2 MCP endpoint rejected initialization."}
    end
  end

  defp exchange(session, message) do
    parent = self()
    ref = make_ref()
    emit = fn payload -> send(parent, {ref, payload}) end

    case session.post.(session.endpoint, headers(session), JSON.encode!(message), emit) do
      {:ok, status, resp_headers} when status in 200..299 ->
        payloads = collect(ref)
        protocol = Enum.find_value(payloads, &protocol_version_of/1) || session.protocol_version

        session = %{
          session
          | session_id: resp_headers["mcp-session-id"] || session.session_id,
            protocol_version: protocol
        }

        {:ok, session, payloads}

      {:ok, status, _headers} ->
        collect(ref)
        {:error, {:http, status}}

      {:error, reason} ->
        collect(ref)
        {:error, reason}
    end
  end

  defp collect(ref) do
    receive do
      {^ref, payload} -> [payload | collect(ref)]
    after
      0 -> []
    end
  end
end
