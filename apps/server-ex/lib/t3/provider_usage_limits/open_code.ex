defmodule T3.ProviderUsageLimits.OpenCode do
  @moduledoc """
  OpenCode Go's quota: its rolling (session), weekly and monthly windows from
  `GET https://opencode.ai/zen/go/v1/usage`, with the Go key OpenCode stores, as the
  Node server reads it (`openCodeUsageLimits.ts`).

  An instance on an external OpenCode server is `unsupported`: that server owns its
  credentials, so the node never reads this machine's account for it. No key, or a
  key without a Go subscription (403), is `unsupported` too.
  """

  alias T3.ProviderUsageLimits, as: Limits

  @url "https://opencode.ai/zen/go/v1/usage"
  @windows [
    {"rolling", "go_rolling", "session", "Go · Session", 5 * 60},
    {"weekly", "go_weekly", "weekly", "Go · Weekly", 7 * 24 * 60},
    {"monthly", "go_monthly", "monthly", "Go · Monthly", nil}
  ]

  @doc "The limits of an instance on `server_url` (nil for a local OpenCode), read with `env`."
  def probe(server_url, _env, checked_at) when is_binary(server_url),
    do: Limits.unavailable(checked_at, "unsupported")

  def probe(nil, env, checked_at) do
    case api_key(env) do
      nil ->
        Limits.unavailable(checked_at, "unsupported")

      key ->
        case Limits.get_json(Application.get_env(:t3, :opencode_go_usage_url, @url), key, 5_000) do
          {:ok, 403, _} -> Limits.unavailable(checked_at, "unsupported")
          {:ok, 200, %{"usage" => %{} = usage}} -> limits(usage, checked_at)
          _ -> failed(checked_at)
        end
    end
  rescue
    _ -> failed(checked_at)
  end

  defp limits(usage, checked_at) do
    windows =
      for {key, id, kind, label, minutes} <- @windows do
        %{"percent" => percent, "resetsAt" => resets_at} = usage[key]
        true = is_number(percent)

        %{
          "id" => id,
          "kind" => kind,
          "label" => label,
          "usedPercent" => Limits.clamp(percent),
          "resetsAt" => Limits.iso(resets_at) || raise("no reset time")
        }
        |> Limits.put_present("windowDurationMins", minutes)
      end

    Limits.limits(checked_at, windows)
  end

  # OpenCode's stored `opencode-go` API credential wins over OPENCODE_API_KEY.
  defp api_key(env) do
    auth =
      case env["OPENCODE_AUTH_CONTENT"] do
        content when is_binary(content) and content != "" ->
          JSON.decode!(content)

        _ ->
          data =
            env["XDG_DATA_HOME"] ||
              Path.join([env["HOME"] || System.user_home!(), ".local", "share"])

          case File.read(Path.join([data, "opencode", "auth.json"])) do
            {:ok, body} -> JSON.decode!(body)
            {:error, :enoent} -> %{}
          end
      end

    key =
      case auth["opencode-go"] do
        %{"type" => "api", "key" => key} when is_binary(key) -> key
        _ -> env["OPENCODE_API_KEY"]
      end

    if is_binary(key) and String.trim(key) != "", do: String.trim(key)
  end

  defp failed(checked_at),
    do: Limits.unavailable(checked_at, "probeFailed", "OpenCode Go could not read usage.")
end
