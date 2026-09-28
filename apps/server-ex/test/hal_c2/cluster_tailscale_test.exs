defmodule HalC2.Cluster.TailscaleTest do
  use ExUnit.Case, async: true

  test "online peers are tried at their IPv4 address" do
    status = %{
      "Self" => %{"TailscaleIPs" => ["100.67.211.56", "fd7a::1"]},
      "Peer" => %{
        "k1" => %{"Online" => true, "TailscaleIPs" => ["100.66.87.5", "fd7a::2"]},
        "k2" => %{"Online" => false, "TailscaleIPs" => ["100.79.210.10"]},
        "k3" => %{"Online" => true, "TailscaleIPs" => ["fd7a::3"]}
      }
    }

    assert HalC2.Cluster.Tailscale.peers(status) == ["100.66.87.5"]
    assert HalC2.Cluster.Tailscale.peers(%{"BackendState" => "Stopped"}) == []
  end
end
