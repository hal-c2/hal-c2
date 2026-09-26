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
  The node's access token, generated on first use and kept in the HAL-C2 home directory
  with owner-only permissions.
  """
  @spec token() :: String.t()
  def token do
    case :persistent_term.get({__MODULE__, :token}, nil) do
      nil ->
        path = Path.join(HalC2.Paths.data_dir(), "access-token")

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
end
