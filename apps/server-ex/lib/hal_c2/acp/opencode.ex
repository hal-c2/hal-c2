defmodule HalC2.Acp.OpenCode do
  @moduledoc """
  The HTTP API of the server `opencode acp --port` runs beside its ACP stdio, for what
  ACP has no call for (`OpenCodeAdapterV2`): forking a session at a user message, which
  is how a thread rewinds and how a forked thread starts, and reading the session's
  messages, whose ids name those cut points. The server listens on loopback and takes
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

    {command ++ ["--port", "#{port}", "--hostname", "127.0.0.1"],
     [{"OPENCODE_SERVER_USERNAME", "opencode"}, {"OPENCODE_SERVER_PASSWORD", password} | env],
     %{url: "http://127.0.0.1:#{port}", password: password}}
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

  @doc "The id of the session's newest message: nil for an empty session."
  @spec leaf(server, String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def leaf(server, session) do
    with {:ok, list} <- messages(server, session, 1),
         do: {:ok, list |> List.last() |> then(&(&1 && id(&1)))}
  end

  @doc """
  The first user message after `leaf` (the newest message before the turn began, nil
  when the session was empty): the turn's own message, whatever was steered in after it.
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
    body = if before, do: %{"messageID" => before}, else: %{}

    case request(server, :post, "/session/#{session}/fork", body) do
      {:ok, 200, %{"id" => id}} when is_binary(id) -> {:ok, id}
      other -> {:error, failure("fork the session", other)}
    end
  end

  defp id(message), do: get_in(message, ["info", "id"])

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
