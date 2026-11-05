defmodule HalC2.AttachmentsTest do
  use ExUnit.Case, async: false
  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias HalC2.Attachments

  @moduletag :tmp_dir
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3>>

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    :persistent_term.erase({Attachments, :secret})
    on_exit(fn -> :persistent_term.erase({Attachments, :secret}) end)
    :ok
  end

  defp upload(bytes \\ @png) do
    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      Attachments.create_upload_url(%{
        "name" => "shot.png",
        "mimeType" => "image/png",
        "sizeBytes" => byte_size(bytes)
      })

    {id, token}
  end

  defp media_url(path) do
    {:ok, %{"relativeUrl" => url}} =
      Attachments.create_url(%{
        "resource" => %{"_tag" => "media-file", "threadId" => "t", "path" => path}
      })

    url
  end

  defp asset_token(url),
    do: url |> String.replace_prefix("/api/assets/", "") |> String.split("/") |> hd()

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
        flunk("asset producer exited: #{inspect(reason)}")
    after
      5_000 -> flunk("asset stream stalled")
    end
  end

  test "an upload is stored only with a valid token and the promised size" do
    {id, token} = upload()

    assert {:error, 400, _} = Attachments.store(token, "short")
    [payload, _signature] = String.split(token, ".")
    assert {:error, 403, _} = Attachments.store(payload <> ".forged", @png)
    assert :ok = Attachments.store(token, @png)
    assert File.read!(Attachments.path(%{"id" => id})) == @png
  end

  test "a message claims its uploads into the thread, and asset URLs serve them" do
    {id, token} = upload()
    :ok = Attachments.store(token, @png)

    attachment = %{
      "type" => "image",
      "id" => id,
      "name" => "shot.png",
      "mimeType" => "image/png",
      "sizeBytes" => byte_size(@png)
    }

    assert {:ok, [%{"id" => claimed}]} = Attachments.claim("Thread 42", [attachment])
    assert "thread-42-" <> _ = claimed
    # Already claimed attachments pass through.
    assert {:ok, [%{"id" => ^claimed}]} =
             Attachments.claim("Thread 42", [%{attachment | "id" => claimed}])

    assert {:error, "Attachment 'shot.png' was not uploaded."} =
             Attachments.claim("t", [
               %{attachment | "id" => "pending-00000000-0000-0000-0000-000000000000"}
             ])

    {:ok, %{"relativeUrl" => "/api/assets/" <> url}} =
      Attachments.create_url(%{
        "resource" => %{
          "_tag" => "attachment",
          "attachmentId" => claimed,
          "mimeType" => "image/png"
        }
      })

    [asset, _name] = String.split(url, "/")
    assert {:ok, 200, headers, stream} = Attachments.serve(asset)
    assert {:ok, @png, [_]} = collect_stream(stream)
    assert {"content-type", "image/png"} in headers
    assert {"content-disposition", ~s(attachment; filename="#{claimed}.png")} in headers
  end

  test "the HTTP routes take an upload and serve an asset" do
    {id, token} = upload()
    conn = conn(:post, "/api/attachments/upload/" <> token, @png) |> HalC2.Web.Router.call([])
    assert conn.status == 204

    {:ok, %{"relativeUrl" => url}} =
      Attachments.create_url(%{
        "resource" => %{
          "_tag" => "attachment",
          "attachmentId" => id,
          "mimeType" => "image/png",
          "fileName" => "shot.png"
        }
      })

    conn = conn(:get, url) |> HalC2.Web.Router.call([])
    assert conn.status == 200
    assert conn.resp_body == @png
    assert ["image/png" <> _] = Plug.Conn.get_resp_header(conn, "content-type")

    assert (conn(:get, "/api/assets/bad.token") |> HalC2.Web.Router.call([])).status == 403
  end

  test "media URLs serve only media files" do
    dir = Application.fetch_env!(:hal_c2, :home)
    File.write!(Path.join(dir, "clip.mp4"), "video")
    File.write!(Path.join(dir, "notes.txt"), "text")

    assert {:ok, _} =
             Attachments.create_url(%{
               "resource" => %{
                 "_tag" => "media-file",
                 "threadId" => "t",
                 "path" => Path.join(dir, "clip.mp4")
               }
             })

    assert {:error, %{"_tag" => "AssetPreviewTypeValidationError"}} =
             Attachments.create_url(%{
               "resource" => %{
                 "_tag" => "media-file",
                 "threadId" => "t",
                 "path" => Path.join(dir, "notes.txt")
               }
             })
  end

  test "media URLs serve audio files" do
    dir = Application.fetch_env!(:hal_c2, :home)

    for {name, type} <- [
          {"theme.mp3", "audio/mpeg"},
          {"theme.wav", "audio/wav"},
          {"theme.ogg", "audio/ogg"},
          {"theme.m4a", "audio/mp4"},
          {"theme.flac", "audio/flac"}
        ] do
      File.write!(Path.join(dir, name), "audio")

      assert {:ok, %{"relativeUrl" => url}} =
               Attachments.create_url(%{
                 "resource" => %{
                   "_tag" => "media-file",
                   "threadId" => "t",
                   "path" => Path.join(dir, name)
                 }
               })

      conn = conn(:get, url) |> HalC2.Web.Router.call([])
      assert conn.status == 200, name
      assert conn.resp_body == "audio"
      assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, type), name
    end
  end

  test "a large local response is delivered in bounded chunks" do
    dir = Application.fetch_env!(:hal_c2, :home)
    chunk = Attachments.chunk_bytes()
    bytes = :crypto.strong_rand_bytes(3 * chunk + 417)
    path = Path.join(dir, "large.mp4")
    File.write!(path, bytes)
    url = media_url(path)

    assert {:ok, 200, _headers, stream} = Attachments.serve(asset_token(url))
    assert {:ok, ^bytes, chunks} = collect_stream(stream)
    assert length(chunks) == 4
    assert Enum.all?(chunks, &(byte_size(&1) <= chunk))

    response = conn(:get, url) |> HalC2.Web.Router.call([])
    assert response.status == 200
    assert response.state == :chunked
    assert response.resp_body == bytes
  end

  test "full, ranged, open-ended and malformed requests keep their bytes and headers" do
    dir = Application.fetch_env!(:hal_c2, :home)
    bytes = :crypto.strong_rand_bytes(200_000)
    size = byte_size(bytes)
    path = Path.join(dir, "ranges.mp4")
    File.write!(path, bytes)
    url = media_url(path)

    requests = [
      {nil, nil, 200, bytes, nil},
      {"bytes=1000-1999", nil, 206, binary_part(bytes, 1000, 1000), "bytes 1000-1999/#{size}"},
      {"bytes=0-", nil, 206, bytes, "bytes 0-#{size - 1}/#{size}"},
      {"bytes=150000-", nil, 206, binary_part(bytes, 150_000, 50_000),
       "bytes 150000-#{size - 1}/#{size}"},
      {"bytes=-1000", nil, 206, binary_part(bytes, size - 1000, 1000),
       "bytes #{size - 1000}-#{size - 1}/#{size}"},
      {"bytes=1000-1999", ~s("old"), 206, binary_part(bytes, 1000, 1000),
       "bytes 1000-1999/#{size}"},
      {"bytes=not-a-range", nil, 200, bytes, nil},
      {"bytes=0-1,4-5", nil, 200, bytes, nil},
      {"bytes=999999-", nil, 416, "", "bytes */#{size}"}
    ]

    for {range, if_range, status, expected, content_range} <- requests do
      request = conn(:get, url)
      request = if range, do: put_req_header(request, "range", range), else: request
      request = if if_range, do: put_req_header(request, "if-range", if_range), else: request
      response = HalC2.Web.Router.call(request, [])

      assert response.status == status, "range: #{inspect(range)}"
      assert response.resp_body == expected, "range: #{inspect(range)}"

      expected_headers = if content_range, do: [content_range], else: []

      assert Plug.Conn.get_resp_header(response, "content-range") == expected_headers,
             "range: #{inspect(range)}"
    end
  end

  test "a media path swapped before open fails its descriptor identity check" do
    dir = Application.fetch_env!(:hal_c2, :home)
    path = Path.join(dir, "swap.mp4")
    secret = Path.join(dir, "secret.txt")
    File.write!(path, "signed video")
    File.write!(secret, "private target")
    token = asset_token(media_url(path))

    File.rm!(path)
    File.ln_s!(secret, path)

    assert {:error, 404, "The file is gone."} = Attachments.serve(token)
  end

  test "a media path swapped after open still serves only the signed inode" do
    dir = Application.fetch_env!(:hal_c2, :home)
    path = Path.join(dir, "open.mp4")
    secret = Path.join(dir, "secret.txt")
    bytes = :crypto.strong_rand_bytes(Attachments.chunk_bytes() + 31)
    File.write!(path, bytes)
    File.write!(secret, "private target")
    token = asset_token(media_url(path))

    assert {:ok, 200, _headers, stream} = Attachments.serve(token)
    File.rm!(path)
    File.ln_s!(secret, path)

    assert {:ok, ^bytes, chunks} = collect_stream(stream)
    assert length(chunks) == 2
    refute IO.iodata_to_binary(chunks) =~ "private target"
  end

  test "pasted images are stored straight into the thread" do
    data = "data:image/png;base64," <> Base.encode64(@png)

    assert {:ok,
            %{
              "attachments" => [
                %{"id" => "t1-" <> _ = id, "sizeBytes" => 11, "mimeType" => "image/png"}
              ]
            }} =
             Attachments.persist(%{
               "threadId" => "t1",
               "messageId" => "m",
               "attachments" => [
                 %{
                   "type" => "image",
                   "name" => "p.png",
                   "mimeType" => "image/png",
                   "sizeBytes" => 11,
                   "dataUrl" => data
                 }
               ]
             })

    assert File.read!(Attachments.path(%{"id" => id})) == @png

    assert {:error, %{"_tag" => "PersistChatAttachmentsError"}} =
             Attachments.persist(%{
               "threadId" => "t1",
               "attachments" => [%{"name" => "x", "dataUrl" => "nope"}]
             })
  end
end
