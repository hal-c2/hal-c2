defmodule T3.Test.FakeAcp do
  @moduledoc """
  A scripted ACP agent (`test/support/fake_acp_scripted.py`) standing in for a
  provider CLI (Grok, OpenCode, Pi's adapter) in the provider features. Provider CLIs
  never run for real.

  `install/4` gives an instance its own fake: a directory with the script's
  `config.json` and `log.jsonl`, and an executable wrapper the instance's
  `binaryPath` points at, so the node builds the command line itself. The fake is
  kept under `context.fakes[instance]`; `context.provider` names the instance the
  scenario is about.
  """

  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World

  @script Path.expand("fake_acp_scripted.py", __DIR__)
  @instances ~w(grok opencode pi cursor)

  @run_test %{
    "permission" => %{
      "toolCallId" => "cmd-1",
      "title" => "npm test",
      "kind" => "execute",
      "rawInput" => %{"command" => "npm test"}
    }
  }

  # What the fake does with the prompts the steps send, unless a config says otherwise.
  @turns [
           %{
             "match" => "run a command",
             "steps" => [
               %{
                 "permission" => %{
                   "toolCallId" => "cmd-1",
                   "title" => "npm test",
                   "kind" => "execute",
                   "rawInput" => %{"command" => "npm test"}
                 }
               },
               %{"text" => "Ran it."}
             ]
           },
           %{
             "match" => "edit a file",
             "steps" => [
               %{
                 "permission" => %{
                   "toolCallId" => "edit-1",
                   "title" => "Edit src/app.ts",
                   "kind" => "edit",
                   "locations" => [%{"path" => "src/app.ts"}],
                   "rawInput" => %{"path" => "src/app.ts"}
                 }
               },
               %{"text" => "Edited it."}
             ]
           },
           %{
             "match" => "a long task",
             "steps" => [%{"text" => "Working on it."}, %{"waitCancel" => true}]
           },
           %{
             "match" => "run it twice",
             "steps" => [
               @run_test,
               put_in(@run_test, ["permission", "toolCallId"], "cmd-2"),
               %{"text" => "Ran both."}
             ]
           }
         ] ++
           for(
             {match, kind, path} <- [
               {"read a source file", "read", "src/app.ts"},
               {"read a file", "read", "src/app.ts"},
               {"read the .env file", "read", ".env"},
               {"read .env.example", "read", ".env.example"},
               {"work outside the project", "edit", "/etc/hosts"}
             ],
             do: %{
               "match" => match,
               "steps" => [
                 %{
                   "permission" => %{
                     "toolCallId" => "tool-1",
                     "title" => "#{kind} #{path}",
                     "kind" => kind,
                     "locations" => [%{"path" => path}],
                     "rawInput" => %{"path" => path}
                   }
                 },
                 %{"text" => "Done."}
               ]
             }
           )

  @doc "The fake's default turn scripts (see `@turns`), for configs that add their own."
  def turns, do: @turns

  @doc """
  Sets up a fake agent for `instance` with `config` (see the script). Options:
  `:enabled` (default false) and `:binary` (the wrapper's file name, default the
  instance id). The instance's `binaryPath` is the wrapper.
  """
  def install(context, instance, config \\ %{}, opts \\ []) do
    services()
    for id <- @instances, do: T3.Acp.forget(id)
    ExUnit.Callbacks.on_exit(fn -> for id <- @instances, do: T3.Acp.forget(id) end)

    dir = Node.tmp_dir(context.node, "fake-#{instance}")
    # OpenCode reports a version T3 Code supports unless the scenario says otherwise.
    config =
      if instance == "opencode", do: Map.put_new(config, "version", "1.14.19"), else: config

    File.write!(Path.join(dir, "config.json"), JSON.encode!(Map.put_new(config, "turns", @turns)))
    bin = Path.join([dir, "bin", opts[:binary] || instance])
    File.mkdir_p!(Path.dirname(bin))

    File.write!(bin, """
    #!/bin/sh
    export FAKE_DIR='#{dir}'
    exec python3 -u '#{@script}' "$@"
    """)

    File.chmod!(bin, 0o755)
    fake = %{dir: dir, bin: bin, instance: instance}

    settings(fn settings ->
      put_in(settings, [Access.key("providers", %{}), Access.key(instance, %{})], %{
        "enabled" => Keyword.get(opts, :enabled, false),
        "binaryPath" => bin
      })
    end)

    context
    |> Map.update(:fakes, %{instance => fake}, &Map.put(&1, instance, fake))
    |> Map.put(:provider, instance)
  end

  @doc """
  Pi's ACP adapter is installed from the ACP Registry; this runs the fake as that
  adapter instead (`:acp_commands`), with `pi_binary` as Pi's own binary path.
  """
  def pi_adapter(context, pi_binary) do
    fake = context.fakes["pi"]
    Application.put_env(:t3, :acp_commands, %{"pi" => [fake.bin]})
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :acp_commands) end)
    settings(&put_in(&1, ["providers", "pi", "binaryPath"], pi_binary))
    context
  end

  @doc "The services an ACP thread needs besides the node's own."
  def services do
    Node.ensure(T3.Settings)

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: T3.Acp.Registry}, id: :acp_registry)
    )

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: T3.Codex.Registry},
        id: :codex_registry
      )
    )

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: T3.Claude.Registry},
        id: :claude_registry
      )
    )

    Node.ensure(
      Supervisor.child_spec(
        {DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one},
        id: :codex_supervisor
      )
    )

    Node.ensure(T3.Acp.UrlAuth)
    :ok
  end

  @doc "Rewrites the settings document with `fun`."
  def settings(fun) do
    {settings, version} = T3.Settings.get()
    {:ok, _} = T3.Settings.put(fun.(settings), version)
    :ok
  end

  @doc "Replaces a fake's `config.json`; `fun` gets the current config."
  def configure(context, instance \\ nil, fun) do
    %{dir: dir} = fake(context, instance)
    path = Path.join(dir, "config.json")
    File.write!(path, JSON.encode!(fun.(JSON.decode!(File.read!(path)))))
    context
  end

  def fake(context, instance \\ nil),
    do: context.fakes[instance || context.provider] || flunk("no fake agent for #{instance}")

  @doc "Every line the fake logged: `%{\"start\" => ...}` and `%{\"recv\" => message}`."
  def log(context, instance \\ nil) do
    path = Path.join(fake(context, instance).dir, "log.jsonl")

    case File.read(path) do
      {:ok, body} -> for line <- String.split(body, "\n", trim: true), do: JSON.decode!(line)
      {:error, :enoent} -> []
    end
  end

  @doc "How the fake was started, each time: `%{\"argv\", \"cwd\", \"env\"}`."
  def starts(context, instance \\ nil),
    do: for(%{"start" => start} <- log(context, instance), do: start)

  @doc "The messages the fake received with `method` (or answers, for `nil`)."
  def received(context, method, instance \\ nil),
    do: for(%{"recv" => %{} = msg} <- log(context, instance), msg["method"] == method, do: msg)

  @doc "The fake's answer to its own request `method` (by the request's order)."
  def answers(context, instance \\ nil),
    do:
      for(
        %{"recv" => %{"id" => "fake-" <> _} = msg} <- log(context, instance),
        not Map.has_key?(msg, "method"),
        do: msg
      )

  @doc """
  Creates the thread `title` on the provider under test in the scenario's project,
  with `mode` as its runtime mode.
  """
  def thread(context, title \\ "Work", mode \\ "full-access", fields \\ %{}) do
    instance = context.provider

    context =
      World.create_thread(
        context,
        title,
        nil,
        Map.merge(
          %{
            "modelSelection" => %{"instanceId" => instance, "model" => "fake/one"},
            "runtimeMode" => mode
          },
          fields
        )
      )

    Map.put(context, :thread, title)
  end

  @doc "Sends a message in the scenario's thread; returns the context with the reply."
  def send_message(context, text, title \\ nil) do
    thread_id = World.thread_id(context, title || context.thread)

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "messageId" => "msg-#{System.unique_integer([:positive])}",
        "text" => text,
        "attachments" => []
      })

    context
  end

  @doc "Waits until the thread's latest run has `status`; returns the stream state."
  def await_run(context, status, title \\ nil) do
    World.await_stream(World.thread_id(context, title || context.thread), fn state ->
      case T3.StreamState.list(state, "run") |> Enum.max_by(& &1["requestedAt"], fn -> nil end) do
        %{"status" => ^status} -> state
        _ -> nil
      end
    end)
  end

  @doc "Waits until the thread has `count` runs that are all finished; returns the state."
  def await_runs(context, count, title \\ nil) do
    World.await_stream(World.thread_id(context, title || context.thread), fn state ->
      runs = T3.StreamState.list(state, "run")

      if length(runs) >= count and
           Enum.all?(runs, &(&1["status"] in ~w(completed failed interrupted cancelled))),
         do: state
    end)
  end

  @doc "Waits for a pending runtime request in the thread and returns it."
  def await_request(context, title \\ nil) do
    World.await_stream(World.thread_id(context, title || context.thread), fn state ->
      state
      |> T3.StreamState.list("runtime-request")
      |> Enum.find(&(&1["status"] == "pending"))
    end)
  end

  @doc "Answers a runtime request in the scenario's thread."
  def respond(context, request_id, response) do
    thread_id = World.thread_id(context, context.thread)

    {:ok, _} =
      T3.Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "runtime-request.respond",
            "commandId" => "cmd-#{System.unique_integer([:positive])}",
            "threadId" => thread_id,
            "requestId" => request_id
          },
          response
        )
      )

    context
  end

  @doc "The provider entry of `instance` in the node's provider list, or nil."
  def entry(instance), do: Enum.find(T3.Environment.providers(), &(&1["instanceId"] == instance))

  @doc "Reads the instance's agent again now (the probe `server.refreshProviders` runs)."
  def probe(instance) do
    T3.Acp.reload(instance)
    entry(instance)
  end

  @doc """
  Subscribes the scenario's socket to the node's config and returns
  `{providers, context}` from its first snapshot.
  """
  def open_config(context) do
    id = System.unique_integer([:positive])

    client =
      World.client(context)
      |> Node.sub(id, %{"type" => "config", "node" => Atom.to_string(node())})

    {frame, client} = Node.await(client, &(&1["t"] == "config" and &1["id"] == id))
    providers = frame["config"]["providers"]

    {providers,
     context |> World.put_client(client) |> Map.merge(%{config_sub: id, providers: providers})}
  end

  @doc """
  Waits for a `config.providers` push on the config subscription whose list
  satisfies `fun`; returns `{providers, context}`.
  """
  def await_providers(context, fun, timeout \\ 5_000) do
    context = if context[:config_sub], do: context, else: elem(open_config(context), 1)
    id = context.config_sub

    if fun.(context.providers) do
      {context.providers, context}
    else
      {frame, client} =
        Node.await(
          World.client(context),
          &(&1["t"] == "config.providers" and &1["id"] == id and fun.(&1["providers"])),
          timeout
        )

      {frame["providers"],
       context |> World.put_client(client) |> Map.put(:providers, frame["providers"])}
    end
  end

  @doc "Turns an instance on the way a client does: rewriting the settings over the socket."
  def enable(context, instance, enabled \\ true) do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "t3.readSettings")

    settings =
      put_in(
        settings,
        [Access.key("providers", %{}), Access.key(instance, %{}), "enabled"],
        enabled
      )

    {_, context} =
      World.call!(context, "t3.writeSettings", %{"settings" => settings, "version" => version})

    context
  end

  @doc "An instance's entry in a provider list."
  def find(providers, instance), do: Enum.find(providers || [], &(&1["instanceId"] == instance))

  @doc """
  Asserts that text generation ran the scenario's fake with every tool refused:
  the fake asks to read a file first and gets a cancellation, and it ran in a
  directory of its own rather than the project.
  """
  def assert_tools_refused(context) do
    assert [%{"result" => %{"outcome" => %{"outcome" => "cancelled"}}}] = answers(context)
    assert [%{"cwd" => cwd}] = starts(context)
    refute cwd == World.project(context).root
    :ok
  end
end
