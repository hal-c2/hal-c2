defmodule HalC2.Cluster.Tailscale do
  @moduledoc """
  Discovery strategy: the online peers on this machine's tailnet, from the local
  daemon's `tailscale status --json` (no API key). Machines without a HAL-C2 MC refuse
  the connection and ones outside the cluster fail the handshake, so every peer is
  worth a try.
  """

  @behaviour HalC2.Cluster.Discovery

  @impl true
  def addresses do
    [command | args] = Application.get_env(:hal_c2, :tailscale_command, ["tailscale"])

    case System.cmd(command, args ++ ["status", "--json"], stderr_to_stdout: true) do
      {json, 0} -> json |> JSON.decode!() |> peers()
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc "The IPv4 address of each online peer in a `tailscale status --json` document."
  @spec peers(map) :: [String.t()]
  def peers(%{"Peer" => peers}) when is_map(peers) do
    for {_key, %{"Online" => true, "TailscaleIPs" => ips}} <- peers,
        ip = Enum.find(ips, &String.contains?(&1, ".")),
        ip != nil,
        do: ip
  end

  def peers(_status), do: []
end
