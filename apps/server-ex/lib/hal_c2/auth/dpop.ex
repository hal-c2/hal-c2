defmodule HalC2.Auth.Dpop do
  @moduledoc """
  DPoP proofs (RFC 9449), as `packages/shared/src/dpop.ts` verifies them: a compact
  ES256 JWT with `typ: dpop+jwt` and the client's P-256 public key in its header,
  claiming the request's method (`htm`), URL without query (`htu`), a unique `jti`,
  `iat` within five minutes and, on resource requests, `ath` (the access token's
  hash). Each proof is accepted once.
  """

  @max_age 300
  # UUIDs and encoded hashes fit comfortably; retained replay identifiers do not need more.
  @max_jti_bytes 256
  @proofs __MODULE__.Proofs

  @doc "The replay table, which `HalC2.Auth` creates and keeps across its restarts."
  def table, do: @proofs

  @doc """
  Verifies and claims `proof` for a request; returns `{:ok, thumbprint}` or
  `{:error, reason}`. Options: `thumbprint` (the key the proof must use), `access_token`
  (for `ath`).
  """
  def verify(proof, method, url, opts \\ []) do
    with {:ok, verified} <- verify_unclaimed(proof, method, url, opts),
         :ok <- claim(verified) do
      {:ok, verified.thumbprint}
    end
  end

  @doc """
  Verifies `proof` without claiming its replay identity. The caller must pass the returned
  identity to `claim/1` once the operation it authorizes is known to be valid.
  """
  def verify_unclaimed(proof, method, url, opts \\ []) do
    now = div(HalC2.Auth.now(), 1000)

    with [h, p, sig] when h != "" and p != "" and sig != "" <- String.split(proof || "", "."),
         {:ok, %{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk}} <- decode(h),
         %{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y} when not is_map_key(jwk, "d") <-
           jwk,
         {:ok, %{"htm" => htm, "htu" => htu, "jti" => jti, "iat" => iat} = claims}
         when is_binary(htm) and is_binary(jti) and byte_size(jti) > 0 and
                byte_size(jti) <= @max_jti_bytes and is_integer(iat) <- decode(p),
         thumbprint = thumbprint(jwk),
         :ok <- check(opts[:thumbprint] in [nil, thumbprint], :key_mismatch),
         :ok <- check(String.upcase(htm) == String.upcase(method), :request_mismatch),
         :ok <- check(htu == htu(url), :request_mismatch),
         :ok <- check(ath_ok?(claims, opts[:access_token]), :token_mismatch),
         :ok <- check(signed?("#{h}.#{p}", sig, x, y), :invalid_proof),
         :ok <- check(iat <= now + 5 and now - iat <= @max_age, :time_window) do
      {:ok, %{thumbprint: thumbprint, jti: jti, iat: iat}}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_proof}
    end
  end

  @doc "A request URL as proofs name it: no query or fragment."
  def htu(url), do: %{URI.parse(url) | query: nil, fragment: nil} |> URI.to_string()

  @doc "The RFC 7638 thumbprint of a P-256 public JWK."
  def thumbprint(%{"crv" => crv, "kty" => kty, "x" => x, "y" => y}) do
    :crypto.hash(:sha256, ~s({"crv":"#{crv}","kty":"#{kty}","x":"#{x}","y":"#{y}"}))
    |> Base.url_encode64(padding: false)
  end

  @doc "The `ath` claim for an access token."
  def ath(access_token),
    do: :crypto.hash(:sha256, access_token) |> Base.url_encode64(padding: false)

  defp ath_ok?(_claims, nil), do: true
  defp ath_ok?(claims, token), do: claims["ath"] == ath(token)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp decode(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false), do: JSON.decode(json)
  end

  # The signature is JOSE's raw r || s; `:crypto` wants DER.
  defp signed?(input, sig, x, y) do
    with {:ok, <<r::256, s::256>>} <- Base.url_decode64(sig, padding: false),
         {:ok, <<_::binary-32>> = x} <- Base.url_decode64(x, padding: false),
         {:ok, <<_::binary-32>> = y} <- Base.url_decode64(y, padding: false) do
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
      :crypto.verify(:ecdsa, :sha256, input, der, [<<4, x::binary, y::binary>>, :secp256r1])
    else
      _ -> false
    end
  end

  @doc "Atomically claims a verified proof's replay identity, or refuses a replay."
  def claim(nil), do: :ok

  def claim(%{thumbprint: thumbprint, jti: jti, iat: iat}) do
    if :ets.insert_new(@proofs, {{thumbprint, jti}, iat}),
      do: :ok,
      else: {:error, :replay}
  end

  @doc "Forgets proofs too old to be accepted again; returns how many."
  def prune(now \\ div(HalC2.Auth.now(), 1000)),
    do: :ets.select_delete(@proofs, [{{:_, :"$1"}, [{:<, :"$1", now - @max_age - 5}], [true]}])
end
