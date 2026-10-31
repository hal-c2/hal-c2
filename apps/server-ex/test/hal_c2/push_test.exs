defmodule HalC2.PushTest do
  # Push on a real MC (store, auth, shell, streams), to a phone's endpoint on loopback.
  use ExUnit.Case, async: false

  alias HalC2.Push
  alias HalC2.Test.{Mc, PushPhone}
  alias HalC2.Test.Mc.World

  setup do
    dir = Path.join(System.tmp_dir!(), "hal-c2-push-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    mc = Mc.start(dir)
    Mc.ensure(PushPhone)
    # Retries say how long they would wait instead of waiting.
    test = self()
    {Push, opts} = PushPhone.service()
    Mc.ensure({Push, Keyword.put(opts, :sleep, &send(test, {:slept, &1}))})

    {:ok, access, _, _} =
      HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(mc.store), %{"label" => "Phone"})

    {:ok, ticket, _} = HalC2.Auth.issue_ticket(access)
    [%{"sessionId" => session}] = Enum.filter(HalC2.Auth.clients(), & &1["sessionId"])

    context =
      %{mc: mc, clients: %{}, projects: %{}, threads: %{}}
      |> World.put_client("phone", Mc.connect(mc, "wsTicket=#{ticket}"))
      |> World.create_project("shop")
      |> World.create_thread("Fix checkout", "shop")

    {:ok, context: context, phone: PushPhone.start("/ntfy/up1"), session: session}
  end

  defp register(context, phone, fields \\ %{}) do
    {result, context} =
      World.call(context, "hal-c2.registerPush", PushPhone.registration(phone, fields), "phone")

    assert result == {:ok, %{}}
    context
  end

  # Each run completes at least a millisecond after the last, as a thread's runs do:
  # alerts tell a thread's completions apart by the millisecond.
  defp finish(context, title \\ "Fix checkout") do
    at = max(System.os_time(:millisecond), Process.get(:last_finish, 0) + 1)
    Process.put(:last_finish, at)
    iso = at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    context = World.add_run(context, title, "completed", iso)
    :ok = Push.drain()
    context
  end

  test "an alert is POSTed encrypted to the endpoint, with TTL and urgency", %{
    context: context,
    phone: phone
  } do
    context |> register(phone) |> finish()

    assert [%{path: "/ntfy/up1", headers: headers, status: 201}] = PushPhone.requests(phone)
    assert {"content-encoding", "aes128gcm"} in headers
    assert {"ttl", "600"} in headers
    assert {"urgency", "high"} in headers

    assert [%{"v" => 1, "alert" => alert} = message] = PushPhone.messages(phone)
    refute Map.has_key?(message, "activity")

    assert %{"kind" => "completed", "title" => "Fix checkout", "body" => "Agent finished"} =
             alert

    assert alert["link"] == "hal-c2://threads/#{context.mc.environment}/#{alert["threadId"]}"
    assert Enum.all?(PushPhone.posted_urls(), &(&1 == phone.endpoint))
  end

  test "a registration that cannot be pushed to is refused", %{context: context, phone: phone} do
    for fields <- [
          %{"endpoint" => "ftp://example.com/up"},
          %{"keys" => %{"p256dh" => "AAAA", "auth" => "AAAA"}},
          %{"quietHours" => %{"start" => 2000, "end" => 0}}
        ] do
      payload = PushPhone.registration(phone, fields)

      assert {{:error, _message, %{"_tag" => "InvalidPushRegistration"}}, _} =
               World.call(context, "hal-c2.registerPush", payload, "phone")
    end

    assert Push.registrations() == %{}
  end

  test "the MC's own token has no client to push to", %{context: context, phone: phone} do
    assert {{:error, _, _}, _} =
             World.call(context, "hal-c2.registerPush", PushPhone.registration(phone))
  end

  test "an endpoint that answers 410 is dropped", %{context: context, phone: phone} do
    context = register(context, phone)
    PushPhone.answer(phone, [410])
    context = finish(context)
    assert Push.registrations() == %{}
    assert HalC2.Store.metas(HalC2.Store.path(), "push:") == %{}

    finish(context)
    assert length(PushPhone.requests(phone)) == 1
  end

  test "a busy endpoint is retried with backoff, the same alert each time", %{
    context: context,
    phone: phone
  } do
    context = register(context, phone)
    PushPhone.answer(phone, [503, 429])
    finish(context)

    assert [503, 429, 201] = Enum.map(PushPhone.requests(phone), & &1.status)
    assert_received {:slept, 1_000}
    assert_received {:slept, 2_000}

    ids =
      for %{body: body} <- PushPhone.requests(phone) do
        {:ok, json} = HalC2.Push.WebPush.decrypt(body, phone.private, phone.auth)
        JSON.decode!(json)["alert"]["id"]
      end

    assert [id, id, id] = ids
  end

  test "an endpoint that never takes it is given up after six tries", %{
    context: context,
    phone: phone
  } do
    context = register(context, phone)
    PushPhone.answer(phone, List.duplicate(500, 6))
    finish(context)
    assert length(PushPhone.requests(phone)) == 6
    assert map_size(Push.registrations()) == 1
  end

  test "revoking the client drops its registration", %{
    context: context,
    phone: phone,
    session: session
  } do
    context = register(context, phone)
    assert HalC2.Auth.revoke_client(session)
    assert Push.registrations() == %{}
    finish(context)
    assert PushPhone.requests(phone) == []
  end

  test "a registration survives a restart", %{context: context, phone: phone} do
    context = register(context, phone)
    context = %{context | mc: Mc.restart(context.mc), clients: %{}}
    assert map_size(Push.registrations()) == 1
    finish(context)
    assert [%{"title" => "Fix checkout"}] = PushPhone.alerts(phone)
  end

  test "a restart deletes what is stored for revoked sessions", %{context: context, phone: phone} do
    context = register(context, phone)
    registration = JSON.encode!(%{"endpoint" => "https://push.example/gone"})
    :ok = HalC2.Store.put_meta("push:revoked-session", registration)
    :ok = HalC2.Store.put_meta("push-held:revoked-session", "[]")
    :ok = HalC2.Store.put_meta("push-held:unregistered-session", "[]")

    Mc.restart(context.mc)

    assert map_size(Push.registrations()) == 1
    stored = HalC2.Store.metas(HalC2.Store.path(), "push")
    assert [_] = Map.keys(stored)
  end

  test "unregistering stops alerts", %{context: context, phone: phone} do
    context = register(context, phone)
    {{:ok, %{}}, context} = World.call(context, "hal-c2.unregisterPush", %{}, "phone")
    {{:ok, %{}}, context} = World.call(context, "hal-c2.unregisterPush", %{}, "phone")
    finish(context)
    assert PushPhone.requests(phone) == []
  end

  test "a muted thread gets no alert until unmuted", %{context: context, phone: phone} do
    key = "#{context.mc.environment}:#{World.thread_id(context, "Fix checkout")}"
    context = context |> register(phone, %{"mutedThreads" => [key]}) |> finish()
    assert PushPhone.alerts(phone) == []

    context |> register(phone) |> finish()
    assert [%{"title" => "Fix checkout"}] = PushPhone.alerts(phone)
  end

  test "a thread keeps its mute when it moves to another MC", %{context: context, phone: phone} do
    id = World.thread_id(context, "Fix checkout")
    context |> register(phone, %{"mutedThreads" => ["env-elsewhere:#{id}"]}) |> finish()
    assert PushPhone.alerts(phone) == []
  end

  test "what another MC had when it joins is not news", %{context: context, phone: phone} do
    register(context, phone)

    row = fn run ->
      at = World.iso_from_now(String.to_integer(run) * 1000)

      %{
        "id" => "far",
        "title" => "Far away",
        "latestRunId" => run,
        "status" => "completed",
        "latestRunCompletedAt" => at,
        "updatedAt" => at
      }
    end

    send(Push, {:hal_c2_shell, {:rows, :"peer@push.invalid", [{"far", {"thread", row.("1")}}]}})
    :ok = Push.drain()
    assert PushPhone.alerts(phone) == []

    send(Push, {:hal_c2_shell, {:rows, :"peer@push.invalid", [{"far", {"thread", row.("2")}}]}})
    :ok = Push.drain()
    assert [%{"title" => "Far away"}] = PushPhone.alerts(phone)

    # Removed from the cluster and back: its rows are a baseline again.
    send(Push, {:hal_c2_shell, {:mc, :"peer@push.invalid", :removed}})
    send(Push, {:hal_c2_shell, {:rows, :"peer@push.invalid", [{"far", {"thread", row.("3")}}]}})
    :ok = Push.drain()
    assert length(PushPhone.alerts(phone)) == 1
  end

  test "a card for work still running is sent again before it expires", %{
    context: context,
    phone: phone
  } do
    context = register(context, phone, %{"liveActivity" => true})
    World.add_run(context, "Fix checkout", "running")
    :ok = Push.drain()
    assert [%{"activity" => %{"active" => true}}] = PushPhone.messages(phone)

    PushPhone.set_clock(System.os_time(:millisecond) + :timer.minutes(59))
    :ok = Push.drain()
    assert length(PushPhone.messages(phone)) == 1

    PushPhone.set_clock(System.os_time(:millisecond) + :timer.minutes(61))
    :ok = Push.drain()
    assert [_, %{"activity" => %{"active" => true} = card}] = PushPhone.messages(phone)
    assert card["expiresAt"] > System.os_time(:millisecond) + :timer.minutes(61)
  end

  describe "quiet hours" do
    # 22:00 to 07:00 UTC.
    @quiet %{"start" => 1320, "end" => 420, "allowApprovals" => false, "utcOffsetMinutes" => 0}

    defp today(hour, minute) do
      now = System.os_time(:millisecond)
      now - rem(now, :timer.hours(24)) + :timer.hours(hour) + :timer.minutes(minute)
    end

    test "alerts are held and sent together when they end", %{context: context, phone: phone} do
      PushPhone.set_clock(today(23, 0))
      context = World.create_thread(context, "Add search", "shop")
      context = context |> register(phone, %{"quietHours" => @quiet}) |> finish()
      finish(context, "Add search")
      assert PushPhone.requests(phone) == []

      PushPhone.set_clock(today(6, 59) + :timer.hours(24))
      :ok = Push.drain()
      assert PushPhone.requests(phone) == []

      PushPhone.set_clock(today(7, 0) + :timer.hours(24))
      :ok = Push.drain()

      assert [%{"kind" => "grouped", "title" => "2 agents finished", "body" => body}] =
               PushPhone.alerts(phone)

      assert String.split(body, "\n") == ["Fix checkout", "Add search"]
    end

    test "a thread muted while its alert is held is left out", %{context: context, phone: phone} do
      PushPhone.set_clock(today(23, 0))
      context = World.create_thread(context, "Add search", "shop")
      context = context |> register(phone, %{"quietHours" => @quiet}) |> finish()
      finish(context, "Add search")

      key = "#{context.mc.environment}:#{World.thread_id(context, "Fix checkout")}"
      register(context, phone, %{"quietHours" => @quiet, "mutedThreads" => [key]})
      PushPhone.set_clock(today(7, 0) + :timer.hours(24))
      :ok = Push.drain()

      assert [%{"kind" => "completed", "title" => "Add search"}] = PushPhone.alerts(phone)
    end

    test "alerts held survive a restart", %{context: context, phone: phone} do
      PushPhone.set_clock(today(23, 0))
      context = context |> register(phone, %{"quietHours" => @quiet}) |> finish()
      assert PushPhone.requests(phone) == []

      PushPhone.set_clock(today(7, 0) + :timer.hours(24))
      Mc.restart(context.mc)
      :ok = Push.drain()
      assert [%{"title" => "Fix checkout"}] = PushPhone.alerts(phone)
    end

    test "approvals go through when allowed", %{context: context, phone: phone} do
      PushPhone.set_clock(today(23, 0))
      context = register(context, phone, %{"quietHours" => %{@quiet | "allowApprovals" => true}})
      context = finish(context)
      id = "rq-#{System.unique_integer([:positive])}"
      at = World.iso_from_now(0)

      World.put_entity(context, "Fix checkout", "runtime-request", id, %{
        "s" => %{
          "id" => id,
          "threadId" => World.thread_id(context, "Fix checkout"),
          "kind" => "command",
          "status" => "pending",
          "createdAt" => at,
          "updatedAt" => at
        }
      })

      :ok = Push.drain()
      assert [%{"kind" => "approval", "body" => "Approval needed"}] = PushPhone.alerts(phone)
    end
  end

  test "the activity card follows the work and clears once", %{context: context, phone: phone} do
    context = register(context, phone, %{"liveActivity" => true})
    context = World.add_run(context, "Fix checkout", "running")
    :ok = Push.drain()

    assert [%{"activity" => card} = message] = PushPhone.messages(phone)
    refute Map.has_key?(message, "alert")
    assert %{"active" => true, "phase" => "running", "activeCount" => 1} = card

    assert [%{"status" => "Working", "title" => "Fix checkout", "project" => "shop"}] =
             card["rows"]

    assert {"urgency", "normal"} in hd(PushPhone.requests(phone)).headers

    # Nothing changed: nothing sent.
    :ok = Push.drain()
    assert length(PushPhone.requests(phone)) == 1

    # The same run completes.
    run = World.row(context, "Fix checkout")["latestRunId"]
    completed = %{"status" => "completed", "completedAt" => World.iso_from_now(0)}
    World.put_entity(context, "Fix checkout", "run", run, %{"s" => completed})
    :ok = Push.drain()
    [_, %{"alert" => %{"kind" => "completed"}, "activity" => done}] = PushPhone.messages(phone)
    assert %{"active" => false, "rows" => [%{"status" => "Done"}]} = done

    PushPhone.set_clock(System.os_time(:millisecond) + :timer.minutes(16))
    :ok = Push.drain()
    :ok = Push.drain()

    assert [_, _, %{"activity" => %{"active" => false, "rows" => []}}] =
             PushPhone.messages(phone)
  end
end
