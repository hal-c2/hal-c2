defmodule HalC2.Prop.Auth do
  @moduledoc """
  What the `HalC2.Auth` property tests share: a table of the real credentials behind
  the model's integer handles (so a counterexample prints `redeem(3)`, not a token),
  a fixed clock, and DPoP proofs signed with a small pool of P-256 keys.
  """

  alias HalC2.Auth.Dpop

  @table :auth_prop_handles
  @t0 1_700_000_000_000
  @keys 3

  @doc "Creates the handle table, the keys and the clock for one case."
  def setup do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public])

    for k <- 0..(@keys - 1) do
      {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
      :ets.insert(@table, {{:key, k}, pub, priv})
    end

    Application.put_env(:hal_c2, :auth_now, @t0)
    :ok
  end

  def teardown do
    Application.delete_env(:hal_c2, :auth_now)
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ok
  end

  def t0, do: @t0
  def key_count, do: @keys

  def put(key, value), do: :ets.insert(@table, {key, value})

  def get(key) do
    [{_, value}] = :ets.lookup(@table, key)
    value
  end

  def get(key, default) do
    case :ets.lookup(@table, key) do
      [{_, value}] -> value
      [] -> default
    end
  end

  def advance(ms), do: Application.put_env(:hal_c2, :auth_now, HalC2.Auth.now() + ms)

  @doc "The RFC 7638 thumbprint of key `k`."
  def thumbprint(k) do
    [{_, pub, _}] = :ets.lookup(@table, {:key, k})
    pub |> jwk() |> Dpop.thumbprint()
  end

  defp jwk(<<4, x::binary-32, y::binary-32>>) do
    %{"kty" => "EC", "crv" => "P-256", "x" => b64(x), "y" => b64(y)}
  end

  @doc """
  A proof signed for key `k`, naming `token`, made at the current time plus `offset`
  seconds. `variant` breaks one thing: `:wrong_method`, `:wrong_url`, `:wrong_ath`,
  or `:forged` (signed by the next key while claiming `k`'s).
  """
  def proof(k, token, jti, offset, variant, method, url) do
    [{_, pub, _}] = :ets.lookup(@table, {:key, k})
    [{_, _, signer}] = :ets.lookup(@table, {:key, rem(k + 1, @keys)})
    [{_, _, own}] = :ets.lookup(@table, {:key, k})

    header = %{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk(pub)}

    claims = %{
      "htm" => if(variant == :wrong_method, do: "DELETE", else: method),
      "htu" => if(variant == :wrong_url, do: url <> "/other", else: Dpop.htu(url)),
      "jti" => jti,
      "iat" => div(HalC2.Auth.now(), 1000) + offset,
      "ath" => Dpop.ath(if(variant == :wrong_ath, do: token <> "x", else: token))
    }

    input = b64(JSON.encode!(header)) <> "." <> b64(JSON.encode!(claims))
    key = if variant == :forged, do: signer, else: own
    der = :crypto.sign(:ecdsa, :sha256, input, [key, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64(<<r::256, s::256>>)
  end

  defp b64(data), do: Base.url_encode64(data, padding: false)
end
