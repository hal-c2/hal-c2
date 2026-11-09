defmodule HalC2.OpenShellExecPropTest do
  @moduledoc """
  `HalC2.OpenShell.Exec`, as `HalC2.OpenShell.Client.exec/4` starts it, against a
  model of what a command stream promises, over any sequence of commands started on
  one client, stdin written and half-closed, a command that stops reading while a
  writer floods it, cancels (also while output pours in), and owners that exit. The
  gateway is the TLS fake: `cat` echoes its stdin and exits 0 at its end; `stall`
  never reads; `spew` writes small chunks of output as fast as the stream takes
  them, then stalls. The promises:

    * a command's output is exactly the stdin it was sent, and it ends with exit 0
      once stdin is closed;
    * a cancel ends it with `{:error, :cancelled}` after at most the output it had
      made, and a writer it held fails;
    * exactly one ending reaches the owner, and nothing after it, however a cancel
      falls among the output;
    * however a command ends, its process and its connection are gone;
    * nothing that happens to one command (a writer stuck on it, its cancel, its
      owner's exit) stops another, or the client's own calls, from working;
    * a command in a sandbox this MC does not own is refused before any stream or
      connection is opened;
    * a command whose stream fails to open after its connection did leaves that
      connection closed.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Client
  alias HalC2.OpenShell.Exec
  alias HalC2.Test.FakeOpenShell

  @moduletag timeout: :infinity

  # Long enough for anything here to arrive; reaching it fails the case.
  @wait 5_000

  # Chunks a `spew` writes before it stalls.
  @spew 2_000

  property "a command stream ends once, with its connection, and never takes another down",
    numtests: HalC2.Prop.numtests(60),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("openshell-exec")
        level = Logger.level()
        # A stream the MC closes under a handler logs on the fake's side.
        Logger.configure(level: :none)
        gateway = FakeOpenShell.start(Path.join(home, "pki"), exec: &gateway_exec/2)
        FakeOpenShell.put_sandbox(gateway, "box", %{OpenShell.owner_label() => OpenShell.owner()})
        FakeOpenShell.put_sandbox(gateway, "theirs", %{OpenShell.owner_label() => "env-b"})
        {:ok, conn} = Client.connect(gateway.endpoint, gateway.credentials)
        Process.put(:exec_prop, %{conn: conn, execs: %{}})

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            for {_, e} <- Process.get(:exec_prop).execs do
              Exec.cancel(e.exec)
              Process.exit(e.owner, :kill)
            end

            Client.disconnect(conn)
            Supervisor.stop(gateway.server)
            Logger.configure(level: level)
            File.rm_rf!(home)
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # Until the stream is gone, which stops the gateway's process for it: a stall that
  # ended by itself would end its stream with no exit, and fail a later cancel.
  defp gateway_exec(["stall"], _io), do: receive(do: (:never -> :ok))
  defp gateway_exec(["cat"], io), do: cat(io)
  defp gateway_exec(["spew"], io), do: spew(io, @spew)

  # Bounded, so a command left open fills no mailbox; it stops once the stream is gone.
  defp spew(io, 0), do: gateway_exec(["stall"], io)

  defp spew(io, n) do
    if io.stdout.("spew\n") == :ok, do: spew(io, n - 1)
  end

  defp cat(io) do
    case io.read.() do
      {:stdin, data} ->
        io.stdout.(data)
        cat(io)

      :eof ->
        io.exit.(0)

      _ ->
        cat(io)
    end
  end

  # --- model ----------------------------------------------------------------------

  # execs: the open commands by index, each `%{kind, stdin: :open | :closed, sent,
  # flooded}`; next: the index the next command gets.
  def initial_state, do: %{execs: %{}, next: 0}

  def command(state) do
    open = Map.keys(state.execs)
    cats = for {i, %{kind: :cat, stdin: :open}} <- state.execs, do: i
    stalls = for {i, %{kind: :stall, flooded: false}} <- state.execs, do: i

    frequency(
      [
        {3, {:call, __MODULE__, :start, [state.next, oneof([:cat, :stall, :spew])]}},
        {1, {:call, __MODULE__, :health, []}},
        {1, {:call, __MODULE__, :foreign, []}},
        {1, {:call, __MODULE__, :unstartable, []}}
      ] ++
        if(cats == [],
          do: [],
          else: [
            {4, {:call, __MODULE__, :write, [oneof(cats), oneof(["a", "bc", <<0, 255>>])]}},
            {2, {:call, __MODULE__, :close, [oneof(cats)]}}
          ]
        ) ++
        if(stalls == [], do: [], else: [{2, {:call, __MODULE__, :flood, [oneof(stalls)]}}]) ++
        if(open == [],
          do: [],
          else: [
            {2, {:call, __MODULE__, :cancel, [oneof(open)]}},
            {1, {:call, __MODULE__, :owner_exits, [oneof(open)]}}
          ]
        )
    )
  end

  def precondition(state, {:call, _, :start, [i, _]}),
    do: i == state.next and map_size(state.execs) < 3

  def precondition(state, {:call, _, op, [i | _]}) when op in [:write, :close],
    do: match?(%{kind: :cat, stdin: :open}, state.execs[i])

  def precondition(state, {:call, _, :flood, [i]}),
    do: match?(%{kind: :stall, flooded: false}, state.execs[i])

  def precondition(state, {:call, _, op, [i]}) when op in [:cancel, :owner_exits],
    do: Map.has_key?(state.execs, i)

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :start, [i, kind]}) do
    exec = %{kind: kind, stdin: :open, sent: "", flooded: false}
    %{state | execs: Map.put(state.execs, i, exec), next: i + 1}
  end

  def next_state(state, _result, {:call, _, :write, [i, data]}),
    do: update_in(state.execs[i].sent, &(&1 <> data))

  def next_state(state, _result, {:call, _, :flood, [i]}),
    do: put_in(state.execs[i].flooded, true)

  def next_state(state, _result, {:call, _, op, [i]}) when op in [:close, :cancel, :owner_exits],
    do: %{state | execs: Map.delete(state.execs, i)}

  def next_state(state, _result, _call), do: state

  def postcondition(_state, {:call, _, :start, _}, result), do: result == :ok
  def postcondition(_state, {:call, _, :health, _}, result), do: match?({:ok, _}, result)
  def postcondition(_state, {:call, _, :foreign, _}, result), do: result == :refused
  def postcondition(_state, {:call, _, :unstartable, _}, result), do: result == :closed
  def postcondition(_state, {:call, _, :write, _}, result), do: result == :ok
  def postcondition(_state, {:call, _, :flood, _}, result), do: result == :ok

  def postcondition(state, {:call, _, :close, [i]}, result),
    do: result == {:ended, state.execs[i].sent, {:exit, 0}}

  # `cat` may have echoed some of its stdin before the cancel; `spew` any of its output.
  def postcondition(state, {:call, _, :cancel, [i]}, result) do
    %{kind: kind, sent: sent, flooded: flooded} = state.execs[i]
    sent = if kind == :spew, do: String.duplicate("spew\n", @spew), else: sent
    writer = if flooded, do: :failed, else: nil

    match?({:ended, _, {:error, :cancelled}, ^writer}, result) and
      String.starts_with?(sent, elem(result, 1))
  end

  def postcondition(_state, {:call, _, :owner_exits, _}, result), do: result == :gone

  # --- commands -------------------------------------------------------------------

  # Starts `kind` with an owner of its own that forwards what it gets, so the owner
  # can exit without the case.
  def start(i, kind) do
    ctx = Process.get(:exec_prop)
    case_pid = self()
    owner = spawn(fn -> forward(case_pid) end)
    before = connections()

    case Client.exec(ctx.conn, "box", [Atom.to_string(kind)], owner: owner) do
      {:ok, exec} ->
        [connection] = connections() -- before

        e = %{
          exec: exec,
          owner: owner,
          exec_ref: Process.monitor(exec),
          connection: connection,
          connection_ref: Process.monitor(connection),
          writer: nil
        }

        Process.put(:exec_prop, put_in(ctx.execs[i], e))
        :ok

      error ->
        Process.exit(owner, :kill)
        error
    end
  end

  def health, do: Client.health(Process.get(:exec_prop).conn)

  # Refused, with no connection opened and no stream asked of the gateway.
  def foreign do
    before = connections()
    result = Client.exec(Process.get(:exec_prop).conn, "theirs", ["cat"])
    opened = connections() -- before

    cond do
      result != {:error, :not_owned} -> {:ran, result}
      opened != [] -> {:opened, opened}
      true -> :refused
    end
  end

  # A stream that fails to open once the connection is up (an owner that is no
  # process) fails the start and closes that connection.
  def unstartable do
    before = connections()
    result = Client.exec(Process.get(:exec_prop).conn, "box", ["cat"], owner: "nobody")

    left = Enum.reject(connections() -- before, &gone?/1)

    cond do
      not match?({:error, _}, result) -> {:ran, result}
      left != [] -> {:left_open, left}
      true -> :closed
    end
  end

  defp gone?(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> true
    after
      @wait -> false
    end
  end

  def write(i, data), do: Exec.send_stdin(exec(i).exec, data)

  # A writer with more than the flow-control windows hold, left waiting on a command
  # that does not read.
  def flood(i) do
    %{exec: exec} = exec(i)
    case_pid = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(case_pid, {:flooded, i, Exec.send_stdin(exec, :binary.copy(<<0>>, 4_000_000))})
      end)

    ctx = Process.get(:exec_prop)
    Process.put(:exec_prop, put_in(ctx.execs[i].writer, {pid, ref}))
    :ok
  end

  def close(i) do
    e = exec(i)

    with :ok <- Exec.close_stdin(e.exec) do
      {out, ending} = output(e.exec)
      settled(i, e, {:ended, out, ending})
    end
  end

  def cancel(i) do
    e = exec(i)
    :ok = Exec.cancel(e.exec)
    {out, ending} = output(e.exec)

    writer =
      case e.writer do
        nil ->
          nil

        {_pid, ref} ->
          receive do
            {:flooded, ^i, :ok} ->
              :wrote

            {:flooded, ^i, _error} ->
              receive do
                {:DOWN, ^ref, _, _, _} -> :failed
              after
                @wait -> :stuck
              end
          after
            @wait -> :stuck
          end
      end

    settled(i, e, {:ended, out, ending, writer})
  end

  # What the owner was sent before it exited is not an ending; drop it.
  def owner_exits(i) do
    e = exec(i)
    Process.exit(e.owner, :kill)
    gone = down(e.exec_ref) and down(e.connection_ref)
    drain(e.exec)
    ctx = Process.get(:exec_prop)
    Process.put(:exec_prop, %{ctx | execs: Map.delete(ctx.execs, i)})
    if gone, do: :gone, else: :still_running
  end

  # Once a command has ended: its process and connection stop, it sends nothing
  # more, and it leaves the model.
  defp settled(i, e, result) do
    gone = down(e.exec_ref) and down(e.connection_ref)
    sync_owner(e.owner)
    extra = drain(e.exec)
    ctx = Process.get(:exec_prop)
    Process.put(:exec_prop, %{ctx | execs: Map.delete(ctx.execs, i)})
    Process.exit(e.owner, :kill)

    cond do
      not gone -> {:still_running, result}
      extra != [] -> {:after_ending, extra, result}
      true -> result
    end
  end

  defp down(ref) do
    receive do
      {:DOWN, ^ref, :process, _, _} -> true
    after
      @wait -> false
    end
  end

  # A forwarder has passed on everything it got before it answers this.
  defp sync_owner(owner) do
    if Process.alive?(owner) do
      ref = make_ref()
      send(owner, {:sync, self(), ref})

      receive do
        {:owned, {:synced, ^ref}} -> :ok
      after
        @wait -> :ok
      end
    end
  end

  defp drain(exec, acc \\ []) do
    receive do
      {:owned, {:openshell_exec, ^exec, msg}} -> drain(exec, [msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp output(exec, acc \\ []) do
    receive do
      {:owned, {:openshell_exec, ^exec, {:stdout, data}}} -> output(exec, [acc, data])
      {:owned, {:openshell_exec, ^exec, ending}} -> {IO.iodata_to_binary(acc), ending}
    after
      @wait -> {IO.iodata_to_binary(acc), :timeout}
    end
  end

  defp forward(case_pid) do
    receive do
      {:sync, ^case_pid, ref} -> send(case_pid, {:owned, {:synced, ref}})
      msg -> send(case_pid, {:owned, msg})
    end

    forward(case_pid)
  end

  defp exec(i), do: Process.get(:exec_prop).execs[i]

  # The gRPC client connections open now, one per channel.
  defp connections do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(GRPC.Client.Supervisor),
        is_pid(pid),
        do: pid
  end
end
