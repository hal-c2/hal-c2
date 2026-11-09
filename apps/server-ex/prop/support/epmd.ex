defmodule HalC2.Prop.Epmd do
  @moduledoc """
  The property tests' port mapper (`prop/test_helper.exs` installs it before anything
  starts distribution): `:erl_epmd` for every node, but an MC's, named after its
  member host as `HalC2.Cluster.mc_name/1` names it, whose address and port the test
  gave with `put/3`. A peer named so runs `HalC2.Cluster.Epmd` and registers nowhere,
  so cases running at once in other checkouts never share its name.
  """

  @doc "Reaches the MC named after `host` at `ip` and `port` from now on."
  def put(host, ip, port), do: :persistent_term.put({__MODULE__, to_string(host)}, {ip, port})

  def start_link, do: :erl_epmd.start_link()
  def register_node(name, port), do: :erl_epmd.register_node(name, port)
  def register_node(name, port, family), do: :erl_epmd.register_node(name, port, family)
  def listen_port_please(name, host), do: :erl_epmd.listen_port_please(name, host)
  def port_please(name, host), do: :erl_epmd.port_please(name, host)
  def port_please(name, host, timeout), do: :erl_epmd.port_please(name, host, timeout)
  def names, do: :erl_epmd.names()
  def names(host), do: :erl_epmd.names(host)

  def address_please(name, host, family) do
    case :persistent_term.get({__MODULE__, to_string(host)}, nil) do
      {ip, port} -> {:ok, ip, port, 6}
      nil -> :erl_epmd.address_please(name, host, family)
    end
  end
end
