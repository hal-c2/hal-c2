defmodule HalC2.SpacePresencePropTest do
  @moduledoc """
  A state machine over who is on the pages of a Space (`HalC2.Space.Presence`): sockets
  subscribing and letting go under refs of their own, sockets dying, agents touching
  pages, finishing and going idle, a stale idle timer, and the service restarting.

  After each command every page's view is read back and each viewer's mailbox emptied:

  - a page's view is the devices with a socket on it, each once, and the agents whose
    last touched page it is, and no socket is on a page after its last ref or its death;
  - a socket is told of a page only while on it, once for each change of its view, and
    never of what it just subscribed to; a change nobody can see tells nobody;
  - a restart forgets everyone and tells no one.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Space.Presence

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @space "s"
  @pages ~w(p1 p2 p3)
  @threads ~w(t1 t2)
  # The first two are two connections of one device.
  @devices %{"v1" => "d1", "v2" => "d1", "v3" => "d2", "v4" => "d3"}
  @viewers Map.keys(@devices)

  property "who is on a page follows the model",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.start_services([Presence])
        for viewer <- @viewers, do: spawn_viewer(viewer)
        {history, state, result} = run_commands(__MODULE__, cmds)
        for viewer <- @viewers, do: Process.exit(pid(viewer), :kill)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # on: {viewer, page} => its refs; agents: thread => the page it last touched.
  def initial_state, do: %{on: %{}, agents: %{}}

  def command(_s) do
    viewer = oneof(@viewers)
    page = oneof(@pages)
    ref = oneof(~w(a b))
    thread = oneof(@threads)

    oneof([
      {:call, __MODULE__, :open, [viewer, page, ref]},
      {:call, __MODULE__, :open, [viewer, page, ref]},
      {:call, __MODULE__, :leave, [viewer, page, ref]},
      {:call, __MODULE__, :die, [viewer]},
      {:call, __MODULE__, :touch, [thread, page]},
      {:call, __MODULE__, :finish, [thread]},
      {:call, __MODULE__, :idle, [thread]},
      {:call, __MODULE__, :stale_idle, [thread]},
      {:call, __MODULE__, :restart, []}
    ])
  end

  def precondition(_s, _call), do: true

  def next_state(s, _res, {:call, _, :open, [viewer, page, ref]}) do
    update_in(s.on[{viewer, page}], &Enum.uniq([ref | &1 || []]))
  end

  def next_state(s, _res, {:call, _, :leave, [viewer, page, ref]}) do
    case List.delete(s.on[{viewer, page}] || [], ref) do
      [] -> %{s | on: Map.delete(s.on, {viewer, page})}
      refs -> put_in(s.on[{viewer, page}], refs)
    end
  end

  def next_state(s, _res, {:call, _, :die, [viewer]}) do
    %{s | on: Map.reject(s.on, fn {{on, _}, _} -> on == viewer end)}
  end

  def next_state(s, _res, {:call, _, :touch, [thread, page]}), do: put_in(s.agents[thread], page)

  def next_state(s, _res, {:call, _, name, [thread]}) when name in [:finish, :idle] do
    %{s | agents: Map.delete(s.agents, thread)}
  end

  def next_state(s, _res, {:call, _, :stale_idle, _}), do: s
  def next_state(_s, _res, {:call, _, :restart, []}), do: initial_state()

  def postcondition(s, {:call, _, name, args} = call, res) do
    next = next_state(s, res, call)

    views_match = res.views == Map.new(@pages, &{&1, model_view(next, &1)})
    replied = name != :open or res.reply == model_view(next, Enum.at(args, 1))
    told = res.inbox == expected_inbox(s, next, name, args)
    views_match and replied and told
  end

  # Each viewer on a page whose view changed hears the new one, but for the subscriber.
  defp expected_inbox(s, next, name, args) do
    for viewer <- @viewers, into: %{} do
      told =
        for page <- @pages,
            model_view(s, page) != model_view(next, page),
            is_map_key(next.on, {viewer, page}),
            not (name == :open and Enum.at(args, 0) == viewer) do
          {:hal_c2_space_presence, @space, page, model_view(next, page)}
        end

      {viewer, Enum.sort(told)}
    end
  end

  defp model_view(s, page) do
    devices =
      for({{viewer, ^page}, _} <- s.on, uniq: true, do: @devices[viewer])
      |> Enum.sort()
      |> Enum.map(&%{key: &1, label: label(&1)})

    agents =
      for({thread, ^page} <- s.agents, do: thread)
      |> Enum.sort()
      |> Enum.map(&%{thread_id: &1, title: title(&1)})

    %{devices: devices, agents: agents}
  end

  # --- commands -------------------------------------------------------------------

  def open(viewer, page, ref) do
    reply = Presence.subscribe(pid(viewer), @space, page, device(viewer), ref)
    observed() |> Map.put(:reply, reply)
  end

  def leave(viewer, page, ref) do
    Presence.unsubscribe(pid(viewer), @space, page, device(viewer), ref)
    observed()
  end

  # Waits for the service to see the death: its monitor and this test's race.
  def die(viewer) do
    gone = pid(viewer)
    Process.exit(gone, :kill)
    spawn_viewer(viewer)
    await_forgotten(gone)
    observed()
  end

  def touch(thread, page) do
    Presence.agent_touched(thread, title(thread), @space, page)
    observed()
  end

  def finish(thread) do
    Presence.agent_done(thread)
    observed()
  end

  def idle(thread) do
    case :sys.get_state(Presence).agents do
      %{^thread => %{timer: timer}} -> send(Presence, {:agent_idle, thread, timer})
      _ -> :ok
    end

    observed()
  end

  def stale_idle(thread) do
    send(Presence, {:agent_idle, thread, make_ref()})
    observed()
  end

  def restart do
    HalC2.Prop.restart_service(Presence)
    observed()
  end

  defp await_forgotten(pid) do
    known = for {_, %{devices: %{^pid => _}}} <- :sys.get_state(Presence).pages, do: pid

    if known != [] do
      :erlang.yield()
      await_forgotten(pid)
    end
  end

  # Every page's view, then what each viewer was sent: both are past what came before.
  defp observed do
    views = Map.new(@pages, &{&1, Presence.view(@space, &1)})
    %{views: views, inbox: Map.new(@viewers, &{&1, drain(pid(&1))})}
  end

  defp drain(viewer) do
    send(viewer, {:drain, self()})

    receive do
      {:drained, ^viewer, messages} -> Enum.sort(messages)
    end
  end

  defp spawn_viewer(name), do: Process.put({:viewer, name}, spawn(fn -> viewer([]) end))

  defp viewer(seen) do
    receive do
      {:drain, from} ->
        send(from, {:drained, self(), seen})
        viewer([])

      {:hal_c2_watched, _refs, message} ->
        viewer([message | seen])
    end
  end

  defp pid(name), do: Process.get({:viewer, name})
  defp device(viewer), do: %{key: @devices[viewer], label: label(@devices[viewer])}
  defp label(device), do: "name of #{device}"
  defp title(thread), do: "title of #{thread}"
end
