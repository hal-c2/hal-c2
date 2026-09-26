defmodule T3.Test.FakeHttp do
  @moduledoc """
  A loopback HTTP service standing in for a provider's web API (Grok's billing,
  OpenCode Go's usage, an OpenCode server). `start/1` serves `routes`, a map from
  request path to `{status, json_body}` or to `fun.(conn) -> {status, json_body}`,
  and returns its base URL; `requests/1` lists what it was asked.
  """
  @behaviour Plug

  import Plug.Conn

  @doc "Starts the service under the test supervisor; returns `{base_url, server}`."
  def start(routes) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__, {routes, log}}, port: 0, ip: :loopback},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {"http://127.0.0.1:#{port}", log}
  end

  @doc "The requests served so far: `%{method, path, query, authorization, body}`."
  def requests(log), do: Agent.get(log, &Enum.reverse/1)

  @impl true
  def init(arg), do: arg

  @impl true
  def call(conn, {routes, log}) do
    {:ok, body, conn} = read_body(conn)

    Agent.update(log, fn requests ->
      [
        %{
          "method" => conn.method,
          "path" => conn.request_path,
          "query" => conn.query_string,
          "authorization" => List.first(get_req_header(conn, "authorization")),
          "body" => body
        }
        | requests
      ]
    end)

    {status, reply} =
      case routes[conn.request_path] do
        nil -> {404, %{"error" => "not found"}}
        fun when is_function(fun, 1) -> fun.(conn)
        {status, reply} -> {status, reply}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(reply))
  end
end
