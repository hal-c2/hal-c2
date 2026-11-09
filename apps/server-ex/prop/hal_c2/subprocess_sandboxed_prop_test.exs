defmodule HalC2.SubprocessSandboxedPropTest do
  @moduledoc """
  `HalC2.Subprocess` programs in an OpenShell sandbox (`HalC2.Subprocess.Sandboxed`),
  against a model of what an owner is promised, over any sequence of programs started,
  written to, half-closed, exiting by themselves, their exit taken from the mailbox
  (as `HalC2.JsonRpc.Connection` does, through `HalC2.Subprocess.exit_status/2`),
  asked whether they exited, and stopped. The gateway is the TLS fake: `cat` echoes
  its stdin and exits with its code at the end of it; `exit` exits with its code at
  once; `stall` never reads. The promises:

    * a line written comes back as that line (blank ones are dropped, so none is
      written);
    * `exited/2` gives the program's own exit status once it has exited, whether or
      not its owner already took that message, and `:running` before;
    * `stop/2` gives the program's own exit status, whether it exited by itself
      (the message taken or not) or on its stdin closing, and a stalled program is
      cancelled; the status is never made up;
    * however it stops, the program's stream is gone.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Client
  alias HalC2.Subprocess
  alias HalC2.Test.FakeOpenShell

  @moduletag timeout: :infinity

  # Long enough for anything here to arrive; reaching it fails the case.
  @wait 5_000

  # The status a cancelled stream ends with (`HalC2.Subprocess.Sandboxed`).
  @cancelled 255

  property "a sandboxed program's exit status is its own, however its owner asks",
    numtests: HalC2.Prop.numtests(50),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("sandboxed")
        level = Logger.level()
        Logger.configure(level: :none)
        gateway = FakeOpenShell.start(Path.join(home, "pki"), exec: &gateway_exec/2)
        FakeOpenShell.put_sandbox(gateway, "box", %{OpenShell.owner_label() => OpenShell.owner()})
        {:ok, conn} = Client.connect(gateway.endpoint, gateway.credentials)
        Process.put(:sandboxed_prop, %{conn: conn, subs: %{}})

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            for {_, sub} <- Process.get(:sandboxed_prop).subs, do: Subprocess.stop(sub, 0)
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

  defp gateway_exec(["stall"], _io), do: receive(do: (:never -> :ok))
  defp gateway_exec(["exit", code], io), do: io.exit.(String.to_integer(code))
  defp gateway_exec(["cat", code], io), do: cat(io, String.to_integer(code))

  defp cat(io, code) do
    case io.read.() do
      {:stdin, data} ->
        io.stdout.(data)
        cat(io, code)

      :eof ->
        io.exit.(code)

      _ ->
        cat(io, code)
    end
  end

  # --- model ----------------------------------------------------------------------

  # progs: the programs not yet stopped, by index, each `%{kind, code, ended, taken}`:
  # `ended` once it has exited or will by itself, `taken` once its exit message has
  # left the owner's mailbox.
  def initial_state, do: %{progs: %{}, next: 0}

  def command(state) do
    open = for {i, %{kind: :cat, ended: false}} <- state.progs, do: i
    ended = for {i, %{ended: true, taken: false}} <- state.progs, do: i
    any = Map.keys(state.progs)
    start = [state.next, oneof([:cat, :exit, :stall]), oneof([0, 1, 3, 137])]
    line = oneof(["a", "two words", ~s({"id":1})])

    frequency(
      [{3, {:call, __MODULE__, :start, start}}] ++
        on(open, [
          {3, {:call, __MODULE__, :write, [oneof(open), line]}},
          {2, {:call, __MODULE__, :close, [oneof(open)]}}
        ]) ++
        on(ended, [{3, {:call, __MODULE__, :take, [oneof(ended)]}}]) ++
        on(any, [
          {2,
           let(i <- oneof(any), do: {:call, __MODULE__, :exited, [i, wait(state, :exited, i)]})},
          {3, let(i <- oneof(any), do: {:call, __MODULE__, :stop, [i, wait(state, :stop, i)]})}
        ])
    )
  end

  defp on([], _commands), do: []
  defp on(_, commands), do: commands

  # How long `op` waits on program `i`: the whole wait for an exit that comes (one it
  # made, or a stop's closed stdin ending a `cat`), none for one that does not, where
  # `exited/2` says `:running` and a stop cancels.
  defp wait(state, :exited, i), do: if(state.progs[i].ended, do: @wait, else: 0)
  defp wait(state, :stop, i), do: if(state.progs[i].kind == :stall, do: 0, else: @wait)

  def precondition(state, {:call, _, :start, [i, _, _]}), do: i == state.next

  def precondition(state, {:call, _, op, [i | _]}) when op in [:write, :close],
    do: match?(%{kind: :cat, ended: false}, state.progs[i])

  def precondition(state, {:call, _, :take, [i]}),
    do: match?(%{ended: true, taken: false}, state.progs[i])

  def precondition(state, {:call, _, op, [i, wait]}) when op in [:exited, :stop],
    do: Map.has_key?(state.progs, i) and wait == wait(state, op, i)

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :start, [i, kind, code]}) do
    prog = %{kind: kind, code: code, ended: kind == :exit, taken: false}
    %{state | progs: Map.put(state.progs, i, prog), next: i + 1}
  end

  def next_state(state, _result, {:call, _, :close, [i]}),
    do: put_in(state.progs[i].ended, true)

  def next_state(state, _result, {:call, _, :take, [i]}),
    do: put_in(state.progs[i].taken, true)

  def next_state(state, _result, {:call, _, :exited, [i, _]}) do
    if state.progs[i].ended, do: put_in(state.progs[i].taken, true), else: state
  end

  def next_state(state, _result, {:call, _, :stop, [i, _]}),
    do: %{state | progs: Map.delete(state.progs, i)}

  def next_state(state, _result, _call), do: state

  def postcondition(_state, {:call, _, :start, _}, result), do: result == :ok
  def postcondition(_state, {:call, _, :write, [_, line]}, result), do: result == [line]
  def postcondition(_state, {:call, _, :close, _}, result), do: result == :ok
  def postcondition(state, {:call, _, :take, [i]}, result), do: result == state.progs[i].code

  def postcondition(state, {:call, _, :exited, [i, _]}, result) do
    case state.progs[i] do
      %{ended: true, code: code} -> result == {:ok, code}
      _ -> result == :running
    end
  end

  def postcondition(state, {:call, _, :stop, [i, _]}, result) do
    case state.progs[i] do
      %{kind: :stall} -> result == {{:ok, @cancelled}, :gone}
      %{kind: :cat, code: code} -> result == {{:ok, code}, :gone}
      %{kind: :exit, code: code} -> result == {{:ok, code}, :gone}
    end
  end

  # --- commands -------------------------------------------------------------------

  def start(i, kind, code) do
    ctx = Process.get(:sandboxed_prop)
    argv = if kind == :stall, do: ["stall"], else: [Atom.to_string(kind), Integer.to_string(code)]

    case Subprocess.start(argv, sandbox: %{conn: ctx.conn, name: "box"}) do
      {:ok, sub} ->
        Process.put(:sandboxed_prop, put_in(ctx.subs[i], sub))
        :ok

      error ->
        error
    end
  end

  # The echo, as the owner gets it: one batch, which it acknowledges.
  def write(i, line) do
    sub = sub(i)
    :ok = Subprocess.write_line(sub, line)
    reader = sub.reader

    receive do
      {:subprocess_lines, ^reader, lines} ->
        Subprocess.ack(sub)
        lines
    after
      @wait -> :no_echo
    end
  end

  def close(i), do: HalC2.OpenShell.Exec.close_stdin(sub(i).proc.exec)

  # As an owner that receives every message does, keeping the status from it.
  def take(i) do
    sub = sub(i)
    ref = sub.proc.exit_ref

    receive do
      {^ref, _} = message ->
        {:ok, status} = Subprocess.exit_status(sub, message)
        status
    after
      @wait -> :no_exit
    end
  end

  def exited(i, wait), do: Subprocess.exited(sub(i), wait)

  def stop(i, wait) do
    sub = sub(i)
    exec = Process.monitor(sub.proc.exec)
    status = Subprocess.stop(sub, wait)
    ctx = Process.get(:sandboxed_prop)
    Process.put(:sandboxed_prop, %{ctx | subs: Map.delete(ctx.subs, i)})

    receive do
      {:DOWN, ^exec, :process, _, _} -> {status, :gone}
    after
      @wait -> {status, :running}
    end
  end

  defp sub(i), do: Process.get(:sandboxed_prop).subs[i]
end
