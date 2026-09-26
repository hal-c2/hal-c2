defmodule T3.Steps.Providers.Pi do
  @moduledoc """
  Steps for `features/providers/pi.feature`. Pi runs through the ACP Registry's
  pi-acp adapter, which runs the user's own `pi`; the scripted fake
  (`T3.Test.FakeAcp`) plays the adapter, and a dummy executable is the user's Pi.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias T3.Test.FakeAcp
  alias T3.Test.Node.World

  # A stand-in for the user's Pi installation: the adapter is told where it is.
  defp pi_binary(context, version \\ "0.80.5") do
    bin = Path.join([T3.Test.Node.tmp_dir(context.node, "pi-install"), "bin", "pi"])
    File.mkdir_p!(Path.dirname(bin))
    File.write!(bin, "#!/bin/sh\necho #{version}\n")
    File.chmod!(bin, 0o755)
    bin
  end

  # The fake adapter is in place before the instance is turned on, so the node never
  # looks for the registry's pi-acp.
  defp adapter(context, enabled, pi, config \\ %{}) do
    context =
      context
      |> FakeAcp.install("pi", config, binary: "pi-acp")
      |> FakeAcp.pi_adapter(pi)
      |> Map.put(:pi_binary, pi)

    if enabled, do: FakeAcp.settings(&put_in(&1, ["providers", "pi", "enabled"], true))
    context
  end

  defp enabled(context, config \\ %{}), do: adapter(context, true, pi_binary(context), config)

  defp pi(context), do: FakeAcp.find(context.providers, "pi")

  # Where the thread's adapter ran: the fake's starts in the project.
  defp thread_starts(context) do
    root = World.project(context).root
    Enum.filter(FakeAcp.starts(context), &(&1["cwd"] == root))
  end

  step "Pi is installed but not enabled", context do
    adapter(context, false, pi_binary(context))
  end

  step "no Pi process is started", context do
    T3.Acp.load()
    assert %{"enabled" => false} = FakeAcp.entry("pi")
    assert FakeAcp.starts(context, "pi") == []
    context
  end

  step "the pi command is not installed on the node", context do
    FakeAcp.services()
    T3.Acp.forget("pi")
    missing = Path.join(T3.Test.Node.tmp_dir(context.node, "no-pi"), "pi")
    FakeAcp.settings(&put_in(&1, ["providers"], %{"pi" => %{"binaryPath" => missing}}))
    Map.put(context, :provider, "pi")
  end

  step "Pi is not offered", context do
    assert context.providers != nil
    assert FakeAcp.find(context.providers, "pi") == nil
    context
  end

  step "Pi is installed and enabled", context do
    context = adapter(context, true, pi_binary(context))
    assert %{"enabled" => true} = FakeAcp.entry("pi")
    context
  end

  step "Pi's binary path is set to {string}", %{args: [path]} = context do
    adapter(context, true, path)
  end

  step "the user sends a message to Pi", context do
    context = context |> FakeAcp.thread() |> FakeAcp.send_message("hello Pi")
    FakeAcp.await_run(context, "completed")
    context
  end

  step "the turn runs on the user's own Pi installation", context do
    assert_runs_on(context, context.pi_binary)
  end

  step "that Pi binary runs the turn", context do
    assert_runs_on(context, "/opt/pi/bin/pi")
  end

  defp assert_runs_on(context, pi) do
    # The adapter (the fake, behind its `pi-acp` wrapper) ran the thread in the
    # project, told to run this Pi.
    root = T3.Test.Node.World.project(context).root
    assert [%{"env" => env}] = Enum.filter(FakeAcp.starts(context), &(&1["cwd"] == root))
    assert env["PI_ACP_PI_COMMAND"] == pi
    assert [%{"params" => %{"prompt" => prompt}}] = FakeAcp.received(context, "session/prompt")
    assert Enum.any?(prompt, &(&1["text"] =~ "hello Pi"))
    context
  end

  # --- status ---

  step "the installed Pi is 0.79.0", context do
    adapter(context, true, pi_binary(context, "0.79.0"))
  end

  step "Pi is shown as unsupported with a hint to update to 0.80.5 or newer", context do
    assert %{"status" => "error", "message" => message} = pi(context)
    assert message == "Pi 0.79.0 is unsupported. Update to Pi 0.80.5 or newer."
    context
  end

  step "Pi reports no models", context do
    enabled(context, %{"configOptions" => []})
  end

  step "Pi says to sign in with Pi in a terminal or configure an API key", context do
    assert %{"status" => "warning", "message" => message} = pi(context)
    assert message =~ "Run `pi` in a terminal and use /login, or configure an API key"
    assert pi(context)["auth"]["status"] == "unauthenticated"
    context
  end

  # Pi waits for input at startup, so the adapter cannot open a session to read
  # models and commands from.
  step "Pi discovery needs interactive input", context do
    enabled(context, %{
      "sessionError" => %{"code" => -32603, "message" => "Pi is waiting for input"}
    })
  end

  step "Pi stays available with the {string} model", %{args: [name]} = context do
    entry = pi(context)
    assert entry["status"] != "error"
    assert [%{"slug" => "default", "name" => ^name}] = entry["models"]
    assert entry["message"] =~ "The live session will retry startup."
    context
  end

  # The thread runs on Pi's own default model; the node never picks one for it.
  step "the first thread lets Pi handle its startup prompt", context do
    context =
      FakeAcp.configure(context, &Map.delete(&1, "sessionError"))
      |> FakeAcp.thread("Work", "full-access", %{
        "modelSelection" => %{"instanceId" => "pi", "model" => "default"}
      })
      |> FakeAcp.send_message("hello Pi")

    FakeAcp.await_run(context, "completed")
    assert [_] = thread_starts(context)
    assert FakeAcp.received(context, "session/set_config_option") == []
    assert FakeAcp.received(context, "session/set_model") == []
    context
  end

  # --- access modes ---

  step ~r/^the thread runs Pi in (?<mode>approval required|auto-accept edits|full access)$/,
       %{args: [mode]} = context do
    context |> enabled() |> FakeAcp.thread("Work", String.replace(mode, " ", "-"))
  end

  step ~r/^Pi wants to (?<action>read a file|edit a file|run a command)$/,
       %{args: [action]} = context do
    FakeAcp.send_message(context, "please #{action}")
  end

  step "the user opens the access picker in a Pi thread", context do
    context = context |> enabled() |> FakeAcp.thread("Work", "approval-required")
    {_, context} = FakeAcp.open_config(context)
    context
  end

  step "a Pi thread saved with auto mode", context do
    context |> enabled() |> FakeAcp.thread("Work", "auto")
  end

  step "it shows and behaves as approval required", context do
    # Pi offers approval required first and no auto, so the thread shows that...
    assert ["approval-required" | modes] = pi(context)["supportedRuntimeModes"]
    refute "auto" in modes

    # ...and an edit waits for the user.
    context = FakeAcp.send_message(context, "please edit a file")
    assert %{"status" => "pending", "kind" => "file-change"} = FakeAcp.await_request(context)
    context
  end

  step "a Pi thread with history", context do
    context =
      context
      |> enabled()
      |> FakeAcp.thread("Work", "approval-required")
      |> FakeAcp.send_message("hello Pi")

    FakeAcp.await_run(context, "completed")
    [%{"params" => %{"sessionId" => session}}] = FakeAcp.received(context, "session/prompt")
    Map.put(context, :pi_session, session)
  end

  # The next turn starts a new adapter in the new mode, which resumes the session.
  step "Pi restarts and continues the same native conversation", context do
    context = FakeAcp.send_message(context, "hello again")
    FakeAcp.await_runs(context, 2)

    assert [_, _] = thread_starts(context)

    assert [%{"params" => %{"sessionId" => session}}] =
             FakeAcp.received(context, "session/resume")

    assert session == context.pi_session

    assert [_, %{"params" => %{"sessionId" => ^session}}] =
             FakeAcp.received(context, "session/prompt")

    context
  end

  step "Pi asked to run the same command twice", context do
    context =
      context
      |> enabled()
      |> FakeAcp.thread("Work", "approval-required")
      |> FakeAcp.send_message("please run it twice")

    Map.put(context, :request, FakeAcp.await_request(context))
  end

  step "the user allows it for the session the first time", context do
    FakeAcp.respond(context, context.request["id"], %{"decision" => "acceptForSession"})
  end

  step "the second request is allowed without asking", context do
    state = FakeAcp.await_run(context, "completed")
    assert [%{"status" => "resolved"}] = T3.StreamState.list(state, "runtime-request")

    assert [
             %{"result" => %{"outcome" => %{"optionId" => "always"}}},
             %{"result" => %{"outcome" => %{"outcome" => "selected"}}}
           ] = FakeAcp.answers(context)

    context
  end

  # --- process exit ---

  step "a Pi turn is running", context do
    context =
      context
      |> enabled()
      |> FakeAcp.thread()
      |> FakeAcp.send_message("please do a long task")

    FakeAcp.await_run(context, "running")

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(T3.StreamState.list(state, "turn-item"), &(&1["type"] == "assistant_message"))
    end)

    context
  end

  # The adapter's own pid, from the fake's start log (never found by name).
  step "the Pi process exits unexpectedly", context do
    assert [%{"pid" => pid}] = thread_starts(context)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(pid)])
    context
  end

  step "the turn fails saying Pi exited unexpectedly", context do
    state = FakeAcp.await_run(context, "failed")

    assert Enum.any?(
             T3.StreamState.list(state, "provider-session"),
             &(&1["lastError"] == "Pi exited unexpectedly")
           )

    context
  end
end
