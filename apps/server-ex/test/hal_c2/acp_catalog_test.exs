defmodule HalC2.Acp.CatalogTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @fake_acp Path.expand("../support/fake_acp.py", __DIR__)

  defmodule Files do
    @moduledoc false
    @behaviour Plug

    def init(dir), do: dir

    def call(%{request_path: "/" <> name} = conn, dir) do
      case File.read(Path.join(dir, name)) do
        {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
        _ -> Plug.Conn.send_resp(conn, 404, "")
      end
    end
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, Path.join(dir, "home"))
    :persistent_term.erase({HalC2.Acp.Catalog, :index})
    :persistent_term.erase({HalC2.Acp.Catalog, :fetch_failed_at})
    start_supervised!(HalC2.Settings)

    served = Path.join(dir, "served")
    File.mkdir_p!(served)
    server = start_supervised!({Bandit, plug: {Files, served}, port: 0, ip: :loopback})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"
    Application.put_env(:hal_c2, :acp_registry_url, "#{base}/registry.json")

    on_exit(fn ->
      Application.delete_env(:hal_c2, :acp_registry_url)
      :persistent_term.erase({HalC2.Acp.Catalog, :index})
      :persistent_term.erase({HalC2.Acp.Catalog, :fetch_failed_at})
    end)

    # An agent archive holding bin/fake, a script that runs the fake ACP agent.
    script = Path.join(dir, "fake")
    File.write!(script, "#!/bin/sh\nexec python3 -u #{@fake_acp} \"$@\"\n")
    File.chmod!(script, 0o755)
    archive = Path.join(served, "fake.tar.gz")

    :ok =
      :erl_tar.create(to_charlist(archive), [{~c"bin/fake", to_charlist(script)}], [:compressed])

    sha = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    %{served: served, base: base, sha: sha}
  end

  defp publish(served, agents),
    do:
      File.write!(
        Path.join(served, "registry.json"),
        JSON.encode!(%{"version" => "1.0.0", "agents" => agents})
      )

  defp fake(base, sha, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "fake-agent",
        "name" => "Fake Agent",
        "version" => "1.2.3",
        "description" => "A test agent",
        "authors" => ["Tests"],
        "distribution" => %{
          "binary" => %{
            HalC2.Acp.Catalog.platform() => %{
              "archive" => "#{base}/fake.tar.gz",
              "cmd" => "./bin/fake",
              "args" => ["--acp"],
              "env" => %{"FAKE_MODE" => "1"},
              "sha256" => sha
            }
          }
        }
      },
      extra
    )
  end

  test "search ranks agents and describes their distribution", %{
    served: served,
    base: base,
    sha: sha
  } do
    publish(served, [
      fake(base, sha),
      %{
        "id" => "other",
        "name" => "Other",
        "version" => "1.0.0",
        "description" => "mentions fake in passing",
        "distribution" => %{"npx" => %{"package" => "other@1.0.0"}}
      },
      # Unsafe entries are dropped.
      fake(base, sha, %{"id" => "../escape"})
    ])

    assert {:ok, %{"agents" => [first, second]}} = HalC2.Acp.Catalog.search(%{"query" => "fake"})
    assert %{"id" => "fake-agent", "distribution" => "binary", "integrity" => "sha256"} = first
    assert %{"id" => "other", "distribution" => "npx", "integrity" => "registry"} = second
  end

  test "an agent installs, runs from its instance, and uninstalls when unused",
       %{served: served, base: base, sha: sha} do
    publish(served, [fake(base, sha)])

    assert {:ok, %{"agentId" => "fake-agent", "version" => "1.2.3", "distribution" => "binary"}} =
             HalC2.Acp.Catalog.prepare(%{"agentId" => "fake-agent"})

    instance = %{
      "driver" => "acpRegistry",
      "displayName" => "My Fake",
      "environment" => [%{"name" => "FAKE_KEY", "value" => "secret"}],
      "config" => %{"agentId" => "fake-agent"}
    }

    {:ok, 1} = HalC2.Settings.put(%{"providerInstances" => %{"acpRegistry_fake" => instance}}, 0)

    assert HalC2.Acp.agent?("acpRegistry_fake")
    assert {:ok, [exe, "--acp"], env} = HalC2.Acp.command("acpRegistry_fake")
    assert exe =~ ~r{/tools/fake-agent/1\.2\.3/[^/]+/bin/fake$}
    assert {"FAKE_MODE", "1"} in env and {"FAKE_KEY", "secret"} in env

    # The provider entry reads the agent's models from a throwaway session.
    :ok = HalC2.Settings.watch(self())

    assert %{"driver" => "acpRegistry", "displayName" => "My Fake", "enabled" => true} =
             HalC2.Acp.entry("acpRegistry_fake")

    assert_receive {:hal_c2_providers_changed, _}, 5_000

    assert %{"version" => "9.9", "models" => [%{"slug" => "fake/one"}, _]} =
             HalC2.Acp.entry("acpRegistry_fake")

    assert {:ok, %{"removed" => false}} =
             HalC2.Acp.Catalog.uninstall(%{"agentId" => "fake-agent"})

    {:ok, 2} = HalC2.Settings.put(%{"providerInstances" => %{}}, 1)
    assert {:ok, %{"removed" => true}} = HalC2.Acp.Catalog.uninstall(%{"agentId" => "fake-agent"})
    refute File.exists?(Path.dirname(Path.dirname(Path.dirname(exe))))
  end

  test "an archive that does not match its checksum is not installed",
       %{served: served, base: base} do
    publish(served, [fake(base, String.duplicate("0", 64))])

    assert {:error, %{"_tag" => "AcpRegistryOperationError", "reason" => "checksum_mismatch"}} =
             HalC2.Acp.Catalog.prepare(%{"agentId" => "fake-agent"})

    home = Application.fetch_env!(:hal_c2, :home)
    assert Path.wildcard(Path.join(home, "tools/fake-agent/**/bin/fake")) == []
  end

  test "the cached index serves when the registry is unreachable",
       %{served: served, base: base, sha: sha} do
    publish(served, [fake(base, sha)])
    assert {:ok, %{"agents" => [_]}} = HalC2.Acp.Catalog.search(%{"query" => ""})

    File.rm!(Path.join(served, "registry.json"))
    :persistent_term.erase({HalC2.Acp.Catalog, :index})

    assert {:ok, %{"agents" => [%{"id" => "fake-agent"}]}} =
             HalC2.Acp.Catalog.search(%{"query" => ""})
  end

  test "a command replaced by a relative link inside its folder still runs, a chained link out does not",
       %{served: served, base: base, sha: sha, tmp_dir: dir} do
    publish(served, [fake(base, sha)])
    assert {:ok, _} = HalC2.Acp.Catalog.prepare(%{"agentId" => "fake-agent"})
    assert {:ok, [exe | _], _env} = HalC2.Acp.Catalog.command(%{"agentId" => "fake-agent"})
    root = exe |> Path.dirname() |> Path.dirname()

    # bin/fake -> ../lib/real, the layout real archives use.
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join([root, "lib", "real"]), "#!/bin/sh\nexit 0\n")
    File.rm!(exe)
    File.ln_s!("../lib/real", exe)
    assert {:ok, [^exe | _], _env} = HalC2.Acp.Catalog.command(%{"agentId" => "fake-agent"})

    # bin/fake -> ../lib/out -> a file outside the install folder.
    outside = Path.join(dir, "outside")
    File.write!(outside, "#!/bin/sh\nexit 0\n")
    File.ln_s!(outside, Path.join([root, "lib", "out"]))
    File.rm!(exe)
    File.ln_s!("../lib/out", exe)

    assert {:error, %{"reason" => "archive_invalid", "message" => message}} =
             HalC2.Acp.Catalog.command(%{"agentId" => "fake-agent"})

    assert message =~ "resolves outside its installation directory"
  end

  test "a package spec that only ends in a version is not pinned", %{
    served: served,
    base: base,
    sha: sha
  } do
    npx_agent = fn id, package ->
      fake(base, sha, %{
        "id" => id,
        "name" => id,
        "distribution" => %{"npx" => %{"package" => package}}
      })
    end

    publish(served, [
      npx_agent.("url-pkg", "pkg@https://evil.example/pkg-1.2.3"),
      npx_agent.("alias-pkg", "pkg@npm:other@1.2.3"),
      npx_agent.("git-pkg", "pkg@git+https://host.example/x#1.2.3"),
      npx_agent.("good-pkg", "good@1.2.3")
    ])

    assert {:ok, %{"agents" => agents}} = HalC2.Acp.Catalog.search(%{"query" => ""})
    assert Enum.map(agents, & &1["id"]) == ["good-pkg"]
  end

  test "the agent's PATH has no trailing empty entry when nothing sets one", %{
    served: served,
    base: base,
    sha: sha
  } do
    publish(served, [fake(base, sha)])
    assert {:ok, _} = HalC2.Acp.Catalog.prepare(%{"agentId" => "fake-agent"})

    path = System.get_env("PATH")
    on_exit(fn -> if path, do: System.put_env("PATH", path), else: System.delete_env("PATH") end)
    System.delete_env("PATH")

    assert {:ok, [exe | _], env} = HalC2.Acp.Catalog.command(%{"agentId" => "fake-agent"})
    assert {"PATH", Path.dirname(exe)} in env
  end

  test "after a failed fetch a search serves the cached copy without fetching again at once",
       %{served: served, base: base, sha: sha} do
    publish(served, [fake(base, sha)])

    assert {:ok, %{"agents" => [%{"id" => "fake-agent"}]}} =
             HalC2.Acp.Catalog.search(%{"query" => ""})

    {_, agents, _} = :persistent_term.get({HalC2.Acp.Catalog, :index})
    aged = System.system_time(:millisecond) - 10 * 60_000
    :persistent_term.put({HalC2.Acp.Catalog, :index}, {aged, agents, true})

    File.rm!(Path.join(served, "registry.json"))

    assert {:ok, %{"agents" => [%{"id" => "fake-agent"}]}} =
             HalC2.Acp.Catalog.search(%{"query" => ""})

    # The registry is back with other agents, but the failed fetch is still
    # recent: this search must not fetch again.
    publish(served, [fake(base, sha, %{"id" => "second", "name" => "Second"})])

    assert {:ok, %{"agents" => [%{"id" => "fake-agent"}]}} =
             HalC2.Acp.Catalog.search(%{"query" => ""})

    # A forced read still fetches.
    assert {:ok, [%{"id" => "second"}]} = HalC2.Acp.Catalog.index(true)
  end

  test "installing a package agent leaves the caller's exit trapping and mailbox alone",
       %{served: served, base: base, sha: sha, tmp_dir: dir} do
    bin = Path.join(dir, "fake-bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "npm"), """
    #!/bin/sh
    mkdir -p "$npm_config_prefix/lib/node_modules/agent" "$npm_config_prefix/bin"
    printf '{"name":"agent","version":"2.0.0","bin":{"agent":"index.js"}}' > "$npm_config_prefix/lib/node_modules/agent/package.json"
    printf '#!/bin/sh\\nexit 0\\n' > "$npm_config_prefix/bin/agent"
    chmod +x "$npm_config_prefix/bin/agent"
    """)

    File.chmod!(Path.join(bin, "npm"), 0o755)
    path = System.get_env("PATH")
    on_exit(fn -> if path, do: System.put_env("PATH", path), else: System.delete_env("PATH") end)
    System.put_env("PATH", bin <> ":" <> (path || ""))

    publish(served, [
      fake(base, sha, %{
        "id" => "np-agent",
        "name" => "Np Agent",
        "distribution" => %{"npx" => %{"package" => "agent@2.0.0"}}
      })
    ])

    Process.flag(:trap_exit, false)
    assert {:ok, %{"prepared" => true}} = HalC2.Acp.Catalog.prepare(%{"agentId" => "np-agent"})
    assert Process.info(self(), :trap_exit) == {:trap_exit, false}
    refute_receive {:EXIT, _, _}, 100
  end

  # An MC that loads new code keeps the index it read before: the new code's entries
  # still apply to it.
  test "an index read before an upgrade runs Kimi Code", %{base: base, sha: sha} do
    kimi_cli =
      fake(base, sha, %{
        "id" => "kimi",
        "name" => "Kimi CLI",
        "repository" => "https://github.com/MoonshotAI/kimi-cli"
      })

    now = System.system_time(:millisecond)
    :persistent_term.put({HalC2.Acp.Catalog, :index}, {now, [kimi_cli]})

    assert %{name: "Kimi Code", version: "2.3.1"} = HalC2.Acp.Catalog.describe("kimi")
  end
end
