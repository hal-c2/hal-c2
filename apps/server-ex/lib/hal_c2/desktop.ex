defmodule HalC2.Desktop do
  @moduledoc """
  Running as the HAL-C2 desktop app's own node.

  The desktop app starts the release with `HALC2_BOOTSTRAP_STDIN=1` and writes one
  JSON line to its stdin: the bootstrap it gives the Node server (`port`, bind
  `host`, `halc2Home`, and `desktopBootstrapToken`). Its window exchanges that token at
  `/oauth/token` for a bearer session (`HalC2.Auth`), so the local machine needs no
  pairing. The token never appears in argv or the environment.

  Node state goes to `<halc2Home>/elixir`, apart from the Node server's.
  """

  @doc "Reads the bootstrap and applies it to the app env; a no-op outside the desktop app."
  def configure do
    with "1" <- System.get_env("HALC2_BOOTSTRAP_STDIN"),
         line when is_binary(line) <- IO.read(:stdio, :line) do
      apply_bootstrap(JSON.decode!(line))
    end

    :ok
  end

  @doc false
  def apply_bootstrap(bootstrap) do
    if home = bootstrap["halc2Home"], do: Application.put_env(:hal_c2, :home, Path.join(home, "elixir"))
    if port = bootstrap["port"], do: Application.put_env(:hal_c2, :port, port)
    if host = bootstrap["host"], do: Application.put_env(:hal_c2, :host, host)

    if token = bootstrap["desktopBootstrapToken"],
      do: Application.put_env(:hal_c2, :desktop_token, token)

    :ok
  end
end
