defmodule HalC2.Test.RunningPlugin do
  @moduledoc """
  Lets a test publish as plugin `id` without building one: run on the MC whose host
  is to take it as running.
  """

  def mark(id) do
    host = Process.whereis(HalC2.Plugins)
    :sys.replace_state(host, &put_in(&1.plugins[id].sup, host))
    :ok
  end
end
