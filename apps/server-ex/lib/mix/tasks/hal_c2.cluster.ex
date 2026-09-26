defmodule Mix.Tasks.HalC2.Cluster do
  @shortdoc "Creates, invites to, and joins a cluster of your machines"
  @moduledoc """
      mix hal_c2.cluster init ADDRESS         # first machine: new cluster CA + its own cert
      mix hal_c2.cluster invite ADDRESS FILE  # on a member: write a join bundle for ADDRESS
      mix hal_c2.cluster join FILE            # on the new machine: install the bundle
      mix hal_c2.cluster vm-args              # flags to boot this node clustered
      mix hal_c2.cluster revoke ADDRESS       # on every member: stop admitting ADDRESS

  ADDRESS is how other members reach the machine, usually its Tailscale IP. A join
  bundle contains the new machine's private key: move it privately and delete it.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    home = HalC2.Paths.data_dir()

    case args do
      ["init", address] ->
        case HalC2.Cluster.init(home, address) do
          :ok ->
            Mix.shell().info("Created cluster CA and certificate for #{address}")

          {:error, :already_initialized} ->
            Mix.raise("#{HalC2.Cluster.dir(home)} already has a cluster")
        end

      ["invite", address, file] ->
        File.write!(file, HalC2.Cluster.invite(home, address))
        File.chmod!(file, 0o600)
        Mix.shell().info("Wrote join bundle for #{address} to #{file}")

      ["join", file] ->
        :ok = HalC2.Cluster.join(home, File.read!(file))
        Mix.shell().info("Joined as hal_c2@#{HalC2.Cluster.address(home)}")

      ["revoke", address] ->
        :ok = HalC2.Cluster.revoke(home, address)
        Mix.shell().info("Revoked hal_c2@#{address} on this machine; run this on every member")

      ["vm-args"] ->
        IO.puts(HalC2.Cluster.vm_args(home) || Mix.raise("not in a cluster yet"))

      _ ->
        Mix.raise("see `mix help hal_c2.cluster`")
    end
  end
end
