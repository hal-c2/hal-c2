defmodule HalC2.Attachments do
  @moduledoc """
  Chat attachments and file URLs (`attachments.createUploadUrl`, `attachments.delete`,
  `assets.createUrl`).

  A client asks the thread's MC for a signed upload URL, sends the bytes to it,
  and names the upload in its message; the message's MC then claims it into the
  thread (`claim/2`), and providers read the file from `path/1`. Asset URLs are
  signed the same way and serve an attachment or a project file.

  A client reaches every MC through one: signed URLs name the MC that issued
  them, the MC that receives the request forwards it there (`HalC2.Web.Router`),
  and only the issuing MC checks the signature, with its own key.
  """

  @upload_ttl_ms 10 * 60_000
  @asset_ttl_ms 60 * 60_000
  @max_image_bytes 10 * 1024 * 1024
  @max_file_bytes 50 * 1024 * 1024
  @chunk_bytes 64 * 1024
  @stream_timeout_ms 60_000
  @pending_max_age_s 24 * 60 * 60
  @image_types %{
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/jpg" => ".jpg",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "image/svg+xml" => ".svg",
    "image/bmp" => ".bmp",
    "image/avif" => ".avif",
    "image/heic" => ".heic",
    "image/heif" => ".heif",
    "image/tiff" => ".tiff"
  }
  @image_extensions ~w(.png .jpg .jpeg .gif .webp .svg .bmp .avif .ico)
  # What a media URL may serve from outside a project.
  @media_extensions ~w(.png .jpg .jpeg .gif .webp .svg .bmp .avif .ico .mp4 .webm .mov .m4v
                       .mp3 .wav .ogg .oga .opus .m4a .aac .flac .html .htm .pdf)

  # --- uploads ---------------------------------------------------------------------

  @doc """
  `attachments.createUploadUrl`: an id for the upload and where to send it. `now`
  (epoch ms) is when the URL counts as issued.
  """
  def create_upload_url(input, now \\ now_ms())

  def create_upload_url(%{"name" => name, "mimeType" => mime, "sizeBytes" => size} = input, now) do
    type = input["type"] || "image"
    limit = if type == "file", do: @max_file_bytes, else: @max_image_bytes

    if is_integer(size) and size >= 1 and size <= limit do
      sweep_pending()
      id = "pending-#{HalC2.Environment.uuid4()}" <> id_suffix(type, name)
      expires = now + @upload_ttl_ms

      claims = %{
        "kind" => "attachment-upload",
        "type" => type,
        "attachmentId" => id,
        "name" => name,
        "mimeType" => mime,
        "sizeBytes" => size,
        "expiresAt" => expires
      }

      {:ok,
       %{
         "attachmentId" => id,
         "relativeUrl" => "/api/attachments/upload/" <> sign(claims),
         "expiresAt" => expires
       }}
    else
      {:error, "Attachments may be at most #{div(limit, 1024 * 1024)} MB."}
    end
  end

  @doc "The largest image an upload may be, in bytes."
  def max_image_bytes, do: @max_image_bytes

  @doc "Stores an upload's bytes on this MC, if its signed token is valid."
  def store(token, body) do
    with {:ok, %{"kind" => "attachment-upload"} = claims} <- verify(token),
         true <-
           byte_size(body) == claims["sizeBytes"] || {:error, 400, "The body is the wrong size."} do
      path =
        Path.join(
          dir(),
          claims["attachmentId"] <> extension(claims["type"], claims["mimeType"], claims["name"])
        )

      File.mkdir_p!(dir())
      part = path <> ".part"
      File.write!(part, body)
      File.rename!(part, path)
      :ok
    else
      {:ok, _other} -> {:error, 403, "Not an upload URL."}
      {:error, status, message} -> {:error, status, message}
      {:error, message} -> {:error, 403, message}
    end
  end

  @doc "`attachments.delete`: drops an upload no message took."
  def delete(%{"attachmentId" => "pending-" <> _ = id}) do
    if safe_id?(id), do: Enum.each(Path.wildcard(Path.join(dir(), id <> ".*")), &File.rm/1)
    {:ok, nil}
  end

  def delete(_input), do: {:ok, nil}

  @doc "Removes every file a thread claimed or stored, when the thread is deleted."
  def delete_thread(thread_id) do
    dir()
    |> Path.join(thread_segment(thread_id) <> "-*")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)

    :ok
  end

  @doc """
  Moves a message's pending uploads into its thread: each is copied under a
  thread-scoped id of its own, which the message then names, so two messages naming
  one upload hold two copies. Attachments the thread already has pass through, without
  the mark only the MC's own folds carry.
  """
  def claim(thread_id, attachments) when is_list(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
      case claim_one(thread_id, attachment) do
        {:ok, claimed} -> {:cont, {:ok, [claimed | acc]}}
        {:error, _} = error -> {:halt, {error, acc}}
      end
    end)
    |> case do
      {:ok, claimed} ->
        {:ok, Enum.reverse(claimed)}

      # One that cannot be claimed leaves none of the message's uploads claimed.
      {error, claimed} ->
        release(attachments, Enum.reverse(claimed))
        error
    end
  end

  def claim(_thread_id, _attachments), do: {:ok, []}

  @doc """
  Gives back what `claim/2` returned for `attachments` when the MC then refuses the
  message: the thread's copies go, and the pending uploads they were copied from stay,
  so the client can send them again. Attachments the thread already had are not touched.
  """
  # Removes only files named by a checked id in the attachments directory.
  # sobelow_skip ["Traversal.FileModule"]
  def release(attachments, claimed) when is_list(attachments) and is_list(claimed) do
    for {%{"id" => from}, %{"id" => id}} <- Enum.zip(attachments, claimed),
        from != id,
        safe_id?(id),
        file <- Path.wildcard(Path.join(dir(), id <> ".*")),
        do: File.rm(file)

    :ok
  end

  def release(_attachments, _claimed), do: :ok

  defp claim_one(thread_id, %{"id" => "pending-" <> rest = id} = attachment) do
    with true <- safe_id?(id) || {:error, "Attachment '#{attachment["name"]}' has a bad id."},
         [source] <- Path.wildcard(Path.join(dir(), id <> ".*")),
         {:ok, %File.Stat{size: size}} <- File.stat(source),
         true <-
           size == attachment["sizeBytes"] ||
             {:error, "Attachment '#{attachment["name"]}' does not match its upload."} do
      # Each claim stores a copy of its own, so `release/2` of a message the MC refused
      # can never take a file another message names (proof/models/asset_stream.maude).
      claimed_id = "#{thread_segment(thread_id)}-#{copy_tag()}-#{rest}"
      File.cp!(source, Path.join(dir(), claimed_id <> Path.extname(source)))
      {:ok, attachment |> unmarked() |> Map.put("id", claimed_id)}
    else
      [] -> {:error, "Attachment '#{attachment["name"]}' was not uploaded."}
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Attachment '#{attachment["name"]}' cannot be sent."}
    end
  end

  defp claim_one(_thread_id, attachment), do: {:ok, unmarked(attachment)}

  defp copy_tag, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc """
  `assets.persistChatAttachments`: images a client sends inline (pasted), stored
  straight into the thread as its attachments. Every image is checked before any is
  written, so one that is not what it claims to be stores none of the message's images.
  """
  def persist(%{"threadId" => thread_id, "attachments" => attachments}) do
    attachments
    |> Enum.reduce_while({:ok, []}, fn attachment, {:ok, acc} ->
      case pasted_image(attachment) do
        {:ok, decoded} -> {:cont, {:ok, [{attachment, decoded} | acc]}}
        :error -> {:halt, {:error, persist_error(attachment)}}
      end
    end)
    |> case do
      {:ok, decoded} ->
        {:ok,
         %{"attachments" => decoded |> Enum.reverse() |> Enum.map(&store_pasted(thread_id, &1))}}

      error ->
        error
    end
  end

  defp persist_error(attachment) do
    %{
      "_tag" => "PersistChatAttachmentsError",
      "message" => "Image '#{attachment["name"]}' could not be saved."
    }
  end

  # The data URL must be a base64 image of the type and size the client declared.
  defp pasted_image(attachment) do
    with "data:" <> rest <- attachment["dataUrl"] || "",
         [header, data] <- String.split(rest, ",", parts: 2),
         [type, "base64"] <- header |> String.split(";") |> Enum.map(&String.trim/1),
         "image/" <> _ <- String.downcase(type),
         declared = attachment["mimeType"] || type,
         true <- String.downcase(declared) == String.downcase(type),
         {:ok, bytes} <- Base.decode64(data, ignore: :whitespace),
         true <- bytes != "" and byte_size(bytes) <= @max_image_bytes,
         true <-
           is_nil(attachment["sizeBytes"]) or attachment["sizeBytes"] == byte_size(bytes) do
      {:ok, {declared, bytes}}
    else
      _ -> :error
    end
  end

  defp store_pasted(thread_id, {attachment, {mime, bytes}}) do
    id = "#{thread_segment(thread_id)}-#{HalC2.Environment.uuid4()}"
    File.mkdir_p!(dir())
    File.write!(Path.join(dir(), id <> extension("image", mime, attachment["name"])), bytes)

    %{
      "type" => "image",
      "id" => id,
      "name" => attachment["name"],
      "mimeType" => mime,
      "sizeBytes" => byte_size(bytes)
    }
    |> then(&if(attachment["source"], do: Map.put(&1, "source", attachment["source"]), else: &1))
  end

  # What of a message too long to send whole stays in its text (`fold_long_text/3`).
  @long_text_chars 120_000
  @long_text_start 8_000
  @long_text_end 2_000
  @folded_source %{"_tag" => "pasted-text", "folded" => true}

  @doc """
  A message too long to send whole, folded as a client folds a long paste: past
  120,000 characters its text becomes its start and end around a mark saying what was
  cut, and the whole of it a text file attached to the message (a `pasted-text` file,
  which providers are given as a path). The thread shows what the agent was sent, and
  the file goes wherever the thread does. Shorter text passes through.
  """
  # The file is the attachments folder, a thread segment of `[a-z0-9_-]` and a fresh
  # uuid, never a path a client or an agent names.
  # sobelow_skip ["Traversal.FileModule"]
  def fold_long_text(thread_id, text, attachments) when is_binary(text) do
    chars = String.length(text)

    cond do
      chars <= @long_text_chars ->
        {:ok, text, attachments}

      byte_size(text) > @max_file_bytes ->
        {:error,
         "The message is too long to send, even as a file: at most #{div(@max_file_bytes, 1024 * 1024)} MB."}

      true ->
        id = "#{thread_segment(thread_id)}-#{HalC2.Environment.uuid4()}"
        name = free_name(attachments, "message")
        file = Path.join(dir(), id <> ".txt")

        case with(:ok <- File.mkdir_p(dir()), do: File.write(file, text)) do
          :ok ->
            cut = chars - @long_text_start - @long_text_end

            folded =
              String.slice(text, 0, @long_text_start) <>
                "\n\n[... #{cut} characters cut here; the whole message is in the attached #{name} ...]\n\n" <>
                String.slice(text, chars - @long_text_end, @long_text_end)

            file = %{
              "type" => "file",
              "id" => id,
              "name" => name,
              "mimeType" => "text/plain",
              "sizeBytes" => byte_size(text),
              "source" => @folded_source
            }

            {:ok, folded, attachments ++ [file]}

          # No message names what a failed write left, so it goes here.
          {:error, reason} ->
            File.rm(file)

            {:error,
             "The message is too long to send whole, and saving it as a file failed: #{:file.format_error(reason)}."}
        end
    end
  end

  def fold_long_text(_thread_id, text, attachments), do: {:ok, text, attachments}

  @doc """
  The files `fold_long_text/3` folded a message's `text` into, among its
  `attachments`: those the MC marked as its folds whose name a cut mark in `text`
  names. Only the MC marks a file (`claim/2` drops a client's mark), so text quoting a cut mark, or a
  pasted text of the same name, never makes another file a fold.
  """
  def folded_into(text, attachments) when is_binary(text) and is_list(attachments) do
    named =
      ~r/\[\.\.\. \d+ characters cut here; the whole message is in the attached (.+?) \.\.\.\]/
      |> Regex.scan(text, capture: :all_but_first)
      |> MapSet.new(fn [name] -> name end)

    Enum.filter(attachments, &(&1["source"] == @folded_source and &1["name"] in named))
  end

  def folded_into(_text, _attachments), do: []

  # An attachment a client names, without the mark only the MC gives the files it folds
  # long messages into (`folded_into/2`).
  defp unmarked(%{"source" => %{"_tag" => "pasted-text"} = source} = attachment),
    do: Map.put(attachment, "source", Map.delete(source, "folded"))

  defp unmarked(attachment), do: attachment

  @doc """
  What an edit of a message's text from `old` to `new` leaves behind among its
  `attachments`: the file `old` was folded into, unless `new` still names it among the
  attachments the edit `kept`, as an edit of the stored folded text does.
  """
  def left_behind(old, new, attachments, kept),
    do: folded_into(old, attachments) -- folded_into(new, kept)

  # `message.txt`, or `message-2.txt` and on when the message already has one.
  defp free_name(attachments, base) do
    taken = MapSet.new(attachments, & &1["name"])

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&if(&1 == 1, do: "#{base}.txt", else: "#{base}-#{&1}.txt"))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  @doc """
  A thread's own copies of attachments another thread's messages name (a fork copies
  its source's), under ids of its own, so they stay when that thread and its files are
  deleted: `{:ok, copies}`, in order. An
  attachment whose file is not on this MC, or goes while it is copied, passes through.
  A copy that cannot be made of a file that is there (a full disk) is `{:error,
  reason}`, and the copies already made go: passed through, the thread would name
  files that go with the other thread's.
  """
  # The source comes from `path/1` (a `safe_id?` id inside the attachments folder) and
  # the target is that folder, a thread segment and a fresh uuid.
  # sobelow_skip ["Traversal.FileModule"]
  def copy_into(thread_id, attachments) when is_list(attachments) do
    attachments
    |> Enum.reduce_while({:ok, []}, fn attachment, {:ok, copies} ->
      case copy(thread_id, attachment) do
        {:ok, copy} ->
          {:cont, {:ok, [copy | copies]}}

        {:error, reason} ->
          for copy <- copies, copy not in attachments, path = path(copy), do: File.rm(path)

          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, copies} -> {:ok, Enum.reverse(copies)}
      error -> error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp copy(thread_id, attachment) do
    with source when is_binary(source) <- match?(%{"id" => _}, attachment) && path(attachment) do
      id = "#{thread_segment(thread_id)}-#{HalC2.Environment.uuid4()}"
      target = Path.join(dir(), id <> Path.extname(source))

      # A copy, not a link: an agent is given each file's path and may write into
      # it, which a link would carry into the other thread's file.
      case File.cp(source, target) do
        :ok ->
          {:ok, Map.put(attachment, "id", id)}

        {:error, reason} ->
          File.rm(target)
          if File.exists?(source), do: {:error, reason}, else: {:ok, attachment}
      end
    else
      _ -> {:ok, attachment}
    end
  end

  @doc "The file of an attachment on this MC, or `nil`."
  def path(%{"id" => id}),
    do: if(safe_id?(id), do: List.first(Path.wildcard(Path.join(dir(), id <> ".*"))))

  @doc "The bytes of an attachment stored on this MC, or `:error`."
  # The file comes from `path/1`: an id that passed `safe_id?` inside the attachments
  # folder, never a path a client or an agent names.
  # sobelow_skip ["Traversal.FileModule"]
  def read(attachment) do
    case path(attachment) do
      path when is_binary(path) -> File.read(path)
      nil -> :error
    end
  end

  @doc "Whether an attachment id can name a stored upload at all."
  def valid_id?(id), do: safe_id?(id)

  @native_image_types ~w(image/gif image/jpeg image/png image/webp)

  @doc """
  A turn's text with where each attachment is saved,
  so agents can open files (and images they cannot take natively).
  """
  def prompt_text(text, attachments) do
    Enum.reduce(attachments, text || "", fn attachment, text ->
      if is_binary(Map.get(attachment, :path)) do
        note =
          ~s([Attached #{attachment.type} "#{attachment.name}" is saved at: #{attachment.path}])

        if text == "", do: note, else: text <> "\n\n" <> note
      else
        text
      end
    end)
  end

  @doc "The images a model takes inline: `{mime_type, base64}` for each."
  def native_images(attachments) do
    for %{type: "image", mime_type: mime, path: path} <- attachments,
        is_binary(path),
        String.downcase(mime || "") in @native_image_types,
        {:ok, bytes} <- [File.read(path)],
        do: {String.downcase(mime), Base.encode64(bytes)}
  end

  # Uploads no message took within a day go away, checked at most every 15 minutes.
  defp sweep_pending do
    now = System.os_time(:second)

    if now - :persistent_term.get({__MODULE__, :swept}, 0) > 900 do
      :persistent_term.put({__MODULE__, :swept}, now)

      for file <- Path.wildcard(Path.join(dir(), "pending-*")),
          {:ok, %File.Stat{mtime: mtime}} <- [File.stat(file, time: :posix)],
          now - mtime > @pending_max_age_s,
          do: File.rm(file)
    end

    :ok
  end

  # --- asset URLs ------------------------------------------------------------------

  @doc """
  `assets.createUrl`: a signed URL that serves an attachment, a file, a project's
  favicon, an application's icon or GitHub media. The URL ends in the file's name; a
  project without a favicon gets a URL ending in
  `project-favicon-missing`, which answers 404 and tells the client to draw its
  default icon. `now` (epoch ms) is when the URL counts as issued.
  """
  def create_url(%{"resource" => resource}, now \\ now_ms()) do
    with {:ok, claims, name} <- asset_claims(resource, now) do
      claims =
        Map.merge(claims, %{
          "kind" => "asset",
          "fileName" => claims["fileName"] || name,
          "expiresAt" => claims["expiresAt"] || now + @asset_ttl_ms
        })

      {:ok,
       %{
         "relativeUrl" =>
           "/api/assets/" <> sign(claims) <> "/" <> URI.encode(name, &URI.char_unreserved?/1),
         "expiresAt" => claims["expiresAt"]
       }}
    end
  end

  defp asset_claims(%{"_tag" => "project-favicon", "cwd" => cwd} = resource, now) do
    if File.dir?(cwd) do
      case HalC2.ProjectFavicon.resolve(cwd, saved_favicon(cwd)) do
        nil ->
          {:ok, %{"path" => nil, "expiresAt" => favicon_expiry(now)}, "project-favicon-missing"}

        path ->
          if String.downcase(Path.extname(path)) in @image_extensions do
            revision = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

            {:ok,
             %{
               "path" => path,
               "mimeType" => MIME.from_path(path),
               "disposition" => "inline",
               "expiresAt" => favicon_expiry(now)
             }, "v#{revision}-#{Path.basename(path)}"}
          else
            error("AssetPreviewTypeValidationError", resource, "Only images are served as icons.")
          end
      end
    else
      error("AssetWorkspaceContextNotFoundError", resource, "Workspace context was not found.")
    end
  end

  defp asset_claims(%{"_tag" => "native-app-icon", "app" => app}, _now),
    do:
      {:ok, %{"source" => "native-app-icon", "app" => app, "disposition" => "inline"},
       "native-app-icon.png"}

  defp asset_claims(%{"_tag" => "github-media", "cwd" => cwd, "url" => url}, _now) do
    case HalC2.Attachments.GitHubMedia.fetch_url(url) do
      nil ->
        {:error,
         %{
           "_tag" => "AssetGitHubMediaUrlValidationError",
           "message" => "Only media hosted by GitHub can be fetched with a GitHub credential."
         }}

      fetch_url ->
        {:ok, %{"source" => "github-media", "url" => fetch_url, "cwd" => cwd},
         HalC2.Attachments.GitHubMedia.file_name(fetch_url)}
    end
  end

  defp asset_claims(resource, _now) do
    with {:ok, path, mime, name} <- resolve(resource) do
      claims = %{
        "path" => path,
        "mimeType" => mime,
        "fileName" => name,
        "disposition" =>
          resource["disposition"] ||
            if(resource["_tag"] == "attachment", do: "attachment", else: "inline")
      }

      # A media file is served only while it is the file that was signed: one
      # replaced under its name (a rename over it) needs a new URL.
      {:ok,
       if(resource["_tag"] == "media-file", do: Map.merge(claims, identity(path)), else: claims),
       name}
    end
  end

  # A favicon URL stays the same for half an hour, so clients cache one image.
  defp favicon_expiry(now), do: (div(now, 30 * 60_000) + 2) * 30 * 60_000

  defp saved_favicon(cwd) do
    Enum.find_value(HalC2.Shell.rows(), fn
      {{_mc, _id}, {"project", %{"workspaceRoot" => ^cwd, "faviconPath" => path}}}
      when is_binary(path) ->
        path

      _ ->
        nil
    end)
  end

  defp identity(path) do
    case File.stat(path) do
      {:ok, %File.Stat{major_device: device, inode: inode}} ->
        %{"device" => device, "inode" => inode}

      _ ->
        %{}
    end
  end

  @doc """
  Serves a signed asset on this MC for a request with `headers` (`range` and
  `if-range`, lower-case): `{:ok, status, headers, body}` or `{:error, status, message}`.
  A successful file body is `{:stream, pid, ref}`; the consumer starts it with
  `{ref, :start, consumer_pid}` and acknowledges each `{ref, :chunk, bytes}` with
  `{ref, :ack}`. A single byte range is answered with 206, so a player seeks a
  long video without downloading it.
  """
  def serve(token, headers \\ %{}) do
    case verify(token) do
      {:ok, %{"kind" => "asset"} = claims} -> serve_claims(claims, headers)
      {:ok, _} -> {:error, 403, "Not an asset URL."}
      {:error, message} -> {:error, 403, message}
    end
  end

  @doc false
  def chunk_bytes, do: @chunk_bytes

  defp serve_claims(%{"source" => "native-app-icon", "app" => app} = claims, headers) do
    case HalC2.Attachments.AppIcon.resolve(app) do
      nil -> {:error, 404, "The application's icon was not found."}
      path -> serve_file(path, Map.put(claims, "mimeType", MIME.from_path(path)), headers)
    end
  end

  defp serve_claims(%{"source" => "github-media"} = claims, headers),
    do: HalC2.Attachments.GitHubMedia.serve(claims, headers)

  defp serve_claims(%{"path" => nil}, _headers), do: {:error, 404, "The project has no favicon."}
  defp serve_claims(%{"path" => path} = claims, headers), do: serve_file(path, claims, headers)

  defp serve_file(path, claims, headers) do
    caller = self()
    ref = make_ref()
    {pid, monitor} = spawn_monitor(fn -> file_answer(caller, ref, path, claims, headers) end)

    receive do
      {^pid, ^ref, answer} ->
        Process.demonitor(monitor, [:flush])
        answer

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, 404, "The file is gone."}
    after
      @stream_timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, 404, "The file is gone."}
    end
  end

  defp file_answer(caller, ref, path, claims, headers) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          case opened_stat(file, claims) do
            {:ok, size} -> send_file_answer(caller, ref, file, size, path, claims, headers)
            :error -> send(caller, {self(), ref, {:error, 404, "The file is gone."}})
          end
        after
          :file.close(file)
        end

      _ ->
        send(caller, {self(), ref, {:error, 404, "The file is gone."}})
    end
  end

  # This stats the opened descriptor, not the path: after this point a rename or
  # symlink swap cannot change which inode the stream reads.
  defp opened_stat(file, claims) do
    with {:ok, info} <- :file.read_file_info(file, [:raw]),
         %File.Stat{type: :regular, size: size} = stat <- File.Stat.from_record(info),
         true <-
           claims["inode"] == nil or
             {stat.major_device, stat.inode} == {claims["device"], claims["inode"]} do
      {:ok, size}
    else
      _ -> :error
    end
  end

  defp send_file_answer(caller, ref, file, size, path, claims, headers) do
    name = String.replace(claims["fileName"] || Path.basename(path), ~s("), "")

    base = [
      {"content-type", claims["mimeType"] || "application/octet-stream"},
      {"content-disposition", ~s(#{claims["disposition"] || "inline"}; filename="#{name}")},
      {"cache-control", "private, max-age=3600"},
      {"accept-ranges", "bytes"}
    ]

    case byte_range(headers["range"], size) do
      nil ->
        send_stream_answer(caller, ref, 200, [content_length(size) | base])
        stream_file(file, ref, 0, size)

      {first, last} ->
        send_stream_answer(caller, ref, 206, [
          content_length(last - first + 1),
          {"content-range", "bytes #{first}-#{last}/#{size}"} | base
        ])

        stream_file(file, ref, first, last - first + 1)

      :unsatisfiable ->
        send(caller, {self(), ref, {:ok, 416, [{"content-range", "bytes */#{size}"}], ""}})
    end
  end

  # A declared length lets a player show progress and keeps the HTTP server from
  # compressing the stream; a body cut short is then visible to the client.
  defp content_length(length), do: {"content-length", Integer.to_string(length)}

  defp send_stream_answer(caller, ref, status, headers),
    do: send(caller, {self(), ref, {:ok, status, headers, {:stream, self(), ref}}})

  defp stream_file(file, ref, offset, length) do
    receive do
      {^ref, :start, consumer} ->
        monitor = Process.monitor(consumer)
        stream_span(file, ref, consumer, monitor, offset, length)
    after
      @stream_timeout_ms -> :ok
    end
  end

  defp stream_span(_file, ref, consumer, _monitor, _offset, 0),
    do: send(consumer, {ref, :done})

  defp stream_span(file, ref, consumer, monitor, offset, length) do
    case :file.pread(file, offset, min(length, @chunk_bytes)) do
      {:ok, bytes} when byte_size(bytes) > 0 ->
        case offer_chunk(ref, consumer, monitor, bytes) do
          :ok ->
            read = byte_size(bytes)
            stream_span(file, ref, consumer, monitor, offset + read, length - read)

          :stop ->
            :ok
        end

      _ ->
        send(consumer, {ref, :error, :read})
    end
  end

  defp offer_chunk(ref, consumer, monitor, bytes) do
    send(consumer, {ref, :chunk, bytes})

    receive do
      {^ref, :ack} -> :ok
      {^ref, :stop} -> :stop
      {:DOWN, ^monitor, :process, ^consumer, _reason} -> :stop
    after
      @stream_timeout_ms -> :stop
    end
  end

  # One `bytes=` range (`a-b`, `a-` or `-n`); anything else serves the whole file.
  defp byte_range("bytes=" <> spec, size) do
    case String.split(spec, "-", parts: 2) do
      ["", suffix] ->
        with {n, ""} when n > 0 <- Integer.parse(suffix),
             do: if(size == 0, do: :unsatisfiable, else: {max(size - n, 0), size - 1}),
             else: (_ -> nil)

      [first, last] ->
        with {a, ""} <- Integer.parse(first),
             {b, ""} <- if(last == "", do: {size - 1, ""}, else: Integer.parse(last)) do
          cond do
            a >= size -> :unsatisfiable
            b < a -> nil
            true -> {a, min(b, size - 1)}
          end
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp byte_range(_range, _size), do: nil

  defp resolve(%{"_tag" => "attachment", "attachmentId" => id} = resource) do
    case path(%{"id" => id}) do
      nil ->
        error("AssetAttachmentNotFoundError", resource, "Attachment was not found.")

      file ->
        {:ok, file, resource["mimeType"] || MIME.from_path(file),
         resource["fileName"] || Path.basename(file)}
    end
  end

  defp resolve(%{"_tag" => "space-image", "spaceId" => space_id, "imageId" => id} = resource) do
    case HalC2.Space.image_file(space_id, id) do
      {:ok, file, mime, name} -> {:ok, file, mime, name}
      :error -> error("AssetAttachmentNotFoundError", resource, "The image was not found.")
    end
  end

  defp resolve(%{"_tag" => "workspace-file", "threadId" => thread_id, "path" => relative} = r),
    do: project_file(r, thread_root(thread_id), relative)

  defp resolve(%{"_tag" => "draft-workspace-file", "cwd" => cwd, "path" => relative} = r),
    do: project_file(r, cwd, relative)

  # A media file may be anywhere the MC can read, but only a media type.
  defp resolve(%{"_tag" => "media-file", "threadId" => thread_id, "path" => path} = resource) do
    full =
      if Path.type(path) == :absolute,
        do: path,
        else: Path.join(thread_root(thread_id) || "/", path)

    cond do
      String.downcase(Path.extname(full)) not in @media_extensions ->
        error("AssetPreviewTypeValidationError", resource, "Only media files are served.")

      not File.regular?(full) ->
        error("AssetWorkspaceAssetNotFoundError", resource, "Media file was not found.")

      true ->
        {:ok, full, media_type(full), Path.basename(full)}
    end
  end

  defp resolve(%{"_tag" => tag} = resource),
    do:
      error(
        "AssetWorkspaceResolutionError",
        resource,
        "#{tag} files are not served by this MC yet."
      )

  # The mime library lacks these audio types, which would otherwise serve as
  # application/octet-stream.
  @audio_types %{".ogg" => "audio/ogg", ".m4a" => "audio/mp4", ".flac" => "audio/flac"}

  defp media_type(path) do
    extension = String.downcase(Path.extname(path))
    Map.get_lazy(@audio_types, extension, fn -> MIME.from_path(path) end)
  end

  defp project_file(resource, nil, _relative),
    do: error("AssetWorkspaceContextNotFoundError", resource, "Workspace context was not found.")

  defp project_file(resource, root, relative) do
    case HalC2.Workspace.resolve(root, relative) do
      {:ok, full} ->
        if File.regular?(full),
          do: {:ok, full, media_type(full), Path.basename(full)},
          else:
            error("AssetWorkspaceAssetNotFoundError", resource, "Workspace file was not found.")

      {:error, %{"message" => message}} ->
        error("AssetWorkspaceResolutionError", resource, message)
    end
  end

  defp thread_root(thread_id) do
    case HalC2.Shell.row(node(), thread_id) do
      {"thread", row} -> row["worktreePath"] || project_root(row["projectId"])
      _ -> nil
    end
  end

  defp project_root(nil), do: nil

  defp project_root(project_id) do
    case HalC2.Shell.row(node(), project_id) do
      {"project", %{"workspaceRoot" => root}} -> root
      _ -> nil
    end
  end

  # The contract's asset errors carry the resource; `cause` where they take one.
  defp error(tag, resource, message) do
    detail = %{"_tag" => tag, "resource" => resource, "message" => message}

    {:error,
     if(tag == "AssetWorkspaceResolutionError",
       do: Map.put(detail, "cause", message),
       else: detail
     )}
  end

  # --- tokens ----------------------------------------------------------------------

  @doc "The MC a signed token was issued by (unverified: only for routing)."
  def issuer(token) do
    with [payload, _signature] <- String.split(token, ".", parts: 2),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"mc" => name}} <- JSON.decode(json),
         mc when mc != nil <- Enum.find(known_mcs(), &(Atom.to_string(&1) == name)) do
      {:ok, mc}
    else
      _ -> :error
    end
  end

  # Members that went offline stay known to the shell, so their links fail as
  # unavailable rather than invalid.
  defp known_mcs do
    [node() | Node.list()] ++ for {mc, _} <- HalC2.Shell.environments(), do: mc
  rescue
    ArgumentError -> [node() | Node.list()]
  end

  defp sign(claims) do
    payload =
      claims
      |> Map.merge(%{"v" => 1, "mc" => Atom.to_string(node())})
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    payload <> "." <> mac(payload)
  end

  defp verify(token) do
    with [payload, signature] <- String.split(token, ".", parts: 2),
         true <- Plug.Crypto.secure_compare(signature, mac(payload)),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"expiresAt" => expires} = claims} <- JSON.decode(json),
         true <- expires > now_ms() do
      {:ok, claims}
    else
      _ -> {:error, "The link is invalid or expired."}
    end
  end

  defp mac(payload),
    do: :crypto.mac(:hmac, :sha256, secret(), payload) |> Base.url_encode64(padding: false)

  # One random key per MC, kept owner-only in its home.
  defp secret do
    case :persistent_term.get({__MODULE__, :secret}, nil) do
      nil ->
        path = Path.join([HalC2.Paths.data_dir(), "secrets", "asset-signing-key"])

        key =
          case File.read(path) do
            {:ok, key} when byte_size(key) == 32 ->
              key

            _ ->
              key = :crypto.strong_rand_bytes(32)
              File.mkdir_p!(Path.dirname(path))
              File.write!(path, key)
              File.chmod!(path, 0o600)
              key
          end

        :persistent_term.put({__MODULE__, :secret}, key)
        key

      key ->
        key
    end
  end

  # --- ids and paths ---------------------------------------------------------------

  defp id_suffix("file", name) do
    case String.downcase(Path.extname(name)) do
      "." <> ext ->
        if Regex.match?(~r/^[a-z0-9]{1,10}$/, ext) and ext != "part", do: "-" <> ext, else: "-bin"

      _ ->
        "-bin"
    end
  end

  defp id_suffix(_image, _name), do: ""

  defp extension("file", _mime, name) do
    "-" <> ext = id_suffix("file", name)
    "." <> ext
  end

  defp extension(_image, mime, _name), do: Map.get(@image_types, String.downcase(mime), ".bin")

  defp safe_id?(id), do: is_binary(id) and Regex.match?(~r/^[a-z0-9_-]{1,200}$/i, id)

  @doc "The part of a thread's attachment ids that names the thread."
  def thread_segment(thread_id) do
    segment =
      thread_id
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    if segment in ["", "pending"], do: "_pending", else: segment
  end

  @doc false
  def dir, do: Path.join(HalC2.Paths.data_dir(), "attachments")
  defp now_ms, do: System.system_time(:millisecond)
end
