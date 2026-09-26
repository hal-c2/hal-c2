defmodule Mix.Tasks.T3.Pair do
  @shortdoc "Prints a one-time pairing URL for this node"
  @moduledoc """
  Mints a pairing token (valid 5 minutes, single use) and prints the URL a client
  opens or pastes to pair with this node:

      mix t3.pair [BASE_URL]
      mix t3.pair --tailscale [--tailscale-serve-port PORT]

  `BASE_URL` defaults to the local listener, `http://127.0.0.1:3780`.

  `--tailscale` publishes the node over Tailscale Serve HTTPS (port 443 unless
  `--tailscale-serve-port` names another) and pairs through the machine's tailnet
  name. The mapping stays in tailscaled across restarts; a port that already serves
  something else is left alone.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:exqlite, :inets])

    {opts, rest} =
      OptionParser.parse!(args, strict: [tailscale: :boolean, tailscale_serve_port: :integer])

    home = Application.fetch_env!(:t3, :home)
    port = Application.get_env(:t3, :port, 3780)
    serve_port = opts[:tailscale_serve_port] || T3.TailscaleServe.default_port()

    base =
      if opts[:tailscale] do
        case T3.TailscaleServe.publish(port, serve_port) do
          {:ok, base} -> base
          {:error, message} -> Mix.raise(message)
        end
      else
        List.first(rest) || "http://127.0.0.1:#{port}"
      end

    token = T3.Auth.create_pairing_token(Path.join(home, "t3.sqlite"))
    Mix.shell().info("#{String.trim_trailing(base, "/")}/?token=#{token}")

    if opts[:tailscale] do
      Mix.shell().info(
        "Tailscale Serve maps #{base} to this node and keeps it across restarts. Remove it with `tailscale serve --https=#{serve_port} off`."
      )
    end
  end
end
