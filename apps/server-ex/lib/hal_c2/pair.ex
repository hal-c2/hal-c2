defmodule HalC2.Pair do
  @moduledoc """
  `mix hal_c2.pair` and `bin/hal-c2-service pair`: mints a pairing token (valid 5
  minutes, single use) and prints the URL a client opens or pastes to pair with this
  MC.

      pair [BASE_URL]
      pair --tailscale [--tailscale-serve-port PORT]
      pair --release [BASE_URL | --tailscale]

  `BASE_URL` is an http or https address with a host and no credentials, query or
  fragment, and defaults to the MC's own address (`HalC2.Web.base_url/0`), such as
  `http://127.0.0.1:3790` for the installed MC (`:3780` for one run from a checkout), or
  the LAN or tailnet address it was bound to.

  From a checkout with no HAL-C2 home configured it pairs with the MC that is running,
  whether that is the installed one or a development one (`HalC2.RuntimeRecord.locate/2`).
  When both run, that is the one of the profile the command was run from, so a checkout
  pairs with its own; `--release` pairs with the installed MC instead. The installed
  MC's own command (`hal-c2-service pair`) is always the installed profile's: it never
  pairs with a development MC, and fails when the installed one is not running. An
  installed MC started with `HAL_C2_HOME` or `HAL_C2_MC_HOME` is paired with by the
  same variables on this command, from a checkout too, though a checkout's own MC
  ignores `HAL_C2_HOME` (config/runtime.exs).

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
      # The located MC's store takes the token. The app env is left alone, so a caller
      # in a running MC keeps its own home.
      {home, running} = located || {Application.get_env(:hal_c2, :home), nil}
      port = (running && running["port"]) || Application.get_env(:hal_c2, :port, 3780)
      serve_port = opts[:tailscale_serve_port] || HalC2.TailscaleServe.default_port()

      dirs = HalC2.Paths.mc_dirs(home, System.get_env(), HalC2.Paths.user_home())

      with {:ok, base} <- base(opts[:tailscale], port, serve_port, rest, running, dirs) do
        # Minting ahead of a first start: the store's directory may not be there yet.
        if running == nil, do: HalC2.Paths.ensure!(dirs)
        token = HalC2.Auth.create_pairing_token(Path.join(dirs.data, "hal-c2.sqlite"))
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
  # fragment, without a scheme and host, with a space or a port no socket has, would mint
  # a token into a link nothing opens. Credentials would be printed in the link, and
  # `http://trusted@other-host` reads as the wrong destination.
  # `URI.new/1`, not `URI.parse/1`: parse lends `http://host:abc` the scheme's
  # default port and keeps illegal host characters and raw escapes, so each of
  # those would pass the checks below and mint a token into an unopenable link.
  # URI.new still lets an empty port (`http://host:`) through as the default,
  # so the raw authority is checked for a colon nothing follows.
  defp base_url?(url) do
    case URI.new(url) do
      {:ok,
       %URI{scheme: scheme, host: host, port: port, userinfo: nil, query: nil, fragment: nil}}
      when scheme in ["http", "https"] and host not in [nil, ""] and port in 1..65_535 ->
        not String.match?(url, ~r/\s/u) and
          not String.match?(url, ~r{://[^/?#]*:(?:$|[/?#])})

      _ ->
        false
    end
  end

  # A refused address is echoed rebuilt from its parsed form, without its
  # credentials, query or fragment (a pasted pairing link carries a live token
  # in those): the message lands in logs and script output. An address with no
  # parseable authority — scheme-less credentials, say — is not echoed at all,
  # as the raw text is exactly what must not be printed.
  defp redacted(url) do
    case URI.new(url) do
      {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" ->
        URI.to_string(%{uri | userinfo: uri.userinfo && "redacted", query: nil, fragment: nil})

      _ ->
        "(withheld)"
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
         "BASE_URL must be an http or https address with a host, a port from 1 to 65535 if any, and no credentials, spaces, query or fragment, such as http://127.0.0.1:3780, not #{redacted(hd(rest))}"}

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
    installed = installed_home(home)

    if release == true or HalC2.Upgrade.release_root() do
      installed(installed)
    else
      {:ok, HalC2.RuntimeRecord.locate(home, installed)}
    end
  end

  # The home the installed MC runs with in this environment: the `:home` a release or
  # `HAL_C2_MC_HOME` gave this command, else a `HAL_C2_HOME` root, which config/runtime.exs
  # applies to a release only, so a checkout's `:dev` does not carry it.
  defp installed_home(home) when home not in [nil, :dev], do: home

  defp installed_home(_home) do
    root = System.get_env("HAL_C2_HOME")
    if root && HalC2.Paths.root?(root, :root, HalC2.Paths.user_home()), do: {:root, root}
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

  defp base(true, port, serve_port, _rest, running, dirs),
    do: HalC2.TailscaleServe.publish(port, serve_port, located_id(dirs, running))

  defp base(_, _port, _serve_port, rest, running, _dirs),
    do: {:ok, List.first(rest) || (running && running["origin"]) || HalC2.Web.base_url()}

  # The located MC's environment id, for the Tailscale Serve check: read from its
  # home, or asked of the MC itself at its recorded origin. Never
  # `HalC2.Environment.id/0`: that is the *caller's* home's identity (and makes
  # and caches it), which is another MC when pairing across profiles — the check
  # would then bless a mapping that fronts the caller's MC and refuse the located
  # one's own. Nil only when no MC was located: the MC being paired is then this
  # command's own home, whose identity is the caller's to name. A located MC
  # whose id can be neither read nor asked for matches nothing (""), so an
  # existing mapping to it under another address is refused, not blessed against
  # the wrong identity.
  defp located_id(dirs, running) do
    file_id =
      case File.read(Path.join(dirs.data, "environment-id")) do
        {:ok, id} -> String.trim(id)
        _ -> ""
      end

    cond do
      file_id != "" -> file_id
      running == nil -> nil
      true -> origin_id(running["origin"]) || ""
    end
  end

  defp origin_id(origin) when is_binary(origin) do
    request = {String.to_charlist(origin <> "/.well-known/hal-c2/environment"), []}

    with {:ok, {{_, 200, _}, _, body}} <-
           :httpc.request(:get, request, [timeout: 2_000], body_format: :binary),
         {:ok, %{"environmentId" => id}} when is_binary(id) and id != "" <- JSON.decode(body) do
      id
    else
      _ -> nil
    end
  end

  defp origin_id(_origin), do: nil
end
