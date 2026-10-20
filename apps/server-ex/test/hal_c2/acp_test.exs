defmodule HalC2.AcpTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

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

    assert {:ok, ["grok", "agent", "--always-approve", "stdio"], []} =
             HalC2.Acp.command("grok", "full-access")

    assert {:ok, ["grok", "--permission-mode", "default", "agent", "stdio"], []} =
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

  test "Pi is offered only where its binary is installed" do
    {:ok, _} =
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

  # Other services broadcast `providers_changed` too. The read's own broadcast follows
  # the removal of its probe directory, which follows its publication, so the first
  # broadcast seen once that directory is gone means the read is done.
  defp read_done(probe) do
    assert_receive {:hal_c2_providers_changed, _}, 10_000
    if File.exists?(probe), do: read_done(probe)
  end
end
