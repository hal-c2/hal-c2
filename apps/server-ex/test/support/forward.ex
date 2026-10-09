defmodule HalC2.Test.Forward do
  @moduledoc """
  A process that passes everything it is sent on to `to`. Spawned on another MC, it
  is a local tracer there for a test on this one.
  """

  def loop(to) do
    receive do
      message ->
        send(to, message)
        loop(to)
    end
  end
end
