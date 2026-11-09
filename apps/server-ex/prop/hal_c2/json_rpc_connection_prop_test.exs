defmodule HalC2.JsonRpcConnectionPropTest do
  @moduledoc """
  `HalC2.JsonRpc.Connection` with a `:program` whose exit can fall anywhere among the
  calls its owner makes: before the program is told to exit, every call gets its
  answer; from then on every call fails with the program's exit and what it printed,
  whether it was written before the exit, failed to write, or found the connection
  already stopped (`Connection.gone/2`), and the connection stops with that error as its
  reason. Never a bare close, never an exit in the owner.
  """

  use ExUnit.Case, async: true
  use PropCheck
  use PropCheck.StateM

  alias HalC2.JsonRpc.Connection

  @peer Path.expand("../../test/support/echo_rpc.py", __DIR__)
  @said "Error: Missing optional dependency @openai/codex-darwin-arm64"

  property "a program's exit reaches every call made after it, however the race falls",
    numtests: HalC2.Prop.numtests(40),
    max_size: 12 do
    forall cmds <- commands(__MODULE__) do
      Process.flag(:trap_exit, true)

      {:ok, conn} =
        Connection.start_link(
          cmd: ["python3", "-u", @peer],
          handler: self(),
          program: "Peer",
          stderr_tail: true
        )

      Process.put(:conn, {conn, Process.monitor(conn)})
      {history, state, result} = run_commands(__MODULE__, cmds)
      Connection.stop(conn)
      flush(conn)

      (result == :ok)
      |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
      |> aggregate(command_names(cmds))
    end
  end

  defp flush(conn) do
    receive do
      {:EXIT, ^conn, _} -> flush(conn)
      {:DOWN, _, :process, ^conn, _} -> flush(conn)
      {:json_rpc, ^conn, _} -> flush(conn)
    after
      0 -> :ok
    end
  end

  # --- model: the exit code the program was told to exit with, and whether its stop was seen

  def initial_state, do: %{exited: nil, down: false}

  def command(%{exited: nil}),
    do:
      oneof([
        {:call, __MODULE__, :call, [integer(1, 9)]},
        {:call, __MODULE__, :program_exit, [integer(1, 3)]}
      ])

  def command(%{down: false}),
    do: oneof([{:call, __MODULE__, :call, [integer(1, 9)]}, {:call, __MODULE__, :await_down, []}])

  def command(_state), do: {:call, __MODULE__, :call, [integer(1, 9)]}

  def precondition(%{exited: code}, {:call, _, :program_exit, _}), do: code == nil

  def precondition(%{exited: code, down: down}, {:call, _, :await_down, _}),
    do: code != nil and not down

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :program_exit, [code]}), do: %{state | exited: code}
  def next_state(state, _result, {:call, _, :await_down, _}), do: %{state | down: true}
  def next_state(state, _result, _call), do: state

  def postcondition(%{exited: nil}, {:call, _, :call, [n]}, result),
    do: result == {:ok, %{"method" => "echo", "params" => %{"n" => n}}}

  def postcondition(%{exited: code}, {:call, _, :call, _}, result),
    do: result == {:error, exit_error(code)}

  def postcondition(%{exited: code}, {:call, _, :await_down, _}, reason),
    do: reason == {:shutdown, {:ended, exit_error(code)}}

  def postcondition(_state, _call, _result), do: true

  defp exit_error(code),
    do: %{
      "message" => "Peer process exited with code #{code}",
      "exitCode" => code,
      "stderr" => @said,
      "ended" => true
    }

  # --- commands, as the connection's owner makes them

  def call(n) do
    {conn, _ref} = Process.get(:conn)

    try do
      Connection.call(conn, "echo", %{"n" => n}, 5_000)
    catch
      :exit, reason -> Connection.gone(conn, reason)
    end
  end

  def program_exit(code) do
    {conn, _ref} = Process.get(:conn)
    Connection.notify(conn, "exit", %{"code" => code, "said" => @said})
  end

  # The connection's stop, so the calls after it find it gone.
  def await_down do
    {conn, ref} = Process.get(:conn)

    receive do
      {:DOWN, ^ref, :process, ^conn, reason} -> reason
    after
      5_000 -> :no_stop
    end
  end
end
