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
      plug: HalC2.Web.Entry,
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

  # An MC listening on every interface is reached at the network address of this machine
  # that others most likely share.
  def address(_input) do
    if Application.get_env(:hal_c2, :host, "127.0.0.1") in ["0.0.0.0", "::"] do
      case network_ip(:inet.getifaddrs()) do
        nil -> {:ok, reached_at(base_url())}
        ip -> {:ok, reached_at("http://#{ip}:#{port()}")}
      end
    else
      {:ok, reached_at(base_url())}
    end
  end

  @virtual_interfaces ~w(docker br- virbr veth vmnet vboxnet podman cni lxcbr lxdbr bridge
                         flannel kube- cilium incusbr mpqemubr)

  @doc """
  The IPv4 address of an interface that is up and running in `:inet.getifaddrs/0`'s answer, not
  loopback, link-local or a bridge for this machine's containers and VMs, which nobody
  else can reach: a home or office network first, a tailnet or public address last.
  """
  def network_ip({:ok, interfaces}) do
    ips =
      for {name, opts} <- interfaces,
          not String.starts_with?(to_string(name), @virtual_interfaces),
          flags = Keyword.get(opts, :flags, []),
          :up in flags and :running in flags,
          {:addr, {a, b, _, _} = ip} <- opts,
          a != 127 and {a, b} != {169, 254},
          do: ip

    case Enum.sort_by(ips, &network_rank/1) do
      [ip | _] -> List.to_string(:inet.ntoa(ip))
      [] -> nil
    end
  end

  def network_ip(_), do: nil

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

  @doc """
  Whether `ip` is this machine (127.0.0.0/8 or ::1): the only place the MC's
  access token, a file any local process of the user can read, may authenticate
  from. Remote clients pair into revocable sessions instead.
  """
  def loopback_ip?({127, _, _, _}), do: true
  def loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # A dual-stack listener (`host: "::"`) reports IPv4 loopback in mapped form.
  def loopback_ip?({0, 0, 0, 0, 0, 0xFFFF, g, _}) when div(g, 256) == 127, do: true
  def loopback_ip?(_ip), do: false

  # Headers a reverse proxy adds; Tailscale Serve (`HalC2.TailscaleServe`) sends the
  # forwarded ones, and the tailnet identity for a user's device.
  @proxy_headers ~w(forwarded x-forwarded-for x-forwarded-host x-real-ip tailscale-user-login)

  @doc """
  Whether `conn` came from this machine and not through a proxy on it: Tailscale
  Serve connects from loopback on behalf of the tailnet, so a forwarded request is
  remote. Where the MC's access token may authenticate.
  """
  def local_request?(%{remote_ip: ip, req_headers: headers}),
    do: loopback_ip?(ip) and not Enum.any?(headers, fn {key, _} -> key in @proxy_headers end)

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
              HalC2.Paths.mkdir_private!(Path.dirname(path))
              :ok = HalC2.Paths.write_replace(path, token, 0o600)
              token
          end

        :persistent_term.put({__MODULE__, :token}, token)
        token

      token ->
        token
    end
  end

  @doc """
  The loopback URL and access token of the MC on `port` whose token is at `path` (this
  home's by default), for a local tool to call it with: `{url, token}` once the
  listener there has proved it holds the token without being sent it (`holds_token?/2`),
  nil when nothing there can (no MC runs, or another program holds the port). Nil too
  for an MC bound to one non-loopback address (`loopback_host/1`): the loopback port is
  free for anyone to take, and such a squatter can relay the challenge to that MC.
  """
  # sobelow_skip ["Traversal.FileModule"]
  # Reads only an MC's own token file: this home's, or the installed MC's the
  # upgrade task found under its home.
  def local_mc(port \\ port(), path \\ token_path()) do
    host = loopback_host(Application.get_env(:hal_c2, :host))
    base = host && "http://#{host}:#{port}"

    with true <- is_binary(base),
         {:ok, token} <- File.read(path),
         token = String.trim(token),
         true <- holds_token?(base, token) do
      {base, token}
    else
      _ -> nil
    end
  end

  @doc """
  Whether the listener at `base` proves it holds `token` by answering a fresh challenge
  with `proof/2`, so the token can be sent there. The MC answers only from loopback,
  so a program squatting on loopback cannot relay the challenge to an MC elsewhere.
  """
  def holds_token?(base, token) do
    challenge = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    request = {~c"#{base}/.well-known/hal-c2/proof?challenge=#{challenge}", []}

    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, {{_, 200, _}, _, reply}} <-
           :httpc.request(:get, request, [timeout: 5_000], body_format: :binary),
         {:ok, %{"proof" => proof}} when is_binary(proof) <- JSON.decode(reply) do
      Plug.Crypto.secure_compare(proof, proof(token, challenge))
    else
      _ -> false
    end
  end

  @doc """
  Where a local tool reaches an MC bound to `host`: that host when it is a loopback
  address, `127.0.0.1` when it is a wildcard (which listens there too) or unset, nil for one
  non-loopback address. The MC holds the address returned, so while it runs no other
  program listens there on its port.
  """
  def loopback_host(host) when host in [nil, "0.0.0.0", "::"], do: "127.0.0.1"

  def loopback_host(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> host
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> "[::1]"
      _ -> if host == "localhost", do: "127.0.0.1"
    end
  end

  @doc "What `holds_token?/2` expects the listener to answer to `challenge`."
  def proof(token, challenge) do
    :crypto.mac(:hmac, :sha256, token, "hal-c2 local proof\n" <> challenge)
    |> Base.url_encode64(padding: false)
  end

  @doc "Where `token/0` keeps the access token, for local tools that read it."
  def token_path, do: Path.join(HalC2.Paths.data_dir(), "access-token")
end
