defmodule HalC2.AcpTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "Kimi's session model list preserves choices and the current model" do
    session = %{
      "models" => %{
        "currentModelId" => "kimi-code/k3,thinking",
        "availableModels" => [
          %{"modelId" => "kimi-code/k3", "name" => "K3"},
          %{"modelId" => "kimi-code/k3,thinking", "name" => "K3 (thinking)"}
        ]
      }
    }

    assert [
             %{"slug" => "kimi-code/k3", "name" => "K3", "isDefault" => false},
             %{"slug" => "kimi-code/k3,thinking", "name" => "K3 (thinking)", "isDefault" => true}
           ] = HalC2.Acp.session_models(session)
  end

  test "a model config option takes precedence over the older model list" do
    session = %{
      "configOptions" => [
        %{
          "id" => "model",
          "currentValue" => "new",
          "options" => [%{"value" => "new", "name" => "New"}]
        }
      ],
      "models" => %{
        "currentModelId" => "old",
        "availableModels" => [%{"modelId" => "old", "name" => "Old"}]
      }
    }

    assert [%{"slug" => "new", "isDefault" => true}] = HalC2.Acp.session_models(session)
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!(HalC2.Settings)
    # What a test makes it load or fail to load is kept in :persistent_term.
    HalC2.Acp.forget("antigravity")
    on_exit(fn -> HalC2.Acp.forget("antigravity") end)
    :ok
  end

  test "agent commands follow the runtime mode and the configured binary" do
    assert {:ok, ["opencode", "acp"], []} = HalC2.Acp.command("opencode", "full-access")

    # Grok is told HAL-C2 started it.
    referrer = [{"GROK_OAUTH2_REFERRER", "hal-c2"}]

    assert {:ok, ["grok", "agent", "--always-approve", "stdio"], ^referrer} =
             HalC2.Acp.command("grok", "full-access")

    assert {:ok, ["grok", "--permission-mode", "default", "agent", "stdio"], ^referrer} =
             HalC2.Acp.command("grok", "approval-required")

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "opencode" => %{
              "driver" => "opencode",
              "enabled" => true,
              "config" => %{"binaryPath" => "/opt/oc"}
            }
          }
        },
        0
      )

    assert {:ok, ["/opt/oc", "acp"], []} = HalC2.Acp.command("opencode")
    assert HalC2.Acp.enabled?("opencode")
    refute HalC2.Acp.enabled?("grok")
    assert {:error, _} = HalC2.Acp.command("nope")
  end

  test "Cursor runs the SDK sidecar with its sign-in under the HAL-C2 home", %{tmp_dir: dir} do
    assert {:ok, ["node", script, "--mode", "full-access"], env} =
             HalC2.Acp.command("cursor", "full-access")

    assert File.exists?(script)

    assert {"HAL_C2_CURSOR_CREDENTIALS", Path.join(dir, "provider-auth/cursor/cursor.json")} in env
  end

  test "an invalid legacy Cursor login is retried on the next start", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    legacy = Path.join([home, ".cursor", "sdk", "auth.json"])
    File.mkdir_p!(Path.dirname(legacy))

    previous = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
    end)

    target = HalC2.Acp.cursor_credentials("cursor")
    marker = Path.join(Path.dirname(target), "legacy-migrated")

    # Not a readable login: nothing is copied and nothing is remembered.
    File.write!(legacy, "not json")
    assert {:ok, _, _} = HalC2.Acp.command("cursor")
    refute File.exists?(target)
    refute File.exists?(marker)

    # A readable login at the next start is copied, and only then remembered;
    # the SDK's own file stays where it was.
    File.write!(legacy, JSON.encode!(%{"apiKey" => "cursor-key"}))
    assert {:ok, _, _} = HalC2.Acp.command("cursor")
    assert JSON.decode!(File.read!(target))["apiKey"] == "cursor-key"
    assert File.exists?(marker)
    assert File.exists?(legacy)
  end

  test "a Cursor skill mention reads the workspace snapshot, not a fresh scan",
       %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    File.mkdir_p!(home)
    previous = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
      :persistent_term.erase({HalC2.Acp, "cursor", :workspaces})
    end)

    work = Path.join(dir, "work")
    skill = Path.join([work, ".cursor", "skills", "deploy"])
    File.mkdir_p!(skill)
    File.write!(Path.join(skill, "SKILL.md"), "---\n---\nShip it.\n")

    # No snapshot yet: the mention resolves by scanning the workspace.
    assert HalC2.Acp.cursor_skill_mentions("run $deploy now", "cursor", work) ==
             "run /deploy now"

    # With a snapshot read, its names decide — the folder can even be gone.
    assert :ok = HalC2.Acp.CursorSkills.refresh_workspace("cursor", work)
    File.rm_rf!(Path.join(work, ".cursor"))

    assert HalC2.Acp.cursor_skill_mentions("run $deploy now", "cursor", work) ==
             "run /deploy now"
  end

  # Review of #1284: two refreshes of different folders each read the snapshots, added
  # theirs and wrote them back, so one overwrote the other's; and a scan that began
  # before the instance was dropped wrote its snapshot back after it.
  test "Cursor workspace refreshes keep each other's snapshots and not a dropped one's",
       %{tmp_dir: dir} do
    previous = System.get_env("HOME")
    System.put_env("HOME", Path.join(dir, "home"))

    on_exit(fn ->
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
      :persistent_term.erase({HalC2.Acp, "cursor", :workspaces})
    end)

    folders =
      for n <- 1..8 do
        work = Path.join(dir, "work#{n}")
        File.mkdir_p!(Path.join([work, ".cursor", "skills", "s#{n}"]))
        File.write!(Path.join([work, ".cursor", "skills", "s#{n}", "SKILL.md"]), "---\n---\nx\n")
        work
      end

    folders
    |> Task.async_stream(&HalC2.Acp.CursorSkills.refresh_workspace("cursor", &1),
      max_concurrency: 8
    )
    |> Enum.each(&assert {:ok, :ok} = &1)

    assert Enum.sort(Enum.map(HalC2.Acp.CursorSkills.workspaces("cursor"), & &1["cwd"])) ==
             Enum.sort(folders)

    epoch = HalC2.Acp.workspaces_epoch("cursor")
    HalC2.Acp.drop("cursor")
    assert HalC2.Acp.CursorSkills.workspaces("cursor") == []
    assert :dropped = HalC2.Acp.put_workspace("cursor", hd(folders), %{}, epoch)
    assert HalC2.Acp.CursorSkills.workspaces("cursor") == []
  end

  test "an enabled Pi whose binary is missing stays listed as unavailable" do
    {:ok, version} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "pi" => %{
              "driver" => "pi",
              "enabled" => true,
              "config" => %{"binaryPath" => "/nope/pi"}
            }
          }
        },
        0
      )

    assert HalC2.Acp.agent?("pi")

    # An enabled Pi stays listed so its health load can say it is missing
    # (pi.feature health states), as an enabled Muse does; a Pi nobody
    # enabled is not offered at all (pi.feature "only offered when installed").
    assert %{"installed" => false, "status" => "error", "availability" => "unavailable"} =
             HalC2.Acp.entry("pi")

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "pi" => %{
              "driver" => "pi",
              "enabled" => false,
              "config" => %{"binaryPath" => "/nope/pi"}
            }
          }
        },
        version
      )

    assert HalC2.Acp.entry("pi") == nil
  end

  test "a disabled agent says so instead of claiming to be ready", %{tmp_dir: dir} do
    grok = Path.join(dir, "grok")
    File.write!(grok, "#!/bin/sh\n")
    File.chmod!(grok, 0o755)

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "grok" => %{
              "driver" => "grok",
              "enabled" => false,
              "config" => %{"binaryPath" => grok}
            }
          }
        },
        0
      )

    assert %{"enabled" => false, "status" => "disabled", "message" => message} =
             HalC2.Acp.entry("grok")

    assert message == "Grok is disabled in HAL-C2 settings."
  end

  test "a disabled agent has no version, since it has never been launched", %{tmp_dir: dir} do
    grok = Path.join(dir, "grok")
    File.write!(grok, "#!/bin/sh\n")
    File.chmod!(grok, 0o755)

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "grok" => %{
              "driver" => "grok",
              "enabled" => false,
              "config" => %{"binaryPath" => grok}
            }
          }
        },
        0
      )

    assert %{"version" => nil} = HalC2.Acp.entry("grok")
  end

  test "a disabled Antigravity is installed only when its runtime is on this machine", %{
    tmp_dir: dir
  } do
    put = fn path ->
      {:ok, _} =
        HalC2.Settings.put(
          %{
            "providerInstances" => %{
              "antigravity" => %{
                "driver" => "antigravity",
                "enabled" => false,
                "config" => %{"binaryPath" => path}
              }
            }
          },
          0
        )
    end

    put.(Path.join(dir, "missing"))

    assert %{"status" => "disabled", "installed" => false, "version" => nil} =
             HalC2.Acp.entry("antigravity")
  end

  test "a disabled Antigravity with its runtime on this machine is installed but not launched", %{
    tmp_dir: dir
  } do
    {exe, harness} = HalC2.Acp.Antigravity.names()
    marker = Path.join(dir, "launched")

    # Either script, if run, leaves this behind: no marker is the behavioural
    # proof that nothing was launched, whatever the loader keeps.
    for name <- [exe, harness] do
      File.write!(Path.join(dir, name), "#!/bin/sh\ntouch '#{marker}'\n")
      File.chmod!(Path.join(dir, name), 0o755)
    end

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "antigravity" => %{
              "driver" => "antigravity",
              "enabled" => false,
              "config" => %{"binaryPath" => Path.join(dir, exe)}
            }
          }
        },
        0
      )

    assert %{"status" => "disabled", "installed" => true, "version" => nil} =
             HalC2.Acp.entry("antigravity")

    refute File.exists?(marker)

    # Belt and braces: launching starts a loader, which sets its flag before
    # anything else, and what it keeps (models or a failure) comes later.
    assert :persistent_term.get({HalC2.Acp, "antigravity", :loading}, false) == false
    assert :persistent_term.get({HalC2.Acp, "antigravity", :models}, nil) == nil
    assert :persistent_term.get({HalC2.Acp, "antigravity", :error}, nil) == nil
  end

  test "a successful generic probe clears a previous error and signed-out flag without a forget",
       %{tmp_dir: dir} do
    grok = Path.join(dir, "grok")

    File.write!(grok, """
    #!/usr/bin/env python3
    import sys
    if sys.argv[1:] == ["--version"]:
        print("grok 9.9.9")
        sys.exit(0)
    import json, sys
    def answer(request, result):
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    answer(json.loads(sys.stdin.readline()), {"protocolVersion": 1, "agentInfo": {"version": "9.9.9"}, "agentCapabilities": {}})
    model = {"id": "model", "currentValue": "fresh", "options": [{"value": "fresh", "name": "Fresh"}]}
    answer(json.loads(sys.stdin.readline()), {"sessionId": "s", "configOptions": [model]})
    sys.stdin.read()
    """)

    File.chmod!(grok, 0o755)

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "grok" => %{
              "driver" => "grok",
              "enabled" => true,
              "config" => %{"binaryPath" => grok}
            }
          }
        },
        0
      )

    on_exit(fn -> HalC2.Acp.forget("grok") end)
    :persistent_term.put({HalC2.Acp, "grok", :error}, "stale failure")
    :persistent_term.put({HalC2.Acp, "grok", :unauthenticated}, true)

    HalC2.Acp.load()

    assert :persistent_term.get({HalC2.Acp, "grok", :error}, nil) == nil
    assert :persistent_term.get({HalC2.Acp, "grok", :unauthenticated}, false) == false
    assert :persistent_term.get({HalC2.Acp, "grok", :models}, nil) != nil
  end

  test "a read that raises leaves the next listing to read again", %{tmp_dir: dir} do
    grok = Path.join(dir, "grok")
    raised = Path.join(dir, "raised")

    # The first launch answers `session/new` with what no read can take.
    File.write!(grok, """
    #!/usr/bin/env python3
    import sys
    if sys.argv[1:] == ["--version"]:
        print("grok 9.9.9")
        sys.exit(0)
    import json, os, sys
    def answer(request, result):
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    answer(json.loads(sys.stdin.readline()), {"protocolVersion": 1, "agentInfo": {"version": "9.9.9"}, "agentCapabilities": {}})
    model = {"id": "model", "currentValue": "fresh", "options": [{"value": "fresh", "name": "Fresh"}]}
    first = not os.path.exists(#{inspect(raised)})
    open(#{inspect(raised)}, "w").close()
    answer(json.loads(sys.stdin.readline()), 42 if first else {"sessionId": "s", "configOptions": [model]})
    sys.stdin.read()
    """)

    File.chmod!(grok, 0o755)

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "grok" => %{
              "driver" => "grok",
              "enabled" => true,
              "config" => %{"binaryPath" => grok}
            }
          }
        },
        0
      )

    on_exit(fn -> HalC2.Acp.forget("grok") end)
    :ok = HalC2.Settings.watch(self())

    assert %{"models" => []} = HalC2.Acp.entry("grok")
    assert_receive {:hal_c2_providers_changed, _}, 5_000
    assert :persistent_term.get({HalC2.Acp, "grok", :loading}, false) == false
    assert :persistent_term.get({HalC2.Acp, "grok", :error}, nil) == nil

    assert %{"models" => []} = HalC2.Acp.entry("grok")
    assert_receive {:hal_c2_providers_changed, _}, 5_000
    assert %{"models" => [%{"slug" => "fresh"}]} = HalC2.Acp.entry("grok")
  end

  # One macOS refuses (quarantine) dies before it answers: its connection may stop
  # before `initialize` is sent, while it is written, or while it waits. Each of
  # those is a closed connection, never an exit that leaves the read unpublished.
  test "an agent that dies at once fails as closed", %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :acp_commands, %{"dying" => ["sh", "-c", "exit 137"]})
    on_exit(fn -> Application.delete_env(:hal_c2, :acp_commands) end)

    assert HalC2.Acp.with_agent("dying", dir, fn _conn, _init -> :answered end) ==
             {:error, :closed}
  end

  test "a read that was forgotten while it ran leaves no failure behind", %{tmp_dir: dir} do
    # The agent refuses `initialize` once the instance is forgotten.
    forgotten_mid_read(dir, """
    error = {"code": -32603, "message": "refused"}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": error}), flush=True)
    """)

    assert :persistent_term.get({HalC2.Acp, "grok", :error}, nil) == nil
  end

  test "a read that was forgotten while it ran leaves nothing it read behind", %{tmp_dir: dir} do
    # The agent answers: what it says after the instance is forgotten (its version,
    # capabilities and models) must not stand as the new state.
    forgotten_mid_read(dir, """
    def answer(request, result):
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    answer(request, {"protocolVersion": 1, "agentInfo": {"version": "9.9.9"}, "agentCapabilities": {}})
    model = {"id": "model", "currentValue": "stale", "options": [{"value": "stale", "name": "Stale"}]}
    answer(json.loads(sys.stdin.readline()), {"sessionId": "s", "configOptions": [model]})
    """)

    for key <- [:version, :capabilities, :models, :config, :error],
        do: assert(:persistent_term.get({HalC2.Acp, "grok", key}, nil) == nil, inspect(key))
  end

  test "of two concurrent reads only the most recently started publishes", %{tmp_dir: dir} do
    started = Path.join(dir, "started")
    release = Path.join(dir, "release")
    second = Path.join(dir, "second")
    {_, 0} = System.cmd("mkfifo", [started, release])
    grok = Path.join(dir, "grok")

    # The first probe holds its `initialize` until released and then answers
    # "stale"; a later probe answers "fresh" at once. Finishing last must not
    # let the first read overwrite the second.
    File.write!(grok, """
    #!/usr/bin/env python3
    import sys
    if sys.argv[1:] == ["--version"]:
        print("grok 9.9.9")
        sys.exit(0)
    import json, os, sys
    request = json.loads(sys.stdin.readline())
    def answer(request, result):
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    def serve(name):
        answer(request, {"protocolVersion": 1, "agentInfo": {"version": "9.9.9"}, "agentCapabilities": {}})
        model = {"id": "model", "currentValue": name, "options": [{"value": name, "name": name}]}
        answer(json.loads(sys.stdin.readline()), {"sessionId": "s", "configOptions": [model]})
    if os.path.exists("#{second}"):
        serve("fresh")
    else:
        open("#{second}", "w").close()
        open("#{started}", "w").write(os.getcwd() + "\\n")
        open("#{release}").read()
        serve("stale")
    sys.stdin.read()
    """)

    File.chmod!(grok, 0o755)

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "grok" => %{
              "driver" => "grok",
              "enabled" => true,
              "config" => %{"binaryPath" => grok}
            }
          }
        },
        0
      )

    on_exit(fn -> HalC2.Acp.forget("grok") end)
    :ok = HalC2.Settings.watch(self())

    HalC2.Acp.entry("grok")
    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary, args: [started]])
    assert_receive {^port, {:data, probe}}, 10_000

    # The boot-style read runs while the first is still held, and publishes.
    HalC2.Acp.load()
    assert inspect(:persistent_term.get({HalC2.Acp, "grok", :models}, nil)) =~ "fresh"

    File.write!(release, "go\n")
    read_done(String.trim(probe))

    models = inspect(:persistent_term.get({HalC2.Acp, "grok", :models}, nil))
    assert models =~ "fresh"
    refute models =~ "stale"
  end

  test "a reload publishes what it read when a listing asks for the agent meanwhile",
       %{tmp_dir: dir} do
    started = Path.join(dir, "started")
    release = Path.join(dir, "release")
    probes = Path.join(dir, "probes")
    {_, 0} = System.cmd("mkfifo", [started, release])
    grok = Path.join(dir, "grok")

    # The reload's probe holds its `initialize` until released. Any other probe
    # never answers, so a read started beside the reload cannot stand in for it.
    File.write!(grok, """
    #!/usr/bin/env python3
    import sys
    if sys.argv[1:] == ["--version"]:
        print("grok 9.9.9")
        sys.exit(0)
    import json, os, sys
    request = json.loads(sys.stdin.readline())
    first = not os.path.exists("#{probes}")
    open("#{probes}", "a").write("probe\\n")
    if first:
        open("#{started}", "w").write("held\\n")
        open("#{release}").read()
        def answer(request, result):
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        answer(request, {"protocolVersion": 1, "agentInfo": {"version": "9.9.9"}, "agentCapabilities": {}})
        model = {"id": "model", "currentValue": "reloaded", "options": [{"value": "reloaded", "name": "Reloaded"}]}
        answer(json.loads(sys.stdin.readline()), {"sessionId": "s", "configOptions": [model]})
    sys.stdin.read()
    """)

    File.chmod!(grok, 0o755)

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "grok" => %{
              "driver" => "grok",
              "enabled" => true,
              "config" => %{"binaryPath" => grok}
            }
          }
        },
        0
      )

    on_exit(fn -> HalC2.Acp.forget("grok") end)

    reload = Task.async(fn -> HalC2.Acp.reload("grok") end)
    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary, args: [started]])
    assert_receive {^port, {:data, "held\n"}}, 10_000

    # A client lists the providers while the reload's agent is still answering.
    assert %{"models" => []} = HalC2.Acp.entry("grok")

    File.write!(release, "go\n")
    assert :ok = Task.await(reload, 10_000)

    assert inspect(:persistent_term.get({HalC2.Acp, "grok", :models}, nil)) =~ "reloaded"
    assert File.read!(probes) == "probe\n"
  end

  # Reads the grok instance from a fake agent that, holding the read's `initialize`
  # (`request`), waits until the test has forgotten the instance and then runs `script`
  # (Python). Returns once that read has published what it would and finished. The agent
  # tells the test it holds the read, and where its probe runs, through a FIFO.
  defp forgotten_mid_read(dir, script) do
    started = Path.join(dir, "started")
    release = Path.join(dir, "release")
    {_, 0} = System.cmd("mkfifo", [started, release])
    grok = Path.join(dir, "grok")

    File.write!(grok, """
    #!/usr/bin/env python3
    import sys
    if sys.argv[1:] == ["--version"]:
        print("grok 9.9.9")
        sys.exit(0)
    import json, os, sys
    request = json.loads(sys.stdin.readline())
    open("#{started}", "w").write(os.getcwd() + "\\n")
    open("#{release}").read()
    #{script}
    sys.stdin.read()
    """)

    File.chmod!(grok, 0o755)

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "grok" => %{
              "driver" => "grok",
              "enabled" => true,
              "config" => %{"binaryPath" => grok}
            }
          }
        },
        0
      )

    on_exit(fn -> HalC2.Acp.forget("grok") end)
    :ok = HalC2.Settings.watch(self())

    # The first listing starts the read; the instance is forgotten while the agent holds
    # it, as a scenario's teardown or a reload does.
    HalC2.Acp.entry("grok")
    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary, args: [started]])
    assert_receive {^port, {:data, probe}}, 10_000
    HalC2.Acp.forget("grok")
    File.write!(release, "go\n")
    read_done(String.trim(probe))
  end

  # Found by HalC2.AcpLegacyModesPropTest (merge queue run 43116789842): a probe that
  # published after a running session had set its mode showed the agent's default mode.
  test "a probe or reload keeps the mode a running session set while the agent offers it",
       %{tmp_dir: dir} do
    id = "acpRegistry_modes"
    fake = Path.expand("../support/fake_acme_agent.py", __DIR__)

    File.write!(
      Path.join(dir, "control.json"),
      JSON.encode!(%{"acme" => %{"legacyModes" => ["ask", "code", "debug"]}})
    )

    Application.put_env(:hal_c2, :acp_commands, %{
      id => ["python3", "-u", fake, "--control", dir, "--name", "acme"]
    })

    :persistent_term.put(
      {HalC2.Acp.Catalog, :index},
      {System.system_time(:millisecond),
       [
         %{
           "id" => "modes-agent",
           "name" => "Modes agent",
           "version" => "1.0.0",
           "distribution" => %{
             "binary" => %{HalC2.Acp.Catalog.platform() => %{"archive" => "", "cmd" => "./acme"}}
           }
         }
       ]}
    )

    on_exit(fn ->
      HalC2.Acp.drop(id)
      Application.delete_env(:hal_c2, :acp_commands)
      :persistent_term.erase({HalC2.Acp.Catalog, :index})
    end)

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            id => %{
              "driver" => "acpRegistry",
              "enabled" => true,
              "config" => %{"agentId" => "modes-agent"}
            }
          }
        },
        0
      )

    mode = fn ->
      {HalC2.Acp, id, :config}
      |> :persistent_term.get([])
      |> Enum.find_value(&(&1["id"] == "mode" && &1["currentValue"]))
    end

    HalC2.Acp.load()
    assert mode.() == "ask"

    # The thread's session switched to "code" (`session/set_mode`); a later probe's
    # fresh session starts in "ask" again.
    HalC2.Acp.put_option(id, "mode", "code")
    HalC2.Acp.load()
    assert mode.() == "code"

    # A reload (a settings change, a sign-in) forgets what was read and probes again;
    # the session is still in "code".
    HalC2.Acp.forget(id)
    assert mode.() == nil
    HalC2.Acp.load()
    assert mode.() == "code"

    # A removed instance keeps nothing; read again, it shows the agent's default.
    HalC2.Acp.drop(id)
    HalC2.Acp.load()
    assert mode.() == "ask"

    # A mode the agent no longer offers gives way to the probe's.
    HalC2.Acp.put_option(id, "mode", "gone")
    HalC2.Acp.load()
    assert mode.() == "ask"

    # A default only a probe set is the agent's to change: the next probe's stands.
    HalC2.Acp.drop(id)
    HalC2.Acp.load()
    assert mode.() == "ask"

    File.write!(
      Path.join(dir, "control.json"),
      JSON.encode!(%{"acme" => %{"legacyModes" => ["debug", "ask", "code"]}})
    )

    HalC2.Acp.load()
    assert mode.() == "debug"
  end

  test "forgetting an instance leaves no generation entry behind" do
    :persistent_term.put({HalC2.Acp, "gone", :generation}, make_ref())
    :persistent_term.put({HalC2.Acp, "gone", :models}, [])

    HalC2.Acp.forget("gone")

    assert :persistent_term.get({HalC2.Acp, "gone", :generation}, :none) == :none
    assert :persistent_term.get({HalC2.Acp, "gone", :models}, :none) == :none
  end

  test "an instance's commands and skills are its own and are forgotten with it" do
    HalC2.Acp.put_commands("opencode", [
      %{"name" => "review", "description" => "Review"},
      %{"name" => "$deploy", "description" => "Deploy"}
    ])

    on_exit(fn -> HalC2.Acp.forget("opencode") end)

    assert :persistent_term.get({HalC2.Acp, "opencode", :commands}) ==
             [%{"name" => "review", "description" => "Review"}]

    assert [%{"name" => "deploy"}] = :persistent_term.get({HalC2.Acp, "opencode", :skills})
    assert :persistent_term.get({HalC2.Acp, "grok", :commands}, :none) == :none

    HalC2.Acp.forget("opencode")

    assert :persistent_term.get({HalC2.Acp, "opencode", :commands}, :none) == :none
    assert :persistent_term.get({HalC2.Acp, "opencode", :skills}, :none) == :none
  end

  # Other services broadcast `providers_changed` too. The read's own broadcast follows
  # the removal of its probe directory, which follows its publication, so the first
  # broadcast seen once that directory is gone means the read is done.
  defp read_done(probe) do
    assert_receive {:hal_c2_providers_changed, _}, 10_000
    if File.exists?(probe), do: read_done(probe)
  end
end
