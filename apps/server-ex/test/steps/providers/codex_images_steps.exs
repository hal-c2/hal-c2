defmodule HalC2.Steps.Providers.CodexImages do
  @moduledoc """
  Steps for the images Codex generates or a tool returns, and for partial
  answers, in `features/providers/codex.feature`. Codex runs on `fake_codex.py`,
  whose image and partial-answer turns are in `fake_codex_images.py`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Codex.GeneratedImages
  alias HalC2.StreamState
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @thread "Codex work"
  @png_magic <<137, 80, 78, 71>>

  # Codex runs with a home of the scenario's own, where it saves its images
  # and, with `sessions`, keeps its rollouts.
  defp codex_home(context, opts \\ []) do
    context = World.fake_providers(context)
    home = Mc.tmp_dir(context.mc, "codex-images-home")
    if opts[:sessions], do: World.put_os_env("FAKE_SESSIONS", "1")
    World.merge_settings(%{"providers" => %{"codex" => %{"homePath" => home}}})
    Map.put(context, :codex_home, home)
  end

  defp saved_image(context, name) do
    [path] = Path.wildcard(Path.join([context.codex_home, "generated_images", "*", name]))
    path
  end

  # --- generated images --------------------------------------------------------------------

  step "Codex generates an image with its image tool during a turn", context do
    context |> codex_home() |> World.launch_on(@thread, "codex", "draw a fox")
  end

  step "the turn finishes", context do
    World.await_runs(context, @thread, ["completed"])
    World.await_idle(context, @thread)
    context
  end

  step "the image is shown under Codex's final reply", context do
    shown = saved_image(context, "image-*-1.png")
    second = saved_image(context, "image-*-2.png")

    assert World.replies(context, @thread) == [
             "Here is the fox.\n\n![fox](#{shown})\n\n" <> GeneratedImages.embed(second)
           ]

    Map.put(context, :shown_image, shown)
  end

  step "an image the reply already shows is not shown twice", context do
    [reply] = World.replies(context, @thread)
    # Codex reported the shown image saved twice; the one that failed is not shown.
    assert length(String.split(reply, context.shown_image)) == 2
    refute reply =~ "-3.png"
    context
  end

  step "Codex is still generating an image when it sends its final reply", context do
    context = codex_home(context)
    gate = Mc.tmp_dir(context.mc, "codex-image-gate")
    World.put_os_env("FAKE_CODEX_GATE", gate)
    context = World.launch_on(context, @thread, "codex", "draw slowly")
    World.await_runs(context, @thread, ["completed"])
    assert World.replies(context, @thread) == ["The fox is on its way."]
    Map.put(context, :image_gate, gate)
  end

  step "the image is saved", context do
    File.write!(Path.join(context.image_gate, "image"), "")

    World.await_value(context, @thread, fn state ->
      Enum.any?(StreamState.list(state, "message"), &(&1["text"] =~ "![]("))
    end)

    context
  end

  step "the image is shown under that reply", context do
    path = saved_image(context, "image-*-late.png")
    embed = GeneratedImages.embed(path)
    assert World.replies(context, @thread) == ["The fox is on its way.\n\n" <> embed]

    # The turn item the reply belongs to says the same, and the run stays as it ended.
    assert [%{"text" => "The fox is on its way.\n\n" <> ^embed}] =
             for(
               item <- StreamState.list(World.stream(context, @thread), "turn-item"),
               item["type"] == "assistant_message",
               do: item
             )

    assert [%{"status" => "completed"}] = World.runs(context, @thread)
    context
  end

  # An image Codex saved on the MC's own disk, at a path written as Windows writes it.
  # A regex keeps the path as written: `{string}` would read a UNC path's `\\` as one.
  step ~r/^Codex saved a generated image at "(?<path>[^"]+)"$/, %{args: [path]} = context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "codex", "wait for me")

    World.await_running(context, @thread)
    World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))
    {_, runtime} = World.codex_runtime(context, @thread)
    ctx = %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
    image = %{"type" => "imageGeneration", "id" => "image-windows", "status" => "inProgress"}
    reply = %{"type" => "agentMessage", "id" => "msg-windows", "phase" => "final_answer"}

    for {method, item} <- [
          {"item/started", image},
          {"item/completed", Map.merge(image, %{"status" => "completed", "savedPath" => path})},
          {"item/started", Map.put(reply, "text", "")},
          {"item/completed", Map.put(reply, "text", "Here it is.")}
        ],
        do: World.codex_notify(context, @thread, method, Map.put(ctx, "item", item))

    World.codex_notify(context, @thread, "turn/completed", %{
      "turn" => %{"id" => ctx["turnId"], "status" => "completed"}
    })

    World.await_runs(context, @thread, ["completed"])
    Map.put(context, :saved_path, path)
  end

  step "the user reads the reply on the desktop, the phone or the terminal", context do
    [reply] = World.replies(context, @thread)
    Map.put(context, :reply_text, reply)
  end

  # Every client reads the embed's destination as the same file on the MC: a
  # drive path with forward slashes, a UNC path as a `file:` URL, never backslashes,
  # which a client's markdown would read as escapes.
  step "the image loads", context do
    assert ["Here it is.", "![](" <> rest] = String.split(context.reply_text, "\n\n")
    destination = String.trim_trailing(rest, ")")
    refute destination =~ "\\"
    # Read as a drive or UNC path, so no backslash went in percent-encoded.
    refute destination =~ "%5C"
    assert GeneratedImages.host_path(destination) == context.saved_path
    context
  end

  # --- images a tool returns -----------------------------------------------------------------

  step "a Codex tool call returns an image as embedded image data", context do
    context
    |> World.fake_providers()
    |> World.launch_on(@thread, "codex", "use a tool with an image")
    |> tap(&World.await_runs(&1, @thread, ["completed"]))
  end

  step "the user expands the tool call", context do
    tools =
      for item <- StreamState.list(World.stream(context, @thread), "turn-item"),
          item["type"] == "dynamic_tool",
          do: item

    assert [_, _] = tools
    Map.put(context, :tools, tools)
  end

  # Each tool's image is one of the thread's attachments, which a client loads
  # as it loads an image pasted into a message.
  step "the image is shown", context do
    for tool <- context.tools do
      assert [%{"type" => "image", "id" => id, "mimeType" => "image/png"}] =
               Enum.filter(tool["output"], &(&1["type"] == "image"))

      resource = %{
        "_tag" => "attachment",
        "threadId" => World.thread_id(context, @thread),
        "attachmentId" => id
      }

      assert {:ok, %{"relativeUrl" => "/api/assets/" <> url}} =
               HalC2.Attachments.create_url(%{"resource" => resource})

      token = url |> String.split("/") |> hd()
      assert {:ok, 200, _headers, {:stream, pid, ref}} = HalC2.Attachments.serve(token)
      send(pid, {ref, :start, self()})
      assert @png_magic <> _ = read_stream(pid, ref, "")
    end

    context
  end

  step "no image data text is shown", context do
    for tool <- context.tools do
      text = JSON.encode!(tool)
      refute text =~ "base64"
      refute text =~ "iVBORw0KGgo"
      assert Enum.any?(tool["output"], &(&1["type"] in ["inputText", "text"]))
    end

    context
  end

  defp read_stream(pid, ref, acc) do
    receive do
      {^ref, :chunk, bytes} ->
        send(pid, {ref, :ack})
        read_stream(pid, ref, acc <> bytes)

      {^ref, :done} ->
        acc
    after
      5_000 -> flunk("the image never arrived")
    end
  end

  # --- partial answers ------------------------------------------------------------------------

  step "Codex sends a partial answer and then a final answer with the same text in one turn",
       context do
    context
    |> World.fake_providers()
    |> World.launch_on(@thread, "codex", "answer in parts")
    |> tap(&World.await_runs(&1, @thread, ["completed"]))
  end

  defp answer_messages(context, title) do
    for message <- StreamState.list(World.stream(context, title), "message"),
        message["role"] == "assistant",
        do: {message["id"], message["text"]}
  end

  step "the thread keeps the partial answer", context do
    assert [{"message:codex:msg-partial-answer-" <> _, "The answer is 42."} | _] =
             answer_messages(context, @thread)

    context
  end

  step "the final answer is shown once", context do
    assert [_partial, {"message:codex:msg-final-answer-" <> _, "The answer is 42."}] =
             answer_messages(context, @thread)

    context
  end

  step "a Codex thread's history holds a partial answer", context do
    context
    |> codex_home(sessions: true)
    |> World.run_turns(@thread, "codex", ["answer in parts", "repeat after me"])
  end

  step "the user resumes the thread", context do
    # The app-server that held the thread is gone; the next message resumes it
    # from Codex's history.
    {_, runtime} = World.codex_runtime(context, @thread)
    ref = Process.monitor(runtime.conn)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    assert {_, %{conn: nil}} = World.codex_runtime(context, @thread)

    context
    |> World.post_message(@thread, "where are we")
    |> Map.put(:history_action, :resume)
  end

  # The MC reads a Codex thread's history from its rollout, as it does to
  # import a Codex session.
  step "the user reads the thread", context do
    [rollout] = Path.wildcard(Path.join(context.codex_home, "sessions/*/*/*/rollout-*.jsonl"))
    %{mtime: mtime} = File.stat!(rollout, time: :posix)
    read = HalC2.AgentSessions.parse(%{source: "codex", path: rollout, mtime: mtime})
    Map.merge(context, %{history_action: :read, history: read})
  end

  step "it succeeds with the whole history", context do
    case Map.get(context, :history_action, :fork) do
      :fork -> forked(context)
      :resume -> resumed(context)
      :read -> read(context)
    end
  end

  defp forked(context) do
    assert {:ok, _} = context.reply
    context = World.post_message(context, "fork", "where are we")

    World.await_value(context, "fork", fn state ->
      match?(
        [_, _, %{"status" => "completed"}],
        state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
      )
    end)

    whole_history(context, "fork")
  end

  defp resumed(context) do
    World.await_runs(context, @thread, ["completed", "completed", "completed"])
    whole_history(context, @thread)
  end

  # The thread shows the partial and the final answer, and Codex went on from a
  # history holding both turns.
  defp whole_history(context, title) do
    [partial, final, repeated, where] = World.replies(context, title)
    assert partial == "The answer is 42." and final == "The answer is 42."
    assert repeated =~ "repeat after me"
    assert where =~ "earlier [answer in parts | repeat after me]"
    context
  end

  defp read(context) do
    assert %{messages: messages} = context.history

    assert [
             {"user", "answer in parts"},
             {"assistant", "The answer is 42."},
             {"assistant", "The answer is 42."},
             {"user", "repeat after me"}
           ] = Enum.map(messages, &{to_string(&1.role), &1.text})

    context
  end
end
