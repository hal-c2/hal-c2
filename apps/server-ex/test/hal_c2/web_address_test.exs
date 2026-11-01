defmodule HalC2.WebAddressTest do
  use ExUnit.Case, async: true

  alias HalC2.Web

  defp up(ip), do: {"if", [flags: [:up], addr: ip]}

  describe "the network address of an MC listening on every interface" do
    test "a home or office network comes before the rest of the private ranges, and those before anything else" do
      assert Web.network_ip({:ok, [up({100, 64, 0, 1}), up({192, 168, 1, 20})]}) == "192.168.1.20"
      assert Web.network_ip({:ok, [up({172, 17, 0, 1}), up({10, 0, 0, 5})]}) == "10.0.0.5"
      assert Web.network_ip({:ok, [up({100, 64, 0, 1}), up({172, 17, 0, 1})]}) == "172.17.0.1"
      assert Web.network_ip({:ok, [up({100, 64, 0, 1})]}) == "100.64.0.1"
    end

    # Found on a machine running Compose: a bridge's 192.168 address outranked the Wi-Fi's 10.
    test "a bridge for this machine's containers and VMs does not count" do
      bridges =
        for name <- ~w(docker0 br-e0f16321754d virbr0),
            do: {~c"#{name}", [flags: [:up], addr: {192, 168, 144, 1}]}

      assert Web.network_ip(
               {:ok, bridges ++ [{~c"wlan0", [flags: [:up], addr: {10, 0, 3, 114}]}]}
             ) == "10.0.3.114"

      assert Web.network_ip({:ok, bridges}) == nil

      assert Web.network_ip({:ok, [{~c"br0", [flags: [:up], addr: {192, 168, 1, 20}]}]}) ==
               "192.168.1.20"
    end

    test "loopback, link-local, IPv6 and interfaces that are down do not count" do
      assert Web.network_ip({:ok, [up({127, 0, 0, 1}), up({169, 254, 0, 1})]}) == nil
      assert Web.network_ip({:ok, [up({0, 0, 0, 0, 0, 0, 0, 1})]}) == nil
      assert Web.network_ip({:ok, [{"if", [flags: [], addr: {192, 168, 1, 20}]}]}) == nil
      assert Web.network_ip({:error, :enotsup}) == nil
    end
  end

  describe "the address a clustered MC listening on every interface reports to members" do
    @interfaces {:ok,
                 [
                   {~c"lo", [flags: [:up], addr: {127, 0, 0, 1}]},
                   {~c"docker0", [flags: [:up], addr: {172, 17, 0, 1}]},
                   {~c"wlan0", [flags: [:up], addr: {10, 0, 3, 114}]}
                 ]}

    # Members are told of every interface in the system's order, so a bridge can come first.
    test "skips a bridge for this machine's containers and VMs" do
      assert Web.member_ip(["172.17.0.1:4369", "10.0.3.114:4369", "127.0.0.1:4369"], @interfaces) ==
               "10.0.3.114"
    end

    test "is nothing when only a bridge and loopback are left" do
      assert Web.member_ip(["172.17.0.1:4369", "127.0.0.1:4369"], @interfaces) == nil
      assert Web.member_ip([], @interfaces) == nil
    end

    test "still names an address when the interfaces cannot be read" do
      assert Web.member_ip(["10.0.3.114:4369"], {:error, :enotsup}) == "10.0.3.114"
    end
  end
end
