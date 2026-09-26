defmodule HalC2.Steps.Orchestration.Commands do
  @moduledoc "Steps for `features/node/orchestration/commands.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

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
    shape = %{"type" => "stream", "node" => Atom.to_string(node()), "stream" => id}
    client = context.node |> Node.connect() |> Node.sub(9, shape)
    {frame, _client} = Node.await(client, &(&1["t"] == "live" and &1["id"] == 9))
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
      context.node.store
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
    context = World.put_client(context, Node.connect(context.node))
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
