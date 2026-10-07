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
  listens on every interface (as the Node server's pairing links do).
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
  else the address the MC listens on. `localOnly` says only this machine can reach it.
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

  # An MC listening on every interface is reached at the address it reports to members.
  def address(_input) do
    wildcard? = Application.get_env(:hal_c2, :host, "127.0.0.1") in ["0.0.0.0", "::"]

    with true <- wildcard?,
         %{"clustered" => true, "addresses" => [address | _]} <- HalC2.Cluster.status(),
         [ip | _] <- String.split(address, ":"),
         false <- String.starts_with?(ip, "127.") do
      {:ok, reached_at("http://#{ip}:#{port()}")}
    else
      _ -> {:ok, reached_at(base_url())}
    end
  end

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
