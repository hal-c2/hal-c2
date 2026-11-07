defmodule HalC2.Steps.Platform.AuthAndScopes do
  @moduledoc "Steps for features/mc/platform/auth-and-scopes.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @standard ~w(orchestration:read orchestration:operate terminal:operate review:write relay:read)
  @admin @standard ++ ~w(access:read access:write relay:write)

  # --- helpers -------------------------------------------------------------------

  # Runs SQL against the MC's store, as an older MC or the clock would have left it.
  defp sql(context, statement, args \\ []) do
    {:ok, db} = Exqlite.Sqlite3.open(context.mc.store)

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
    assert {200, %{"access_token" => access}} = Mc.exchange(context.mc, token, fields)
    access
  end

  defp standard!(context), do: pair!(context, HalC2.Auth.create_pairing_token(context.mc.store))

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
             Mc.request(context.mc, :post, "/api/auth/websocket-ticket", bearer: access)

    Mc.connect(context.mc, "wsTicket=#{ticket}")
  end

  # Starts the MC again with the desktop app's bootstrap token (as `HalC2.Desktop` sets it).
  defp desktop_boot(context, token) do
    Application.put_env(:hal_c2, :desktop_token, token)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :desktop_token) end)
    %{context | mc: Mc.restart(context.mc), clients: %{}}
  end

  # Moves the MC's boot time so its desktop token expires `ms_left` from now.
  defp desktop_expires_in(ms_left),
    do: :sys.replace_state(HalC2.Auth, &put_in(&1.desktop.expires_at, now() + ms_left))

  # A P-256 key as a DPoP client holds it: `{public_jwk, private_key}`.
  defp dpop_key do
    {<<4, x::binary-32, y::binary-32>>, private} = :crypto.generate_key(:ecdh, :secp256r1)
    b64 = &Base.url_encode64(&1, padding: false)
    {%{"kty" => "EC", "crv" => "P-256", "x" => b64.(x), "y" => b64.(y)}, private}
  end

  defp dpop_proof({jwk, private}, method, url, access \\ nil, iat \\ nil) do
    b64 = &Base.url_encode64(&1, padding: false)
    header = b64.(JSON.encode!(%{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk}))

    claims =
      %{
        "htm" => method,
        "htu" => url,
        "jti" => Base.encode16(:crypto.strong_rand_bytes(8)),
        "iat" => iat || System.os_time(:second)
      }
      |> then(&if(access, do: Map.put(&1, "ath", HalC2.Auth.Dpop.ath(access)), else: &1))

    input = header <> "." <> b64.(JSON.encode!(claims))
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64.(<<r::256, s::256>>)
  end

  defp url(context, path), do: "http://127.0.0.1:#{context.mc.port}#{path}"

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
        Mc.request(context.mc, :post, "/api/auth/pairing-token", [json: %{}] ++ opts)

      "list pairing links" ->
        Mc.request(context.mc, :get, "/api/auth/pairing-links", opts)

      "revoke a pairing link" ->
        Mc.request(
          context.mc,
          :post,
          "/api/auth/pairing-links/revoke",
          [json: %{"id" => "pairing-0"}] ++ opts
        )

      "list authorized clients" ->
        Mc.request(context.mc, :get, "/api/auth/clients", opts)

      "revoke a client" ->
        Mc.request(
          context.mc,
          :post,
          "/api/auth/clients/revoke",
          [json: %{"sessionId" => "session-0"}] ++ opts
        )

      "revoke every other client" ->
        Mc.request(context.mc, :post, "/api/auth/clients/revoke-others", [json: %{}] ++ opts)
    end
  end

  # --- pairing -------------------------------------------------------------------

  step "a pairing token minted on the MC", context do
    Map.put(context, :token, HalC2.Auth.create_pairing_token(context.mc.store))
  end

  step "a pairing token that a client already exchanged", context do
    token = HalC2.Auth.create_pairing_token(context.mc.store)
    pair!(context, token)
    Map.put(context, :token, token)
  end

  step "a pairing token minted six minutes ago", context do
    token = HalC2.Auth.create_pairing_token(context.mc.store)
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
      Mc.exchange(context.mc, context.token, %{
        "client_label" => "Work laptop",
        "client_device_type" => "desktop",
        "client_os" => "macOS"
      })

    Map.put(context, :grant, grant)
  end

  step ~r/^(?:a client|another client|the desktop app) exchanges (?:it|that token)$/, context do
    Map.put(context, :grant, Mc.exchange(context.mc, context.token))
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

  step "the MC is running", context do
    assert {200, _, %{"authenticated" => false}} =
             Mc.request(context.mc, :get, "/api/auth/session")

    context
  end

  step "an operator mints a pairing link from the command line", context do
    base = url(context, "")
    assert [link, _expires] = printed = mix_output(Mix.Tasks.HalC2.Pair, [base])
    Map.merge(context, %{link: link, base: base, printed: printed})
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

  step "the running MC accepts it", context do
    assert {200, %{"scope" => scope}} = Mc.exchange(context.mc, context.token)
    assert String.split(scope) == @standard
    assert {400, %{"error" => "invalid_grant"}} = Mc.exchange(context.mc, context.token)
    context
  end

  step ~r/^a client pairs with (?<credential>a command-line pairing token|the desktop bootstrap token|a pairing link naming scopes)$/,
       %{args: [credential]} = context do
    {context, token} =
      case credential do
        "a command-line pairing token" ->
          {context, HalC2.Auth.create_pairing_token(context.mc.store)}

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
        "only the named scopes the MC knows" -> ["orchestration:read", "relay:write"]
        "only " <> scope -> [scope]
        list -> String.split(list, ", ")
      end

    assert {200, _, %{"authenticated" => true, "scopes" => ^expected}} =
             Mc.request(context.mc, :get, "/api/auth/session", bearer: context.access)

    context
  end

  # --- the desktop bootstrap token -------------------------------------------------

  step "the desktop app started the MC with a bootstrap token", context do
    context = desktop_boot(context, "desktop-token")
    Map.merge(context, %{token: "desktop-token", access: pair!(context, "desktop-token")})
  end

  step "its window exchanges the token again an hour later", context do
    desktop_expires_in(:timer.hours(23))
    Map.put(context, :grant, Mc.exchange(context.mc, context.token))
  end

  step "it receives another administrative session", context do
    assert {200, %{"access_token" => access, "scope" => scope}} = context.grant
    assert access != context.access
    assert String.split(scope) == @admin
    assert {:ok, %{scopes: @admin}} = HalC2.Auth.session(access)
    context
  end

  step "the MC booted more than 24 hours ago with a bootstrap token", context do
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
      Mc.request(context.mc, :post, "/api/auth/websocket-ticket", bearer: context.access)

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
    client = Mc.connect(context.mc, "wsTicket=#{context.ticket}")
    # The ticket works once, and the access token is no ticket.
    assert {:error, 401} =
             Mc.ws_client().connect(context.mc.port, "/ws?wsTicket=#{context.ticket}")

    assert {:error, 401} =
             Mc.ws_client().connect(context.mc.port, "/ws?wsTicket=#{context.access}")

    World.put_client(context, "ticketed", client)
  end

  # --- the MC's access token on HTTP ---------------------------------------------

  step "a local tool that read the MC's access token", context do
    Map.put(context, :access, File.read!(Path.join(HalC2.Paths.data_dir(), "access-token")))
  end

  step "it asks the MC about its session with that token as a bearer", context do
    Map.put(
      context,
      :response,
      Mc.request(context.mc, :get, "/api/auth/session", bearer: context.access)
    )
  end

  step "the MC says it is authenticated with the administrative scopes", context do
    assert {200, _, %{"authenticated" => true, "scopes" => @admin} = body} = context.response
    assert body["sessionMethod"] == "bearer-access-token"
    context
  end

  step "the tool can buy a socket ticket with that token", context do
    assert {200, _, %{"ticket" => ticket}} =
             Mc.request(context.mc, :post, "/api/auth/websocket-ticket", bearer: context.access)

    Map.put(context, :ticket, ticket)
  end

  step "a socket opened with that ticket may do anything the MC's own token may", context do
    assert {:ok, @admin} = HalC2.Auth.ticket_scopes(context.ticket)
    client = Mc.connect(context.mc, "wsTicket=#{context.ticket}")
    # The MC's own token may watch the access list, which needs access:read.
    client = Mc.sub(client, 1, %{"type" => "authAccess"})
    assert {%{"t" => "authAccess", "id" => 1}, client} = Mc.await(client, &(&1["id"] == 1))
    World.put_client(context, "local", client)
  end

  step "a local tool bought a socket ticket with the MC's access token", context do
    access = File.read!(Path.join(HalC2.Paths.data_dir(), "access-token"))

    assert {200, _, %{"ticket" => ticket}} =
             Mc.request(context.mc, :post, "/api/auth/websocket-ticket", bearer: access)

    World.put_client(context, "local", Mc.connect(context.mc, "wsTicket=#{ticket}"))
  end

  step "an administrator lists the authorized clients", context do
    Map.put(
      context,
      :response,
      access_request(context, "list authorized clients", context[:admin] || admin!(context))
    )
  end

  step "the MC's access token is not among them", context do
    # Only the administrator who asked is listed.
    assert {200, _, [%{"current" => true} = admin]} = context.response
    assert admin["sessionId"] != nil
    context
  end

  step "a client asks for a socket ticket with an unknown bearer token", context do
    response =
      Mc.request(context.mc, :post, "/api/auth/websocket-ticket", bearer: "not-a-session")

    Map.put(context, :response, response)
  end

  step "it asks the MC about its session", context do
    Map.put(
      context,
      :response,
      Mc.request(context.mc, :get, "/api/auth/session", bearer: context.access)
    )
  end

  step "the MC says it is authenticated with its scopes and expiry", context do
    assert {200, _, %{"authenticated" => true, "scopes" => @standard} = body} = context.response
    assert body["sessionMethod"] == "bearer-access-token"
    {:ok, expires, _} = DateTime.from_iso8601(body["expiresAt"])
    assert DateTime.diff(expires, DateTime.utc_now(), :day) in 29..30
    context
  end

  step "without a credential the MC says it is not authenticated", context do
    assert {200, _, %{"authenticated" => false} = body} =
             Mc.request(context.mc, :get, "/api/auth/session")

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
      Mc.request(context.mc, :post, "/api/auth/websocket-ticket", bearer: context.access)

    Map.put(context, :response, response)
  end

  step "the client's session still works", context do
    assert {200, _, %{"ticket" => ticket}} =
             Mc.request(context.mc, :post, "/api/auth/websocket-ticket",
               bearer: context.access_token
             )

    client = Mc.connect(context.mc, "wsTicket=#{ticket}")
    World.put_client(context, "restarted", client)
  end

  # --- renewing a session --------------------------------------------------------

  defp expires_in(context, access, ms) do
    sql(context, "UPDATE auth_sessions SET expires_at = ?1 WHERE token_hash = ?2", [
      now() + ms,
      sha(access)
    ])
  end

  step "a client whose session runs out in a day, with a socket open", context do
    access = standard!(context)
    expires_in(context, access, :timer.hours(24))
    admin = socket!(context, admin!(context))
    admin = Mc.sub(admin, 42, %{"type" => "authAccess"})

    {_, admin} =
      Mc.await(admin, &(&1["t"] == "authAccess" and &1["event"]["type"] == "snapshot"))

    context
    |> World.put_client(socket!(context, access))
    |> World.put_client("admin", admin)
    |> Map.put(:access, access)
  end

  step "a client whose session runs out in a year", context do
    access = standard!(context)
    expires_in(context, access, :timer.hours(24 * 365))
    Map.put(context, :access, access)
  end

  step "it renews its session", context do
    response =
      Mc.request(context.mc, :post, "/api/auth/session/renew", bearer: context.access)

    Map.put(context, :response, response)
  end

  step "its session is valid for 30 days from now, with the same token", context do
    assert {200, _, %{"expiresAt" => expires}} = context.response
    {:ok, expires, _} = DateTime.from_iso8601(expires)
    assert DateTime.diff(expires, DateTime.utc_now(), :hour) in (30 * 24 - 1)..(30 * 24)
    assert {:ok, %{expires_at: stored}} = HalC2.Auth.session(context.access)
    assert stored == DateTime.to_unix(expires, :millisecond)
    Map.put(context, :expires_at, stored)
  end

  step "administrators watching the access list see the new expiry", context do
    id = session_id(context.access)
    expected = context.expires_at

    {_, client} =
      Mc.await(World.client(context, "admin"), fn frame ->
        frame["t"] == "authAccess" and frame["event"]["type"] == "clientUpserted" and
          frame["event"]["payload"]["sessionId"] == id and
          ms(frame["event"]["payload"]["expiresAt"]) == expected
      end)

    World.put_client(context, "admin", client)
  end

  step "its session still runs out in a year", context do
    assert {200, _, %{"expiresAt" => expires}} = context.response
    {:ok, expires, _} = DateTime.from_iso8601(expires)
    assert DateTime.diff(expires, DateTime.utc_now(), :day) in 364..365
    context
  end

  defp ms(iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(at, :millisecond)
  end

  # --- access management ---------------------------------------------------------

  # A scope the standard grant holds is left out of the session, so a refusal for it can be shown.
  step ~r/^a client whose session lacks (?<scope>\S+)$/, %{args: [scope]} = context do
    {:ok, link} =
      HalC2.Auth.create_pairing_link(%{"scopes" => @standard -- [scope], "label" => "Narrow"})

    access = pair!(context, link["credential"])
    {:ok, session} = HalC2.Auth.session(access)
    refute scope in session.scopes

    context
    |> World.put_client("device", socket!(context, access))
    |> Map.put(:access, access)
  end

  step ~r/^it tries to (?<action>write to a terminal|create a pairing link|list pairing links|revoke a pairing link|list authorized clients|revoke a client|revoke every other client)$/,
       %{args: [action]} = context do
    case action do
      "write to a terminal" ->
        {reply, client} =
          Mc.call(
            World.client(context, "device"),
            context.mc.environment,
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

  @rpc_for_action %{
    "reports the host's power state" => "server.reportHostPowerState",
    "reports that the client is in the foreground" => "server.reportClientActivity",
    "submits a review on a pull request" => "pullRequests.submitReview",
    "previews a pull request" => "pullRequests.preview",
    "reads a review diff" => "review.getDiffPreview",
    "opens a preview" => "preview.open",
    "lists previews" => "preview.list"
  }

  step ~r/^it (?<action>reports the host's power state|reports that the client is in the foreground|submits a review on a pull request|previews a pull request|reads a review diff|opens a preview|lists previews)$/,
       %{args: [action]} = context do
    {reply, context} = World.call(context, @rpc_for_action[action], %{}, "device")
    Map.put(context, :refusal, reply)
  end

  step ~r/^the MC refuses saying (?<scope>\S+) is required$/, %{args: [scope]} = context do
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

  step "the MC answers that a credential is missing", context do
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
      Mc.request(context.mc, :post, "/api/auth/clients/revoke",
        bearer: admin!(context),
        body: "{not json"
      )

    Map.put(context, :response, response)
  end

  step "the MC answers that the request is invalid", context do
    assert {400, _, %{"_tag" => "EnvironmentRequestInvalidError"}} = context.response
    context
  end

  step "an administrator creating a pairing link", context do
    {:ok, link} =
      HalC2.Auth.create_pairing_link(%{"scopes" => ["access:read", "access:write"]})

    Map.put(context, :access, pair!(context, link["credential"]))
  end

  step ~r/^it names (a scope that the administrator does not hold|an unknown scope|no scopes at all|the same scope twice|the default scopes without holding all of them)$/,
       %{args: [scopes]} = context do
    requested =
      case scopes do
        "a scope that the administrator does not hold" -> ["terminal:operate"]
        "an unknown scope" -> ["files:everything"]
        "no scopes at all" -> []
        "the same scope twice" -> ["access:write", "access:write"]
        "the default scopes without holding all of them" -> nil
      end

    body = if requested == nil, do: %{}, else: %{"scopes" => requested}

    response =
      Mc.request(context.mc, :post, "/api/auth/pairing-token",
        bearer: context.access,
        json: body
      )

    Map.put(context, :response, response)
  end

  step "the MC refuses the link as an invalid scope", context do
    assert {400, _, %{"_tag" => "EnvironmentRequestInvalidError"}} = context.response
    assert HalC2.Auth.pairing_links() == []
    context
  end

  step "an administrator follows the MC's access list", context do
    access = admin!(context)
    client = socket!(context, access)
    client = Mc.sub(client, 40, %{"type" => "authAccess"})

    {snapshot, client} =
      Mc.await(client, &(&1["t"] == "authAccess" and &1["event"]["type"] == "snapshot"))

    context
    |> World.put_client("admin", client)
    |> Map.merge(%{admin: access, snapshot: snapshot["event"]["payload"]})
  end

  step "a pairing link is created and then revoked", context do
    assert {200, _, %{"id" => id, "credential" => credential}} =
             Mc.request(context.mc, :post, "/api/auth/pairing-token",
               bearer: context.admin,
               json: %{"label" => "Tablet"}
             )

    assert {200, _, %{"revoked" => true}} =
             Mc.request(context.mc, :post, "/api/auth/pairing-links/revoke",
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

    {up, client} = Mc.await(client, event.("pairingLinkUpserted", &(&1["id"] == link)))
    {down, client} = Mc.await(client, event.("pairingLinkRemoved", &(&1["id"] == link)))
    {paired, client} = Mc.await(client, event.("clientUpserted", &(&1["sessionId"] == device)))
    revisions = for frame <- [up, down, paired], do: frame["event"]["revision"]
    assert revisions == Enum.sort(revisions)
    assert up["event"]["payload"]["label"] == "Tablet"
    World.put_client(context, "admin", client)
  end

  step "the revoked link no longer pairs", context do
    assert {400, %{"error" => "invalid_grant"}} = Mc.exchange(context.mc, context.token)
    context
  end

  step "a device paired with standard scopes", context do
    access = standard!(context)
    World.put_client(context, "device", socket!(context, access))
  end

  step "it asks to follow the access list", context do
    client = Mc.sub(World.client(context, "device"), 41, %{"type" => "authAccess"})
    World.put_client(context, "device", client)
  end

  step "only that subscription fails saying access:read is required", context do
    {frame, client} =
      Mc.await(World.client(context, "device"), &(&1["t"] == "error" and &1["id"] == 41))

    assert frame["reason"] == "access:read is required"
    World.put_client(context, "device", client)
  end

  step "the rest of its socket keeps working", context do
    client = Mc.config(World.client(context, "device"), 42)
    client = Mc.ws_client().send_json(client, %{"t" => "ping"})
    {_, client} = Mc.await(client, &(&1["t"] == "pong"))
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
      Mc.await(
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
        "subject_token" => HalC2.Auth.create_pairing_token(context.mc.store),
        "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
        "client_label" => label
      }

      assert {200, _, _} =
               Mc.request(context.mc, :post, "/oauth/token",
                 form: form,
                 headers: [{"user-agent", agent}]
               )
    end

    context
  end

  step "the MC records each as mobile, tablet and desktop", context do
    types = Map.new(HalC2.Auth.clients(), &{&1["client"]["label"], &1["client"]["deviceType"]})
    assert types == %{"Phone" => "mobile", "Tablet" => "tablet", "Desktop" => "desktop"}
    context
  end

  step "an administrator created a pairing link", context do
    admin = admin!(context)

    assert {200, _, link} =
             Mc.request(context.mc, :post, "/api/auth/pairing-token",
               bearer: admin,
               json: %{"label" => "Kitchen tablet", "scopes" => ["orchestration:read"]}
             )

    Map.merge(context, %{admin: admin, link: link})
  end

  step "anyone lists pairing links", context do
    Map.put(
      context,
      :response,
      Mc.request(context.mc, :get, "/api/auth/pairing-links", bearer: context.admin)
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
      Mc.request(context.mc, :post, "/api/auth/clients/revoke",
        bearer: admin,
        json: %{"sessionId" => session_id(admin)}
      )

    Map.merge(context, %{admin: admin, response: response})
  end

  step "the MC refuses because the current session cannot be revoked", context do
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
      Mc.request(context.mc, :post, "/api/auth/clients/revoke-others", bearer: context.admin)

    Map.put(context, :response, response)
  end

  step "the other two sessions are revoked", context do
    for access <- context.others, do: assert(HalC2.Auth.session(access) == :error)
    assert {:ok, _} = HalC2.Auth.session(context.admin)
    context
  end

  step "the MC reports how many it revoked", context do
    assert {200, _, %{"revokedCount" => 2}} = context.response
    context
  end

  # --- access over the socket ------------------------------------------------------

  step ~r/^it calls (?<method>hal-c2\.\w+) on the MC$/, %{args: [method]} = context do
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
  # that got past the MC would fail as unavailable instead.
  step "another member of the MC's cluster", context do
    member = %{"environmentId" => "env-member", "label" => "Member"}
    send(HalC2.Shell, {:nodeup, :member@nowhere})
    GenServer.cast(HalC2.Shell, {:peer_environment, :member@nowhere, member})
    :sys.get_state(HalC2.Shell)
    Map.put(context, :member, "env-member")
  end

  step ~r/^the administrator calls (?<method>hal-c2\.\w+) on that member$/,
       %{args: [method]} = context do
    [first, _] = context.others
    payload = %{"sessionId" => session_id(first)}
    client = World.client(context, "admin")
    {reply, client} = Mc.call(client, context.member, method, payload)
    context |> World.put_client("admin", client) |> Map.put(:refusal, reply)
  end

  step "the call is refused because the caller's session lives on another MC", context do
    assert {:error, _,
            %{
              "_tag" => "EnvironmentOperationForbiddenError",
              "reason" => "session_on_another_mc"
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

  step "an MC store written before client metadata was recorded", context do
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

    access = "an-access-token-from-an-older-mc"

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
             Mc.request(context.mc, :post, "/api/auth/clients/revoke",
               bearer: admin!(context),
               json: %{"sessionId" => context.device}
             )

    context
  end

  step "the client's socket is closed as revoked", context do
    assert {:close, 4401, "session revoked"} = Mc.await_close(World.client(context, "device"))
    context
  end

  step "it cannot reconnect with its old session", context do
    assert {401, _, _} =
             Mc.request(context.mc, :post, "/api/auth/websocket-ticket", bearer: context.access)

    context
  end

  # --- narrowing, DPoP, the dev credential ---------------------------------------

  step "a pairing link with administrative scopes", context do
    {:ok, link} = HalC2.Auth.create_pairing_link(%{"scopes" => @admin})
    Map.put(context, :token, link["credential"])
  end

  step "a client exchanges it asking only for orchestration:read", context do
    assert {200, %{"scope" => "orchestration:read", "access_token" => access}} =
             Mc.exchange(context.mc, context.token, %{"scope" => "orchestration:read"})

    # Asking for a scope the credential does not grant is refused.
    assert {400, %{"error" => "invalid_scope"}} =
             Mc.exchange(context.mc, HalC2.Auth.create_pairing_token(context.mc.store), %{
               "scope" => "access:write"
             })

    Map.put(context, :access, access)
  end

  step "a pairing link with standard scopes", context do
    Map.put(context, :token, HalC2.Auth.create_pairing_token(context.mc.store))
  end

  step "a client exchanges it asking for access:write", context do
    Map.put(
      context,
      :result,
      Mc.exchange(context.mc, context.token, %{"scope" => "access:write"})
    )
  end

  step "the exchange is refused as an invalid scope", context do
    assert {400, %{"error" => "invalid_scope"}} = context.result
    context
  end

  step "the link still pairs a client that asks for what it grants", context do
    assert {200, %{"access_token" => _}} = Mc.exchange(context.mc, context.token)
    context
  end

  step "a client that paired with a DPoP key", context do
    key = dpop_key()
    token = HalC2.Auth.create_pairing_token(context.mc.store)
    proof = dpop_proof(key, "POST", url(context, "/oauth/token"))

    form = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
      "subject_token" => token,
      "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap"
    }

    assert {200, _, %{"token_type" => "DPoP", "access_token" => access, "expires_in" => 3600}} =
             Mc.request(context.mc, :post, "/oauth/token",
               form: form,
               headers: [{"dpop", proof}]
             )

    Map.merge(context, %{key: key, access: access})
  end

  step "it presents its access token with a proof", context do
    proof = dpop_proof(context.key, "GET", url(context, "/api/auth/session"), context.access)

    response =
      Mc.request(context.mc, :get, "/api/auth/session",
        headers: [{"authorization", "DPoP #{context.access}"}, {"dpop", proof}]
      )

    Map.put(context, :response, response)
  end

  step "the MC accepts it", context do
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
             Mc.request(context.mc, :post, path,
               headers: [{"authorization", "DPoP #{context.access}"}, {"dpop", forged}]
             )

    # No proof at all, and the same token as a plain bearer.
    assert {401, _, _} =
             Mc.request(context.mc, :post, path,
               headers: [{"authorization", "DPoP #{context.access}"}]
             )

    assert {401, _, _} = Mc.request(context.mc, :post, path, bearer: context.access)
    # A proof is good once.
    proof = dpop_proof(context.key, "POST", url(context, path), context.access)
    headers = [{"authorization", "DPoP #{context.access}"}, {"dpop", proof}]
    assert {200, _, %{"ticket" => _}} = Mc.request(context.mc, :post, path, headers: headers)

    assert {401, _, %{"dpopFailureReason" => "replay"}} =
             Mc.request(context.mc, :post, path, headers: headers)

    context
  end

  step "a fixed development auth token is configured", context do
    token = "reusable-dev-auth-token-that-is-long-enough"
    Application.put_env(:hal_c2, :dev_auth_token, token)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :dev_auth_token) end)

    %{context | mc: Mc.restart(context.mc), clients: %{}}
    |> Map.put(:token, token)
  end

  step "a browser presents it to a development MC", context do
    Map.put(context, :grant, Mc.exchange(context.mc, context.token))
  end

  step "the MC grants an administrative session", context do
    assert {200, %{"access_token" => access, "scope" => scope}} = context.grant
    assert String.split(scope) == @admin
    # The credential is itself a session, usable as a bearer.
    assert {200, _, %{"authenticated" => true, "scopes" => @admin}} =
             Mc.request(context.mc, :get, "/api/auth/session", bearer: context.token)

    Map.put(context, :access, access)
  end

  step "revoking it locally does not affect another worktree", context do
    dev = "dev-auth-" <> sha(context.token)

    assert {200, _, %{"revoked" => true}} =
             Mc.request(context.mc, :post, "/api/auth/clients/revoke",
               bearer: context.access,
               json: %{"sessionId" => dev}
             )

    assert {400, %{"error" => "invalid_grant"}} = Mc.exchange(context.mc, context.token)

    # Another worktree's MC, with its own store and the same credential.
    other = Mc.restart(%{context.mc | home: Mc.tmp_dir(context.mc, "worktree")})
    assert {200, %{"scope" => scope}} = Mc.exchange(other, context.token)
    assert String.split(scope) == @admin
    %{context | mc: other, clients: %{}}
  end

  step "the development token is rotated", context do
    rotated = context.token <> "-rotated"
    Application.put_env(:hal_c2, :dev_auth_token, rotated)

    %{context | mc: Mc.restart(context.mc), clients: %{}}
    |> Map.merge(%{previous_token: context.token, token: rotated})
  end

  step "the previous development credential is refused", context do
    assert {200, _, %{"authenticated" => false}} =
             Mc.request(context.mc, :get, "/api/auth/session", bearer: context.previous_token)

    assert {401, _, _} =
             Mc.request(context.mc, :post, "/api/auth/websocket-ticket",
               bearer: context.previous_token
             )

    assert {400, %{"error" => "invalid_grant"}} =
             Mc.exchange(context.mc, context.previous_token)

    context
  end

  step "the replacement development credential signs in", context do
    assert {200, _, %{"authenticated" => true, "scopes" => @admin}} =
             Mc.request(context.mc, :get, "/api/auth/session", bearer: context.token)

    assert {200, %{"scope" => scope}} = Mc.exchange(context.mc, context.token)
    assert String.split(scope) == @admin
    context
  end

  step "the development token is removed", context do
    Application.delete_env(:hal_c2, :dev_auth_token)

    %{context | mc: Mc.restart(context.mc), clients: %{}}
    |> Map.put(:previous_token, context.token)
  end

  step "a non-development MC restarts on the same store with that token in its environment",
       context do
    World.put_os_env("HAL_C2_DEV_AUTH_TOKEN", context.token)
    refute Keyword.has_key?(HalC2.Test.Storage.boot_config(:prod), :dev_auth_token)
    Application.delete_env(:hal_c2, :dev_auth_token)

    %{context | mc: Mc.restart(context.mc), clients: %{}}
    |> Map.put(:previous_token, context.token)
  end

  # --- the command line ------------------------------------------------------------

  step "an operator lists sessions from the MC's command line", context do
    Map.put(context, :listed, mix_output(Mix.Tasks.HalC2.Auth, ["session", "list"]))
  end

  step "it sees the same clients as Connections settings", context do
    assert {200, _, clients} =
             Mc.request(context.mc, :get, "/api/auth/clients", bearer: context.admin)

    listed = for line <- context.listed, do: line |> String.split("\t") |> hd()
    assert Enum.sort(listed) == Enum.sort(for c <- clients, do: c["sessionId"])
    assert length(listed) == 3
    context
  end

  step "it can revoke one of them", context do
    [other | _] = context.others
    id = session_id(other)

    assert [<<^id::binary-size(byte_size(id)), ": the session was revoked">>] =
             mix_output(Mix.Tasks.HalC2.Auth, ["session", "revoke", id])

    assert {401, _, _} =
             Mc.request(context.mc, :post, "/api/auth/websocket-ticket", bearer: other)

    listed = mix_output(Mix.Tasks.HalC2.Auth, ["session", "list"])
    refute Enum.any?(listed, &String.starts_with?(&1, id))
    context
  end

  # --- credentials in answers, racing, narrowing -----------------------------------

  step "a pairing token that has not been exchanged", context do
    Map.put(context, :token, HalC2.Auth.create_pairing_token(context.mc.store))
  end

  step "two clients exchange it at the same moment", context do
    tasks = for _ <- 1..2, do: Task.async(fn -> Mc.exchange(context.mc, context.token) end)
    Map.put(context, :grants, Task.await_many(tasks, 30_000))
  end

  step "exactly one of them receives a session", context do
    assert [{200, %{"access_token" => _}}] = Enum.filter(context.grants, &(elem(&1, 0) == 200))
    assert length(HalC2.Auth.clients()) == 1
    context
  end

  step "the other is refused as an invalid grant", context do
    assert [{400, %{"error" => "invalid_grant"}}] =
             Enum.reject(context.grants, &(elem(&1, 0) == 200))

    context
  end

  step "a client exchanges a pairing token or asks for a socket ticket", context do
    token = HalC2.Auth.create_pairing_token(context.mc.store)

    form = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
      "subject_token" => token,
      "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap"
    }

    {200, exchange_headers, %{"access_token" => access}} =
      Mc.request(context.mc, :post, "/oauth/token", form: form)

    {200, ticket_headers, _} =
      Mc.request(context.mc, :post, "/api/auth/websocket-ticket", bearer: access)

    {400, refused_headers, _} =
      Mc.request(context.mc, :post, "/oauth/token", form: %{form | "subject_token" => token})

    Map.put(context, :credential_headers, [exchange_headers, ticket_headers, refused_headers])
  end

  step "the answer is marked as not storable by browsers or proxies", context do
    for headers <- context.credential_headers,
        do: assert({"cache-control", "no-store"} in headers)

    context
  end

  step "a pairing link granting only some scopes", context do
    {:ok, link} =
      HalC2.Auth.create_pairing_link(%{"scopes" => ["orchestration:read", "terminal:operate"]})

    Map.put(context, :token, link["credential"])
  end

  step "a client exchanges it asking for those scopes", context do
    grant =
      Mc.exchange(context.mc, context.token, %{"scope" => "orchestration:read terminal:operate"})

    Map.put(context, :grant, grant)
  end

  step "the session holds exactly those scopes", context do
    assert {200, %{"access_token" => access, "scope" => "orchestration:read terminal:operate"}} =
             context.grant

    assert {:ok, %{scopes: ["orchestration:read", "terminal:operate"]}} =
             HalC2.Auth.session(access)

    context
  end

  step "a request the link cannot grant is refused before the link is used up", context do
    {:ok, link} = HalC2.Auth.create_pairing_link(%{"scopes" => ["orchestration:read"]})

    assert {400, %{"error" => "invalid_scope"}} =
             Mc.exchange(context.mc, link["credential"], %{"scope" => "access:write"})

    assert {200, %{"scope" => "orchestration:read"}} = Mc.exchange(context.mc, link["credential"])
    context
  end

  # --- sessions that end -------------------------------------------------------------

  step ~r/^the client's session expires$/, context do
    sql(context, "UPDATE auth_sessions SET expires_at = ?1 WHERE id = ?2", [
      now() - 1,
      context.device
    ])

    HalC2.Auth.prune()
    context
  end

  step "the client's session is replaced by a new one", context do
    # The desktop's session is the one a new bootstrap exchange replaces.
    :sys.replace_state(HalC2.Auth, fn state ->
      %{state | desktop: %{hash: sha("next-desktop-token"), expires_at: now() + 60_000}}
    end)

    sql(context, "UPDATE auth_sessions SET subject = 'desktop-bootstrap' WHERE id = ?1", [
      context.device
    ])

    assert {200, _} = Mc.exchange(context.mc, "next-desktop-token")
    context
  end

  step "an administrator revokes the client while its socket opens", context do
    context = Map.put(context, :admin_access, admin!(context))

    assert {200, _, %{"revoked" => true}} =
             Mc.request(context.mc, :post, "/api/auth/clients/revoke",
               bearer: context.admin_access,
               json: %{"sessionId" => context.device}
             )

    # A socket that was still opening when the revoke ran is told to close all the same.
    GenServer.cast(HalC2.Auth, {:connected, context.device, self()})
    assert_receive {:hal_c2_session_revoked, _}, 5_000
    context
  end

  step "the client's socket is closed", context do
    assert {:close, _, _} = Mc.await_close(World.client(context, "device"))
    context
  end

  # --- listing order, expiry with a socket open, the user agent -----------------------

  defp set_created(context, access, ms_ago),
    do:
      sql(context, "UPDATE auth_sessions SET created_at = ?1 WHERE token_hash = ?2", [
        now() - ms_ago,
        sha(access)
      ])

  step "three paired clients, one of them an administrator", context do
    admin = admin!(context)

    idle =
      pair!(context, HalC2.Auth.create_pairing_token(context.mc.store), %{
        "client_label" => "Idle"
      })

    busy =
      pair!(context, HalC2.Auth.create_pairing_token(context.mc.store), %{
        "client_label" => "Busy"
      })

    # The administrator is the newest, so only the ordering rules can put it first.
    set_created(context, idle, 3_000)
    set_created(context, busy, 2_000)
    Map.merge(context, %{admin: admin, idle: idle, busy: busy})
  end

  step "one of the others has an open socket", context do
    World.put_client(context, "busy", socket!(context, context.busy))
  end

  step "the administrator comes first", context do
    assert {200, _, [%{"current" => true} | _]} = context.response
    context
  end

  step "the connected client comes before the one that is not connected", context do
    assert {200, _, [_, %{"connected" => true, "client" => %{"label" => "Busy"}}, idle]} =
             context.response

    assert idle["client"]["label"] == "Idle"
    context
  end

  step "clients that tie are listed newest first", context do
    newer =
      pair!(context, HalC2.Auth.create_pairing_token(context.mc.store), %{
        "client_label" => "Newer idle"
      })

    set_created(context, newer, 1_000)
    {200, _, listed} = access_request(context, "list authorized clients", context.admin)
    labels = for client <- listed, do: client["client"]["label"]
    assert labels == ["Admin", "Busy", "Newer idle", "Idle"]
    context
  end

  step "a paired client whose session has expired", context do
    access = standard!(context)
    device = session_id(access)

    sql(context, "UPDATE auth_sessions SET expires_at = ?1 WHERE token_hash = ?2", [
      now() - 1,
      sha(access)
    ])

    Map.merge(context, %{access: access, device: device})
  end

  step "it still has a socket open", context do
    # Its socket opened while the session was valid and is still open.
    context = Map.put(context, :admin, admin!(context))

    sql(context, "UPDATE auth_sessions SET expires_at = ?1 WHERE id = ?2", [
      now() + 60_000,
      context.device
    ])

    context = World.put_client(context, "device", socket!(context, context.access))

    sql(context, "UPDATE auth_sessions SET expires_at = ?1 WHERE id = ?2", [
      now() - 1,
      context.device
    ])

    context
  end

  step "the client is listed as connected", context do
    assert {200, _, listed} = context.response
    assert %{"connected" => true} = Enum.find(listed, &(&1["sessionId"] == context.device))
    context
  end

  step "once its last socket closes it is no longer listed", context do
    HalC2.Auth.prune()
    assert {200, _, listed} = access_request(context, "list authorized clients", context.admin)
    refute Enum.any?(listed, &(&1["sessionId"] == context.device))
    context
  end

  step "the MC minted a link for the app that started it", context do
    desktop_boot(context, "desktop-token")
  end

  step ~r/^an administrator created a pairing link labelled "(?<label>[^"]+)"$/,
       %{args: [label]} = context do
    admin = admin!(context)

    assert {200, _, _} =
             Mc.request(context.mc, :post, "/api/auth/pairing-token",
               bearer: admin,
               json: %{"label" => label}
             )

    Map.put(context, :admin, admin)
  end

  step "an administrator lists pairing links", context do
    Map.put(
      context,
      :response,
      Mc.request(context.mc, :get, "/api/auth/pairing-links", bearer: context.admin)
    )
  end

  step ~r/^only the "(?<label>[^"]+)" link is listed$/, %{args: [label]} = context do
    assert {200, _, [%{"label" => ^label}]} = context.response
    context
  end

  step "a client pairs presenting a device type, an operating system and a label", context do
    token = HalC2.Auth.create_pairing_token(context.mc.store)

    assert {200, _, _} =
             Mc.request(context.mc, :post, "/oauth/token",
               form: %{
                 "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
                 "subject_token" => token,
                 "subject_token_type" =>
                   "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
                 "client_label" => "Ana's tablet",
                 "client_device_type" => "tablet"
               },
               headers: [{"user-agent", "Mozilla/5.0 (X11; Linux x86_64) Chrome/130.0"}]
             )

    context
  end

  step "the MC records what the client presented", context do
    assert [%{"client" => %{"deviceType" => "tablet", "label" => "Ana's tablet"}}] =
             HalC2.Auth.clients()

    context
  end

  step "only what it left out is read from the user agent", context do
    assert [%{"client" => %{"userAgent" => "Mozilla/5.0 (X11; Linux x86_64) Chrome/130.0"}}] =
             HalC2.Auth.clients()

    context
  end

  step "curl or wget exchanges a pairing token", context do
    for agent <- ["curl/8.5.0", "Wget/1.21.4"] do
      token = HalC2.Auth.create_pairing_token(context.mc.store)

      assert {200, _, _} =
               Mc.request(context.mc, :post, "/oauth/token",
                 form: %{
                   "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
                   "subject_token" => token,
                   "subject_token_type" =>
                     "urn:hal-c2:params:oauth:token-type:environment-bootstrap"
                 },
                 headers: [{"user-agent", agent}]
               )
    end

    context
  end

  step "the MC records its device type as bot", context do
    assert ["bot", "bot"] =
             for(client <- HalC2.Auth.clients(), do: client["client"]["deviceType"])

    context
  end

  # --- DPoP in depth, keys on links ---------------------------------------------------

  defp token_path, do: "/api/auth/websocket-ticket"

  defp dpop_headers(access, proof), do: [{"authorization", "DPoP #{access}"}, {"dpop", proof}]

  step "a pairing link minted for a client's DPoP key", context do
    key = dpop_key()
    {jwk, _} = key

    {:ok, link} =
      HalC2.Auth.create_pairing_link(%{
        "scopes" => @standard,
        "proofKeyThumbprint" => HalC2.Auth.Dpop.thumbprint(jwk)
      })

    Map.merge(context, %{key: key, token: link["credential"]})
  end

  defp exchange_with_key(context, key) do
    proof = dpop_proof(key, "POST", url(context, "/oauth/token"))

    Mc.request(context.mc, :post, "/oauth/token",
      form: %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token" => context.token,
        "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap"
      },
      headers: [{"dpop", proof}]
    )
  end

  step "a client that holds another key exchanges it", context do
    {status, _, body} = exchange_with_key(context, dpop_key())
    Map.put(context, :grant, {status, body})
  end

  step "the exchange is refused as an invalid grant", context do
    assert {400, %{"error" => "invalid_grant"}} = context.grant
    context
  end

  step "the client that holds the named key can still exchange it", context do
    assert {200, _, %{"token_type" => "DPoP"}} = exchange_with_key(context, context.key)
    context
  end

  step "its session expires after one hour, not thirty days", context do
    assert {:ok, %{expires_at: expires}} = HalC2.Auth.session(context.access)
    assert (expires - now()) in :timer.minutes(59)..:timer.minutes(61)
    context
  end

  step "presenting that token as a plain bearer is refused", context do
    assert {401, _, %{"reason" => "invalid_credential"}} =
             Mc.request(context.mc, :post, token_path(), bearer: context.access)

    context
  end

  step "presenting a token that is not bound to a key under the DPoP scheme is refused",
       context do
    plain = standard!(context)
    proof = dpop_proof(context.key, "POST", url(context, token_path()), plain)

    assert {401, _, %{"reason" => "invalid_credential"}} =
             Mc.request(context.mc, :post, token_path(), headers: dpop_headers(plain, proof))

    context
  end

  step "it presented its token with a proof that the MC accepted", context do
    proof = dpop_proof(context.key, "POST", url(context, token_path()), context.access)
    headers = dpop_headers(context.access, proof)

    assert {200, _, %{"ticket" => _}} =
             Mc.request(context.mc, :post, token_path(), headers: headers)

    Map.put(context, :headers, headers)
  end

  step "the same proof is presented again", context do
    Map.put(
      context,
      :response,
      Mc.request(context.mc, :post, token_path(), headers: context.headers)
    )
  end

  step "the MC refuses it as a replay", context do
    assert {401, _, %{"dpopFailureReason" => "replay"}} = context.response
    context
  end

  step ~r/^it presents a proof that (?<problem>.+)$/, %{args: [problem]} = context do
    url = url(context, token_path())
    now = System.os_time(:second)

    proof =
      case problem do
        "was signed too long ago or in the future" ->
          dpop_proof(context.key, "POST", url, context.access, now - 3_600)

        "was signed by a key other than the paired one" ->
          dpop_proof(dpop_key(), "POST", url, context.access)

        "names another method or address than the request" ->
          dpop_proof(context.key, "GET", url, context.access)

        "was made for a different access token" ->
          dpop_proof(context.key, "POST", url, "another-access-token")

        "is not a well-formed proof" ->
          "not-a-jwt"
      end

    Map.put(
      context,
      :response,
      Mc.request(context.mc, :post, token_path(), headers: dpop_headers(context.access, proof))
    )
  end

  step ~r/^the MC refuses it as (?<reason>time_window|key_mismatch|request_mismatch|token_mismatch|invalid_proof)$/,
       %{args: [reason]} = context do
    assert {401, _, %{"reason" => "invalid_credential", "dpopFailureReason" => ^reason}} =
             context.response

    context
  end

  # --- the command line, lifetimes, labels, JSON ---------------------------------

  defp auth_cli(args), do: mix_output(Mix.Tasks.HalC2.Auth, args)

  step ~r/^an operator mints a pairing link with a lifetime of one hour, the label "(?<label>[^"]+)" and the public address "(?<addr>[^"]+)"$/,
       %{args: [label, addr]} = context do
    assert [link, _expires] =
             mix_output(Mix.Tasks.HalC2.Pair, [addr, "--ttl", "1h", "--label", label])

    Map.merge(context, %{link: link, base: addr, label: label})
  end

  step ~r/^the printed link points at "(?<addr>[^"]+)" and carries a one-time token$/,
       %{args: [addr]} = context do
    assert String.starts_with?(context.link, addr <> "/?token=")
    context
  end

  step "the link expires after one hour", context do
    assert [%{"expiresAt" => expires}] = HalC2.Auth.pairing_links()
    {:ok, expires, _} = DateTime.from_iso8601(expires)
    assert DateTime.diff(expires, DateTime.utc_now(), :second) in 3590..3600
    context
  end

  step ~r/^Connections settings lists the link as "(?<label>[^"]+)"$/,
       %{args: [label]} = context do
    assert [%{"label" => ^label}] = HalC2.Auth.pairing_links()
    context
  end

  step "the output says when the link expires as an ISO 8601 time such as \"2026-09-28T00:56:46.668Z\"",
       context do
    assert [_link, "Expires " <> iso] = context.printed
    assert {:ok, _, 0} = DateTime.from_iso8601(iso)
    assert iso =~ ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$/
    context
  end

  step "an operator mints a pairing link from the command line and asks for JSON", context do
    Map.put(context, :printed, mix_output(Mix.Tasks.HalC2.Pair, [url(context, ""), "--json"]))
  end

  step "the output is only a JSON document with the link's id, label, token, scopes and expiry",
       context do
    assert [json] = context.printed
    assert %{"id" => _, "token" => _, "scopes" => _, "expiresAt" => _} = JSON.decode!(json)
    assert Map.has_key?(JSON.decode!(json), "label")
    context
  end

  step ~r/^an operator issues a session for the subject "(?<subject>[^"]+)" from the command line$/,
       %{args: [subject]} = context do
    assert [_summary, token] = auth_cli(["session", "issue", subject])
    Map.merge(context, %{issued: token, subject: subject})
  end

  step ~r/^the MC prints a bearer token that signs in as a session for "(?<subject>[^"]+)"$/,
       %{args: [_subject]} = context do
    assert {:ok, %{id: _}} = HalC2.Auth.session(context.issued)
    context
  end

  step "the session has administrative scopes", context do
    assert {:ok, %{scopes: scopes}} = HalC2.Auth.session(context.issued)
    assert Enum.sort(scopes) == Enum.sort(@admin)
    context
  end

  step "the session is listed with the other clients and can be revoked", context do
    {:ok, session} = HalC2.Auth.session(context.issued)
    assert Enum.any?(auth_cli(["session", "list"]), &String.starts_with?(&1, session.id))
    assert [msg] = auth_cli(["session", "revoke", session.id])
    assert msg =~ "the session was revoked"
    refute match?({:ok, _}, HalC2.Auth.session(context.issued))
    context
  end

  step ~r/^an operator issues a session from the command line asking for (?<form>the token|JSON)$/,
       %{args: [form]} = context do
    flag = if form == "JSON", do: "--json", else: "--token"
    Map.merge(context, %{printed: auth_cli(["session", "issue", "ci", flag]), form: form})
  end

  step ~r/^the output is (?<result>only the bearer token, so a script can capture it|only a JSON document with the session id, token, scopes, subject and expiry)$/,
       %{args: [result]} = context do
    assert [line] = context.printed

    if String.contains?(result, "JSON") do
      assert %{"id" => _, "token" => _, "scopes" => _, "subject" => "ci", "expiresAt" => _} =
               JSON.decode!(line)
    else
      assert {:ok, _} = HalC2.Auth.session(line)
    end

    context
  end

  step "two pairing links are waiting to be used", context do
    for label <- ["First", "Second"],
        do: HalC2.Auth.create_pairing_link(%{"scopes" => @standard, "label" => label})

    context
  end

  step "each link shows its id, label, scopes and expiry", context do
    assert length(context.listed) == 2

    for line <- context.listed do
      assert [id, label, scopes, "expires " <> _] = String.split(line, "\t")
      assert id != "" and label in ["First", "Second"]
      assert String.split(scopes, ",") == @standard
    end

    context
  end

  step "no link shows its token", context do
    refute Enum.any?(context.listed, &(&1 =~ "token"))
    context
  end

  step "the desktop's own bootstrap link is not listed", context do
    assert length(context.listed) == 2
    context
  end

  step "a paired client that has never connected to the MC", context do
    Map.put(context, :client_access, standard!(context))
  end

  step "the client shows its scopes, method, subject, issue time and expiry", context do
    id = session_id(context.client_access)
    line = Enum.find(context.listed, &String.starts_with?(&1, id))

    assert [^id, _label, method, subject, scopes, "issued " <> _, "expires " <> _, _] =
             String.split(line, "\t")

    assert method != "" and subject != ""
    assert String.split(scopes, ",") == @standard
    Map.put(context, :line, line)
  end

  step "its last connection reads \"never\"", context do
    assert context.line =~ "last connected never"
    context
  end

  step "a session with no client label reads \"unlabeled client\"", context do
    id = session_id(context.client_access)
    sql(context, "UPDATE auth_sessions SET label = NULL WHERE id = ?1", [id])
    line = Enum.find(auth_cli(["session", "list"]), &String.starts_with?(&1, id))
    assert line =~ "\tunlabeled client\t"
    context
  end

  step "bearer tokens are never shown", context do
    refute Enum.any?(context.listed, &(&1 =~ context.client_access))
    context
  end

  step ~r/^there are no (?<things>pairing links|sessions)$/, %{args: [things]} = context do
    sql(context, "DELETE FROM auth_pairing")
    sql(context, "DELETE FROM auth_sessions")
    Map.put(context, :things, things)
  end

  step ~r/^an operator lists (?<things>pairing links|sessions) from the command line$/,
       %{args: [things]} = context do
    kind = if things == "sessions", do: "session", else: "pairing"
    Map.put(context, :listed, auth_cli([kind, "list"]))
  end

  step ~r/^the output says "(?<message>[^"]+)"$/, %{args: [message]} = context do
    assert context.listed == [message]
    context
  end

  step ~r/^(?<state>a pairing link waiting to be used|a pairing link that was already used|a paired client's session|a session that is already revoked)$/,
       %{args: [state]} = context do
    {:ok, link} = HalC2.Auth.create_pairing_link(%{"scopes" => @standard})
    link_id = link["id"]

    case state do
      "a pairing link waiting to be used" ->
        Map.merge(context, %{
          cli: ["pairing", "revoke", link_id],
          result: "the pairing credential was revoked"
        })

      "a pairing link that was already used" ->
        pair!(context, link["credential"])

        Map.merge(context, %{
          cli: ["pairing", "revoke", link_id],
          result: "no active pairing credential has that id"
        })

      "a paired client's session" ->
        id = session_id(standard!(context))
        Map.merge(context, %{cli: ["session", "revoke", id], result: "the session was revoked"})

      "a session that is already revoked" ->
        id = session_id(standard!(context))
        HalC2.Auth.revoke_session(context.mc.store, id)

        Map.merge(context, %{
          cli: ["session", "revoke", id],
          result: "no active session has that id"
        })
    end
  end

  step "an operator revokes it by id from the command line", context do
    Map.put(context, :printed, auth_cli(context.cli))
  end

  step ~r/^the output says (?<result>the pairing credential was revoked|no active pairing credential has that id|the session was revoked|no active session has that id)$/,
       %{args: [result]} = context do
    assert [line] = context.printed
    assert line =~ result
    context
  end
end
