defmodule HalC2.ClusterAuthorizationTest do
  use ExUnit.Case, async: false

  alias HalC2.Test.Mc

  @moduletag :tmp_dir

  defmodule Transport do
    @moduledoc false
    def start(_dir, _id), do: :ok
    def connected, do: Application.get_env(:hal_c2, :fake_connected, [])

    def disconnect(mc),
      do: Application.put_env(:hal_c2, :fake_connected, connected() -- [mc])

    def send(mc, message),
      do: Kernel.send(Application.get_env(:hal_c2, :fake_owner), {:sent, mc, message})

    def version_changed(_dir), do: :ok
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :cluster_transport, Transport)
    Application.put_env(:hal_c2, :cluster_listen, "127.0.0.1")
    Application.put_env(:hal_c2, :fake_owner, self())

    on_exit(fn ->
      for key <- [:cluster_transport, :cluster_listen, :fake_owner, :fake_connected],
          do: Application.delete_env(:hal_c2, key)
    end)

    mc = Mc.start(dir)
    Mc.ensure(HalC2.Cluster)
    {:ok, _} = Application.ensure_all_started(:inets)
    %{mc: mc}
  end

  test "HTTP cluster mutations require terminal operation as well as access management", %{
    mc: mc
  } do
    for scopes <- [
          ["access:write"],
          ["orchestration:read", "orchestration:operate", "access:read", "access:write"]
        ] do
      access = Mc.pair(scopes, "Access without terminals")

      for {path, body} <- [
            {"/api/cluster/invite", %{}},
            {"/api/cluster/join", %{"link" => "not-a-link"}},
            {"/api/cluster/remove", %{"id" => "other"}},
            {"/api/cluster/members", member()}
          ] do
        assert {403,
                %{
                  "_tag" => "EnvironmentScopeRequiredError",
                  "requiredScope" => "terminal:operate"
                }} = Mc.http(mc, :post, path, bearer: access, json: body)
      end
    end

    assert HalC2.Cluster.status()["members"] == []
    assert HalC2.Auth.pairing_links() == []
  end

  test "socket cluster mutations require terminal operation as well as access management", %{
    mc: mc
  } do
    for scopes <- [
          ["access:write"],
          ["orchestration:read", "orchestration:operate", "access:read", "access:write"]
        ] do
      client = Mc.connect_as(mc, Mc.pair(scopes, "Access without terminals"))

      for {method, payload} <- [
            {"cluster.invite", %{}},
            {"cluster.join", %{"link" => "not-a-link"}},
            {"cluster.update", %{}},
            {"cluster.remove", %{"id" => "other"}}
          ],
          reduce: client do
        client ->
          {reply, client} = Mc.call(client, mc.environment, method, payload)

          assert {:error, "terminal:operate is required",
                  %{
                    "_tag" => "EnvironmentScopeRequiredError",
                    "requiredScope" => "terminal:operate"
                  }} = reply

          client
      end
    end

    assert HalC2.Cluster.status()["members"] == []
    assert HalC2.Auth.pairing_links() == []
  end

  test "a forwarded cluster mutation is refused before it leaves the socket's MC", %{mc: mc} do
    member = %{"environmentId" => "env-member", "label" => "Member"}
    send(HalC2.Shell, {:nodeup, :member@nowhere})
    GenServer.cast(HalC2.Shell, {:peer_environment, :member@nowhere, member})
    :sys.get_state(HalC2.Shell)

    client = Mc.connect_as(mc, Mc.pair(["access:write"], "Access only"))

    assert {{:error, "terminal:operate is required",
             %{
               "_tag" => "EnvironmentScopeRequiredError",
               "requiredScope" => "terminal:operate"
             }}, _} = Mc.call(client, "env-member", "cluster.invite", %{})
  end

  test "cluster reads still require only access:read", %{mc: mc} do
    access = Mc.pair(["access:read"], "Reader")
    assert {200, %{"clustered" => true}} = Mc.http(mc, :get, "/api/cluster", bearer: access)

    client = Mc.connect_as(mc, access)
    assert {{:ok, %{"clustered" => true}}, _} = Mc.call(client, mc.environment, "cluster.status")
  end

  defp member do
    %{
      "id" => "joining",
      "fingerprint" => String.duplicate("a", 64),
      "label" => "Joining",
      "addresses" => []
    }
  end
end
