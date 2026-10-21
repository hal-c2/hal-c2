defmodule HalC2.Test.WsClient do
  @moduledoc "Minimal blocking WebSocket client for tests, speaking JSON text frames."

  @doc "Connects and upgrades; `transport_opts` go to the socket (`:gen_tcp`)."
  def connect(port, path, host \\ "127.0.0.1", transport_opts \\ []) do
    {:ok, conn} = Mint.HTTP.connect(:http, host, port, transport_opts: transport_opts)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, [])
    {conn, [{:status, ^ref, status}, {:headers, ^ref, headers} | rest]} = recv_http(conn, [])

    if status == 101 do
      {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, headers)
      # The server's first frame can arrive in the same packet as the upgrade response.
      early = for {:data, ^ref, data} <- rest, into: "", do: data
      {:ok, ws, frames} = Mint.WebSocket.decode(ws, early)

      {:ok,
       %{
         conn: conn,
         ws: ws,
         ref: ref,
         inbox: for({:text, text} <- frames, do: JSON.decode!(text))
       }}
    else
      {:error, status}
    end
  end

  def send_json(client, message) do
    {:ok, ws, data} =
      Mint.WebSocket.encode(
        client.ws,
        {:text, IO.iodata_to_binary(JSON.encode_to_iodata!(message))}
      )

    {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
    %{client | conn: conn, ws: ws}
  end

  @doc """
  Sends every message as its own frame but in one write, so they travel in one
  packet: the server handles every frame of a packet before it reads its mailbox.
  """
  def send_json_many(client, messages) do
    {data, ws} =
      Enum.map_reduce(messages, client.ws, fn message, ws ->
        {:ok, ws, data} =
          Mint.WebSocket.encode(
            ws,
            {:text, IO.iodata_to_binary(JSON.encode_to_iodata!(message))}
          )

        {IO.iodata_to_binary(data), ws}
      end)

    {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, Enum.join(data))
    %{client | conn: conn, ws: ws}
  end

  @doc """
  Waits until `pid`'s mailbox holds at least `count` messages — the receipt
  that frames a client sent have queued at a suspended process, in the order
  a test then resumes it in. Bounded: after `attempts` tries it raises with
  the mailbox it found, so a regression fails instead of hanging.
  """
  def await_mailbox(pid, count, attempts \\ 200) do
    {:message_queue_len, len} = Process.info(pid, :message_queue_len) || {:message_queue_len, 0}

    cond do
      len >= count ->
        :ok

      attempts <= 0 ->
        raise "mailbox of #{inspect(pid)} never held #{count} messages " <>
                "(#{len}): #{inspect(Process.info(pid, :messages), limit: 20)}"

      true ->
        receive do
        after
          5 -> await_mailbox(pid, count, attempts - 1)
        end
    end
  end

  @doc "Receives the next decoded JSON frame."
  def recv(%{inbox: [frame | rest]} = client, _timeout), do: {frame, %{client | inbox: rest}}

  def recv(client, timeout) do
    socket = Mint.HTTP.get_socket(client.conn)

    # Only this connection's socket messages; several clients may share a test process.
    receive do
      {tag, ^socket, _} = message when tag in [:tcp, :ssl] -> recv(feed(client, message), timeout)
    after
      timeout -> raise "no frame within #{timeout} ms"
    end
  end

  @doc """
  Decodes one of this connection's socket messages into its inbox, for a test
  process that receives from several sockets (and other processes) at once.
  """
  def feed(client, message) do
    {:ok, conn, [{:data, _, data}]} = Mint.WebSocket.stream(client.conn, message)
    {:ok, ws, frames} = Mint.WebSocket.decode(client.ws, data)
    decoded = for {:text, text} <- frames, do: JSON.decode!(text)
    %{client | conn: conn, ws: ws, inbox: client.inbox ++ decoded}
  end

  @doc """
  Receives frames until one matches `fun`, returning it and the frames skipped.
  `timeout` bounds the whole wait, not each frame: a trickle of non-matching
  frames does not extend it. The default is generous for that total bound —
  callers waiting on slow paths (resync, cluster, usage sources) pass more.
  """
  def recv_until(client, fun, timeout \\ 5_000, skipped \\ []) do
    deadline = System.monotonic_time(:millisecond) + timeout
    recv_until(client, fun, timeout, deadline, skipped)
  end

  defp recv_until(client, fun, timeout, deadline, skipped) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: raise("no frame within #{timeout} ms")

    {frame, client} =
      try do
        recv(client, remaining)
      rescue
        # `recv/2` reports the remainder it was given; the caller's budget is
        # the diagnostic that names the wait that actually expired.
        error in RuntimeError ->
          if error.message =~ "no frame within",
            do: raise("no frame within #{timeout} ms"),
            else: reraise(error, __STACKTRACE__)
      end

    if fun.(frame),
      do: {frame, Enum.reverse(skipped), client},
      else: recv_until(client, fun, timeout, deadline, [frame | skipped])
  end

  # Only this connection's socket messages, so a scenario's other mail (closed
  # sockets of earlier clients, service subscriptions) stays in the mailbox.
  defp recv_http(conn, acc) do
    socket = Mint.HTTP.get_socket(conn)

    # Only this connection's socket messages (data, close, error); the test process
    # also gets shell pushes.
    receive do
      message
      when is_tuple(message) and tuple_size(message) >= 2 and elem(message, 1) == socket ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)
        acc = acc ++ responses
        if Enum.any?(acc, &match?({:done, _}, &1)), do: {conn, acc}, else: recv_http(conn, acc)

      {tag, ^socket} = message when tag in [:tcp_closed, :ssl_closed] ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)
        {conn, acc ++ responses}
    end
  end
end
