defmodule HalC2.Pair do
  @moduledoc """
  `mix hal_c2.pair` and `bin/hal-c2-service pair`: mints a pairing token (valid 5
  minutes, single use) and prints the URL a client opens or pastes to pair with this
  MC.

      pair [BASE_URL]
      pair --tailscale [--tailscale-serve-port PORT]
      pair --release [BASE_URL | --tailscale]

  `BASE_URL` is an http or https address with no query or fragment, and defaults to the MC's own address (`HalC2.Web.base_url/0`), such as
  `http://127.0.0.1:3790` for the installed MC (`:3780` for one run from a checkout), or
  the LAN or tailnet address it was bound to.

  From a checkout with no HAL-C2 home configured it pairs with the MC that is running,
  whether that is the installed one or a development one (`HalC2.RuntimeRecord.locate/1`).
  When both run, that is the one of the profile the command was run from, so a checkout
  pairs with its own; `--release` pairs with the installed MC instead. The installed
  MC's own command (`hal-c2-service pair`) is always the installed profile's: it never
  pairs with a development MC, and fails when the installed one is not running. An
  installed MC started with `HAL_C2_HOME` or `HAL_C2_MC_HOME` is paired with by the
  same variables on this command.

  `--tailscale` publishes the MC over Tailscale Serve HTTPS (port 443 unless
  `--tailscale-serve-port` names another, 1 to 65535) and pairs through the machine's
  tailnet name; it takes no BASE_URL. The mapping stays in tailscaled across restarts; a port that already serves
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
    # Only what the store and the Tailscale check need. Starting `:hal_c2` itself would
    # bind the MC's port inside this `eval`.
    {:ok, _} = Application.ensure_all_started([:exqlite, :inets])

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [release: :boolean, tailscale: :boolean, tailscale_serve_port: :integer]
      )

    with :ok <- check_options(invalid, rest, opts),
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

  # The link is the address with `/?token=` after it, so an address with its own query or
  # fragment, or without a scheme and host, would mint a token into a link nothing opens.
  defp base_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, query: nil, fragment: nil}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        true

      _ ->
        false
    end
  end

  defp check_options([], [_, _ | _], _opts),
    do: {:error, "`#{command_name()}` takes at most one BASE_URL"}

  defp check_options([], rest, opts) do
    port = opts[:tailscale_serve_port]

    cond do
      rest != [] and opts[:tailscale] ->
        {:error,
         "`#{command_name()} --tailscale` pairs through the tailnet name; it takes no BASE_URL"}

      match?([_], rest) and not base_url?(hd(rest)) ->
        {:error,
         "BASE_URL must be an http or https address with no query or fragment, such as http://127.0.0.1:3780, not #{hd(rest)}"}

      port && !opts[:tailscale] ->
        {:error, "`--tailscale-serve-port` only applies with `--tailscale`"}

      port && port not in 1..65_535 ->
        {:error, "`--tailscale-serve-port` must be a port from 1 to 65535, not #{port}"}

      true ->
        :ok
    end
  end

  defp check_options(invalid, _rest, _opts) do
    options =
      Enum.map_join(invalid, ", ", fn
        {option, nil} -> option
        {option, value} -> "#{option}=#{value}"
      end)

    {:error, "Not an option of `#{command_name()}`, or given a bad value: #{options}"}
  end

  # With no home configured, a checkout pairs with the MC that is running, in the
  # installed profile or the development one: its store takes the token and its
  # address goes in the link. `--release` names the installed one outright, and a release
  # is the installed profile, so its own command never looks at a development MC. A
  # chosen home (`HAL_C2_HOME`, `HAL_C2_MC_HOME`) is one MC's own: the release and
  # `--release` pair with the MC of that home, and fail when it is not running rather than
  # mint into a store nothing serves.
  defp locate(release) do
    home = Application.get_env(:hal_c2, :home)
    chosen = if home not in [nil, :dev], do: home

    if release == true or HalC2.Upgrade.release_root() do
      installed(chosen)
    else
      {:ok, HalC2.RuntimeRecord.locate(home)}
    end
  end

  defp installed(home) do
    case HalC2.RuntimeRecord.running(home) do
      nil -> {:error, not_running(home)}
      record -> {:ok, {home, record}}
    end
  end

  # "Leave --release out" only helps when no home was chosen: a chosen home is one MC's
  # own, and a checkout's other MC is not it.
  defp not_running(nil) do
    if HalC2.Upgrade.release_root(),
      do: "The installed MC is not running. Start it, then run `#{command_name()}` again.",
      else:
        "The installed MC is not running. Start it, or leave --release out to pair with the MC this checkout runs."
  end

  defp not_running(_home),
    do:
      "The installed MC is not running at the home HAL_C2_HOME or HAL_C2_MC_HOME names. Start it, then run `#{command_name()}` again."

  defp base(true, port, serve_port, _rest, _running),
    do: HalC2.TailscaleServe.publish(port, serve_port)

  defp base(_, _port, _serve_port, rest, running),
    do: {:ok, List.first(rest) || (running && running["origin"]) || HalC2.Web.base_url()}
end
