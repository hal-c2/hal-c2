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
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

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
  # lost: the socket holds it lost with its MC.
  def initial_state, do: %{subs: [], text: "", n: 0, started: false, lost: false}

  def command(state) do
    free = @ids -- state.subs
    token = "t#{state.n}"

    frequency(
      if(free != [], do: [{3, {:call, __MODULE__, :sub, [oneof(free)]}}], else: []) ++
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

  def precondition(state, {:call, _, :kill, []}), do: state.started
  def precondition(state, {:call, _, :lose, []}), do: state.started
  def precondition(_state, {:call, _, :back, []}), do: true

  def precondition(state, {:call, _, :output, [token]}),
    do: state.started and token == "t#{state.n}"

  def precondition(state, {:call, _, op, [id, token]}) when op in [:race_sub, :race_sub_attach],
    do: state.started and id not in state.subs and token == "t#{state.n}"

  def next_state(state, _result, {:call, _, :sub, [id]}),
    do: %{state | subs: [id | state.subs], started: true}

  def next_state(state, _result, {:call, _, :unsub, [id]}),
    do: %{state | subs: List.delete(state.subs, id)}

  # The subscriptions were forgotten; the next one starts the terminal again.
  def next_state(state, _result, {:call, _, :kill, []}), do: %{state | subs: [], started: false}
  def next_state(state, _result, {:call, _, :lose, []}), do: %{state | lost: true}

  def next_state(%{lost: true} = state, _result, {:call, _, :back, []}),
    do: %{state | subs: [], lost: false}

  def next_state(state, _result, {:call, _, :back, []}), do: state

  def next_state(state, _result, {:call, _, :output, [token]}),
    do: %{state | text: state.text <> token <> "\r\n", n: state.n + 1}

  def next_state(state, _result, {:call, _, op, [id, token]})
      when op in [:race_sub, :race_sub_attach],
      do: %{state | subs: [id | state.subs], text: state.text <> token <> "\r\n", n: state.n + 1}

  def postcondition(state, {:call, _, :sub, [id]}, frames),
    do: frames == [{id, :snapshot, state.text}]

  def postcondition(_state, {:call, _, :unsub, _}, frames), do: frames == []

  def postcondition(state, {:call, _, :kill, []}, frames),
    do: frames == Enum.sort(for id <- state.subs, do: {id, :resync})

  def postcondition(state, {:call, _, :lose, []}, frames),
    do: frames == Enum.sort(for id <- state.subs, do: {id, :lost})

  def postcondition(%{lost: true} = state, {:call, _, :back, []}, frames),
    do: frames == Enum.sort(for id <- state.subs, do: {id, :resync})

  def postcondition(_state, {:call, _, :back, []}, frames), do: frames == []

  def postcondition(state, {:call, _, :output, [token]}, frames),
    do: frames == Enum.sort(for id <- state.subs, do: {id, :output, token <> "\r\n"})

  # The new subscription's snapshot holds the output; the ones already there are
  # told it, and the new one is not told it again.
  def postcondition(state, {:call, _, op, [id, token]}, frames)
      when op in [:race_sub, :race_sub_attach] do
    told = for old <- state.subs, do: {old, :output, token <> "\r\n"}
    frames == Enum.sort([{id, :snapshot, state.text <> token <> "\r\n"} | told])
  end

  # --- commands ---------------------------------------------------------------------

  def sub(id), do: send_frame(%{"t" => "sub", "id" => id, "shape" => shape()})
  def unsub(id), do: send_frame(%{"t" => "unsub", "id" => id})

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

  def output(token) do
    pid = terminal_pid()
    send(pid, {:stdout, :sys.get_state(pid).os_pid, token <> "\r\n"})
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

    Enum.sort(
      for(
        %{"t" => "terminal", "id" => id, "event" => event} <- frames,
        frame <- List.wrap(frame(id, event)),
        do: frame
      ) ++ for(%{"t" => "resync", "id" => id} <- frames, do: {id, :resync})
    )
  end

  defp frame(id, %{"type" => "snapshot", "snapshot" => snapshot}),
    do: {id, :snapshot, snapshot["history"]}

  defp frame(id, %{"type" => "output", "data" => data}), do: {id, :output, data}
  defp frame(id, %{"type" => "error"}), do: {id, :lost}
  defp frame(_id, _event), do: nil
end
