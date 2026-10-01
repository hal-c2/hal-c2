defmodule HalC2.Web.Router do
  @moduledoc """
  HTTP entry point: environment discovery, pairing and session auth (`HalC2.Auth`), and
  the client WebSocket. A socket needs a WebSocket ticket, or the MC's own access
  token (`HalC2.Web.token/0`) for local tools.
  """

  use Plug.Router

  @cors_headers [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-methods", "GET, POST, OPTIONS"},
    {"access-control-allow-headers",
     "authorization, b3, traceparent, content-type, dpop, x-hal-c2-orchestration-protocol"},
    {"access-control-max-age", "600"}
  ]

  plug :cors
  plug :match
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug :dispatch

  # Clients reach an MC from other origins (the hosted app, another dev server)
  # with bearer tokens rather than cookies, so any origin may call it.
  defp cors(%{method: "OPTIONS"} = conn, _opts),
    do: conn |> merge_resp_headers(@cors_headers) |> send_resp(204, "") |> halt()

  defp cors(conn, _opts), do: merge_resp_headers(conn, @cors_headers)

  get "/.well-known/hal-c2/environment" do
    body =
      HalC2.Environment.descriptor()
      |> Map.put("mc", Atom.to_string(node()))
      |> Map.put("cluster", cluster())
      |> JSON.encode_to_iodata!()

    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # A pairing link opened in a browser lands here. The MC serves no app, so the
  # page says where the link goes instead of answering "not found".
  get "/" do
    label = HalC2.Environment.descriptor()["label"]

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, """
    <!doctype html><meta charset="utf-8"><title>HAL-C2 MC #{Plug.HTML.html_escape(label)}</title>
    <body style="font:15px system-ui;max-width:34em;margin:4em auto;padding:0 1em;line-height:1.5">
    <h1 style="font-size:1.3em">HAL-C2 MC: #{Plug.HTML.html_escape(label)}</h1>
    <p>This is a pairing link for a HAL-C2 MC. To connect, copy the full address from the
    address bar and paste it into <b>HAL-C2 → Settings → Connections → Add environment</b>.</p>
    <p>Pairing links work once and expire after 5 minutes.</p>
    </body>
    """)
  end

  # Pairing: exchange a one-time pairing token for a bearer access token, or with a
  # `DPoP` proof for a token bound to the client's key. `scope` asks for fewer scopes.
  # A HAL-C2 Connect credential was minted for one device key and needs its proof.
  post "/oauth/token" do
    params = conn.body_params

    with "urn:ietf:params:oauth:grant-type:token-exchange" <- params["grant_type"],
         "urn:hal-c2:params:oauth:token-type:environment-bootstrap" <-
           params["subject_token_type"],
         {:ok, requested} <- requested_scopes(params["scope"]),
         {:ok, proof_jkt} <- exchange_proof(conn),
         {:ok, access, expires_in, scopes} <-
           HalC2.Auth.exchange(params["subject_token"] || "", %{
             label: params["client_label"],
             device_type: params["client_device_type"],
             os: params["client_os"],
             user_agent: conn |> get_req_header("user-agent") |> List.first(),
             scopes: requested,
             proof_jkt: proof_jkt
           }) do
      json(conn, 200, %{
        "access_token" => access,
        "issued_token_type" => "urn:ietf:params:oauth:token-type:access_token",
        "token_type" => if(proof_jkt, do: "DPoP", else: "Bearer"),
        "expires_in" => expires_in,
        "scope" => Enum.join(scopes, " ")
      })
    else
      {:error, :invalid_scope} ->
        json(conn, 400, %{"error" => "invalid_scope"})

      {:error, :scope_not_granted} ->
        json(conn, 400, %{"error" => "invalid_scope"})

      {:error, :dpop, reason} ->
        conn
        |> put_resp_header("www-authenticate", "DPoP")
        |> json(401, auth_invalid("invalid_credential", reason))

      _ ->
        json(conn, 400, %{"error" => "invalid_grant"})
    end
  end

  get "/api/auth/session" do
    auth = HalC2.Environment.server_config()["auth"]

    case request_session(conn) do
      {:ok, session} ->
        json(conn, 200, %{
          "authenticated" => true,
          "auth" => auth,
          "scopes" => session.scopes,
          "sessionMethod" => HalC2.Auth.session_method(session.proof_jkt),
          "expiresAt" => iso(session.expires_at)
        })

      {:error, _reason, _dpop} ->
        json(conn, 200, %{"authenticated" => false, "auth" => auth})
    end
  end

  post "/api/auth/websocket-ticket" do
    with {:ok, session} <- request_session(conn),
         {:ok, ticket, expires_at} <- HalC2.Auth.issue_ticket(session) do
      json(conn, 200, %{"ticket" => ticket, "expiresAt" => iso(expires_at)})
    else
      {:error, reason, dpop} -> json(conn, 401, auth_invalid(reason, dpop))
    end
  end

  # The `hal-c2` MCP server for agents; each thread's agent has its own bearer.
  post "/mcp" do
    {:ok, body, conn} = read_body(conn, length: 10_000_000)
    authorization = conn |> get_req_header("authorization") |> List.first()

    case HalC2.Mcp.handle(authorization, body) do
      {status, nil} -> send_resp(conn, status, "")
      {status, reply} -> json(conn, status, reply)
    end
  end

  # No server-initiated stream: every answer comes back on its request.
  get "/mcp", do: send_resp(conn, 405, "")
  delete "/mcp", do: send_resp(conn, 200, "")

  # Settings → Connections: pairing links and the clients paired with this MC.
  post "/api/auth/pairing-token" do
    with_scope(conn, "access:write", fn _session ->
      with {:ok, body} <- json_body(conn),
           {:ok, link} <- HalC2.Auth.create_pairing_link(body),
           do: {200, link}
    end)
  end

  get "/api/auth/pairing-links" do
    with_scope(conn, "access:read", fn _session -> {200, HalC2.Auth.pairing_links()} end)
  end

  post "/api/auth/pairing-links/revoke" do
    with_scope(conn, "access:write", fn _session ->
      with {:ok, %{"id" => id}} <- json_body(conn),
           do: {200, %{"revoked" => HalC2.Auth.revoke_pairing_link(id)}}
    end)
  end

  get "/api/auth/clients" do
    with_scope(conn, "access:read", fn session ->
      {200,
       for(
         client <- HalC2.Auth.clients(),
         do: %{client | "current" => client["sessionId"] == session.id}
       )}
    end)
  end

  post "/api/auth/clients/revoke" do
    with_scope(conn, "access:write", fn session ->
      case json_body(conn) do
        {:ok, %{"sessionId" => id}} when id == session.id ->
          {403,
           %{
             "_tag" => "EnvironmentOperationForbiddenError",
             "code" => "operation_forbidden",
             "reason" => "current_session_revoke_not_allowed",
             "traceId" => trace_id()
           }}

        {:ok, %{"sessionId" => id}} ->
          {200, %{"revoked" => HalC2.Auth.revoke_client(id)}}

        error ->
          error
      end
    end)
  end

  post "/api/auth/clients/revoke-others" do
    with_scope(conn, "access:write", fn session ->
      {200, %{"revokedCount" => HalC2.Auth.revoke_other_clients(session.id)}}
    end)
  end

  # The cluster of this person's machines (`HalC2.Cluster`). A machine joining through a
  # pairing link is admitted with the link's one-time session, which ends there.
  get "/api/cluster" do
    with_scope(conn, "access:read", fn _session -> {200, HalC2.Cluster.status()} end)
  end

  post "/api/cluster/members" do
    with_scope(conn, "access:write", fn session ->
      with {:ok, body} <- json_body(conn) do
        answer = cluster_answer(HalC2.Cluster.admit(body))
        if session.id && elem(answer, 0) == 200, do: HalC2.Auth.revoke_client(session.id)
        answer
      end
    end)
  end

  post "/api/cluster/invite" do
    with_scope(conn, "access:write", fn _session ->
      with {:ok, body} <- json_body(conn), do: cluster_answer(HalC2.Cluster.invite(body))
    end)
  end

  post "/api/cluster/join" do
    with_scope(conn, "access:write", fn _session ->
      case json_body(conn) do
        {:ok, %{"link" => link}} when is_binary(link) -> cluster_answer(HalC2.Cluster.join(link))
        _ -> {:error, :invalid_body}
      end
    end)
  end

  post "/api/cluster/remove" do
    with_scope(conn, "access:write", fn _session ->
      case json_body(conn) do
        {:ok, %{"id" => id}} when is_binary(id) -> cluster_answer(HalC2.Cluster.remove(id))
        _ -> {:error, :invalid_body}
      end
    end)
  end

  # A pull request's patch, which is large enough to want HTTP rather than the socket.
  post "/api/pull-requests/diff" do
    with_scope(conn, "orchestration:read", fn _session ->
      with {:ok, input} <- json_body(conn) do
        case HalC2.PullRequests.diff_on_project_mc(input) do
          {:ok, result} ->
            {200, result}

          {:error, %{"_tag" => tag} = error} ->
            status = if tag == "PullRequestUnavailableError", do: 503, else: 502
            {status, Map.delete(error, "message")}
        end
      end
    end)
  end

  # Client spans (OTLP JSON), kept in the MC's trace file and forwarded to its
  # collector (`HalC2.Traces.accept/1`).
  post "/api/observability/v1/traces" do
    with_scope(conn, "orchestration:operate", fn _session ->
      with {:ok, payload} <- json_body(conn) do
        case HalC2.Traces.accept(payload) do
          :ok -> {204, ""}
          {:error, :export} -> {502, "Trace export failed."}
        end
      end
    end)
  end

  get "/ws" do
    conn = fetch_query_params(conn)

    with :ok <- compatible_protocol(conn.query_params["protocol"]),
         {:ok, session} <- socket_session(conn.query_params) do
      conn
      |> WebSockAdapter.upgrade(HalC2.Web.Socket, %{session: session}, timeout: 60_000)
      |> halt()
    else
      {:incompatible, side} ->
        version = HalC2.Web.Protocol.version()

        json(conn, 426, %{
          "code" => "protocol_incompatible",
          "message" => "Update this #{side}: the MC speaks protocol #{version}.",
          "protocolVersion" => version
        })

      :error ->
        send_resp(conn, 401, "unauthorized")
    end
  end

  # A client may name the protocol it speaks (`?protocol=`); the side with the older
  # one is the side to update.
  defp compatible_protocol(nil), do: :ok

  defp compatible_protocol(protocol) do
    ours = HalC2.Web.Protocol.version()

    case Integer.parse(protocol) do
      {theirs, ""} when theirs > ours -> {:incompatible, "MC"}
      {theirs, ""} when theirs < ours -> {:incompatible, "client"}
      _ -> :ok
    end
  end

  # Every MC this one knows, so a client paired here can reach all of them.
  defp cluster do
    for {_mc, descriptor} <- HalC2.Shell.environments(),
        do: Map.take(descriptor, ["environmentId", "label"])
  end

  defp cluster_answer(:ok), do: {200, %{}}
  defp cluster_answer({:ok, body}), do: {200, body}

  defp cluster_answer({:error, reason}),
    do:
      {409,
       %{"reason" => HalC2.Cluster.reason(reason), "message" => HalC2.Cluster.describe(reason)}}

  # The session a socket opens for, or nil for one opened with the MC's own token.
  defp socket_session(%{"wsTicket" => ticket}), do: HalC2.Auth.take_ticket(ticket)

  # The MC's own access token, for local tools and development.
  defp socket_session(%{"token" => token}),
    do: if(Plug.Crypto.secure_compare(token, HalC2.Web.token()), do: {:ok, nil}, else: :error)

  defp socket_session(_), do: :error

  # Runs `fun.(session)` for a bearer whose session has `scope`; `fun` returns
  # `{status, body}` or `{:error, reason}`.
  defp with_scope(conn, scope, fun) do
    case request_session(conn) do
      {:ok, session} ->
        if scope in session.scopes do
          case fun.(session) do
            {204, nil} ->
              send_resp(conn, 204, "")

            {status, body} when is_integer(status) and is_binary(body) ->
              send_resp(conn, status, body)

            {status, body} when is_integer(status) ->
              json(conn, status, body)

            {:error, _} ->
              json(conn, 400, %{
                "_tag" => "EnvironmentRequestInvalidError",
                "traceId" => trace_id()
              })
          end
        else
          json(conn, 403, %{
            "_tag" => "EnvironmentScopeRequiredError",
            "code" => "insufficient_scope",
            "requiredScope" => scope,
            "traceId" => trace_id()
          })
        end

      {:error, reason, dpop} ->
        json(conn, 401, auth_invalid(reason, dpop))
    end
  end

  defp auth_invalid(reason, dpop) do
    %{
      "_tag" => "EnvironmentAuthInvalidError",
      "code" => "auth_invalid",
      "reason" => reason,
      "traceId" => trace_id()
    }
    |> then(&if(dpop, do: Map.put(&1, "dpopFailureReason", to_string(dpop)), else: &1))
  end

  @scopes ~w(orchestration:read orchestration:operate terminal:operate review:write access:read access:write relay:read relay:write)

  # `scope` on a token exchange: space-separated, each one the MC knows.
  defp requested_scopes(nil), do: {:ok, nil}

  defp requested_scopes(scope) do
    requested = String.split(scope)

    if requested != [] and Enum.all?(requested, &(&1 in @scopes)),
      do: {:ok, Enum.uniq(requested)},
      else: {:error, :invalid_scope}
  end

  # A DPoP proof on the exchange binds the token to the proof's key.
  defp exchange_proof(conn) do
    case get_req_header(conn, "dpop") do
      [] ->
        {:ok, nil}

      [proof | _] ->
        case HalC2.Auth.Dpop.verify(proof, conn.method, request_url(conn)) do
          {:ok, thumbprint} -> {:ok, thumbprint}
          {:error, reason} -> {:error, :dpop, reason}
        end
    end
  end

  defp json_body(conn) do
    with {:ok, body, _conn} <- read_body(conn),
         {:ok, %{} = decoded} <- JSON.decode(if(body == "", do: "{}", else: body)) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_body}
    end
  end

  # The session a request authenticates as (`HalC2.Auth.authenticate/1`): `{:ok, session}`
  # or `{:error, reason, dpop_failure}`.
  defp request_session(conn), do: HalC2.Auth.authenticate(conn)

  defp trace_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(body))
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  # Signed URLs are their own authorization. Each names the MC that issued it,
  # which holds the file and checks the signature; this MC only forwards.
  post "/api/attachments/upload/:token" do
    with {:ok, mc} <- HalC2.Attachments.issuer(token),
         {:ok, body, conn} <- read_all(conn, 50 * 1024 * 1024 + 1, []) do
      case remote(mc, HalC2.Attachments, :store, [token, body]) do
        :ok -> send_resp(conn, 204, "")
        {:error, status, message} -> send_resp(conn, status, message)
        _ -> send_resp(conn, 502, "The MC holding this upload is unavailable.")
      end
    else
      :too_large -> send_resp(conn, 413, "The upload is too large.")
      _ -> send_resp(conn, 403, "The link is invalid or expired.")
    end
  end

  # A version's bundle, for a cluster peer holding a one-time link (`HalC2.Upgrade.Source`).
  get "/api/upgrade/:token" do
    case HalC2.Upgrade.Source.take(token) do
      {:ok, path} ->
        conn
        |> put_resp_content_type("application/gzip", nil)
        |> send_file(200, path)

      :error ->
        send_resp(conn, 403, "The link is invalid or expired.")
    end
  end

  # An MC run from a checkout loads what `mix compile` changed since it started
  # (`mix hal_c2.upgrade --dev` with no MC names). Only the MC's own token may ask.
  post "/api/dev/reload" do
    bearer = conn |> get_req_header("authorization") |> List.first("")

    cond do
      HalC2.Upgrade.release_root() != nil ->
        send_resp(conn, 404, "")

      not Plug.Crypto.secure_compare(bearer, "Bearer " <> HalC2.Web.token()) ->
        send_resp(conn, 401, "")

      true ->
        case HalC2.Upgrade.reload_checkout() do
          {:ok, report} ->
            names = &Enum.map(&1, fn mod -> inspect(mod) end)

            json(conn, 200, %{
              "changed" => names.(report.changed),
              "needsRestart" => names.(report.needs_restart),
              "lingering" => names.(report.lingering)
            })

          {:error, reason} ->
            json(conn, 409, %{"reason" => inspect(reason)})
        end
    end
  end

  # The trailing segment is the file's name, for the client; the token decides what is served.
  get "/api/assets/:token", do: serve_asset(conn, token)
  get "/api/assets/:token/*_name", do: serve_asset(conn, token)

  defp serve_asset(conn, token) do
    headers = for {k, v} <- conn.req_headers, k in ["range", "if-range"], into: %{}, do: {k, v}

    with {:ok, mc} <- HalC2.Attachments.issuer(token),
         {:ok, status, resp_headers, body} <-
           remote(mc, HalC2.Attachments, :serve, [token, headers]) do
      conn
      |> merge_resp_headers(resp_headers)
      |> send_resp(status, body)
    else
      {:error, status, message} -> send_resp(conn, status, message)
      _ -> send_resp(conn, 403, "The link is invalid or expired.")
    end
  end

  defp read_all(conn, left, acc) do
    case read_body(conn, length: min(left, 8_000_000)) do
      {:ok, data, conn} ->
        if byte_size(data) >= left,
          do: :too_large,
          else: {:ok, IO.iodata_to_binary([acc, data]), conn}

      {:more, data, conn} ->
        if byte_size(data) >= left,
          do: :too_large,
          else: read_all(conn, left - byte_size(data), [acc, data])

      {:error, _} = error ->
        error
    end
  end

  defp remote(mc, module, fun, args) do
    :erpc.call(mc, module, fun, args, 60_000)
  catch
    _, _ -> {:error, 502, "The MC holding this file is unavailable."}
  end

  # HAL-C2 Connect: a client's link settings, and the relay's signed requests.
  forward "/api/connect", to: HalC2.Connect.Http
  forward "/api/hal-c2-connect", to: HalC2.Connect.Http

  # Every MC's device hub, relayed to the MC that owns it (`HalC2.Devices.Proxy`).
  match "/api/device-hub/*rest", do: HalC2.Devices.Proxy.serve(conn, rest)

  match _ do
    send_resp(conn, 404, "not found")
  end
end
