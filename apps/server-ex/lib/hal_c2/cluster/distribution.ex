defmodule HalC2.Cluster.Distribution do
  @moduledoc """
  How `HalC2.Cluster` reaches the other members: Erlang distribution over mutual TLS.
  It boots distribution, lists and drops connected members and sends to their
  `HalC2.Cluster`. The cluster's bookkeeping never touches distribution but through
  this module, so the `:cluster_transport` config can put a fake in its place and the
  bookkeeping runs without a network (the property tests in `prop/`).
  """

  require Logger

  alias HalC2.Cluster
  alias HalC2.Cluster.Epmd

  @doc """
  Starts distribution as the MC `Cluster.mc_name(id)` and reports members coming and
  going to the caller: `:ok`, or `{:off, reason}` when the VM was not booted for it.
  """
  def start(dir, id) do
    started = start_distribution(dir, id)
    forget_boot_flags()
    if started == :ok, do: :ok = :net_kernel.monitor_nodes(true)
    started
  end

  @doc "The members connected now."
  def connected, do: Node.list()

  def disconnect(mc), do: Node.disconnect(mc)

  @doc "Sends `message` to the `HalC2.Cluster` of the connected member `mc`."
  def send(mc, message), do: GenServer.cast({Cluster, mc}, message)

  @doc """
  Takes up the version this MC moved to in place: keeps the port and changes the
  cookie, which names the version, and drops every member to find them again.
  """
  def version_changed(dir) do
    # An MC updated in place from a version that kept no port has not kept its own yet.
    keep_port(dir)
    Node.set_cookie(cookie())
    for mc <- Node.list(), do: Node.disconnect(mc)
    :ok
  end

  defp start_distribution(dir, id) do
    name = Cluster.mc_name(id)

    cond do
      # The cluster process restarted; distribution outlives it.
      node() == name ->
        :ok

      Node.alive?() ->
        {:off, :not_booted_for_clustering}

      true ->
        with {:ok, [[~c"inet_tls"]]} <- :init.get_argument(:proto_dist),
             {:ok, [[optfile]]} <- :init.get_argument(:ssl_dist_optfile) do
          File.mkdir_p!(Path.dirname(optfile))
          File.write!(optfile, ssl_dist_conf(dir))
          Application.put_env(:kernel, :epmd_module, Epmd)

          with ip when is_binary(ip) <- Application.get_env(:hal_c2, :cluster_listen),
               {:ok, ip} <- :inet.parse_address(to_charlist(ip)),
               do: Application.put_env(:kernel, :inet_dist_use_interface, ip)

          if Enum.any?(Enum.uniq([Cluster.dist_port(), kept_port(dir), 0]), &listen(name, &1)) do
            keep_port(dir)
            Node.set_cookie(cookie())
            :ok
          else
            {:off, :distribution_failed}
          end
        else
          _ -> {:off, :not_booted_for_clustering}
        end
    end
  end

  # The port this MC last listened on. Members reach it at the addresses it reported,
  # so one that could not have the cluster port takes the same other port every time:
  # members that all restart at once (an update) would otherwise each come back on a
  # port no other member knows.
  defp kept_port(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "port")),
         {port, ""} when port in 1..65_535 <- Integer.parse(String.trim(text)) do
      port
    else
      _ -> Cluster.dist_port()
    end
  end

  defp keep_port(dir),
    do: File.write!(Path.join(dir, "port"), Integer.to_string(Epmd.listen_port()))

  defp cookie, do: :"hal_c2_#{HalC2.Upgrade.version()}"

  # The boot flags arrive in ELIXIR_ERL_OPTIONS, which programs the MC starts (an
  # agent's `mix test`) would inherit and boot with.
  defp forget_boot_flags do
    with options when is_binary(options) <- System.get_env("ELIXIR_ERL_OPTIONS") do
      case Regex.replace(
             ~r/\s*-(proto_dist inet_tls|ssl_dist_optfile \S+|setcookie hal_c2)\b/,
             options,
             ""
           ) do
        "" -> System.delete_env("ELIXIR_ERL_OPTIONS")
        rest -> System.put_env("ELIXIR_ERL_OPTIONS", rest)
      end
    end
  end

  defp listen(name, port) do
    Epmd.put_listen_port(port)

    case :net_kernel.start(name, %{name_domain: :longnames}) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("Cluster: could not listen on port #{port}: #{inspect(reason)}")
        false
    end
  end

  # file:consult/1 format: plain terms only, no function calls (an external fun is a term).
  # The CA file is the MC's own certificate: members' certificates are pinned instead.
  defp ssl_dist_conf(dir) do
    opts =
      [
        certfile: to_charlist(Path.join(dir, "mc.pem")),
        keyfile: to_charlist(Path.join(dir, "mc.key")),
        cacertfile: to_charlist(Path.join(dir, "mc.pem")),
        verify: :verify_peer,
        verify_fun: {&Cluster.verify_peer/3, []},
        versions: [:"tlsv1.3"]
      ]

    conf = [server: opts ++ [fail_if_no_peer_cert: true], client: opts]
    :io_lib.format(~c"~p.~n", [conf]) |> IO.iodata_to_binary()
  end
end
