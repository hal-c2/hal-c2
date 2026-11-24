Code.require_file("../../../../../plugins/cliproxyapi/mc/instances.ex", __DIR__)

defmodule HalC2.OpenShell.RouteTest do
  # Where a review sandbox's model requests go (#1781), read from what the instance
  # holds; the CLIProxyAPI plugin's instances are read as the plugin writes them
  # (`HalC2Plugins.CliProxyApi.Instances.desired/4`), so a change to how it writes
  # them fails here.
  use ExUnit.Case, async: true

  alias HalC2.OpenShell.Route
  alias HalC2Plugins.CliProxyApi.Instances

  @host %{
    host: "host.containers.internal",
    dialed: "host.containers.internal.",
    ips: ["10.0.0.5"]
  }

  defp plugin(name, base, key \\ "client-key") do
    instance = Instances.desired(name, base, key, "/claude")
    env = Map.new(instance["environment"], &{&1["name"], &1["value"]})
    args = OptionParser.split(get_in(instance, ["config", "launchArgs"]) || "")
    {instance["driver"], %{env: env, args: args, plugin?: true}}
  end

  defp pick({driver, instance}), do: Route.pick(driver, instance, key(driver))
  defp key("claudeAgent"), do: "ANTHROPIC_API_KEY"
  defp key("codex"), do: "OPENAI_API_KEY"

  describe "the API's own host" do
    test "an instance with no base URL takes its key from its environment, then the MC's" do
      own = %{env: %{"OPENAI_API_KEY" => "sk-own"}, args: [], plugin?: false}
      assert {:ok, %{key: "sk-own", proxy: nil}} = Route.pick("codex", own, "OPENAI_API_KEY")

      bare = %{env: %{}, args: [], plugin?: false}

      assert {:ok, %{key: "sk-mc", proxy: nil}} =
               Route.pick("codex", bare, "OPENAI_API_KEY", %{"OPENAI_API_KEY" => "sk-mc"})

      assert {:error, message} = Route.pick("codex", bare, "OPENAI_API_KEY")
      assert message =~ "needs OPENAI_API_KEY"
    end

    test "Claude's own address is no proxy" do
      claude = %{
        env: %{"ANTHROPIC_BASE_URL" => "https://api.anthropic.com/", "ANTHROPIC_API_KEY" => "k"},
        args: [],
        plugin?: false
      }

      assert {:ok, %{proxy: nil}} = Route.pick("claudeAgent", claude, "ANTHROPIC_API_KEY")
    end

    test "OpenAI's own address is no proxy, by variable or by launch argument" do
      for env <- [%{"OPENAI_BASE_URL" => "https://api.openai.com/v1/"}, %{}],
          args <- [[], ["-c", ~s(openai_base_url="https://api.openai.com/v1")]],
          env != %{} or args != [] do
        codex = %{env: Map.put(env, "OPENAI_API_KEY", "k"), args: args, plugin?: false}
        assert {:ok, %{key: "k", proxy: nil}} = Route.pick("codex", codex, "OPENAI_API_KEY")
      end
    end
  end

  describe "the container runtime" do
    test "a proxy on this machine's loopback is refused on Docker, with the reason" do
      {:ok, route} = pick(plugin("claude", "http://127.0.0.1:8317"))
      assert {:ok, ^route} = Route.reachable(route, "podman")
      assert {:ok, ^route} = Route.reachable(route, nil)
      assert {:error, message} = Route.reachable(route, "docker")
      assert message =~ "on Docker cannot reach a CLIProxyAPI"
    end

    test "the API's own host is reached on Docker too" do
      upstream = %{key: "k", proxy: nil}
      assert {:ok, ^upstream} = Route.reachable(upstream, "docker")
    end
  end

  describe "the CLIProxyAPI plugin's instances" do
    test "Claude via CLIProxyAPI on this machine reaches it at its port, with its client key" do
      assert {:ok, %{key: "client-key", proxy: proxy}} =
               pick(plugin("claude", "http://127.0.0.1:8317"))

      assert %{port: 8317, prefix: "", scheme: "http"} = proxy

      assert Route.endpoint(proxy, @host) == %{
               host: "host.containers.internal",
               port: 8317,
               ips: ["10.0.0.5"],
               url: "http://host.containers.internal.:8317"
             }
    end

    test "Codex via CLIProxyAPI reaches it as its own model provider, its key in the provider's variable" do
      assert {:ok, %{key: "client-key", proxy: proxy}} =
               pick(plugin("codex", "http://localhost:8400/"))

      assert %{port: 8400, prefix: ""} = proxy
      %{url: url} = Route.endpoint(proxy, @host)

      {command, environment} = Route.agent("codex", url, "OPENAI_API_KEY")
      assert environment == %{}
      assert ["codex", "app-server" | config] = command

      assert config |> Enum.chunk_every(2) |> Enum.map(fn ["-c", pair] -> pair end) == [
               "model_provider=review",
               "model_providers.review.name=CLIProxyAPI",
               "model_providers.review.base_url=http://host.containers.internal.:8400/v1",
               "model_providers.review.env_key=OPENAI_API_KEY",
               "model_providers.review.wire_api=responses"
             ]
    end

    test "one on this machine keeps its path" do
      assert {:ok, %{proxy: proxy}} = pick(plugin("claude", "http://127.0.0.1:8317/team"))
      assert %{url: "http://host.containers.internal.:8317/team"} = Route.endpoint(proxy, @host)
    end

    # Rootless Podman forwards the sandbox's host address to 127.0.0.1 alone.
    test "one on another loopback address is refused, naming 127.0.0.1" do
      for base <- ["http://[::1]:8317", "http://127.0.0.2:8317"] do
        assert {:error, message} = pick(plugin("claude", base))
        assert message =~ "listen on 127.0.0.1"
      end

      assert {:ok, _} = pick(plugin("claude", "http://LocalHost:8317"))
    end

    # OpenShell would inject the key into a plain http request to that host and port too.
    test "one on another machine is refused, over https as well" do
      for base <- ["http://192.168.1.4:8317", "https://Proxy.Example.com/team"] do
        assert {:error, message} = pick(plugin("codex", base))
        assert message =~ "on this machine only"
        assert message =~ URI.parse(base).scheme <> "://"
      end
    end

    test "one with a query, credentials or a fragment is refused" do
      for base <- ["http://127.0.0.1:8317?x=1", "http://user:pw@127.0.0.1:8317"] do
        assert {:error, message} = pick(plugin("claude", base))
        assert message =~ "credentials, a query or a fragment"
        refute message =~ "pw"
      end
    end

    test "one whose path climbs out of where it points is refused" do
      for base <- ["http://127.0.0.1:8317/../v0", "https://localhost/./x"] do
        assert {:error, message} = pick(plugin("claude", base))
        assert message =~ "a path a review sandbox does not take"
      end
    end

    test "one without its client key is refused" do
      assert {:error, message} = pick(plugin("codex", "http://127.0.0.1:8317", ""))
      assert message =~ "CLIPROXYAPI_API_KEY"
    end
  end

  describe "any other base URL" do
    test "is refused for Claude, saying which reviews in a sandbox" do
      other = %{
        env: %{"ANTHROPIC_BASE_URL" => "http://127.0.0.1:8317", "ANTHROPIC_AUTH_TOKEN" => "k"},
        args: [],
        plugin?: false
      }

      assert {:error, message} = Route.pick("claudeAgent", other, "ANTHROPIC_API_KEY")
      assert message =~ "does not reach"
      assert message =~ "CLIProxyAPI plugin"
    end

    test "is refused for Codex, by launch arguments or by its variable" do
      {"codex", %{args: args}} = plugin("codex", "http://127.0.0.1:8317")
      other = %{env: %{"CLIPROXYAPI_API_KEY" => "k"}, args: args, plugin?: false}
      assert {:error, message} = Route.pick("codex", other, "OPENAI_API_KEY")
      assert message =~ "does not reach"

      env = %{env: %{"OPENAI_BASE_URL" => "https://llm.example.com/v1"}, args: [], plugin?: false}
      assert {:error, _} = Route.pick("codex", env, "OPENAI_API_KEY")
    end

    test "Codex on another wire API is refused, as the sandbox lets the Responses API through only" do
      args = ["-c", "model_provider=p", "-c", "model_providers.p.base_url=http://127.0.0.1:1/v1"]

      instance = %{
        env: %{},
        args: args ++ ["-c", "model_providers.p.wire_api=chat"],
        plugin?: true
      }

      assert {:error, message} = Route.pick("codex", instance, "OPENAI_API_KEY")
      assert message =~ "Responses API"
    end
  end
end
