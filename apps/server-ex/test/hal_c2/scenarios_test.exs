defmodule HalC2.ScenariosTest do
  @moduledoc """
  End-to-end behavior a client sees over the protocol 3 socket, one scenario per
  test. Everything runs on this node with its own store; no provider runs.
  """
  use ExUnit.Case, async: false

  alias HalC2.Test.WsClient

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :port, 0)
    :persistent_term.erase({HalC2.Web, :token})
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Auth)
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(HalC2.Web))
    [{_node, %{"environmentId" => environment}}] = HalC2.Shell.environments()
    %{port: port, environment: environment, store: Path.join(dir, "hal-c2.sqlite")}
  end

  defp connect(port, query \\ nil) do
    {:ok, client} = WsClient.connect(port, "/ws?" <> (query || "token=#{HalC2.Web.token()}"))
    {%{"t" => "hello", "protocol" => 3}, client} = WsClient.recv(client, 1_000)
    client
  end

  defp sub(client, id, shape),
    do: WsClient.send_json(client, %{"t" => "sub", "id" => id, "shape" => shape})

  defp rpc(client, environment, id, method, payload) do
    WsClient.send_json(client, %{
      "t" => "rpc",
      "id" => id,
      "environment" => environment,
      "method" => method,
      "payload" => payload
    })
  end

  defp await(client, fun) do
    {frame, _skipped, client} = WsClient.recv_until(client, fun)
    {frame, client}
  end

  # The first frame matching each predicate, in predicate order, whatever order
  # they arrive in (an RPC's reply and the push it causes race).
  defp await_all(client, preds), do: await_all(client, Enum.with_index(preds), %{})

  defp await_all(client, [], found),
    do: {found |> Enum.sort() |> Enum.map(&elem(&1, 1)), client}

  defp await_all(client, pending, found) do
    {frame, client} = WsClient.recv(client, 2_000)

    case Enum.find(pending, fn {pred, _} -> pred.(frame) end) do
      nil ->
        await_all(client, pending, found)

      {_, index} = hit ->
        await_all(client, List.delete(pending, hit), Map.put(found, index, frame))
    end
  end

  defp reply?(id), do: &(&1["t"] in ["rpc.result", "rpc.error"] and &1["id"] == id)

  defp config(client, id) do
    client = sub(client, id, %{"type" => "config", "node" => Atom.to_string(node())})
    {_, client} = await(client, &(&1["t"] == "config.usageLimitSources" and &1["id"] == id))
    client
  end

  test "Given two clients on one node, when one writes settings at the version it read, then the other sees them and a stale write is refused",
       %{port: port, environment: env} do
    start_supervised!(HalC2.Settings)
    writer = connect(port) |> config(1)
    reader = connect(port) |> config(1)

    writer = rpc(writer, env, 2, "hal-c2.readSettings", %{})

    {%{"t" => "rpc.result", "result" => %{"settings" => %{}, "version" => version}}, writer} =
      await(writer, reply?(2))

    doc = %{"enableAssistantStreaming" => false}

    writer =
      rpc(writer, env, 3, "hal-c2.writeSettings", %{"settings" => doc, "version" => version})

    {%{"t" => "rpc.result", "result" => %{"version" => next}}, writer} = await(writer, reply?(3))
    assert next == version + 1

    assert {%{"t" => "config.settings", "settings" => ^doc}, _} =
             await(reader, &(&1["t"] == "config.settings"))

    # The same starting point a second time is a lost update.
    writer =
      rpc(writer, env, 4, "hal-c2.writeSettings", %{"settings" => %{}, "version" => version})

    assert {%{
              "t" => "rpc.error",
              "error" => "settings changed",
              "detail" => %{"_tag" => "StaleSettings"}
            }, _} = await(writer, reply?(4))
  end

  test "Given a client following config, when it adds and then removes a keybinding, then each change comes back as the whole rule list",
       %{port: port, environment: env} do
    start_supervised!(HalC2.Settings)
    client = connect(port) |> config(1)
    rule = %{"key" => "mod+j", "command" => "terminal.toggle"}

    client = rpc(client, env, 2, "hal-c2.upsertKeybinding", rule)

    {[%{"t" => "rpc.result", "result" => %{"rules" => [^rule]}}, pushed], client} =
      await_all(client, [reply?(2), &(&1["t"] == "config.keybindings")])

    assert %{"id" => 1, "rules" => [^rule]} = pushed

    client = rpc(client, env, 3, "hal-c2.removeKeybinding", rule)

    assert {[%{"t" => "rpc.result"}, %{"t" => "config.keybindings", "rules" => []}], _} =
             await_all(client, [reply?(3), &(&1["t"] == "config.keybindings")])
  end

  test "Given a client following the shell, when it creates, archives, and unarchives a thread, then the sidebar and the archived list follow each step",
       %{port: port, environment: env} do
    client = connect(port) |> sub(1, %{"type" => "shell"})
    {%{"t" => "shell"}, client} = WsClient.recv(client, 1_000)
    thread = "th-#{System.unique_integer([:positive])}"
    row? = fn pred -> &(&1["t"] == "shell.rows" and Enum.any?(&1["rows"], pred)) end

    client =
      rpc(client, env, 2, "orchestration.dispatchCommand", %{
        "type" => "thread.create",
        "commandId" => "cmd-1",
        "threadId" => thread,
        "title" => "Scenario"
      })

    {[%{"t" => "rpc.result"}, _], client} =
      await_all(client, [
        reply?(2),
        row?.(&match?([^thread, "thread", %{"title" => "Scenario"}], &1))
      ])

    archived? = row?.(&match?([^thread, "thread", %{"archivedAt" => at}] when is_binary(at), &1))

    client =
      rpc(client, env, 3, "orchestration.dispatchCommand", %{
        "type" => "thread.archive",
        "commandId" => "cmd-2",
        "threadId" => thread
      })

    {[%{"t" => "rpc.result"}, _], client} = await_all(client, [reply?(3), archived?])

    client = rpc(client, env, 4, "orchestration.getArchivedShellSnapshot", %{})
    {%{"result" => %{"threads" => threads}}, client} = await(client, reply?(4))
    assert [^thread] = Enum.map(threads, & &1["id"])

    # The way back out.
    client =
      rpc(client, env, 5, "orchestration.dispatchCommand", %{
        "type" => "thread.unarchive",
        "commandId" => "cmd-3",
        "threadId" => thread
      })

    {[%{"t" => "rpc.result"}, _], client} =
      await_all(client, [
        reply?(5),
        row?.(&match?([^thread, "thread", %{"archivedAt" => nil}], &1))
      ])

    client = rpc(client, env, 6, "orchestration.getArchivedShellSnapshot", %{})
    assert {%{"result" => %{"threads" => []}}, _} = await(client, reply?(6))
  end

  test "Given an administrator following access, when a pairing link is created, revoked, and a device pairs, then each change arrives and the revoked link no longer pairs",
       %{port: port, store: store} do
    client = connect(port) |> sub(1, %{"type" => "authAccess"})

    {%{"t" => "authAccess", "event" => %{"type" => "snapshot", "payload" => snapshot}}, client} =
      WsClient.recv(client, 1_000)

    assert %{"pairingLinks" => [], "clientSessions" => []} = snapshot

    {:ok, %{"id" => link, "credential" => credential}} =
      HalC2.Auth.create_pairing_link(%{"label" => "Phone"})

    {%{"event" => %{"type" => "pairingLinkUpserted", "payload" => upserted}}, client} =
      WsClient.recv(client, 1_000)

    assert %{"id" => ^link, "label" => "Phone", "subject" => "pairing-link"} = upserted
    refute Map.has_key?(upserted, "credential")

    assert HalC2.Auth.revoke_pairing_link(link)

    {%{"event" => %{"type" => "pairingLinkRemoved", "payload" => %{"id" => ^link}}}, client} =
      WsClient.recv(client, 1_000)

    assert HalC2.Auth.exchange(credential) == :error

    {:ok, _access, _expires, _scopes} =
      HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(store), %{"label" => "Laptop"})

    assert {%{"event" => %{"type" => "clientUpserted"}}, _} =
             await(client, &(&1["event"]["type"] == "clientUpserted"))
  end

  test "Given a device paired with standard scopes, when it asks to follow access, then only that subscription fails and its socket keeps working",
       %{port: port, store: store} do
    {:ok, access, _expires, scopes} = HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(store))
    refute "access:read" in scopes
    {:ok, ticket, _} = HalC2.Auth.issue_ticket(access)

    client = connect(port, "wsTicket=#{ticket}") |> sub(1, %{"type" => "authAccess"})

    assert {%{"t" => "error", "id" => 1, "reason" => "access:read is required"}, client} =
             WsClient.recv(client, 1_000)

    client = sub(client, 2, %{"type" => "shell"})
    assert {%{"t" => "shell", "id" => 2}, _} = WsClient.recv(client, 1_000)
  end

  test "Given two thread subscriptions, when the client drops one, then later changes to it send nothing while the other keeps streaming",
       %{port: port} do
    me = Atom.to_string(node())

    for stream <- ~w(th-dropped th-kept),
        do:
          {:ok, _} =
            HalC2.Streams.commit(stream, :thread, [{"turn-item", "i1", %{"s" => %{"text" => ""}}}])

    client =
      connect(port)
      |> sub(1, %{"type" => "stream", "node" => me, "stream" => "th-dropped"})
      |> sub(2, %{"type" => "stream", "node" => me, "stream" => "th-kept"})

    {[_, _], client} =
      await_all(client, [
        &(&1["t"] == "live" and &1["id"] == 1),
        &(&1["t"] == "live" and &1["id"] == 2)
      ])

    client = WsClient.send_json(client, %{"t" => "unsub", "id" => 1})
    # A round trip, so the socket has handled the unsub before anything commits.
    client = WsClient.send_json(client, %{"t" => "ping"})
    {%{"t" => "pong"}, client} = WsClient.recv(client, 1_000)

    patch = %{"a" => %{"text" => "late"}}
    {:ok, _} = HalC2.Streams.commit("th-dropped", :thread, [{"turn-item", "i1", patch}])
    {:ok, kept} = HalC2.Streams.commit("th-kept", :thread, [{"turn-item", "i1", patch}])

    {%{"events" => [[^kept, "turn-item", "i1", ^patch, _]]}, skipped, _} =
      WsClient.recv_until(client, &(&1["t"] == "events" and &1["id"] == 2))

    assert Enum.filter(skipped, &(&1["id"] == 1)) == []
  end

  test "Given a client on the socket, when it calls what this node cannot serve, then each call fails on its own and the socket stays up",
       %{port: port, environment: env} do
    client =
      connect(port)
      |> rpc(env, 1, "server.commitDesktopUpdate", %{})
      |> rpc("no-such-environment", 2, "server.getSettings", %{})
      |> rpc(env, 3, "orchestration.dispatchCommand", %{"type" => "prepared-run.release"})

    {[unserved, elsewhere, internal], client} =
      await_all(client, [reply?(1), reply?(2), reply?(3)])

    assert %{
             "t" => "rpc.error",
             "error" => "server.commitDesktopUpdate is not served by this node yet"
           } =
             unserved

    assert %{"t" => "rpc.error", "error" => "unknown environment"} = elsewhere

    assert %{
             "t" => "rpc.error",
             "error" => "prepared-run.release is not supported by this node yet"
           } =
             internal

    client = WsClient.send_json(client, %{"t" => "ping"})
    assert {%{"t" => "pong"}, _} = WsClient.recv(client, 1_000)
  end

  test "Given a client following scheduled tasks, when it adds, enables, and deletes a task, then every change pushes the whole list",
       %{port: port, environment: env} do
    start_supervised!(HalC2.ScheduledTasks)
    me = Atom.to_string(node())
    client = connect(port) |> sub(1, %{"type" => "scheduledTasks", "node" => me})
    {%{"t" => "scheduledTasks", "tasks" => []}, client} = WsClient.recv(client, 1_000)
    pushed? = &(&1["t"] == "scheduledTasks" and &1["id"] == 1)

    client =
      rpc(client, env, 2, "scheduledTasks.upsert", %{
        "title" => "Nightly",
        "prompt" => "summarize the day",
        "enabled" => false,
        "schedule" => %{"type" => "interval", "everyMs" => 3_600_000}
      })

    {[%{"result" => %{"task" => %{"id" => id}}}, %{"tasks" => [added]}], client} =
      await_all(client, [reply?(2), pushed?])

    assert %{"id" => ^id, "enabled" => false, "nextRunAt" => nil} = added

    client = rpc(client, env, 3, "scheduledTasks.setEnabled", %{"id" => id, "enabled" => true})
    {[_, %{"tasks" => [enabled]}], client} = await_all(client, [reply?(3), pushed?])
    assert %{"enabled" => true, "nextRunAt" => next} = enabled
    assert is_binary(next)

    client = rpc(client, env, 4, "scheduledTasks.delete", %{"id" => id})

    assert {[%{"result" => %{"id" => ^id}}, %{"tasks" => []}], _} =
             await_all(client, [reply?(4), pushed?])
  end
end
