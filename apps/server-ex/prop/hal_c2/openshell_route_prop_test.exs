Code.require_file("../../../../plugins/cliproxyapi/mc/instances.ex", __DIR__)

defmodule HalC2.OpenShellRoutePropTest do
  @moduledoc """
  Where a review sandbox's model requests go (`HalC2.OpenShell.Route`, #1781), over
  any base URL a provider instance can name, as the CLIProxyAPI plugin writes its
  instances (`HalC2Plugins.CliProxyApi.Instances.desired/4`) or as anything else
  does. The promises:

    * an instance that is not the plugin's, with a base URL other than its API's own,
      is refused;
    * a plugin's instance on this machine is reached at the sandbox's address for
      this machine, its addresses pinned, at the proxy's port alone;
    * one elsewhere is refused, over https too: OpenShell binds the key to a host and
      port, not to TLS;
    * the path the agent dials under is plain segments, never a query, a fragment or
      credentials;
    * the client key is never in the agent's command or environment.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.OpenShell.Route
  alias HalC2Plugins.CliProxyApi.Instances

  @host %{
    host: "host.containers.internal",
    dialed: "host.containers.internal.",
    ips: ["10.0.0.5"]
  }
  @local ~w(127.0.0.1 127.1.2.3 localhost [::1])
  @hosts @local ++ ~w(192.168.1.4 proxy.example.com Proxy.Example.COM)
  @paths ["", "/", "/team", "/a/b", "/../x", "/%2e%2e", "/a b", "/v0/management"]
  @extras ["", "?x=1", "#f"]
  @keys ["client-key", "client-key", "client-key", ""]

  defp base do
    let [
      scheme <- frequency([{5, "http"}, {4, "https"}, {1, "ftp"}]),
      userinfo <- frequency([{9, ""}, {1, "user:pw@"}]),
      host <- elements(@hosts),
      port <- oneof([nil, integer(1, 65_535)]),
      path <- frequency([{6, elements(["", "/", "/team", "/a/b"])}, {4, elements(@paths)}]),
      extra <- frequency([{8, ""}, {2, elements(@extras)}])
    ] do
      "#{scheme}://#{userinfo}#{host}#{if port, do: ":#{port}"}#{path}#{extra}"
    end
  end

  defp instance(driver, base, key) do
    instance = Instances.desired(driver, base, key, "/claude")
    env = Map.new(instance["environment"], &{&1["name"], &1["value"]})
    args = OptionParser.split(get_in(instance, ["config", "launchArgs"]) || "")
    {instance["driver"], %{env: env, args: args}}
  end

  defp upstream("claudeAgent"), do: "ANTHROPIC_API_KEY"
  defp upstream("codex"), do: "OPENAI_API_KEY"

  property "an instance that is not the plugin's is refused for any base URL of its own" do
    forall {name, base, key} <- {elements(~w(claude codex)), base(), elements(@keys)} do
      {driver, instance} = instance(name, base, key)

      case Route.pick(driver, Map.put(instance, :plugin?, false), upstream(driver)) do
        {:error, _} -> true
        {:ok, %{proxy: nil}} -> String.starts_with?(base, "https://api.anthropic.com")
        {:ok, _} -> false
      end
    end
  end

  property "a plugin's instance is reached at the proxy's port alone, its key never in the agent's command",
    numtests: 500 do
    forall {name, base, key} <- {elements(~w(claude codex)), base(), elements(@keys)} do
      {driver, instance} = instance(name, base, key)

      case Route.pick(driver, Map.put(instance, :plugin?, true), upstream(driver)) do
        {:error, message} ->
          not String.contains?(message, "pw") and
            (key == "" or not String.contains?(message, key))

        {:ok, %{key: ^key, proxy: proxy}} when key != "" ->
          endpoint = Route.endpoint(proxy, @host)
          uri = URI.parse(endpoint.url)
          {command, environment} = Route.agent(driver, endpoint.url, upstream(driver))
          shown = Enum.join(command ++ Map.keys(environment) ++ Map.values(environment), " ")

          # Only a proxy on this machine is taken, reached as the sandbox reaches it.
          placed =
            Enum.any?(@local, &String.contains?(base, "://#{&1}")) and
              endpoint.host == @host.host and endpoint.ips == @host.ips and
              uri.host == @host.dialed

          placed and uri.scheme == proxy.scheme and endpoint.port == proxy.port and
            uri.port == proxy.port and
            uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
            (uri.path || "") =~ ~r/\A(\/[A-Za-z0-9_.-]+)*\z/ and
            not String.contains?(uri.path || "", "..") and
            not String.contains?(shown, key)

        {:ok, _} ->
          false
      end
    end
  end
end
