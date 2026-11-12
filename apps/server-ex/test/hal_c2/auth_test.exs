defmodule HalC2.AuthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Exqlite.Sqlite3
  alias HalC2.Test.WsClient

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :port, 0)
    :persistent_term.erase({HalC2.Web, :token})
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Auth)
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(HalC2.Web))
    {:ok, _} = Application.ensure_all_started(:inets)
    %{port: port, path: Path.join(dir, "hal-c2.sqlite")}
  end

  test "a device goes by its label, else its type, and a blank one is no name" do
    cases = [
      {"Phone", "mobile", "Phone"},
      {" Phone ", nil, "Phone"},
      {nil, "mobile", "mobile"},
      {"", "mobile", "mobile"},
      {" \t", " mobile ", "mobile"},
      {"", "", nil},
      {"  ", "  ", nil},
      {nil, nil, nil}
    ]

    for {label, device_type, name} <- cases do
      {:ok, %{"credential" => credential}} = HalC2.Auth.create_pairing_link(%{})

      {:ok, access, _expires_in, _scopes} =
        HalC2.Auth.exchange(credential, %{label: label, device_type: device_type})

      {:ok, %{id: id}} = HalC2.Auth.session(access)
      assert HalC2.Auth.device_name(id) == name
    end
  end

  # The same requests, in the same order, the client runtime makes when pairing.
  test "pairing token -> bearer token -> ws ticket -> socket", %{port: port, path: path} do
    pairing = HalC2.Auth.create_pairing_token(path)
    base = "http://127.0.0.1:#{port}"

    form = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
      "subject_token" => pairing,
      "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
      "requested_token_type" => "urn:ietf:params:oauth:token-type:access_token",
      "client_label" => "test"
    }

    assert {200, %{"access_token" => access, "token_type" => "Bearer", "scope" => scope}} =
             post_form(base <> "/oauth/token", form)

    assert scope =~ "orchestration:read"
    # Pairing tokens are single use.
    assert {400, _} = post_form(base <> "/oauth/token", form)

    assert {200, %{"authenticated" => true, "sessionMethod" => "bearer-access-token"}} =
             request(:get, base <> "/api/auth/session", access)

    assert {200, %{"authenticated" => false}} = request(:get, base <> "/api/auth/session", nil)
    assert {401, _} = request(:post, base <> "/api/auth/websocket-ticket", "wrong")

    assert {200, %{"ticket" => ticket, "expiresAt" => _}} =
             request(:post, base <> "/api/auth/websocket-ticket", access)

    assert {:ok, client} = WsClient.connect(port, "/ws?wsTicket=#{ticket}")
    assert {%{"t" => "hello"}, _} = WsClient.recv(client, 1_000)
    # Tickets open one socket.
    assert {:error, 401} = WsClient.connect(port, "/ws?wsTicket=#{ticket}")
  end

  test "the desktop app's bootstrap token signs its window in, as often as needed", %{
    port: port
  } do
    :ok = stop_supervised(HalC2.Auth)
    :ok = HalC2.Desktop.apply_bootstrap(%{"desktopBootstrapToken" => "desk-token"})
    on_exit(fn -> Application.delete_env(:hal_c2, :desktop_token) end)
    start_supervised!(HalC2.Auth)

    form = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
      "subject_token" => "desk-token",
      "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
      "client_label" => "HAL-C2 Desktop"
    }

    base = "http://127.0.0.1:#{port}"
    assert {200, %{"scope" => scope}} = post_form(base <> "/oauth/token", form)
    assert scope =~ "access:write"
    # A reloaded window exchanges it again.
    assert {200, %{"access_token" => _}} = post_form(base <> "/oauth/token", form)
    assert {400, _} = post_form(base <> "/oauth/token", %{form | "subject_token" => "other"})
  end

  # An exchange that fails after spending its token leaves the token unspent: the
  # failing session insert crashes the exchange, and the token is still good after.
  test "a failed exchange does not spend its pairing token", %{path: path} do
    token = HalC2.Auth.create_pairing_token(path)
    assert_exchange_fails(path, token)

    assert {:ok, _, _, _} = HalC2.Auth.exchange(token)
  end

  test "a failed desktop exchange keeps the desktop's previous session", %{path: path} do
    :ok = stop_supervised(HalC2.Auth)
    :ok = HalC2.Desktop.apply_bootstrap(%{"desktopBootstrapToken" => "desk-token"})
    on_exit(fn -> Application.delete_env(:hal_c2, :desktop_token) end)
    start_supervised!(HalC2.Auth)

    {:ok, previous, _, _} = HalC2.Auth.exchange("desk-token")
    assert_exchange_fails(path, "desk-token")

    assert {:ok, %{}} = HalC2.Auth.session(previous)
  end

  test "a failed desktop exchange keeps the tickets of the desktop's previous session",
       %{path: path} do
    :ok = stop_supervised(HalC2.Auth)
    :ok = HalC2.Desktop.apply_bootstrap(%{"desktopBootstrapToken" => "desk-token"})
    on_exit(fn -> Application.delete_env(:hal_c2, :desktop_token) end)
    start_supervised!(HalC2.Auth)

    {:ok, previous, _, _} = HalC2.Auth.exchange("desk-token")
    {:ok, %{id: id}} = HalC2.Auth.session(previous)
    {:ok, ticket, _} = HalC2.Auth.issue_ticket(previous)
    # Its tables outlive the crash with their heir, as they do in a running MC.
    assert_exchange_fails(path, "desk-token", restart: false)

    assert {:ok, ^id} = HalC2.Auth.take_ticket(ticket)
  end

  # A socket reads its session's scopes, then connects; a revoke between the two must
  # not leave the socket open with them. This process is the socket: its connected cast
  # is handled before `clients/0` (a call from the same process) returns.
  test "a socket connecting after its session was revoked is told to close", %{path: path} do
    {:ok, access, _, _} = HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(path))
    {:ok, %{id: id}} = HalC2.Auth.session(access)

    assert {:ok, _} = HalC2.Auth.session_scopes(id)
    assert HalC2.Auth.revoke_client(id)

    HalC2.Auth.connected(id)
    HalC2.Auth.clients()
    assert_received {:hal_c2_session_revoked, ^id}
  end

  test "revoking a session through the store API closes its live socket", %{path: path} do
    {:ok, access, _, _} = HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(path))
    {:ok, %{id: id}} = HalC2.Auth.session(access)
    connect_socket(id)

    assert HalC2.Auth.revoke_session(path, id)
    assert_receive {:socket, {:hal_c2_session_revoked, ^id}}
  end

  # The CLI revokes from another VM, where no close message can reach the
  # socket: deleting the row directly stands in for it here.
  test "a session deleted from the store loses its socket on its next call",
       %{port: port, path: path} do
    Application.put_env(:hal_c2, :session_recheck_ms, 0)
    on_exit(fn -> Application.delete_env(:hal_c2, :session_recheck_ms) end)

    {client, id} = paired_socket(port, HalC2.Auth.standard_scopes(), "Phone")
    socket = Mint.HTTP.get_socket(client.conn)

    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "DELETE FROM auth_sessions WHERE id = '#{id}'")
    Sqlite3.close(db)

    client =
      WsClient.send_json(client, %{
        "t" => "rpc",
        "id" => 91_001,
        "environment" => HalC2.Environment.id(),
        "method" => "server.getConfig",
        "payload" => %{}
      })

    assert_receive {:tcp, ^socket, _} = message, 5_000
    {:ok, _conn, [{:data, _, data}]} = Mint.WebSocket.stream(client.conn, message)
    assert {:ok, _, [{:close, 4401, "session revoked"}]} = Mint.WebSocket.decode(client.ws, data)
  end

  test "a nested subject token is an invalid grant and leaves Auth running", %{
    port: port,
    path: path
  } do
    assert :error = HalC2.Auth.exchange(%{"x" => "y"})

    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap"
      }) <> "&subject_token%5Bx%5D=y"

    assert {400, %{"error" => "invalid_grant"}} =
             post_form("http://127.0.0.1:#{port}/oauth/token", body)

    assert {:ok, _, _, _} = HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(path))
  end

  test "pairing link TTLs are integers from one second to one day", %{port: port} do
    admin_scopes = HalC2.Auth.standard_scopes() ++ ~w(access:read access:write relay:write)

    {:ok, %{"credential" => credential}} =
      HalC2.Auth.create_pairing_link(%{"scopes" => admin_scopes})

    {:ok, access, _, _} = HalC2.Auth.exchange(credential)

    for ttl <- [1_000, 86_400_000] do
      assert {:ok, %{"expiresAt" => _}} = HalC2.Auth.create_pairing_link(%{"ttlMs" => ttl})
    end

    existing = HalC2.Auth.pairing_links()

    for ttl <- [0, 999, 86_400_001, 1.5, "1000", true, %{"seconds" => 1}] do
      assert {:error, :invalid_ttl} = HalC2.Auth.create_pairing_link(%{"ttlMs" => ttl})
    end

    assert HalC2.Auth.pairing_links() == existing

    assert {400, %{"_tag" => "EnvironmentRequestInvalidError"}} =
             request(:post, "http://127.0.0.1:#{port}/api/auth/pairing-token", access, %{
               "ttlMs" => "forever"
             })

    assert {:ok, _} = HalC2.Auth.create_pairing_link(%{})
  end

  # A ticket request reads its session, then inserts the ticket; a revoke between the
  # two must not leave a ticket for the revoked session.
  test "a ticket requested just before its session was revoked is refused", %{path: path} do
    {:ok, access, _, _} = HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(path))
    {:ok, session} = HalC2.Auth.session(access)

    assert HalC2.Auth.revoke_client(session.id)
    assert :error = HalC2.Auth.issue_ticket(session)
  end

  # Before invites had a kind of their own, `Cluster.invite/1` made them as pairing
  # links granting access:write; one still pending at an upgrade must not sign anyone in.
  test "a cluster invite made before the upgrade is no pairing link after it", %{path: path} do
    :ok = stop_supervised(HalC2.Auth)
    token = "legacy-cluster-invite"
    hash = Base.encode16(:crypto.hash(:sha256, token), case: :lower)
    expires = System.system_time(:millisecond) + 300_000
    {:ok, db} = Sqlite3.open(path)

    {:ok, insert} =
      Sqlite3.prepare(
        db,
        "INSERT INTO auth_pairing (token_hash, expires_at, id, label, scopes, created_at) VALUES (?1, ?2, NULL, 'Cluster invite', 'access:write', ?3)"
      )

    :ok = Sqlite3.bind(insert, [hash, expires, System.system_time(:millisecond)])
    :done = Sqlite3.step(db, insert)
    :ok = Sqlite3.release(db, insert)
    Sqlite3.close(db)
    start_supervised!(HalC2.Auth)

    assert HalC2.Auth.exchange(token) == :error
  end

  defp assert_exchange_fails(path, token, opts \\ []) do
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(db, """
      CREATE TRIGGER fail_sessions BEFORE INSERT ON auth_sessions
      BEGIN SELECT RAISE(ABORT, 'busy'); END
      """)

    capture_log(fn ->
      assert {_, {GenServer, :call, _}} = catch_exit(HalC2.Auth.exchange(token))
    end)

    :ok = Sqlite3.execute(db, "DROP TRIGGER fail_sessions")
    Sqlite3.close(db)

    # The crashed server is restarted by its supervisor; the new one reads the store.
    if Keyword.get(opts, :restart, true) do
      :ok = stop_supervised(HalC2.Auth)
      start_supervised!(HalC2.Auth)
    end
  end

  test "an administrator makes pairing links, and sees and revokes paired clients", %{port: port} do
    :ok = stop_supervised(HalC2.Auth)
    :ok = HalC2.Desktop.apply_bootstrap(%{"desktopBootstrapToken" => "desk-token"})
    on_exit(fn -> Application.delete_env(:hal_c2, :desktop_token) end)
    start_supervised!(HalC2.Auth)
    base = "http://127.0.0.1:#{port}"

    exchange = fn token, label ->
      post_form(base <> "/oauth/token", %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token" => token,
        "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
        "client_label" => label
      })
    end

    {200, %{"access_token" => admin}} = exchange.("desk-token", "HAL-C2 Desktop")

    assert {200, %{"id" => link_id, "credential" => credential, "label" => "Phone"}} =
             request(:post, base <> "/api/auth/pairing-token", admin, %{"label" => "Phone"})

    assert {200, [%{"id" => ^link_id, "label" => "Phone"}]} =
             request(:get, base <> "/api/auth/pairing-links", admin)

    # Using the link removes it and pairs a client with standard scopes.
    {200, %{"access_token" => phone}} = exchange.(credential, "Phone")
    assert {200, []} = request(:get, base <> "/api/auth/pairing-links", admin)

    assert {200, clients} = request(:get, base <> "/api/auth/clients", admin)
    assert [%{"current" => true}, %{"current" => false, "sessionId" => phone_session}] = clients

    # A standard client cannot manage access, and nobody can revoke themselves.
    assert {403, %{"_tag" => "EnvironmentScopeRequiredError"}} =
             request(:get, base <> "/api/auth/clients", phone)

    [%{"sessionId" => admin_session} | _] = clients

    assert {403, %{"reason" => "current_session_revoke_not_allowed"}} =
             request(:post, base <> "/api/auth/clients/revoke", admin, %{
               "sessionId" => admin_session
             })

    assert {200, %{"revoked" => true}} =
             request(:post, base <> "/api/auth/clients/revoke", admin, %{
               "sessionId" => phone_session
             })

    assert {200, %{"authenticated" => false}} = request(:get, base <> "/api/auth/session", phone)
  end

  test "an administrator manages pairing links and clients over the socket, as over HTTP",
       %{port: port} do
    admin_scopes = HalC2.Auth.standard_scopes() ++ ~w(access:read access:write relay:write)
    {admin, admin_session} = paired_socket(port, admin_scopes, "Admin")
    {phone, phone_session} = paired_socket(port, HalC2.Auth.standard_scopes(), "Phone")

    # A standard session is refused before anything runs.
    for {method, scope} <- [
          {"hal-c2.createPairingLink", "access:write"},
          {"hal-c2.pairingLinks", "access:read"},
          {"hal-c2.revokePairingLink", "access:write"},
          {"hal-c2.clients", "access:read"},
          {"hal-c2.revokeClient", "access:write"},
          {"hal-c2.revokeOtherClients", "access:write"}
        ],
        reduce: phone do
      phone ->
        {reply, phone} = call(phone, method, %{})
        assert {:error, %{"_tag" => "EnvironmentScopeRequiredError"} = detail} = reply
        assert detail["requiredScope"] == scope
        phone
    end

    input = %{"label" => "Tablet", "scopes" => ["orchestration:read"]}
    {{:ok, link}, admin} = call(admin, "hal-c2.createPairingLink", input)
    assert %{"id" => link_id, "credential" => credential, "label" => "Tablet"} = link
    # With where this MC is reached: its loopback listener, which only this machine reaches.
    assert Enum.sort(Map.keys(link)) == ~w(address credential expiresAt id label localOnly)
    assert %{"address" => "http://127.0.0.1:" <> _, "localOnly" => true} = link

    {{:ok, [listed]}, admin} = call(admin, "hal-c2.pairingLinks", %{})
    assert %{"id" => ^link_id, "scopes" => ["orchestration:read"]} = listed
    refute Map.has_key?(listed, "credential")

    {reply, admin} = call(admin, "hal-c2.revokePairingLink", %{"id" => link_id})
    assert {:ok, %{"revoked" => true}} = reply
    {{:ok, []}, admin} = call(admin, "hal-c2.pairingLinks", %{})
    refute match?({:ok, _, _, _}, HalC2.Auth.exchange(credential, %{"label" => "Tablet"}))

    {{:ok, clients}, admin} = call(admin, "hal-c2.clients", %{})
    assert [^admin_session] = for(%{"current" => true} = c <- clients, do: c["sessionId"])
    assert Enum.any?(clients, &(&1["sessionId"] == phone_session))

    {reply, admin} = call(admin, "hal-c2.revokeClient", %{"sessionId" => admin_session})

    assert {:error,
            %{
              "_tag" => "EnvironmentOperationForbiddenError",
              "reason" => "current_session_revoke_not_allowed"
            }} = reply

    {_laptop, laptop_session} = paired_socket(port, HalC2.Auth.standard_scopes(), "Laptop")
    {reply, admin} = call(admin, "hal-c2.revokeClient", %{"sessionId" => laptop_session})
    assert {:ok, %{"revoked" => true}} = reply

    # The phone is the only other session left.
    {reply, admin} = call(admin, "hal-c2.revokeOtherClients", %{})
    assert {:ok, %{"revokedCount" => 1}} = reply
    assert {{:ok, [%{"sessionId" => ^admin_session}]}, _} = call(admin, "hal-c2.clients", %{})
  end

  test "HTTP pairing links cannot delegate scopes their creator does not hold", %{port: port} do
    {:ok, %{"credential" => credential}} =
      HalC2.Auth.create_pairing_link(%{"scopes" => ["access:write"]})

    {:ok, access, _, _} = HalC2.Auth.exchange(credential)
    base = "http://127.0.0.1:#{port}"
    admin_scopes = HalC2.Auth.standard_scopes() ++ ~w(access:read access:write relay:write)

    for scopes <- [
          nil,
          [],
          ["access:write", "access:write"],
          ["not-a-scope"],
          ["access:write", "terminal:operate"],
          admin_scopes
        ] do
      body = if scopes == nil, do: %{}, else: %{"scopes" => scopes}

      assert {400, %{"_tag" => "EnvironmentRequestInvalidError"}} =
               request(:post, base <> "/api/auth/pairing-token", access, body)
    end

    assert HalC2.Auth.pairing_links() == []

    assert {200, %{"credential" => narrow_credential}} =
             request(:post, base <> "/api/auth/pairing-token", access, %{
               "scopes" => ["access:write"]
             })

    assert {:ok, _, _, ["access:write"]} = HalC2.Auth.exchange(narrow_credential)
  end

  test "socket pairing links cannot delegate scopes their creator does not hold", %{port: port} do
    {narrow, _} = paired_socket(port, ["access:write"], "Narrow")
    admin_scopes = HalC2.Auth.standard_scopes() ++ ~w(access:read access:write relay:write)

    for scopes <- [
          nil,
          [],
          ["access:write", "access:write"],
          ["not-a-scope"],
          ["access:write", "terminal:operate"],
          admin_scopes
        ],
        reduce: narrow do
      narrow ->
        payload = if scopes == nil, do: %{}, else: %{"scopes" => scopes}
        {reply, narrow} = call(narrow, "hal-c2.createPairingLink", payload)
        assert reply == {:error, "invalid pairing link scopes"}
        narrow
    end

    assert HalC2.Auth.pairing_links() == []

    {{:ok, link}, _} =
      call(narrow, "hal-c2.createPairingLink", %{"scopes" => ["access:write"]})

    assert {:ok, _, _, ["access:write"]} = HalC2.Auth.exchange(link["credential"])
  end

  test "forwarded pairing link RPCs validate the socket's scopes", %{port: port, path: path} do
    {narrow, _} = paired_socket(port, ["access:write"], "Narrow")
    :ok = HalC2.Shell.subscribe(self())
    peer = HalC2.Test.Mc.start_peer(%{home: Path.dirname(path)})

    assert_receive {:hal_c2_shell, {:environment, ^peer, %{"environmentId" => peer_environment}}},
                   10_000

    payload = %{
      "scopes" => HalC2.Auth.standard_scopes() ++ ~w(access:read access:write relay:write)
    }

    assert {{:error, "invalid pairing link scopes"}, _} =
             call(narrow, "hal-c2.createPairingLink", payload, peer_environment)

    assert :erpc.call(peer, HalC2.Auth, :pairing_links, []) == []
  end

  test "paired clients are only managed on the MC the caller's session belongs to",
       %{port: port} do
    admin_scopes = HalC2.Auth.standard_scopes() ++ ~w(access:read access:write relay:write)
    {admin, _admin_session} = paired_socket(port, admin_scopes, "Admin")
    {_phone, phone_session} = paired_socket(port, HalC2.Auth.standard_scopes(), "Phone")

    # Another member of the cluster, as its environment reaches the shell.
    member = %{"environmentId" => "env-member", "label" => "Member"}
    send(HalC2.Shell, {:nodeup, :member@nowhere})
    GenServer.cast(HalC2.Shell, {:peer_environment, :member@nowhere, member})
    :sys.get_state(HalC2.Shell)

    for {method, payload} <- [
          {"hal-c2.clients", %{}},
          {"hal-c2.revokeClient", %{"sessionId" => phone_session}},
          {"hal-c2.revokeOtherClients", %{}}
        ],
        reduce: admin do
      admin ->
        {reply, admin} = call(admin, method, payload, "env-member")

        assert {:error,
                %{
                  "_tag" => "EnvironmentOperationForbiddenError",
                  "reason" => "session_on_another_mc"
                }} = reply

        admin
    end

    assert length(HalC2.Auth.clients()) == 2
  end

  test "saving a file by its full path needs terminal:operate, checked before the call is routed",
       %{port: port, tmp_dir: dir} do
    start_supervised!(HalC2.Workspace)
    project = Path.join(dir, "shop")
    File.mkdir_p!(project)
    HalC2.Test.Machines.create_project("shop", "Shop", project)
    outside = Path.join(dir, "notes.txt")
    File.write!(outside, "- buy milk\n")

    {phone, _} =
      paired_socket(port, HalC2.Auth.standard_scopes() -- ["terminal:operate"], "Phone")

    # A member the shell knows but cannot reach: a call routed there would not come back
    # as a scope refusal.
    send(HalC2.Shell, {:nodeup, :member@nowhere})

    GenServer.cast(
      HalC2.Shell,
      {:peer_environment, :member@nowhere, %{"environmentId" => "env-member"}}
    )

    :sys.get_state(HalC2.Shell)

    write = %{"cwd" => project, "relativePath" => outside, "contents" => "rm -rf ~\n"}

    phone =
      for environment <- [HalC2.Environment.id(), "env-member"], reduce: phone do
        phone ->
          {reply, phone} = call(phone, "projects.writeFile", write, environment)

          assert {:error,
                  %{
                    "_tag" => "EnvironmentScopeRequiredError",
                    "requiredScope" => "terminal:operate"
                  }} =
                   reply

          phone
      end

    assert File.read!(outside) == "- buy milk\n"

    {reply, _} = call(phone, "projects.writeFile", %{write | "relativePath" => "src/app.ts"})
    assert {:ok, %{"relativePath" => "src/app.ts"}} = reply

    {terminal, _} = paired_socket(port, HalC2.Auth.standard_scopes(), "Laptop")
    {reply, _} = call(terminal, "projects.writeFile", %{write | "contents" => "- buy eggs\n"})
    assert {:ok, %{"relativePath" => ^outside}} = reply
    assert File.read!(outside) == "- buy eggs\n"
  end

  test "a malformed client report is left out instead of failing the upgrade" do
    assert HalC2.Auth.client_report(%{
             "clientAppVersion" => ["1.0"],
             "clientSurface" => %{"a" => "b"}
           }) ==
             %{surface: nil, app_version: nil}

    assert HalC2.Auth.client_report(%{
             "clientAppVersion" => " 1.2.3 ",
             "clientSurface" => "desktop"
           }) ==
             %{surface: "desktop", app_version: "1.2.3"}
  end

  test "a desktop bootstrap line sets where the MC listens and keeps its state" do
    previous = for key <- [:home, :port, :host], do: {key, Application.fetch_env(:hal_c2, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        with {:ok, value} <- value,
             do: Application.put_env(:hal_c2, key, value),
             else: (:error -> Application.delete_env(:hal_c2, key))
      end
    end)

    :ok =
      HalC2.Desktop.apply_bootstrap(%{
        "port" => 4123,
        "host" => "0.0.0.0",
        "halC2Home" => "/home/me/hal-c2-profile",
        "noBrowser" => true
      })

    assert Application.get_env(:hal_c2, :port) == 4123
    assert Application.get_env(:hal_c2, :host) == "0.0.0.0"
    assert Application.get_env(:hal_c2, :home) == {:root, "/home/me/hal-c2-profile"}
  end

  test "browsers on other origins may call the MC", %{port: port} do
    {:ok, {{_, 204, _}, headers, _}} =
      :httpc.request(:options, {"http://127.0.0.1:#{port}/oauth/token", []}, [], [])

    assert {~c"access-control-allow-origin", ~c"*"} in headers
    assert {_, allowed} = List.keyfind(headers, ~c"access-control-allow-headers", 0)
    assert to_string(allowed) =~ "authorization"
  end

  test "a pairing link opened in a browser explains where to paste it", %{port: port} do
    {:ok, {{_, 200, _}, _, body}} = :httpc.request(~c"http://127.0.0.1:#{port}/?token=abc")
    assert :binary.list_to_bin(body) =~ "Settings → Connections"
  end

  test "rotating or removing the dev credential revokes its sessions, tickets and sockets" do
    on_exit(fn -> Application.delete_env(:hal_c2, :dev_auth_token) end)
    restart_dev_auth("dev-token-a")
    assert {:ok, %{id: old_id}} = HalC2.Auth.session("dev-token-a")
    {:ok, old_ticket, _} = HalC2.Auth.issue_ticket("dev-token-a")
    connect_socket(old_id)
    {:ok, _, _} = HalC2.Auth.subscribe(self())

    restart_dev_auth("dev-token-b")

    assert HalC2.Auth.session("dev-token-a") == :error
    assert HalC2.Auth.take_ticket(old_ticket) == :error
    assert_receive {:socket, {:hal_c2_session_revoked, ^old_id}}

    assert_receive {:hal_c2_auth_access,
                    %{"type" => "clientRemoved", "payload" => %{"sessionId" => ^old_id}}}

    assert {:ok, %{id: new_id}} = HalC2.Auth.session("dev-token-b")
    {:ok, new_ticket, _} = HalC2.Auth.issue_ticket("dev-token-b")
    connect_socket(new_id)

    restart_dev_auth(nil)

    assert HalC2.Auth.session("dev-token-b") == :error
    assert HalC2.Auth.take_ticket(new_ticket) == :error
    assert_receive {:socket, {:hal_c2_session_revoked, ^new_id}}

    assert_receive {:hal_c2_auth_access,
                    %{"type" => "clientRemoved", "payload" => %{"sessionId" => ^new_id}}}
  end

  test "a non-development start removes a seeded dev credential" do
    on_exit(fn ->
      Application.delete_env(:hal_c2, :dev_auth_token)
      System.delete_env("HAL_C2_DEV_AUTH_TOKEN")
    end)

    restart_dev_auth("dev-token-a")
    assert {:ok, _} = HalC2.Auth.session("dev-token-a")
    :ok = stop_supervised(HalC2.Auth)
    System.put_env("HAL_C2_DEV_AUTH_TOKEN", "dev-token-a")
    refute Keyword.has_key?(HalC2.Test.Storage.boot_config(:prod), :dev_auth_token)
    Application.delete_env(:hal_c2, :dev_auth_token)
    start_supervised!(HalC2.Auth)

    assert HalC2.Auth.session("dev-token-a") == :error
  end

  defp restart_dev_auth(token) do
    if token do
      Application.put_env(:hal_c2, :dev_auth_token, token)
    else
      Application.delete_env(:hal_c2, :dev_auth_token)
    end

    server = Process.whereis(HalC2.Auth)
    ref = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    :sys.get_state(HalC2.Auth.Supervisor)
    :sys.get_state(HalC2.Auth)
  end

  defp connect_socket(id) do
    test = self()

    pid =
      spawn_link(fn ->
        HalC2.Auth.connected(id)
        :sys.get_state(HalC2.Auth)
        send(test, {:socket_ready, self()})
        receive do: (message -> send(test, {:socket, message}))
      end)

    assert_receive {:socket_ready, ^pid}
  end

  # A socket opened with a ticket from a session paired with `scopes`, and that session's id.
  defp paired_socket(port, scopes, label) do
    {:ok, %{"credential" => credential}} =
      HalC2.Auth.create_pairing_link(%{"label" => label, "scopes" => scopes})

    {:ok, access, _expires, _scopes} = HalC2.Auth.exchange(credential, %{"label" => label})
    {:ok, session} = HalC2.Auth.session(access)
    {:ok, ticket, _} = HalC2.Auth.issue_ticket(access)
    {:ok, client} = WsClient.connect(port, "/ws?wsTicket=#{ticket}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 1_000)
    {client, session.id}
  end

  # One RPC on this MC's environment: `{:ok, result}` or `{:error, detail or message}`,
  # and the client.
  defp call(client, method, payload, environment \\ HalC2.Environment.id()) do
    id = System.unique_integer([:positive])
    frame = %{"t" => "rpc", "id" => id, "environment" => environment}

    client =
      WsClient.send_json(client, Map.merge(frame, %{"method" => method, "payload" => payload}))

    {frame, _, client} = WsClient.recv_until(client, &(&1["id"] == id and &1["t"] =~ "rpc."))

    reply =
      case frame do
        %{"t" => "rpc.result", "result" => result} -> {:ok, result}
        %{"t" => "rpc.error", "detail" => detail} -> {:error, detail}
        %{"t" => "rpc.error", "error" => error} -> {:error, error}
      end

    {reply, client}
  end

  defp post_form(url, form) do
    body = if is_binary(form), do: form, else: URI.encode_query(form)

    {:ok, {{_, status, _}, _, resp}} =
      :httpc.request(:post, {url, [], ~c"application/x-www-form-urlencoded", body}, [], [])

    {status, JSON.decode!(to_string(resp))}
  end

  defp request(method, url, bearer, body \\ nil) do
    headers = if bearer, do: [{~c"authorization", ~c"Bearer " ++ to_charlist(bearer)}], else: []

    req =
      if method == :post,
        do: {url, headers, ~c"application/json", if(body, do: JSON.encode!(body), else: "")},
        else: {url, headers}

    {:ok, {{_, status, _}, _, resp}} = :httpc.request(method, req, [], [])
    {status, JSON.decode!(to_string(resp))}
  end
end
