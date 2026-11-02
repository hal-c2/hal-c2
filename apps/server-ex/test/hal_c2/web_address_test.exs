defmodule HalC2.WebAddressTest do
  use ExUnit.Case, async: false

  alias HalC2.Web

  defp up(ip), do: {"if", [flags: [:up, :running], addr: ip]}

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
        for name <-
              ~w(docker0 br-e0f16321754d virbr0 flannel.1 kube-bridge cilium_host incusbr0 mpqemubr0),
            do: {~c"#{name}", [flags: [:up, :running], addr: {192, 168, 144, 1}]}

      assert Web.network_ip(
               {:ok, bridges ++ [{~c"wlan0", [flags: [:up, :running], addr: {10, 0, 3, 114}]}]}
             ) == "10.0.3.114"

      assert Web.network_ip({:ok, bridges}) == nil

      assert Web.network_ip({:ok, [{~c"br0", [flags: [:up, :running], addr: {192, 168, 1, 20}]}]}) ==
               "192.168.1.20"
    end

    test "loopback, link-local, IPv6 and interfaces that are down do not count" do
      assert Web.network_ip({:ok, [up({127, 0, 0, 1}), up({169, 254, 0, 1})]}) == nil
      assert Web.network_ip({:ok, [up({0, 0, 0, 0, 0, 0, 0, 1})]}) == nil
      assert Web.network_ip({:ok, [{"if", [flags: [], addr: {192, 168, 1, 20}]}]}) == nil
      assert Web.network_ip({:error, :enotsup}) == nil
    end

    # An unplugged port with a static address is up, and would outrank the Wi-Fi that works.
    test "an interface with no carrier does not count" do
      unplugged = {~c"eth0", [flags: [:up], addr: {192, 168, 1, 20}]}
      wifi = {~c"wlan0", [flags: [:up, :running], addr: {10, 0, 3, 114}]}
      assert Web.network_ip({:ok, [unplugged, wifi]}) == "10.0.3.114"
    end
  end

  describe "the address of an MC listening on every interface" do
    setup do
      previous = Application.get_env(:hal_c2, :host)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:hal_c2, :host, previous),
          else: Application.delete_env(:hal_c2, :host)
      end)

      Application.put_env(:hal_c2, :host, "0.0.0.0")
      :ok
    end

    test "is this machine's network address, or localhost when it has none" do
      {:ok, %{"address" => address}} = Web.address(%{})
      ip = Web.network_ip(:inet.getifaddrs())
      assert address == "http://#{ip || "localhost"}:#{Web.port()}"
    end
  end
end
