defmodule HalC2.Cluster.Join do
  @moduledoc """
  The two messages of a cluster join. The inviter first signs a challenge with the
  certificate the invite pins. Only then does the joiner encrypt its certificate and
  entry to that key, sign them with its own cluster key, and prove the invite with an
  HMAC whose key is the invite's stored SHA-256. The secret itself never goes out.
  """

  import X509.ASN1

  @p256 {1, 2, 840, 10045, 3, 1, 7}
  @inviter_domain "hal-c2.cluster.join.inviter.v1"
  @joiner_domain "hal-c2.cluster.join.member.v1"
  @encryption_domain "hal-c2.cluster.join.encryption.v1"
  @key_domain "hal-c2.cluster.join.key.v1"
  @proof_domain "hal-c2.cluster.join.invite.v1"

  @doc "Starts a join without describing the joining machine."
  def challenge(invite) when is_binary(invite) and invite != "" do
    {ephemeral, private} = :crypto.generate_key(:ecdh, :secp256r1)
    nonce = :crypto.strong_rand_bytes(32)

    request = %{
      "invite" => invite,
      "nonce" => encode(nonce),
      "ephemeralKey" => encode(ephemeral)
    }

    {:ok, request, %{nonce: nonce, ephemeral: ephemeral, private: private}}
  end

  def challenge(_invite), do: {:error, :invalid_link}

  @doc "Answers a challenge with the inviter's certificate and its signature."
  def answer(request, cert, key) do
    with {:ok, invite, joiner_nonce, ephemeral} <- request_parts(request),
         {:ok, cert_der} <- certificate_der(cert),
         {:ok, _private} <- private_key(key) do
      inviter_nonce = :crypto.strong_rand_bytes(32)

      message =
        inviter_message(invite, joiner_nonce, ephemeral, inviter_nonce, cert_der)

      {:ok,
       %{
         "certificate" => encode(cert_der),
         "nonce" => encode(inviter_nonce),
         "signature" => encode(:public_key.sign(message, :sha256, key))
       }}
    end
  end

  @doc """
  Authenticates an inviter's answer, then seals the joiner's certificate and entry for
  it. No certificate or entry leaves this function unless the answer's certificate has
  the invite's fingerprint and its signature covers this exact challenge.
  """
  def seal(request, answer, token, pin, entry, joiner_cert, joiner_key, private) do
    with {:ok, invite, joiner_nonce, ephemeral} <- request_parts(request),
         %{private: ephemeral_private} <- private,
         {:ok, cert_der} <- decode(answer, "certificate"),
         {:ok, inviter_nonce} <- decode(answer, "nonce", 32),
         {:ok, signature} <- decode(answer, "signature"),
         cert = X509.Certificate.from_der!(cert_der),
         true <- fingerprint(cert_der) == pin,
         message = inviter_message(invite, joiner_nonce, ephemeral, inviter_nonce, cert_der),
         true <-
           :public_key.verify(message, :sha256, signature, X509.Certificate.public_key(cert)),
         {:ok, inviter_point} <- public_point(cert),
         {:ok, joiner_der} <- certificate_der(joiner_cert),
         {:ok, _private} <- private_key(joiner_key),
         {:ok, encryption_nonce} <- random_nonce(),
         shared = :crypto.compute_key(:ecdh, inviter_point, ephemeral_private, :secp256r1),
         common = [invite, joiner_nonce, inviter_nonce, ephemeral, cert_der, encryption_nonce],
         key = encryption_key(shared, common),
         plaintext = JSON.encode!(%{"certificate" => encode(joiner_der), "entry" => entry}),
         aad = pack([@encryption_domain | common]),
         {ciphertext, tag} <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             encryption_nonce,
             plaintext,
             aad,
             true
           ),
         member_message = member_message(common, ciphertext, tag),
         signature = :public_key.sign(member_message, :sha256, joiner_key),
         proof_message = proof_message(common, ciphertext, tag, signature),
         proof = :crypto.mac(:hmac, :sha256, :crypto.hash(:sha256, token), proof_message) do
      {:ok,
       request
       |> Map.merge(%{
         "inviterCertificate" => encode(cert_der),
         "inviterNonce" => encode(inviter_nonce),
         "encryptionNonce" => encode(encryption_nonce),
         "ciphertext" => encode(ciphertext),
         "tag" => encode(tag),
         "signature" => encode(signature),
         "proof" => encode(proof)
       })}
    else
      false -> {:error, :wrong_machine}
      nil -> {:error, :wrong_machine}
      {:error, _} = error -> error
      _ -> {:error, :wrong_machine}
    end
  rescue
    _ -> {:error, :wrong_machine}
  end

  @doc """
  Opens an admission with the inviter's key and verifies the joiner's certificate,
  signature, and claimed fingerprint. The returned proof message is what Auth checks
  before consuming the one-time invite.
  """
  def open(admission, inviter_cert, inviter_key) do
    with {:ok, invite, joiner_nonce, ephemeral} <- request_parts(admission),
         {:ok, cert_der} <- decode(admission, "inviterCertificate"),
         {:ok, own_der} <- certificate_der(inviter_cert),
         true <- cert_der == own_der,
         {:ok, inviter_nonce} <- decode(admission, "inviterNonce", 32),
         {:ok, encryption_nonce} <- decode(admission, "encryptionNonce", 12),
         {:ok, ciphertext} <- decode(admission, "ciphertext"),
         {:ok, tag} <- decode(admission, "tag", 16),
         {:ok, signature} <- decode(admission, "signature"),
         {:ok, proof} <- decode(admission, "proof", 32),
         {:ok, private} <- private_key(inviter_key),
         true <- byte_size(ephemeral) == 65,
         shared = :crypto.compute_key(:ecdh, ephemeral, private, :secp256r1),
         common = [invite, joiner_nonce, inviter_nonce, ephemeral, cert_der, encryption_nonce],
         key = encryption_key(shared, common),
         aad = pack([@encryption_domain | common]),
         plaintext <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             encryption_nonce,
             ciphertext,
             aad,
             tag,
             false
           ),
         {:ok, %{"certificate" => encoded_cert, "entry" => entry}} <- JSON.decode(plaintext),
         {:ok, joiner_der} <- decode64(encoded_cert),
         joiner_cert = X509.Certificate.from_der!(joiner_der),
         member_message = member_message(common, ciphertext, tag),
         true <-
           :public_key.verify(
             member_message,
             :sha256,
             signature,
             X509.Certificate.public_key(joiner_cert)
           ),
         true <- entry["fingerprint"] == fingerprint(joiner_der) do
      {:ok,
       %{
         invite: invite,
         entry: entry,
         proof: proof,
         proof_message: proof_message(common, ciphertext, tag, signature)
       }}
    else
      _ -> {:error, :invalid_member}
    end
  rescue
    _ -> {:error, :invalid_member}
  end

  defp request_parts(request) do
    with {:ok, invite} <- fetch(request, "invite"),
         true <- invite != "",
         {:ok, nonce} <- decode(request, "nonce", 32),
         {:ok, ephemeral} <- decode(request, "ephemeralKey", 65) do
      {:ok, invite, nonce, ephemeral}
    else
      _ -> {:error, :invalid_link}
    end
  end

  defp inviter_message(invite, joiner_nonce, ephemeral, inviter_nonce, cert_der),
    do: pack([@inviter_domain, invite, joiner_nonce, ephemeral, inviter_nonce, cert_der])

  defp member_message(common, ciphertext, tag),
    do: pack([@joiner_domain | common] ++ [ciphertext, tag])

  defp proof_message(common, ciphertext, tag, signature),
    do: pack([@proof_domain | common] ++ [ciphertext, tag, signature])

  defp encryption_key(shared, common),
    do: :crypto.hash(:sha256, pack([@key_domain, shared | common]))

  defp pack(parts) do
    IO.iodata_to_binary(for part <- parts, do: <<byte_size(part)::64, part::binary>>)
  end

  defp random_nonce, do: {:ok, :crypto.strong_rand_bytes(12)}

  defp certificate_der(cert) when is_binary(cert) do
    if :public_key.der_decode(:Certificate, cert) != :error,
      do: {:ok, cert},
      else: {:error, :invalid_member}
  rescue
    _ -> {:error, :invalid_member}
  end

  defp certificate_der(cert), do: {:ok, X509.Certificate.to_der(cert)}

  defp private_key(key) do
    case key do
      ec_private_key(parameters: {:namedCurve, @p256}, privateKey: private)
      when byte_size(private) == 32 ->
        {:ok, private}

      _ ->
        {:error, :invalid_member}
    end
  end

  defp public_point(cert) do
    case X509.Certificate.public_key(cert) do
      {ec_point(point: point), {:namedCurve, @p256}} when byte_size(point) == 65 ->
        {:ok, point}

      _ ->
        {:error, :wrong_machine}
    end
  end

  defp fingerprint(der), do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)

  defp fetch(map, key) do
    case map do
      %{^key => value} when is_binary(value) -> {:ok, value}
      _ -> {:error, :invalid_link}
    end
  end

  defp decode(map, key, size \\ nil) do
    with {:ok, encoded} <- fetch(map, key),
         {:ok, decoded} <- decode64(encoded),
         true <- size == nil or byte_size(decoded) == size do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_link}
    end
  end

  defp decode64(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_link}
    end
  end

  defp encode(binary), do: Base.encode64(binary)
end
