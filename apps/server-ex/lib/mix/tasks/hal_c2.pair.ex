defmodule Mix.Tasks.HalC2.Pair do
  @shortdoc "Prints a one-time pairing URL for this MC"
  @moduledoc """
  Mints a pairing token (valid 5 minutes, single use) and prints the URL a client
  opens or pastes to pair with this MC:

      mix hal_c2.pair [BASE_URL]
      mix hal_c2.pair --tailscale [--tailscale-serve-port PORT]

  `BASE_URL` defaults to the MC's own address (`HalC2.Web.base_url/1`), such as
  `http://127.0.0.1:3780`, or the LAN or tailnet address it was bound to.

  With no HAL-C2 home configured it pairs with the MC that is running, whether that is
  the installed one or a development one (`HalC2.RuntimeRecord.locate/1`).

  `--tailscale` publishes the MC over Tailscale Serve HTTPS (port 443 unless
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

    # With no home configured, the MC to pair with is the one that is running, in the
    # installed profile or the development one: its store takes the token and its
    # address goes in the link.
    running =
      case HalC2.RuntimeRecord.locate(Application.get_env(:hal_c2, :home)) do
        {home, record} ->
          Application.put_env(:hal_c2, :home, home)
          record

        nil ->
          nil
      end

    port = (running && running["port"]) || Application.get_env(:hal_c2, :port, 3780)
    serve_port = opts[:tailscale_serve_port] || HalC2.TailscaleServe.default_port()

    base =
      if opts[:tailscale] do
        case HalC2.TailscaleServe.publish(port, serve_port) do
          {:ok, base} -> base
          {:error, message} -> Mix.raise(message)
        end
      else
        List.first(rest) || (running && running["origin"]) || HalC2.Web.base_url()
      end

    token = HalC2.Auth.create_pairing_token(HalC2.Store.home_path())
    Mix.shell().info("#{String.trim_trailing(base, "/")}/?token=#{token}")

    if opts[:tailscale] do
      Mix.shell().info(
        "Tailscale Serve maps #{base} to this MC and keeps it across restarts. Remove it with `tailscale serve --https=#{serve_port} off`."
      )
    end
  end
end
