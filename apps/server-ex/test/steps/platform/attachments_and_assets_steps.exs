defmodule HalC2.Steps.Platform.AttachmentsAndAssets do
  @moduledoc "Steps for features/mc/platform/attachments-and-assets.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @mb 1024 * 1024
  @png_magic <<137, 80, 78, 71, 13, 10, 26, 10>>
  @fake_gh Path.expand("../../support/fake_gh.py", __DIR__)

  # --- helpers ---------------------------------------------------------------------

  defp png(size), do: @png_magic <> :crypto.strong_rand_bytes(size - byte_size(@png_magic))

  defp rpc(context, method, payload), do: World.call(context, method, payload, "paired")

  defp thread(context), do: World.thread_id(context, "main")
  defp root(context), do: World.project(context, "widgets").root

  # An upload URL for `size` bytes: `{attachment, relative_url}`.
  defp upload_url(context, type, name, mime, size, now \\ nil) do
    input = %{"type" => type, "name" => name, "mimeType" => mime, "sizeBytes" => size}

    {:ok, result} =
      if now,
        do: HalC2.Attachments.create_upload_url(input, now),
        else: elem(rpc(context, "attachments.createUploadUrl", input), 0)

    attachment = %{
      "type" => type,
      "id" => result["attachmentId"],
      "name" => name,
      "mimeType" => mime,
      "sizeBytes" => size
    }

    {attachment, result["relativeUrl"]}
  end

  # Uploads `bytes` and returns the attachment a message names.
  defp upload!(context, type, name, mime, bytes) do
    {attachment, url} = upload_url(context, type, name, mime, byte_size(bytes))
    assert {204, _, _} = Mc.request(context.mc, :post, url, body: bytes)
    attachment
  end

  defp send_message(context, attachments) do
    command = %{
      "type" => "message.dispatch",
      "threadId" => thread(context),
      "messageId" => "msg-#{System.unique_integer([:positive])}",
      "text" => "look at this",
      "attachments" => attachments,
      "dispatchMode" => %{"type" => "queue_after_active"}
    }

    {reply, context} = World.dispatch(context, command, "paired")
    context |> Map.put(:reply, reply) |> Map.put(:message_id, command["messageId"])
  end

  defp messages(thread_id),
    do:
      HalC2.StreamState.list(
        HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id)),
        "message"
      )

  defp message(context),
    do: Enum.find(messages(thread(context)), &(&1["id"] == context.message_id))

  defp create_url(context, resource) do
    {reply, context} = rpc(context, "assets.createUrl", %{"resource" => resource})
    Map.put(context, :asset, reply)
  end

  defp asset_url!(context) do
    assert {:ok, %{"relativeUrl" => url}} = context.asset
    url
  end

  defp token(url),
    do: url |> String.replace_prefix("/api/assets/", "") |> String.split("/") |> hd()

  defp host_file(context, name, bytes) do
    path = Path.join(Mc.tmp_dir(context.mc, "host"), name)
    File.write!(path, bytes)
    path
  end

  defp claimed_image(context) do
    image = upload!(context, "image", "shot.png", "image/png", png(4096))
    context = send_message(context, [image])
    assert {:ok, _} = context.reply
    [claimed] = message(context)["attachments"]
    {claimed, context}
  end

  # A resource for each row of the feature's tables, as `{resource, bytes}`.
  defp resource(context, "a thread attachment") do
    {claimed, _context} = claimed_image(context)

    {%{
       "_tag" => "attachment",
       "attachmentId" => claimed["id"],
       "fileName" => "shot.png",
       "mimeType" => "image/png"
     }, File.read!(HalC2.Attachments.path(claimed))}
  end

  defp resource(context, "a file in the project") do
    File.write!(Path.join(root(context), "notes.md"), "# notes\n")

    {%{"_tag" => "workspace-file", "threadId" => thread(context), "path" => "notes.md"},
     "# notes\n"}
  end

  defp resource(context, "a file for a draft in the project") do
    File.write!(Path.join(root(context), "draft.md"), "# draft\n")

    {%{"_tag" => "draft-workspace-file", "cwd" => root(context), "path" => "draft.md"},
     "# draft\n"}
  end

  defp resource(context, "a media file an agent wrote on the host") do
    bytes = png(2048)

    {%{
       "_tag" => "media-file",
       "threadId" => thread(context),
       "path" => host_file(context, "chart.png", bytes)
     }, bytes}
  end

  defp resource(context, "an attachment that is gone"),
    do: {%{"_tag" => "attachment", "attachmentId" => "#{thread(context)}-gone"}, nil}

  defp resource(context, "a project file that is gone"),
    do: {%{"_tag" => "workspace-file", "threadId" => thread(context), "path" => "gone.md"}, nil}

  defp resource(context, "a media file that is gone"),
    do:
      {%{
         "_tag" => "media-file",
         "threadId" => thread(context),
         "path" => Path.join(Mc.tmp_dir(context.mc, "host"), "gone.png")
       }, nil}

  defp resource(_context, "a project the MC does not know"),
    do: {%{"_tag" => "workspace-file", "threadId" => "th-unknown", "path" => "README.md"}, nil}

  defp resource(_context, "an asset kind this MC does not know"),
    do: {%{"_tag" => "hologram", "cwd" => "/"}, nil}

  defp fake_gh(context, rules) do
    home = context.mc.home
    World.put_app_env(:gh_command, @fake_gh)
    System.put_env("FAKE_GH_RULES", Path.join(home, "gh-rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(home, "gh.log"))
    :persistent_term.erase({HalC2.Attachments.GitHubMedia, :token})

    ExUnit.Callbacks.on_exit(fn ->
      System.delete_env("FAKE_GH_RULES")
      System.delete_env("FAKE_GH_LOG")
      :persistent_term.erase({HalC2.Attachments.GitHubMedia, :token})
    end)

    File.write!(Path.join(home, "gh-rules.json"), JSON.encode!(rules))
  end

  # A stand-in for GitHub: serves `bytes` as a PNG to requests carrying `token`, 404
  # otherwise, and tells the test what each request carried.
  defmodule FakeGitHub do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{test: test, token: token, bytes: bytes}) do
      auth = get_req_header(conn, "authorization")
      send(test, {:github_request, conn.request_path, auth})

      if auth == ["Bearer " <> token],
        do: conn |> put_resp_content_type("image/png", nil) |> send_resp(200, bytes),
        else: send_resp(conn, 404, "Not Found")
    end
  end

  defp private_github_image(context, signed_in \\ true) do
    token = "gho_private#{System.unique_integer([:positive])}"
    fake_gh(context, if(signed_in, do: gh_signed_in(token), else: []))
    bytes = png(1024)
    github_origin(%{test: self(), token: token, bytes: bytes})

    context
    |> Map.put(:github, %{token: token, bytes: bytes})
    |> create_url(%{
      "_tag" => "github-media",
      "cwd" => root(context),
      "url" => "https://github.com/user-attachments/assets/0f3c1d2e-screenshot"
    })
  end

  defp gh_signed_in(token), do: [%{"args" => ["auth", "token"], "stdout" => token <> "\n"}]

  # Points the MC's GitHub media fetches at a local stand-in answering with `plug`.
  defp github_origin(opts, plug \\ FakeGitHub) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {plug, opts},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :github_media_origin) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    Application.put_env(:hal_c2, :github_media_origin, "http://127.0.0.1:#{port}")
  end

  # A stand-in for GitHub's media hosts answering as `mode` says; it tells the test what
  # each request carried.
  defmodule FakeUpstream do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{test: test, mode: mode}) do
      send(test, {:upstream_request, conn.request_path, conn.req_headers})
      answer(conn, mode)
    end

    defp answer(conn, :not_found), do: send_resp(conn, 404, "Not Found")
    defp answer(conn, :server_error), do: send_resp(conn, 503, "Unavailable")

    defp answer(conn, :redirects) do
      n = conn.request_path |> String.split("/") |> List.last() |> Integer.parse()
      n = if match?({_, ""}, n), do: elem(n, 0), else: 0

      conn
      |> put_resp_header("location", "https://github.com/hop/#{n + 1}")
      |> send_resp(302, "")
    end

    defp answer(conn, :insecure_redirect),
      do: conn |> put_resp_header("location", "http://github.com/elsewhere") |> send_resp(302, "")

    defp answer(conn, :html),
      do: conn |> put_resp_content_type("text/html") |> send_resp(200, "<html>sign in</html>")

    defp answer(conn, :octet_stream) do
      conn
      |> put_resp_content_type("application/octet-stream", nil)
      |> send_resp(200, "mp4 bytes")
    end

    defp answer(conn, {:video, bytes}) do
      case get_req_header(conn, "range") do
        ["bytes=100-199"] ->
          conn
          |> put_resp_content_type("video/mp4", nil)
          |> put_resp_header("content-range", "bytes 100-199/#{byte_size(bytes)}")
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("etag", ~s("clip-v1"))
          |> put_resp_header("last-modified", "Wed, 21 Oct 2026 07:28:00 GMT")
          |> send_resp(206, binary_part(bytes, 100, 100))

        _ ->
          conn |> put_resp_content_type("video/mp4", nil) |> send_resp(200, bytes)
      end
    end
  end

  # An asset URL's signed claims, read without checking the signature.
  defp claims(url) do
    [payload | _] = url |> String.replace_prefix("/api/assets/", "") |> String.split(".")
    payload |> Base.url_decode64!(padding: false) |> JSON.decode!()
  end

  defp attachment_dir_count(context),
    do:
      HalC2.Attachments.dir()
      |> Path.join(String.downcase(thread(context)) <> "-*")
      |> Path.wildcard()
      |> length()

  # --- macOS stand-in: the commands the MC runs to find an application's icon -------

  @fake_mac Path.expand("../../support/fake_mac.sh", __DIR__)

  defp mac(context) do
    if context[:mac], do: context, else: Map.put(context, :mac, build_mac(context))
  end

  defp build_mac(context) do
    tools = Mc.tmp_dir(context.mc, "mac-tools")
    File.mkdir_p!(Path.join(tools, "used"))
    File.write!(Path.join(tools, "mdfind.out"), "")
    File.write!(Path.join(tools, "calls.log"), "")
    System.put_env("FAKE_MAC_DIR", tools)
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_MAC_DIR") end)

    bin = Path.join(tools, "bin")
    File.mkdir_p!(bin)
    for tool <- ~w(mdfind mdls plutil sips), do: File.ln_s!(@fake_mac, Path.join(bin, tool))
    World.put_app_env(:host_os, :darwin)
    World.put_app_env(:mac_tools_dir, bin)

    %{dir: tools, apps: Mc.tmp_dir(context.mc, "Applications")}
  end

  # An application bundle: `icon` is the file named by `plist`'s icon key, if any.
  defp mac_app(context, name, plist, resources) do
    bundle = Path.join(context.mac.apps, name)
    File.mkdir_p!(Path.join([bundle, "Contents", "Resources"]))
    File.write!(Path.join([bundle, "Contents", "Info.plist"]), plist)

    for {file, bytes} <- resources,
        do: File.write!(Path.join([bundle, "Contents", "Resources", file]), bytes)

    bundle
  end

  defp mac_calls(context),
    do:
      context.mac.dir |> Path.join("calls.log") |> File.read!() |> String.split("\n", trim: true)

  defp set_spotlight(context, bundles, used) do
    File.write!(Path.join(context.mac.dir, "mdfind.out"), Enum.join(bundles, "\n") <> "\n")

    for {bundle, date} <- Enum.zip(bundles, used),
        do: File.write!(Path.join([context.mac.dir, "used", Path.basename(bundle)]), date)
  end

  defp desktop_entry(dir, file, name, icon) do
    File.mkdir_p!(Path.join(dir, "applications"))

    File.write!(
      Path.join([dir, "applications", file]),
      "[Desktop Entry]\nType=Application\nName=#{name}\nExec=#{String.downcase(name)}\nIcon=#{icon}\n"
    )
  end

  defp xdg_data(context) do
    dir = Mc.tmp_dir(context.mc, "xdg")

    for var <- ["XDG_DATA_HOME", "XDG_DATA_DIRS"] do
      previous = System.get_env(var)
      System.put_env(var, dir)

      ExUnit.Callbacks.on_exit(fn ->
        if previous, do: System.put_env(var, previous), else: System.delete_env(var)
      end)
    end

    dir
  end

  defp read(context, url, headers \\ []),
    do: Map.put(context, :response, Mc.request(context.mc, :get, url, headers: headers))

  defp read_chunks(context, url) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", context.mc.port, mode: :passive)
    {:ok, conn, request} = Mint.HTTP.request(conn, "GET", url, [], nil)
    result = mint_response(conn, request, %{status: nil, headers: [], chunks: []})
    {:ok, _conn} = Mint.HTTP.close(conn)
    chunks = Enum.reverse(result.chunks)

    Map.put(context, :response, {result.status, result.headers, IO.iodata_to_binary(chunks)})
  end

  defp stream_pieces(pid, ref, pieces) do
    receive do
      {^ref, :chunk, bytes} ->
        send(pid, {ref, :ack})
        stream_pieces(pid, ref, [bytes | pieces])

      {^ref, :done} ->
        Enum.reverse(pieces)
    after
      5_000 -> flunk("the asset stream stalled")
    end
  end

  defp mint_response(conn, request, result) do
    {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 10_000)

    {result, done} =
      Enum.reduce(responses, {result, false}, fn
        {:status, ^request, status}, {result, _} ->
          {%{result | status: status}, false}

        {:headers, ^request, headers}, {result, _} ->
          {%{result | headers: headers}, false}

        {:data, ^request, bytes}, {result, _} ->
          {%{result | chunks: [bytes | result.chunks]}, false}

        {:done, ^request}, {result, _} ->
          {result, true}
      end)

    if done, do: result, else: mint_response(conn, request, result)
  end

  step "the client reads the video without a range", context do
    read_chunks(context, asset_url!(context))
  end

  # Over the wire the body is length-delimited, so how it splits into reads is TCP's
  # business; the bound is on what the MC reads and holds per piece.
  step "the MC serves the whole video in bounded pieces", context do
    assert {200, headers, body} = context.response
    assert body == context.bytes
    assert {"content-length", Integer.to_string(byte_size(body))} in headers

    assert {:ok, 200, _headers, {:stream, pid, ref}} =
             HalC2.Attachments.serve(token(asset_url!(context)))

    send(pid, {ref, :start, self()})
    pieces = stream_pieces(pid, ref, [])
    assert IO.iodata_to_binary(pieces) == context.bytes
    assert length(pieces) > 1
    assert Enum.all?(pieces, &(byte_size(&1) <= HalC2.Attachments.chunk_bytes()))
    context
  end

  # --- background ------------------------------------------------------------------

  step "a running MC with a project and a thread", context do
    context |> World.create_project("widgets") |> World.create_thread("main", "widgets")
  end

  # --- uploads ---------------------------------------------------------------------

  step "sends the image's bytes to that URL", context do
    Map.put(
      context,
      :response,
      Mc.request(context.mc, :post, context.upload_url, body: png(2 * @mb))
    )
  end

  step "the MC accepts the upload", context do
    assert {204, _, _} = context.response
    path = HalC2.Attachments.path(context.attachment)
    assert File.stat!(path).size == 2 * @mb
    context
  end

  step "an upload URL issued eleven minutes ago", context do
    now = System.system_time(:millisecond) - 11 * 60_000
    {attachment, url} = upload_url(context, "image", "shot.png", "image/png", 1024, now)
    Map.merge(context, %{attachment: attachment, upload_url: url})
  end

  step "the client sends bytes to it", context do
    Map.put(
      context,
      :response,
      Mc.request(context.mc, :post, context.upload_url, body: png(1024))
    )
  end

  step "the MC refuses the link as invalid or expired", context do
    assert {403, _, "The link is invalid or expired."} = context.response
    refute HalC2.Attachments.path(context.attachment)
    context
  end

  step ~r/^the client asks for an upload URL for (?:an|a) (?<size>\d+) MB (?<kind>image|document)$/,
       %{args: [size, kind]} = context do
    {type, name, mime} =
      if kind == "image",
        do: {"image", "shot.png", "image/png"},
        else: {"file", "report.pdf", "application/pdf"}

    input = %{
      "type" => type,
      "name" => name,
      "mimeType" => mime,
      "sizeBytes" => String.to_integer(size) * @mb
    }

    {reply, context} = rpc(context, "attachments.createUploadUrl", input)

    case reply do
      {:ok, %{"attachmentId" => id, "relativeUrl" => url}} ->
        Map.merge(context, %{reply: reply, attachment: Map.put(input, "id", id), upload_url: url})

      _ ->
        Map.put(context, :reply, reply)
    end
  end

  step ~r/^the MC refuses saying attachments may be at most (?<limit>\d+ MB)$/,
       %{args: [limit]} = context do
    assert {:error, message, _} = context.reply
    assert message == "Attachments may be at most #{limit}."
    context
  end

  step "the client sends more than 50 MB to an upload URL", context do
    {_attachment, url} =
      upload_url(context, "file", "big.bin", "application/octet-stream", 50 * @mb)

    body = :binary.copy(<<0>>, 50 * @mb + 1)
    Map.put(context, :response, Mc.request(context.mc, :post, url, body: body))
  end

  step "the MC answers that the upload is too large", context do
    assert {413, _, "The upload is too large."} = context.response
    context
  end

  step "an upload URL for a 2 MB file", context do
    {attachment, url} = upload_url(context, "file", "notes.txt", "text/plain", 2 * @mb)
    Map.merge(context, %{attachment: attachment, upload_url: url})
  end

  step "the client sends 1 MB to it", context do
    Map.put(
      context,
      :response,
      Mc.request(context.mc, :post, context.upload_url, body: :binary.copy("a", @mb))
    )
  end

  step "the MC answers that the body is the wrong size", context do
    assert {400, _, "The body is the wrong size."} = context.response
    refute HalC2.Attachments.path(context.attachment)
    context
  end

  step "the client sends bytes to an asset URL as if it were an upload URL", context do
    path = host_file(context, "chart.png", png(512))

    context =
      create_url(context, %{"_tag" => "media-file", "threadId" => thread(context), "path" => path})

    upload = "/api/attachments/upload/" <> token(asset_url!(context))
    Map.put(context, :response, Mc.request(context.mc, :post, upload, body: png(512)))
  end

  step "the MC refuses it as not an upload URL", context do
    assert {403, _, "Not an upload URL."} = context.response
    context
  end

  # --- claims ----------------------------------------------------------------------

  step "the client uploaded an image", context do
    Map.put(context, :attachment, upload!(context, "image", "shot.png", "image/png", png(4096)))
  end

  step "the client sends a message naming that upload", context do
    send_message(context, [context.attachment])
  end

  step "the image belongs to the thread", context do
    assert {:ok, _} = context.reply

    assert [%{"id" => id, "name" => "shot.png", "type" => "image"}] =
             message(context)["attachments"]

    refute String.starts_with?(id, "pending-")
    assert String.starts_with?(id, thread(context))
    context
  end

  step "the provider can read it", context do
    [claimed] = message(context)["attachments"]
    path = HalC2.Attachments.path(claimed)
    assert File.read!(path) == File.read!(HalC2.Attachments.path(context.attachment))

    assert HalC2.Attachments.prompt_text("look", [%{type: "image", name: "shot.png", path: path}]) =~
             path

    context
  end

  step "the thread has a message with an attached image and an attached text file", context do
    image = upload!(context, "image", "shot.png", "image/png", png(4096))
    text = upload!(context, "file", "notes.txt", "text/plain", "remember the milk\n")
    context = send_message(context, [image, text])
    assert {:ok, _} = context.reply
    context
  end

  step "the MC starts and the thread's history loads with both attachments", context do
    assert [image, text] = message(context)["attachments"]
    assert %{"type" => "image", "name" => "shot.png"} = image
    assert %{"type" => "file", "name" => "notes.txt"} = text
    assert File.read!(HalC2.Attachments.path(text)) == "remember the milk\n"
    assert File.regular?(HalC2.Attachments.path(image))
    context
  end

  step "the client sends a message naming an upload it never sent", context do
    ghost = %{
      "type" => "image",
      "id" => "pending-00000000-0000-4000-8000-000000000000",
      "name" => "ghost.png",
      "mimeType" => "image/png",
      "sizeBytes" => 10
    }

    send_message(context, [ghost])
  end

  step "the message fails saying the attachment was not uploaded", context do
    assert {:error, "Attachment 'ghost.png' was not uploaded.", _} = context.reply
    refute message(context)
    context
  end

  step "it sends a message naming that upload with another size", context do
    send_message(context, [%{context.attachment | "sizeBytes" => 99}])
  end

  step "the message fails saying the attachment does not match its upload", context do
    assert {:error, "Attachment 'shot.png' does not match its upload.", _} = context.reply
    refute message(context)
    context
  end

  step "an upload no message claimed for 25 hours", context do
    attachment = upload!(context, "image", "old.png", "image/png", png(256))
    path = HalC2.Attachments.path(attachment)
    File.touch!(path, System.os_time(:second) - 25 * 60 * 60)
    # The sweep runs at most every 15 minutes; this scenario starts a fresh window.
    :persistent_term.erase({HalC2.Attachments, :swept})
    Map.merge(context, %{attachment: attachment, old_path: path})
  end

  step "the MC has removed it", context do
    # Asking for an upload URL is what runs the sweep.
    fresh = upload!(context, "image", "new.png", "image/png", png(256))
    refute File.exists?(context.old_path)
    assert HalC2.Attachments.path(fresh)
    context
  end

  step "it deletes that upload", context do
    {reply, context} =
      rpc(context, "attachments.delete", %{"attachmentId" => context.attachment["id"]})

    assert {:ok, _} = reply
    context
  end

  step "the upload is gone", context do
    refute HalC2.Attachments.path(context.attachment)
    context
  end

  step "the client sends a message with pasted images inline", context do
    bytes = png(300)

    input = %{
      "threadId" => thread(context),
      "attachments" => [
        %{
          "name" => "paste-1.png",
          "mimeType" => "image/png",
          "dataUrl" => "data:image/png;base64," <> Base.encode64(bytes)
        },
        %{
          "name" => "paste-2.png",
          "mimeType" => "image/png",
          "dataUrl" => "data:image/png;base64," <> Base.encode64(bytes)
        }
      ]
    }

    {reply, context} = rpc(context, "assets.persistChatAttachments", input)
    Map.merge(context, %{reply: reply, pasted: bytes})
  end

  step "the MC stores them as thread attachments", context do
    assert {:ok, %{"attachments" => [first, second]}} = context.reply

    for {stored, name} <- [{first, "paste-1.png"}, {second, "paste-2.png"}] do
      assert %{"type" => "image", "name" => ^name, "sizeBytes" => 300} = stored
      assert String.starts_with?(stored["id"], thread(context))
      assert File.read!(HalC2.Attachments.path(stored)) == context.pasted
    end

    context
  end

  # --- asset URLs ------------------------------------------------------------------

  step ~r/^the client asks for an asset URL for (?!the GitHub media address|"https?:)(?<resource>.+)$/,
       %{args: [name]} = context do
    {resource, bytes} = resource(context, name)
    context |> Map.merge(%{resource: resource, bytes: bytes}) |> create_url(resource)
  end

  step "the MC returns a URL that serves the file", context do
    context = read(context, asset_url!(context))
    assert {200, _, body} = context.response
    assert body == context.bytes
    context
  end

  step "the URL stops working after an hour", context do
    assert {:ok, %{"expiresAt" => expires}} = context.asset
    assert_in_delta expires, System.system_time(:millisecond) + 60 * 60_000, 60_000
    # The same file signed an hour and a minute ago no longer serves.
    issued = System.system_time(:millisecond) - 61 * 60_000

    {:ok, %{"relativeUrl" => old}} =
      HalC2.Attachments.create_url(%{"resource" => context.resource}, issued)

    assert {403, _, "The link is invalid or expired."} = Mc.request(context.mc, :get, old)
    context
  end

  step "the client reads a signed asset URL", context do
    {resource, _bytes} = resource(context, "a thread attachment")
    context |> create_url(resource) |> then(&read(&1, asset_url!(&1)))
  end

  step "the response may be cached privately for an hour", context do
    assert {200, headers, _} = context.response
    assert {"cache-control", "private, max-age=3600"} in headers
    context
  end

  step "it names the file for download", context do
    {200, headers, _} = context.response
    assert {"content-disposition", ~s(attachment; filename="shot.png")} in headers
    context
  end

  step "the client asks for a media URL for a text file", context do
    path = host_file(context, "notes.txt", "plain text")
    create_url(context, %{"_tag" => "media-file", "threadId" => thread(context), "path" => path})
  end

  step "the MC refuses saying only media files are served", context do
    assert {:error, "Only media files are served.",
            %{"_tag" => "AssetPreviewTypeValidationError"}} =
             context.asset

    context
  end

  step ~r/^the MC fails with (?<tag>Asset\w+Error)$/, %{args: [tag]} = context do
    assert {:error, _message, %{"_tag" => ^tag} = detail} = context.asset
    # The GitHub media error carries nothing: it must not repeat the address.
    assert Map.get(detail, "resource", context.resource) == context.resource
    context
  end

  step "a signed URL for a project file", context do
    {resource, _} = resource(context, "a file in the project")
    context |> Map.put(:resource, resource) |> create_url(resource)
  end

  step "the file is deleted", context do
    File.rm!(Path.join(root(context), "notes.md"))
    context
  end

  step "the client reads the URL", context do
    read(context, asset_url!(context))
  end

  step "the MC answers that the file is gone", context do
    assert {404, _, "The file is gone."} = context.response
    context
  end

  step "an asset URL issued by another member", context do
    {mc, peer} = Mc.cluster(context.mc)
    bytes = png(3 * HalC2.Attachments.chunk_bytes() + 117)
    path = Path.join(peer.home, "peer-chart.png")
    File.mkdir_p!(peer.home)
    File.write!(path, bytes)

    resource = %{"_tag" => "media-file", "threadId" => "th-peer", "path" => path}

    {:ok, %{"relativeUrl" => url}} =
      :erpc.call(peer.name, HalC2.Attachments, :create_url, [%{"resource" => resource}])

    Map.merge(context, %{mc: mc, peer: peer, peer_url: url, bytes: bytes})
  end

  step "the client reads it through the MC it is connected to", context do
    read(context, context.peer_url)
  end

  step "the MC forwards the request to the issuer", context do
    assert {200, _, body} = context.response
    assert body == context.bytes
    assert {:ok, context.peer.name} == HalC2.Attachments.issuer(token(context.peer_url))
    context
  end

  step "only the issuer checks the signature", context do
    # This MC's own key does not verify the peer's signature; the peer's does.
    token = token(context.peer_url)
    assert {:error, 403, _} = HalC2.Attachments.serve(token)

    assert {:ok, 200, _, _} =
             :erpc.call(context.peer.name, HalC2.Attachments, :serve, [token, %{}])

    context
  end

  step "the MC fails saying files are not served by this MC yet", context do
    assert {:error, message, %{"_tag" => "AssetWorkspaceResolutionError"}} = context.asset
    assert message == "#{context.resource["_tag"]} files are not served by this MC yet."
    context
  end

  # --- favicons --------------------------------------------------------------------

  step "a project with a favicon in its repository", context do
    icon = "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"4\"/></svg>"
    File.mkdir_p!(Path.join(root(context), "public"))
    File.write!(Path.join([root(context), "public", "favicon.svg"]), icon)
    Map.put(context, :bytes, icon)
  end

  step "a project with no favicon", context do
    Map.put(context, :bytes, nil)
  end

  step "a client asks for the project's favicon", context do
    context = create_url(context, %{"_tag" => "project-favicon", "cwd" => root(context)})
    read(context, asset_url!(context))
  end

  step "the MC serves that icon", context do
    assert {200, headers, body} = context.response
    assert body == context.bytes
    assert {"content-type", "image/svg+xml"} in headers
    assert asset_url!(context) =~ ~r/\/v[0-9a-f]{64}-favicon\.svg$/
    context
  end

  step "the client shows the default project icon", context do
    # The URL names the fallback marker, which the client reads as "draw the default".
    assert String.ends_with?(asset_url!(context), "/project-favicon-missing")
    context
  end

  # --- native app icons ------------------------------------------------------------

  step "a work log entry that names an application on the host", context do
    dir = xdg_data(context)
    icon = png(700)
    icons = Path.join([dir, "icons", "hicolor", "64x64", "apps"])
    File.mkdir_p!(icons)
    File.write!(Path.join(icons, "sketchpad.png"), icon)
    desktop_entry(dir, "org.example.Sketchpad.desktop", "Sketchpad", "sketchpad")

    Map.merge(context, %{
      app: %{"_tag" => "display-name", "displayName" => "Sketchpad"},
      bytes: icon
    })
  end

  step "a work log entry naming an application the host does not have", context do
    xdg_data(context)
    Map.put(context, :app, %{"_tag" => "app-id", "appId" => "org.example.Nowhere"})
  end

  step ~r/^a client asks for (?:that application's|its) icon$/, context do
    context = create_url(context, %{"_tag" => "native-app-icon", "app" => context.app})
    read(context, asset_url!(context))
  end

  step "the MC serves the icon", context do
    assert {200, headers, body} = context.response
    assert body == context.bytes
    assert {"content-type", "image/png"} in headers
    context
  end

  step "the entry keeps its text", context do
    # Only the icon is missing: the URL was issued, so the entry renders with its label.
    assert {:ok, %{"relativeUrl" => "/api/assets/" <> _}} = context.asset
    assert {404, _, _} = context.response
    context
  end

  # --- GitHub media ----------------------------------------------------------------

  step "a pull request comment with an image in a private repository", context do
    private_github_image(context)
  end

  step "a client asks for that image", context do
    read(context, asset_url!(context))
  end

  step "the MC fetches it with the host's GitHub credentials and serves it", context do
    token = context.github.token

    assert_received {:github_request, "/user-attachments/assets/0f3c1d2e-screenshot",
                     ["Bearer " <> ^token]}

    assert {200, headers, body} = context.response
    assert body == context.github.bytes
    assert {"content-type", "image/png"} in headers
    context
  end

  step "a client reads proxied GitHub media", context do
    context = private_github_image(context)
    read(context, asset_url!(context))
  end

  step "the response carries no GitHub token", context do
    assert {200, headers, body} = context.response
    assert body == context.github.bytes
    refute Enum.any?(headers, fn {_k, v} -> String.contains?(v, context.github.token) end)
    refute String.contains?(asset_url!(context), context.github.token)
    context
  end

  # --- file identity and ranges ----------------------------------------------------

  step "a signed URL for a media file on the host", context do
    path = host_file(context, "chart.png", png(900))

    context =
      create_url(context, %{"_tag" => "media-file", "threadId" => thread(context), "path" => path})

    Map.put(context, :media_path, path)
  end

  step "the file is replaced atomically by another file", context do
    replacement = context.media_path <> ".tmp"
    File.write!(replacement, png(900))
    File.rename!(replacement, context.media_path)
    context
  end

  step "the old URL no longer serves it", context do
    assert {404, _, "The file is gone."} = Mc.request(context.mc, :get, asset_url!(context))
    context
  end

  step "editing the same file in place keeps the URL working", context do
    context =
      create_url(context, %{
        "_tag" => "media-file",
        "threadId" => thread(context),
        "path" => context.media_path
      })

    edited = png(900)
    {:ok, file} = File.open(context.media_path, [:write, :read, :binary])
    :ok = :file.pwrite(file, 0, edited)
    :ok = File.close(file)
    assert {200, _, body} = Mc.request(context.mc, :get, asset_url!(context))
    assert body == edited
    context
  end

  step "a signed URL for a video on the host", context do
    bytes = :crypto.strong_rand_bytes(200_000)
    path = host_file(context, "demo.mp4", bytes)

    context =
      create_url(context, %{"_tag" => "media-file", "threadId" => thread(context), "path" => path})

    Map.put(context, :bytes, bytes)
  end

  step "a player seeks into the video", context do
    read(context, asset_url!(context), [{"range", "bytes=150000-150999"}])
  end

  step "the MC serves the requested range", context do
    assert {206, headers, body} = context.response
    assert body == binary_part(context.bytes, 150_000, 1000)
    assert {"content-range", "bytes 150000-150999/200000"} in headers
    assert {"content-type", "video/mp4"} in headers
    context
  end

  # --- claims that fail or are refused ----------------------------------------------

  step "the client uploaded two images", context do
    first = upload!(context, "image", "one.png", "image/png", png(2048))
    second = upload!(context, "image", "two.png", "image/png", png(2048))
    Map.put(context, :attachments, [first, second])
  end

  step "the client sends a message naming both and the second cannot be claimed", context do
    [first, second] = context.attachments
    send_message(context, [first, %{second | "sizeBytes" => 99}])
  end

  step "the message fails naming the second image", context do
    assert {:error, "Attachment 'two.png' does not match its upload.", _} = context.reply
    context
  end

  step "the first image does not belong to the thread", context do
    assert attachment_dir_count(context) == 0
    context
  end

  step "both uploads can still be sent again", context do
    context = send_message(context, context.attachments)
    assert {:ok, _} = context.reply
    assert [%{"name" => "one.png"}, %{"name" => "two.png"}] = message(context)["attachments"]
    context
  end

  # A steer aimed at a run that does not exist is a delivery no provider can make.
  step "the client sends a message naming that upload and the MC refuses the message", context do
    command = %{
      "type" => "message.dispatch",
      "threadId" => thread(context),
      "messageId" => "msg-#{System.unique_integer([:positive])}",
      "text" => "look at this",
      "attachments" => [context.attachment],
      "dispatchMode" => %{"type" => "steer_active", "targetRunId" => "run-that-is-not-active"}
    }

    {reply, context} = World.dispatch(context, command, "paired")
    assert {:error, _, _} = reply
    Map.put(context, :reply, reply)
  end

  step "the image does not belong to the thread", context do
    assert attachment_dir_count(context) == 0
    context
  end

  step "the upload can still be sent again", context do
    context = send_message(context, [context.attachment])
    assert {:ok, _} = context.reply
    context
  end

  # --- removing an upload ------------------------------------------------------------

  step "an upload that is still pending and the same image already stored with a thread",
       context do
    {claimed, context} = claimed_image(context)
    attachment = upload!(context, "image", "shot.png", "image/png", png(4096))
    Map.merge(context, %{attachment: attachment, claimed: claimed})
  end

  step "a client deletes the pending upload twice and then deletes the thread's attachment id",
       context do
    ids = [context.attachment["id"], context.attachment["id"], context.claimed["id"]]

    {replies, context} =
      Enum.map_reduce(ids, context, fn id, context ->
        rpc(context, "attachments.delete", %{"attachmentId" => id})
      end)

    Map.put(context, :replies, replies)
  end

  step "the pending upload is gone and both requests succeeded", context do
    refute HalC2.Attachments.path(context.attachment)
    assert Enum.all?(context.replies, &match?({:ok, _}, &1))
    context
  end

  step "the thread's copy is still there", context do
    assert File.regular?(HalC2.Attachments.path(context.claimed))
    context
  end

  # --- pasted images that are not what they claim -----------------------------------

  step ~r/^the client sends a message with a pasted image (?<problem>whose .+)$/,
       %{args: [problem]} = context do
    good = png(300)

    bad =
      case problem do
        "whose data is not a base64 image" ->
          %{"mimeType" => "image/png", "dataUrl" => "text:" <> Base.encode64(good)}

        "whose data is a different image type than its declared type" ->
          %{
            "mimeType" => "image/png",
            "dataUrl" => "data:image/jpeg;base64," <> Base.encode64(good)
          }

        "whose data is not valid base64" ->
          %{"mimeType" => "image/png", "dataUrl" => "data:image/png;base64,@@not base64@@"}

        "whose decoded size differs from its declared size" ->
          %{
            "mimeType" => "image/png",
            "sizeBytes" => 301,
            "dataUrl" => "data:image/png;base64," <> Base.encode64(good)
          }
      end

    input = %{
      "threadId" => thread(context),
      "attachments" => [
        %{
          "name" => "good.png",
          "mimeType" => "image/png",
          "dataUrl" => "data:image/png;base64," <> Base.encode64(good)
        },
        Map.put(bad, "name", "bad.png")
      ]
    }

    {reply, context} = rpc(context, "assets.persistChatAttachments", input)
    Map.put(context, :reply, reply)
  end

  step "the message fails naming the image", context do
    assert {:error, "Image 'bad.png' could not be saved.", _} = context.reply
    context
  end

  step "the MC stores none of the message's pasted images", context do
    assert attachment_dir_count(context) == 0
    context
  end

  # --- names the MC cannot trust ------------------------------------------------------

  step "the client uploads a file named {string}", %{args: [name]} = context do
    attachment = upload!(context, "file", name, "application/octet-stream", "some bytes")
    Map.put(context, :attachment, attachment)
  end

  step "the MC stores the file without an extension it cannot trust", context do
    assert {:ok, _} = context.reply
    [claimed] = message(context)["attachments"]
    assert String.ends_with?(HalC2.Attachments.path(claimed), "-bin.bin")
    Map.put(context, :claimed, claimed)
  end

  step "the provider and the user can still open it", context do
    path = HalC2.Attachments.path(context.claimed)
    assert File.read!(path) == "some bytes"

    context =
      create_url(context, %{
        "_tag" => "attachment",
        "attachmentId" => context.claimed["id"],
        "fileName" => context.claimed["name"]
      })

    context = read(context, asset_url!(context))
    assert {200, _, "some bytes"} = context.response
    context
  end

  # --- ids that point elsewhere --------------------------------------------------------

  step "a client asks for the attachment {string}", %{args: [id]} = context do
    # A file where a traversing id would land, to be read if the id were trusted.
    File.write!(Path.expand("../../settings.json", HalC2.Attachments.dir()), "{}")
    create_url(context, %{"_tag" => "attachment", "attachmentId" => id})
  end

  step "the MC answers that no such attachment exists", context do
    assert {:error, _message, %{"_tag" => "AssetAttachmentNotFoundError"}} = context.asset
    context
  end

  step "nothing outside the attachment store is read", context do
    refute match?({:ok, _}, context.asset)
    context
  end

  # --- signed URLs that were altered ----------------------------------------------------

  step ~r/^the client reads the URL with (?<change>.+)$/, %{args: [change]} = context do
    url = asset_url!(context)
    [_, token, name] = Regex.run(~r{^/api/assets/([^/]+)/(.+)$}, url)
    [payload, signature] = String.split(token, ".", parts: 2)

    other = host_file(context, "other.png", png(300))

    context =
      create_url(context, %{
        "_tag" => "media-file",
        "threadId" => thread(context),
        "path" => other
      })

    [other_payload | _] =
      context.asset
      |> elem(1)
      |> Map.fetch!("relativeUrl")
      |> String.replace_prefix("/api/assets/", "")
      |> String.split(".")

    altered =
      case change do
        "extra characters after the signature" -> payload <> "." <> signature <> "AAAA"
        "the signature removed" -> payload
        "its payload swapped for another URL's" -> other_payload <> "." <> signature
      end

    read(context, "/api/assets/#{altered}/#{name}")
  end

  step "the MC does not serve the file", context do
    assert {status, _, _} = context.response
    assert status in [403, 404]
    context
  end

  # --- the signing key ------------------------------------------------------------------

  step "the client reads the URL within its hour", context do
    read(context, asset_url!(context))
  end

  step "the MC serves the file", context do
    assert {200, _, "# notes\n"} = context.response
    context
  end

  step "a URL signed by a different MC's key is still refused", context do
    [_, token, name] = Regex.run(~r{^/api/assets/([^/]+)/(.+)$}, asset_url!(context))
    [payload, _signature] = String.split(token, ".", parts: 2)

    forged =
      :crypto.mac(:hmac, :sha256, :crypto.strong_rand_bytes(32), payload)
      |> Base.url_encode64(padding: false)

    assert {403, _, _} = Mc.request(context.mc, :get, "/api/assets/#{payload}.#{forged}/#{name}")
    context
  end

  # --- favicons ---------------------------------------------------------------------------

  defp favicon_file(context, svg) do
    File.mkdir_p!(Path.join(root(context), "public"))
    File.write!(Path.join([root(context), "public", "favicon.svg"]), svg)
  end

  # URLs are issued at a fixed moment, so a half-hour boundary cannot fall between asks.
  defp favicon_url(context, now) do
    {:ok, result} =
      HalC2.Attachments.create_url(
        %{"resource" => %{"_tag" => "project-favicon", "cwd" => root(context)}},
        now
      )

    result
  end

  @half_hour 30 * 60_000

  step "a signed URL for a project's favicon", context do
    favicon_file(context, "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"4\"/></svg>")
    now = div(System.system_time(:millisecond), @half_hour) * @half_hour + 1_000
    Map.merge(context, %{issued: now, favicon: favicon_url(context, now)})
  end

  step "a client asks for the project's favicon URL again within half an hour", context do
    Map.put(context, :again, favicon_url(context, context.issued + 10 * 60_000))
  end

  step "it receives the same URL", context do
    assert context.again == context.favicon
    context
  end

  step "the icon file's contents change", context do
    favicon_file(context, "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"4\"/></svg>")
    Map.put(context, :changed, favicon_url(context, context.issued + 11 * 60_000))
  end

  step "the next URL ends in a different name", context do
    name = fn %{"relativeUrl" => url} -> url |> String.split("/") |> List.last() end
    assert name.(context.changed) != name.(context.favicon)
    context
  end

  step "the URL's expiry falls on a half-hour boundary, between one and two half-hours away",
       context do
    expires = context.favicon["expiresAt"]
    assert rem(expires, @half_hour) == 0
    assert expires > context.issued + @half_hour
    assert expires <= context.issued + 2 * @half_hour
    context
  end

  step "the user saved {string} as the project's icon", %{args: [path]} = context do
    File.write!(Path.join(root(context), "secret.txt"), "not an image")
    project = World.project(context, "widgets")

    {reply, context} =
      World.call(context, "projects.mutate", %{
        "type" => "project.update",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "projectId" => project.id,
        "faviconPath" => path
      })

    assert {:ok, _} = reply
    :ok = HalC2.Streams.flush_shell(project.id)
    context
  end

  step "a client asks for the project's favicon URL", context do
    create_url(context, %{"_tag" => "project-favicon", "cwd" => root(context)})
  end

  step "the MC refuses it saying only images are served as icons", context do
    assert {:error, "Only images are served as icons.",
            %{"_tag" => "AssetPreviewTypeValidationError"}} = context.asset

    context
  end

  # --- applications' icons ---------------------------------------------------------------

  step ~r/^the MC runs on macOS and Spotlight knows (?<apps>.+)$/, %{args: [apps]} = context do
    context = mac(context)
    [first | rest] = Regex.scan(~r/"([^"]+)"/, apps, capture: :all_but_first) |> List.flatten()

    {names, id} =
      if apps =~ "bundle id", do: {[first], List.first(rest)}, else: {[first | rest], nil}

    bundles =
      for name <- names do
        id_line = if id, do: "CFBundleIdentifier=#{id}\n", else: ""

        mac_app(context, name, id_line <> "CFBundleIconFile=icon\n", [
          {"icon.icns", "icon-of-#{name}"}
        ])
      end

    # Later names were used more recently when the row says so; otherwise one app.
    used = Enum.with_index(bundles) |> Enum.map(fn {_, i} -> "2026-01-0#{i + 1}" end)
    set_spotlight(context, bundles, used)
    context
  end

  step ~r/^a client asks for the icon of the application (?<reference>.+)$/,
       %{args: [reference]} = context do
    context = mac(context)

    app =
      case Regex.run(~r/^with the bundle id "([^"]+)"$/, reference) do
        [_, id] ->
          %{"_tag" => "app-id", "appId" => id}

        nil ->
          name =
            case reference do
              "named a name with a line break" -> "Review\nApp"
              "named a name with a NUL character" -> "Review\0App"
              "named " <> quoted -> String.trim(quoted, "\"")
            end

          %{"_tag" => "display-name", "displayName" => name}
      end

    context = create_url(context, %{"_tag" => "native-app-icon", "app" => app})
    context |> Map.put(:app, app) |> then(&read(&1, asset_url!(&1)))
  end

  step ~r/^the MC serves the icon of "(?<app>[^"]+)"$/, %{args: [app]} = context do
    assert {200, headers, body} = context.response
    assert body == "icon-of-#{app}"
    assert {"content-type", "image/png"} in headers
    context
  end

  step "the MC does not search the host with it as part of a query", context do
    query = for "mdfind\t" <> query <- mac_calls(context), do: query

    case context.app["displayName"] do
      "Review * App" ->
        assert Enum.all?(query, &(&1 =~ ~S(Review \* App) and not (&1 =~ ~r/[^\\]\*/)))

      _ ->
        assert query == []
    end

    context
  end

  step "the star only matches a star, not any name", context do
    assert {404, _, _} = context.response
    context
  end

  # --- GitHub media addresses -------------------------------------------------------------

  step "the client asks for an asset URL for the GitHub media address {word}",
       %{args: [address]} = context do
    resource = %{"_tag" => "github-media", "cwd" => root(context), "url" => address}
    context |> Map.put(:resource, resource) |> create_url(resource)
  end

  step "the URL ends in the attachment's id", context do
    assert String.ends_with?(asset_url!(context), "/1a1842fb-6383-492f-873c-57aa0033fa6c")
    context
  end

  step "the MC will fetch it from raw.githubusercontent.com instead", context do
    assert claims(asset_url!(context))["url"] ==
             "https://raw.githubusercontent.com/owner/repo/main/docs/shot.png"

    context
  end

  step "the MC will fetch the older attachment address as it is", context do
    assert claims(asset_url!(context))["url"] ==
             "https://github.com/owner/repo/assets/45952064/1a1842fb"

    context
  end

  step "the MC will fetch the Git LFS address as it is", context do
    assert claims(asset_url!(context))["url"] ==
             "https://media.githubusercontent.com/media/owner/repo/main/a.mp4"

    context
  end

  step "the URL ends in {string}", %{args: [name]} = context do
    assert String.ends_with?(asset_url!(context), "/" <> name)
    context
  end

  step "the client asks for an asset URL for {string}", %{args: [address]} = context do
    resource = %{"_tag" => "github-media", "cwd" => root(context), "url" => address}
    context |> Map.put(:resource, resource) |> create_url(resource)
  end

  step "the failure does not contain the address or its token", context do
    assert {:error, _, _} = context.asset
    text = inspect(context.asset)
    refute text =~ "example.com"
    refute text =~ "private-media-token"
    context
  end

  step "the host's GitHub CLI is not signed in", context do
    token = "gho_private#{System.unique_integer([:positive])}"
    fake_gh(context, [])
    Map.put(context, :gh_token, token)
  end

  step "a private repository image is signed for a client", context do
    token = context.gh_token
    bytes = png(1024)
    github_origin(%{test: self(), token: token, bytes: bytes})

    context
    |> Map.put(:github, %{token: token, bytes: bytes})
    |> create_url(%{
      "_tag" => "github-media",
      "cwd" => root(context),
      "url" => "https://github.com/user-attachments/assets/0f3c1d2e-screenshot"
    })
  end

  step "the client reads it", context do
    read(context, asset_url!(context))
  end

  step "GitHub answers 404 and the client receives 404", context do
    assert_received {:github_request, _path, []}
    assert {404, _, _} = context.response
    context
  end

  step "the host signs in to GitHub", context do
    File.write!(
      Path.join(context.mc.home, "gh-rules.json"),
      JSON.encode!(gh_signed_in(context.github.token))
    )

    context
  end

  step "the client reads it again", context do
    read(context, asset_url!(context))
  end

  step "the MC sends the credential and serves the image", context do
    token = context.github.token
    assert_received {:github_request, _path, ["Bearer " <> ^token]}
    assert {200, _, body} = context.response
    assert body == context.github.bytes
    context
  end

  step "the next requests reuse the credential without asking the CLI again", context do
    asked = fn ->
      Path.join(context.mc.home, "gh.log")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.count(&(&1 =~ ~s("auth","token")))
    end

    before = asked.()
    context = read(context, asset_url!(context))
    assert {200, _, _} = context.response
    context = read(context, asset_url!(context))
    assert {200, _, _} = context.response
    assert asked.() == before
    context
  end

  # --- what GitHub answers ----------------------------------------------------------------

  step ~r/^GitHub answers a media request with (?<upstream>.+)$/, %{args: [upstream]} = context do
    {mode, name} =
      case upstream do
        "404, or any other status below 500" -> {:not_found, "shot.png"}
        "a 5xx status" -> {:server_error, "shot.png"}
        "four redirects in a row" -> {:redirects, "shot.png"}
        "a redirect to an address that is not https" -> {:insecure_redirect, "shot.png"}
        "an HTML page with status 200" -> {:html, "shot.png"}
        ~s("application/octet-stream" for a file named "clip.mp4") -> {:octet_stream, "clip.mp4"}
      end

    fake_gh(context, [])
    github_origin(%{test: self(), mode: mode}, FakeUpstream)

    create_url(context, %{
      "_tag" => "github-media",
      "cwd" => root(context),
      "url" => "https://github.com/owner/repo/blob/main/#{name}"
    })
  end

  step "a client reads the media URL", context do
    read(context, asset_url!(context))
  end

  step ~r/^the MC answers (?<answer>that same status, with no body|200 with the type "video\/mp4")$/,
       %{args: [answer]} = context do
    assert {status, headers, body} = context.response

    case answer do
      "that same status, with no body" ->
        assert status == 404
        assert body == ""

      ~s(200 with the type "video/mp4") ->
        assert status == 200
        assert {"content-type", "video/mp4"} in headers
    end

    context
  end

  step "a signed URL for a video hosted on GitHub", context do
    bytes = :crypto.strong_rand_bytes(1000)
    fake_gh(context, [])
    github_origin(%{test: self(), mode: {:video, bytes}}, FakeUpstream)

    context
    |> Map.put(:bytes, bytes)
    |> create_url(%{
      "_tag" => "github-media",
      "cwd" => root(context),
      "url" => "https://github.com/owner/repo/blob/main/clip.mp4"
    })
  end

  step "a player asks for {string}", %{args: [range]} = context do
    read(context, asset_url!(context), [{"range", range}])
  end

  step "the MC forwards that range to GitHub", context do
    assert_received {:upstream_request, _path, headers}
    assert {"range", "bytes=100-199"} in headers
    context
  end

  step "answers with GitHub's range, length and validators", context do
    assert {206, headers, body} = context.response
    assert body == binary_part(context.bytes, 100, 100)
    assert {"content-range", "bytes 100-199/1000"} in headers
    assert {"content-length", "100"} in headers
    assert {"etag", ~s("clip-v1")} in headers
    assert {"last-modified", "Wed, 21 Oct 2026 07:28:00 GMT"} in headers
    context
  end

  step "the response may be cached privately for as long as the signed URL has left, and not at all once it has expired",
       context do
    assert {206, headers, _} = context.response
    {"cache-control", "private, max-age=" <> left} = List.keyfind(headers, "cache-control", 0)
    assert String.to_integer(left) in 3590..3600

    expired = %{
      claims(asset_url!(context))
      | "expiresAt" => System.system_time(:millisecond) - 1_000
    }

    assert {:ok, 200, headers, _} =
             HalC2.Attachments.GitHubMedia.serve(expired, %{})

    assert {"cache-control", "private, no-store"} in headers
    context
  end
end
