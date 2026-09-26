defmodule T3.Steps.Orchestration.LaunchingThreads do
  @moduledoc """
  Steps for features/node/orchestration/launching-threads.feature.

  A launch goes through `orchestration.launchThread` on the scenario's socket and
  names the thread it makes "new" (`context.thread`). A new worktree is held while
  it is prepared: the project's `post-checkout` hook and its blocking setup script
  each wait for a gate file (`context.gates`), which steps write with an exit code.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World

  @fake_text Path.expand("../../support/fake_text_cli.py", __DIR__)
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3>>

  # --- launching ---------------------------------------------------------------------

  step "a client launches a thread in {string} at the project root with message {string}",
       %{args: [project, text]} = context do
    launch(context, project, %{"initialMessage" => message(text)})
  end

  step "a client launches a thread in {string} at the project root on branch {string}",
       %{args: [project, branch]} = context do
    launch(context, project, %{"workspaceStrategy" => %{"type" => "root", "branch" => branch}})
  end

  step "a client launches a thread in {string} in existing worktree {string} on branch {string}",
       %{args: [project, path, branch]} = context do
    strategy = %{"type" => "existing_worktree", "worktreePath" => path, "branch" => branch}
    launch(context, project, %{"workspaceStrategy" => strategy})
  end

  step "a client launches a thread in {string} with no message", %{args: [project]} = context do
    launch(context, project, %{})
  end

  step "a client launches thread {string} with message {string}",
       %{args: [thread, text]} = context do
    fields = %{"threadId" => World.thread_id(context, thread), "initialMessage" => message(text)}
    context |> launch(nil, fields) |> Map.put(:thread, thread)
  end

  step "a client launches a thread with command {string} and message {string}",
       %{args: [command, text]} = context do
    launch(context, nil, %{"commandId" => command, "initialMessage" => message(text)})
  end

  step "a new thread exists in {string}", %{args: [project]} = context do
    assert World.thread(context, "new")["projectId"] == World.project(context, project).id
    context
  end

  step "the launch reports the thread was not resumed", context do
    assert {:ok, %{"resumed" => false}} = context.launch
    context
  end

  step "the launch reports the thread was resumed", context do
    assert {:ok, %{"resumed" => true}} = context.launch
    context
  end

  step "the new thread records branch {string}", %{args: [branch]} = context do
    assert %{"branch" => ^branch, "worktreePath" => nil} = World.thread(context, "new")
    context
  end

  step "the new thread records worktree {string} and branch {string}",
       %{args: [path, branch]} = context do
    assert %{"branch" => ^branch, "worktreePath" => ^path} = World.thread(context, "new")
    context
  end

  step "the thread has no runs", context do
    assert World.runs(context, "new") == []
    assert World.state(context, "new") |> T3.StreamState.list("message") == []
    context
  end

  step "{string} is sent to {string} like any other message", %{args: [text, thread]} = context do
    [run] = runs_when(context, thread, ["completed"])

    assert World.state(context, thread)
           |> T3.StreamState.get("message")
           |> Map.fetch!(run["userMessageId"])
           |> Map.fetch!("text") == text

    assert List.last(World.provider_prompts(context, "codex")) == text
    context
  end

  # The launch sent its first message as a command of its own: sending that command
  # id again is answered from the first outcome, with no second message.
  step "the first message is dispatched as command {string}", %{args: [id]} = context do
    runs_when(context, "new", ["completed"])
    command = World.message_command(context, "new", "Hello again", %{"commandId" => id})
    {reply, context} = World.dispatch(context, command)
    assert {:ok, %{"sequence" => _}} = reply

    assert [%{"text" => "Hello"}] =
             World.state(context, "new")
             |> T3.StreamState.list("message")
             |> Enum.filter(&(&1["role"] == "user"))

    context
  end

  # --- titles --------------------------------------------------------------------------

  step "the text generation model fails twice and then succeeds", context do
    text_model(context, 2, "Parser cleanup")
  end

  step "the text generation model answers {string}", %{args: [title]} = context do
    text_model(context, 0, title)
  end

  step "a client launches a thread with message {string} asking for a generated title",
       %{args: [text]} = context do
    titled_launch(context, text)
  end

  step "a client launches a thread asking for a generated title", context do
    titled_launch(context, "Tidy up the parser")
  end

  step "a client launches a thread with an empty message asking for a generated title",
       context do
    titled_launch(context, "")
  end

  # The fake text CLI answers "codex title".
  step "the thread is later retitled with a generated title", context do
    World.await_row(World.thread_id(context, "new"), &(&1["title"] == "codex title"), 5_000)
    assert [call] = text_calls(context)
    assert call["prompt"] =~ "Refactor the parser"
    context
  end

  # Node waits 2s and then 4s between attempts.
  step "the thread is retitled after the third attempt", context do
    World.await_row(World.thread_id(context, "new"), &(&1["title"] == "Parser cleanup"), 15_000)
    assert length(text_calls(context)) == 3
    assert System.monotonic_time(:millisecond) - context.launched_at >= 6_000
    context
  end

  step "the thread keeps its original title", context do
    await_title_tasks(context)
    assert [_] = text_calls(context)
    assert World.thread(context, "new")["title"] == "Launched"
    context
  end

  step "no title is generated", context do
    assert context.title_tasks == []
    assert text_calls(context) == []
    assert World.thread(context, "new")["title"] == "Launched"
    context
  end

  # --- new worktrees -----------------------------------------------------------------

  step "a client launches a thread in {string} in a new worktree with message {string}",
       %{args: [project, text]} = context do
    launch_in_worktree(context, project, text)
  end

  step "a launched thread's first run is preparing its worktree", context do
    context = launch_in_worktree(context, nil, "Hello")
    assert [%{"status" => "preparing"}] = await_run(context, "preparing")
    context
  end

  step "the first run is preparing", context do
    assert [%{"status" => "preparing"} = run] = await_run(context, "preparing")

    assert %{
             "type" => "command_execution",
             "status" => "running",
             "input" => "Preparing workspace"
           } =
             preparation_item(context, run)

    context
  end

  step "no turn starts yet", context do
    assert [%{"status" => "preparing"}] = World.runs(context, "new")
    assert World.state(context, "new") |> T3.StreamState.list("provider-turn") == []
    refute "turn/start" in World.codex_methods(context)
    context
  end

  step "the worktree and its setup script are ready", context do
    open_gate(context, :checkout, "0")
    open_gate(context, :setup, "0")
    context
  end

  step "the run starts with the message it was waiting with", context do
    [run] = runs_when(context, "new", ["completed"])

    message =
      World.state(context, "new")
      |> T3.StreamState.get("message")
      |> Map.fetch!(run["userMessageId"])

    assert message["text"] == "Hello"
    assert World.provider_prompts(context, "codex") == ["Hello"]
    assert preparation_item(context, run)["title"] == "Workspace ready"
    context
  end

  step "a baseline checkpoint is captured before the turn", context do
    state = World.state(context, "new")
    %{"worktreePath" => path} = World.thread(context, "new")
    [scope] = T3.StreamState.list(state, "checkpoint-scope")
    assert scope["cwd"] == path

    ordinals =
      state
      |> T3.StreamState.list("checkpoint")
      |> Enum.map(& &1["ordinalWithinScope"])
      |> Enum.sort()

    assert ordinals == [0, 1]
    World.git!(path, ["rev-parse", "--verify", T3.Checkpoint.ref(scope["id"], 0)])
    context
  end

  step "adding the worktree fails", context do
    open_gate(context, :checkout, "1")
    context
  end

  step "the thread can take its next message", context do
    assert World.thread(context, "new")["worktreePath"] == nil
    assert %{"status" => "completed", "ordinal" => 2} = World.finish_turn(context, "new", "Next")
    context
  end

  step "the user cancels the setup before the agent starts", context do
    thread_id = World.thread_id(context, "new")
    T3.WorktreeSetup.subscribe(thread_id, self())
    open_gate(context, :checkout, "0")
    snapshot = await_setup(thread_id, &(&1["setupScript"] != nil))
    assert File.dir?(snapshot["worktreePath"])
    {reply, context} = World.call(context, "worktreeSetup.cancel", %{"threadId" => thread_id})
    assert {:ok, %{"cancelled" => true}} = reply
    Map.put(context, :worktree_path, snapshot["worktreePath"])
  end

  step "the run is cancelled", context do
    assert [%{"status" => "cancelled"} = run] = await_run(context, "cancelled")
    assert preparation_item(context, run)["status"] == "cancelled"
    context
  end

  step "the new worktree is removed", context do
    refute File.exists?(context.worktree_path)
    World.await_row(World.thread_id(context, "new"), &(&1["worktreePath"] == nil))
    context
  end

  step "thread {string} has a run that already started", %{args: [thread]} = context do
    context = World.create_thread(context, thread, nil)
    run = World.finish_turn(context, thread, "Hi")
    assert run["status"] == "completed"
    Map.merge(context, %{thread: thread, started_run: run["id"]})
  end

  step "the node releases that run as prepared", context do
    thread_id = World.thread_id(context, context.thread)
    {:error, message} = T3.Orchestration.release_prepared(thread_id, context.started_run)
    Map.put(context, :reply, {:error, message, nil})
  end

  step "a client launches a thread in a new worktree of a project this node does not have",
       context do
    fields = %{
      "projectId" => "project-elsewhere",
      "workspaceStrategy" => %{"type" => "worktree", "baseRef" => "main"},
      "initialMessage" => message("Hello")
    }

    context = World.worktree_setup(context)

    {reply, context} =
      World.call(context, "orchestration.launchThread", input(context, nil, fields))

    Map.put(context, :reply, reply)
  end

  # --- attachments -------------------------------------------------------------------

  step "the user uploaded {string} but has not sent it", %{args: [name]} = context do
    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      T3.Attachments.create_upload_url(%{
        "name" => name,
        "mimeType" => "image/png",
        "sizeBytes" => byte_size(@png)
      })

    :ok = T3.Attachments.store(token, @png)
    Map.put(context, :upload, id)
  end

  step "a client launches a thread with message {string} attaching {string}",
       %{args: [text, name]} = context do
    attachment = %{
      "type" => "image",
      "id" => context.upload,
      "name" => name,
      "mimeType" => "image/png",
      "sizeBytes" => byte_size(@png)
    }

    launch(context, nil, %{"initialMessage" => message(text, [attachment])})
  end

  step "{string} belongs to the new thread", %{args: [name]} = context do
    [%{"attachments" => [attachment]}] = user_messages(context)
    assert attachment["name"] == name
    assert attachment["id"] != context.upload

    assert String.starts_with?(
             attachment["id"],
             String.replace(World.thread_id(context, "new"), ~r/[^a-zA-Z0-9_-]/, "-")
           )

    assert File.read!(T3.Attachments.path(attachment)) == @png
    context
  end

  step "the first message carries the attachment", context do
    [%{"attachments" => [attachment]} = message] = user_messages(context)
    assert message["text"] == "Look"
    [run] = runs_when(context, "new", ["completed"])
    assert run["userMessageId"] == message["id"]
    assert [prompt] = World.provider_prompts(context, "codex")
    assert prompt =~ T3.Attachments.path(attachment)
    context
  end

  # --- prepared-run commands ---------------------------------------------------------

  step "a client reports progress for the worktree phase and then the setup phase", context do
    Enum.reduce(["worktree", "setup"], context, fn phase, context ->
      context = prepared(context, "prepared-run.progress", %{"phase" => phase})
      Map.update(context, :phases, [item_title(context)], &(&1 ++ [item_title(context)]))
    end)
  end

  step "a client releases the prepared run", context do
    context = prepared(context, "prepared-run.release", %{})
    Map.update(context, :phases, [item_title(context)], &(&1 ++ [item_title(context)]))
  end

  step "the run records each phase and then starts", context do
    assert context.phases == ["Preparing worktree", "Starting setup script", "Workspace ready"]
    [run] = runs_when(context, "new", ["completed"])
    assert %{"status" => "completed", "exitCode" => 0} = preparation_item(context, run)
    assert World.provider_prompts(context, "codex") == ["Hello"]
    context
  end

  step "a client fails the prepared run with a failure description", context do
    failure = %{
      "class" => "provider_error",
      "message" => "The sandbox image could not be pulled.",
      "code" => "image_pull_failed",
      "retryable" => true
    }

    context
    |> prepared("prepared-run.fail", %{"failure" => failure})
    |> Map.put(:failure, failure)
  end

  step "the run is failed with that description", context do
    assert [%{"status" => "failed"} = run] = World.runs(context, "new")

    assert %{"status" => "failed", "output" => output, "exitCode" => 1} =
             preparation_item(context, run)

    assert output == context.failure["message"]

    assert [%{"failure" => failure, "status" => "failed"}] =
             World.state(context, "new")
             |> T3.StreamState.list("turn-item")
             |> Enum.filter(&(&1["type"] == "error"))

    assert failure == context.failure
    context
  end

  # --- after a restart ---------------------------------------------------------------

  step "no setup progress is reported for that thread", context do
    shape = %{
      "type" => "worktreeSetup",
      "node" => Atom.to_string(node()),
      "threadId" => World.thread_id(context, "new")
    }

    client = context.node |> Node.connect() |> Node.sub(7, shape)
    {frame, _client} = Node.await(client, &(&1["t"] == "worktreeSetup" and &1["id"] == 7))
    assert frame["event"] == nil
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp message(text, attachments \\ []),
    do: %{
      "messageId" => "msg-#{System.unique_integer([:positive])}",
      "text" => text,
      "attachments" => attachments
    }

  defp input(context, project, fields) do
    Map.merge(
      %{
        "commandId" => "cmd-launch-#{System.unique_integer([:positive])}",
        "threadId" => "th-new-#{System.unique_integer([:positive])}",
        "projectId" => World.project(context, project).id,
        "title" => "Launched",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"}
      },
      fields
    )
  end

  # Launches over the socket; the new thread is "new" unless it resumed one.
  defp launch(context, project, fields) do
    context = World.providers(context)
    input = input(context, project, fields)
    :ok = T3.Streams.subscribe(input["threadId"], self(), nil)
    {reply, context} = World.call(context, "orchestration.launchThread", input)
    assert {:ok, %{"threadId" => id}} = reply
    World.await_row(id, & &1)

    context = Map.put(context, :launch, reply)

    if Map.values(context.threads) |> Enum.member?(id),
      do: context,
      else: context |> put_in([:threads, "new"], id) |> Map.put(:thread, "new")
  end

  defp launch_in_worktree(context, project, text) do
    context = context |> World.worktree_setup() |> hold(project)
    strategy = %{"type" => "worktree", "baseRef" => "main"}

    launch(context, project, %{"workspaceStrategy" => strategy, "initialMessage" => message(text)})
  end

  # Holds preparation at the checkout (the project's post-checkout hook) and at its
  # blocking setup script until the step opens each gate with an exit code. Gates
  # left shut open with the scenario's end; the waits also stop when their
  # directory is gone.
  defp hold(context, project) do
    %{id: id, root: root} = World.project(context, project)
    dir = Node.tmp_dir(context.node, "gates")
    gates = %{checkout: Path.join(dir, "checkout"), setup: Path.join(dir, "setup")}

    for {name, gate} <- gates do
      File.write!(Path.join(dir, "#{name}.sh"), """
      i=0
      while [ ! -f '#{gate}' ] && [ -d '#{dir}' ] && [ $i -lt 1500 ]; do sleep 0.02; i=$((i+1)); done
      exit $(cat '#{gate}' 2>/dev/null || echo 1)
      """)
    end

    hook = Path.join([root, ".git", "hooks", "post-checkout"])
    File.mkdir_p!(Path.dirname(hook))
    File.write!(hook, "#!/bin/sh\nexec sh '#{Path.join(dir, "checkout.sh")}'\n")
    File.chmod!(hook, 0o755)

    ExUnit.Callbacks.on_exit(fn ->
      for {_, gate} <- gates, not File.exists?(gate), do: File.write(gate, "1")
    end)

    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => id,
        "scripts" => [
          %{
            "id" => "setup",
            "name" => "Setup",
            "command" => "sh '#{Path.join(dir, "setup.sh")}'",
            "icon" => "configure",
            "runOnWorktreeCreate" => true,
            "async" => false
          }
        ]
      })

    World.await_row(id, &match?([_], &1["scripts"]))
    Map.put(context, :gates, gates)
  end

  defp open_gate(context, name, code), do: File.write!(context.gates[name], code)

  defp await_run(context, status), do: runs_when(context, "new", [status])

  # The thread's runs once they have exactly `statuses`.
  defp runs_when(context, thread, statuses) do
    World.await_runs(context, thread, statuses, 10_000)
    World.runs(context, thread)
  end

  defp await_setup(thread_id, fun) do
    receive do
      {:t3_worktree_setup, ^thread_id, snapshot} ->
        if fun.(snapshot), do: snapshot, else: await_setup(thread_id, fun)
    after
      10_000 -> flunk("the worktree setup never got there")
    end
  end

  defp preparation_item(context, run) do
    World.state(context, "new")
    |> T3.StreamState.get("turn-item")
    |> Map.fetch!("turn-item:workspace-preparation:#{run["id"]}")
  end

  defp item_title(context), do: preparation_item(context, hd(World.runs(context, "new")))["title"]

  defp prepared(context, type, fields) do
    [run] = World.runs(context, "new")

    command =
      Map.merge(
        %{"type" => type, "threadId" => World.thread_id(context, "new"), "runId" => run["id"]},
        fields
      )

    {reply, context} = World.dispatch(context, command)
    assert {:ok, %{"sequence" => _}} = reply
    context
  end

  defp user_messages(context) do
    World.state(context, "new")
    |> T3.StreamState.list("message")
    |> Enum.filter(&(&1["role"] == "user"))
  end

  # Title generation runs `codex exec` through a per-scenario fake: it fails its
  # first `fails` calls and then answers `title`, logging each call.
  defp text_model(context, fails, title) do
    dir = Node.tmp_dir(context.node, "text")
    script = Path.join(dir, "codex")

    File.write!(script, """
    #!/usr/bin/env python3
    import json, os, sys
    args = sys.argv[1:]
    prompt = sys.stdin.read()
    with open(#{inspect(text_log(context))}, "a") as f:
        f.write(json.dumps({"argv": args, "prompt": prompt}) + "\\n")
    with open(#{inspect(text_log(context))}) as f:
        calls = len(f.read().splitlines())
    if calls <= #{fails}:
        sys.exit(1)
    with open(args[args.index("--output-last-message") + 1], "w") as f:
        f.write(json.dumps({"title": #{inspect(title)}, "needsRefinement": False}))
    """)

    File.chmod!(script, 0o755)
    use_text_command(script)
    Map.put(context, :text_model, script)
  end

  defp use_text_command(command) do
    previous = Application.get_env(:t3, :text_codex_command)
    Application.put_env(:t3, :text_codex_command, command)
    ExUnit.Callbacks.on_exit(fn -> restore_app_env(:text_codex_command, previous) end)
  end

  defp text_log(context), do: Path.join(context.node.home, "text-calls.jsonl")

  defp text_calls(context) do
    case File.read(text_log(context)) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  # Launches from this process, so the title generation it starts can be awaited.
  defp titled_launch(context, text) do
    context =
      if context[:text_model] do
        context
      else
        System.put_env("FAKE_TEXT_LOG", text_log(context))
        ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_TEXT_LOG") end)
        use_text_command(@fake_text)
        context
      end

    started = System.monotonic_time(:millisecond)

    context =
      World.launch_titled(context, "new", nil, text, %{
        "title" => "Launched",
        "generateTitle" => true
      })

    Map.merge(context, %{thread: "new", launched_at: started, title_tasks: title_tasks()})
  end

  # The title generation tasks this process started (`$callers`).
  defp title_tasks do
    me = self()

    for pid <- Process.list(),
        {:dictionary, dict} <- [Process.info(pid, :dictionary)],
        me in (dict[:"$callers"] || []),
        {T3.Orchestration, name, _} <- [dict[:"$initial_call"]],
        String.contains?(Atom.to_string(name), "generate_title"),
        do: pid
  end

  defp await_title_tasks(context) do
    for pid <- context.title_tasks do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
    end
  end

  # Puts an app env key back as it was; one that was unset stays unset (a nil value
  # would override `Application.get_env/3` defaults in later scenarios).
  defp restore_app_env(key, nil), do: Application.delete_env(:t3, key)
  defp restore_app_env(key, value), do: Application.put_env(:t3, key, value)
end
