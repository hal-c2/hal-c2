defmodule T3.Attachments.GitHubMedia do
  @moduledoc """
  Media a pull request body points at on GitHub (`github-media` assets), as the Node
  server serves it (`GitHubMediaFetch.ts`, `githubMedia.ts`). A private repository
  answers an unauthenticated request for one with 404, so the node fetches it with
  the host's `gh` credential and hands the bytes back; the token rides only on
  requests to GitHub's own hosts and never reaches the client.

  `Application.get_env(:t3, :github_media_origin)` points fetches at another origin
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

  @doc "Fetches the claims' `url` with the `gh` credential: `{:ok, status, headers, body}`."
  def serve(%{"url" => url, "cwd" => cwd, "expiresAt" => expires}, headers) do
    remaining = div(expires - System.system_time(:millisecond), 1000)

    base = [
      {"cache-control",
       if(remaining > 0, do: "private, max-age=#{remaining}", else: "private, no-store")},
      {"x-content-type-options", "nosniff"}
    ]

    forwarded = for name <- ["range", "if-range"], value = headers[name], do: {name, value}

    case fetch(url, forwarded, token(cwd), 0) do
      {:ok, status, _headers, _body} when status >= 400 ->
        {:ok, if(status >= 500, do: 502, else: status), base, ""}

      {:ok, status, upstream, body} ->
        type =
          (upstream["content-type"] || "")
          |> String.split(";")
          |> hd()
          |> String.trim()
          |> String.downcase()

        type =
          if Regex.match?(@media, type), do: type, else: MIME.from_path(file_name(url))

        if Regex.match?(@media, type) do
          kept =
            for name <- @forwarded_response,
                name != "content-type",
                v = upstream[name],
                do: {name, v}

          svg =
            if type == "image/svg+xml",
              do: [
                {"content-security-policy",
                 "default-src 'none'; style-src 'unsafe-inline'; sandbox"}
              ],
              else: []

          {:ok, status, [{"content-type", type} | base] ++ kept ++ svg, body}
        else
          {:ok, 415, base, ""}
        end

      :error ->
        {:ok, 502, base, ""}
    end
  end

  # GitHub answers an asset with a redirect to a signed object URL, which needs no
  # credential: the token rides only on requests to GitHub itself.
  defp fetch(url, headers, token, hop) do
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
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, response_headers, body}} ->
        response =
          Map.new(response_headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

        cond do
          status not in 300..399 ->
            {:ok, status, response, body}

          hop >= @max_redirects or response["location"] == nil ->
            :error

          true ->
            next = URI.merge(url, response["location"]) |> URI.to_string()

            if String.starts_with?(next, "https://"),
              do: fetch(next, headers, token, hop + 1),
              else: :error
        end

      _ ->
        :error
    end
  end

  defp target(url) do
    case Application.get_env(:t3, :github_media_origin) do
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
        case T3.PullRequests.GitHub.gh(cwd, ["auth", "token", "--hostname", "github.com"]) do
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
