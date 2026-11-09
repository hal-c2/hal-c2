defmodule HalC2.ProviderInstallTest do
  use ExUnit.Case, async: true

  alias HalC2.ProviderInstall

  # Regression: a write that failed (a full disk) was ignored, so a truncated file was
  # reported as a dropped connection.
  @tag skip: not File.exists?("/dev/full")
  test "a download that cannot be written is a disk error, not an interrupted connection" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        body = String.duplicate("x", 4096)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
              body
          )

        :gen_tcp.close(socket)
      end)

    assert {:error, {:disk, :enospc}} =
             ProviderInstall.fetch("http://127.0.0.1:#{port}/pkg", "/dev/full", 4096, fn _ ->
               :ok
             end)

    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "a destination that cannot be opened is a disk error and starts no deadline timer" do
    dest = Path.join(System.tmp_dir!(), "no-such-dir-#{System.unique_integer([:positive])}/pkg")

    assert {:error, {:disk, :enoent}} =
             ProviderInstall.fetch("http://127.0.0.1:1/pkg", dest, 1, fn _ -> :ok end,
               deadline_ms: 1
             )

    refute_receive _, 20
  end
end
