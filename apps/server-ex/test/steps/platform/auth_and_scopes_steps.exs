defmodule HalC2.Steps.Platform.AuthAndScopes do
  @moduledoc "Steps for features/node/platform/auth-and-scopes.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @standard ~w(orchestration:read orchestration:operate terminal:operate review:write relay:read)
  @admin @standard ++ ~w(access:read access:write relay:write)

  # --- helpers -------------------------------------------------------------------

  # Runs SQL against the node's store, as an older node or the clock would have left it.
  defp sql(context, statement, args \\ []) do
    {:ok, db} = Exqlite.Sqlite3.open(context.node.store)

    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, statement)
      :ok = Exqlite.Sqlite3.bind(stmt, args)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
      rows
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  defp now, do: System.os_time(:millisecond)
  defp sha(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)

  # Pairs over `/oauth/token` and returns the access token.
  defp pair!(context, token, fields \\ %{}) do
    assert {200, %{"access_token" => access}} = Node.exchange(context.node, token, fields)
    access
  end

  defp standard!(context), do: pair!(context, HalC2.Auth.create_pairing_token(context.node.store))

  defp admin!(context) do
    {:ok, link} = HalC2.Auth.create_pairing_link(%{"scopes" => @admin, "label" => "Admin"})
    pair!(context, link["credential"], %{"client_label" => "Admin"})
  end

  defp session_id(access) do
    {:ok, session} = HalC2.Auth.session(access)
    session.id
  end

  # An RPC from the administrator's socket that must succeed: `{result, context}`.
  defp admin_call!(context, method, payload \\ %{}) do
    {reply, context} = World.call(context, method, payload, "admin")
    assert {:ok, result} = reply
    {result, context}
  end

  # A socket opened the way clients open one: a ticket bought with the session.
  defp socket!(context, access) do
    assert {200, _, %{"ticket" => ticket}} =
             Node.request(context.node, :post, "/api/auth/websocket-ticket", bearer: access)

    Node.connect(context.node, "wsTicket=#{ticket}")
  end

  # Starts the node again with the desktop app's bootstrap token (as `HalC2.Desktop` sets it).
  defp desktop_boot(context, token) do
    Application.put_env(:hal_c2, :desktop_token, token)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :desktop_token) end)
    %{context | node: Node.restart(context.node), clients: %{}}
  end

  # Moves the node's boot time so its desktop token expires `ms_left` from now.
  defp desktop_expires_in(ms_left),
    do: :sys.replace_state(HalC2.Auth, &put_in(&1.desktop.expires_at, now() + ms_left))

  # A P-256 key as a DPoP client holds it: `{public_jwk, private_key}`.
  defp dpop_key do
    {<<4, x::binary-32, y::binary-32>>, private} = :crypto.generate_key(:ecdh, :secp256r1)
    b64 = &Base.url_encode64(&1, padding: false)
    {%{"kty" => "EC", "crv" => "P-256", "x" => b64.(x), "y" => b64.(y)}, private}
  end

  defp dpop_proof({jwk, private}, method, url, access \\ nil) do
    b64 = &Base.url_encode64(&1, padding: false)
    header = b64.(JSON.encode!(%{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk}))

    claims =
      %{
        "htm" => method,
        "htu" => url,
        "jti" => Base.encode16(:crypto.strong_rand_bytes(8)),
        "iat" => System.os_time(:second)
      }
      |> then(&if(access, do: Map.put(&1, "ath", HalC2.Auth.Dpop.ath(access)), else: &1))

    input = header <> "." <> b64.(JSON.encode!(claims))
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64.(<<r::256, s::256>>)
  end

  defp url(context, path), do: "http://127.0.0.1:#{context.node.port}#{path}"

  # Runs a mix task and returns what it printed.
  defp mix_output(task, args) do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      task.run(args)
    after
      Mix.shell(shell)
    end

    collect_output([])
  end

  defp collect_output(lines) do
    receive do
      {:mix_shell, :info, [line]} -> collect_output([line | lines])
    after
      0 -> Enum.reverse(lines)
    end
  end

  defp access_request(context, action, access) do
    opts = if access, do: [bearer: access], else: []

    case action do
      "create a pairing link" ->
        Node.request(context.node, :post, "/api/auth/pairing-token", [json: %{}] ++ opts)

      "list pairing links" ->
        Node.request(context.node, :get, "/api/auth/pairing-links", opts)

      "revoke a pairing link" ->
        Node.request(
          context.node,
          :post,
          "/api/auth/pairing-links/revoke",
          [json: %{"id" => "pairing-0"}] ++ opts
        )

      "list authorized clients" ->
        Node.request(context.node, :get, "/api/auth/clients", opts)

      "revoke a client" ->
        Node.request(
          context.node,
          :post,
          "/api/auth/clients/revoke",
          [json: %{"sessionId" => "session-0"}] ++ opts
        )

      "revoke every other client" ->
        Node.request(context.node, :post, "/api/auth/clients/revoke-others", [json: %{}] ++ opts)
    end
  end

  # --- pairing -------------------------------------------------------------------

  step "a pairing token minted on the node", context do
    Map.put(context, :token, HalC2.Auth.create_pairing_token(context.node.store))
  end

  step "a pairing token that a client already exchanged", context do
    token = HalC2.Auth.create_pairing_token(context.node.store)
    pair!(context, token)
    Map.put(context, :token, token)
  end

  step "a pairing token minted six minutes ago", context do
    token = HalC2.Auth.create_pairing_token(context.node.store)
    six_minutes_ago = now() - :timer.minutes(6)

    sql(
      context,
      "UPDATE auth_pairing SET created_at = ?1, expires_at = ?2 WHERE token_hash = ?3",
      [
        six_minutes_ago,
        six_minutes_ago + :timer.minutes(5),
        sha(token)
      ]
    )

    Map.put(context, :token, token)
  end

  step "a client exchanges it with its label, device type and OS", context do
    grant =
      Node.exchange(context.node, context.token, %{
        "client_label" => "Work laptop",
        "client_device_type" => "desktop",
        "client_os" => "macOS"
      })

    Map.put(context, :grant, grant)
  end

  step ~r/^(?:a client|another client|the desktop app) exchanges (?:it|that token)$/, context do
    Map.put(context, :grant, Node.exchange(context.node, context.token))
  end

  step "the client receives a bearer access token that lasts 30 days", context do
    assert {200, grant} = context.grant
    assert %{"token_type" => "Bearer", "access_token" => access} = grant
    assert grant["expires_in"] == 30 * 24 * 60 * 60
    # The label, device type and OS are recorded on the session.
    id = session_id(access)
    client = Enum.find(HalC2.Auth.clients(), &(&1["sessionId"] == id))

    assert %{"label" => "Work laptop", "deviceType" => "desktop", "os" => "macOS"} =
             client["client"]

    Map.put(context, :access, access)
  end

  step "the grant lists the scopes it carries", context do
    assert {200, %{"scope" => scope}} = context.grant
    assert String.split(scope) == @standard
    {:ok, session} = HalC2.Auth.session(context.access)
    assert session.scopes == @standard
    context
  end

  step "the exchange fails as an invalid grant", context do
    assert {400, %{"error" => "invalid_grant"}} = context.grant
    context
  end

  step "the node is running", context do
    assert {200, _, %{"authenticated" => false}} =
             Node.request(context.node, :get, "/api/auth/session")

    context
  end

  step "an operator mints a pairing link from the command line", context do
    base = url(context, "")
    assert [link] = mix_output(Mix.Tasks.HalC2.Pair, [base])
    Map.merge(context, %{link: link, base: base})
  end

  step "it prints a link with a one-time token for standard scopes", context do
    assert String.starts_with?(context.link, context.base <> "/?token=")
    %{"token" => token} = context.link |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    # Listed like any pairing link: standard scopes, expiring in five minutes.
    assert [%{"scopes" => @standard, "expiresAt" => expires}] = HalC2.Auth.pairing_links()
    {:ok, expires, _} = DateTime.from_iso8601(expires)
    left = DateTime.diff(expires, DateTime.utc_now(), :second)
    assert left in 290..300
    Map.put(context, :token, token)
  end

  step "the running node accepts it", context do
    assert {200, %{"scope" => scope}} = Node.exchange(context.node, context.token)
    assert String.split(scope) == @standard
    assert {400, %{"error" => "invalid_grant"}} = Node.exchange(context.node, context.token)
    context
  end

  step ~r/^a client pairs with (?<credential>a command-line pairing token|the desktop bootstrap token|a pairing link naming scopes)$/,
       %{args: [credential]} = context do
    {context, token} =
      case credential do
        "a command-line pairing token" ->
          {context, HalC2.Auth.create_pairing_token(context.node.store)}

        "the desktop bootstrap token" ->
          {desktop_boot(context, "desktop-bootstrap-token"), "desktop-bootstrap-token"}

        "a pairing link naming scopes" ->
          {:ok, link} =
            HalC2.Auth.create_pairing_link(%{
              "scopes" => ["orchestration:read", "relay:write", "files:everything"]
            })

          {context, link["credential"]}
      end

    Map.put(context, :access, pair!(context, token))
  end

  step ~r/^its session carries (?<scopes>.+)$/, %{args: [scopes]} = context do
    expected =
      case scopes do
        "the standard scopes plus access:read, access:write and relay:write" -> @admin
        "only the named scopes the node knows" -> ["orchestration:read", "relay:write"]
        "only " <> scope -> [scope]
        list -> String.split(list, ", ")
      end

    assert {200, _, %{"authenticated" => true, "scopes" => ^expected}} =
             Node.request(context.node, :get, "/api/auth/session", bearer: context.access)

    context
  end

  # --- the desktop bootstrap token -------------------------------------------------

  step "the desktop app started the node with a bootstrap token", context do
    context = desktop_boot(context, "desktop-token")
    Map.merge(context, %{token: "desktop-token", access: pair!(context, "desktop-token")})
  end

  step "its window exchanges the token again an hour later", context do
    desktop_expires_in(:timer.hours(23))
    Map.put(context, :grant, Node.exchange(context.node, context.token))
  end

  step "it receives another administrative session", context do
    assert {200, %{"access_token" => access, "scope" => scope}} = context.grant
    assert access != context.access
    assert String.split(scope) == @admin
    assert {:ok, %{scopes: @admin}} = HalC2.Auth.session(access)
    context
  end

  step "the node booted more than 24 hours ago with a bootstrap token", context do
    context = desktop_boot(context, "desktop-token")
    desktop_expires_in(-1)
    Map.put(context, :token, "desktop-token")
  end

  step "the desktop app exchanged its bootstrap token before a restart", context do
    context = desktop_boot(context, "desktop-token-1")
    access = pair!(context, "desktop-token-1")
    assert {:ok, _} = HalC2.Auth.session(access)
    Map.put(context, :earlier, access)
  end

  step "it exchanges the new token after the restart", context do
    context = desktop_boot(context, "desktop-token-2")
    Map.put(context, :access, pair!(context, "desktop-token-2"))
  end

  step "the earlier desktop session is revoked in the same step", context do
    assert HalC2.Auth.session(context.earlier) == :error
    assert {:ok, %{scopes: @admin}} = HalC2.Auth.session(context.access)
    assert [_one] = Enum.filter(HalC2.Auth.clients(), &("access:write" in &1["scopes"]))
    context
  end

  # --- sessions and tickets ------------------------------------------------------

  step "a client with a valid session", context do
    Map.put(context, :access, standard!(context))
  end

  step "it asks for a socket ticket", context do
    response =
      Node.request(context.node, :post, "/api/auth/websocket-ticket", bearer: context.access)

    Map.put(context, :response, response)
  end

  step "it receives a ticket valid for five minutes", context do
    assert {200, _, %{"ticket" => ticket, "expiresAt" => expires}} = context.response
    {:ok, expires, _} = DateTime.from_iso8601(expires)
    assert DateTime.diff(expires, DateTime.utc_now(), :second) in 295..300
    Map.put(context, :ticket, ticket)
  end

  step "the long-lived token never appears in the socket URL", context do
    assert context.ticket != context.access
    client = Node.connect(context.node, "wsTicket=#{context.ticket}")
    # The ticket works once, and the access token is no ticket.
    assert {:error, 401} =
             Node.ws_client().connect(context.node.port, "/ws?wsTicket=#{context.ticket}")

    assert {:error, 401} =
             Node.ws_client().connect(context.node.port, "/ws?wsTicket=#{context.access}")

    World.put_client(context, "ticketed", client)
  end

  # --- the node's access token on HTTP ---------------------------------------------

  step "a local tool that read the node's access token", context do
    Map.put(context, :access, File.read!(Path.join(HalC2.Paths.data_dir(), "access-token")))
  end

  step "it asks the node about its session with that token as a bearer", context do
    Map.put(
      context,
      :response,
      Node.request(context.node, :get, "/api/auth/session", bearer: context.access)
    )
  end

  step "the node says it is authenticated with the administrative scopes", context do
    assert {200, _, %{"authenticated" => true, "scopes" => @admin} = body} = context.response
    assert body["sessionMethod"] == "bearer-access-token"
    context
  end

  step "the tool can buy a socket ticket with that token", context do
    assert {200, _, %{"ticket" => ticket}} =
             Node.request(context.node, :post, "/api/auth/websocket-ticket",
               bearer: context.access
             )

    Map.put(context, :ticket, ticket)
  end

  step "a socket opened with that ticket may do anything the node's own token may", context do
    assert {:ok, @admin} = HalC2.Auth.ticket_scopes(context.ticket)
    client = Node.connect(context.node, "wsTicket=#{context.ticket}")
    # The node's own token may watch the access list, which needs access:read.
    client = Node.sub(client, 1, %{"type" => "authAccess"})
    assert {%{"t" => "authAccess", "id" => 1}, client} = Node.await(client, &(&1["id"] == 1))
    World.put_client(context, "local", client)
  end

  step "a local tool bought a socket ticket with the node's access token", context do
    access = File.read!(Path.join(HalC2.Paths.data_dir(), "access-token"))

    assert {200, _, %{"ticket" => ticket}} =
             Node.request(context.node, :post, "/api/auth/websocket-ticket", bearer: access)

    World.put_client(context, "local", Node.connect(context.node, "wsTicket=#{ticket}"))
  end

  step "an administrator lists the authorized clients", context do
    Map.put(
      context,
      :response,
      access_request(context, "list authorized clients", admin!(context))
    )
  end

  step "the node's access token is not among them", context do
    # Only the administrator who asked is listed.
    assert {200, _, [%{"current" => true} = admin]} = context.response
    assert admin["sessionId"] != nil
    context
  end

  step "a client asks for a socket ticket with an unknown bearer token", context do
    response =
      Node.request(context.node, :post, "/api/auth/websocket-ticket", bearer: "not-a-session")

    Map.put(context, :response, response)
  end

  step "it asks the node about its session", context do
    Map.put(
      context,
      :response,
      Node.request(context.node, :get, "/api/auth/session", bearer: context.access)
    )
  end

  step "the node says it is authenticated with its scopes and expiry", context do
    assert {200, _, %{"authenticated" => true, "scopes" => @standard} = body} = context.response
    assert body["sessionMethod"] == "bearer-access-token"
    {:ok, expires, _} = DateTime.from_iso8601(body["expiresAt"])
    assert DateTime.diff(expires, DateTime.utc_now(), :day) in 29..30
    context
  end

  step "without a credential the node says it is not authenticated", context do
    assert {200, _, %{"authenticated" => false} = body} =
             Node.request(context.node, :get, "/api/auth/session")

    refute Map.has_key?(body, "scopes")
    context
  end

  step "a session that expired", context do
    access = standard!(context)

    sql(context, "UPDATE auth_sessions SET expires_at = ?1 WHERE token_hash = ?2", [
      now() - 1,
      sha(access)
    ])

    Map.put(context, :access, access)
  end

  step "the client asks for a socket ticket with it", context do
    response =
      Node.request(context.node, :post, "/api/auth/websocket-ticket", bearer: context.access)

    Map.put(context, :response, response)
  end

  step "the client's session still works", context do
    assert {200, _, %{"ticket" => ticket}} =
             Node.request(context.node, :post, "/api/auth/websocket-ticket",
               bearer: context.access_token
             )

    client = Node.connect(context.node, "wsTicket=#{ticket}")
    World.put_client(context, "restarted", client)
  end

  # --- access management ---------------------------------------------------------

  step ~r/^a client whose session lacks (?<scope>\S+)$/, %{args: [scope]} = context do
    access = standard!(context)
    {:ok, session} = HalC2.Auth.session(access)
    refute scope in session.scopes
    Map.put(context, :access, access)
  end

  step ~r/^it tries to (?<action>write to a terminal|create a pairing link|list pairing links|revoke a pairing link|list authorized clients|revoke a client|revoke every other client)$/,
       %{args: [action]} = context do
    case action do
      "write to a terminal" ->
        {reply, client} =
          Node.call(
            World.client(context, "device"),
            context.node.environment,
            "terminal.write",
            %{
              "threadId" => "thread-1",
              "terminalId" => "default",
              "data" => "ls\n"
            }
          )

        context |> World.put_client("device", client) |> Map.put(:refusal, reply)

      _ ->
        Map.put(context, :response, access_request(context, action, context.access))
    end
  end

  step ~r/^the node refuses saying (?<scope>\S+) is required$/, %{args: [scope]} = context do
    case context do
      %{refusal: refusal} ->
        assert {:error, _,
                %{"_tag" => "EnvironmentScopeRequiredError", "requiredScope" => ^scope}} =
                 refusal

      _ ->
        assert {403, _,
                %{
                  "_tag" => "EnvironmentScopeRequiredError",
                  "code" => "insufficient_scope",
                  "requiredScope" => ^scope
                }} = context.response
    end

    context
  end

  step "a client calls an access route without a bearer token", context do
    Map.put(context, :response, access_request(context, "list authorized clients", nil))
  end

  step "the node answers that a credential is missing", context do
    assert {401, _,
            %{
              "_tag" => "EnvironmentAuthInvalidError",
              "code" => "auth_invalid",
              "reason" => "missing_credential"
            }} = context.response

    context
  end

  step "an administrator sends an access request with an invalid body", context do
    response =
      Node.request(context.node, :post, "/api/auth/clients/revoke",
        bearer: admin!(context),
        body: "{not json"
      )

    Map.put(context, :response, response)
  end

  step "the node answers that the request is invalid", context do
    assert {400, _, %{"_tag" => "EnvironmentRequestInvalidError"}} = context.response
    context
  end

  step "an administrator follows the node's access list", context do
    access = admin!(context)
    client = socket!(context, access)
    client = Node.sub(client, 40, %{"type" => "authAccess"})

    {snapshot, client} =
      Node.await(client, &(&1["t"] == "authAccess" and &1["event"]["type"] == "snapshot"))

    context
    |> World.put_client("admin", client)
    |> Map.merge(%{admin: access, snapshot: snapshot["event"]["payload"]})
  end

  step "a pairing link is created and then revoked", context do
    assert {200, _, %{"id" => id, "credential" => credential}} =
             Node.request(context.node, :post, "/api/auth/pairing-token",
               bearer: context.admin,
               json: %{"label" => "Tablet"}
             )

    assert {200, _, %{"revoked" => true}} =
             Node.request(context.node, :post, "/api/auth/pairing-links/revoke",
               bearer: context.admin,
               json: %{"id" => id}
             )

    Map.merge(context, %{link_id: id, token: credential})
  end

  step "another device pairs", context do
    access = standard!(context)
    Map.put(context, :device, session_id(access))
  end

  step "each change arrives as it happens", context do
    client = World.client(context, "admin")
    link = context.link_id
    device = context.device

    event = fn type, match ->
      &(&1["t"] == "authAccess" and &1["event"]["type"] == type and match.(&1["event"]["payload"]))
    end

    {up, client} = Node.await(client, event.("pairingLinkUpserted", &(&1["id"] == link)))
    {down, client} = Node.await(client, event.("pairingLinkRemoved", &(&1["id"] == link)))
    {paired, client} = Node.await(client, event.("clientUpserted", &(&1["sessionId"] == device)))
    revisions = for frame <- [up, down, paired], do: frame["event"]["revision"]
    assert revisions == Enum.sort(revisions)
    assert up["event"]["payload"]["label"] == "Tablet"
    World.put_client(context, "admin", client)
  end

  step "the revoked link no longer pairs", context do
    assert {400, %{"error" => "invalid_grant"}} = Node.exchange(context.node, context.token)
    context
  end

  step "a device paired with standard scopes", context do
    access = standard!(context)
    World.put_client(context, "device", socket!(context, access))
  end

  step "it asks to follow the access list", context do
    client = Node.sub(World.client(context, "device"), 41, %{"type" => "authAccess"})
    World.put_client(context, "device", client)
  end

  step "only that subscription fails saying access:read is required", context do
    {frame, client} =
      Node.await(World.client(context, "device"), &(&1["t"] == "error" and &1["id"] == 41))

    assert frame["reason"] == "access:read is required"
    World.put_client(context, "device", client)
  end

  step "the rest of its socket keeps working", context do
    client = Node.config(World.client(context, "device"), 42)
    client = Node.ws_client().send_json(client, %{"t" => "ping"})
    {_, client} = Node.await(client, &(&1["t"] == "pong"))
    World.put_client(context, "device", client)
  end

  step "the administrator's own session is marked as current", context do
    own = session_id(context.admin)
    sessions = context.snapshot["clientSessions"]
    assert [%{"sessionId" => ^own}] = Enum.filter(sessions, & &1["current"])
    context
  end

  step "a paired device opens a socket", context do
    access = standard!(context)

    context
    |> World.put_client("device", socket!(context, access))
    |> Map.put(:device, session_id(access))
  end

  step "that client shows as connected with its last connection time", context do
    device = context.device

    {frame, client} =
      Node.await(
        World.client(context, "admin"),
        &(&1["t"] == "authAccess" and &1["event"]["type"] == "clientUpserted" and
            &1["event"]["payload"]["sessionId"] == device and &1["event"]["payload"]["connected"])
      )

    {:ok, last, _} = DateTime.from_iso8601(frame["event"]["payload"]["lastConnectedAt"])
    assert DateTime.diff(DateTime.utc_now(), last, :second) in 0..5
    refute frame["event"]["payload"]["current"]
    World.put_client(context, "admin", client)
  end

  step "a phone, a tablet and a desktop browser each pair", context do
    agents = %{
      "Phone" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile/15E148",
      "Tablet" => "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) Safari/604.1",
      "Desktop" => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36"
    }

    for {label, agent} <- agents do
      form = %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token" => HalC2.Auth.create_pairing_token(context.node.store),
        "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
        "client_label" => label
      }

      assert {200, _, _} =
               Node.request(context.node, :post, "/oauth/token",
                 form: form,
                 headers: [{"user-agent", agent}]
               )
    end

    context
  end

  step "the node records each as mobile, tablet and desktop", context do
    types = Map.new(HalC2.Auth.clients(), &{&1["client"]["label"], &1["client"]["deviceType"]})
    assert types == %{"Phone" => "mobile", "Tablet" => "tablet", "Desktop" => "desktop"}
    context
  end

  step "an administrator created a pairing link", context do
    admin = admin!(context)

    assert {200, _, link} =
             Node.request(context.node, :post, "/api/auth/pairing-token",
               bearer: admin,
               json: %{"label" => "Kitchen tablet", "scopes" => ["orchestration:read"]}
             )

    Map.merge(context, %{admin: admin, link: link})
  end

  step "anyone lists pairing links", context do
    Map.put(
      context,
      :response,
      Node.request(context.node, :get, "/api/auth/pairing-links", bearer: context.admin)
    )
  end

  step "the link is listed with its label, scopes and expiry", context do
    assert {200, _, links} = context.response
    id = context.link["id"]
    assert [listed] = Enum.filter(links, &(&1["id"] == id))

    assert %{
             "label" => "Kitchen tablet",
             "scopes" => ["orchestration:read"],
             "expiresAt" => expires
           } =
             listed

    assert expires == context.link["expiresAt"]
    context
  end

  step "its credential is not in the listing", context do
    assert {200, _, links} = context.response
    refute JSON.encode!(links) =~ context.link["credential"]
    assert Enum.all?(links, &(not Map.has_key?(&1, "credential")))
    context
  end

  step "an administrator revokes their own current session", context do
    admin = admin!(context)

    response =
      Node.request(context.node, :post, "/api/auth/clients/revoke",
        bearer: admin,
        json: %{"sessionId" => session_id(admin)}
      )

    Map.merge(context, %{admin: admin, response: response})
  end

  step "the node refuses because the current session cannot be revoked", context do
    assert {403, _,
            %{
              "_tag" => "EnvironmentOperationForbiddenError",
              "reason" => "current_session_revoke_not_allowed"
            }} = context.response

    assert {:ok, _} = HalC2.Auth.session(context.admin)
    context
  end

  step "three paired clients", context do
    Map.merge(context, %{admin: admin!(context), others: [standard!(context), standard!(context)]})
  end

  step "an administrator revokes every other client", context do
    response =
      Node.request(context.node, :post, "/api/auth/clients/revoke-others", bearer: context.admin)

    Map.put(context, :response, response)
  end

  step "the other two sessions are revoked", context do
    for access <- context.others, do: assert(HalC2.Auth.session(access) == :error)
    assert {:ok, _} = HalC2.Auth.session(context.admin)
    context
  end

  step "the node reports how many it revoked", context do
    assert {200, _, %{"revokedCount" => 2}} = context.response
    context
  end

  # --- access over the socket ------------------------------------------------------

  step ~r/^it calls (?<method>hal-c2\.\w+) on the node$/, %{args: [method]} = context do
    {reply, context} = World.call(context, method, %{}, "device")
    Map.put(context, :refusal, reply)
  end

  step ~r/^only that call fails saying (?<scope>\S+) is required$/, %{args: [scope]} = context do
    assert {:error, "#{scope} is required",
            %{"_tag" => "EnvironmentScopeRequiredError", "requiredScope" => scope}} ==
             context.refusal

    context
  end

  step "an administrator's socket", context do
    access = admin!(context)

    context
    |> World.put_client("admin", socket!(context, access))
    |> Map.put(:admin, access)
  end

  step ~r/^it creates a pairing link labelled "(?<label>[^"]+)" through hal-c2.createPairingLink$/,
       %{args: [label]} = context do
    payload = %{"label" => label, "scopes" => ["orchestration:read"]}
    {link, context} = admin_call!(context, "hal-c2.createPairingLink", payload)
    assert %{"id" => _, "credential" => _, "label" => ^label, "expiresAt" => _} = link
    Map.merge(context, %{link: link, token: link["credential"]})
  end

  step "hal-c2.pairingLinks lists the link without its credential", context do
    {links, context} = admin_call!(context, "hal-c2.pairingLinks")
    id = context.link["id"]

    assert [%{"label" => "Tablet", "scopes" => ["orchestration:read"]}] =
             for(%{"id" => ^id} = l <- links, do: l)

    refute JSON.encode!(links) =~ context.link["credential"]
    context
  end

  step "it revokes the link through hal-c2.revokePairingLink", context do
    payload = %{"id" => context.link["id"]}

    assert {%{"revoked" => true}, context} =
             admin_call!(context, "hal-c2.revokePairingLink", payload)

    context
  end

  step "hal-c2.pairingLinks no longer lists it", context do
    {links, context} = admin_call!(context, "hal-c2.pairingLinks")
    refute Enum.any?(links, &(&1["id"] == context.link["id"]))
    context
  end

  step "two other paired clients", context do
    Map.put(context, :others, [standard!(context), standard!(context)])
  end

  step "hal-c2.clients marks the administrator's own session as current", context do
    {clients, context} = admin_call!(context, "hal-c2.clients")
    own = session_id(context.admin)
    assert [%{"sessionId" => ^own}] = Enum.filter(clients, & &1["current"])
    assert length(clients) == 3
    context
  end

  step "hal-c2.revokeClient refuses the administrator's own session", context do
    payload = %{"sessionId" => session_id(context.admin)}
    {reply, context} = World.call(context, "hal-c2.revokeClient", payload, "admin")

    assert {:error, _,
            %{
              "_tag" => "EnvironmentOperationForbiddenError",
              "reason" => "current_session_revoke_not_allowed"
            }} = reply

    assert {:ok, _} = HalC2.Auth.session(context.admin)
    context
  end

  step "it revokes one of the others through hal-c2.revokeClient", context do
    [first, _] = context.others
    payload = %{"sessionId" => session_id(first)}
    assert {%{"revoked" => true}, context} = admin_call!(context, "hal-c2.revokeClient", payload)
    assert HalC2.Auth.session(first) == :error
    context
  end

  step "it revokes every other client through hal-c2.revokeOtherClients", context do
    assert {%{"revokedCount" => 1}, context} = admin_call!(context, "hal-c2.revokeOtherClients")
    context
  end

  step "hal-c2.clients lists only the administrator's session", context do
    {clients, context} = admin_call!(context, "hal-c2.clients")
    own = session_id(context.admin)
    assert [%{"sessionId" => ^own, "current" => true}] = clients
    context
  end

  # A member as its environment reaches the shell; nothing answers there, so a call
  # that got past the node would fail as unavailable instead.
  step "another member of the node's cluster", context do
    member = %{"environmentId" => "env-member", "label" => "Member"}
    GenServer.cast(HalC2.Shell, {:peer_environment, :member@nowhere, member})
    :sys.get_state(HalC2.Shell)
    Map.put(context, :member, "env-member")
  end

  step ~r/^the administrator calls (?<method>hal-c2\.\w+) on that member$/,
       %{args: [method]} = context do
    [first, _] = context.others
    payload = %{"sessionId" => session_id(first)}
    client = World.client(context, "admin")
    {reply, client} = Node.call(client, context.member, method, payload)
    context |> World.put_client("admin", client) |> Map.put(:refusal, reply)
  end

  step "the call is refused because the caller's session lives on another node", context do
    assert {:error, _,
            %{
              "_tag" => "EnvironmentOperationForbiddenError",
              "reason" => "session_on_another_node"
            }} =
             context.refusal

    context
  end

  step "no client was revoked", context do
    assert length(HalC2.Auth.clients()) == 3

    for access <- [context.admin | context.others],
        do: assert({:ok, _} = HalC2.Auth.session(access))

    context
  end

  # --- older stores --------------------------------------------------------------

  step "a node store written before client metadata was recorded", context do
    ExUnit.Callbacks.stop_supervised(HalC2.Auth)
    sql(context, "DROP TABLE auth_pairing")
    sql(context, "DROP TABLE auth_sessions")

    sql(
      context,
      "CREATE TABLE auth_pairing (token_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL)"
    )

    sql(context, """
    CREATE TABLE auth_sessions (token_hash TEXT PRIMARY KEY, scopes TEXT NOT NULL, label TEXT,
      created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL)
    """)

    access = "an-access-token-from-an-older-node"

    sql(context, "INSERT INTO auth_pairing VALUES (?1, ?2)", [sha("old-pairing"), now() + 60_000])

    sql(context, "INSERT INTO auth_sessions VALUES (?1, ?2, 'Old laptop', ?3, ?4)", [
      sha(access),
      Enum.join(@standard, " "),
      now(),
      now() + :timer.hours(24)
    ])

    Map.put(context, :access, access)
  end

  step "its pairing and session records gain the missing fields", context do
    columns = fn table ->
      for [_, name | _] <- sql(context, "PRAGMA table_info(#{table})"), do: name
    end

    assert ~w(id label scopes created_at) -- columns.("auth_pairing") == []

    assert ~w(id last_connected_at device_type os user_agent subject proof_jkt) --
             columns.("auth_sessions") == []

    assert [["pairing-" <> _]] = sql(context, "SELECT id FROM auth_pairing")
    assert [["session-" <> _]] = sql(context, "SELECT id FROM auth_sessions")
    context
  end

  step "existing sessions keep working", context do
    client = socket!(context, context.access)
    assert [%{"client" => %{"label" => "Old laptop"}}] = HalC2.Auth.clients()
    World.put_client(context, "old", client)
  end

  # --- scopes on the socket --------------------------------------------------------

  step "a device paired without terminal:operate", context do
    {:ok, link} =
      HalC2.Auth.create_pairing_link(%{
        "scopes" => ["orchestration:read", "orchestration:operate"]
      })

    access = pair!(context, link["credential"])
    World.put_client(context, "device", socket!(context, access))
  end

  step "a paired client has an open socket", context do
    access = standard!(context)

    context
    |> World.put_client("device", socket!(context, access))
    |> Map.merge(%{access: access, device: session_id(access)})
  end

  step "an administrator revokes that client", context do
    assert {200, _, %{"revoked" => true}} =
             Node.request(context.node, :post, "/api/auth/clients/revoke",
               bearer: admin!(context),
               json: %{"sessionId" => context.device}
             )

    context
  end

  step "the client's socket is closed as revoked", context do
    assert {:close, 4401, "session revoked"} = Node.await_close(World.client(context, "device"))
    context
  end

  step "it cannot reconnect with its old session", context do
    assert {401, _, _} =
             Node.request(context.node, :post, "/api/auth/websocket-ticket",
               bearer: context.access
             )

    context
  end

  # --- narrowing, DPoP, the dev credential ---------------------------------------

  step "a pairing link with administrative scopes", context do
    {:ok, link} = HalC2.Auth.create_pairing_link(%{"scopes" => @admin})
    Map.put(context, :token, link["credential"])
  end

  step "a client exchanges it asking only for orchestration:read", context do
    assert {200, %{"scope" => "orchestration:read", "access_token" => access}} =
             Node.exchange(context.node, context.token, %{"scope" => "orchestration:read"})

    # Asking for a scope the credential does not grant is refused.
    assert {400, %{"error" => "invalid_scope"}} =
             Node.exchange(context.node, HalC2.Auth.create_pairing_token(context.node.store), %{
               "scope" => "access:write"
             })

    Map.put(context, :access, access)
  end

  step "a client that paired with a DPoP key", context do
    key = dpop_key()
    token = HalC2.Auth.create_pairing_token(context.node.store)
    proof = dpop_proof(key, "POST", url(context, "/oauth/token"))

    form = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
      "subject_token" => token,
      "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap"
    }

    assert {200, _, %{"token_type" => "DPoP", "access_token" => access, "expires_in" => 3600}} =
             Node.request(context.node, :post, "/oauth/token",
               form: form,
               headers: [{"dpop", proof}]
             )

    Map.merge(context, %{key: key, access: access})
  end

  step "it presents its access token with a proof", context do
    proof = dpop_proof(context.key, "GET", url(context, "/api/auth/session"), context.access)

    response =
      Node.request(context.node, :get, "/api/auth/session",
        headers: [{"authorization", "DPoP #{context.access}"}, {"dpop", proof}]
      )

    Map.put(context, :response, response)
  end

  step "the node accepts it", context do
    assert {200, _,
            %{
              "authenticated" => true,
              "sessionMethod" => "dpop-access-token",
              "scopes" => @standard
            }} =
             context.response

    context
  end

  step "a token presented with an invalid proof is refused rather than treated as a bearer",
       context do
    path = "/api/auth/websocket-ticket"
    # A proof signed by another key.
    forged = dpop_proof(dpop_key(), "POST", url(context, path), context.access)

    assert {401, _, %{"reason" => "invalid_credential", "dpopFailureReason" => "key_mismatch"}} =
             Node.request(context.node, :post, path,
               headers: [{"authorization", "DPoP #{context.access}"}, {"dpop", forged}]
             )

    # No proof at all, and the same token as a plain bearer.
    assert {401, _, _} =
             Node.request(context.node, :post, path,
               headers: [{"authorization", "DPoP #{context.access}"}]
             )

    assert {401, _, _} = Node.request(context.node, :post, path, bearer: context.access)
    # A proof is good once.
    proof = dpop_proof(context.key, "POST", url(context, path), context.access)
    headers = [{"authorization", "DPoP #{context.access}"}, {"dpop", proof}]
    assert {200, _, %{"ticket" => _}} = Node.request(context.node, :post, path, headers: headers)

    assert {401, _, %{"dpopFailureReason" => "replay"}} =
             Node.request(context.node, :post, path, headers: headers)

    context
  end

  step "a fixed development auth token is configured", context do
    token = "reusable-dev-auth-token-that-is-long-enough"
    Application.put_env(:hal_c2, :dev_auth_token, token)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :dev_auth_token) end)

    %{context | node: Node.restart(context.node), clients: %{}}
    |> Map.put(:token, token)
  end

  step "a browser presents it to a development node", context do
    Map.put(context, :grant, Node.exchange(context.node, context.token))
  end

  step "the node grants an administrative session", context do
    assert {200, %{"access_token" => access, "scope" => scope}} = context.grant
    assert String.split(scope) == @admin
    # The credential is itself a session, usable as a bearer.
    assert {200, _, %{"authenticated" => true, "scopes" => @admin}} =
             Node.request(context.node, :get, "/api/auth/session", bearer: context.token)

    Map.put(context, :access, access)
  end

  step "revoking it locally does not affect another worktree", context do
    dev = "dev-auth-" <> sha(context.token)

    assert {200, _, %{"revoked" => true}} =
             Node.request(context.node, :post, "/api/auth/clients/revoke",
               bearer: context.access,
               json: %{"sessionId" => dev}
             )

    assert {400, %{"error" => "invalid_grant"}} = Node.exchange(context.node, context.token)

    # Another worktree's node, with its own store and the same credential.
    other = Node.restart(%{context.node | home: Node.tmp_dir(context.node, "worktree")})
    assert {200, %{"scope" => scope}} = Node.exchange(other, context.token)
    assert String.split(scope) == @admin
    %{context | node: other, clients: %{}}
  end

  # --- the command line ------------------------------------------------------------

  step "an operator lists sessions from the node's command line", context do
    Map.put(context, :listed, mix_output(Mix.Tasks.HalC2.Auth, ["session", "list"]))
  end

  step "it sees the same clients as Connections settings", context do
    assert {200, _, clients} =
             Node.request(context.node, :get, "/api/auth/clients", bearer: context.admin)

    listed = for line <- context.listed, do: line |> String.split("\t") |> hd()
    assert Enum.sort(listed) == Enum.sort(for c <- clients, do: c["sessionId"])
    assert length(listed) == 3
    context
  end

  step "it can revoke one of them", context do
    [other | _] = context.others
    id = session_id(other)
    assert ["Revoked " <> _] = mix_output(Mix.Tasks.HalC2.Auth, ["session", "revoke", id])

    assert {401, _, _} =
             Node.request(context.node, :post, "/api/auth/websocket-ticket", bearer: other)

    listed = mix_output(Mix.Tasks.HalC2.Auth, ["session", "list"])
    refute Enum.any?(listed, &String.starts_with?(&1, id))
    context
  end
end
