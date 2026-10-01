defmodule HalC2.Connect.Jwt do
  @moduledoc """
  The signatures HAL-C2 Connect trades in: Ed25519 (`EdDSA`) JWTs between the MC and
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

  @doc "The MC's own link key pair `{public, private}` (raw), made on first use."
  def key_pair do
    case HalC2.Connect.Secrets.get(@key_pair) do
      nil ->
        {public, private} = :crypto.generate_key(:eddsa, :ed25519)

        pair = %{
          "privateKey" => pem(:PrivateKeyInfo, @pkcs8_prefix <> private),
          "publicKey" => public_pem(public)
        }

        :ok = HalC2.Connect.Secrets.put(@key_pair, JSON.encode!(pair))
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

  # --- DPoP (proofs are checked by `HalC2.Auth.Dpop`) --------------------------------

  @doc "The RFC 7638 thumbprint of a P-256 JWK."
  def thumbprint(%{"crv" => crv, "kty" => kty, "x" => x, "y" => y}) do
    canonical =
      ~s({"crv":#{JSON.encode!(crv)},"kty":#{JSON.encode!(kty)},"x":#{JSON.encode!(x)},"y":#{JSON.encode!(y)}})

    b64(:crypto.hash(:sha256, canonical))
  end

  def b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp decode(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false), do: JSON.decode(json)
  end
end
