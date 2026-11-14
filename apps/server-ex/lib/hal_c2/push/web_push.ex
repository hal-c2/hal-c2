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
  (404, 410: the endpoint is no more; or its host resolves to an address that is not
  public) or `{:retry, reason}` (429, 5xx, DNS, transport).

  The host is resolved once, every address it has must be public, and the request goes
  to the address checked (named by `hostname` for SNI, certificate and `Host`), so DNS
  that answers differently at connect time cannot point it at this machine or its LAN.
  Redirects are not followed. `resolve` stands in for that lookup in tests.
  """
  def post(endpoint, body, urgency, resolve \\ &resolve/1) do
    %URI{scheme: scheme, host: host, port: port, path: path, query: query} =
      URI.parse(endpoint)

    headers = [
      {"content-encoding", "aes128gcm"},
      {"content-type", "application/octet-stream"},
      {"ttl", "600"},
      {"urgency", urgency}
    ]

    case resolve.(host) do
      {:ok, address} ->
        target = if(query, do: "#{path || "/"}?#{query}", else: path || "/")
        # Registrations are https (`HalC2.Push`); a test's phone serves http.
        scheme = if(scheme == "http", do: :http, else: :https)
        request(scheme, address, host, port, target, headers, body)

      :private ->
        :gone

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp request(scheme, address, host, port, target, headers, body) do
    with {:ok, conn} <-
           Mint.HTTP.connect(scheme, address, port,
             hostname: host,
             mode: :passive,
             protocols: [:http1],
             transport_opts: [timeout: 5_000]
           ),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, "POST", target, headers, body) do
      status = await_status(conn, ref, System.monotonic_time(:millisecond) + 10_000)
      Mint.HTTP.close(conn)

      case status do
        status when status in [200, 201, 202] -> :delivered
        status when status in [404, 410] -> :gone
        status when is_integer(status) -> {:retry, status}
        {:error, reason} -> {:retry, reason}
      end
    else
      {:error, reason} -> {:retry, reason}
      {:error, _conn, reason} -> {:retry, reason}
    end
  end

  # The final status: an informational 1xx keeps the request open for the real one.
  defp await_status(conn, ref, deadline) do
    case Mint.HTTP.recv(conn, 0, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, conn, responses} ->
        case Enum.find_value(responses, fn
               {:status, ^ref, status} when status >= 200 -> status
               _ -> nil
             end) do
          nil -> await_status(conn, ref, deadline)
          status -> status
        end

      {:error, _conn, reason, _responses} ->
        {:error, reason}
    end
  end

  @doc """
  The address a request to `host` goes to: `{:ok, address}`, its first IPv4 address,
  else its first IPv6 one, when all of them are public; `:private` when one is not.
  """
  def resolve(host) do
    host = String.to_charlist(host)

    addresses =
      for family <- [:inet, :inet6],
          {:ok, found} <- [:inet.getaddrs(host, family)],
          address <- found,
          do: address

    cond do
      addresses == [] -> {:error, :nxdomain}
      Enum.all?(addresses, &public_address?/1) -> {:ok, hd(addresses)}
      true -> :private
    end
  end

  @doc """
  Whether `address` is on the public internet: not this machine, a private or CGNAT
  (Tailscale) range, link-local, benchmarking, multicast or reserved space, as itself
  or as an IPv4-mapped IPv6 address.
  """
  def public_address?({a, b, _, _}) do
    not (a in [0, 10, 127] or a >= 224 or {a, b} == {169, 254} or
           (a == 172 and b in 16..31) or {a, b} == {192, 168} or
           (a == 100 and b in 64..127) or {a, b} in [{198, 18}, {198, 19}])
  end

  def public_address?({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    public_address?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
  end

  def public_address?({a, b, c, d, e, f, _, _}) do
    not ({a, b, c, d, e, f} == {0, 0, 0, 0, 0, 0} or a in 0xFC00..0xFDFF or
           a in 0xFE80..0xFEBF or a in 0xFF00..0xFFFF)
  end
end
