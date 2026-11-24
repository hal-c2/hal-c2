defmodule HalC2.OpenShell.Route do
  @moduledoc """
  Where a review sandbox's agent sends its model's requests (#1781): its API's own
  host, or the CLIProxyAPI the instance routes through, as the CLIProxyAPI plugin's
  "Claude via CLIProxyAPI" and "Codex via CLIProxyAPI" instances do.

  `pick/3` reads that from what the instance holds: Claude's `ANTHROPIC_BASE_URL`
  and `ANTHROPIC_AUTH_TOKEN`, Codex's `-c model_provider=…` launch arguments and the
  variable they name for the key. A base URL is taken from the plugin's own
  instances only, and only one the sandbox can reach without being let through to
  anything else: a proxy on this machine's 127.0.0.1, at the address the sandbox
  reaches this machine by (the review broker's, `HalC2.OpenShell.Broker`) and that port
  alone. Rootless Podman forwards that address to the host's 127.0.0.1 and no other,
  so a proxy on another loopback address, `[::1]` or `127.0.0.2`, is refused too.
  `endpoint/2` turns the pick into the policy's endpoint and what the agent dials.

  A proxy on another machine is refused. OpenShell 0.1.7 binds a credential to an
  endpoint's host, port and path, never to TLS: its forward proxy injects the key into
  a plain `http://` request to that host and port as well, so a sandboxed agent could
  send the proxy key across the network in the clear. On this machine that request
  stays on the host.

  Either way the key is the provider's, which OpenShell injects into the model's
  requests, and the policy lets through that driver's model requests alone, so a
  proxy's other paths (its management API among them) stay shut.
  """

  @provider "review"

  @doc """
  The route `driver`'s agent takes for an instance with variables `env` and launch
  arguments `args` (Codex's, split), `plugin?` when the instance is one the
  CLIProxyAPI plugin put. `upstream_key` names the variable the upstream API's key is
  in, read from `env` and then `system` (the MC's environment).

  `{:ok, %{key: key, proxy: nil}}` for the API's own host, `{:ok, %{key: key, proxy:
  %{scheme, port, prefix}}}` for a proxy on this machine, else `{:error, message}`.
  """
  def pick(driver, %{env: env, args: args, plugin?: plugin?}, upstream_key, system \\ %{}) do
    with {:ok, base, key_var} <- base(driver, env, args) do
      cond do
        base == nil ->
          key(present(env[upstream_key]) || present(system[upstream_key]), nil, fn ->
            "A review sandbox needs #{upstream_key} for #{name(driver)}: a sign-in on this machine does not reach the sandbox. Set it in the provider's environment in Settings."
          end)

        not plugin? ->
          {:error,
           "This provider sends #{name(driver)} to #{shown(base)}, which a review sandbox does not reach. A sandboxed review runs on #{name(driver)}'s own API, or on CLIProxyAPI through the CLIProxyAPI plugin's provider."}

        true ->
          with {:ok, proxy} <- proxy(driver, base) do
            key(present(env[key_var]), proxy, fn ->
              "A review sandbox needs the CLIProxyAPI client key in #{key_var} for #{name(driver)} via CLIProxyAPI, which the CLIProxyAPI plugin sets once it is running."
            end)
          end
      end
    end
  end

  @doc """
  Whether a sandbox on container runtime `runtime` (OpenShell's driver, `"docker"` or
  `"podman"`) reaches `route`'s proxy (`pick/4`'s). On rootless Podman the sandbox's
  proxy connects to this machine from loopback, so a proxy listening on 127.0.0.1 takes
  it. On Docker that traffic arrives on another interface (`HalC2.OpenShell.Broker`
  binds every one there), so a proxy on 127.0.0.1 alone would refuse it; the review is
  refused up front with a reason instead (#1786).
  """
  def reachable(%{proxy: %{}}, "docker"),
    do:
      {:error,
       "A review sandbox on Docker cannot reach a CLIProxyAPI that listens on this machine's 127.0.0.1 only. Review through CLIProxyAPI with OpenShell on Podman, or with the API's own key."}

  def reachable(route, _runtime), do: {:ok, route}

  @doc """
  The policy endpoint and the base URL the agent dials for `proxy` (`pick/3`'s), the
  sandbox reaching this machine as `host` (`%{host, dialed, ips}`, the broker's):
  `%{host, port, ips, url}`.
  """
  def endpoint(proxy, host) do
    %{
      host: host.host,
      port: proxy.port,
      ips: host.ips,
      url: "#{proxy.scheme}://#{host.dialed}:#{proxy.port}#{proxy.prefix}"
    }
  end

  @doc """
  What the agent of `driver` runs with to take `url` (`endpoint/2`'s): `{command,
  environment}`, the key being in `key` in its environment as OpenShell puts it.
  """
  def agent("claudeAgent", url, _key), do: {["claude"], %{"ANTHROPIC_BASE_URL" => url}}

  def agent("codex", url, key) do
    config = [
      "model_provider=#{@provider}",
      "model_providers.#{@provider}.name=CLIProxyAPI",
      "model_providers.#{@provider}.base_url=#{url}/v1",
      "model_providers.#{@provider}.env_key=#{key}",
      "model_providers.#{@provider}.wire_api=responses"
    ]

    {["codex", "app-server" | Enum.flat_map(config, &["-c", &1])], %{}}
  end

  # The base URL `driver` is sent to, nil for its API's own, and the variable its key
  # is in when it is a proxy's.
  defp base("claudeAgent", env, _args) do
    case present(env["ANTHROPIC_BASE_URL"]) do
      nil ->
        {:ok, nil, nil}

      url ->
        if String.trim_trailing(url, "/") == "https://api.anthropic.com",
          do: {:ok, nil, nil},
          else:
            {:ok, url,
             if(present(env["ANTHROPIC_AUTH_TOKEN"]),
               do: "ANTHROPIC_AUTH_TOKEN",
               else: "ANTHROPIC_API_KEY"
             )}
    end
  end

  defp base("codex", env, args) do
    config = config(args)

    case unquote_toml(config["model_provider"]) do
      provider when provider in [nil, "openai"] ->
        case present(env["OPENAI_BASE_URL"]) || unquote_toml(config["openai_base_url"]) do
          nil ->
            {:ok, nil, nil}

          url ->
            if String.trim_trailing(url, "/") == "https://api.openai.com/v1",
              do: {:ok, nil, nil},
              else: {:ok, url, "OPENAI_API_KEY"}
        end

      provider ->
        table = "model_providers.#{provider}."
        url = unquote_toml(config[table <> "base_url"])
        wire = unquote_toml(config[table <> "wire_api"])

        cond do
          url == nil ->
            {:error,
             "This provider runs Codex on model provider #{provider}, which names no base URL a review sandbox could reach."}

          wire != "responses" ->
            {:error,
             "A review sandbox runs Codex over the Responses API, and this provider's model provider #{provider} uses #{wire || "another one"}."}

          true ->
            {:ok, url, unquote_toml(config[table <> "env_key"]) || "OPENAI_API_KEY"}
        end
    end
  end

  # What a proxy's base URL is, for an agent that adds its own `/v1` paths to it:
  # Claude's is the root it is given, Codex's the root with `/v1`.
  defp proxy(driver, url) do
    uri = URI.parse(url)
    path = String.trim_trailing(uri.path || "", "/")

    prefix =
      case driver do
        "codex" -> if String.ends_with?(path, "/v1"), do: String.replace_suffix(path, "/v1", "")
        _ -> path
      end

    cond do
      uri.scheme not in ["http", "https"] or present(uri.host) == nil ->
        {:error, "#{name(driver)}'s base URL in this provider is not an http or https address."}

      uri.userinfo != nil or uri.query != nil or uri.fragment != nil ->
        {:error,
         "#{name(driver)}'s base URL in this provider has credentials, a query or a fragment, which a review sandbox does not send."}

      prefix == nil ->
        {:error,
         "#{name(driver)}'s base URL in this provider does not end in /v1, as CLIProxyAPI's does."}

      not (prefix =~ ~r/\A(\/[A-Za-z0-9_-][A-Za-z0-9_.-]*)*\z/) ->
        {:error,
         "#{name(driver)}'s base URL in this provider has a path a review sandbox does not take."}

      not loopback?(uri.host) ->
        {:error,
         "A review sandbox reaches a CLIProxyAPI on this machine only, and this provider's is #{shown(url)}: OpenShell cannot hold the sandbox to TLS, so the proxy's key could cross the network unencrypted."}

      String.downcase(uri.host) not in ["127.0.0.1", "localhost"] ->
        {:error,
         "A review sandbox reaches this machine at 127.0.0.1 only, and this provider's CLIProxyAPI is at #{shown(url)}. Have CLIProxyAPI listen on 127.0.0.1."}

      # The sandbox dials the broker's alias, which a certificate for this machine
      # does not name, and the request stays on the host either way.
      uri.scheme == "https" ->
        {:error,
         "A review sandbox reaches this machine's CLIProxyAPI over http, and this provider's is #{shown(url)}. Use the proxy's http address on 127.0.0.1 instead."}

      true ->
        {:ok, %{scheme: uri.scheme, port: uri.port, prefix: prefix}}
    end
  end

  defp key(nil, _proxy, message), do: {:error, message.()}
  defp key(key, proxy, _message), do: {:ok, %{key: key, proxy: proxy}}

  # Each `-c key=value` (or `--config`) of Codex's launch arguments, the last winning.
  defp config(args) do
    args
    |> pairs()
    |> Enum.flat_map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> [{String.trim(key), String.trim(value)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp pairs([flag, value | rest]) when flag in ["-c", "--config"], do: [value | pairs(rest)]

  defp pairs([arg | rest]) do
    case arg do
      "--config=" <> value -> [value | pairs(rest)]
      "-c=" <> value -> [value | pairs(rest)]
      _ -> pairs(rest)
    end
  end

  defp pairs([]), do: []

  # Codex reads a `-c` value as TOML, and one that is not TOML as a string.
  defp unquote_toml(nil), do: nil

  defp unquote_toml(value) do
    value =
      case Regex.run(~r/\A(["'])(.*)\1\z/, value) do
        [_, _, inner] -> inner
        _ -> value
      end

    present(value)
  end

  defp loopback?(host) do
    case :inet.parse_address(String.to_charlist(String.trim(host, "[") |> String.trim("]"))) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> String.downcase(host) == "localhost"
    end
  end

  # The scheme and host of a URL, never what else it carries.
  defp shown(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}"

      _ ->
        "an address that is not one"
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil

  defp name("claudeAgent"), do: "Claude"
  defp name("codex"), do: "Codex"
end
