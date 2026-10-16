defmodule Mix.Tasks.HalC2.Pair do
  @shortdoc "Prints a one-time pairing URL for this MC"
  @moduledoc """
  Mints a pairing token (valid 5 minutes, single use) and prints the URL a client
  opens or pastes to pair with this MC:

      mix hal_c2.pair [BASE_URL]
      mix hal_c2.pair --tailscale [--tailscale-serve-port PORT]
      mix hal_c2.pair --release [BASE_URL | --tailscale]

  See `HalC2.Pair`. An installed MC has the same command as `hal-c2-service pair ...`.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case HalC2.Pair.command(args) do
      {:ok, lines} -> Enum.each(lines, fn line -> Mix.shell().info(line) end)
      {:error, message} -> Mix.raise(message)
    end
  end
end
