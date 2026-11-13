defmodule HalC2.Push.WebPushTest do
  use ExUnit.Case, async: true

  alias HalC2.Push.WebPush

  defp b64(text), do: Base.url_decode64!(text, padding: false)

  # RFC 8291, Appendix A.
  @plaintext "When I grow up, I want to be a watermelon"
  @as_public "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
  @as_private "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  @ua_public "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  @ua_private "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
  @salt "DGv6ra1nlYgDCS1FRnbzlw"
  @auth "BTBZMqHH6r4Tts7J_aSIgg"
  @body "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

  test "encrypts the RFC 8291 example message byte for byte" do
    body =
      WebPush.encrypt(@plaintext, b64(@ua_public), b64(@auth),
        keys: {b64(@as_public), b64(@as_private)},
        salt: b64(@salt)
      )

    assert Base.url_encode64(body, padding: false) == @body
  end

  test "the phone decrypts the RFC 8291 example with its private key" do
    assert WebPush.decrypt(b64(@body), b64(@ua_private), b64(@auth)) == {:ok, @plaintext}
  end

  test "each message has its own key and salt and decrypts to what was sent" do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)
    json = ~s({"v":1,"sentAt":1})

    first = WebPush.encrypt(json, public, auth)
    second = WebPush.encrypt(json, public, auth)

    assert first != second
    <<_salt::binary-16, 4096::32, 65, as_public::binary-65, _::binary>> = first
    assert <<4, _::binary-64>> = as_public
    assert WebPush.decrypt(first, private, auth) == {:ok, json}
    assert WebPush.decrypt(second, private, auth) == {:ok, json}
  end

  test "a body for another phone does not decrypt" do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)
    {_other, other_private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)

    assert WebPush.decrypt(WebPush.encrypt("hello", public, auth), other_private, auth) ==
             :error
  end

  describe "post/4" do
    # The request never leaves: an endpoint whose name resolves to this machine is gone.
    test "a host that resolves to a private address is refused before connecting" do
      assert WebPush.resolve("localhost") == :private
      assert WebPush.post("https://localhost:1/push", "body", "normal") == :gone
    end

    # The connection goes to the address checked, under the endpoint's own name, so
    # what DNS answers at connect time does not matter.
    test "the request goes to the resolved address, naming the endpoint's host" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)
      test = self()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, hello} = :gen_tcp.recv(socket, 0, 5_000)
        send(test, {:client_hello, hello})
        :gen_tcp.close(socket)
      end)

      pinned = fn "push.invalid" -> {:ok, {127, 0, 0, 1}} end

      assert {:retry, _} =
               WebPush.post("https://push.invalid:#{port}/p", "body", "normal", pinned)

      assert_receive {:client_hello, hello}, 5_000
      assert hello =~ "push.invalid"
    end

    test "public addresses are the internet's, and the rest are not" do
      for address <- [{8, 8, 8, 8}, {1, 1, 1, 1}, {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}],
          do: assert(WebPush.public_address?(address))

      for address <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {192, 168, 1, 1},
            {169, 254, 169, 254},
            {100, 100, 100, 100},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFD7A, 0x115C, 0xA1E0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
          ],
          do: refute(WebPush.public_address?(address))
    end
  end
end
