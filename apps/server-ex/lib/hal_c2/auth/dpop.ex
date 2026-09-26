defmodule HalC2.Auth.Dpop do
  @moduledoc """
  DPoP proofs (RFC 9449), as `packages/shared/src/dpop.ts` verifies them: a compact
  ES256 JWT with `typ: dpop+jwt` and the client's P-256 public key in its header,
  claiming the request's method (`htm`), URL without query (`htu`), a unique `jti`,
  `iat` within five minutes and, on resource requests, `ath` (the access token's
  hash). Each proof is accepted once.
  """

  @max_age 300
  @proofs __MODULE__.Proofs

  @doc "Creates the replay table; called by `HalC2.Auth` on start."
  def init, do: :ets.new(@proofs, [:named_table, :public, write_concurrency: true])

  @doc """
  Verifies `proof` for a request; returns `{:ok, thumbprint}` or `{:error, reason}`.
  Options: `thumbprint` (the key the proof must use), `access_token` (for `ath`).
  """
  def verify(proof, method, url, opts \\ []) do
    now = System.os_time(:second)

    with [h, p, sig] when h != "" and p != "" and sig != "" <- String.split(proof || "", "."),
         {:ok, %{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk}} <- decode(h),
         %{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y} when not is_map_key(jwk, "d") <-
           jwk,
         {:ok, %{"htm" => htm, "htu" => htu, "jti" => jti, "iat" => iat} = claims}
         when is_binary(htm) and is_binary(jti) and jti != "" and is_integer(iat) <- decode(p),
         thumbprint = thumbprint(jwk),
         :ok <- check(opts[:thumbprint] in [nil, thumbprint], :key_mismatch),
         :ok <- check(String.upcase(htm) == String.upcase(method), :request_mismatch),
         :ok <- check(htu == htu(url), :request_mismatch),
         :ok <- check(ath_ok?(claims, opts[:access_token]), :token_mismatch),
         :ok <- check(signed?("#{h}.#{p}", sig, x, y), :invalid_proof),
         :ok <- check(iat <= now + 5 and now - iat <= @max_age, :time_window),
         :ok <- check(fresh?(thumbprint, jti, iat, now), :replay) do
      {:ok, thumbprint}
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

  defp fresh?(thumbprint, jti, iat, now) do
    :ets.select_delete(@proofs, [{{:_, :"$1"}, [{:<, :"$1", now - @max_age - 5}], [true]}])
    :ets.insert_new(@proofs, {{thumbprint, jti}, iat})
  end
end
