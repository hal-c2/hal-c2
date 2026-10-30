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
end
