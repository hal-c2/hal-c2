defmodule HalC2.KimiWirePropTest do
  @moduledoc """
  A state machine over Kimi CLI's session record (`HalC2.Acp.Kimi.read/2`): Kimi
  appends lines to it, cut anywhere (inside a line, inside a character), and the MC
  reads it from where its last read stopped, at any moment.

  The promise: every subagent event in a whole line is read once, in the order it was
  written, and nothing else is: not the parent's own lines, not a line that only
  mentions a subagent event, not a line still being written.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Acp.Kimi

  @moduletag timeout: :infinity

  property "each subagent event in the record is read once, in order",
    numtests: HalC2.Prop.numtests(200),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      path = Path.join(HalC2.Prop.scratch_home("kimi-wire"), "wire.jsonl")
      Process.put(:wire, {path, 0})
      {history, state, result} = run_commands(__MODULE__, cmds)

      (result == :ok)
      |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
      |> aggregate(command_names(cmds))
    end
  end

  # What Kimi has written, what it has still to write of the lines it began, and how
  # far into the written bytes the MC has read.
  def initial_state, do: %{written: "", pending: "", read: 0}

  def command(state) do
    frequency([
      {3, {:call, __MODULE__, :write, chunk(state.pending)}},
      {2, {:call, __MODULE__, :read, []}}
    ])
  end

  # The next bytes Kimi writes, some of what it began and of new lines, and what it
  # has left to write after them.
  defp chunk(pending) do
    let {lines, cut} <- {resize(4, list(line())), integer(0, 100)} do
      buffer = pending <> Enum.join(lines)
      at = div(byte_size(buffer) * cut, 100)
      [binary_part(buffer, 0, at), binary_part(buffer, at, byte_size(buffer) - at)]
    end
  end

  defp line do
    let {kind, parent, text} <-
          {oneof([:sub, :parent, :mention]), oneof(["tool_a", "tool_b"]),
           oneof(["", "lib", "på", "😀 x", "a\\nb"])} do
      message =
        case kind do
          :sub ->
            %{
              "type" => "SubagentEvent",
              "payload" => %{
                "parent_tool_call_id" => parent,
                "event" => %{"type" => "ContentPart", "payload" => %{"text" => text}}
              }
            }

          :parent ->
            %{"type" => "ContentPart", "payload" => %{"text" => text}}

          # The parent's own work can quote the record.
          :mention ->
            %{"type" => "ToolResult", "payload" => %{"output" => ~s("SubagentEvent" #{text})}}
        end

      JSON.encode!(%{"timestamp" => 0, "message" => message}) <> "\n"
    end
  end

  def precondition(_state, _call), do: true

  # A shrunk case may drop the write that began a line: what is read follows from
  # the bytes written alone.
  def next_state(state, _result, {:call, _, :write, [bytes, rest]}),
    do: %{state | written: state.written <> bytes, pending: rest}

  def next_state(state, _result, {:call, _, :read, []}),
    do: %{state | read: whole(state.written)}

  def postcondition(_state, {:call, _, :write, _}, result), do: result == :ok

  def postcondition(state, {:call, _, :read, []}, result) do
    unread = binary_part(state.written, state.read, whole(state.written) - state.read)
    result == expected(unread)
  end

  def write(bytes, _rest) do
    {path, _} = Process.get(:wire)
    File.write!(path, bytes, [:append])
  end

  def read do
    {path, offset} = Process.get(:wire)
    {events, offset} = Kimi.read(path, offset)
    Process.put(:wire, {path, offset})
    events
  end

  # The subagent events of whole lines, decoded as plainly as possible.
  defp expected(bytes) do
    for line <- String.split(bytes, "\n", trim: true),
        {:ok, %{"message" => %{"type" => "SubagentEvent", "payload" => payload}}} <-
          [JSON.decode(line)],
        do: {payload["parent_tool_call_id"], payload["event"]}
  end

  # How many bytes of `written` are whole lines.
  defp whole(written) do
    case :binary.matches(written, "\n") do
      [] -> 0
      matches -> matches |> List.last() |> then(fn {at, 1} -> at + 1 end)
    end
  end
end
