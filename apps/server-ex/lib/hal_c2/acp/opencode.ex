defmodule HalC2.Acp.OpenCode do
  @moduledoc """
  The HTTP API of the server `opencode acp --port` runs beside its ACP stdio, for
  what ACP has no call for (`OpenCodeAdapterV2`): steering a running turn
  (`prompt_async`) and forking a session at a user message, which is how a thread
  rewinds and how a forked thread starts. The server listens on loopback and takes
  the `opencode` user with a password made for the process.

  OpenCode's fork keeps the messages before the one it is given (exclusive) and gives
  the copies new ids, in order.
  """

  @timeout 30_000

  @type server :: %{url: String.t(), password: String.t()}

  @doc "`command` and `env` with a server of their own, and how to reach it."
  @spec serve([String.t()], [{String.t(), String.t()}]) ::
          {[String.t()], [{String.t(), String.t()}], server}
  def serve(command, env) do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    password = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    {command ++ ["--port", "#{port}"], [{"OPENCODE_SERVER_PASSWORD", password} | env],
     %{url: "http://127.0.0.1:#{port}", password: password}}
  end

  @doc """
  Adds a message to the session's running turn. OpenCode's loop takes it before its
  next step; `model` is `provider/model`, `agent` and `variant` the session's.
  """
  @spec steer(server, String.t(), String.t(), keyword) :: :ok | {:error, String.t()}
  def steer(server, session, text, opts \\ []) do
    case String.trim(text) do
      "" ->
        {:error, "OpenCode steering requires text or an attachment"}

      text ->
        body =
          %{"parts" => [%{"type" => "text", "text" => text}]}
          |> put(
            "model",
            case String.split(opts[:model] || "", "/", parts: 2) do
              [provider, model] when provider != "" and model != "" ->
                %{"providerID" => provider, "modelID" => model}

              _ ->
                nil
            end
          )
          |> put("agent", opts[:agent])
          |> put("variant", opts[:variant])

        case request(server, :post, "/session/#{session}/prompt_async", body) do
          {:ok, status, _} when status in 200..299 -> :ok
          other -> {:error, failure("steer the turn", other)}
        end
    end
  end

  @doc "The session's messages (`limit`: the newest that many), oldest first."
  @spec messages(server, String.t(), pos_integer | nil) :: {:ok, [map]} | {:error, String.t()}
  def messages(server, session, limit \\ nil) do
    query = if limit, do: "?limit=#{limit}", else: ""

    case request(server, :get, "/session/#{session}/message#{query}", nil) do
      {:ok, 200, list} when is_list(list) -> {:ok, list}
      other -> {:error, failure("read the session", other)}
    end
  end

  @doc "The id of the session's newest message, or nil for an empty session."
  @spec leaf(server, String.t()) :: String.t() | nil
  def leaf(server, session) do
    case messages(server, session, 1) do
      {:ok, [message]} -> id(message)
      _ -> nil
    end
  end

  @doc """
  The first user message after `leaf` (the newest message before the turn began):
  the turn's own message, whatever the user steered in after it.
  """
  @spec turn_message(server, String.t(), String.t() | nil) :: String.t() | nil
  def turn_message(server, session, leaf) do
    recent = with {:ok, list} <- messages(server, session, 100), do: after_leaf(list, leaf)

    found =
      case recent do
        :missing -> with {:ok, list} <- messages(server, session), do: after_leaf(list, leaf)
        other -> other
      end

    case found do
      list when is_list(list) ->
        Enum.find_value(list, &(get_in(&1, ["info", "role"]) == "user" && id(&1)))

      _ ->
        nil
    end
  end

  defp after_leaf(list, nil), do: list

  defp after_leaf(list, leaf) do
    case Enum.split_while(list, &(id(&1) != leaf)) do
      {_, [_ | rest]} -> rest
      {_, []} -> :missing
    end
  end

  @doc """
  Forks `session` before the message `before` (all of it for nil): the fork's id and
  each kept message's new id by its old one.
  """
  @spec fork(server, String.t(), String.t() | nil) ::
          {:ok, String.t(), %{String.t() => String.t()}} | {:error, String.t()}
  def fork(server, session, before) do
    with {:ok, source} <- messages(server, session),
         {:ok, kept} <- kept(source, before),
         {:ok, fork} <- fork_session(server, session, before),
         {:ok, copied} <- messages(server, fork) do
      if length(copied) == length(kept),
        do: {:ok, fork, Map.new(Enum.zip(Enum.map(kept, &id/1), Enum.map(copied, &id/1)))},
        else: {:error, "OpenCode did not preserve the requested rewind boundary."}
    end
  end

  defp kept(source, nil), do: {:ok, source}

  defp kept(source, before) do
    case Enum.split_while(source, &(id(&1) != before)) do
      {kept, [_ | _]} -> {:ok, kept}
      {_, []} -> {:error, "The OpenCode rewind boundary is no longer available."}
    end
  end

  defp fork_session(server, session, before) do
    case request(server, :post, "/session/#{session}/fork", put(%{}, "messageID", before)) do
      {:ok, 200, %{"id" => id}} when is_binary(id) -> {:ok, id}
      other -> {:error, failure("fork the session", other)}
    end
  end

  defp id(message), do: get_in(message, ["info", "id"])

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp failure(action, {:ok, status, body}) do
    detail =
      case body do
        %{"data" => %{"message" => message}} when is_binary(message) -> ": #{message}"
        %{"message" => message} when is_binary(message) -> ": #{message}"
        _ -> ""
      end

    "OpenCode could not #{action} (HTTP #{status})#{detail}"
  end

  defp failure(action, {:error, reason}),
    do: "OpenCode could not #{action}: #{inspect(reason)}"

  defp request(server, method, path, body) do
    auth =
      {~c"authorization", ~c"Basic " ++ to_charlist(Base.encode64("opencode:#{server.password}"))}

    url = to_charlist(server.url <> path)

    request =
      case method do
        :get -> {url, [auth]}
        :post -> {url, [auth], ~c"application/json", JSON.encode!(body || %{})}
      end

    case :httpc.request(method, request, [timeout: @timeout, connect_timeout: 5_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, body}} ->
        {:ok, status,
         case JSON.decode(body) do
           {:ok, json} -> json
           _ -> nil
         end}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
