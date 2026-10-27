defmodule HalC2.Steps.Orchestration.Commands do
  @moduledoc "Steps for `features/mc/orchestration/commands.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  step "{string} is at sequence {int}", %{args: [thread, seq]} = context do
    Map.put(context, :sequence, bump(context, thread, seq))
  end

  step "{string} was last visited at {int}:{int} and is at sequence {int}",
       %{args: [thread, hour, minute, seq]} = context do
    {{:ok, _}, context} = World.dispatch(context, visit(context, thread, hour, minute))
    Map.put(context, :sequence, bump(context, thread, seq))
  end

  step "a client pins {string}", %{args: [thread]} = context do
    command = %{"type" => "thread.pin", "threadId" => World.thread_id(context, thread)}
    answer(context, command)
  end

  step "a client records a visit to {string} at {int}:{int}",
       %{args: [thread, hour, minute]} = context do
    answer(context, visit(context, thread, hour, minute))
  end

  step "the answer is a sequence after {int}", %{args: [seq]} = context do
    assert {:ok, %{"sequence" => answered}} = context.reply
    assert answered > max(seq, context.sequence)
    context
  end

  step "the answer is sequence {int}", %{args: [seq]} = context do
    assert context.sequence == seq
    assert {:ok, %{"sequence" => ^seq}} = context.reply
    context
  end

  step "a client subscribed to {string} has seen that sequence once the change reaches it",
       %{args: [thread]} = context do
    {:ok, %{"sequence" => seq}} = context.reply
    id = World.thread_id(context, thread)
    shape = %{"type" => "stream", "mc" => Atom.to_string(node()), "stream" => id}
    client = context.mc |> Mc.connect() |> Mc.sub(9, shape)
    {frame, _client} = Mc.await(client, &(&1["t"] == "live" and &1["id"] == 9))
    assert frame["offset"] >= seq
    context
  end

  step "two clients rename {string} at the same moment", %{args: [thread]} = context do
    id = World.thread_id(context, thread)

    renames =
      ["First title", "Second title"]
      |> Enum.map(fn title ->
        Task.async(fn ->
          {:ok, %{"sequence" => seq}} =
            HalC2.Orchestration.dispatch(%{
              "type" => "thread.metadata.update",
              "commandId" => "cmd-#{System.unique_integer([:positive])}",
              "threadId" => id,
              "title" => title
            })

          {seq, title}
        end)
      end)
      |> Task.await_many()

    Map.put(context, :renames, renames)
  end

  step "one rename applies after the other and {string} ends with the later title",
       %{args: [thread]} = context do
    titles = Enum.map(context.renames, &elem(&1, 1))
    id = World.thread_id(context, thread)

    # The stream's events hold both renames, one after the other.
    applied =
      context.mc.store
      |> HalC2.Store.reduce_stream(id, 0, [], fn event, acc ->
        case Enum.find(titles, &String.contains?(JSON.encode!(event.patch), &1)) do
          nil -> acc
          title -> [title | acc]
        end
      end)
      |> Enum.reverse()

    assert Enum.sort(applied) == Enum.sort(titles)
    assert World.thread(context, thread)["title"] == List.last(applied)
    context
  end

  step "a client dispatches a command that fails its checks on {string}",
       %{args: [thread]} = context do
    context = Map.put(context, :sequence, sequence(context, thread))
    id = World.thread_id(context, thread)

    # A thread cannot be created twice.
    answer(context, %{"type" => "thread.create", "threadId" => id, "title" => "Again"})
  end

  step "it fails with a message saying why", context do
    assert {:error, message, _} = context.reply
    assert message =~ "already exists"
    context
  end

  step "the sequence of {string} is unchanged", %{args: [thread]} = context do
    assert sequence(context, thread) == context.sequence
    context
  end

  step "a client dispatches a command of type {string}", %{args: [type]} = context do
    context = Map.put(context, :sequence, sequence(context, "t1"))
    answer(context, %{"type" => type, "threadId" => World.thread_id(context, "t1")})
  end

  step "it fails and nothing changes", context do
    assert {:error, message, _} = context.reply
    assert message =~ "not supported"
    assert sequence(context, "t1") == context.sequence
    context
  end

  step "a client dispatched message {string} to {string} with command id {string}",
       %{args: [text, thread, id]} = context do
    command = World.message_command(World.providers(context), thread, text, %{"commandId" => id})
    context = answer(context, command)
    assert {:ok, %{"sequence" => _}} = context.reply
    World.await_runs(context, thread, ["completed"])
    Map.merge(context, %{command: command, first_reply: context.reply})
  end

  step "it dispatches the same command again with command id {string} after a reconnect",
       %{args: [id]} = context do
    assert context.command["commandId"] == id
    context = World.put_client(context, Mc.connect(context.mc))
    answer(context, context.command)
  end

  step "no second message or run is created", context do
    state = World.state(context, "t1")
    assert [%{"status" => "completed"}] = HalC2.StreamState.list(state, "run")

    assert [_] =
             state |> HalC2.StreamState.list("message") |> Enum.filter(&(&1["role"] == "user"))

    context
  end

  step "the answer is the sequence of the first dispatch", context do
    assert context.reply == context.first_reply
    context
  end

  step "a client dispatched a command to {string} with command id {string}",
       %{args: [thread, id]} = context do
    command = %{"type" => "thread.pin", "commandId" => id}
    context = answer(context, Map.put(command, "threadId", World.thread_id(context, thread)))
    assert {:ok, _} = context.reply
    Map.put(context, :command, command)
  end

  step "a client dispatches a command with id {string} to {string}",
       %{args: [id, thread]} = context do
    assert context.command["commandId"] == id
    context = World.create_thread(context, thread, "demo")
    context = Map.put(context, :before, World.thread(context, thread))
    answer(context, Map.put(context.command, "threadId", World.thread_id(context, thread)))
  end

  step "the command is rejected", context do
    assert {:error, message, _} = context.reply
    assert message =~ "cannot be replayed"
    context
  end

  step "nothing about {string} changes", %{args: [thread]} = context do
    assert World.thread(context, thread) == context.before
    context
  end

  # Pinning a thread that does not exist yet is refused; once it exists the same
  # command would pass, so a second refusal shows the first outcome was kept.
  step "a command with id {string} was rejected", %{args: [id]} = context do
    command = %{"type" => "thread.pin", "commandId" => id, "threadId" => "th-later"}
    context = answer(context, command)
    assert {:error, _, _} = context.reply
    Map.merge(context, %{command: command, first_reply: context.reply})
  end

  step "it is dispatched again with id {string}", %{args: [id]} = context do
    assert context.command["commandId"] == id
    context = World.create_thread(context, "later", "demo", %{"threadId" => "th-later"})
    answer(context, context.command)
  end

  step "it is rejected again without being re-evaluated", context do
    assert {:error, message, _} = context.reply
    assert {:error, ^message, _} = context.first_reply
    assert World.thread(context, "later")["pinnedAt"] == nil
    context
  end

  step "a command was accepted and its provider work was not yet started", context do
    context = World.providers(context)
    context = World.add_message(context, "t1", "user", "hello")
    [%{"id" => message}] = HalC2.StreamState.list(World.state(context, "t1"), "message")

    World.add_run(context, "t1", "starting", nil, %{
      "userMessageId" => message,
      "startedAt" => nil
    })
  end

  step "the pending provider work runs once after the restart", context do
    state = World.await_runs(context, "t1", ["completed"])
    assert [_] = HalC2.StreamState.list(state, "provider-turn")
    context
  end

  # --- a recording that fails part way ------------------------------------------------

  # Fails on the second change recorded for a thread, inside the store's
  # append transaction (`:store_hook`).
  def fail_second_change(count, :append_change, _stream_id) do
    if Agent.get_and_update(count, &{&1, &1 + 1}) == 1,
      do: raise("the disk filled while recording")
  end

  step "recording a command on {string} fails part way through",
       %{args: [thread]} = context do
    context = World.providers(context)
    {:ok, count} = Agent.start_link(fn -> 0 end)
    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :fail_second_change, [count]})
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :store_hook) end)

    command =
      World.message_command(context, thread, "hello", %{
        "commandId" => "cmd-atomic",
        "messageId" => "msg-atomic"
      })

    context =
      Map.merge(context, %{
        command: command,
        sequence: sequence(context, thread),
        messages: length(World.entities(context, thread, "message")),
        runs: length(World.entities(context, thread, "run"))
      })

    answer(context, command)
  end

  step "{string} has none of its events, no receipt for it and none of its side effects",
       %{args: [thread]} = context do
    Application.delete_env(:hal_c2, :store_hook)
    assert {:error, message, _} = context.reply
    assert message =~ "the disk filled while recording"
    assert sequence(context, thread) == context.sequence
    assert length(World.entities(context, thread, "message")) == context.messages
    assert length(World.entities(context, thread, "run")) == context.runs
    assert HalC2.Store.meta(HalC2.Store.path(), "command-receipt:cmd-atomic") == nil

    assert Enum.filter(
             effects(context, thread),
             &(&1["type"] == "provider-turn.start")
           ) == []

    context
  end

  step "the same command can be dispatched again", context do
    context = answer(context, context.command)
    assert {:ok, _} = context.reply
    World.await_runs(context, "t1", ["completed"])
    context
  end

  # --- a side effect that keeps failing -----------------------------------------------

  step "a command was accepted and its side effect keeps failing", context do
    context = World.text_writers(context, [:codex], %{})
    World.put_env("FAKE_TEXT_FAIL", "the writer is down")

    context =
      World.launch_titled(context, "titled", "demo", "Fix the parser", %{
        "title" => "New thread",
        "generateTitle" => true
      })

    :ok = HalC2.Orchestration.Effects.drain(World.thread_id(context, "titled"), 20_000)
    context
  end

  step "the side effect is tried {int} times in all", %{args: [tries]} = context do
    assert title_effect(context)["attempts"] == tries
    assert length(World.text_calls(context)) == tries
    context
  end

  step "the waits between tries double from {int} milliseconds, never more than {int} seconds",
       %{args: [first, cap]} = context do
    delays = title_effect(context)["delays"]
    assert delays == Enum.map(0..(length(delays) - 1), &(first * 2 ** &1))
    assert Enum.all?(delays, &(&1 <= cap * 1000))
    context
  end

  step "after the last try it is recorded as failed with its error", context do
    effect = title_effect(context)
    assert effect["status"] == "failed"
    assert effect["error"] =~ "the writer is down"
    context
  end

  defp title_effect(context) do
    context
    |> effects("titled")
    |> Enum.find(&(&1["type"] == "thread-title.generate"))
  end

  defp effects(context, thread),
    do: HalC2.Orchestration.Effects.effects(World.thread_id(context, thread))

  # --- holding an effect ---------------------------------------------------------------

  # Holds matching effects in `:effects_hold_match` (`{thread_id, type}`)
  # before they run, until the test releases (or kills) the holding process.
  def hold_effect(test, :execute, record) do
    {thread, type} = Application.get_env(:hal_c2, :effects_hold_match, {nil, nil})

    if thread in [nil, record["threadId"]] and record["type"] == type do
      id = record["id"]
      send(test, {:effect_held, id, self()})

      receive do
        {:release_effect, ^id} -> :ok
      end
    end

    :ok
  end

  # Holds only the first matching effect; later ones run.
  def hold_first_effect(count, test, :execute, record) do
    {thread, type} = Application.get_env(:hal_c2, :effects_hold_match, {nil, nil})

    if thread in [nil, record["threadId"]] and record["type"] == type and
         Agent.get_and_update(count, &{&1, &1 + 1}) == 0 do
      id = record["id"]
      send(test, {:effect_held, id, self()})

      receive do
        {:release_effect, ^id} -> :ok
      end
    end

    :ok
  end

  defp hold_effects(context, thread, type, first_only \\ false) do
    Application.put_env(:hal_c2, :effects_hold_match, {World.thread_id(context, thread), type})

    hook =
      if first_only do
        {:ok, count} = Agent.start_link(fn -> 0 end)
        {__MODULE__, :hold_first_effect, [count, self()]}
      else
        {__MODULE__, :hold_effect, [self()]}
      end

    Application.put_env(:hal_c2, :effects_hook, hook)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:hal_c2, :effects_hook)
      Application.delete_env(:hal_c2, :effects_hold_match)
    end)

    context
  end

  defp await_held do
    receive do
      {:effect_held, id, pid} -> {id, pid}
    after
      5_000 -> flunk("no effect was held")
    end
  end

  defp release_helds do
    receive do
      {:effect_held, id, pid} ->
        send(pid, {:release_effect, id})
        release_helds()
    after
      0 -> :ok
    end
  end

  # --- work left by a lost server process ----------------------------------------------

  @bound_work %{
    "starting a provider turn" => "provider-turn.start",
    "interrupting a provider turn" => "provider-turn.interrupt",
    "steering a provider turn" => "provider-turn.steer",
    "restarting a provider turn" => "provider-turn.restart",
    "answering a provider's request" => "runtime-request.respond"
  }

  step ~r/^(?<work>.+) was pending or under way when the server process ended$/,
       %{args: [work]} = context do
    type = Map.fetch!(@bound_work, work)
    context = World.providers(context)
    context = hold_effects(context, "t1", type)

    {:ok, id} =
      HalC2.Orchestration.Effects.enqueue(
        World.thread_id(context, "t1"),
        type,
        %{"runId" => "run-lost", "requestId" => "request-lost"}
      )

    {^id, held} = await_held()
    Map.merge(context, %{effect_id: id, held: held, work_type: type})
  end

  step "that work is not run again", context do
    effect = find_effect(context, context.effect_id)
    assert effect["attempts"] == 1
    Process.exit(context.held, :kill)
    context
  end

  step "it is recorded as {string}", %{args: [message]} = context do
    effect = find_effect(context, context.effect_id)
    assert effect["status"] == "cancelled"
    assert effect["error"] == message
    context
  end

  defp find_effect(context, id) do
    World.thread_id(context, "t1")
    |> HalC2.Orchestration.Effects.effects()
    |> Enum.find(&(&1["id"] == id))
  end

  @safe_work %{
    "continuing a thread after an update" => "provider-runtime.continue",
    "detaching a provider session" => "provider-session.detach",
    "rolling back a provider conversation" => "provider-thread.rollback",
    "capturing a checkpoint" => "checkpoint.capture",
    "cleaning up a thread's terminals" => "terminal.cleanup",
    "removing a thread's attached files" => "attachment.cleanup",
    "generating a thread title" => "thread-title.generate"
  }

  step ~r/^(?<work>.+) was under way when the server process ended$/,
       %{args: [work]} = context do
    type = Map.fetch!(@safe_work, work)
    context = safe_setup(context, work)
    context = hold_effects(context, "t1", type)

    {:ok, id} =
      HalC2.Orchestration.Effects.enqueue(
        World.thread_id(context, "t1"),
        type,
        safe_args(context, work),
        if(type == "thread-title.generate", do: "title", else: "provider")
      )

    {^id, held} = await_held()
    Map.merge(context, %{effect_id: id, held: held, work: work, work_type: type})
  end

  # What each kind of repeatable work needs around it to run again for real.
  defp safe_setup(context, "generating a thread title"),
    do: World.text_writers(World.providers(context), [:codex], %{})

  defp safe_setup(context, "removing a thread's attached files") do
    context = World.providers(context)
    thread_id = World.thread_id(context, "t1")

    {:ok, %{"attachments" => [stored]}} =
      HalC2.Attachments.persist(%{
        "threadId" => thread_id,
        "attachments" => [
          %{
            "name" => "note.png",
            "mimeType" => "image/png",
            "dataUrl" => "data:image/png;base64,#{Base.encode64("png-bytes")}"
          }
        ]
      })

    path = HalC2.Attachments.path(stored)
    assert File.exists?(path)
    Map.put(context, :attached_file, path)
  end

  defp safe_setup(context, work)
       when work in ["rolling back a provider conversation", "capturing a checkpoint"] do
    context = World.providers(context)
    context = answer(context, World.message_command(context, "t1", "first"))
    World.await_runs(context, "t1", ["completed"])
    context = answer(context, World.message_command(context, "t1", "second"))
    World.await_runs(context, "t1", ["completed", "completed"])
    context
  end

  defp safe_setup(context, _work), do: World.providers(context)

  defp safe_args(context, "continuing a thread after an update") do
    %{
      "command" =>
        World.message_command(context, "t1", "Continue where you left off.", %{
          "commandId" => "cmd-continue-lost",
          "messageId" => "msg-continue-lost",
          "createdBy" => "agent",
          "creationSource" => "server"
        })
    }
  end

  defp safe_args(context, "rolling back a provider conversation") do
    scope = HalC2.Checkpoint.scope_id(World.thread_id(context, "t1"))

    %{
      "command" => %{
        "type" => "checkpoint.rollback",
        "threadId" => World.thread_id(context, "t1"),
        "scopeId" => scope,
        "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope, 1),
        "restoreFiles" => false
      }
    }
  end

  defp safe_args(context, "capturing a checkpoint") do
    thread_id = World.thread_id(context, "t1")
    [run | _] = World.entities(context, "t1", "run")

    %{
      "cwd" => World.project(context, "demo").root,
      "scopeId" => HalC2.Checkpoint.scope_id(thread_id),
      "runOrdinal" => run["ordinal"],
      "runId" => run["id"],
      "rootNodeId" => run["rootNodeId"],
      "at" => HalC2.Orchestration.Entities.now()
    }
  end

  defp safe_args(_context, "generating a thread title"),
    do: %{"text" => "Fix the parser", "attachments" => [], "previous" => nil}

  defp safe_args(_context, _work), do: %{}

  step "that work is run again from the start", context do
    thread_id = World.thread_id(context, "t1")
    # The hold that kept the work under way across the restart also caught
    # its replay; let it go now.
    Application.delete_env(:hal_c2, :effects_hook)
    Application.delete_env(:hal_c2, :effects_hold_match)
    release_helds()
    :ok = HalC2.Orchestration.Effects.drain(thread_id, 20_000)
    effect = find_effect(context, context.effect_id)
    assert effect["status"] == "done"
    assert effect["attempts"] >= 2
    safe_outcome(context)
    Process.exit(context.held, :kill)
    context
  end

  defp safe_outcome(%{work: "continuing a thread after an update"} = context) do
    texts =
      context
      |> World.entities("t1", "message")
      |> Enum.map(& &1["text"])

    assert "Continue where you left off." in texts
  end

  defp safe_outcome(%{work: "rolling back a provider conversation"} = context) do
    statuses = context |> World.entities("t1", "run") |> Enum.map(& &1["status"])
    assert statuses == ["completed", "rolled_back"]
  end

  defp safe_outcome(%{work: "capturing a checkpoint"} = context) do
    scope = HalC2.Checkpoint.scope_id(World.thread_id(context, "t1"))
    ref = HalC2.Checkpoint.ref(scope, 1)
    root = World.project(context, "demo").root
    assert {_out, 0} = System.cmd("git", ["rev-parse", "--verify", ref], cd: root)
  end

  defp safe_outcome(%{work: "removing a thread's attached files"} = context),
    do: refute(File.exists?(context.attached_file))

  defp safe_outcome(%{work: "generating a thread title"} = context),
    do: assert(World.thread(context, "t1")["title"] == "codex title")

  defp safe_outcome(_context), do: :ok

  # --- ordering on a thread --------------------------------------------------------------

  step "{string} has two side effects waiting and thread {string} has one",
       %{args: [first, second]} = context do
    context = World.providers(context)
    context = World.create_thread(context, second, "demo")
    context = hold_effects(context, first, "provider-session.detach", true)

    for thread <- [first, first, second] do
      {:ok, _} =
        HalC2.Orchestration.Effects.enqueue(
          World.thread_id(context, thread),
          "provider-session.detach",
          %{}
        )
    end

    {id, held} = await_held()
    :ok = HalC2.Orchestration.Effects.drain(World.thread_id(context, second), 10_000)
    Map.merge(context, %{held: held, held_id: id})
  end

  step("the first side effect of {string} is slow", %{args: [_thread]} = context, do: context)

  step "the second side effect of {string} waits for it", %{args: [thread]} = context do
    detach = Enum.filter(effects(context, thread), &(&1["type"] == "provider-session.detach"))
    running = Enum.find(detach, &(&1["status"] == "running"))
    waiting = Enum.find(detach, &(&1["status"] == "pending"))

    assert running["id"] == context.held_id
    assert waiting != nil
    send(context.held, {:release_effect, context.held_id})
    :ok = HalC2.Orchestration.Effects.drain(World.thread_id(context, thread), 10_000)
    context
  end

  step "the side effect of {string} runs without waiting", %{args: [thread]} = context do
    [effect] = Enum.filter(effects(context, thread), &(&1["type"] == "provider-session.detach"))
    assert effect["status"] == "done"
    context
  end

  # --- the title lane --------------------------------------------------------------------

  step "{string} is generating its title", %{args: [thread]} = context do
    context = World.text_writers(context, [:codex], %{})

    # The launched thread is a new one, so the hold matches by kind alone.
    Application.put_env(:hal_c2, :effects_hold_match, {nil, "thread-title.generate"})
    Application.put_env(:hal_c2, :effects_hook, {__MODULE__, :hold_effect, [self()]})

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:hal_c2, :effects_hook)
      Application.delete_env(:hal_c2, :effects_hold_match)
    end)

    context =
      World.launch_titled(context, thread, "demo", "Fix the parser", %{
        "title" => "New thread",
        "generateTitle" => true
      })

    {id, held} = await_held()
    Map.merge(context, %{held: held, held_id: id})
  end

  step "the provider turn starts without waiting for the title", context do
    World.await_runs(context, "t1", ["completed", "completed"])
    assert find_effect(context, context.held_id)["status"] == "running"
    send(context.held, {:release_effect, context.held_id})
    context
  end

  step "a slow provider turn does not hold back the title", context do
    Application.delete_env(:hal_c2, :effects_hook)
    context = answer(context, World.message_command(context, "t1", "wait for me"))
    World.await_latest_run(context, "t1", "running")

    context =
      answer(context, %{
        "type" => "thread.metadata.update",
        "threadId" => World.thread_id(context, "t1"),
        "regenerateTitle" => true
      })

    World.await_state(context, "t1", fn state ->
      title =
        get_in(HalC2.StreamState.get(state, "thread"), [World.thread_id(context, "t1"), "title"])

      title == "codex title"
    end)

    context =
      answer(context, %{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, "t1")
      })

    World.await_latest_run(context, "t1", "interrupted")
    context
  end

  # --- cancelling provider work ------------------------------------------------------------

  step "a message to {string} was accepted and its provider turn has not started",
       %{args: [thread]} = context do
    context = World.providers(context)
    context = World.add_message(context, thread, "user", "hello")
    [%{"id" => message}] = HalC2.StreamState.list(World.state(context, thread), "message")

    context =
      World.add_run(context, thread, "starting", nil, %{
        "userMessageId" => message,
        "startedAt" => nil
      })

    Map.put(context, :methods_before, World.codex_methods(context))
  end

  step "the user interrupts {string}", %{args: [thread]} = context do
    context =
      answer(context, %{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, thread)
      })

    assert {:ok, _} = context.reply
    context
  end

  step "the provider turn is never started", context do
    World.await_runs(context, "t1", ["interrupted"])
    HalC2.Orchestration.start_next(World.thread_id(context, "t1"))
    :ok = HalC2.Orchestration.Effects.drain(World.thread_id(context, "t1"), 10_000)
    assert World.codex_methods(context) == context.methods_before
    assert HalC2.StreamState.list(World.state(context, "t1"), "provider-turn") == []
    context
  end

  step "a side effect of {string} is running", %{args: [thread]} = context do
    context = World.running_turn(context, thread)
    World.queue_message(context, thread, "next please")
  end

  step "a later command cancels it", context do
    context =
      answer(context, %{
        "type" => "run.interrupt",
        "threadId" => World.thread_id(context, "t1"),
        "runId" => context.running
      })

    assert {:ok, _} = context.reply
    context
  end

  step "it stops and is not tried again", context do
    World.await_runs(context, "t1", ["interrupted", "completed"])
    starts = Enum.count(World.codex_methods(context), &(&1 == "turn/start"))
    assert starts == 2
    context
  end

  step "the next side effect of {string} runs", %{args: [thread]} = context do
    statuses = context |> World.entities(thread, "run") |> Enum.map(& &1["status"])
    assert statuses == ["interrupted", "completed"]
    context
  end

  step "the user interrupted {string} just as its provider turn ended",
       %{args: [thread]} = context do
    context = World.providers(context)
    context = answer(context, World.message_command(context, thread, "hello"))
    state = World.await_runs(context, thread, ["completed"])
    [run] = HalC2.StreamState.list(state, "run")
    Map.put(context, :ended_run, run["id"])
  end

  step "the provider answers that the turn is not active", context do
    answer(context, %{
      "type" => "run.interrupt",
      "threadId" => World.thread_id(context, "t1"),
      "runId" => context.ended_run
    })
  end

  step "the interrupt is treated as done", context do
    assert {:ok, _} = context.reply
    context
  end

  step "it is not retried", context do
    [effect] =
      Enum.filter(effects(context, "t1"), &(&1["type"] == "provider-turn.interrupt"))

    assert effect["status"] == "done"
    assert effect["attempts"] == 1
    assert Enum.count(World.codex_methods(context), &(&1 == "turn/interrupt")) <= 1
    context
  end

  # --- provider capability refusals --------------------------------------------------------

  @abilities %{
    "queue messages behind an active run" => [:queued_messages],
    "take a message into an active run" => [:active_steering, :interrupt_restart_steering],
    "be interrupted and restarted with a message" => [:interrupt_restart_steering],
    "be interrupted" => [:interrupt],
    "fork a conversation natively" => [:fork],
    "fork from an earlier turn" => [:fork_from_turn],
    "say reliably when its runs finish" => [:strong_terminal_status]
  }

  step ~r/^"(?<thread>[^"]+)" runs on "(?<name>[^"]+)", which cannot (?<ability>.+)$/,
       %{args: [thread, name, ability]} = context do
    case ability do
      "rewind its conversation" -> rewind_setup(context, thread)
      "report its conversation after a rewind" -> snapshot_setup(context, thread, name)
      "receive a context handoff" -> handoff_setup(context, thread, name)
      _ -> policy_setup(context, thread, name, ability)
    end
  end

  # A provider plugin named as the scenario names it, declaring everything
  # except what this scenario takes away; the thread runs on it.
  defp policy_plugin(context, id, name, missing, source \\ nil) do
    capabilities = HalC2.Plugins.ProviderAdapter.capabilities() -- missing

    context
    |> World.providers()
    |> HalC2.Steps.Plugins.Fixtures.install(
      id,
      source || HalC2.Steps.Plugins.Fixtures.provider(id, name: name, capabilities: capabilities)
    )
    |> HalC2.Steps.Plugins.Fixtures.enable(id)
  end

  defp policy_setup(context, thread, name, ability) do
    missing = Map.fetch!(@abilities, ability)
    context = policy_plugin(context, "codexpolicy", name, missing)

    context =
      World.create_thread(context, "policy", "demo", %{
        "modelSelection" => %{"instanceId" => "codexpolicy", "model" => "codexpolicy-1"}
      })

    context = put_in(context, [:threads, thread], World.thread_id(context, "policy"))
    id = World.thread_id(context, thread)

    context =
      case ability do
        fork when fork in ["fork a conversation natively", "fork from an earlier turn"] ->
          context = answer(context, policy_message(id, "m1", "write a.txt"))
          assert {:ok, _} = context.reply
          World.await_runs(context, thread, ["completed"])

          if fork == "fork from an earlier turn" do
            context = answer(context, policy_message(id, "m2", "write b.txt"))
            assert {:ok, _} = context.reply
            World.await_runs(context, thread, ["completed", "completed"])
          end

          context

        _ ->
          context = answer(context, policy_message(id, "m1", "wait"))
          assert {:ok, _} = context.reply
          World.await_runs(context, thread, ["running"])
          context
      end

    Map.merge(context, %{ability: ability, instance: "codexpolicy"})
  end

  defp policy_message(thread_id, message_id, text, fields \\ %{}) do
    Map.merge(HalC2.Steps.Plugins.Turns.message(thread_id, message_id, text), fields)
  end

  # An Antigravity instance the user knows as Codex, with a checkpoint its
  # thread could be rewound to.
  defp rewind_setup(context, thread) do
    context = World.providers(context)

    World.merge_settings(%{
      "providerInstances" => %{
        "codexRewind" => %{"driver" => "antigravity", "displayName" => "Codex"}
      }
    })

    thread_id = World.thread_id(context, thread)
    scope = HalC2.Checkpoint.scope_id(thread_id)
    at = HalC2.Orchestration.Entities.now()
    provider_thread_id = "provider-thread:codexRewind:#{thread_id}"

    context =
      World.put_entity(context, thread, "provider-thread", provider_thread_id, %{
        "s" => %{
          "id" => provider_thread_id,
          "threadId" => thread_id,
          "providerInstanceId" => "codexRewind",
          "driver" => "antigravity",
          "nativeThreadRef" => %{
            "driver" => "antigravity",
            "nativeId" => "native-1",
            "strength" => "strong"
          },
          "status" => "idle",
          "createdAt" => at,
          "updatedAt" => at
        }
      })

    context =
      World.put_entity(context, thread, "checkpoint-scope", scope, %{
        "s" =>
          HalC2.Checkpoint.scope(
            thread_id,
            "run-1",
            "node-1",
            provider_thread_id,
            World.project(context, "demo").root,
            at
          )
      })

    checkpoint_id = HalC2.Checkpoint.checkpoint_id(scope, 1)

    context =
      World.put_entity(context, thread, "checkpoint", checkpoint_id, %{
        "s" => %{
          "id" => checkpoint_id,
          "threadId" => thread_id,
          "scopeId" => scope,
          "runId" => "run-1",
          "nodeId" => "node-1",
          "parentCheckpointId" => HalC2.Checkpoint.checkpoint_id(scope, 0),
          "ordinalWithinScope" => 1,
          "appRunOrdinal" => 1,
          "ref" => HalC2.Checkpoint.ref(scope, 1),
          "status" => "ready",
          "files" => [],
          "capturedAt" => at
        }
      })

    current = World.thread(context, thread)

    context =
      World.put_entity(context, thread, "thread", thread_id, %{
        "s" => Map.put(current, "activeProviderThreadId", provider_thread_id)
      })

    Map.merge(context, %{
      ability: "rewind its conversation",
      scope: scope,
      checkpoint: checkpoint_id
    })
  end

  # A provider that rewinds but reports nothing back, in its own worktree so
  # its turns take checkpoints.
  defp snapshot_setup(context, thread, name) do
    source =
      "codexpolicy"
      |> HalC2.Steps.Plugins.Fixtures.provider(
        name: name,
        capabilities: HalC2.Plugins.ProviderAdapter.capabilities()
      )
      |> String.replace(~s|{:ok, %{"nativeThreadRef" => nil}}|, "{:ok, %{}}")

    context = policy_plugin(context, "codexpolicy", name, [], source)
    work = World.git_repo(context, "snapshot-work")
    thread_id = "thread-snapshot-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.launch_thread(%{
        "commandId" => "cmd-#{thread_id}",
        "threadId" => thread_id,
        "projectId" => World.project(context, "demo").id,
        "title" => "Snapshot work",
        "modelSelection" => %{"instanceId" => "codexpolicy", "model" => "codexpolicy-1"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{
          "type" => "existing_worktree",
          "worktreePath" => work,
          "branch" => "main"
        },
        "initialMessage" => %{"messageId" => "m1", "text" => "write a.txt", "attachments" => []}
      })

    context = put_in(context, [:threads, thread], thread_id)
    World.await_runs(context, thread, ["completed"])
    context = answer(context, policy_message(thread_id, "m2", "write b.txt"))
    assert {:ok, _} = context.reply
    World.await_runs(context, thread, ["completed", "completed"])

    Map.merge(context, %{
      ability: "report its conversation after a rewind",
      instance: "codexpolicy"
    })
  end

  # The thread has a conversation on the built-in Codex; the named provider
  # is the one that would have to receive it.
  defp handoff_setup(context, thread, name) do
    context = policy_plugin(context, "codexpolicy", name, [:context_handoff])
    context = answer(context, World.message_command(context, thread, "hello"))
    assert {:ok, _} = context.reply
    World.await_runs(context, thread, ["completed"])
    Map.merge(context, %{ability: "receive a context handoff", instance: "codexpolicy"})
  end

  step "a client dispatches a command that needs it", context do
    id = World.thread_id(context, "t1")
    instance = context[:instance]

    command =
      case context.ability do
        "queue messages behind an active run" ->
          policy_message(id, "m2", "later", %{"dispatchMode" => %{"type" => "queue_after_active"}})

        "say reliably when its runs finish" ->
          policy_message(id, "m2", "later", %{"dispatchMode" => %{"type" => "queue_after_active"}})

        "take a message into an active run" ->
          policy_message(id, "m2", "use the red button", %{"deliveryIntent" => "steer"})

        "be interrupted and restarted with a message" ->
          policy_message(id, "m2", "start over", %{"deliveryIntent" => "restart"})

        "be interrupted" ->
          %{"type" => "run.interrupt", "threadId" => id}

        "fork a conversation natively" ->
          %{
            "type" => "thread.fork",
            "sourceThreadId" => id,
            "targetThreadId" => "fork-policy",
            "sourcePoint" => %{"type" => "latest_stable"},
            "forkStrategy" => "native_fork"
          }

        "fork from an earlier turn" ->
          [first | _] = World.entities(context, "t1", "run")

          %{
            "type" => "thread.fork",
            "sourceThreadId" => id,
            "targetThreadId" => "fork-policy",
            "sourcePoint" => %{"type" => "run", "runId" => first["id"]},
            "forkStrategy" => "native_fork"
          }

        "rewind its conversation" ->
          %{
            "type" => "checkpoint.rollback",
            "threadId" => id,
            "scopeId" => context.scope,
            "checkpointId" => context.checkpoint,
            "restoreFiles" => false
          }

        "report its conversation after a rewind" ->
          scope = HalC2.Checkpoint.scope_id(id)

          %{
            "type" => "checkpoint.rollback",
            "threadId" => id,
            "scopeId" => scope,
            "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope, 1)
          }

        "receive a context handoff" ->
          policy_message(id, "m2", "carry on", %{
            "modelSelection" => %{"instanceId" => instance, "model" => "codexpolicy-1"}
          })
      end

    answer(context, command)
  end

  step "{string} runs on {string} and has a turn running",
       %{args: [thread, _name]} = context do
    World.running_turn(context, thread)
  end

  step "a client sends a message in a way the provider supports no form of", context do
    answer(
      context,
      World.message_command(context, "t1", "into the void", %{
        "dispatchMode" => %{"type" => "steer_active", "targetRunId" => "run-not-active"}
      })
    )
  end

  step "{string} runs on a provider instance called {string} that cannot queue messages",
       %{args: [thread, instance]} = context do
    context = policy_plugin(context, instance, instance, [:queued_messages])

    context =
      World.create_thread(context, "policy", "demo", %{
        "modelSelection" => %{"instanceId" => instance, "model" => "#{instance}-1"}
      })

    context = put_in(context, [:threads, thread], World.thread_id(context, "policy"))
    id = World.thread_id(context, thread)
    context = answer(context, policy_message(id, "m1", "wait"))
    assert {:ok, _} = context.reply
    World.await_runs(context, thread, ["running"])
    context
  end

  step "a client queues a message behind the running turn of {string}",
       %{args: [thread]} = context do
    answer(
      context,
      policy_message(World.thread_id(context, thread), "m2", "later", %{
        "dispatchMode" => %{"type" => "queue_after_active"}
      })
    )
  end

  # --- the most specific reason ------------------------------------------------------------

  step "a command on {string} fails inside the provider with {string}",
       %{args: [thread, reason]} = context do
    wrapped = "Failed to dispatch orchestration command: #{reason}"

    source =
      "sandboxed"
      |> HalC2.Steps.Plugins.Fixtures.provider(
        name: "Codex",
        capabilities: HalC2.Plugins.ProviderAdapter.capabilities()
      )
      |> String.replace(
        "  def start_turn(thread_id, turn) do",
        "  def respond(_thread_id, _request_id, _response), do: raise(#{inspect(wrapped)})\n\n  def start_turn(thread_id, turn) do",
        global: false
      )

    context = policy_plugin(context, "sandboxed", "Codex", [], source)

    context =
      World.create_thread(context, "sandbox", "demo", %{
        "modelSelection" => %{"instanceId" => "sandboxed", "model" => "sandboxed-1"}
      })

    context = put_in(context, [:threads, thread], World.thread_id(context, "sandbox"))
    Map.put(context, :specific_reason, reason)
  end

  step "the failure reaches the client wrapped in the engine's general dispatch errors",
       context do
    answer(context, %{
      "type" => "runtime-request.respond",
      "threadId" => World.thread_id(context, "t1"),
      "requestId" => "request-sandbox",
      "decision" => "accept"
    })
  end

  step "the general {string} wrapper is not shown", %{args: [wrapper]} = context do
    assert {:error, message, _} = context.reply
    refute message =~ wrapper
    context
  end

  # --- small commands on a long thread -------------------------------------------------------

  # A long history for the control-read scenarios below, with history reads
  # traced from here on. The step itself lives with the projections steps,
  # whose windows use the same words for their own history.
  def long_history(context, thread) do
    context = World.providers(context)
    context = World.numbered_run(context, thread, 1, "completed")
    thread_id = World.thread_id(context, thread)
    at = World.iso_from_now(0)

    items =
      for i <- 1..1200 do
        {"turn-item", "turn-item:bulk-#{i}",
         %{
           "s" => %{
             "id" => "turn-item:bulk-#{i}",
             "threadId" => thread_id,
             "runId" => "run-1",
             "nodeId" => "node-run-1",
             "providerTurnId" => nil,
             "nativeItemRef" => nil,
             "parentItemId" => nil,
             "type" => "agent_message",
             "status" => "completed",
             "ordinal" => i,
             "startedAt" => at,
             "completedAt" => at,
             "updatedAt" => at
           }
         }}
      end

    messages =
      for i <- 1..300 do
        {"message", "msg-bulk-#{i}",
         %{
           "s" => %{
             "id" => "msg-bulk-#{i}",
             "threadId" => thread_id,
             "runId" => "run-1",
             "nodeId" => nil,
             "role" => "assistant",
             "text" => "old #{i}",
             "attachments" => [],
             "streaming" => false,
             "createdBy" => "agent",
             "creationSource" => "provider",
             "createdAt" => at,
             "updatedAt" => at
           }
         }}
      end

    {:ok, _} = HalC2.Streams.commit(thread_id, :thread, items ++ messages)
    HalC2.Streams.flush_shell(thread_id)
    # Warm the stream, as an open thread's stream is.
    _ = HalC2.Streams.state(thread_id)
    arm_reads()
    Map.put(context, :long_history, true)
  end

  # Traces history reads from here on; `collect_reads/0` answers them. The
  # reads whose cost grows with a thread are listing its messages or turn
  # items and replaying its log; a lookup of one entity by id (closing the
  # answered request's own item, say) costs the same on any thread.
  defp arm_reads do
    disarm_reads()
    drain_trace()

    :erlang.trace_pattern(
      {HalC2.StreamState, :list, 2},
      [{[:_, :"$1"], [{:orelse, {:==, :"$1", "message"}, {:==, :"$1", "turn-item"}}], []}],
      []
    )

    :erlang.trace_pattern({HalC2.Store, :reduce_stream, 5}, true, [])
    :erlang.trace_pattern({HalC2.Store, :reduce_stream, 6}, true, [])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    ExUnit.Callbacks.on_exit(fn -> disarm_reads() end)
    :ok
  end

  defp disarm_reads do
    :erlang.trace(:all, false, [:call])
    :erlang.trace_pattern({HalC2.StreamState, :list, 2}, false, [])
    :erlang.trace_pattern({HalC2.Store, :reduce_stream, 5}, false, [])
    :erlang.trace_pattern({HalC2.Store, :reduce_stream, 6}, false, [])
    :ok
  end

  defp drain_trace do
    receive do
      {:trace, _, :call, _} -> drain_trace()
    after
      0 -> :ok
    end
  end

  defp collect_reads do
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      5_000 -> :ok
    end

    collect_traced([])
  end

  defp collect_traced(acc) do
    receive do
      {:trace, _pid, :call, {module, fun, _args}} -> collect_traced([{module, fun} | acc])
    after
      0 -> acc
    end
  end

  # Answers `command` with history reads traced, kept in `context.reads`.
  # The window ends when the answer returns: what the command set going does
  # afterwards (a turn finishing, say) is not the command being decided.
  defp traced_answer(context, command) do
    arm_reads()
    context = answer(context, command)
    disarm_reads()
    reads = collect_reads()
    Map.merge(context, %{reads: reads, traced: true})
  end

  step "a client renames {string}", %{args: [thread]} = context do
    traced_answer(context, %{
      "type" => "thread.metadata.update",
      "threadId" => World.thread_id(context, thread),
      "title" => "Renamed"
    })
  end

  step "a client resumes the queue of {string}", %{args: [thread]} = context do
    thread_id = World.thread_id(context, thread)
    at = World.iso_from_now(0)

    run = fn id, ordinal, status, extra ->
      {"run", id,
       %{
         "s" =>
           Map.merge(
             %{
               "id" => id,
               "threadId" => thread_id,
               "ordinal" => ordinal,
               "providerInstanceId" => "codex",
               "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
               "providerThreadId" => nil,
               "userMessageId" => nil,
               "rootNodeId" => nil,
               "activeAttemptId" => nil,
               "status" => status,
               "queuePosition" => nil,
               "requestedAt" => at,
               "startedAt" => at,
               "completedAt" => nil,
               "checkpointId" => nil,
               "contextHandoffId" => nil
             },
             extra
           )
       }}
    end

    {:ok, _} =
      HalC2.Streams.commit(thread_id, :thread, [
        run.("run-active", 2000, "running", %{}),
        run.("run-queued", 2001, "queued", %{
          "queueHeld" => true,
          "queuePosition" => 1,
          "userMessageId" => "msg-bulk-1",
          "startedAt" => nil
        })
      ])

    HalC2.Streams.flush_shell(thread_id)
    traced_answer(context, %{"type" => "queue.resume", "threadId" => thread_id})
  end

  step "a client answers a pending request of {string}", %{args: [thread]} = context do
    context = answer(context, World.message_command(context, thread, "approve this"))
    assert {:ok, _} = context.reply
    request = World.await_request(context, thread)

    traced_answer(context, %{
      "type" => "runtime-request.respond",
      "threadId" => World.thread_id(context, thread),
      "requestId" => request["id"],
      "decision" => "accept"
    })
  end

  step "the command is accepted without the messages and turn items of {string} being read",
       %{args: [_thread]} = context do
    reads =
      if context[:traced] do
        context.reads
      else
        reads = collect_reads()
        disarm_reads()
        reads
      end

    assert {:ok, _} = context.reply
    assert reads == [], "history was read: #{inspect(reads)}"
    context
  end

  defp answer(context, command) do
    {reply, context} = World.dispatch(context, command)

    reply =
      case reply do
        {:ok, result} -> {:ok, result}
        {:error, error, detail} -> {:error, error, detail}
      end

    Map.put(context, :reply, reply)
  end

  defp visit(context, thread, hour, minute) do
    at = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(Time.new!(hour, minute, 0))

    %{
      "type" => "thread.visit",
      "threadId" => World.thread_id(context, thread),
      "visitedAt" => DateTime.to_iso8601(at)
    }
  end

  defp sequence(context, thread), do: World.state(context, thread).seq

  # Commits changes to the thread until its stream reaches `seq`.
  defp bump(context, thread, seq) do
    id = World.thread_id(context, thread)

    if sequence(context, thread) < seq do
      {:ok, _} = HalC2.Streams.commit(id, :thread, [{"thread", id, %{"s" => %{"bump" => seq}}}])
      bump(context, thread, seq)
    else
      sequence(context, thread)
    end
  end
end
