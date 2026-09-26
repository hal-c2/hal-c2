defmodule HalC2.Connect.Http do
  @moduledoc """
  HAL-C2 Connect's HTTP routes (`environmentHttp.ts`), forwarded from `HalC2.Web.Router`:
  a signed-in client's `/api/connect/*` (relay scopes), and the relay's own
  `/api/hal-c2-connect/*`, which carry relay-signed proofs instead of a session.
  Credential responses are never cached.
  """

  use Plug.Router

  plug :match
  plug :dispatch

  post "/link-proof" do
    with_scope(conn, "relay:write", fn body ->
      HalC2.Connect.link_proof(body, %{
        forwarded?:
          get_req_header(conn, "x-forwarded-host") != [] or
            get_req_header(conn, "x-forwarded-proto") != [],
        host: conn.host,
        port: conn.port
      })
    end)
  end

  post "/relay-config", do: with_scope(conn, "relay:write", &HalC2.Connect.apply_relay_config/1)

  get "/link-state",
    do: with_scope(conn, "relay:read", fn _ -> {:ok, HalC2.Connect.link_state()} end)

  post "/unlink", do: with_scope(conn, "relay:write", fn _ -> HalC2.Connect.unlink() end)
  post "/preferences", do: with_scope(conn, "relay:write", &HalC2.Connect.preferences/1)

  post "/health", do: relay(conn, &HalC2.Connect.health/1)
  post "/mint-credential", do: relay(conn, &HalC2.Connect.mint_credential/1)

  match _, do: send_resp(conn, 404, "not found")

  defp with_scope(conn, scope, fun) do
    case HalC2.Auth.request_session(conn) do
      {:ok, %{scopes: scopes}} ->
        if scope in scopes,
          do: respond(conn, fun.(body(conn))),
          else:
            json(conn, 403, %{"_tag" => "EnvironmentScopeRequiredError", "requiredScope" => scope})

      :error ->
        json(conn, 401, %{
          "_tag" => "EnvironmentHttpUnauthorizedError",
          "message" => "Unauthorized."
        })
    end
  end

  defp relay(conn, fun) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> respond(fun.(body(conn)))
  end

  defp respond(conn, {:ok, reply}), do: json(conn, 200, reply)

  defp respond(conn, {:error, status, message}),
    do: json(conn, status, %{"_tag" => tag(status), "message" => message})

  defp respond(conn, {:error, 503, message, runtime}) do
    json(conn, 503, %{
      "_tag" => "EnvironmentCloudEndpointUnavailableError",
      "message" => message,
      "endpointRuntimeStatus" => runtime
    })
  end

  defp tag(400), do: "EnvironmentHttpBadRequestError"
  defp tag(401), do: "EnvironmentHttpUnauthorizedError"
  defp tag(409), do: "EnvironmentHttpConflictError"
  defp tag(_), do: "EnvironmentInternalError"

  defp body(conn) do
    with {:ok, raw, _conn} <- read_body(conn),
         {:ok, %{} = body} <- JSON.decode(if(raw == "", do: "{}", else: raw)),
         do: body,
         else: (_ -> %{})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(body))
  end
end
