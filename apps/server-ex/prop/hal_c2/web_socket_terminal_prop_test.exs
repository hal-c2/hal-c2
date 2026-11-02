defmodule HalC2.WebSocketTerminalPropTest do
  @moduledoc """
  The `terminal` shape on one client socket, against a model of what it promises:
  every subscription the socket holds to one terminal (a page in each window of
  one client, or one made before the last is destroyed) is sent its snapshot and
  then every output event after it, under its own id, until its own unsub, and an
  unsub ends the socket's attach only with its last subscription. Output the
  terminal flushed while a subscription's attach was still in flight is in its
  snapshot and is not sent to it again. A terminal that stops without closing
  (stopped here, as one whose MC left the cluster is lost) tells every
  subscription to `resync`, and the next attach opens it again from its saved
  scrollback. One lost with its MC (`lose/0`, as the socket hears it) tells
  every subscription so in the terminal, and when the MC is back (`back/0`),
  every subscription it then has is told to `resync`.

  The shell is `cat` on a PTY and output is handed to the terminal as erlexec
  sends it, flushed on the test's word, so attaches race the pending batch
  without a timer. After every step, the terminal frames the socket sent before
  the pong answering a ping must be exactly the model's.

  A subscription that acknowledges (`sub_acking/1`) is sent output until
  `OutputWindow.limit/0` bytes wait, and nothing after that until it has acknowledged
  all of it (`ack/1`), when it is sent one new snapshot holding what it missed. A
  snapshot's own history does not count, however large.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Terminal.OutputWindow
  alias HalC2.Test.WsClient

  @moduletag timeout: :infinity
  # The terminals `kill/0` stops log their crash.
  @moduletag :capture_log

  @ids [1, 2, 3]
  @key {"th-1", "term-1"}
  @away :"hal-c2@away"

  setup do
    saved = for key <- [:port, :home], do: {key, Application.fetch_env(:hal_c2, key)}

    on_exit(fn ->
      :persistent_term.erase({HalC2.Web, :token})

      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end)
  end

  property "each terminal subscription on a socket follows the terminal until its own unsub",
    numtests: HalC2.Prop.numtests(40),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        stop()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    Application.put_env(:hal_c2, :port, 0)
    home = HalC2.Prop.scratch_home("web-socket-terminal")
    :persistent_term.erase({HalC2.Web, :token})
    Process.put({__MODULE__, :shell}, System.get_env("SHELL"))
    System.put_env("SHELL", System.find_executable("cat"))
    Process.put({__MODULE__, :home}, home)

    sup =
      HalC2.Prop.start_services([
        {Registry, keys: :unique, name: HalC2.Terminal.Registry},
        {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one},
        HalC2.Terminal.Hub,
        Supervisor.child_spec(HalC2.Web, id: HalC2.Web)
      ])

    [port] =
      for {HalC2.Web, pid, _, _} <- Supervisor.which_children(sup) do
        {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
        Process.put({__MODULE__, :web}, pid)
        port
      end

    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 5_000)
    Process.put({__MODULE__, :client}, client)
  end

  defp stop do
    Process.delete({__MODULE__, :client})
    Process.delete({__MODULE__, :web})
    HalC2.Prop.stop_services()

    case Process.delete({__MODULE__, :shell}) do
      nil -> System.delete_env("SHELL")
      shell -> System.put_env("SHELL", shell)
    end
  end

  # --- model ------------------------------------------------------------------------

  # subs: the ids subscribed to the terminal. text: everything it has printed.
  # lost: the socket holds it lost with its MC. windows: for a subscription that
  # acknowledges, the bytes it has not and whether it fell behind.
  def initial_state, do: %{subs: [], text: "", n: 0, started: false, lost: false, windows: %{}}

  def command(state) do
    free = @ids -- state.subs
    token = "t#{state.n}"

    frequency(
      if(free != [],
        do: [
          {3, {:call, __MODULE__, :sub, [oneof(free)]}},
          {2, {:call, __MODULE__, :sub_acking, [oneof(free)]}}
        ],
        else: []
      ) ++
        if(state.windows != %{},
          do: [{3, {:call, __MODULE__, :ack, [oneof(Map.keys(state.windows))]}}],
          else: []
        ) ++
        if(state.started,
          do: [{2, {:call, __MODULE__, :flood, [token]}}],
          else: []
        ) ++
        if(state.subs != [],
          do: [{2, {:call, __MODULE__, :unsub, [oneof(state.subs)]}}],
          else: []
        ) ++
        if(state.started,
          do: [{4, {:call, __MODULE__, :output, [token]}}],
          else: []
        ) ++
        if(state.started and free != [],
          do: [
            {2, {:call, __MODULE__, :race_sub, [oneof(free), token]}},
            {2, {:call, __MODULE__, :race_sub_attach, [oneof(free), token]}}
          ],
          else: []
        ) ++
        if(state.started, do: [{1, {:call, __MODULE__, :kill, []}}], else: []) ++
        if(state.started, do: [{1, {:call, __MODULE__, :lose, []}}], else: []) ++
        [{1, {:call, __MODULE__, :back, []}}]
    )
  end

  def precondition(state, {:call, _, :sub, [id]}), do: id not in state.subs
  def precondition(state, {:call, _, :unsub, [id]}), do: id in state.subs
  def precondition(state, {:call, _, :sub_acking, [id]}), do: id not in state.subs
  def precondition(state, {:call, _, :ack, [id]}), do: is_map_key(state.windows, id)

  def precondition(state, {:call, _, :flood, [token]}),
    do: state.started and token == "t#{state.n}"

  def precondition(state, {:call, _, :kill, []}), do: state.started
  def precondition(state, {:call, _, :lose, []}), do: state.started
  def precondition(_state, {:call, _, :back, []}), do: true

  def precondition(state, {:call, _, :output, [token]}),
    do: state.started and token == "t#{state.n}"

  def precondition(state, {:call, _, op, [id, token]}) when op in [:race_sub, :race_sub_attach],
    do: state.started and id not in state.subs and token == "t#{state.n}"

  def next_state(state, _result, {:call, _, :sub, [id]}),
    do: %{state | subs: [id | state.subs], started: true}

  # With its last subscription the terminal is no longer awaited.
  def next_state(state, _result, {:call, _, :unsub, [id]}) do
    subs = List.delete(state.subs, id)
    %{state | subs: subs, lost: state.lost and subs != [], windows: Map.delete(state.windows, id)}
  end

  def next_state(state, _result, {:call, _, :sub_acking, [id]}) do
    %{
      state
      | subs: [id | state.subs],
        started: true,
        windows: Map.put(state.windows, id, %{bytes: 0, behind: false})
    }
  end

  def next_state(state, _result, {:call, _, :ack, [id]}),
    do: put_in(state.windows[id], %{bytes: 0, behind: false})

  def next_state(state, _result, {:call, _, :flood, [token]}),
    do: printed(state, flood_line(token))

  # The subscriptions were forgotten; the next one starts the terminal again.
  def next_state(state, _result, {:call, _, :kill, []}),
    do: %{state | subs: [], started: false, lost: false, windows: %{}}

  def next_state(state, _result, {:call, _, :lose, []}),
    do: %{state | lost: state.lost or state.subs != []}

  def next_state(%{lost: true} = state, _result, {:call, _, :back, []}),
    do: %{state | subs: [], lost: false, windows: %{}}

  def next_state(state, _result, {:call, _, :back, []}), do: state

  def next_state(state, _result, {:call, _, :output, [token]}),
    do: printed(state, token <> "\r\n")

  def next_state(state, _result, {:call, _, op, [id, token]})
      when op in [:race_sub, :race_sub_attach] do
    state = printed(state, token <> "\r\n")
    %{state | subs: [id | state.subs]}
  end

  # What the printed `line` does to the terminal and each subscription's window.
  defp printed(state, line) do
    windows =
      Map.new(state.windows, fn {id, window} ->
        {id,
         case told?(window) do
           true -> %{window | bytes: window.bytes + byte_size(line)}
           false -> %{window | behind: true}
         end}
      end)

    %{state | text: state.text <> line, n: state.n + 1, windows: windows}
  end

  defp told?(nil), do: true
  defp told?(%{behind: behind, bytes: bytes}), do: not behind and bytes < OutputWindow.limit()

  defp told(state, line),
    do: for(id <- state.subs, told?(state.windows[id]), do: {id, :output, line})

  defp flood_line(token), do: token <> String.duplicate("x", 40_000) <> "\r\n"

  def postcondition(state, {:call, _, :sub, [id]}, frames),
    do: frames == [{id, :snapshot, state.text}]

  def postcondition(state, {:call, _, :sub_acking, [id]}, frames),
    do: frames == [{id, :snapshot, state.text}]

  def postcondition(state, {:call, _, :ack, [id]}, frames) do
    if state.windows[id].behind,
      do: frames == [{id, :snapshot, state.text}],
      else: frames == []
  end

  def postcondition(state, {:call, _, :flood, [token]}, frames),
    do: frames == Enum.sort(told(state, flood_line(token)))

  def postcondition(_state, {:call, _, :unsub, _}, frames), do: frames == []

  def postcondition(state, {:call, _, :kill, []}, frames),
    do: frames == Enum.sort(for id <- state.subs, do: {id, :resync})

  def postcondition(state, {:call, _, :lose, []}, frames),
    do: frames == Enum.sort(for id <- state.subs, do: {id, :lost})

  def postcondition(%{lost: true} = state, {:call, _, :back, []}, frames),
    do: frames == Enum.sort(for id <- state.subs, do: {id, :resync})

  def postcondition(_state, {:call, _, :back, []}, frames), do: frames == []

  def postcondition(state, {:call, _, :output, [token]}, frames),
    do: frames == Enum.sort(told(state, token <> "\r\n"))

  # The new subscription's snapshot holds the output; the ones already there are
  # told it, and the new one is not told it again.
  def postcondition(state, {:call, _, op, [id, token]}, frames)
      when op in [:race_sub, :race_sub_attach] do
    frames ==
      Enum.sort([{id, :snapshot, state.text <> token <> "\r\n"} | told(state, token <> "\r\n")])
  end

  # --- commands ---------------------------------------------------------------------

  def sub(id), do: send_frame(%{"t" => "sub", "id" => id, "shape" => shape()})
  def unsub(id), do: send_frame(%{"t" => "unsub", "id" => id})

  def sub_acking(id),
    do: send_frame(%{"t" => "sub", "id" => id, "shape" => shape(), "acks" => true})

  # Acknowledges everything the subscription has been sent.
  def ack(id) do
    sequence = Process.get({__MODULE__, :seen}, %{}) |> Map.fetch!(id)
    send_frame(%{"t" => "ack", "id" => id, "sequence" => sequence})
  end

  def flood(token), do: output_line(flood_line(token))

  # Stops the terminal abnormally with its scrollback saved, as a terminal that
  # lived past its last quiet moment has it on disk. Its `terminate/2` unregisters
  # it before this returns, so the next attach starts it again.
  def kill do
    pid = terminal_pid()
    :ok = HalC2.Terminal.save(elem(@key, 0))
    :ok = GenServer.stop(pid, :lost)
    terminal_frames()
  end

  # The socket hears the terminal went with an MC no longer in the cluster.
  def lose do
    send(socket(), {:hal_c2_terminal_down, @away, @key, :noconnection})
    terminal_frames()
  end

  # And that the MC is back.
  def back do
    send(socket(), {:nodeup, @away, []})
    terminal_frames()
  end

  # The client's socket: the one connection to the endpoint.
  defp socket do
    {:ok, [pid]} = ThousandIsland.connection_pids(Process.get({__MODULE__, :web}))
    pid
  end

  def output(token), do: output_line(token <> "\r\n")

  defp output_line(line) do
    pid = terminal_pid()
    send(pid, {:stdout, :sys.get_state(pid).os_pid, line})
    terminal_frames()
  end

  # Subscribes `id` with output and its flush queued at the terminal ahead of the
  # attach, as the output timer firing just before the attach lands them.
  def race_sub(id, token), do: race(id, token, true)

  # The same with no flush queued: the batch is still pending when the attach
  # lands, so the attach handler's own flush is what produces it.
  def race_sub_attach(id, token), do: race(id, token, false)

  defp race(id, token, flush?) do
    pid = terminal_pid()
    os_pid = :sys.get_state(pid).os_pid
    :ok = :sys.suspend(HalC2.Terminal.Hub)
    :ok = :sys.suspend(pid)
    send(pid, {:stdout, os_pid, token <> "\r\n"})
    if flush?, do: send(pid, :output)

    Process.put(
      {__MODULE__, :client},
      WsClient.send_json(Process.get({__MODULE__, :client}), %{
        "t" => "sub",
        "id" => id,
        "shape" => shape()
      })
    )

    :ok = WsClient.await_mailbox(pid, if(flush?, do: 3, else: 2))
    :ok = :sys.resume(pid)
    :ok = :sys.resume(HalC2.Terminal.Hub)
    terminal_frames()
  end

  defp shape do
    input = %{
      "threadId" => elem(@key, 0),
      "terminalId" => elem(@key, 1),
      "cwd" => Process.get({__MODULE__, :home})
    }

    %{"type" => "terminal", "mc" => Atom.to_string(node()), "input" => input}
  end

  defp terminal_pid do
    [{pid, _}] = Registry.lookup(HalC2.Terminal.Registry, @key)
    pid
  end

  defp send_frame(frame) do
    Process.put(
      {__MODULE__, :client},
      WsClient.send_json(Process.get({__MODULE__, :client}), frame)
    )

    terminal_frames()
  end

  # The snapshot and output frames sent before the pong answering a ping sent
  # now, sorted, as `{id, :snapshot, history}`, `{id, :output, text}` and
  # `{id, :resync}`. The
  # terminal is made to flush and read back first, so everything a step caused
  # is already on its way to the socket before the ping's frame.
  defp terminal_frames do
    case Registry.lookup(HalC2.Terminal.Registry, @key) do
      [{pid, _}] ->
        send(pid, :output)
        :sys.get_state(pid)

      [] ->
        :ok
    end

    client = WsClient.send_json(Process.get({__MODULE__, :client}), %{"t" => "ping"})
    {_pong, frames, client} = WsClient.recv_until(client, &(&1["t"] == "pong"), 10_000)
    Process.put({__MODULE__, :client}, client)
    note_sequences(frames)

    Enum.sort(
      for(
        %{"t" => "terminal", "id" => id, "event" => event} <- frames,
        frame <- List.wrap(frame(id, event)),
        do: frame
      ) ++ for(%{"t" => "resync", "id" => id} <- frames, do: {id, :resync})
    )
  end

  defp note_sequences(frames) do
    for %{"t" => "terminal", "id" => id, "event" => event} <- frames,
        sequence = event["sequence"] || get_in(event, ["snapshot", "sequence"]) do
      Process.put(
        {__MODULE__, :seen},
        Map.put(Process.get({__MODULE__, :seen}, %{}), id, sequence)
      )
    end
  end

  defp frame(id, %{"type" => "snapshot", "snapshot" => snapshot}),
    do: {id, :snapshot, snapshot["history"]}

  defp frame(id, %{"type" => "output", "data" => data}), do: {id, :output, data}
  defp frame(id, %{"type" => "error"}), do: {id, :lost}
  defp frame(_id, _event), do: nil
end
