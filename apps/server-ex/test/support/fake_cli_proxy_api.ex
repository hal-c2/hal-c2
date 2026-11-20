defmodule HalC2.Test.FakeCliProxyApi do
  @moduledoc """
  CLIProxyAPI's management API (`/v8/management`) and its GitHub release downloads
  (`/releases/<file>`), on a loopback port, for the CLIProxyAPI plugin's scenarios.
  `test/support/fake_cli_proxy_api.sh` stands in for the binary; this answers what the
  plugin asks the proxy, in the shapes v8.0.79 gives (`internal/api/server_management_v8.go`).

  `start/0` returns `%{base, port, agent}`. The scenario sets what it holds with
  `update/2` (`refuse` to refuse every management key with that message, `queue` of
  usage records or `no_usage` to refuse the queue with that message, `logs`,
  `credentials`, `keys`, `access`, `release` files, and `hold` to keep every release
  download waiting) and reads what it was asked with `requests/1`.
  """
  @behaviour Plug

  import Plug.Conn

  @prefix "/v8/management"

  def start do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          refuse: nil,
          queue: [],
          logs: [],
          credentials: [],
          oauth: %{},
          keys: %{},
          access: [],
          version: 1,
          latest: "8.0.79",
          release: %{},
          refuse_keys: nil,
          no_usage: nil,
          hold: false,
          requests: []
        }
      end)

    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__, agent}, port: 0, ip: :loopback},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{base: "http://127.0.0.1:#{port}", port: port, agent: agent}
  end

  def update(%{agent: agent}, fun), do: Agent.update(agent, fun)
  def get(%{agent: agent}), do: Agent.get(agent, & &1)

  @doc "What it was asked, oldest first: `%{method, path, query, authorization, body}`."
  def requests(fake), do: Enum.reverse(get(fake).requests)

  @impl true
  def init(agent), do: agent

  @impl true
  def call(conn, agent) do
    conn = fetch_query_params(conn)
    {:ok, text, conn} = read_body(conn)
    body = if text == "", do: nil, else: JSON.decode!(text)

    Agent.update(agent, fn state ->
      request = %{
        "method" => conn.method,
        "path" => conn.request_path,
        "query" => conn.query_params,
        "authorization" => List.first(get_req_header(conn, "authorization")),
        "body" => body
      }

      %{state | requests: [request | state.requests]}
    end)

    # A held download waits until the scenario ends and the server goes with it.
    if hold?(conn, agent), do: receive(do: (:never -> :ok))

    {status, reply, headers} =
      Agent.get_and_update(agent, fn state ->
        case route(conn, body, state) do
          {status, reply, state} -> {{status, reply, []}, state}
          {status, reply, headers, state} -> {{status, reply, headers}, state}
        end
      end)

    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_resp_header(conn, k, v) end)

    case reply do
      {:raw, bytes} ->
        send_resp(conn, status, bytes)

      reply ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, JSON.encode!(reply))
    end
  end

  defp hold?(%{request_path: "/releases/" <> _}, agent), do: Agent.get(agent, & &1.hold)
  defp hold?(_conn, _agent), do: false

  defp route(%{request_path: "/releases/" <> file}, _body, state) do
    case state.release[file] do
      nil -> {404, {:raw, "Not Found"}, state}
      bytes -> {200, {:raw, bytes}, state}
    end
  end

  defp route(%{request_path: @prefix <> "/oauth/callback", method: "POST"}, body, state) do
    query = URI.decode_query(URI.parse(body["redirect_url"] || "").query || "")
    key = query["state"] || body["state"]

    cond do
      not Map.has_key?(state.oauth, key) ->
        {404, %{"status" => "error", "error" => "unknown or expired state"}, state}

      query["error"] ->
        {200, %{"status" => "ok"}, put_in(state.oauth[key], {"error", query["error"]})}

      query["code"] ->
        provider = body["provider"]

        account = %{
          "id" => "#{provider}-user@example.com.json",
          "name" => "#{provider}-user@example.com.json",
          "provider" => provider,
          "email" => "user@example.com",
          "status" => "active",
          "disabled" => false
        }

        state = %{state | credentials: state.credentials ++ [account]}
        {200, %{"status" => "ok"}, put_in(state.oauth[key], "ok")}

      true ->
        {400, %{"status" => "error", "error" => "code or error is required"}, state}
    end
  end

  defp route(%{request_path: @prefix <> path} = conn, body, state) do
    if state.refuse && conn |> get_req_header("authorization") |> List.first() != nil do
      {401, %{"error" => state.refuse}, state}
    else
      management(conn.method, path, conn.query_params, body, if_match(conn), state)
    end
  end

  defp route(_conn, _body, state), do: {404, %{"error" => "not_found"}, state}

  defp management(
         "GET",
         "/observability/usage/queue",
         _query,
         _body,
         _match,
         %{no_usage: message} = state
       )
       when message != nil,
       do: {404, %{"error" => message}, state}

  defp management("GET", "/observability/usage/queue", query, _body, _match, state) do
    {taken, rest} = Enum.split(state.queue, String.to_integer(query["count"] || "1"))
    {200, taken, %{state | queue: rest}}
  end

  defp management("GET", "/observability/logs", _query, _body, _match, state) do
    reply = %{
      "lines" => state.logs,
      "line-count" => length(state.logs),
      "next-cursor" => "c#{state.version}"
    }

    {200, reply, %{state | logs: []}}
  end

  defp management("DELETE", "/observability/logs", _query, _body, _match, state),
    do: {200, %{"success" => true}, %{state | logs: []}}

  defp management("GET", "/credentials", _query, _body, _match, state),
    do: {200, %{"files" => state.credentials}, state}

  defp management(
         "PATCH",
         "/credentials/status",
         _query,
         %{"name" => name, "disabled" => disabled},
         _match,
         state
       ) do
    credentials =
      Enum.map(
        state.credentials,
        &if(&1["name"] == name, do: %{&1 | "disabled" => disabled}, else: &1)
      )

    {200, %{"status" => "ok"}, %{state | credentials: credentials}}
  end

  defp management("DELETE", "/credentials", %{"name" => name}, _body, _match, state),
    do:
      {200, %{"status" => "ok"},
       %{state | credentials: Enum.reject(state.credentials, &(&1["name"] == name))}}

  defp management(
         "GET",
         "/oauth/auth-url",
         %{"provider" => provider} = query,
         _body,
         _match,
         state
       ) do
    key = "st-#{map_size(state.oauth) + 1}"

    url =
      "https://example.invalid/oauth/#{provider}?state=#{key}#{if query["is_webui"], do: "&webui=1"}"

    {200, %{"status" => "ok", "url" => url, "state" => key}, put_in(state.oauth[key], "wait")}
  end

  defp management("GET", "/oauth/status", %{"state" => key}, _body, _match, state) do
    case state.oauth[key] do
      nil -> {200, %{"status" => "error", "error" => "unknown or expired state"}, state}
      {"error", error} -> {200, %{"status" => "error", "error" => error}, state}
      status -> {200, %{"status" => status}, state}
    end
  end

  defp management("DELETE", "/oauth/session", %{"state" => key}, _body, _match, state),
    do: {200, %{"status" => "ok"}, %{state | oauth: Map.delete(state.oauth, key)}}

  defp management("GET", "/server/latest-version", _query, _body, _match, state),
    do: {200, %{"latest-version" => state.latest}, state}

  defp management("GET", "/config/api-keys", _query, _body, _match, state),
    do: {200, state.keys, [etag(state)], state}

  defp management("GET", "/config/api-keys/" <> provider, _query, _body, _match, state) do
    case state.keys[provider] do
      nil -> {404, %{"error" => "not_found"}, state}
      groups -> {200, groups, [etag(state)], state}
    end
  end

  defp management("PUT", "/config/api-keys/" <> provider, _query, groups, match, state) do
    cond do
      stale?(match, state) ->
        {412, %{"error" => "precondition_failed"}, state}

      state.refuse_keys ->
        {400, %{"error" => "invalid config", "message" => state.refuse_keys}, state}

      true ->
        saved(%{state | keys: Map.put(state.keys, provider, groups)})
    end
  end

  defp management("GET", "/config/access/api-keys", _query, _body, _match, state),
    do: {200, state.access, [etag(state)], state}

  defp management("PUT", "/config/access/api-keys", _query, keys, match, state) do
    if stale?(match, state),
      do: {412, %{"error" => "precondition_failed"}, state},
      else: saved(%{state | access: keys})
  end

  defp management(_method, _path, _query, _body, _match, state),
    do: {404, %{"error" => "not_found"}, state}

  defp saved(state) do
    state = %{state | version: state.version + 1}
    {200, %{"status" => "ok", "config-version" => 8}, [etag(state)], state}
  end

  defp etag(state), do: {"etag", ~s("v#{state.version}")}
  defp stale?(nil, _state), do: false
  defp stale?(match, state), do: match != ~s("v#{state.version}")
  defp if_match(conn), do: conn |> get_req_header("if-match") |> List.first()
end
