defmodule HalC2.Test.LogTap do
  @moduledoc """
  A `:logger` handler that sends the test process each warning or worse the MC logs,
  as `{:logged, level, text}`: a log line a test can wait on as a receipt.
  """

  @doc "Taps the log for the rest of the test."
  def attach do
    id = :"hal_c2_log_tap_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{config: %{pid: self()}, level: :warning})
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(id) end)
  end

  @doc false
  def log(%{msg: msg, level: level}, %{config: %{pid: pid}}),
    do: send(pid, {:logged, level, text(msg)})

  defp text({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp text({:report, report}), do: inspect(report)
  defp text({format, args}), do: format |> :io_lib.format(args) |> IO.chardata_to_string()
end
