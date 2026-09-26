defmodule T3.Steps.Platform.AttachmentsAndAssets do
  @moduledoc "Steps for features/node/platform/attachments-and-assets.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World

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
        do: T3.Attachments.create_upload_url(input, now),
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
    assert {204, _, _} = Node.http(context.node, :post, url, body: bytes)
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
    do: T3.StreamState.list(T3.Streams.Server.state(T3.Streams.ensure(thread_id)), "message")

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
    path = Path.join(Node.tmp_dir(context.node, "host"), name)
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
     }, File.read!(T3.Attachments.path(claimed))}
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
         "path" => Path.join(Node.tmp_dir(context.node, "host"), "gone.png")
       }, nil}

  defp resource(_context, "a project the node does not know"),
    do: {%{"_tag" => "workspace-file", "threadId" => "th-unknown", "path" => "README.md"}, nil}

  defp resource(_context, "an asset kind this node does not know"),
    do: {%{"_tag" => "hologram", "cwd" => "/"}, nil}

  defp fake_gh(context, rules) do
    home = context.node.home
    previous = Application.get_env(:t3, :gh_command)
    Application.put_env(:t3, :gh_command, @fake_gh)
    System.put_env("FAKE_GH_RULES", Path.join(home, "gh-rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(home, "gh.log"))
    :persistent_term.erase({T3.Attachments.GitHubMedia, :token})

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:t3, :gh_command, previous)
      System.delete_env("FAKE_GH_RULES")
      System.delete_env("FAKE_GH_LOG")
      :persistent_term.erase({T3.Attachments.GitHubMedia, :token})
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

  defp private_github_image(context) do
    token = "gho_private#{System.unique_integer([:positive])}"
    fake_gh(context, [%{"args" => ["auth", "token"], "stdout" => token <> "\n"}])
    bytes = png(1024)

    {:ok, pid} =
      Bandit.start_link(
        plug: {FakeGitHub, %{test: self(), token: token, bytes: bytes}},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :github_media_origin) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    Application.put_env(:t3, :github_media_origin, "http://127.0.0.1:#{port}")

    context
    |> Map.put(:github, %{token: token, bytes: bytes})
    |> create_url(%{
      "_tag" => "github-media",
      "cwd" => root(context),
      "url" => "https://github.com/user-attachments/assets/0f3c1d2e-screenshot"
    })
  end

  defp desktop_entry(dir, file, name, icon) do
    File.mkdir_p!(Path.join(dir, "applications"))

    File.write!(
      Path.join([dir, "applications", file]),
      "[Desktop Entry]\nType=Application\nName=#{name}\nExec=#{String.downcase(name)}\nIcon=#{icon}\n"
    )
  end

  defp xdg_data(context) do
    dir = Node.tmp_dir(context.node, "xdg")

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
    do: Map.put(context, :response, Node.http(context.node, :get, url, headers: headers))

  # --- background ------------------------------------------------------------------

  step "a running node with a project and a thread", context do
    context |> World.create_project("widgets") |> World.create_thread("main", "widgets")
  end

  # --- uploads ---------------------------------------------------------------------

  step "sends the image's bytes to that URL", context do
    Map.put(
      context,
      :response,
      Node.http(context.node, :post, context.upload_url, body: png(2 * @mb))
    )
  end

  step "the node accepts the upload", context do
    assert {204, _, _} = context.response
    path = T3.Attachments.path(context.attachment)
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
      Node.http(context.node, :post, context.upload_url, body: png(1024))
    )
  end

  step "the node refuses the link as invalid or expired", context do
    assert {403, _, "The link is invalid or expired."} = context.response
    refute T3.Attachments.path(context.attachment)
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

  step ~r/^the node refuses saying attachments may be at most (?<limit>\d+ MB)$/,
       %{args: [limit]} = context do
    assert {:error, message, _} = context.reply
    assert message == "Attachments may be at most #{limit}."
    context
  end

  step "the client sends more than 50 MB to an upload URL", context do
    {_attachment, url} =
      upload_url(context, "file", "big.bin", "application/octet-stream", 50 * @mb)

    body = :binary.copy(<<0>>, 50 * @mb + 1)
    Map.put(context, :response, Node.http(context.node, :post, url, body: body))
  end

  step "the node answers that the upload is too large", context do
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
      Node.http(context.node, :post, context.upload_url, body: :binary.copy("a", @mb))
    )
  end

  step "the node answers that the body is the wrong size", context do
    assert {400, _, "The body is the wrong size."} = context.response
    refute T3.Attachments.path(context.attachment)
    context
  end

  step "the client sends bytes to an asset URL as if it were an upload URL", context do
    path = host_file(context, "chart.png", png(512))

    context =
      create_url(context, %{"_tag" => "media-file", "threadId" => thread(context), "path" => path})

    upload = "/api/attachments/upload/" <> token(asset_url!(context))
    Map.put(context, :response, Node.http(context.node, :post, upload, body: png(512)))
  end

  step "the node refuses it as not an upload URL", context do
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
    path = T3.Attachments.path(claimed)
    assert File.read!(path) == File.read!(T3.Attachments.path(context.attachment))

    assert T3.Attachments.prompt_text("look", [%{type: "image", name: "shot.png", path: path}]) =~
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

  step "the node starts and the thread's history loads with both attachments", context do
    assert [image, text] = message(context)["attachments"]
    assert %{"type" => "image", "name" => "shot.png"} = image
    assert %{"type" => "file", "name" => "notes.txt"} = text
    assert File.read!(T3.Attachments.path(text)) == "remember the milk\n"
    assert File.regular?(T3.Attachments.path(image))
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
    path = T3.Attachments.path(attachment)
    File.touch!(path, System.os_time(:second) - 25 * 60 * 60)
    # The sweep runs at most every 15 minutes; this scenario starts a fresh window.
    :persistent_term.erase({T3.Attachments, :swept})
    Map.merge(context, %{attachment: attachment, old_path: path})
  end

  step "the node has removed it", context do
    # Asking for an upload URL is what runs the sweep.
    fresh = upload!(context, "image", "new.png", "image/png", png(256))
    refute File.exists?(context.old_path)
    assert T3.Attachments.path(fresh)
    context
  end

  step "it deletes that upload", context do
    {reply, context} =
      rpc(context, "attachments.delete", %{"attachmentId" => context.attachment["id"]})

    assert {:ok, _} = reply
    context
  end

  step "the upload is gone", context do
    refute T3.Attachments.path(context.attachment)
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

  step "the node stores them as thread attachments", context do
    assert {:ok, %{"attachments" => [first, second]}} = context.reply

    for {stored, name} <- [{first, "paste-1.png"}, {second, "paste-2.png"}] do
      assert %{"type" => "image", "name" => ^name, "sizeBytes" => 300} = stored
      assert String.starts_with?(stored["id"], thread(context))
      assert File.read!(T3.Attachments.path(stored)) == context.pasted
    end

    context
  end

  # --- asset URLs ------------------------------------------------------------------

  step ~r/^the client asks for an asset URL for (?<resource>.+)$/, %{args: [name]} = context do
    {resource, bytes} = resource(context, name)
    context |> Map.merge(%{resource: resource, bytes: bytes}) |> create_url(resource)
  end

  step "the node returns a URL that serves the file", context do
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
      T3.Attachments.create_url(%{"resource" => context.resource}, issued)

    assert {403, _, "The link is invalid or expired."} = Node.http(context.node, :get, old)
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

  step "the node refuses saying only media files are served", context do
    assert {:error, "Only media files are served.",
            %{"_tag" => "AssetPreviewTypeValidationError"}} =
             context.asset

    context
  end

  step ~r/^the node fails with (?<tag>Asset\w+Error)$/, %{args: [tag]} = context do
    assert {:error, _message, %{"_tag" => ^tag, "resource" => resource}} = context.asset
    assert resource == context.resource
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

  step "the node answers that the file is gone", context do
    assert {404, _, "The file is gone."} = context.response
    context
  end

  step "an asset URL issued by another member", context do
    {node, peer} = Node.cluster(context.node)
    bytes = png(1500)
    path = Path.join(peer.home, "peer-chart.png")
    File.mkdir_p!(peer.home)
    File.write!(path, bytes)

    resource = %{"_tag" => "media-file", "threadId" => "th-peer", "path" => path}

    {:ok, %{"relativeUrl" => url}} =
      :erpc.call(peer.name, T3.Attachments, :create_url, [%{"resource" => resource}])

    Map.merge(context, %{node: node, peer: peer, peer_url: url, bytes: bytes})
  end

  step "the client reads it through the node it is connected to", context do
    read(context, context.peer_url)
  end

  step "the node forwards the request to the issuer", context do
    assert {200, _, body} = context.response
    assert body == context.bytes
    assert {:ok, context.peer.name} == T3.Attachments.issuer(token(context.peer_url))
    context
  end

  step "only the issuer checks the signature", context do
    # This node's own key does not verify the peer's signature; the peer's does.
    token = token(context.peer_url)
    assert {:error, 403, _} = T3.Attachments.serve(token)
    assert {:ok, 200, _, _} = :erpc.call(context.peer.name, T3.Attachments, :serve, [token, %{}])
    context
  end

  step "the node fails saying files are not served by this node yet", context do
    assert {:error, message, %{"_tag" => "AssetWorkspaceResolutionError"}} = context.asset
    assert message == "#{context.resource["_tag"]} files are not served by this node yet."
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

  step "the node serves that icon", context do
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

  step "the node serves the icon", context do
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

  step "the node fetches it with the host's GitHub credentials and serves it", context do
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
    assert {404, _, "The file is gone."} = Node.http(context.node, :get, asset_url!(context))
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
    assert {200, _, body} = Node.http(context.node, :get, asset_url!(context))
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

  step "the node serves the requested range", context do
    assert {206, headers, body} = context.response
    assert body == binary_part(context.bytes, 150_000, 1000)
    assert {"content-range", "bytes 150000-150999/200000"} in headers
    assert {"content-type", "video/mp4"} in headers
    context
  end
end
