defmodule HalC2.AuthRenewTest do
  use ExUnit.Case, async: false

  alias HalC2.Auth
  alias HalC2.Auth.Dpop
  alias HalC2.Test.Mc

  @moduletag :tmp_dir
  @path "/api/auth/session/renew"

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :port, 0)
    # A fixed clock, so expiries compare exactly.
    now = System.os_time(:millisecond)
    Application.put_env(:hal_c2, :auth_now, now)
    on_exit(fn -> Application.delete_env(:hal_c2, :auth_now) end)
    :persistent_term.erase({HalC2.Web, :token})
    store = Path.join(dir, "hal-c2.sqlite")
    start_supervised!({HalC2.Store, path: store})
    start_supervised!(Auth)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(HalC2.Web))
    {:ok, _} = Application.ensure_all_started(:inets)
    %{mc: %{port: port, store: store}, now: now}
  end

  test "renewing a bearer session gives it 30 more days, keeping its token, tickets and sockets",
       %{mc: mc, now: now} do
    access = pair(mc)
    {:ok, %{id: id}} = Auth.session(access)
    set_expiry(mc, access, now + :timer.hours(1))

    assert {200, _, %{"ticket" => ticket}} =
             Mc.request(mc, :post, "/api/auth/websocket-ticket", bearer: access)

    socket = registered_socket(id)
    {:ok, _, _} = Auth.subscribe(self())

    expected = now + :timer.hours(24 * 30)
    assert {200, _, %{"expiresAt" => iso}} = Mc.request(mc, :post, @path, bearer: access)
    assert ms(iso) == expected
    assert {:ok, %{id: ^id, expires_at: ^expected}} = Auth.session(access)

    assert_receive {:hal_c2_auth_access,
                    %{"type" => "clientUpserted", "payload" => %{"sessionId" => ^id} = payload}}

    assert ms(payload["expiresAt"]) == expected
    assert {:ok, ^id} = Auth.take_ticket(ticket)
    send(socket, {:report, self()})
    assert_receive {:socket_mail, []}
  end

  test "renewing never shortens a session", %{mc: mc, now: now} do
    access = pair(mc)
    later = now + :timer.hours(24 * 365)
    set_expiry(mc, access, later)

    assert {200, _, %{"expiresAt" => iso}} = Mc.request(mc, :post, @path, bearer: access)
    assert ms(iso) == later
    assert {:ok, %{expires_at: ^later}} = Auth.session(access)
  end

  test "a DPoP-bound session renews for an hour with a fresh proof", %{mc: mc, now: now} do
    key = dpop_key()
    pairing = Auth.create_pairing_token(mc.store)

    assert {200, _, %{"access_token" => access, "token_type" => "DPoP"}} =
             Mc.request(mc, :post, "/oauth/token",
               form: %{
                 "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
                 "subject_token" => pairing,
                 "subject_token_type" =>
                   "urn:hal-c2:params:oauth:token-type:environment-bootstrap"
               },
               headers: [{"dpop", dpop_proof(key, "POST", url(mc, "/oauth/token"))}]
             )

    set_expiry(mc, access, now + :timer.minutes(10))
    proof = dpop_proof(key, "POST", url(mc, @path), access: access)
    headers = [{"authorization", "DPoP #{access}"}, {"dpop", proof}]

    assert {200, _, %{"expiresAt" => iso}} = Mc.request(mc, :post, @path, headers: headers)
    assert ms(iso) == now + :timer.hours(1)

    # Sent as a bearer, a bound token is refused, and so is a replayed proof.
    assert {401, _, %{"code" => "auth_invalid"}} = Mc.request(mc, :post, @path, bearer: access)

    assert {401, _, %{"dpopFailureReason" => "replay"}} =
             Mc.request(mc, :post, @path, headers: headers)
  end

  test "an expired or revoked session is refused as auth_invalid", %{mc: mc, now: now} do
    expired = pair(mc)
    set_expiry(mc, expired, now - 1)

    assert {401, _, %{"_tag" => "EnvironmentAuthInvalidError", "code" => "auth_invalid"}} =
             Mc.request(mc, :post, @path, bearer: expired)

    revoked = pair(mc)
    {:ok, %{id: id}} = Auth.session(revoked)
    assert Auth.revoke_client(id)

    assert {401, _, %{"code" => "auth_invalid", "reason" => "invalid_credential"}} =
             Mc.request(mc, :post, @path, bearer: revoked)

    assert {401, _, %{"reason" => "missing_credential"}} = Mc.request(mc, :post, @path)
  end

  test "a session revoked after its request was authenticated is not renewed", %{mc: mc} do
    access = pair(mc)
    {:ok, session} = Auth.session(access)
    assert Auth.revoke_client(session.id)
    assert Auth.renew(session) == :error
  end

  # --- helpers -----------------------------------------------------------------

  defp pair(mc) do
    assert {200, %{"access_token" => access}} =
             Mc.exchange(mc, Auth.create_pairing_token(mc.store))

    access
  end

  defp set_expiry(mc, access, ms) do
    {:ok, db} = Exqlite.Sqlite3.open(mc.store)

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        db,
        "UPDATE auth_sessions SET expires_at = ?1 WHERE token_hash = ?2"
      )

    :ok =
      Exqlite.Sqlite3.bind(stmt, [ms, Base.encode16(:crypto.hash(:sha256, access), case: :lower)])

    :done = Exqlite.Sqlite3.step(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
  end

  # A process registered as an open socket of `id`; it reports the mail it got.
  defp registered_socket(id) do
    parent = self()

    pid =
      spawn_link(fn ->
        Auth.connected(id)
        send(parent, :connected)
        socket_loop([])
      end)

    assert_receive :connected
    _ = :sys.get_state(Auth)
    pid
  end

  defp socket_loop(mail) do
    receive do
      {:report, to} -> send(to, {:socket_mail, Enum.reverse(mail)})
      other -> socket_loop([other | mail])
    end
  end

  defp ms(iso) do
    {:ok, at, 0} = DateTime.from_iso8601(iso)
    DateTime.to_unix(at, :millisecond)
  end

  defp dpop_key do
    {<<4, x::binary-32, y::binary-32>>, private} = :crypto.generate_key(:ecdh, :secp256r1)
    b64 = &Base.url_encode64(&1, padding: false)
    {%{"kty" => "EC", "crv" => "P-256", "x" => b64.(x), "y" => b64.(y)}, private}
  end

  defp dpop_proof({jwk, private}, method, url, opts \\ []) do
    b64 = &Base.url_encode64(&1, padding: false)
    header = b64.(JSON.encode!(%{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk}))

    claims =
      %{
        "htm" => method,
        "htu" => url,
        "jti" => Base.encode16(:crypto.strong_rand_bytes(8)),
        "iat" => div(Auth.now(), 1000)
      }
      |> then(&if(opts[:access], do: Map.put(&1, "ath", Dpop.ath(opts[:access])), else: &1))

    input = header <> "." <> b64.(JSON.encode!(claims))
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64.(<<r::256, s::256>>)
  end

  defp url(mc, path), do: "http://127.0.0.1:#{mc.port}#{path}"
end
