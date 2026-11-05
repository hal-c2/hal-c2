defmodule HalC2.Attachments.GitHubMediaTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias HalC2.Attachments.GitHubMedia

  @moduletag :tmp_dir

  defmodule Upstream do
    @moduledoc false

    def init(opts), do: opts

    def call(conn, %{test: test, response: response}) do
      send(test, {:upstream_request, conn.request_path, conn.req_headers})
      response.(conn)
    end
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    :persistent_term.put({GitHubMedia, :token}, {System.system_time(:millisecond), "test-token"})

    on_exit(fn ->
      Application.delete_env(:hal_c2, :github_media_origin)
      Application.delete_env(:hal_c2, :github_media_max_bytes)
      :persistent_term.erase({GitHubMedia, :token})
    end)

    {:ok, dir: dir}
  end

  defp start_upstream(response) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {Upstream, %{test: self(), response: response}},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    Application.put_env(:hal_c2, :github_media_origin, "http://127.0.0.1:#{port}")
    pid
  end

  defp start_raw_upstream(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
      :ok = :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    Application.put_env(:hal_c2, :github_media_origin, "http://127.0.0.1:#{port}")
  end

  defp serve(dir, path, headers \\ %{}) do
    GitHubMedia.serve(
      %{
        "url" => "https://github.com" <> path,
        "cwd" => dir,
        "expiresAt" => System.system_time(:millisecond) + 60_000
      },
      headers
    )
  end

  defp collect_stream({:stream, pid, ref}) do
    monitor = Process.monitor(pid)
    send(pid, {ref, :start, self()})
    collect_stream(pid, ref, monitor, [])
  end

  defp collect_stream(pid, ref, monitor, chunks) do
    receive do
      {^ref, :chunk, bytes} ->
        send(pid, {ref, :ack})
        collect_stream(pid, ref, monitor, [bytes | chunks])

      {^ref, :done} ->
        Process.demonitor(monitor, [:flush])
        chunks = Enum.reverse(chunks)
        {:ok, IO.iodata_to_binary(chunks), chunks}

      {^ref, :error, reason} ->
        Process.demonitor(monitor, [:flush])
        {:error, reason, Enum.reverse(chunks)}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        flunk("GitHub producer exited: #{inspect(reason)}")
    after
      5_000 ->
        details = Process.info(pid, [:messages, :current_stacktrace])
        flunk("GitHub stream stalled: #{inspect(details, pretty: true)}")
    end
  end

  test "a successful upstream body is forwarded in bounded chunks", %{dir: dir} do
    bytes = :crypto.strong_rand_bytes(3 * HalC2.Attachments.chunk_bytes() + 19)
    Application.put_env(:hal_c2, :github_media_max_bytes, byte_size(bytes))

    start_upstream(fn conn ->
      conn |> put_resp_content_type("image/png", nil) |> send_resp(200, bytes)
    end)

    assert {:ok, 200, headers, stream} = serve(dir, "/media.png")
    assert {"content-type", "image/png"} in headers
    assert {"content-length", Integer.to_string(byte_size(bytes))} in headers
    assert {:ok, ^bytes, chunks} = collect_stream(stream)
    assert length(chunks) > 1
    assert Enum.all?(chunks, &(byte_size(&1) <= HalC2.Attachments.chunk_bytes()))
  end

  test "a declared oversized upstream body is refused before it is served", %{dir: dir} do
    Application.put_env(:hal_c2, :github_media_max_bytes, 16)

    start_raw_upstream(
      "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 17\r\nConnection: close\r\n\r\nx"
    )

    assert {:ok, 413, _headers, "GitHub media is too large."} = serve(dir, "/large.png")
  end

  test "an upstream body cut short declares its length and ends in an error", %{dir: dir} do
    start_raw_upstream(
      "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 10\r\nConnection: close\r\n\r\n1234"
    )

    case serve(dir, "/short.png") do
      {:ok, 502, _headers, ""} ->
        :ok

      {:ok, 200, headers, stream} ->
        assert {"content-length", "10"} in headers
        assert {:error, _reason, _chunks} = collect_stream(stream)
    end
  end

  test "an upstream body that grows past the cap is cut off", %{dir: dir} do
    Application.put_env(:hal_c2, :github_media_max_bytes, 16)

    start_upstream(fn conn ->
      conn = conn |> put_resp_content_type("image/png", nil) |> send_chunked(200)
      {:ok, conn} = chunk(conn, "12345678")
      {:ok, conn} = chunk(conn, "12345678")
      {:ok, conn} = chunk(conn, "12345678")
      conn
    end)

    case serve(dir, "/chunked.png") do
      {:ok, 413, _headers, "GitHub media is too large."} ->
        :ok

      {:ok, 200, _headers, stream} ->
        assert {:error, :too_large, chunks} = collect_stream(stream)
        assert chunks |> IO.iodata_to_binary() |> byte_size() <= 16
        assert Enum.all?(chunks, &(byte_size(&1) <= HalC2.Attachments.chunk_bytes()))
    end
  end

  test "range, if-range and validators survive the upstream hop", %{dir: dir} do
    start_upstream(fn conn ->
      conn
      |> put_resp_content_type("video/mp4", nil)
      |> put_resp_header("content-range", "bytes 2-3/10")
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("etag", ~s("v1"))
      |> put_resp_header("last-modified", "Wed, 21 Oct 2015 07:28:00 GMT")
      |> send_resp(206, "23")
    end)

    assert {:ok, 206, headers, stream} =
             serve(dir, "/range.mp4", %{"range" => "bytes=2-3", "if-range" => ~s("v1")})

    assert_received {:upstream_request, "/range.mp4", request_headers}
    assert {"range", "bytes=2-3"} in request_headers
    assert {"if-range", ~s("v1")} in request_headers
    assert {:ok, "23", _chunks} = collect_stream(stream)
    assert {"content-range", "bytes 2-3/10"} in headers
    assert {"accept-ranges", "bytes"} in headers
    assert {"etag", ~s("v1")} in headers
    assert {"last-modified", "Wed, 21 Oct 2015 07:28:00 GMT"} in headers
  end

  test "a non-media response is refused without streaming its body", %{dir: dir} do
    start_upstream(fn conn ->
      conn |> put_resp_content_type("text/html", nil) |> send_resp(200, "<html></html>")
    end)

    assert {:ok, 415, _headers, ""} = serve(dir, "/page")
  end

  test "the redirect limit still fails as a bad gateway", %{dir: dir} do
    start_upstream(fn conn ->
      number = conn.request_path |> Path.basename() |> String.to_integer()

      conn
      |> put_resp_header("location", "https://github.com/redirect/#{number + 1}")
      |> send_resp(302, "")
    end)

    assert {:ok, 502, _headers, ""} = serve(dir, "/redirect/0")

    for number <- 0..3 do
      path = "/redirect/#{number}"
      assert_received {:upstream_request, ^path, _headers}
    end
  end
end
