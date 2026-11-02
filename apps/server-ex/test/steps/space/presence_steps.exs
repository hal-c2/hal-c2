defmodule HalC2.Steps.Space.Presence do
  @moduledoc """
  Steps for `features/space/presence.feature`. The user and each device are sessions
  paired under their names, and every opening of a page is a connection of its own,
  so what they see goes through the `spacePresence` shape as a client's would.
  `context.presence` holds each name's open connections, newest first, with the viewers
  last seen on each. The Space and its pages come from `HalC2.Steps.Space.Pages`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.{Space, StreamState, Streams}
  alias HalC2.Space.Presence
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @user "This device"
  @sub 1

  step "the user opens the page {string}", %{args: [title]} = context do
    context |> leave(@user) |> open(@user, title)
  end

  step("the user leaves the page", context, do: leave(context, @user))

  step "the device {string} opens the page {string}", %{args: [device, title]} = context do
    open(context, device, title)
  end

  step "the page {string} is open on the device {string}", %{args: [title, device]} = context do
    open(context, device, title)
  end

  step "the page {string} is open again on the device {string}",
       %{args: [title, device]} = context do
    open(context, device, title)
  end

  step "the device {string} leaves the page {string} once", %{args: [device, _]} = context do
    [conn | rest] = connections(context, device)
    Mc.unsub(conn.client, @sub)
    put_connections(context, device, rest)
  end

  step "the device {string} leaves the page {string}", %{args: [device, _]} = context do
    leave(context, device)
  end

  step "the connection of the device {string} drops", %{args: [device]} = context do
    for conn <- connections(context, device), do: Mint.HTTP.close(conn.client.conn)
    put_connections(context, device, [])
  end

  step "the Space's page {string}", %{args: [title]} = context do
    payload = %{"spaceId" => context.space, "title" => title, "parentPageId" => nil}
    {_, context} = World.call!(context, "space.page.create", payload)
    context
  end

  step "the agent in {string} is working on the page {string}",
       %{args: [thread, title]} = context do
    Mc.ensure(Presence)
    {:ok, _} = World.mcp_tool(context, thread, "hal_c2_page_read", page_ref(context, title))
    context
  end

  step "the agent in {string} fails to read a page that does not exist",
       %{args: [thread]} = context do
    ref = %{"spaceId" => context.space, "pageId" => "no-such-page"}
    assert {:error, _, _} = World.mcp_tool(context, thread, "hal_c2_page_read", ref)
    context
  end

  step "the turn of the agent in {string} ends", %{args: [thread]} = context do
    Presence.agent_done(World.thread_id(context, thread))
    context
  end

  step "the agent in {string} has not touched the page for a while",
       %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    %{agents: %{^id => %{timer: timer}}} = :sys.get_state(Presence)
    send(Presence, {:agent_idle, id, timer})
    context
  end

  step("the page shows nobody else", context, do: sees(context, @user, []))

  step "the page shows the user also on {string}", %{args: [device]} = context do
    sees(context, @user, user_on([device]))
  end

  step "the page still shows the user also on {string}", %{args: [device]} = context do
    context |> sees(@user, user_on([device])) |> quiet(@user)
  end

  step "the page shows one person, also on {string} and {string}",
       %{args: [first, second]} = context do
    sees(context, @user, user_on([first, second]))
  end

  step "the page shows the agent of {string}", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    sees(context, @user, [%{"type" => "agent", "threadId" => id, "title" => thread}])
  end

  step "the page shows the agent of {string} as {string}", %{args: [thread, title]} = context do
    id = World.thread_id(context, thread)
    sees(context, @user, [%{"type" => "agent", "threadId" => id, "title" => title}])
  end

  step "the device {string} sees the user also on {string}", %{args: [device, name]} = context do
    sees(context, device, user_on([name]))
  end

  step "the user is no longer on the page {string}", %{args: [_title]} = context do
    sees(context, "Phone", [])
  end

  step("the user hears nothing about who is on a page", context, do: quiet(context, @user))

  step "the Space's stream holds nothing about who is on a page", context do
    refute inspect(Streams.state(Space.stream_id(context.space))) =~ "Phone"
    context
  end

  step "the presence service starts again", context do
    Process.exit(Process.whereis(Presence), :kill)
    context
  end

  step "the client is told to follow the page's viewers again", context do
    [conn | _] = connections(context, @user)
    Mc.await(conn.client, &(&1["t"] == "resync" and &1["id"] == @sub), 5_000)
    context
  end

  defp user_on(devices), do: [%{"type" => "user", "devices" => devices}]

  defp open(context, device, title) do
    Mc.ensure(Presence)
    {access, context} = access(context, device)

    shape = %{
      "type" => "spacePresence",
      "environment" => context.mc.environment,
      "spaceId" => context.space,
      "pageId" => page_id(context, title)
    }

    client = context.mc |> Mc.connect_as(access) |> Mc.sub(@sub, shape)
    {frame, client} = Mc.await(client, &presence?/1, 5_000)
    conn = %{client: client, viewers: frame["viewers"]}
    put_connections(context, device, [conn | connections(context, device)])
  end

  defp access(context, device) do
    case context[:presence_access][device] do
      nil ->
        access = Mc.pair(nil, device)
        known = Map.put(context[:presence_access] || %{}, device, access)
        {access, Map.put(context, :presence_access, known)}

      access ->
        {access, context}
    end
  end

  defp leave(context, device) do
    for conn <- connections(context, device), do: Mc.unsub(conn.client, @sub)
    put_connections(context, device, [])
  end

  defp connections(context, device), do: (context[:presence] || %{})[device] || []

  defp put_connections(context, device, connections) do
    known = Map.put(context[:presence] || %{}, device, connections)
    Map.put(context, :presence, known)
  end

  # The newest connection of `device` comes to show `viewers`.
  defp sees(context, device, viewers) do
    [conn | rest] = connections(context, device)

    if conn.viewers == viewers do
      context
    else
      {frame, client} =
        Mc.await(conn.client, &(presence?(&1) and &1["viewers"] == viewers), 5_000)

      conn = %{client: client, viewers: frame["viewers"]}
      put_connections(context, device, [conn | rest])
    end
  end

  # Nothing reached the newest connection of `device` from what the service has handled.
  defp quiet(context, device) do
    Presence.view("", "")
    [conn | rest] = connections(context, device)
    client = Mc.refute_frame(conn.client, &presence?/1)
    put_connections(context, device, [%{conn | client: client} | rest])
  end

  defp presence?(frame), do: frame["t"] == "spacePresence" and frame["id"] == @sub

  defp page_ref(context, title),
    do: %{"spaceId" => context.space, "pageId" => page_id(context, title)}

  defp page_id(context, title) do
    Streams.state(Space.stream_id(context.space))
    |> StreamState.get("page")
    |> Map.values()
    |> Enum.find(&(&1["title"] == title))
    |> Map.fetch!("id")
  end
end
