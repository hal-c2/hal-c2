defmodule HalC2.AuthDpopTest do
  use ExUnit.Case, async: false

  alias HalC2.Auth
  alias HalC2.Auth.Dpop
  alias HalC2.Test.Mc

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :port, 0)
    :persistent_term.erase({HalC2.Web, :token})
    store = Path.join(dir, "hal-c2.sqlite")
    start_supervised!({HalC2.Store, path: store})
    start_supervised!(Auth)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(HalC2.Web))
    {:ok, _} = Application.ensure_all_started(:inets)
    %{mc: %{port: port, store: store}}
  end

  test "a rejected grant neither claims a proof nor prunes the replay table", %{mc: mc} do
    key = dpop_key()
    proof = dpop_proof(key, "POST", url(mc, "/oauth/token"))
    old_iat = div(Auth.now(), 1000) - 306
    :ets.insert(Dpop.table(), {{"old", "proof"}, old_iat})

    assert {400, _, %{"error" => "invalid_grant"}} = exchange(mc, "not-a-grant", proof)
    assert :ets.lookup(Dpop.table(), {"old", "proof"}) == [{{"old", "proof"}, old_iat}]
    assert :ets.info(Dpop.table(), :size) == 1

    assert %{proofs: 1} = Auth.prune()
    assert :ets.info(Dpop.table(), :size) == 0
  end

  test "empty and overlong proof identifiers are rejected without spending the grant", %{mc: mc} do
    key = dpop_key()
    pairing = Auth.create_pairing_token(mc.store)

    for jti <- ["", String.duplicate("j", 257)] do
      proof = dpop_proof(key, "POST", url(mc, "/oauth/token"), jti: jti)

      assert {401, _, %{"dpopFailureReason" => "invalid_proof"}} =
               exchange(mc, pairing, proof)
    end

    assert :ets.info(Dpop.table(), :size) == 0
    assert {200, %{"access_token" => _}} = Mc.exchange(mc, pairing)
  end

  test "one proof cannot win two concurrent valid exchanges", %{mc: mc} do
    :ok = stop_supervised(Auth)
    Application.put_env(:hal_c2, :desktop_token, "desktop-token")
    on_exit(fn -> Application.delete_env(:hal_c2, :desktop_token) end)
    start_supervised!(Auth)
    key = dpop_key()
    proof = dpop_proof(key, "POST", url(mc, "/oauth/token"))

    responses =
      [
        Task.async(fn -> exchange(mc, "desktop-token", proof) end),
        Task.async(fn -> exchange(mc, "desktop-token", proof) end)
      ]
      |> Enum.map(&Task.await/1)
      |> Enum.sort_by(&elem(&1, 0))

    assert [{200, _, %{"token_type" => "DPoP"}}, {401, _, %{"dpopFailureReason" => "replay"}}] =
             responses

    assert {401, _, %{"dpopFailureReason" => "replay"}} =
             exchange(mc, "desktop-token", proof)

    assert :ets.info(Dpop.table(), :size) == 1
    fresh = dpop_proof(key, "POST", url(mc, "/oauth/token"))
    assert {200, _, %{"token_type" => "DPoP"}} = exchange(mc, "desktop-token", fresh)
    assert :ets.info(Dpop.table(), :size) == 2
  end

  test "DPoP exchange and authenticated requests keep replay protection", %{mc: mc} do
    key = dpop_key()
    pairing = Auth.create_pairing_token(mc.store)
    exchange_proof = dpop_proof(key, "POST", url(mc, "/oauth/token"))

    assert {200, _, %{"access_token" => access, "token_type" => "DPoP", "expires_in" => 3600}} =
             exchange(mc, pairing, exchange_proof)

    path = "/api/auth/websocket-ticket"
    request_proof = dpop_proof(key, "POST", url(mc, path), access: access)
    headers = [{"authorization", "DPoP #{access}"}, {"dpop", request_proof}]

    assert {200, _, %{"ticket" => _}} = Mc.request(mc, :post, path, headers: headers)

    assert {401, _, %{"dpopFailureReason" => "replay"}} =
             Mc.request(mc, :post, path, headers: headers)
  end

  test "a legacy ticket needs its session's DPoP proof for RPC but not media", %{mc: mc} do
    key = dpop_key()
    pairing = Auth.create_pairing_token(mc.store)
    exchange_proof = dpop_proof(key, "POST", url(mc, "/oauth/token"))

    assert {200, _, %{"access_token" => access, "token_type" => "DPoP"}} =
             exchange(mc, pairing, exchange_proof)

    path = "/api/auth/websocket-ticket"
    request_proof = dpop_proof(key, "POST", url(mc, path), access: access)

    assert {200, _, %{"ticket" => ticket}} =
             Mc.request(mc, :post, path,
               headers: [{"authorization", "DPoP #{access}"}, {"dpop", request_proof}]
             )

    assert {:ok, _} = Auth.ticket_scopes(ticket)
    assert Auth.take_ticket(ticket) == :error

    socket_url = url(mc, "/ws?wsTicket=#{ticket}")
    socket_proof = dpop_proof(key, "GET", url(mc, "/ws"), access: ticket)
    assert {:ok, id} = Auth.take_ticket(ticket, {socket_proof, "GET", socket_url})
    assert {:ok, %{id: ^id}} = Auth.session(access)
  end

  test "the DPoP scheme is read in any letter case and refusals challenge for DPoP", %{mc: mc} do
    key = dpop_key()
    pairing = Auth.create_pairing_token(mc.store)
    exchange_proof = dpop_proof(key, "POST", url(mc, "/oauth/token"))

    assert {200, _, %{"access_token" => access, "token_type" => "DPoP"}} =
             exchange(mc, pairing, exchange_proof)

    path = "/api/auth/websocket-ticket"

    for scheme <- ["DPoP", "dpop", "DPOP"] do
      proof = dpop_proof(key, "POST", url(mc, path), access: access)

      assert {200, _, %{"ticket" => _}} =
               Mc.request(mc, :post, path,
                 headers: [{"authorization", "#{scheme} #{access}"}, {"dpop", proof}]
               ),
             "scheme #{scheme} should authenticate"

      assert {401, headers, %{"reason" => "invalid_credential"}} =
               Mc.request(mc, :post, path, headers: [{"authorization", "#{scheme} #{access}"}]),
             "scheme #{scheme} without a proof should be refused"

      assert {"www-authenticate", "DPoP"} in headers,
             "scheme #{scheme} refusal should challenge for DPoP, got: #{inspect(headers)}"
    end

    # A Bearer refusal is not a DPoP challenge.
    assert {401, headers, _} = Mc.request(mc, :post, path, bearer: access)
    refute {"www-authenticate", "DPoP"} in headers
  end

  defp exchange(mc, token, proof) do
    Mc.request(mc, :post, "/oauth/token",
      form: %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token" => token,
        "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap"
      },
      headers: [{"dpop", proof}]
    )
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
        "jti" => opts[:jti] || Base.encode16(:crypto.strong_rand_bytes(8)),
        "iat" => System.os_time(:second)
      }
      |> then(&if(opts[:access], do: Map.put(&1, "ath", Dpop.ath(opts[:access])), else: &1))

    input = header <> "." <> b64.(JSON.encode!(claims))
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64.(<<r::256, s::256>>)
  end

  defp url(mc, path), do: "http://127.0.0.1:#{mc.port}#{path}"
end
