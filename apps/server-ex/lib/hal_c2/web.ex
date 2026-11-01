defmodule HalC2.Web do
  @moduledoc "Client-facing HTTP and WebSocket listener."

  @doc "Bandit child spec for the configured port and host (loopback by default)."
  def child_spec(_opts) do
    port = Application.get_env(:hal_c2, :port, 3780)
    host = Application.get_env(:hal_c2, :host, "127.0.0.1")
    {:ok, ip} = :inet.parse_address(String.to_charlist(host))
    # The token file exists from boot, so local tools can read it before any client connects.
    _ = token()

    [
      plug: HalC2.Web.Router,
      ip: ip,
      port: port,
      startup_log: false,
      thousand_island_options: [supervisor_options: [name: HalC2.Web.Listener]]
    ]
    |> Bandit.child_spec()
    # A fixed id, so the listener can be stopped and started by name.
    |> Supervisor.child_spec(id: __MODULE__)
  end

  @doc "The port the listener is bound to, which the OS picks when `:port` is 0."
  def port do
    case ThousandIsland.listener_info(HalC2.Web.Listener) do
      {:ok, {_ip, port}} -> port
      _ -> Application.get_env(:hal_c2, :port, 3780)
    end
  catch
    :exit, _ -> Application.get_env(:hal_c2, :port, 3780)
  end

  @doc """
  The URL clients reach the listener at: its bind host, or `localhost` when it
  listens on every interface.
  """
  def base_url(scheme \\ "http") do
    host =
      case Application.get_env(:hal_c2, :host, "127.0.0.1") do
        wildcard when wildcard in ["0.0.0.0", "::"] -> "localhost"
        host -> if String.contains?(host, ":"), do: "[#{host}]", else: host
      end

    "#{scheme}://#{host}:#{port()}"
  end

  @doc """
  Where another device reaches this MC, for a link made here (a pairing link, a cluster
  invite): `{:ok, %{"address" => url, "localOnly" => boolean}}`. The address is
  `"baseUrl"` when the caller names one, else with `"tailscale" => true` this MC's
  Tailscale Serve name (published if need be, on the MC's own port number when
  something else holds HTTPS 443, `{:error, {:tailscale, message}}` when it cannot be),
  else the address the MC listens on, or a network address of this machine when it
  listens on every interface. `localOnly` says only this machine can reach it.
  """
  @spec address(map) :: {:ok, map} | {:error, {:tailscale, String.t()}}
  def address(input \\ %{})

  def address(%{"baseUrl" => base}) when is_binary(base) and base != "",
    do: {:ok, reached_at(String.trim_trailing(base, "/"))}

  def address(%{"tailscale" => true}) do
    case HalC2.TailscaleServe.publish_free(port()) do
      {:ok, base} -> {:ok, reached_at(base)}
      {:error, message} -> {:error, {:tailscale, message}}
    end
  end

  # An MC listening on every interface is reached at the address it reports to members,
  # or when it has none on the network address of this machine that others most likely
  # share.
  def address(_input) do
    if Application.get_env(:hal_c2, :host, "127.0.0.1") in ["0.0.0.0", "::"] do
      interfaces = :inet.getifaddrs()

      addresses =
        case HalC2.Cluster.status() do
          %{"clustered" => true, "addresses" => addresses} -> addresses
          _ -> []
        end

      case member_ip(addresses, interfaces) || network_ip(interfaces) do
        nil -> {:ok, reached_at(base_url())}
        ip -> {:ok, reached_at("http://#{ip}:#{port()}")}
      end
    else
      {:ok, reached_at(base_url())}
    end
  end

  @virtual_interfaces ~w(docker br- virbr veth vmnet vboxnet podman cni lxcbr lxdbr bridge)

  @doc """
  The first of the `ip:port` addresses an MC reports to members that another machine can
  reach, given `:inet.getifaddrs/0`'s answer: members are told of every interface, a
  bridge for this machine's containers and VMs among them.
  """
  def member_ip(addresses, interfaces) do
    bridges =
      with {:ok, interfaces} <- interfaces do
        for {name, opts} <- interfaces,
            virtual?(name),
            {:addr, {_, _, _, _} = ip} <- opts,
            do: List.to_string(:inet.ntoa(ip))
      else
        _ -> []
      end

    addresses
    |> Enum.map(&(&1 |> String.split(":") |> hd()))
    |> Enum.find(&(not String.starts_with?(&1, "127.") and &1 not in bridges))
  end

  @doc """
  The IPv4 address of an interface that is up in `:inet.getifaddrs/0`'s answer, not
  loopback, link-local or a bridge for this machine's containers and VMs, which nobody
  else can reach: a home or office network first, a tailnet or public address last.
  """
  def network_ip({:ok, interfaces}) do
    ips =
      for {name, opts} <- interfaces,
          not virtual?(name),
          :up in Keyword.get(opts, :flags, []),
          {:addr, {a, b, _, _} = ip} <- opts,
          a != 127 and {a, b} != {169, 254},
          do: ip

    case Enum.sort_by(ips, &network_rank/1) do
      [ip | _] -> List.to_string(:inet.ntoa(ip))
      [] -> nil
    end
  end

  def network_ip(_), do: nil

  defp virtual?(name), do: String.starts_with?(to_string(name), @virtual_interfaces)

  defp network_rank({192, 168, _, _}), do: 0
  defp network_rank({10, _, _, _}), do: 1
  defp network_rank({172, b, _, _}) when b in 16..31, do: 2
  defp network_rank(_), do: 3

  defp reached_at(base),
    do: %{"address" => base, "localOnly" => loopback?(URI.parse(base).host)}

  # Whether only this machine reaches `host`: localhost, all of 127.0.0.0/8, or ::1.
  defp loopback?(nil), do: false

  defp loopback?(host) do
    host = host |> String.downcase() |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> host == "localhost"
    end
  end

  @doc "Whether `token` is the MC's access token (once the listener has read it)."
  @spec access_token?(String.t()) :: boolean
  def access_token?(token) do
    case :persistent_term.get({__MODULE__, :token}, nil) do
      nil -> false
      expected -> Plug.Crypto.secure_compare(token, expected)
    end
  end

  @doc """
  The MC's access token, generated on first use and kept in the HAL-C2 home directory
  with owner-only permissions.
  """
  @spec token() :: String.t()
  def token do
    case :persistent_term.get({__MODULE__, :token}, nil) do
      nil ->
        path = token_path()

        token =
          case File.read(path) do
            {:ok, token} ->
              String.trim(token)

            {:error, :enoent} ->
              token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
              File.mkdir_p!(Path.dirname(path))
              # Owner-only before the secret is written.
              File.write!(path, "")
              File.chmod!(path, 0o600)
              File.write!(path, token)
              token
          end

        :persistent_term.put({__MODULE__, :token}, token)
        token

      token ->
        token
    end
  end

  @doc "Where `token/0` keeps the access token, for local tools that read it."
  def token_path, do: Path.join(HalC2.Paths.data_dir(), "access-token")
end
