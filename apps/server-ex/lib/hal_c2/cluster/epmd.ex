defmodule HalC2.Cluster.Epmd do
  @moduledoc """
  The distribution's port mapper in place of the EPMD daemon (`HalC2.Cluster` sets
  `:kernel`'s `:epmd_module` before starting distribution). The MC listens on the
  port `put_listen_port/1` names, and reaches a member at the address `put/3` last
  recorded for its host, which `HalC2.Cluster.Discovery` fills in. Nothing is
  registered or looked up anywhere else.

  Addresses live in `HalC2.Cluster`'s table, the port for as long as the VM runs:
  distribution outlives a cluster process that restarts, and names its port only once.
  """

  @table HalC2.Cluster
  @port {__MODULE__, :listen_port}

  def start_link, do: :ignore

  def register_node(name, port), do: register_node(name, port, :inet)

  def register_node(_name, port, _family) do
    put_listen_port(port)
    {:ok, -1}
  end

  def listen_port_please(_name, _host), do: {:ok, listen_port()}

  def port_please(_name, _host), do: :noport
  def port_please(_name, _host, _timeout), do: :noport

  def names(_host), do: {:error, :address}

  def address_please(_name, host, _family) do
    case lookup(to_string(host)) do
      {ip, port} -> {:ok, ip, port, 6}
      nil -> {:error, :nxdomain}
    end
  end

  @doc "The port the MC listens on, once distribution started; the port to try before."
  def listen_port, do: :persistent_term.get(@port, 0)

  @doc false
  def put_listen_port(port), do: :persistent_term.put(@port, port)

  @doc "Reaches the MC named after `host` at `ip` and `port` from now on."
  def put(host, ip, port), do: :ets.insert(@table, {{:address, host}, {ip, port}})

  @doc "Forgets where the MC named after `host` is reached."
  def forget(host), do: :ets.delete(@table, {:address, host})

  @doc "Where the MC named after `host` is reached, if known."
  def lookup(host) do
    case :ets.lookup(@table, {:address, host}) do
      [{_, at}] -> at
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end
end
