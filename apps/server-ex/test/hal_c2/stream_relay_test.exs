defmodule HalC2.StreamRelayTest do
  use ExUnit.Case, async: true

  alias HalC2.Streams.Relay

  test "a stream that is killed takes a relay still sending what it starts from" do
    test = self()

    stream =
      spawn(fn ->
        relay =
          Relay.start(test, fn ->
            send(test, :sending)
            Process.sleep(:infinity)
          end)

        send(test, {:relay, relay})
        Process.sleep(:infinity)
      end)

    assert_receive {:relay, relay}
    assert_receive :sending
    ref = Process.monitor(relay)
    Process.exit(stream, :kill)
    assert_receive {:DOWN, ^ref, :process, ^relay, :killed}
  end
end
