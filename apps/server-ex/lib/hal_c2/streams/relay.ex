defmodule HalC2.Streams.Relay do
  @moduledoc """
  Carries one stream's messages to a subscriber on another MC.

  A send to another MC suspends the sender while that connection is busy, and a
  long thread's state takes seconds to cross a slow link. Sent from the stream
  itself, it kept the thread from taking changes or answering anyone for that long.
  The stream hands its messages to this process instead, so only the one subscriber
  waits for its link.
  """

  @doc """
  Starts a relay for the calling stream. It runs `initial`, which sends `subscriber`
  what it starts from, then passes on every stream message it is sent, in order. It
  stops with the stream or the subscriber; the stream kills it to stop sooner.
  """
  @spec start(pid, (-> any)) :: pid
  def start(subscriber, initial) do
    stream = self()

    spawn(fn ->
      Process.monitor(stream)
      Process.monitor(subscriber)
      initial.()
      # `initial` held the stream's whole state.
      :erlang.garbage_collect()
      __MODULE__.loop(subscriber)
    end)
  end

  @doc false
  def loop(subscriber) do
    receive do
      {:hal_c2_stream, _id, _message} = message ->
        send(subscriber, message)
        __MODULE__.loop(subscriber)

      {:DOWN, _ref, :process, _pid, _reason} ->
        :ok
    end
  end
end
