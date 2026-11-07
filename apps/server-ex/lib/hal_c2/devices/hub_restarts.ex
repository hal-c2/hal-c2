defmodule HalC2.Devices.HubRestarts do
  @moduledoc """
  How long `HalC2.Devices` waits before restarting a device hub that exited on its own: one
  second, doubling with each exit that comes within a minute of the hub starting, up to 30
  seconds. A hub that ran for a minute starts over at one second.

  Times are monotonic milliseconds. `base` scales the waits and the minute alike, so tests
  can shorten both.
  """

  @max_factor 30
  @stable_ms 60_000

  defstruct base: 1_000, delay: nil, started_at: nil

  @doc "The restarts of a hub not yet started, waiting `base` ms first."
  def new(base \\ 1_000), do: %__MODULE__{base: base}

  @doc "The hub came up at `now`."
  def started(restarts, now), do: %{restarts | started_at: now}

  @doc "The hub exited at `now`: how long to wait before restarting it."
  def exited(%__MODULE__{base: base} = restarts, now) do
    quick? =
      restarts.started_at != nil and now - restarts.started_at < div(@stable_ms * base, 1_000)

    delay =
      if quick? and restarts.delay,
        do: min(restarts.delay * 2, base * @max_factor),
        else: base

    {delay, %{restarts | delay: delay, started_at: nil}}
  end
end
