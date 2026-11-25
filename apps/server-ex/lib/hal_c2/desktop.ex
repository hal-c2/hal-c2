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

  A bootstrap with `stdinLifeline` asks for one more thing from
  that same pipe: the desktop holds its write end open for as
  long as it owns this MC, so standard input reaching its end —
  on EOF or on error — means the desktop process is gone,
  cleanly or by a native crash, and this MC (started by that
  desktop, for that desktop) stops itself. A bootstrap without
  it (the Node host, which ends the pipe after the line) never
  arms the watch.
  """

  @doc "Reads the bootstrap and applies it to the app env; a no-op outside the desktop app."
  def configure do
    with "1" <- System.get_env("HAL_C2_BOOTSTRAP_STDIN"),
         line when is_binary(line) <- IO.read(:stdio, :line) do
      bootstrap = JSON.decode!(line)
      apply_bootstrap(bootstrap)
      if bootstrap["stdinLifeline"] == true, do: start_stdin_lifeline()
    end

    :ok
  end

  # The watch is a process of its own reading the pipe
  # configure/0 read the line from (it inherits that group
  # leader), on the Pump like every spawned waiting loop: the
  # lines after the bootstrap are nobody's, so they are read and
  # dropped, and the end of the pipe stops the system. Spawned,
  # not linked, so it outlives the startup that armed it.
  defp start_stdin_lifeline do
    HalC2.Pump.spawn(__MODULE__, :stdin_lifeline)
    :ok
  end

  @doc false
  def step(:stdin_lifeline, :start),
    do: {:call, {IO, :read, [:stdio, :line]}, :stdin_lifeline}

  def step(:stdin_lifeline, {:called, line}) when is_binary(line),
    do: {:call, {IO, :read, [:stdio, :line]}, :stdin_lifeline}

  def step(:stdin_lifeline, {:called, _closed}) do
    desktop_exit().(0)
    {:done, :ok}
  end

  # How a lifeline EOF stops the MC (`System.stop/1` unless a
  # test swaps it, as an upgrade's restart swaps `:restart_exit`).
  defp desktop_exit do
    Application.get_env(:hal_c2, :desktop_exit, &System.stop/1)
  end

  @doc false
  def apply_bootstrap(bootstrap) do
    home = bootstrap["halC2Home"]

    if is_binary(home) and HalC2.Paths.root?(home, :root, HalC2.Paths.user_home()),
      do: Application.put_env(:hal_c2, :home, {:root, home})

    if port = bootstrap["port"], do: Application.put_env(:hal_c2, :port, port)
    if host = bootstrap["host"], do: Application.put_env(:hal_c2, :host, host)

    if token = bootstrap["desktopBootstrapToken"] do
      Application.put_env(:hal_c2, :desktop_token, token)
      Application.put_env(:hal_c2, :desktop_token_expires_at, HalC2.Auth.now() + :timer.hours(24))
    end

    :ok
  end
end
