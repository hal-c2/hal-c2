defmodule HalC2.Steps.Terminal.Errors do
  @moduledoc "Steps for `features/terminal/errors.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.{Terminal, World}

  # --- why a terminal cannot open ------------------------------------------------------------

  step ~r/^a client opens a terminal in "(?<folder>[^"]+)", which is (?<kind>missing|a file)$/,
       %{args: [path, kind]} = context do
    dir = Terminal.folder(context, path)

    if kind == "a file" do
      File.mkdir_p!(Path.dirname(dir))
      File.write!(dir, "# app\n")
    end

    {reply, context} = Terminal.open(context, %{"cwd" => dir})
    Map.merge(context, %{reply: reply, spec_folder: path})
  end

  step "opening fails with {string}", %{args: [message]} = context do
    expected =
      String.replace(message, context.spec_folder, Terminal.folder(context, context.spec_folder))

    assert {:error, ^expected, _detail} = context.reply
    context
  end

  step "no shell starts", context do
    %{"threadId" => thread, "terminalId" => terminal} = context.terminal
    assert Registry.lookup(HalC2.Terminal.Registry, {thread, terminal}) == []
    refute Enum.any?(HalC2.Terminal.Hub.summaries(), &(&1["threadId"] == thread))
    context
  end

  step "the MC cannot read its provider settings", context do
    file = Path.join(HalC2.Paths.config_dir(), "settings.json")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "{not json")
    Mc.ensure(HalC2.Settings)
    context
  end

  step "the open fails saying the settings cannot be read", context do
    assert {:error, message, %{"_tag" => "TerminalProviderEnvironmentError"}} = context.reply
    assert message =~ "settings.json cannot be read"
    context
  end

  step "the folder {string} cannot be read by the MC", %{args: [path]} = context do
    # The folder sits in a directory the MC may not enter.
    dir = Terminal.mkdir(context, path)
    parent = Path.dirname(dir)
    File.chmod!(parent, 0o000)
    ExUnit.Callbacks.on_exit(fn -> File.chmod(parent, 0o755) end)
    Map.put(context, :spec_folder, path)
  end

  step "a client opens a terminal in {string}", %{args: [path]} = context do
    {reply, context} = Terminal.open(context, %{"cwd" => Terminal.folder(context, path)})
    Map.put(context, :reply, reply)
  end

  step "opening fails with {string} and the reason", %{args: [message]} = context do
    expected =
      String.replace(message, context.spec_folder, Terminal.folder(context, context.spec_folder))

    assert {:error, error, %{"_tag" => "TerminalCwdStatError"}} = context.reply
    assert error == expected <> " (eacces)"
    context
  end

  step "the MC's machine has no login shell, zsh, bash or sh", context do
    context = Terminal.ensure(context)
    Terminal.put_env("SHELL", nil)

    Application.put_env(
      :hal_c2,
      :terminal_shells,
      Enum.map(~w(/bin/zsh /bin/bash /bin/sh), &Terminal.folder(context, &1))
    )

    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :terminal_shells) end)
    context
  end

  step "attached clients receive the error {string} naming each shell it tried",
       %{args: [message]} = context do
    {event, context} = Terminal.await_event(context, "default", &(&1["type"] == "error"))
    assert event["message"] =~ message

    for shell <- ~w(/bin/zsh /bin/bash /bin/sh),
        do: assert(event["message"] =~ Terminal.folder(context, shell))

    context
  end

  step "the terminal is marked as failed", context do
    %{"threadId" => thread, "terminalId" => terminal} = context.terminal
    # A client attaching later sees it; the attach also orders after the hub update.
    {snapshot, context} = Terminal.attach!(context, "later", Map.delete(context.terminal, "cwd"))
    assert snapshot["status"] == "error"

    assert Enum.any?(
             HalC2.Terminal.Hub.summaries(),
             &match?(%{"threadId" => ^thread, "terminalId" => ^terminal, "status" => "error"}, &1)
           )

    context
  end

  # --- a terminal that is not running or does not exist --------------------------------------

  step "a terminal whose shell has exited", context do
    Terminal.exited(context, "done")
  end

  step "a client writes {string} to it", %{args: [data]} = context do
    {reply, context} =
      World.call(context, "terminal.write", Map.put(session(context), "data", data <> "\n"))

    Map.put(context, :reply, reply)
  end

  step "the write fails because the terminal is not running", context do
    assert {:error, message, %{"_tag" => "TerminalNotRunningError"}} = context.reply
    assert message =~ "Terminal is not running"
    context
  end

  step ~r/^a client asks to (?<action>write|resize|clear) a terminal the thread does not have$/,
       %{args: [action]} = context do
    context = Terminal.ensure(context)
    target = %{"threadId" => "th-none", "terminalId" => "term-9"}

    payload =
      case action do
        "write" -> Map.put(target, "data", "ls\n")
        "resize" -> Map.merge(target, %{"cols" => 80, "rows" => 24})
        "clear" -> target
      end

    {reply, context} = World.call(context, "terminal.#{action}", payload)
    Map.put(context, :reply, reply)
  end

  step "the request fails naming the unknown thread and terminal", context do
    assert {:error, "Unknown terminal thread: th-none, terminal: term-9",
            %{"_tag" => "TerminalSessionLookupError"}} = context.reply

    context
  end

  step "a client restarts a terminal the thread does not have, in {string}",
       %{args: [path]} = context do
    context = Terminal.ensure(context)
    input = Terminal.input(context, %{"cwd" => Terminal.mkdir(context, path)})

    assert Registry.lookup(HalC2.Terminal.Registry, {input["threadId"], input["terminalId"]}) ==
             []

    {{:ok, snapshot}, context} = World.call(context, "terminal.restart", input)
    context |> Terminal.put_input(input) |> Map.put(:snapshot, snapshot)
  end

  step "a client closes a terminal the thread does not have", context do
    context = Terminal.ensure(context)
    # Another thread's terminal, which must be left alone.
    {snapshot, context} = Terminal.open!(context)

    {reply, context} =
      World.call(context, "terminal.close", %{"threadId" => "th-none", "terminalId" => "term-9"})

    Map.merge(context, %{reply: reply, snapshot: snapshot})
  end

  step "the request succeeds and nothing changes", context do
    assert {:ok, nil} = context.reply
    %{"threadId" => thread} = context.terminal
    assert [%{"threadId" => ^thread, "status" => "running"}] = HalC2.Terminal.Hub.summaries()
    context
  end

  step "a client attaches to a terminal the thread does not have, without giving a folder",
       context do
    context = Terminal.ensure(context)

    {frame, context} =
      Terminal.attach(context, "default", %{"threadId" => "th-none", "terminalId" => "term-9"})

    Map.put(context, :frame, frame)
  end

  step "the attach fails naming the unknown thread and terminal", context do
    assert %{
             "t" => "error",
             "reason" => "Unknown terminal thread: th-none, terminal: term-9",
             "detail" => %{"_tag" => "TerminalSessionLookupError"}
           } = context.frame

    context
  end

  step "a client is closing a terminal", context do
    {_, context} = Terminal.open!(context)
    # Both clients are connected before either sends, so the two closes land together.
    context = World.put_client(context, "second", World.client(context, "second"))
    send_close(context, "first", :closing)
  end

  step "another client closes the same terminal at the same moment", context do
    send_close(context, "second", :racing)
  end

  step "both requests succeed", context do
    for {name, id} <- [{"first", context.closing}, {"second", context.racing}], reduce: context do
      context ->
        {frame, client} = Mc.await(World.client(context, name), Mc.reply?(id))
        assert %{"t" => "rpc.result", "result" => nil} = frame
        World.put_client(context, name, client)
    end
    |> tap(fn %{terminal: t} ->
      assert Registry.lookup(HalC2.Terminal.Registry, {t["threadId"], t["terminalId"]}) == []
    end)
  end

  # --- listing ------------------------------------------------------------------------------

  step "a thread with saved terminals 1 and 2", context do
    context = Terminal.ensure(context)

    for id <- ["term-2", "term-1"], reduce: context do
      context ->
        {_, context} = Terminal.open!(context, %{"terminalId" => id})
        {{:ok, nil}, context} = World.call(context, "terminal.close", session(context))
        context
    end
  end

  step "a client lists the thread's terminals", context do
    {reply, context} =
      World.call(context, "terminal.list", %{"threadId" => context.terminal["threadId"]})

    Map.put(context, :reply, reply)
  end

  step "it receives terminals 1 and 2", context do
    assert {:ok, %{"terminalIds" => ["term-1", "term-2"]}} = context.reply
    context
  end

  # --- helpers ------------------------------------------------------------------------------

  defp session(context), do: Map.take(context.terminal, ["threadId", "terminalId"])

  defp send_close(context, name, key) do
    id = System.unique_integer([:positive])

    client =
      Mc.rpc(
        World.client(context, name),
        context.mc.environment,
        id,
        "terminal.close",
        session(context)
      )

    context |> World.put_client(name, client) |> Map.put(key, id)
  end

  # --- provider instances ---------------------------------------------------------------------

  step ~r/^no provider instance "(?<id>[^"]+)" is configured(?: and none is built in under that name)?$/,
       %{args: [id]} = context do
    context = Terminal.ensure(context)
    assert get_in(HalC2.Settings.settings(), ["providerInstances", id]) == nil
    context
  end

  # Shared with `sessions.feature`.
  step "a client opens a terminal for the provider instance {string}",
       %{args: [id]} = context do
    {reply, context} = Terminal.open(context, %{"providerInstanceId" => id})

    case reply do
      {:ok, snapshot} ->
        Terminal.await_prompt(context.terminal, snapshot["history"])
        {_, context} = Terminal.attach!(context, "default", session(context))
        Map.merge(context, %{reply: reply, snapshot: snapshot, first: snapshot})

      _refused ->
        Map.put(context, :reply, reply)
    end
  end

  step "the open fails with {string}", %{args: [message]} = context do
    assert {:error, ^message, _detail} = context.reply
    context
  end

  step "no shell is started", context do
    %{"threadId" => thread, "terminalId" => terminal} = context.terminal
    assert Registry.lookup(HalC2.Terminal.Registry, {thread, terminal}) == []
    refute Enum.any?(HalC2.Terminal.Hub.summaries(), &(&1["threadId"] == thread))
    context
  end

  step "a client attaches to {string} in {string} for the provider instance {string}",
       %{args: [terminal, path, id]} = context do
    input =
      Terminal.input(context, %{
        "terminalId" => terminal,
        "cwd" => Terminal.mkdir(context, path),
        "providerInstanceId" => id
      })

    {frame, context} = Terminal.attach(context, "default", input)
    context |> Terminal.put_input(input) |> Map.put(:frame, frame)
  end

  step "the attach fails with {string}", %{args: [message]} = context do
    assert %{"t" => "error", "reason" => ^message} = context.frame
    context
  end

  step "a terminal running for the provider instance {string}", %{args: [id]} = context do
    World.merge_settings(%{"providerInstances" => %{id => %{"driver" => "codex"}}})
    {snapshot, context} = Terminal.open!(context, %{"providerInstanceId" => id})
    Map.merge(context, %{first: snapshot, snapshot: snapshot})
  end

  step "the provider instance {string} has since been removed", %{args: [id]} = context do
    {settings, version} = HalC2.Settings.get()

    {:ok, _} =
      HalC2.Settings.put(update_in(settings["providerInstances"], &Map.delete(&1, id)), version)

    context
  end

  step "a client attaches to it asking to restart it if it is not running", context do
    input = Map.put(context.terminal, "restartIfNotRunning", true)
    {snapshot, context} = Terminal.attach!(context, "later", input)
    Map.put(context, :snapshot, snapshot)
  end

  step "the client receives the terminal's snapshot", context do
    assert context.snapshot["status"] == "running"
    assert context.snapshot["terminalId"] == context.terminal["terminalId"]
    context
  end

  step "the running shell is not restarted", context do
    assert context.snapshot["pid"] == context.first["pid"]
    assert File.exists?("/proc/#{context.first["pid"]}")
    context
  end

  step ~r/^a thread with saved terminals "term-10", "term-2" and "default"$/, context do
    context = Terminal.ensure(context)

    for id <- ["term-10", "term-2", "default"], reduce: context do
      context ->
        {_, context} = Terminal.open!(context, %{"terminalId" => id})
        {{:ok, nil}, context} = World.call(context, "terminal.close", session(context))
        context
    end
  end

  step ~r/^it receives them as "default", "term-2" and "term-10"$/, context do
    assert {:ok, %{"terminalIds" => ["default", "term-2", "term-10"]}} = context.reply
    context
  end
end
