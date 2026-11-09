defmodule HalC2.Subprocess.Sandboxed do
  @moduledoc """
  A `HalC2.Subprocess` program that runs in an OpenShell sandbox (#1412): the same
  messages to its owner, over an exec stream (`HalC2.OpenShell.Exec`) instead of a
  local port. `HalC2.Subprocess.start/2` starts one when given `:sandbox`:

      %{conn: conn, name: sandbox, workdir: dir, environment: %{}, timeout_seconds: s,
        output_limit: bytes, on_limit: fun}

  The program gets only `environment`, never the MC's or the project's. The reader is
  the stream's owner: it frames stdout into `{:subprocess_lines, reader, lines}` and
  waits for `ack/1` as the port reader does, sends `{exit_ref, {:ok, status}}` when the
  command exits and `{:subprocess_eof, reader}` once its lines are handed over.
  Stderr is counted and dropped. More than `output_limit` bytes of output in all, or
  more lines waiting on the owner than a batch should ever hold, cancels the command
  (exit 137), drops what was waiting and calls `on_limit`, since the stream does not
  hold output back while the owner is busy. The reader ends with its owner, and the
  stream with the reader.

  The exit status is kept past that message: an owner that took it (as
  `HalC2.Subprocess.exit_status/2` lets it) still gets it from `exited/2` and `stop/2`,
  at once.
  """

  alias HalC2.OpenShell.{Client, Exec}
  alias HalC2.Subprocess

  import Bitwise

  # `status` is a one-slot `:atomics`, `@running` until the reader sets the exit status
  # in it, which it does before it mails the owner: it is never set while that message
  # is still to come.
  @enforce_keys [:exec, :exit_ref, :status]
  defstruct [:exec, :exit_ref, :status]

  @type t :: %__MODULE__{exec: pid, exit_ref: reference, status: :atomics.atomics_ref()}

  # Not an exit status, which the gateway sends as an int32.
  @running 1 <<< 40

  # Exec gives no output backpressure, so a run's output is capped instead, and so are
  # the lines held for a busy owner: short lines cost far more as list cells than their
  # bytes.
  @output_limit 268_435_456
  @held_limit 1_000_000

  @doc false
  def start(argv, sandbox, owner) do
    ref = make_ref()
    status = :atomics.new(1, signed: true)
    :atomics.put(status, 1, @running)
    limit = Map.get(sandbox, :output_limit, @output_limit)
    on_limit = Map.get(sandbox, :on_limit, fn -> :ok end)

    opts = [
      workdir: Map.get(sandbox, :workdir, ""),
      environment: Map.get(sandbox, :environment, %{}),
      timeout_seconds: Map.get(sandbox, :timeout_seconds)
    ]

    # The reader starts the stream itself: the gateway calls leave processes linked
    # to their caller, and an owner that traps exits must not hear them end.
    exec = {sandbox.conn, sandbox.name, argv, opts}
    reader = spawn_link(__MODULE__, :reader_init, [owner, {ref, status}, limit, on_limit, exec])
    monitor = Process.monitor(reader)

    receive do
      {^ref, {:started, exec}} ->
        Process.demonitor(monitor, [:flush])
        proc = %__MODULE__{exec: exec, exit_ref: ref, status: status}
        {:ok, %Subprocess{proc: proc, reader: reader}}

      # Nothing runs here instead: the agent does not start, saying why.
      {^ref, {:failed, reason}} ->
        Process.demonitor(monitor, [:flush])
        unlinked(reader)
        {:error, HalC2.OpenShell.Review.why(reason)}

      {:DOWN, ^monitor, :process, ^reader, reason} ->
        unlinked(reader)
        {:error, HalC2.OpenShell.Review.why({:reader, reason})}
    end
  end

  defp unlinked(reader) do
    Process.unlink(reader)

    receive do
      {:EXIT, ^reader, _} -> :ok
    after
      0 -> :ok
    end
  end

  @doc false
  def write_line(%__MODULE__{exec: exec}, line) do
    Exec.send_stdin(exec, [line, ?\n])
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc false
  def exited(%__MODULE__{exit_ref: ref} = proc, timeout) do
    with nil <- ended(proc) do
      receive do
        {^ref, {:ok, status}} -> {:ok, status}
      after
        timeout -> :running
      end
    end
  end

  # Closes stdin, and cancels the command if it has not exited `timeout` later. A
  # cancel always ends in an exit status from `reader`, unless the reader is gone.
  @doc false
  def stop(%__MODULE__{exec: exec, exit_ref: ref} = proc, reader, timeout) do
    with nil <- ended(proc) do
      try do
        Exec.close_stdin(exec)
      catch
        :exit, _ -> :ok
      end

      receive do
        {^ref, status} -> status
      after
        timeout ->
          monitor = Process.monitor(reader)
          Exec.cancel(exec)

          receive do
            {^ref, status} ->
              Process.demonitor(monitor, [:flush])
              status

            {:DOWN, ^monitor, :process, ^reader, _} ->
              receive do
                {^ref, status} -> status
              after
                0 -> ended(proc) || {:ok, 137}
              end
          end
      end
    end
  end

  # The exit status once the reader has mailed it, and that message taken if the owner
  # has not yet.
  defp ended(%__MODULE__{exit_ref: ref, status: status}) do
    case :atomics.get(status, 1) do
      @running ->
        nil

      code ->
        receive do
          {^ref, {:ok, _}} -> :ok
        after
          0 -> :ok
        end

        {:ok, code}
    end
  end

  @doc false
  def reader_init(owner, {ref, status}, limit, on_limit, {conn, name, argv, opts}) do
    # A monitor, not the link: an owner that exits normally leaves a linked reader up.
    monitor = Process.monitor(owner)

    case Client.exec(conn, name, argv, Keyword.put(opts, :owner, self())) do
      {:error, reason} ->
        send(owner, {ref, {:failed, reason}})

      {:ok, exec} ->
        send(owner, {ref, {:started, exec}})

        __MODULE__.reader_loop(%{
          owner: owner,
          monitor: monitor,
          ref: ref,
          status: status,
          exec: exec,
          limit: limit,
          held_limit: @held_limit,
          on_limit: on_limit,
          seen: 0,
          partial: "",
          lines: [],
          held: 0,
          waiting: false,
          ended: false
        })
    end
  end

  @doc false
  def reader_loop(%{ended: true, waiting: false, lines: []} = s) do
    if is_binary(s.partial) and s.partial != "",
      do: send(s.owner, {:subprocess_lines, self(), [s.partial]})

    send(s.owner, {:subprocess_eof, self()})
  end

  # `lines` is kept newest first while the owner has not acknowledged, so a long run
  # of short lines costs one reverse per batch rather than an append per chunk.
  def reader_loop(%{waiting: false, lines: [_ | _]} = s) do
    send(s.owner, {:subprocess_lines, self(), Enum.reverse(s.lines)})
    __MODULE__.reader_loop(%{s | lines: [], held: 0, waiting: true})
  end

  def reader_loop(%{exec: exec, monitor: monitor} = s) do
    receive do
      :ack ->
        __MODULE__.reader_loop(%{s | waiting: false})

      # Its exec, which it owns, stops with it, cancelling the command.
      {:DOWN, ^monitor, :process, _, _} ->
        :ok

      {:openshell_exec, ^exec, {:stdout, data}} ->
        s = count(s, data)

        if s.ended do
          __MODULE__.reader_loop(s)
        else
          {lines, rest} = Subprocess.split_lines(s.partial, data)
          held = s.held + length(lines)
          s = %{s | lines: Enum.reverse(lines, s.lines), held: held, partial: rest}
          __MODULE__.reader_loop(if held > s.held_limit, do: limited(s), else: s)
        end

      {:openshell_exec, ^exec, {:stderr, data}} ->
        __MODULE__.reader_loop(count(s, data))

      {:openshell_exec, ^exec, {:exit, code}} ->
        __MODULE__.reader_loop(exit_with(s, code))

      {:openshell_exec, ^exec, {:error, _reason}} ->
        __MODULE__.reader_loop(exit_with(s, 255))
    end
  end

  defp count(%{ended: true} = s, _data), do: s

  defp count(s, data) do
    seen = s.seen + byte_size(data)

    if seen > s.limit, do: limited(%{s | seen: seen}), else: %{s | seen: seen}
  end

  defp limited(s) do
    Exec.cancel(s.exec)
    s.on_limit.()
    exit_with(%{s | partial: "", lines: [], held: 0}, 137)
  end

  defp exit_with(%{ended: true} = s, _code), do: s

  defp exit_with(s, code) do
    :atomics.put(s.status, 1, code)
    send(s.owner, {s.ref, {:ok, code}})
    %{s | ended: true}
  end
end
