defmodule HalC2.ClaudeNeverStartedTest do
  # Claude reports usage only with the result that ends the user's turn, so a prompt it
  # ends unstarted drops the handoff's reserve (#1735) only where nothing else in the
  # run could have been answered: an answer the MC was never told the size of still
  # fills the conversation.
  use ExUnit.Case, async: false

  alias HalC2.Claude.ThreadRuntime
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @moduletag :tmp_dir
  @thread "Build"

  setup %{tmp_dir: dir} do
    context =
      %{mc: Mc.start(dir), clients: %{}, projects: %{}, threads: %{}}
      |> World.create_project("shop")
      |> then(&World.put_client(&1, World.client(&1)))
      |> World.fake_providers()
      # The fake takes the prompt and neither starts nor ends it.
      |> World.launch_on(@thread, "claudeAgent", "wait")

    World.await_value(context, @thread, fn state ->
      HalC2.StreamState.list(state, "provider-turn") != []
    end)

    id = World.thread_id(context, @thread)
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, id)
    %{turn: %{ids: ids, prompt: prompt}} = :sys.get_state(pid)
    {:ok, context: context, id: id, pid: pid, run: ids.run, uuid: prompt.uuid}
  end

  test "a prompt that ended unstarted, with no answer, keeps no reserve", context do
    assert never_started?(context)
  end

  test "an answer in the run keeps its reserve", context do
    claude(context, %{
      "type" => "assistant",
      "message" => %{"id" => "own", "content" => [%{"type" => "text", "text" => "Done"}]}
    })

    refute never_started?(context)
  end

  test "an answer Claude began streaming keeps its reserve", context do
    stream(context, %{"type" => "message_start", "message" => %{"id" => "partial"}})

    stream(context, %{
      "type" => "content_block_start",
      "index" => 0,
      "content_block" => %{"type" => "text", "text" => ""}
    })

    refute never_started?(context)
  end

  test "an answer begun with no text yet keeps its reserve", context do
    stream(context, %{"type" => "message_start", "message" => %{"id" => "partial"}})
    refute never_started?(context)
  end

  test "a result of a turn Claude ran on its own keeps its reserve", context do
    claude(context, %{
      "type" => "result",
      "subtype" => "success",
      "user_message_uuids" => ["another-prompt"]
    })

    refute never_started?(context)
  end

  test "a steer sent into the run keeps its reserve", context do
    message = %{text: "wait for the tests", attachments: [], priority: :next}
    assert :ok = ThreadRuntime.steer(context.id, context.run, message)
    refute never_started?(context)
  end

  test "a wake the run took over and Claude still runs keeps its reserve", context do
    :sys.replace_state(context.pid, &%{&1 | wake: %{open: true, buffer: []}})
    refute never_started?(context)
  end

  test "a wake that ended in the run keeps its reserve", context do
    :sys.replace_state(context.pid, &%{&1 | wake: %{open: true, buffer: []}})
    claude(context, %{"type" => "result", "subtype" => "success"})
    refute never_started?(context)
  end

  # Claude ends the prompt unstarted; whether the run records that no answer follows.
  defp never_started?(%{context: world, uuid: uuid} = context) do
    claude(context, %{
      "type" => "command_lifecycle",
      "command_uuid" => uuid,
      "state" => "completed"
    })

    World.await_runs(world, @thread, ["failed"])
    [run] = World.runs(world, @thread)
    run["turnNeverStarted"] == true
  end

  defp stream(context, event),
    do: claude(context, %{"type" => "stream_event", "event" => event})

  defp claude(%{pid: pid}, message),
    do: send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
end
