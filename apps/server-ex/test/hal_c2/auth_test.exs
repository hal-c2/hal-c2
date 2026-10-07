defmodule HalC2.AuthTest do
  use ExUnit.Case, async: false

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

    input = %{"label" => "Tablet", "scopes" => ["orchestration:read", "not-a-scope"]}
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

  test "paired clients are only managed on the MC the caller's session belongs to",
       %{port: port} do
    admin_scopes = HalC2.Auth.standard_scopes() ++ ~w(access:read access:write relay:write)
    {admin, _admin_session} = paired_socket(port, admin_scopes, "Admin")
    {_phone, phone_session} = paired_socket(port, HalC2.Auth.standard_scopes(), "Phone")

    # Another member of the cluster, as its environment reaches the shell.
    member = %{"environmentId" => "env-member", "label" => "Member"}
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
    body = URI.encode_query(form)

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
