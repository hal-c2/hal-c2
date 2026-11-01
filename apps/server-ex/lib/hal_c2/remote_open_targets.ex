defmodule HalC2.RemoteOpenTargets do
  @moduledoc """
  The SSH names this machine advertises (`remoteOpenTargets`) for a client elsewhere to
  open a workspace in its own editor over SSH, most reachable first: the tailnet name
  works from anywhere on the tailnet, `<hostname>.local` only on the same LAN. Whether a
  name resolves from the client's machine only the client can find out; with no SSH
  server listening here none can work, so none are named.
  """

  @ssh_port 22
  @budget_ms 1_000

  @doc "The names, or none when finding them takes longer than a client should wait."
  @spec targets() :: [map]
  def targets do
    budget = Application.get_env(:hal_c2, :remote_open_budget_ms, @budget_ms)
    task = Task.async(&resolve/0)

    case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
      {:ok, targets} -> targets
      _ -> []
    end
  end

  defp resolve do
    if listening?(), do: tailnet() ++ mdns(), else: []
  end

  # sshd can be bound to one address family only.
  defp listening? do
    port = Application.get_env(:hal_c2, :remote_open_ssh_port, @ssh_port)
    Enum.any?([{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}], &answers?(&1, port))
  end

  defp answers?(address, port) do
    case :gen_tcp.connect(address, port, [], 200) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  # Tailscale absent or down is the common case.
  defp tailnet do
    case HalC2.TailscaleServe.magic_dns_name() do
      {:ok, name} -> [%{"kind" => "tailscale", "host" => name}]
      {:error, _} -> []
    end
  end

  # The hostname may already be a full name (macOS's often is `Name.local`).
  defp mdns do
    {:ok, hostname} = :inet.gethostname()

    case hostname |> List.to_string() |> String.split(".") |> hd() |> String.trim() do
      "" -> []
      short -> [%{"kind" => "mdns", "host" => short <> ".local"}]
    end
  end
end
