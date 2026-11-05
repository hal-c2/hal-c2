defmodule HalC2.ClusterJoinTest do
  use ExUnit.Case, async: false

  alias HalC2.Cluster.Join
  alias HalC2.Test.Mc

  @moduletag :tmp_dir

  defmodule Transport do
    @moduledoc false
    def start(_dir, _id), do: :ok
    def connected, do: []
    def disconnect(_mc), do: :ok
    def send(_mc, _message), do: :ok
    def version_changed(_dir), do: :ok
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :cluster_transport, Transport)
    Application.put_env(:hal_c2, :cluster_listen, "127.0.0.1")

    on_exit(fn ->
      for key <- [:cluster_transport, :cluster_listen, :auth_now],
          do: Application.delete_env(:hal_c2, key)
    end)

    mc = Mc.start(dir)
    Mc.ensure(HalC2.Cluster)
    {:ok, _} = Application.ensure_all_started(:inets)
    %{mc: mc}
  end

  test "a stand-in inviter learns no secret or joiner description" do
    inviter = identity("inviter")
    stand_in = identity("stand-in")
    joiner = identity("joining")
    token = random_token()
    {:ok, request, private} = Join.challenge("pairing-public-id")
    {:ok, answer} = Join.answer(request, stand_in.cert, stand_in.key)

    assert {:error, :wrong_machine} =
             Join.seal(
               request,
               answer,
               token,
               inviter.pin,
               joiner.entry,
               joiner.cert,
               joiner.key,
               private
             )

    refute JSON.encode!(request) =~ token
    refute JSON.encode!(request) =~ joiner.entry["id"]
    refute JSON.encode!(request) =~ joiner.entry["fingerprint"]

    {:ok, answer} = Join.answer(request, inviter.cert, inviter.key)

    {:ok, admission} =
      Join.seal(
        request,
        answer,
        token,
        inviter.pin,
        joiner.entry,
        joiner.cert,
        joiner.key,
        private
      )

    wire = JSON.encode!(admission)
    refute wire =~ token
    refute wire =~ joiner.entry["id"]
    refute wire =~ joiner.entry["label"]
    refute wire =~ joiner.entry["fingerprint"]
    refute wire =~ Base.encode64(X509.Certificate.to_der(joiner.cert))
    assert {:ok, package} = Join.open(admission, inviter.cert, inviter.key)
    assert package.entry == joiner.entry
  end

  test "a swapped certificate or mismatched entry is refused and admits nobody", %{mc: mc} do
    {:ok, %{"link" => link}} = HalC2.Cluster.invite(%{"baseUrl" => base(mc)})
    joiner = identity("joining")
    other = identity("other")
    {request, answer, private, token, pin} = challenge(mc, link)

    wrong_entry = %{joiner.entry | "fingerprint" => other.pin}

    {:ok, mismatched} =
      Join.seal(request, answer, token, pin, wrong_entry, joiner.cert, joiner.key, private)

    assert {409, %{"reason" => "invalid_member"}} =
             Mc.http(mc, :post, "/api/cluster/join/admit", json: mismatched)

    assert HalC2.Cluster.status()["members"] == []

    {:ok, valid} =
      Join.seal(request, answer, token, pin, joiner.entry, joiner.cert, joiner.key, private)

    tampered = Map.put(valid, "ciphertext", flip_base64(valid["ciphertext"]))

    assert {409, %{"reason" => "invalid_member"}} =
             Mc.http(mc, :post, "/api/cluster/join/admit", json: tampered)

    assert HalC2.Cluster.status()["members"] == []
    assert {200, %{"members" => members}} = admit(mc, valid)
    assert Map.has_key?(members, joiner.entry["id"])
  end

  test "a replayed invite cannot admit a second time", %{mc: mc} do
    {:ok, %{"link" => link}} = HalC2.Cluster.invite(%{"baseUrl" => base(mc)})
    joiner = identity("joining")
    {request, answer, private, token, pin} = challenge(mc, link)

    {:ok, admission} =
      Join.seal(request, answer, token, pin, joiner.entry, joiner.cert, joiner.key, private)

    assert {200, _} = admit(mc, admission)

    assert {409, %{"reason" => "link_invalid"}} =
             Mc.http(mc, :post, "/api/cluster/join/admit", json: admission)

    assert [%{"id" => id}] = HalC2.Cluster.status()["members"]
    assert id == joiner.entry["id"]
  end

  test "an expired invite cannot get a challenge or admit", %{mc: mc} do
    {:ok, %{"link" => link}} = HalC2.Cluster.invite(%{"baseUrl" => base(mc)})
    joiner = identity("joining")
    {request, answer, private, token, pin} = challenge(mc, link)

    {:ok, admission} =
      Join.seal(request, answer, token, pin, joiner.entry, joiner.cert, joiner.key, private)

    Application.put_env(:hal_c2, :auth_now, HalC2.Auth.now() + :timer.minutes(6))

    assert {409, %{"reason" => "link_invalid"}} =
             Mc.http(mc, :post, "/api/cluster/join/challenge", json: request)

    assert {409, %{"reason" => "link_invalid"}} =
             Mc.http(mc, :post, "/api/cluster/join/admit", json: admission)

    assert HalC2.Cluster.status()["members"] == []
  end

  test "the old bearer path and OAuth exchange cannot spend a cluster invite", %{mc: mc} do
    access = Mc.pair(Mc.admin_scopes(), "Old cluster client")
    joiner = identity("joining")

    assert {409, %{"reason" => "not_an_invite"}} =
             Mc.http(mc, :post, "/api/cluster/members", bearer: access, json: joiner.entry)

    {:ok, %{"link" => link}} = HalC2.Cluster.invite(%{"baseUrl" => base(mc)})
    query = URI.decode_query(URI.parse(link).query)
    assert {400, %{"error" => "invalid_grant"}} = Mc.pair_http(mc, query["token"], "Intercepted")
    assert HalC2.Auth.cluster_invite?(query["invite"])
    assert HalC2.Cluster.status()["members"] == []

    {request, answer, private, token, pin} = challenge(mc, link)

    {:ok, admission} =
      Join.seal(request, answer, token, pin, joiner.entry, joiner.cert, joiner.key, private)

    assert {200, %{"members" => members}} = admit(mc, admission)
    assert Map.has_key?(members, joiner.entry["id"])
  end

  defp challenge(mc, link) do
    uri = URI.parse(link)
    query = URI.decode_query(uri.query)
    pin = URI.decode_query(uri.fragment)["fingerprint"]
    {:ok, request, private} = Join.challenge(query["invite"])

    assert {200, answer} = Mc.http(mc, :post, "/api/cluster/join/challenge", json: request)
    {request, answer, private, query["token"], pin}
  end

  defp admit(mc, admission), do: Mc.http(mc, :post, "/api/cluster/join/admit", json: admission)

  defp base(mc), do: "http://127.0.0.1:#{mc.port}"

  defp identity(id) do
    key = X509.PrivateKey.new_ec(:secp256r1)
    cert = X509.Certificate.self_signed(key, "/CN=#{id}.hal-c2")
    pin = HalC2.Cluster.fingerprint(cert)

    %{
      cert: cert,
      key: key,
      pin: pin,
      entry: %{
        "id" => id,
        "fingerprint" => pin,
        "label" => "Machine #{id}",
        "addresses" => ["127.0.0.1:4370"],
        "version" => HalC2.Upgrade.version()
      }
    }
  end

  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp flip_base64(encoded) do
    binary = Base.decode64!(encoded)
    flipped = :crypto.exor(binary, :binary.copy(<<1>>, byte_size(binary)))
    Base.encode64(flipped)
  end
end
