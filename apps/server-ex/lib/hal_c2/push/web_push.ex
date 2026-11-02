defmodule HalC2.Push.WebPush do
  @moduledoc """
  WebPush message encryption (RFC 8291, `Content-Encoding: aes128gcm`, RFC 8188) and
  delivery to a UnifiedPush endpoint.

  Each message gets a fresh ephemeral P-256 key and salt, and goes out as one record of
  size 4096 with the last-record delimiter 0x02. `decrypt/3` is what the phone does with
  its private key and auth secret.
  """

  @record_size 4096

  @doc """
  Encrypts `plaintext` for the user agent's public key `ua_public` (65 bytes) and
  `auth_secret` (16 bytes). `opts` pins `:keys` (`{public, private}`) and `:salt`, for
  the RFC's test vector.
  """
  def encrypt(plaintext, ua_public, auth_secret, opts \\ []) do
    {as_public, as_private} = opts[:keys] || :crypto.generate_key(:ecdh, :prime256v1)
    salt = opts[:salt] || :crypto.strong_rand_bytes(16)

    {cek, nonce} =
      keys(
        :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1),
        ua_public,
        as_public,
        auth_secret,
        salt
      )

    {cipher, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, plaintext <> <<2>>, "", true)

    salt <> <<@record_size::32, byte_size(as_public)::8>> <> as_public <> cipher <> tag
  end

  @doc "Decrypts a body `encrypt/4` made, with the user agent's keys: `{:ok, plaintext}`."
  def decrypt(body, ua_private, auth_secret) do
    <<salt::binary-16, _rs::32, id_len::8, as_public::binary-size(id_len), rest::binary>> = body
    {ua_public, _} = :crypto.generate_key(:ecdh, :prime256v1, ua_private)
    secret = :crypto.compute_key(:ecdh, as_public, ua_private, :prime256v1)
    {cek, nonce} = keys(secret, ua_public, as_public, auth_secret, salt)
    size = byte_size(rest) - 16
    <<cipher::binary-size(^size), tag::binary-16>> = rest

    case :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, cipher, "", tag, false) do
      :error -> :error
      padded -> {:ok, unpad(padded)}
    end
  end

  # The record ends at its last 0x02 delimiter; zeros after it are padding.
  defp unpad(padded) do
    case :binary.last(padded) do
      0 -> unpad(binary_part(padded, 0, byte_size(padded) - 1))
      _delimiter -> binary_part(padded, 0, byte_size(padded) - 1)
    end
  end

  defp keys(ecdh_secret, ua_public, as_public, auth_secret, salt) do
    prk_key = hmac(auth_secret, ecdh_secret)
    ikm = hmac(prk_key, "WebPush: info" <> <<0>> <> ua_public <> as_public <> <<1>>)
    prk = hmac(salt, ikm)
    <<cek::binary-16, _::binary>> = hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)
    <<nonce::binary-12, _::binary>> = hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>)
    {cek, nonce}
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  @doc """
  POSTs an encrypted `body` to `endpoint`. Returns `:delivered` (200, 201, 202), `:gone`
  (404, 410: the endpoint is no more) or `{:retry, reason}` (429, 5xx, transport).
  """
  def post(endpoint, body, urgency) do
    headers = [
      {~c"content-encoding", ~c"aes128gcm"},
      {~c"ttl", ~c"600"},
      {~c"urgency", String.to_charlist(urgency)}
    ]

    request = {String.to_charlist(endpoint), headers, ~c"application/octet-stream", body}

    case :httpc.request(:post, request, http_options(endpoint), body_format: :binary) do
      {:ok, {{_, status, _}, _, _}} when status in [200, 201, 202] -> :delivered
      {:ok, {{_, status, _}, _, _}} when status in [404, 410] -> :gone
      {:ok, {{_, status, _}, _, _}} -> {:retry, status}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp http_options("https:" <> _),
    do: [timeout: 10_000, connect_timeout: 5_000, ssl: :httpc.ssl_verify_host_options(true)]

  defp http_options(_), do: [timeout: 10_000, connect_timeout: 5_000]
end
