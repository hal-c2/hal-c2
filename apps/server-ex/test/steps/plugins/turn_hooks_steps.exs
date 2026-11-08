defmodule HalC2.Steps.Plugins.TurnHooks do
  @moduledoc """
  Plugins that watch and shape turns (`features/plugins/turn-hooks.feature`), on the
  package `turn-probe`, which the plugin host runs as it runs any extension: it exports
  `observe/2` and `shape_run/2`, telling the scenario's process (registered as
  `:hal_c2_turn_probe`) what it heard and was asked, and shapes runs with the
  `:turn_probe_shape` app env (`:raise`, `:linked_exit` and `:not_json` fail). Its call `"host"` drives the host calls
  on turns, `Host.steer/4`, `notice/5`, `generate/3` and `history/3`, with the
  scenario's thread and run. Threads run on the fake providers
  (`HalC2.Test.Mc.World.fake_providers/2`).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @id "turn-probe"
  @probe :hal_c2_turn_probe
  @thread "Turns"
  @instances %{"Claude" => "claudeAgent", "Codex" => "codex", "OpenCode" => "opencode"}
  @fork "Turns fork"
  # A second Claude instance on the same home as the first (`~/.claude`).
  @same_home "claude-same-home"

  # --- plugins ----------------------------------------------------------------------

  step "a plugin that hears turns", context do
    install(context, ["turns:observe"])
  end

  step "a plugin that would hear turns but was not granted {string}", context do
    install(context, [])
  end

  step "a plugin that shapes runs with the context {string} and {string} off",
       %{args: [text, off]} = context do
    World.put_app_env(:turn_probe_shape, %{"context" => text, "deniedTools" => [off]})
    install(context, ["runs:shape"])
  end

  for {how, shape} <- [
        {"raises", :raise},
        {"dies with a process it linked", :linked_exit},
        {"answers with what is not JSON", :not_json}
      ] do
    step "a plugin that #{how} when asked to shape a run", context do
      World.put_app_env(:turn_probe_shape, unquote(shape))
      install(context, ["runs:shape"])
    end
  end

  step "a plugin on turns granted {string}", %{args: [permission]} = context do
    install(context, [permission])
  end

  # --- threads ----------------------------------------------------------------------

  step "a Claude thread runs a turn that calls a tool", context do
    run(context, "Claude", ["hello"])
  end

  step "a Codex thread runs a turn that starts a subagent", context do
    run(context, "Codex", ["spawn a subagent"])
  end

  step "a Claude thread runs two turns", context do
    run(context, "Claude", ["first", "second"])
  end

  step "a Claude thread that ran two turns", context do
    run(context, "Claude", ["first", "second"])
  end

  step "a Claude thread that ran three turns", context do
    run(context, "Claude", ["first", "second", "third"])
  end

  step "a Claude thread whose turn ended", context do
    run(context, "Claude", ["hello"])
  end

  step "a {word} thread runs a turn", %{args: [provider]} = context do
    run(context, provider, ["hello"])
  end

  step "a Codex thread works toward the goal {string}, then runs a turn",
       %{args: [objective]} = context do
    run(context, "Codex", ["/goal #{objective}", "next"])
  end

  step "a Codex thread that ran a turn", context do
    run(context, "Codex", ["hello"])
  end

  # The fake Claude keeps its transcripts under the home both instances share.
  step "a Claude thread that ran a turn", context do
    World.put_os_env("HOME", Mc.tmp_dir(context.mc, "user-home"))
    World.put_os_env("CLAUDE_CONFIG_DIR", nil)
    World.put_os_env("FAKE_SESSIONS", "1")

    context
    |> World.fake_providers()
    |> World.update_settings(%{
      "providerInstances" => %{
        @same_home => %{
          "driver" => "claudeAgent",
          "enabled" => true,
          "displayName" => "Claude (same home)",
          "config" => %{"homePath" => "~/.claude"}
        }
      }
    })
    |> run("Claude", ["hello"])
  end

  step "the thread is forked and the fork runs a turn", context do
    context = World.fork_thread(context, @thread, @fork)
    World.finish_turn(context, @fork, "next")
    context
  end

  step "its next turn runs on another Claude account with the same home", context do
    context =
      World.send_turn(context, @thread, "next", %{
        "modelSelection" => %{"instanceId" => @same_home, "model" => "sonnet"}
      })

    World.await_runs(context, @thread, ["completed", "completed"])
    context
  end

  step "a Claude thread working on a turn with a command running", context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "claudeAgent", "leave a tool pending")

    World.await_thread(context, @thread, fn state ->
      state
      |> StreamState.list("turn-item")
      |> Enum.any?(&(&1["providerToolName"] == "Bash" and &1["status"] == "running"))
    end)

    # The thread "the user stops the turn" stops (common steps).
    Map.put(context, :thread, @thread)
  end

  step "the turn's runtime dies", context do
    [{runtime, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, @thread))
    Process.exit(runtime, :kill)
    context
  end

  step "a Claude thread working on a turn", context do
    context = context |> World.fake_providers() |> World.launch_on(@thread, "claudeAgent", "wait")
    World.await_running(context, @thread)
    context
  end

  # --- what the plugin hears ----------------------------------------------------------

  step "the plugin hears the turn start as a new conversation", context do
    events = heard([])
    assert [%{"type" => "turn.started"} = started | _] = events
    assert %{"provider" => "claudeAgent", "newConversation" => true} = started
    assert started["threadId"] == World.thread_id(context, @thread)
    Map.merge(context, %{events: events, run_id: started["runId"]})
  end

  step "the plugin hears a new {word} conversation start, then the turn end",
       %{args: [provider]} = context do
    assert [%{"type" => "turn.started"} = started | _] = events = heard([])
    assert %{"type" => "turn.finished", "runId" => run_id} = List.last(events)

    assert %{"newConversation" => true, "runId" => ^run_id} = started
    assert started["provider"] == Map.fetch!(@instances, provider)
    assert started["threadId"] == World.thread_id(context, @thread)
    context
  end

  step "it hears the tool call by Claude's own name for the tool, with what it returned",
       context do
    assert %{"itemType" => "command_execution"} =
             item =
             Enum.find(context.events, &(&1["type"] == "turn.item" and &1["tool"] == "Bash"))

    assert item["runId"] == context.run_id
    assert Map.has_key?(item, "output")
    context
  end

  step ~r/^the plugin hears the command end (?<status>\w+), then the turn end$/,
       %{args: [status]} = context do
    events = heard([])
    assert %{"type" => "turn.finished"} = List.last(events)

    assert %{"status" => ^status} =
             Enum.find(events, &(&1["type"] == "turn.item" and &1["tool"] == "Bash"))

    context
  end

  step "it hears the turn end last", context do
    assert %{"type" => "turn.finished", "status" => "completed"} =
             finished = List.last(context.events)

    assert finished["runId"] == context.run_id
    assert Enum.count(context.events, &(&1["type"] == "turn.finished")) == 1
    context
  end

  step "the plugin hears the subagent start in that turn, before it ends", context do
    assert [%{"type" => "turn.started", "provider" => "codex", "runId" => run_id} | _] =
             events = heard([])

    assert %{"itemType" => "subagent", "status" => "running", "runId" => ^run_id} =
             Enum.find(events, &(&1["type"] == "turn.item" and &1["itemType"] == "subagent"))

    context
  end

  step "the plugin hears nothing", context do
    # The feed handles what it was sent in order; once it answers, it has handled the
    # turn's events.
    assert [{pid, _}] = Registry.lookup(HalC2.Plugins.Hooks, {:observe, @id})
    :sys.get_state(pid)
    refute_received {:observed, _}
    context
  end

  step "the plugin reads the thread's turns", context do
    call(context, %{"call" => "history", "threadId" => World.thread_id(context, @thread)})
  end

  step "the plugin reads one turn from before the thread's last turn", context do
    last = context |> World.runs(@thread) |> List.last()

    call(context, %{
      "call" => "history",
      "threadId" => World.thread_id(context, @thread),
      "before" => last["id"],
      "limit" => 1
    })
  end

  step "it gets the thread's second turn, which ran on Claude", context do
    assert {:ok, [turn]} = context.reply
    assert [_first, second, _third] = World.runs(context, @thread)
    assert %{"runId" => id, "provider" => "claudeAgent"} = turn
    assert id == second["id"]
    context
  end

  step "it gets both turns, oldest first, each with its tool calls", context do
    assert {:ok, [one, two]} = context.reply
    assert [first, second] = World.runs(context, @thread)
    assert one["runId"] == first["id"] and two["runId"] == second["id"]
    for turn <- [one, two], do: assert(Enum.any?(turn["items"], &(&1["tool"] == "Bash")))
    context
  end

  # --- shaping ----------------------------------------------------------------------

  step "{word} gets {string} ahead of the first message only",
       %{args: [provider, text]} = context do
    [first | rest] = prompts(context, provider)
    {ahead, _} = :binary.match(first, text)
    {at, _} = :binary.match(first, hd(context.texts))
    assert ahead < at
    for later <- rest, do: refute(later =~ text)
    context
  end

  step "Codex is asked to work toward {string} after {string}",
       %{args: [objective, text]} = context do
    [first | _] = prompts(context, "Codex")
    {ahead, _} = :binary.match(first, text)
    {at, _} = :binary.match(first, HalC2.Codex.Goals.first_prompt(objective))
    assert ahead < at
    context
  end

  step "the turn after the goal comes without {string}", %{args: [text]} = context do
    assert [_goal, next] = prompts(context, "Codex")
    assert next =~ "next"
    refute next =~ text
    context
  end

  step "Claude ran both turns without {string}", %{args: [tool]} = context do
    launches = claude_launches(context)
    assert launches != []
    for argv <- launches, do: assert(denied(argv) =~ tool)
    context
  end

  step "the plugin was asked once", context do
    assert_received {:shaping, _}
    refute_received {:shaping, _}
    context
  end

  step "the plugin was told the provider's tools are turned off by {word}",
       %{args: [unit]} = context do
    told(context, unit)
  end

  step "the plugin was told the provider's tools are turned off by {word} {word}",
       %{args: words} = context do
    told(context, Enum.join(words, " "))
  end

  step "{word} ran the turn with {string} off", %{args: ["Claude", tool]} = context do
    for argv <- claude_launches(context), do: assert(denied(argv) =~ tool)
    context
  end

  step "Codex forks its own conversation with its subagent tools still off", context do
    assert [fork] =
             for(
               %{"in" => %{"method" => "thread/fork", "params" => params}} <-
                 World.provider_log(context, "codex"),
               do: params
             )

    assert %{
             "features" => %{"multi_agent" => false, "multi_agent_v2" => false},
             "include_collaboration_mode_instructions" => false
           } = fork["config"]

    context
  end

  step "the fork's message comes without {string}", %{args: [text]} = context do
    assert List.last(prompts(context, "Codex")) =~ "next"
    refute List.last(prompts(context, "Codex")) =~ text
    context
  end

  step "that account resumes the conversation without {string}", %{args: [tool]} = context do
    argv = List.last(claude_launches(context))
    native = World.stream(context, @thread) |> StreamState.list("provider-thread")
    native = Enum.find_value(native, &get_in(&1, ["nativeThreadRef", "nativeId"]))
    assert ["--resume", native] in Enum.chunk_every(argv, 2, 1)
    assert denied(argv) =~ tool
    context
  end

  step "Codex ran the turn with its subagent tools off", context do
    [start] =
      for %{"in" => %{"method" => "thread/start", "params" => params}} <-
            World.provider_log(context, "codex"),
          do: params

    assert %{
             "features" => %{"multi_agent" => false, "multi_agent_v2" => false},
             "include_collaboration_mode_instructions" => false
           } = start["config"]

    context
  end

  step "OpenCode ran the turn with every tool it had", context do
    # Nothing in its session says a tool is off: ACP has no way to say so.
    for entry <- World.provider_log(context, "acp"),
        do: refute(JSON.encode!(entry) =~ "anything")

    context
  end

  step "Claude gets the message as the user wrote it", context do
    assert ["hello"] = prompts(context, "Claude")
    context
  end

  step "the turn completes unshaped", context do
    assert ["completed"] = World.runs(context, @thread) |> Enum.map(& &1["status"])
    context
  end

  # --- steering and notices ---------------------------------------------------------

  step "the plugin steers that turn with {string}", %{args: [text]} = context do
    call(context, %{"call" => "steer", "text" => text} |> Map.merge(ids(context)))
  end

  step "the plugin steers the thread with {string}, naming no turn", %{args: [text]} = context do
    input = %{"call" => "steer", "text" => text, "threadId" => World.thread_id(context, @thread)}
    call(context, input)
  end

  step "Claude gets {string} in that turn", %{args: [text]} = context do
    assert {:ok, _} = context.reply

    World.await_provider_log(context, "claude", fn entry ->
      is_map(entry["in"]) and JSON.encode!(entry["in"]) =~ text
    end)

    # The fake answers a steer in the turn it cut short, which then ends: one turn.
    World.await_runs(context, @thread, ["completed"])
    context
  end

  step "the plugin is told the turn cannot take it", context do
    assert {:error, _, %{"_tag" => "PluginCallFailed"}} = context.reply
    context
  end

  step "no turn is queued and no message kept for {string}", %{args: [text]} = context do
    assert ["completed"] = World.runs(context, @thread) |> Enum.map(& &1["status"])

    refute context
           |> World.stream(@thread)
           |> HalC2.StreamState.list("message")
           |> Enum.any?(&(&1["text"] == text))

    context
  end

  step "the plugin shows the notice {string} titled {string} with a way to stop the turn",
       %{args: [message, title]} = context do
    call(
      context,
      %{"call" => "notice", "message" => message, "title" => title, "interrupt" => true}
      |> Map.merge(ids(context))
    )
  end

  step "the turn shows the notice {string} from the plugin, offering to stop the turn",
       %{args: [title]} = context do
    assert {:ok, item_id} = context.reply

    item =
      context
      |> World.stream(@thread)
      |> HalC2.StreamState.get("turn-item")
      |> Map.fetch!(item_id)

    assert %{"type" => "system_notice", "title" => ^title, "pluginId" => @id} = item
    assert item["actions"] == ["interrupt"]
    assert item["runId"] == ids(context)["runId"]
    context
  end

  # --- text generation --------------------------------------------------------------

  step "the plugin asks the text model for a {string}", %{args: [key]} = context do
    context =
      context
      |> World.fake_text_clis([:claude])
      |> World.update_settings(%{
        "textGenerationModelSelection" => %{
          "instanceId" => "claudeAgent",
          "model" => "claude-haiku-5-5"
        }
      })

    call(context, %{
      "call" => "generate",
      "prompt" => "Summarise: the agent read three files.",
      "schema" => %{key => "string"}
    })
  end

  step "it gets a summary", context do
    assert {:ok, %{"out" => %{"summary" => summary}}} = context.reply
    assert is_binary(summary) and summary != ""
    context
  end

  step "it is told the tokens the provider said the answer used", context do
    assert {:ok, %{"usage" => usage}} = context.reply
    assert %{"estimated" => false, "inputTokens" => input, "outputTokens" => output} = usage
    assert input > 0 and output > 0
    context
  end

  # --- refusals ---------------------------------------------------------------------

  step "the plugin tries to steer the turn", context do
    call(context, %{"call" => "steer", "text" => "hi"} |> Map.merge(ids(context)))
  end

  step "the plugin tries to show a notice", context do
    call(context, %{"call" => "notice", "message" => "hi"} |> Map.merge(ids(context)))
  end

  step "the plugin tries to ask the text model", context do
    call(context, %{"call" => "generate", "prompt" => "hi", "schema" => %{"a" => "string"}})
  end

  # --- helpers ----------------------------------------------------------------------

  # Installs and enables `turn-probe` asking for and granted `permissions`, with the
  # scenario's process hearing it.
  defp install(context, permissions) do
    if Process.whereis(@probe) != self(), do: Process.register(self(), @probe)

    dir = Path.join([context.mc.home, "plugins", @id])
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "mc"))

    manifest = %{
      "id" => @id,
      "name" => "Turn probe",
      "version" => "1.0.0",
      "apiVersion" => 1,
      "description" => "Hears and shapes turns.",
      "permissions" => for(id <- permissions, do: %{"id" => id, "reason" => "The scenario."})
    }

    File.write!(Path.join(dir, "plugin.json"), JSON.encode!(manifest))
    File.write!(Path.join(dir, "mc/turn_probe.ex"), source())
    context = context |> Fixtures.ensure() |> Fixtures.rescan()

    {_, context} =
      World.call!(context, "plugins.enable", %{"id" => @id, "acceptPermissions" => permissions})

    assert %{"status" => "running"} = Fixtures.entry(@id)
    Map.put(context, :plugin, @id)
  end

  defp call(context, input) do
    {reply, context} =
      World.call(context, "plugins.call", %{"id" => @id, "method" => "host", "input" => input})

    Map.put(context, :reply, reply)
  end

  defp run(context, provider, texts) do
    context
    |> World.fake_providers()
    |> World.run_turns(@thread, Map.fetch!(@instances, provider), texts)
    |> Map.put(:texts, texts)
  end

  # The scenario's thread and its last run.
  defp ids(context) do
    %{
      "threadId" => World.thread_id(context, @thread),
      "runId" => (context |> World.runs(@thread) |> List.last())["id"]
    }
  end

  # What the plugin heard, oldest first, up to the end of a turn.
  defp heard(events) do
    assert_receive {:observed, event}, 5_000
    events = [event | events]
    if event["type"] == "turn.finished", do: Enum.reverse(events), else: heard(events)
  end

  defp told(context, unit) do
    expected = %{"tool name" => "tool", "capability" => "capability", "nothing" => nil}
    assert_received {:shaping, run}
    assert run["toolUnit"] == Map.fetch!(expected, unit)
    context
  end

  # The text of each user message `provider` was sent, steers included, oldest first.
  defp prompts(context, "Claude") do
    for %{"in" => %{"type" => "user", "message" => message}} <-
          World.provider_log(context, "claude"),
        do: text(message["content"])
  end

  defp prompts(context, "Codex") do
    for %{"in" => %{"method" => "turn/start", "params" => params}} <-
          World.provider_log(context, "codex"),
        do: text(params["input"])
  end

  defp prompts(context, "OpenCode") do
    for %{"method" => "session/prompt", "params" => params} <- acp_messages(context),
        do: text(params["prompt"])
  end

  defp acp_messages(context) do
    for entry <- World.provider_log(context, "acp"),
        msg = entry["in"] || entry,
        is_map(msg),
        do: msg
  end

  defp text(content) when is_binary(content), do: content

  defp text(content) when is_list(content),
    do: content |> Enum.map(&(&1["text"] || "")) |> Enum.join("\n")

  # The argv of each launch of the fake Claude.
  defp claude_launches(context) do
    for %{"argv" => argv} <- World.provider_log(context, "claude"), do: argv
  end

  defp denied(argv) do
    case Enum.drop_while(argv, &(&1 != "--disallowedTools")) do
      [_, tools | _] -> tools
      _ -> ""
    end
  end

  defp source do
    """
    defmodule HalC2PluginFixture.TurnProbe do
      @behaviour HalC2.Plugins.Extension
      alias HalC2.Plugins.Host

      @id #{inspect(@id)}

      def observe(event, _context), do: tell({:observed, event})

      def shape_run(run, _context) do
        tell({:shaping, run})

        case Application.get_env(:hal_c2, :turn_probe_shape) do
          :raise ->
            raise "no shape"

          :linked_exit ->
            spawn_link(fn -> exit(:boom) end)
            receive do: (:never -> nil)

          :not_json ->
            %{"context" => self()}

          shape ->
            shape
        end
      end

      @impl true
      def call("host", %{"call" => "steer"} = input, _context),
        do: Host.steer(@id, input["threadId"], input["runId"], input["text"])

      def call("host", %{"call" => "notice"} = input, _context) do
        opts = [title: input["title"], interrupt: input["interrupt"] == true]
        Host.notice(@id, input["threadId"], input["runId"], input["message"], opts)
      end

      def call("host", %{"call" => "generate"} = input, _context) do
        with {:ok, out, usage} <- Host.generate(@id, input["prompt"], input["schema"]),
             do: {:ok, %{"out" => out, "usage" => usage}}
      end

      def call("host", %{"call" => "history"} = input, _context) do
        opts = [before: input["before"], limit: input["limit"]]
        Host.history(@id, input["threadId"], Enum.reject(opts, &(elem(&1, 1) == nil)))
      end

      def call(method, _input, _context), do: {:error, "no method " <> method}

      defp tell(message) do
        case Process.whereis(#{inspect(@probe)}) do
          nil -> :ok
          pid -> send(pid, message)
        end
      end
    end
    """
  end
end
