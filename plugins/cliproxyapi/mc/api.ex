defmodule HalC2Plugins.CliProxyApi.Api do
  @moduledoc """
  The proxy's management API, `/v8/management`, over `:httpc`. `conn` is
  `%{base: "http://127.0.0.1:8317", key: management key}`.

  Every call answers `{:ok, body, headers}` or `{:error, kind, message}`, the message
  the proxy's own (`{"error": ...}`) where it gave one. `kind` is `:auth` for a 401 or
  403, which the caller must not repeat: five failed keys get this machine's address
  banned from the management API for half an hour. `:down` is a proxy that does not
  answer, `:missing` a 404, `:http` any other refusal, `:conflict` a 412 (the config
  changed under an `If-Match`). An https proxy's certificate is checked.
  """

  @prefix "/v8/management"
  @timeout 10_000

  def get(conn, path, query \\ []), do: request(conn, :get, path, query, nil, [])
  def delete(conn, path, query \\ []), do: request(conn, :delete, path, query, nil, [])
  def post(conn, path, body, query \\ []), do: request(conn, :post, path, query, body, [])
  def patch(conn, path, body), do: request(conn, :patch, path, [], body, [])

  @doc "`PUT` with `If-Match: etag` (none when `etag` is nil)."
  def put(conn, path, body, etag),
    do: request(conn, :put, path, [], body, if(etag, do: [{"if-match", etag}], else: []))

  @doc "The ETag the proxy gave with a config read."
  def etag(headers),
    do: Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == "etag", do: v end)

  defp request(conn, method, path, query, body, headers) do
    url =
      String.trim_trailing(conn.base, "/") <>
        @prefix <> path <> if(query == [], do: "", else: "?" <> URI.encode_query(query))

    headers = [{"authorization", "Bearer " <> conn.key} | headers]
    charlists = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req =
      case body do
        nil -> {to_charlist(url), charlists}
        body -> {to_charlist(url), charlists, ~c"application/json", JSON.encode!(body)}
      end

    options = [timeout: @timeout, connect_timeout: 3_000]

    options =
      if String.starts_with?(url, "https:"),
        do: [{:ssl, :httpc.ssl_verify_host_options(true)} | options],
        else: options

    case :httpc.request(method, req, options, body_format: :binary) do
      {:ok, {{_, status, _}, headers, text}} ->
        answer(status, strings(headers), text)

      {:error, reason} ->
        {:error, :down, "The proxy at #{conn.base} does not answer (#{reason(reason)})."}
    end
  end

  defp answer(status, headers, text) when status in 200..299 do
    case JSON.decode(text) do
      {:ok, body} -> {:ok, body, headers}
      {:error, _} -> {:ok, text, headers}
    end
  end

  defp answer(status, _headers, text) do
    message = message(text) || "The proxy answered #{status}."

    kind =
      cond do
        status in [401, 403] -> :auth
        status == 404 -> :missing
        status == 412 -> :conflict
        true -> :http
      end

    {:error, kind, message}
  end

  defp message(text) do
    case JSON.decode(text) do
      {:ok, %{"error" => error} = body} when is_binary(error) ->
        case body["message"] do
          detail when is_binary(detail) and detail != "" -> "#{error}: #{detail}"
          _ -> error
        end

      {:ok, %{"message" => message}} when is_binary(message) ->
        message

      _ ->
        case String.trim(text) do
          "" -> nil
          text -> String.slice(text, 0, 300)
        end
    end
  end

  defp strings(headers), do: Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)

  defp reason({:failed_connect, [_, {_, _, reason} | _]}), do: inspect(reason)
  defp reason({:failed_connect, _}), do: "connection refused"
  defp reason(reason), do: inspect(reason)
end
