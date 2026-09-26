defmodule HalC2.Steps.Providers.PermissionModes do
  @moduledoc """
  Steps for `features/providers/permission-modes.feature`: how a thread's runtime and
  interaction modes reach each provider (read from what the fakes were started with
  and sent, `HalC2.Test.Node.World.provider_log/2`), approvals, and delegated children.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @thread "Work"
  @instances %{
    "Codex" => "codex",
    "Claude" => "claudeAgent",
    "Grok" => "grok",
    "OpenCode" => "opencode",
    "Cursor" => "cursor"
  }
  @modes %{
    "supervised" => "approval-required",
    "auto-accept edits" => "auto-accept-edits",
    "auto" => "auto",
    "full access" => "full-access"
  }

  # --- defaults for new threads ---------------------------------------------------------------

  step "no default permission mode is set", context do
    {settings, _} = HalC2.Settings.get()
    refute settings["defaultRuntimeMode"]
    context
  end

  step "the environment default is full access", context do
    World.merge_settings(%{"defaultRuntimeMode" => "full-access"})
    context
  end

  step "the project {string} defaults to supervised", %{args: [project]} = context do
    id = World.project(context, project).id

    World.merge_settings(%{
      "projectSettingsOverrides" => %{id => %{"defaultRuntimeMode" => "approval-required"}}
    })

    context
  end

  step ~r/^the thread (?:is in|is) (?<mode>full access|supervised)$/, %{args: [mode]} = context do
    id = World.thread_id(context, World.current_thread(context))
    assert World.await_row(id, & &1)["runtimeMode"] == @modes[mode]
    context
  end

  # --- each mode on each provider ---------------------------------------------------------------

  step ~r/^an? (?<provider>Claude|Codex|Grok|Cursor|OpenCode) thread in (?<mode>supervised|auto-accept edits|auto|full access)$/,
       %{args: [provider, mode]} = context do
    context
    |> World.fake_providers()
    |> Map.put(:pending_launch, %{
      instance: @instances[provider],
      fields: %{"runtimeMode" => @modes[mode]}
    })
  end

  step "Claude runs with the {string} permission mode", %{args: [mode]} = context do
    assert ["--permission-mode", mode] in Enum.chunk_every(launch_argv(context, "claude"), 2, 1)
    context
  end

  step "Codex runs with the {string} approval policy and the {string} sandbox",
       %{args: [policy, sandbox]} = context do
    params = last_turn_start(context)
    assert params["approvalPolicy"] == policy
    assert params["sandboxPolicy"] == %{"type" => sandbox}
    context
  end

  step ~r/^Grok starts with (?:the (?<mode>\w+) permission mode|(?<all>every action approved))$/,
       %{args: args} = context do
    argv = launch_argv(context, "acp")

    case args do
      [mode | _] when mode not in [nil, ""] ->
        assert ["--permission-mode", mode] in Enum.chunk_every(argv, 2, 1)
        refute "--always-approve" in argv

      _ ->
        assert "--always-approve" in argv
        refute "--permission-mode" in argv
    end

    context
  end

  step "Cursor starts in auto-accept edits", context do
    assert ["--mode", "auto-accept-edits"] in Enum.chunk_every(launch_argv(context, "acp"), 2, 1)
    context
  end

  # --- auto -----------------------------------------------------------------------------------

  step "the agent runs a routine action", context do
    %{instance: instance, fields: fields} = context.pending_launch

    context
    |> Map.delete(:pending_launch)
    |> Map.put(:instance, instance)
    |> World.launch_on(@thread, instance, "approve", fields)
  end

  step "the provider's automatic reviewer approves it", context do
    World.await_runs(context, @thread, ["completed"])
    assert StreamState.list(World.stream(context, @thread), "runtime-request") == []

    case context.instance do
      "codex" ->
        assert %{"approvalsReviewer" => "auto_review"} = last_turn_start(context)

        refute Enum.any?(
                 World.provider_log(context, "codex"),
                 &(get_in(&1, ["in", "id"]) == "approval-1")
               )

      "claudeAgent" ->
        assert ["--permission-mode", "auto"] in Enum.chunk_every(
                 launch_argv(context, "claude"),
                 2,
                 1
               )

        refute Enum.any?(
                 World.provider_log(context, "claude"),
                 &(get_in(&1, ["in", "type"]) == "control_response")
               )
    end

    context
  end

  step "the user is asked, as in supervised", context do
    assert %{"kind" => "command", "status" => "pending"} = World.await_request(context, @thread)
    context
  end

  # --- modes a provider offers --------------------------------------------------------------

  step "a Pi thread", context do
    context = World.fake_providers(context)

    World.merge_settings(%{
      "providers" => %{"pi" => %{"enabled" => true, "binaryPath" => context.fakes.acp}}
    })

    Map.put(context, :instance, "pi")
  end

  step "the user opens the permission mode choices", context do
    entry = World.provider(context, context.instance)
    assert entry, "#{context.instance} is not offered"
    # Clients offer every mode unless the provider names the ones it supports.
    Map.put(context, :permission_modes, entry["supportedRuntimeModes"] || Map.values(@modes))
  end

  step "the request is allowed without asking the user", context do
    World.await_runs(context, @thread, ["completed"])
    assert "Hello from acp" in World.replies(context, @thread)
    assert StreamState.list(World.stream(context, @thread), "runtime-request") == []
    assert %{"optionId" => "allow"} = acp_permission_answer(context)
    context
  end

  step "the user is asked to approve the command", context do
    request = World.await_request(context, @thread)
    assert request["kind"] == "command"
    context
  end

  # --- approval decisions -----------------------------------------------------------------------

  step ~r/^an? (?<provider>Codex|Claude|Grok) thread waiting on a command approval$/,
       %{args: [provider]} = context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, @instances[provider], "approve", %{
        "runtimeMode" => "approval-required"
      })

    request = World.await_request(context, @thread)
    assert request["kind"] == "command"
    Map.put(context, :request, request)
  end

  step ~r/^the provider receives (?<received>accept|accept for the session|decline|allow|a denial saying "(?<message>[^"]*)"|its allow-always option|its reject-once option)$/,
       %{args: [received | rest]} = context do
    World.await_idle(context, @thread)

    case received do
      "accept" ->
        assert codex_decision(context) == "accept"

      "accept for the session" ->
        assert codex_decision(context) == "acceptForSession"

      "decline" ->
        assert codex_decision(context) == "decline"

      "allow" ->
        assert %{"behavior" => "allow"} = claude_answer(context)

      "its allow-always option" ->
        assert %{"optionId" => "always"} = acp_permission_answer(context)

      "its reject-once option" ->
        assert %{"optionId" => "deny"} = acp_permission_answer(context)

      _denial ->
        assert %{"behavior" => "deny", "message" => message} = claude_answer(context)
        assert message == hd(rest)
    end

    context
  end

  step "the approval is closed as cancelled", context do
    World.await_value(context, @thread, fn state ->
      match?(
        %{"status" => "cancelled"},
        StreamState.get(state, "runtime-request")[context.request["id"]]
      )
    end)

    World.await_runs(context, @thread, ["interrupted"])
    context
  end

  # --- questions and plans ----------------------------------------------------------------------

  step "Claude asked the user a question", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "ask me")

    Map.put(context, :request, World.await_request(context, @thread))
  end

  step "Claude is told {string}", %{args: [message]} = context do
    World.await_idle(context, @thread)
    assert %{"behavior" => "deny", "message" => ^message} = claude_answer(context)
    context
  end

  step "a Claude thread in plan mode", context do
    context |> World.fake_providers() |> Map.put(:interaction_mode, "plan")
  end

  step "Claude proposes a plan", context do
    context =
      World.launch_on(context, @thread, "claudeAgent", "make a plan", %{
        "interactionMode" => context.interaction_mode
      })

    World.await_idle(context, @thread)
    context
  end

  step "the plan is shown to the user", context do
    assert [%{"kind" => "proposed_plan", "status" => "active", "markdown" => "# Plan\n- do it"}] =
             StreamState.list(World.stream(context, @thread), "plan")

    context
  end

  step "Claude stops to wait for the user's feedback", context do
    assert %{"behavior" => "deny", "message" => message} = claude_answer(context)
    assert message =~ "Stop here and wait for the user's feedback"
    assert ["completed"] = Enum.map(World.runs(context, @thread), & &1["status"])
    context
  end

  step "a resumed Codex thread that last ran in plan mode", context do
    context
    |> World.fake_providers()
    |> World.run_turns(@thread, "codex", ["make a plan"], %{"interactionMode" => "plan"})
  end

  step "the user sends a message in default mode", context do
    set_mode(context, "thread.interaction-mode.set", %{"interactionMode" => "default"})
    run_turn(context, "hello")
  end

  step "Codex runs in default mode", context do
    starts = turn_starts(context)
    assert Enum.map(starts, & &1["collaborationMode"]["mode"]) == ["plan", "default"]
    # Both turns ran on the same Codex thread, which would keep plan mode otherwise.
    assert starts |> Enum.map(& &1["threadId"]) |> Enum.uniq() |> length() == 1
    context
  end

  # --- delegated children -----------------------------------------------------------------------

  step "a supervised thread", context do
    running(context, %{"runtimeMode" => "approval-required"})
  end

  step "a thread in plan mode", context do
    running(context, %{"interactionMode" => "plan"})
  end

  step "an auto-accept edits thread in plan mode", context do
    running(context, %{"runtimeMode" => "auto-accept-edits", "interactionMode" => "plan"})
  end

  step "the agent delegates a task in full access", context do
    delegate(context, %{"runtimeMode" => "full-access"})
  end

  step "the agent delegates a task in default mode", context do
    delegate(context, %{"interactionMode" => "default"})
  end

  step "the agent delegates a task without naming modes", context do
    delegate(context, %{})
  end

  step "the delegation is refused with {string}", %{args: [message]} = context do
    assert {:error, text} = context.delegation
    assert text =~ message
    context
  end

  step "the delegation is refused because the child mode is broader than plan", context do
    assert {:error, text} = context.delegation
    assert text =~ "Child interaction mode default is broader than parent mode plan."
    context
  end

  step "the child thread runs in auto-accept edits and plan mode", context do
    assert {:ok, %{"childThreadId" => child}} = context.delegation
    row = World.await_row(child, & &1)
    assert {row["runtimeMode"], row["interactionMode"]} == {"auto-accept-edits", "plan"}
    context
  end

  # --- changing the mode mid-thread (the TUI's toggles) --------------------------------------

  step "a supervised thread with a running turn", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "codex", "wait for me", %{
        "runtimeMode" => "approval-required"
      })

    World.await_running(context, @thread)
    context
  end

  step "the running turn keeps supervised", context do
    assert [%{"approvalPolicy" => "untrusted"}] = turn_starts(context)
    # The running turn ends as it started; the next one picks up the change.
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread)
      })

    World.await_idle(context, @thread)
    context
  end

  step "the next turn runs in full access", context do
    run_turn(context, "hello")
    assert %{"approvalPolicy" => "never"} = last_turn_start(context)
    context
  end

  step "the user switches the thread to auto-accept edits on desktop or mobile", context do
    set_mode(context, "thread.runtime-mode.set", %{"runtimeMode" => "auto-accept-edits"})
    context
  end

  step "the next turn runs in auto-accept edits", context do
    # The delegating turn that "a supervised thread" left running ends first.
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, @thread)
      })

    World.await_idle(context, @thread)
    run_turn(context, "hello")

    assert %{"approvalPolicy" => "on-request", "sandboxPolicy" => %{"type" => "workspaceWrite"}} =
             last_turn_start(context)

    context
  end

  step "a full access thread", context do
    context |> World.fake_providers() |> World.run_turns(@thread, "codex", ["hello"])
  end

  step "the user switches the thread to supervised", context do
    set_mode(context, "thread.runtime-mode.set", %{"runtimeMode" => "approval-required"})
    context
  end

  step "the next turn asks before commands and file changes", context do
    context = World.post_message(context, @thread, "approve")
    assert %{"kind" => "command"} = World.await_request(context, @thread)

    assert %{"approvalPolicy" => "untrusted", "sandboxPolicy" => %{"type" => "readOnly"}} =
             last_turn_start(context)

    context
  end

  # --- helpers ----------------------------------------------------------------------------------

  defp launch_argv(context, log) do
    %{"argv" => argv} = World.await_provider_log(context, log, &Map.has_key?(&1, "argv"))
    argv
  end

  defp turn_starts(context) do
    for entry <- World.provider_log(context, "codex"),
        get_in(entry, ["in", "method"]) == "turn/start",
        do: entry["in"]["params"]
  end

  defp last_turn_start(context) do
    World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))
    List.last(turn_starts(context))
  end

  defp codex_decision(context) do
    World.await_provider_log(context, "codex", &(get_in(&1, ["in", "id"]) == "approval-1"))
    |> get_in(["in", "result", "decision"])
  end

  defp claude_answer(context) do
    World.await_provider_log(
      context,
      "claude",
      &(get_in(&1, ["in", "type"]) == "control_response")
    )
    |> get_in(["in", "response", "response"])
  end

  defp acp_permission_answer(context) do
    World.await_provider_log(context, "acp", &(get_in(&1, ["in", "id"]) == "perm-1"))
    |> get_in(["in", "result", "outcome"])
  end

  defp set_mode(context, type, fields) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(
        Map.merge(
          %{
            "type" => type,
            "commandId" => "cmd-#{System.unique_integer([:positive])}",
            "threadId" => World.thread_id(context, World.current_thread(context))
          },
          fields
        )
      )
  end

  defp run_turn(context, text) do
    count = length(World.runs(context, @thread))
    context = World.post_message(context, @thread, text)
    World.await_value(context, @thread, &(length(StreamState.list(&1, "run")) > count))
    World.await_idle(context, @thread)
    context
  end

  # A Codex thread whose turn is running, so its agent can call HAL-C2's tools.
  defp running(context, fields) do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "codex", "wait for me", fields)

    World.await_running(context, @thread)
    Node.ensure(HalC2.Mcp)
    :ok = HalC2.Shell.subscribe(self())
    World.await_row(World.thread_id(context, @thread), & &1)
    context
  end

  defp delegate(context, modes) do
    %{authorization: auth} = HalC2.Mcp.server(World.thread_id(context, @thread), "codex")

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "delegate_task",
          "arguments" => Map.merge(%{"task" => "Look into the tests"}, modes)
        }
      })

    result =
      case HalC2.Mcp.handle(auth, body) do
        {200, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}} ->
          {:error, text}

        {200, %{"result" => %{"structuredContent" => result}}} ->
          {:ok, result}
      end

    Map.put(context, :delegation, result)
  end
end
