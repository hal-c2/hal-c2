defmodule HalC2.Orchestration.CommandTail do
  @moduledoc """
  The last `limit/0` bytes a running command printed, kept in memory and nowhere
  else. Output deltas never reach the thread's log (a build can print megabytes): the
  command's item carries only `outputSize`, so a client that shows the output asks for it
  (`orchestration.getCommandOutput`) and refetches when the size moves. Whatever the
  provider reports as the command's whole output is written when the command ends
  (`HalC2.Orchestration.TurnWriter.finish_item/4`), cut to the last `kept/0` bytes.
  """

  use GenServer

  @limit 64 * 1024
  @kept 256 * 1024
  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Bytes a running command's output keeps."
  def limit, do: @limit

  @doc "Bytes of a finished command's output the thread keeps."
  def kept, do: @kept

  @doc """
  Adds `text` to a command's output. Returns how many bytes it has printed in all, which is
  what a client watches.
  """
  def append(thread_id, item_id, text) do
    key = {thread_id, item_id}

    {tail, total} =
      case :ets.lookup(@table, key) do
        [{^key, tail, total}] -> {tail, total}
        [] -> {"", 0}
      end

    total = total + byte_size(text)
    tail = cut(tail <> text, @limit)
    :ets.insert(@table, {key, tail, total})
    total
  end

  @doc """
  Whether the store runs. A test that drives a provider runtime without the MC's services
  has none, and its command output goes to the item as it did before the store.
  """
  def running?, do: :ets.whereis(@table) != :undefined

  @doc "What a running command has printed, at most the last `limit/0` bytes, or nil."
  def get(thread_id, item_id) do
    with true <- running?(),
         [{_, tail, _}] <- :ets.lookup(@table, {thread_id, item_id}) do
      tail
    else
      _ -> nil
    end
  end

  @doc "Forgets a command's output: it ended and the thread has it."
  def delete(thread_id, item_id) do
    if running?(), do: :ets.delete(@table, {thread_id, item_id})
    :ok
  end

  @doc "Forgets every command's output on a thread: its run ended, so none is running."
  def drop_thread(thread_id) do
    if running?(), do: :ets.match_delete(@table, {{thread_id, :_}, :_, :_})
    :ok
  end

  @doc "`text` cut to its last `limit` bytes, from a whole character."
  def cut(text, limit) when byte_size(text) <= limit, do: text

  def cut(text, limit) do
    rest = binary_part(text, byte_size(text) - limit, limit)
    drop_partial(rest)
  end

  # A cut can land inside a multi-byte character: its leftover bytes go.
  defp drop_partial(<<byte, rest::binary>>) when byte in 0x80..0xBF, do: drop_partial(rest)
  defp drop_partial(bin), do: bin

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
