defmodule HalC2.Frozen do
  @moduledoc """
  Marks a module that long-lived processes wait in, so its code changes only at a
  restart.

  Erlang moves a process to a module's new code only when the process next calls
  into the module by name, and a module keeps a single old version. A process that
  waits in a module's code (a `receive`, or a blocking call it made from there) for
  longer than one update keeps that version, and the next update refuses to load the
  module (`{:old_processes, M}`). So a process that may wait for long waits in a
  frozen module, which calls the code that changes by name once per event
  (`HalC2.Pump`). `HalC2.Upgrade.Release.plan/1` restarts the MC for a change to one,
  and the `HalC2.Credo.WaitsInChangingCode` check lets only frozen modules wait
  without an end.

      use HalC2.Frozen
  """

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :hal_c2_frozen, persist: true)
      @hal_c2_frozen true
    end
  end
end
