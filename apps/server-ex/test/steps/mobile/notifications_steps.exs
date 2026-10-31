defmodule HalC2.Steps.Mobile.Notifications do
  @moduledoc """
  The MC's side of `features/mobile/notifications.feature`: `HalC2.Push` alerting a
  paired phone through its UnifiedPush endpoint.

  The phone is a paired client session (`context.clients["phone"]`) whose endpoint is a
  loopback stand-in for its distributor (`HalC2.Test.PushPhone`, `context.phone`); it
  registers over `hal-c2.registerPush` with the fields in `context.push`. "The phone
  shows" is what the endpoint accepted, decrypted, once `HalC2.Push.drain/0` returned.
  The service reads `PushPhone.clock/0`, which quiet hours move; nothing waits.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Push
  alias HalC2.Test.{Mc, PushPhone}
  alias HalC2.Test.Mc.World

  @distributors %{
    "ntfy" => "io.heckel.ntfy",
    "NextPush" => "org.unifiedpush.distributor.nextpush"
  }
  # 22:00 to 07:00 in UTC, the clock's zone here.
  @quiet %{
    "start" => 22 * 60,
    "end" => 7 * 60,
    "allowApprovals" => false,
    "utcOffsetMinutes" => 0
  }

  # --- the phone ----------------------------------------------------------------------

  step "the phone is paired with {string}", %{args: [name]} = context do
    Mc.ensure(PushPhone)

    {:ok, access, _, _} =
      HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(context.mc.store), %{
        "label" => "Phone"
      })

    {:ok, ticket, _} = HalC2.Auth.issue_ticket(access)

    context
    |> Map.merge(%{mc_name: name, push: %{}, distributor: "ntfy"})
    |> World.put_client("phone", Mc.connect(context.mc, "wsTicket=#{ticket}"))
    |> World.create_project("shop")
  end

  step "the user picked {string} as the phone's UnifiedPush distributor",
       %{args: [distributor]} = context do
    assert Map.has_key?(@distributors, distributor)
    Map.put(context, :distributor, distributor)
  end

  step "device notifications are on", context do
    context
    |> Map.put_new_lazy(:phone, fn -> PushPhone.start("/#{context.distributor}/up-phone") end)
    |> register()
  end

  # Presentation is the phone's; the MC pushes either way.
  step("the app is in the background", context, do: context)

  step "the user mutes alerts for {string}", %{args: [title]} = context do
    context = ensure_thread(context, title)
    register(context, %{"mutedThreads" => [key(context, title)]})
  end

  step "alerts for {string} are muted", %{args: [title]} = context do
    context = ensure_thread(context, title)

    context
    |> Map.put_new_lazy(:phone, fn -> PushPhone.start("/#{context.distributor}/up-phone") end)
    |> register(%{"mutedThreads" => [key(context, title)]})
  end

  step "the user unmutes {string}", %{args: [title]} = context do
    register(context, %{"mutedThreads" => context.push["mutedThreads"] -- [key(context, title)]})
  end

  step "the user set quiet hours from 22:00 to 07:00", context do
    PushPhone.set_clock(today(21, 0))
    quiet_hours(context, @quiet)
  end

  step "the user set quiet hours that let approval requests through", context do
    PushPhone.set_clock(today(21, 0))
    quiet_hours(context, %{@quiet | "allowApprovals" => true})
  end

  # --- the agents ---------------------------------------------------------------------

  step "an agent in {string} finishes its turn", %{args: [title]} = context do
    context |> ensure_thread(title) |> World.add_run(title, "completed")
  end

  step "an agent in {string} fails", %{args: [title]} = context do
    context |> ensure_thread(title) |> World.add_run(title, "failed")
  end

  step "an agent in {string} needs the user's input", %{args: [title]} = context do
    context |> ensure_thread(title) |> request(title, "user_input")
  end

  step "an agent finishes its turn at 23:00", context do
    context = ensure_thread(context, "Fix checkout")
    PushPhone.set_clock(today(23, 0))
    World.add_run(context, "Fix checkout", "completed")
  end

  step "an agent needs approval during quiet hours", context do
    context = ensure_thread(context, "Fix checkout")
    PushPhone.set_clock(today(23, 0))
    request(context, "Fix checkout", "command")
  end

  # "Together" is one evaluation: the service takes the five rows at once. The phone's
  # distributor turns the first delivery away, so the MC delivers the alert again.
  step "agents in five threads finish their turns together", context do
    titles = ["Fix checkout", "Add search", "Tidy styles", "Speed up build", "Write docs"]
    context = Enum.reduce(titles, context, &ensure_thread(&2, &1))
    :ok = Push.drain()
    PushPhone.answer(context.phone, [503])
    :ok = :sys.suspend(Push)

    context =
      try do
        Enum.reduce(titles, context, &World.add_run(&2, &1, "completed"))
      after
        :sys.resume(Push)
      end

    Map.put(context, :together, titles)
  end

  step "{string} has several threads whose turns finished days ago", %{args: [_mc]} = context do
    titles = ["Old refactor", "Old fix", "Old docs"]

    context =
      Enum.reduce(titles, context, fn title, context ->
        context
        |> World.create_thread(title, "shop")
        |> World.add_run(title, "completed", World.iso_from_now(-World.days(3)))
      end)

    Map.put(context, :finished_before, titles)
  end

  # A member is played through the shell's own messages: it comes up, and its rows
  # arrive whole (`reset`), here none, as a real member's answer to the shell's hello.
  step "{string} joins the cluster with no threads", %{args: [name]} = context do
    peer = :"#{String.downcase(name)}@127.0.0.1"
    send(HalC2.Shell, {:nodeup, peer})
    GenServer.cast(HalC2.Shell, {:peer_environment, peer, %{"environmentId" => "env-#{name}"}})
    GenServer.cast(HalC2.Shell, {:peer_rows, peer, {"#{name}-run", 0}, 0, [], true})
    Map.put(context, :peer, peer)
  end

  step "the first thread on {string} finishes its turn", %{args: [name]} = context do
    at = World.iso_from_now(1_000)

    row = %{
      "id" => "first",
      "title" => "First on #{name}",
      "latestRunId" => "run-1",
      "status" => "completed",
      "latestRunCompletedAt" => at,
      "updatedAt" => at
    }

    rows = [{"first", {"thread", row}, 1}]
    GenServer.cast(HalC2.Shell, {:peer_rows, context.peer, {"#{name}-run", 1}, 0, rows, false})
    context
  end

  # --- outcomes -----------------------------------------------------------------------

  step "{string} sends the alert to the phone's endpoint at that distributor",
       %{args: [name]} = context do
    assert name == context.mc_name
    :ok = Push.drain()
    requests = PushPhone.requests(context.phone)
    assert requests != []

    for request <- requests do
      assert request.path == "/#{context.distributor}/up-phone"
      assert {"content-encoding", "aes128gcm"} in request.headers
      assert {"urgency", "high"} in request.headers
    end

    context
  end

  step "no HAL-C2-hosted service carries the alert", context do
    assert PushPhone.posted_urls() != []
    assert Enum.all?(PushPhone.posted_urls(), &(&1 == context.phone.endpoint))
    context
  end

  step "the phone shows an alert for {string}", %{args: [title]} = context do
    :ok = Push.drain()
    assert Enum.any?(PushPhone.alerts(context.phone), &(&1["title"] == title))
    context
  end

  step "the phone shows an alert", context do
    :ok = Push.drain()
    assert [%{"kind" => "approval"}] = PushPhone.alerts(context.phone)
    context
  end

  step "the phone shows no alert", context do
    :ok = Push.drain()
    assert PushPhone.alerts(context.phone) == []
    context
  end

  step "the phone shows no alert until 07:00", context do
    :ok = Push.drain()
    assert PushPhone.alerts(context.phone) == []

    PushPhone.set_clock(today(6, 59) + :timer.hours(24))
    :ok = Push.drain()
    assert PushPhone.alerts(context.phone) == []

    PushPhone.set_clock(today(7, 0) + :timer.hours(24))
    :ok = Push.drain()
    assert [%{"title" => "Fix checkout", "kind" => "completed"}] = PushPhone.alerts(context.phone)
    context
  end

  step "the phone shows one alert titled {string}", %{args: [title]} = context do
    :ok = Push.drain()
    assert [%{"kind" => "grouped", "title" => ^title}] = PushPhone.alerts(context.phone)
    context
  end

  step "the alert lists the title of each of the five threads", context do
    [alert] = PushPhone.alerts(context.phone)
    assert Enum.sort(String.split(alert["body"], "\n")) == Enum.sort(context.together)
    context
  end

  step "a repeat delivery of that alert does not change it", context do
    # Every request, the one turned away too, carries the same alert.
    assert [503, 201] = Enum.map(PushPhone.requests(context.phone), & &1.status)

    assert [same, same] =
             for(%{body: body} <- PushPhone.requests(context.phone), do: alert(context, body))

    context
  end

  step "no alert is pushed for those threads", context do
    :ok = Push.drain()
    assert PushPhone.requests(context.phone) == []
    context
  end

  # --- helpers ------------------------------------------------------------------------

  # Registers the phone again with `fields` over what it registered before; the
  # service is started first, as the application has it running.
  defp register(context, fields \\ %{}) do
    Mc.ensure(PushPhone.service())
    push = Map.merge(context.push, fields)
    distributor = @distributors[context.distributor]
    input = PushPhone.registration(context.phone, Map.put(push, "distributor", distributor))
    {{:ok, %{}}, context} = World.call(context, "hal-c2.registerPush", input, "phone")
    :ok = Push.drain()
    %{context | push: push}
  end

  defp quiet_hours(context, quiet) do
    context
    |> Map.put_new_lazy(:phone, fn -> PushPhone.start("/#{context.distributor}/up-phone") end)
    |> ensure_thread("Fix checkout")
    |> register(%{"quietHours" => quiet})
  end

  defp ensure_thread(context, title) do
    if Map.has_key?(context.threads, title) do
      context
    else
      context = World.create_thread(context, title, "shop")
      # Seen as it is before its agent does anything.
      if Process.whereis(Push), do: :ok = Push.drain()
      context
    end
  end

  defp request(context, title, kind) do
    id = "rq-#{System.unique_integer([:positive])}"
    at = World.iso_from_now(0)

    World.put_entity(context, title, "runtime-request", id, %{
      "s" => %{
        "id" => id,
        "threadId" => World.thread_id(context, title),
        "kind" => kind,
        "status" => "pending",
        "createdAt" => at,
        "updatedAt" => at
      }
    })
  end

  defp key(context, title), do: "#{context.mc.environment}:#{World.thread_id(context, title)}"

  defp alert(context, body) do
    {:ok, json} = HalC2.Push.WebPush.decrypt(body, context.phone.private, context.phone.auth)
    JSON.decode!(json)["alert"]
  end

  defp today(hour, minute) do
    now = System.os_time(:millisecond)
    now - rem(now, :timer.hours(24)) + :timer.hours(hour) + :timer.minutes(minute)
  end
end
