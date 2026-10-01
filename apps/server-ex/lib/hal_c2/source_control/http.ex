defmodule HalC2.SourceControl.Http do
  @moduledoc """
  The HTTP requests the MC makes to a source control host's API itself (Bitbucket,
  and Forgejo through `fj`'s stored token). Redirects are not followed, so a
  credential never travels to another origin.
  """

  @timeout 30_000
  @max_bytes 8 * 1024 * 1024

  @doc """
  `{:ok, status, headers, body}` (header names lowercased), or `{:error, detail}`
  when no answer came. Options: `:body` (sent as JSON when not a binary),
  `:timeout` (ms).
  """
  def request(method, url, headers, opts \\ []) do
    headers = Enum.map(headers, fn {name, value} -> {to_charlist(name), to_charlist(value)} end)
    http = [timeout: opts[:timeout] || @timeout, autoredirect: false] ++ ssl(url)

    request =
      case opts[:body] do
        nil ->
          {to_charlist(url), headers}

        body ->
          body = if is_binary(body), do: body, else: JSON.encode!(body)
          {to_charlist(url), headers, ~c"application/json", body}
      end

    case :httpc.request(method, request, http, body_format: :binary) do
      {:ok, {{_, status, _}, headers, body}} when byte_size(body) <= @max_bytes ->
        {:ok, status, Map.new(headers, fn {k, v} -> {String.downcase("#{k}"), "#{v}"} end), body}

      {:ok, _} ->
        {:error, "The host answered with more than #{@max_bytes} bytes."}

      {:error, reason} ->
        {:error, "The host could not be reached: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp ssl("https:" <> _), do: [ssl: :httpc.ssl_verify_host_options(true)]
  defp ssl(_url), do: []
end
