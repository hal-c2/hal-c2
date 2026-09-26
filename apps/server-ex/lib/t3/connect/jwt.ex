defmodule T3.Connect.Jwt do
  @moduledoc """
  The signatures T3 Connect trades in: Ed25519 (`EdDSA`) JWTs between the node and
  the relay, and the P-256 DPoP proofs (RFC 9449) devices bind credentials with.
  Keys travel as PEM (SPKI / PKCS8) as the Node server writes them.
  """

  @spki_prefix Base.decode16!("302A300506032B6570032100")
  @pkcs8_prefix Base.decode16!("302E020100300506032B657004220420")
  @key_pair "cloud-link-ed25519-key-pair"

  @max_age 300
  @clock_tolerance 60

  @doc "A compact EdDSA JWT of `payload` with header `typ`."
  def sign(payload, typ, private) do
    header = b64(JSON.encode!(%{"alg" => "EdDSA", "typ" => typ}))
    body = b64(JSON.encode!(payload))
    input = header <> "." <> body
    input <> "." <> b64(:crypto.sign(:eddsa, :none, input, [private, :ed25519]))
  end

  @doc """
  Verifies an EdDSA JWT of `typ` from `public` for issuer `iss` and audience `aud`,
  within five minutes of issue and a minute of clock skew: `{:ok, payload}` or `:error`.
  """
  def verify(token, typ, public, iss, aud, now \\ System.os_time(:second)) do
    with [h, p, s] <- String.split(token || "", "."),
         {:ok, %{"alg" => "EdDSA", "typ" => ^typ}} <- decode(h),
         {:ok, %{} = payload} <- decode(p),
         {:ok, sig} <- Base.url_decode64(s, padding: false),
         true <- :crypto.verify(:eddsa, :none, h <> "." <> p, sig, [public, :ed25519]),
         %{"iss" => ^iss, "aud" => ^aud, "iat" => iat, "exp" => exp}
         when is_integer(iat) and is_integer(exp) <- payload,
         true <- iat <= now + @clock_tolerance and now - iat <= @max_age + @clock_tolerance,
         true <- exp + @clock_tolerance >= now do
      {:ok, payload}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "The node's own link key pair `{public, private}` (raw), made on first use."
  def key_pair do
    case T3.Connect.Secrets.get(@key_pair) do
      nil ->
        {public, private} = :crypto.generate_key(:eddsa, :ed25519)

        pair = %{
          "privateKey" => pem(:PrivateKeyInfo, @pkcs8_prefix <> private),
          "publicKey" => public_pem(public)
        }

        :ok = T3.Connect.Secrets.put(@key_pair, JSON.encode!(pair))
        {public, private}

      json ->
        %{"privateKey" => private, "publicKey" => public} = JSON.decode!(json)
        {:ok, public} = raw_public(public)
        {:ok, private} = raw(private, :PrivateKeyInfo, @pkcs8_prefix)
        {public, private}
    end
  end

  def public_pem(public), do: pem(:SubjectPublicKeyInfo, @spki_prefix <> public)

  @doc "The raw Ed25519 key of an SPKI PEM: `{:ok, raw}` or `:error`."
  def raw_public(pem), do: raw(pem, :SubjectPublicKeyInfo, @spki_prefix)

  defp raw(pem, type, prefix) do
    case :public_key.pem_decode(pem || "") do
      [{^type, der, _}] when der == prefix <> binary_part(der, byte_size(prefix), 32) ->
        {:ok, binary_part(der, byte_size(prefix), 32)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp pem(type, der), do: String.trim(:public_key.pem_encode([{type, der, :not_encrypted}]))

  # --- DPoP ---------------------------------------------------------------------

  @doc """
  Checks a DPoP proof for `method` and `url`: `{:ok, %{thumbprint, jti}}` or
  `{:error, code}` (`packages/shared/src/dpop.ts`).
  """
  def verify_dpop(proof, method, url, now \\ System.os_time(:second)) do
    with [h, p, s] <- String.split(proof || "", "."),
         {:ok, %{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk}} <- decode(h),
         {:ok, %{"htm" => htm, "htu" => htu, "jti" => jti, "iat" => iat}}
         when is_integer(iat) and is_binary(jti) <- decode(p),
         {:ok, point} <- ec_point(jwk),
         :ok <- check(String.upcase(htm) == String.upcase(method), :method_mismatch),
         :ok <- check(htu == htu(url), :url_mismatch),
         {:ok, <<r::256, s::256>>} <- Base.url_decode64(s, padding: false),
         der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s}),
         :ok <-
           check(
             :crypto.verify(:ecdsa, :sha256, h <> "." <> p, der, [point, :secp256r1]),
             :invalid_signature
           ),
         :ok <- check(iat <= now + 5 and now - iat <= @max_age, :time_window) do
      {:ok, %{thumbprint: thumbprint(jwk), jti: jti}}
    else
      {:error, code} when is_atom(code) -> {:error, code}
      _ -> {:error, :malformed_proof}
    end
  rescue
    _ -> {:error, :invalid_proof}
  end

  @doc "The RFC 7638 thumbprint of a P-256 JWK."
  def thumbprint(%{"crv" => crv, "kty" => kty, "x" => x, "y" => y}) do
    canonical =
      ~s({"crv":#{JSON.encode!(crv)},"kty":#{JSON.encode!(kty)},"x":#{JSON.encode!(x)},"y":#{JSON.encode!(y)}})

    b64(:crypto.hash(:sha256, canonical))
  end

  # A proof names the URL without its query or fragment.
  defp htu(url) do
    uri = URI.parse(url)
    URI.to_string(%{uri | query: nil, fragment: nil})
  end

  defp ec_point(%{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y}) do
    with {:ok, <<_::binary-size(32)>> = x} <- Base.url_decode64(x, padding: false),
         {:ok, <<_::binary-size(32)>> = y} <- Base.url_decode64(y, padding: false),
         do: {:ok, <<4, x::binary, y::binary>>}
  end

  defp ec_point(_), do: :error

  defp check(true, _code), do: :ok
  defp check(_, code), do: {:error, code}

  def b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp decode(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false), do: JSON.decode(json)
  end
end
