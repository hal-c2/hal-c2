defmodule HalC2.Attachments.GitHubMedia do
  @moduledoc """
  Media a pull request body points at on GitHub (`github-media` assets). A private
  repository
  answers an unauthenticated request for one with 404, so the MC fetches it with
  the host's `gh` credential and hands the bytes back; the token rides only on
  requests to GitHub's own hosts and never reaches the client.

  `Application.get_env(:hal_c2, :github_media_origin)` points fetches at another origin
  (tests); the credential still follows the GitHub host the URL names.
  """

  @credentialed ~w(github.com www.github.com raw.githubusercontent.com media.githubusercontent.com)
  @raw "raw.githubusercontent.com"
  @lfs "media.githubusercontent.com"
  @attachment ~r/^\/user-attachments\/assets\/[\w-]+$/u
  @legacy_attachment ~r/^\/[^\/]+\/[^\/]+\/assets\/\d+\/[\w-]+$/u
  @repository_file ~r/^\/([^\/]+)\/([^\/]+)\/(?:raw|blob)\/(.*[^\/])$/u
  @media ~r/^(?:image|video|audio)\/[\w!#$&^.+-]+$/i
  @forwarded_response ~w(content-type content-range accept-ranges etag last-modified)
  @token_ttl_ms 5 * 60_000
  @max_redirects 3
  @max_response_bytes 512 * 1024 * 1024
  @stream_timeout_ms 60_000

  @doc "The URL to fetch with a GitHub credential for `source`, or `nil` if it is not GitHub media."
  def fetch_url(source) do
    with %URI{scheme: "https", host: host, path: path} = uri when is_binary(host) <-
           URI.parse(source),
         host = String.downcase(host),
         path = path || "/" do
      query = if uri.query, do: "?" <> uri.query, else: ""

      cond do
        host in [@raw, @lfs] ->
          "https://#{host}#{path}#{query}"

        host not in ["github.com", "www.github.com"] ->
          nil

        Regex.match?(@attachment, path) or Regex.match?(@legacy_attachment, path) ->
          "https://github.com" <> path

        match = Regex.run(@repository_file, path) ->
          [_, owner, repo, file] = match
          "https://#{@raw}/#{owner}/#{repo}/#{file}"

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  @doc "The last path segment of a fetch URL, for the signed URL's display name."
  def file_name(url) do
    segment = url |> URI.parse() |> Map.get(:path, "") |> to_string() |> Path.basename()
    name = String.replace(URI.decode(segment), ~r/[\x00-\x1f\x7f\\\/]/u, "")
    if name == "", do: "github-media", else: name
  rescue
    _ -> "github-media"
  end

  @doc "Fetches the claims' `url` with the `gh` credential, streaming a successful body."
  def serve(%{"url" => url, "cwd" => cwd, "expiresAt" => expires}, headers) do
    remaining = div(expires - System.system_time(:millisecond), 1000)

    base = [
      {"cache-control",
       if(remaining > 0, do: "private, max-age=#{remaining}", else: "private, no-store")},
      {"x-content-type-options", "nosniff"}
    ]

    forwarded = for name <- ["range", "if-range"], value = headers[name], do: {name, value}
    max = Application.get_env(:hal_c2, :github_media_max_bytes, @max_response_bytes)
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn -> produce(caller, ref, url, forwarded, token(cwd), base, max) end)

    receive do
      {^pid, ^ref, answer} ->
        Process.demonitor(monitor, [:flush])
        answer

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:ok, 502, base, ""}
    after
      30_000 ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:ok, 502, base, ""}
    end
  end

  defp produce(caller, ref, url, headers, token, base, max) do
    case fetch(url, headers, token, 0, max) do
      {:stream, status, upstream, request, handler} ->
        case media_answer(status, upstream, url, base, :stream) do
          {:ok, status, response_headers, :stream} ->
            send(
              caller,
              {self(), ref, {:ok, status, response_headers, {:stream, self(), ref}}}
            )

            stream_upstream(request, handler, ref, max)

          answer ->
            :httpc.cancel_request(request)
            send(caller, {self(), ref, answer})
        end

      {:ok, 200, upstream, body} ->
        case media_answer(200, upstream, url, base, :stream) do
          {:ok, 200, response_headers, :stream} ->
            send(caller, {self(), ref, {:ok, 200, response_headers, {:stream, self(), ref}}})
            stream_binary(body, ref)

          answer ->
            send(caller, {self(), ref, answer})
        end

      {:ok, 206, upstream, body} ->
        case media_answer(206, upstream, url, base, :stream) do
          {:ok, 206, response_headers, :stream} ->
            send(caller, {self(), ref, {:ok, 206, response_headers, {:stream, self(), ref}}})
            stream_binary(body, ref)

          answer ->
            send(caller, {self(), ref, answer})
        end

      {:ok, status, upstream, body} ->
        send(caller, {self(), ref, media_answer(status, upstream, url, base, body)})

      :too_large ->
        send(caller, {self(), ref, {:ok, 413, base, "GitHub media is too large."}})

      :error ->
        send(caller, {self(), ref, {:ok, 502, base, ""}})
    end
  end

  defp media_answer(status, _upstream, _url, base, _body) when status >= 400,
    do: {:ok, if(status >= 500, do: 502, else: status), base, ""}

  defp media_answer(status, upstream, url, base, body) do
    type =
      (upstream["content-type"] || "")
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    # Only a missing or generic type falls back to the file's name; an HTML page named
    # `shot.png` stays refused.
    type =
      cond do
        Regex.match?(@media, type) ->
          type

        type in ["", "application/octet-stream", "binary/octet-stream"] ->
          MIME.from_path(file_name(url))

        true ->
          type
      end

    if Regex.match?(@media, type) do
      kept =
        for name <- @forwarded_response,
            name != "content-type",
            v = upstream[name],
            do: {name, v}

      svg =
        if type == "image/svg+xml",
          do: [
            {"content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox"}
          ],
          else: []

      {:ok, status,
       [{"content-type", type} | base] ++ kept ++ declared_length(upstream, body) ++ svg, body}
    else
      {:ok, 415, base, ""}
    end
  end

  # A streamed body declares the length GitHub did, so a client can tell a body cut short
  # from a whole one; httpc fails a short upstream body, and the router drops the
  # connection. An encoded body's length is not the decoded one, so it goes without.
  defp declared_length(upstream, :stream) do
    with nil <- upstream["content-encoding"],
         {size, ""} when size >= 0 <- Integer.parse(upstream["content-length"] || "") do
      [{"content-length", Integer.to_string(size)}]
    else
      _ -> []
    end
  end

  defp declared_length(_upstream, _body), do: []

  # GitHub answers an asset with a redirect to a signed object URL, which needs no
  # credential: the token rides only on requests to GitHub itself.
  defp fetch(url, headers, token, hop, max) do
    host = URI.parse(url).host

    auth =
      if token && host in @credentialed, do: [{"authorization", "Bearer " <> token}], else: []

    request_headers =
      for {k, v} <- [{"accept-encoding", "identity"} | headers ++ auth],
          do: {String.to_charlist(k), String.to_charlist(v)}

    case :httpc.request(
           :get,
           {String.to_charlist(target(url)), request_headers},
           [timeout: 30_000, autoredirect: false, ssl: :httpc.ssl_verify_host_options(true)],
           sync: false,
           stream: {:self, :once},
           max_body_size: max
         ) do
      {:ok, request} -> await_response(url, headers, token, hop, max, request)
      {:error, :body_too_big} -> :too_large
      _ -> :error
    end
  end

  defp await_response(url, headers, token, hop, max, request) do
    receive do
      {:http, {^request, :stream_start, response_headers, handler}} ->
        response = response_headers(response_headers)

        if declared_too_large?(response, max) do
          :httpc.cancel_request(request)
          :too_large
        else
          status = if response["content-range"], do: 206, else: 200
          {:stream, status, response, request, handler}
        end

      {:http, {^request, {{_, status, _}, response_headers, body}}} ->
        response = response_headers(response_headers)

        cond do
          status not in 300..399 ->
            {:ok, status, response, body}

          hop >= @max_redirects or response["location"] == nil ->
            :error

          true ->
            next = URI.merge(url, response["location"]) |> URI.to_string()

            if String.starts_with?(next, "https://"),
              do: fetch(next, headers, token, hop + 1, max),
              else: :error
        end

      {:http, {^request, {:error, :body_too_big}}} ->
        :too_large

      {:http, {^request, {:error, {:body_too_long, {:max, _limit}}}}} ->
        :too_large

      {:http, {^request, {:error, _reason}}} ->
        :error
    after
      30_000 ->
        :httpc.cancel_request(request)
        :error
    end
  end

  defp response_headers(headers),
    do: Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

  defp declared_too_large?(headers, max) do
    case Integer.parse(headers["content-length"] || "") do
      {size, ""} -> size > max
      _ -> false
    end
  end

  defp stream_upstream(request, handler, ref, max) do
    case await_consumer(ref) do
      {:ok, consumer, monitor} ->
        :httpc.stream_next(handler)
        upstream_chunks(request, handler, ref, consumer, monitor, 0, max)

      :stop ->
        :httpc.cancel_request(request)
    end
  end

  defp upstream_chunks(request, handler, ref, consumer, monitor, total, max) do
    receive do
      {:http, {^request, :stream, bytes}} ->
        if total + byte_size(bytes) > max do
          :httpc.cancel_request(request)
          send(consumer, {ref, :error, :too_large})
        else
          case offer_chunks(ref, consumer, monitor, bytes) do
            :ok ->
              :httpc.stream_next(handler)

              upstream_chunks(
                request,
                handler,
                ref,
                consumer,
                monitor,
                total + byte_size(bytes),
                max
              )

            :stop ->
              :httpc.cancel_request(request)
          end
        end

      {:http, {^request, :stream_end, _headers}} ->
        send(consumer, {ref, :done})

      {:http, {^request, {:error, :body_too_big}}} ->
        send(consumer, {ref, :error, :too_large})

      {:http, {^request, {:error, {:body_too_long, {:max, _limit}}}}} ->
        send(consumer, {ref, :error, :too_large})

      {:http, {^request, {:error, _reason}}} ->
        send(consumer, {ref, :error, :upstream})

      {^ref, :stop} ->
        :httpc.cancel_request(request)

      {:DOWN, ^monitor, :process, ^consumer, _reason} ->
        :httpc.cancel_request(request)
    after
      @stream_timeout_ms ->
        :httpc.cancel_request(request)
        send(consumer, {ref, :error, :timeout})
    end
  end

  defp stream_binary(bytes, ref) do
    case await_consumer(ref) do
      {:ok, consumer, monitor} ->
        case offer_chunks(ref, consumer, monitor, bytes) do
          :ok -> send(consumer, {ref, :done})
          :stop -> :ok
        end

      :stop ->
        :ok
    end
  end

  defp await_consumer(ref) do
    receive do
      {^ref, :start, consumer} ->
        {:ok, consumer, Process.monitor(consumer)}

      {^ref, :stop} ->
        :stop
    after
      @stream_timeout_ms -> :stop
    end
  end

  defp offer_chunks(_ref, _consumer, _monitor, ""), do: :ok

  defp offer_chunks(ref, consumer, monitor, bytes) do
    size = min(byte_size(bytes), HalC2.Attachments.chunk_bytes())
    chunk = binary_part(bytes, 0, size)

    case offer_chunk(ref, consumer, monitor, chunk) do
      :ok ->
        rest = binary_part(bytes, size, byte_size(bytes) - size)
        offer_chunks(ref, consumer, monitor, rest)

      :stop ->
        :stop
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

  defp target(url) do
    case Application.get_env(:hal_c2, :github_media_origin) do
      nil ->
        url

      origin ->
        uri = URI.parse(url)
        origin <> uri.path <> if(uri.query, do: "?" <> uri.query, else: "")
    end
  end

  # `gh` keeps one token per host; asked at most every five minutes. No credential
  # is normal: public media still loads.
  defp token(cwd) do
    now = System.system_time(:millisecond)

    case :persistent_term.get({__MODULE__, :token}, nil) do
      {at, token} when now - at < @token_ttl_ms ->
        token

      _ ->
        case HalC2.PullRequests.GitHub.gh(cwd, ["auth", "token", "--hostname", "github.com"]) do
          {:ok, out} when is_binary(out) and out != "" ->
            token = String.trim(out)
            :persistent_term.put({__MODULE__, :token}, {now, token})
            token

          _ ->
            nil
        end
    end
  end
end
