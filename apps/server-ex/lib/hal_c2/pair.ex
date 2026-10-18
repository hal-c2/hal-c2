defmodule HalC2.Pair do
  @moduledoc """
  `mix hal_c2.pair` and `bin/hal-c2-service pair`: mints a pairing token (valid 5
  minutes, single use) and prints the URL a client opens or pastes to pair with this
  MC.

      pair [BASE_URL]
      pair --tailscale [--tailscale-serve-port PORT]
      pair --release [BASE_URL | --tailscale]

  `BASE_URL` defaults to the MC's own address (`HalC2.Web.base_url/0`), such as
  `http://127.0.0.1:3790`, or the LAN or tailnet address it was bound to.

  With no HAL-C2 home configured it pairs with the MC that is running, whether that is
  the installed one or a development one (`HalC2.RuntimeRecord.locate/1`). When both
  run, that is the one of the profile the command was run from, so a checkout pairs
  with its own; `--release` pairs with the installed MC instead. An installed MC
  started with `HAL_C2_HOME` or `HAL_C2_MC_HOME` is paired with by the same
  variables on this command.

  `--tailscale` publishes the MC over Tailscale Serve HTTPS (port 443 unless
  `--tailscale-serve-port` names another) and pairs through the machine's tailnet
  name. The mapping stays in tailscaled across restarts; a port that already serves
  something else is left alone.

  Runs in a release (`eval`), where Mix does not exist: the Mix task only prints.
  """

  @doc "Runs the command and prints its outcome; exits 1 on failure."
  def main(args) do
    case command(args) do
      {:ok, lines} ->
        Enum.each(lines, &IO.puts/1)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @doc "The command as `{:ok, lines}` (the link first) or `{:error, message}`."
  def command(args) do
    {:ok, _} = Application.ensure_all_started([:exqlite, :inets])

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [release: :boolean, tailscale: :boolean, tailscale_serve_port: :integer]
      )

    with :ok <- check_options(invalid),
         {:ok, located} <- locate(opts[:release]) do
      running =
        case located do
          {home, record} ->
            Application.put_env(:hal_c2, :home, home)
            record

          nil ->
            nil
        end

      port = (running && running["port"]) || Application.get_env(:hal_c2, :port, 3780)
      serve_port = opts[:tailscale_serve_port] || HalC2.TailscaleServe.default_port()

      with {:ok, base} <- base(opts[:tailscale], port, serve_port, rest, running) do
        token = HalC2.Auth.create_pairing_token(HalC2.Store.home_path())
        link = "#{String.trim_trailing(base, "/")}/?token=#{token}"

        if opts[:tailscale] do
          {:ok,
           [
             link,
             "Tailscale Serve maps #{base} to this MC and keeps it across restarts. Remove it with `tailscale serve --https=#{serve_port} off`."
           ]}
        else
          {:ok, [link]}
        end
      end
    end
  end

  @doc """
  What to run to pair a client with this MC, for a message that tells the operator:
  the release's command when this MC is one, the Mix task from a checkout.
  """
  def command_name,
    do: if(HalC2.Upgrade.release_root(), do: "hal-c2-service pair", else: "mix hal_c2.pair")

  defp check_options([]), do: :ok

  defp check_options(invalid) do
    options = Enum.map_join(invalid, ", ", fn {option, _} -> option end)
    {:error, "Not an option of `#{command_name()}`, or given a bad value: #{options}"}
  end

  # With no home configured, the MC to pair with is the one that is running, in the
  # installed profile or the development one: its store takes the token and its
  # address goes in the link. `--release` names the installed one outright.
  defp locate(true) do
    case HalC2.RuntimeRecord.running(nil) do
      nil ->
        {:error,
         "The installed MC is not running. Start it, or leave --release out to pair with the MC this checkout runs."}

      record ->
        {:ok, {nil, record}}
    end
  end

  defp locate(_), do: {:ok, HalC2.RuntimeRecord.locate(Application.get_env(:hal_c2, :home))}

  defp base(true, port, serve_port, _rest, _running),
    do: HalC2.TailscaleServe.publish(port, serve_port)

  defp base(_, _port, _serve_port, rest, running),
    do: {:ok, List.first(rest) || (running && running["origin"]) || HalC2.Web.base_url()}
end
