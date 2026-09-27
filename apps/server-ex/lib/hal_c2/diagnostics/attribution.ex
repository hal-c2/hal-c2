defmodule HalC2.Diagnostics.Attribution do
  @moduledoc """
  The node's own file I/O by what it is for, the resource monitor's application
  I/O (`apps/server/src/resourceTelemetry/ResourceAttribution.ts`): logical bytes
  read and written, calls and time, per component and operation, since the node
  started. The trace file (`server-trace`, `append`) and provider event logs
  (`provider-event-log`, `native.append`) record here, as they do on the TypeScript
  server.

  These are the bytes the node asked to read or write, not what reached the disk;
  the storage counters of each process (`/proc/<pid>/io`) are separate.

  `HalC2.Diagnostics` owns the table, so a node without it records nothing.
  """

  @table __MODULE__

  @doc false
  def create, do: :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

  @doc """
  Adds one operation's `:read`, `:write` (bytes), `:count` (default 1) and
  `:duration_ms` to its totals.
  """
  def record(component, operation, measures) do
    key = {component, operation}

    :ets.update_counter(
      @table,
      key,
      [
        {2, amount(measures[:read], 0)},
        {3, amount(measures[:write], 0)},
        {4, amount(measures[:count], 1)},
        {5, amount(measures[:duration_ms], 0)}
      ],
      {key, 0, 0, 0, 0}
    )

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Runs `write`, which writes `bytes`, and records it with the time it took."
  def write(component, operation, bytes, write) do
    started = System.monotonic_time()
    result = write.()
    elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
    record(component, operation, write: bytes, duration_ms: elapsed)
    result
  end

  @doc "`ResourceAttributionEntry`s, the most written first."
  def entries do
    for {{component, operation}, read, write, count, ms} <- :ets.tab2list(@table) do
      %{
        "component" => component,
        "operation" => operation,
        "logicalReadBytes" => read,
        "logicalWriteBytes" => write,
        "count" => count,
        "durationMs" => ms
      }
    end
    |> Enum.sort_by(& &1["logicalWriteBytes"], :desc)
  rescue
    ArgumentError -> []
  end

  defp amount(value, _default) when is_integer(value), do: max(value, 0)
  defp amount(value, _default) when is_float(value), do: max(round(value), 0)
  defp amount(_value, default), do: default
end
