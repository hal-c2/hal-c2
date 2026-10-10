defmodule HalC2.Desktop do
  @moduledoc """
  Running as the HAL-C2 desktop app's own MC.

  The desktop app starts the release with `HAL_C2_BOOTSTRAP_STDIN=1` and writes one
  JSON line to its stdin: the bootstrap it gives the MC (`port`, bind
  `host`, `halC2Home`, and `desktopBootstrapToken`). Its window exchanges that token at
  `/oauth/token` for a bearer session (`HalC2.Auth`), so the local machine needs no
  pairing. The token never appears in argv or the environment.

  `halC2Home` is the root of the MC's files (`<halC2Home>/data/elixir` and so on);
  with none, or an old `~/.t3`/`~/.hal-c2` home, the MC
  uses the XDG directories.
  """

  @doc "Reads the bootstrap and applies it to the app env; a no-op outside the desktop app."
  def configure do
    with "1" <- System.get_env("HAL_C2_BOOTSTRAP_STDIN"),
         line when is_binary(line) <- IO.read(:stdio, :line) do
      apply_bootstrap(JSON.decode!(line))
    end

    :ok
  end

  @doc false
  def apply_bootstrap(bootstrap) do
    home = bootstrap["halC2Home"]

    if is_binary(home) and HalC2.Paths.root?(home, :root, HalC2.Paths.user_home()),
      do: Application.put_env(:hal_c2, :home, {:root, home})

    if port = bootstrap["port"], do: Application.put_env(:hal_c2, :port, port)
    if host = bootstrap["host"], do: Application.put_env(:hal_c2, :host, host)

    if token = bootstrap["desktopBootstrapToken"],
      do: Application.put_env(:hal_c2, :desktop_token, token)

    :ok
  end
end
