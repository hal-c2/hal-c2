defmodule HalC2.Subprocess do
  @moduledoc """
  Line-framed subprocess I/O for a GenServer that owns an external program.

  The calling process owns the program and its stdin. A linked reader process owns
  stdout, splits it into lines and sends them to the owner as
  `{:subprocess_lines, reader, lines}`. It does not read again until the owner calls
  `ack/1`, so a flood of output backs up in the OS pipe instead of the mailbox. When
  stdout closes the owner receives `{:subprocess_eof, reader}`; the exit status then
  arrives through Exile as `{exit_ref, {:ok, status}}`.

  Stderr is discarded unless `:stderr_prefix` is given: then another reader drains
  it and sends the owner only the lines that start with the prefix, as
  `{:subprocess_stderr, reader, lines}`. The rest never leaves the reader, since an
  agent's stderr can carry credentials. `:stderr_tail` is the one exception, for a
  program whose own stderr is its error log: the reader keeps the last few KB, which
  `stderr_tail/1` hands over once the program has ended, and its last lines become the
  run's error, in the thread's log and wherever that error is shown. What a program that
  died on start said is the only account of why, so ask for it only where that is worth
  the chance of a secret in it.

  Exile stops the program when its owner exits, but not when the VM dies;
  `HalC2.Subprocess.Orphans` records each program so the next boot kills those.

  With `:durable` (a thread id), the program runs detached instead and outlives the MC
  (`HalC2.Subprocess.Durable`); `adopt/3` connects a later MC to it. What crosses
  the helper program in between is the same lines, plus the byte offset they reach
  as `{:subprocess_offset, reader, offset}` after each batch.

  Reader loops recurse through fully qualified calls, so a hot code load moves them
  onto the new module version at the next chunk.
  """

  alias Exile.Process, as: Proc
  alias HalC2.Subprocess.Durable

  require Logger

  @enforce_keys [:proc, :reader]
  defstruct [:proc, :reader, :durable, :errors]

  @type t :: %__MODULE__{proc: Proc.t(), reader: pid, durable: map | nil, errors: pid | nil}

  @read_size 65_535
  # A stdout line longer than this is dropped, however it arrives: one
  # message Pi sends larger than 8 MiB never reaches its handler.
  @max_line 8_388_608
  # A stderr line longer than this is dropped unread; prefixed lines are short.
  @max_stderr_line 65_536
  # How much of the end of stderr `:stderr_tail` keeps, and how many lines it hands over.
  @tail_bytes 4_096
  @tail_lines 8

  @type command :: [String.t()] | (String.t() | nil -> [String.t()])

  @doc """
  Starts `cmd`. A one-argument `cmd` receives the durable directory before launch, or
  `nil` for an owned process, and returns the argv; launch files can be made there first.
  """
  @spec start(command, keyword) :: {:ok, t} | {:error, term}
  def start(cmd, opts \\ []) do
    {durable, opts} = Keyword.pop(opts, :durable)

    if durable && Durable.enabled?(),
      do: start_durable(durable, cmd, opts),
      else: start_owned(cmd, opts)
  end

  defp start_durable(thread_id, cmd, opts) do
    cmd =
      if is_function(cmd, 1),
        do: fn dir -> cmd.(dir) |> spawn_command() end,
        else: spawn_command(cmd)

    with {:ok, program} <- Durable.launch(thread_id, cmd, opts) do
      case attach(program.dir, 0, opts[:stderr_prefix]) do
        {:ok, sub} ->
          {:ok, sub}

        {:error, reason} ->
          Durable.kill_dir(program.dir)
          {:error, reason}
      end
    end
  end

  @doc """
  Connects to the program a previous MC left in `dir`, reading its output from `offset`.
  """
  @spec adopt(String.t(), non_neg_integer, String.t() | nil) :: {:ok, t} | {:error, term}
  def adopt(dir, offset, prefix \\ nil) do
    if Durable.attachable?(dir),
      do: attach(dir, offset, prefix),
      else: {:error, :program_gone}
  end

  defp attach(dir, offset, prefix) do
    stderr = if prefix, do: :consume, else: :disable
    {mark, entry} = HalC2.Subprocess.Orphans.new_mark()
    args = Durable.attach_args(dir, offset, prefix)

    with :ok <- trackable(),
         {:ok, proc} <- Proc.start_link(args, stderr: stderr, env: [entry]),
         :ok <- track(proc, mark) do
      owner = self()
      reader = spawn_link(fn -> durable_reader_init(proc, owner, offset) end)
      :ok = Proc.change_pipe_owner(proc, :stdout, reader)
      send(reader, :owned)

      if prefix do
        errors = spawn(fn -> stderr_init(proc, owner, prefix) end)
        :ok = Proc.change_pipe_owner(proc, :stderr, errors)
        send(errors, :owned)
      end

      HalC2.Subprocess.Orphans.watch_durable(proc.pid, dir)
      {:ok, %__MODULE__{proc: proc, reader: reader, durable: %{dir: dir}}}
    end
  end

  defp start_owned(cmd, opts) do
    cmd = if is_function(cmd, 1), do: cmd.(nil) |> spawn_command(), else: spawn_command(cmd)
    {prefix, opts} = Keyword.pop(opts, :stderr_prefix)
    {tail?, opts} = Keyword.pop(opts, :stderr_tail, false)
    stderr = if prefix || tail?, do: :consume, else: :disable
    {mark, entry} = HalC2.Subprocess.Orphans.new_mark()
    opts = Keyword.update(opts, :env, [entry], &(Enum.to_list(&1 || []) ++ [entry]))

    with :ok <- trackable(),
         {:ok, proc} <- Proc.start_link(cmd, Keyword.put_new(opts, :stderr, stderr)),
         :ok <- track(proc, mark) do
      owner = self()
      reader = spawn_link(fn -> reader_init(proc, owner) end)
      :ok = Proc.change_pipe_owner(proc, :stdout, reader)
      send(reader, :owned)

      errors =
        if prefix || tail? do
          # Unlinked: stderr closing on its own must not stop the owner. The reader
          # dies with the program, when its read fails.
          tail = if tail?, do: ""
          errors = spawn(fn -> stderr_init(proc, owner, prefix, tail) end)
          :ok = Proc.change_pipe_owner(proc, :stderr, errors)
          send(errors, :owned)
          errors
        end

      {:ok, %__MODULE__{proc: proc, reader: reader, errors: errors}}
    end
  end

  # Windows cannot exec a command script (`.cmd`/`.bat`, which is how npm installs
  # its shims there) directly: `cmd.exe` runs it, as every Windows launcher does.
  defp spawn_command([executable | args]) do
    os = Application.get_env(:hal_c2, :os_type, :os.type())

    if match?({:win32, _}, os) and
         String.downcase(Path.extname(executable)) in [".cmd", ".bat"],
       do: [System.find_executable("cmd.exe") || "cmd.exe", "/c", executable | args],
       else: [executable | args]
  end

  defp spawn_command(cmd), do: cmd

  # A failure to track that is already known refuses before anything is
  # started, so no program (a provider CLI, a JSON-RPC connection, the device
  # hub: every caller here) is run up just to be killed. `track/1` after
  # the start stays the check that decides, for what races past this one.
  defp trackable do
    case HalC2.Subprocess.Orphans.available?() do
      {:error, reason} -> {:error, {:untracked, reason}}
      _ -> :ok
    end
  end

  # A program the next boot could not find if this MC died does not outlive its failed
  # record. The wait is bounded: one in uninterruptible sleep takes SIGKILL only once it
  # wakes, and the caller is a session's start. A program already gone (its Exile
  # process ended, or the port has no pid) has nothing to record, as in
  # `Orphans.track/3`.
  defp track(proc, mark) do
    case os_pid_of(proc) do
      {:ok, os_pid} ->
        track(proc, os_pid, mark)

      :gone ->
        :ok

      # Not provably gone, and no pid to record it under: stop it, as a
      # failed record stops it, rather than let it run untracked.
      {:error, reason} ->
        stop_untracked(proc, nil)
        {:error, {:untracked, reason}}
    end
  end

  # Only the documented gone signals read as gone: Exile answering a bare
  # `:undefined` (not an error tuple) once the port is closed, which a
  # program that exits at once can reach before this call, and a `:noproc`
  # exit once its Exile process has ended. Anything else — another return, a
  # timeout exit — leaves the program possibly alive with no pid read.
  defp os_pid_of(proc) do
    case Proc.os_pid(proc) do
      {:ok, os_pid} -> {:ok, os_pid}
      :undefined -> :gone
      other -> {:error, {:os_pid, other}}
    end
  catch
    :exit, {:noproc, _} -> :gone
    :exit, reason -> {:error, {:os_pid, {:exit, reason}}}
  end

  defp track(proc, os_pid, mark) do
    with {:error, reason} <- HalC2.Subprocess.Orphans.track(proc.pid, os_pid, mark) do
      stop_untracked(proc, os_pid)
      {:error, {:untracked, reason}}
    end
  end

  # The error return hands no handle back, and some callers live on after it, so the
  # program must not: if the kill does not take, the Exile process itself is ended
  # (unlinked first, so its death does not take the caller), closing its port. That
  # only closes the program's stdin, which it may not exit on, so the program itself
  # is then checked: one still running is said to run untracked, as in the timeout
  # below. A kill that failed only because the program had already exited needs
  # neither the warning nor the port kill.
  defp stop_untracked(proc, os_pid) do
    with :ok <- Proc.kill(proc, :sigkill),
         {:ok, _status} <- Proc.await_exit(proc, 2_000) do
      :ok
    else
      failed ->
        if os_pid != nil and HalC2.Subprocess.Orphans.gone?(os_pid) do
          :ok
        else
          Logger.warning(
            "program #{os_pid} would run untracked, its kill gave #{inspect(failed)}; " <>
              "stopping its port process instead"
          )

          ref = Process.monitor(proc.pid)
          Process.unlink(proc.pid)
          Process.exit(proc.pid, :kill)

          receive do
            {:DOWN, ^ref, :process, _, _} ->
              cond do
                os_pid == nil ->
                  Logger.warning(
                    "a program whose pid could not be read may run untracked: " <>
                      "its port process ended, which closes its stdin"
                  )

                await_gone(os_pid) ->
                  :ok

                true ->
                  Logger.warning(
                    "program #{os_pid} runs untracked: it stayed after its port process ended"
                  )
              end
          after
            2_000 ->
              # No stray DOWN for a caller that never made this monitor.
              Process.demonitor(ref, [:flush])
              Logger.warning("program #{os_pid} runs untracked: its port process stayed")
          end
        end
    end
  catch
    # The kill or the wait itself exiting (a wedged Exile process timing out)
    # must not silence the outcome this function exists to announce: unless
    # the program is provably gone, say it may run untracked.
    :exit, reason ->
      if os_pid != nil and HalC2.Subprocess.Orphans.gone?(os_pid) do
        :ok
      else
        Logger.warning(
          "program #{os_pid} may run untracked: stopping it exited #{inspect(reason)}"
        )

        :ok
      end
  end

  # A program that does exit on its closed stdin needs a moment to, so "gone" is
  # awaited, bounded, rather than read once. Nothing signals a process other than
  # its parent that it exited, so its state is what can be read.
  defp await_gone(os_pid, tries \\ 50) do
    cond do
      HalC2.Subprocess.Orphans.gone?(os_pid) ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        await_gone(os_pid, tries - 1)
    end
  end

  @spec write_line(t, iodata) :: :ok | {:error, term}
  def write_line(%__MODULE__{proc: proc}, line), do: Proc.write(proc, [line, ?\n])

  @spec ack(t) :: :ok
  def ack(%__MODULE__{reader: reader}) do
    send(reader, :ack)
    :ok
  end

  @spec os_pid(t) :: pos_integer
  def os_pid(%__MODULE__{durable: %{dir: dir}}) do
    %{"pid" => pid} = JSON.decode!(File.read!(Path.join(dir, "meta")))
    pid
  end

  def os_pid(%__MODULE__{proc: proc}) do
    {:ok, pid} = Proc.os_pid(proc)
    pid
  end

  @doc """
  The exit status in `message`, when it is an owned program's exit as Exile sends it to
  the owner. That can arrive before its output ends, and `stop/2` cannot get it once
  the owner has taken it from its mailbox, so an owner that receives every message
  keeps it from here.
  """
  @spec exit_status(t, term) :: {:ok, non_neg_integer} | :error
  def exit_status(%__MODULE__{durable: nil, proc: %Proc{exit_ref: ref}}, {ref, {:ok, status}}),
    do: {:ok, status}

  def exit_status(_sub, _message), do: :error

  @doc "Closes stdin and waits for the program to exit, escalating to signals after `timeout`."
  @spec stop(t, timeout) :: {:ok, non_neg_integer} | term
  def stop(sub, timeout \\ 2_000)

  # A program the MC keeps running across its own stop only loses its helper; any
  # other stop ends it, and it cannot hear a closed stdin (the shim holds it open).
  def stop(%__MODULE__{durable: %{dir: dir}} = sub, timeout) do
    # In this order: the watcher kills a program whose helper ends in a running MC, which
    # must not beat the polite signal; a program the MC keeps must not be stopped at all.
    if HalC2.Orchestration.Recovery.stopping?() do
      detach(sub)
      :detached
    else
      result = Durable.stop(dir, timeout)
      detach(sub)
      result
    end
  end

  def stop(%__MODULE__{proc: proc}, timeout) do
    Proc.close_stdin(proc)
    Proc.await_exit(proc, timeout)
  catch
    # With no pipe left open, Exile's process ends as soon as the program does, so it
    # may be gone before it is asked. It mailed the program's exit status first.
    :exit, reason ->
      receive do
        {ref, status} when ref == proc.exit_ref -> status
      after
        0 -> exit(reason)
      end
  end

  # Stdin closed first, so what was written still reaches the program: the helper ends
  # once it has passed that on, and its output ending ends the reader. Then the port
  # process goes, not through Exile's own stop, which exits `:kill_timeout` at its linked
  # owner when the helper is gone.
  defp detach(%__MODULE__{proc: proc, reader: reader}) do
    Process.unlink(reader)
    drained = Process.monitor(reader)

    try do
      Proc.close_stdin(proc)
    catch
      :exit, _ -> :ok
    end

    send(reader, :ack)

    receive do
      {:DOWN, ^drained, :process, _, _} -> :ok
    after
      500 ->
        Process.demonitor(drained, [:flush])
        Process.exit(reader, :kill)
    end

    ref = Process.monitor(proc.pid)
    Process.unlink(proc.pid)
    Process.exit(proc.pid, :kill)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      1_000 -> Process.demonitor(ref, [:flush])
    end
  end

  @doc false
  def durable_reader_init(proc, owner, offset) do
    receive do: (:owned -> :ok)
    __MODULE__.durable_reader_loop(proc, owner, "", offset)
  end

  @doc false
  # As `reader_loop/3`, counting the bytes of whole lines so a later MC reads on
  # from there, and ending at the shim's report rather than at end of file: the
  # output is a file, which has no end while the helper follows it.
  def durable_reader_loop(proc, owner, partial, offset) do
    case Proc.read(proc, @read_size) do
      {:ok, data} ->
        data = IO.iodata_to_binary(data)
        {lines, rest} = split_lines(partial, data)
        offset = offset + line_bytes(partial) + byte_size(data) - line_bytes(rest)
        {lines, ended} = Enum.split_while(lines, &(not Durable.exit_line?(&1)))

        if lines != [] do
          send(owner, {:subprocess_lines, self(), lines})
          send(owner, {:subprocess_offset, self(), offset})
          receive do: (:ack -> :ok)
        end

        if ended == [] do
          __MODULE__.durable_reader_loop(proc, owner, rest, offset)
        else
          send(owner, {:subprocess_eof, self()})
        end

      _eof_or_error ->
        send(owner, {:subprocess_eof, self()})
    end
  end

  @doc false
  def reader_init(proc, owner) do
    receive do: (:owned -> :ok)
    __MODULE__.reader_loop(proc, owner, "")
  end

  @doc false
  def reader_loop(proc, owner, partial) do
    case Proc.read(proc, @read_size) do
      {:ok, data} ->
        {lines, rest} = split_lines(partial, IO.iodata_to_binary(data))

        if lines != [] do
          send(owner, {:subprocess_lines, self(), lines})
          receive do: (:ack -> :ok)
        end

        __MODULE__.reader_loop(proc, owner, rest)

      _eof_or_error ->
        if is_binary(partial) and partial != "",
          do: send(owner, {:subprocess_lines, self(), [partial]})

        send(owner, {:subprocess_eof, self()})
    end
  end

  # The bytes an unsplit rest holds; a dropped line's rest (`:skip`) holds none.
  defp line_bytes(:skip), do: 0
  defp line_bytes(partial), do: byte_size(partial)

  @doc false
  def stderr_init(proc, owner, prefix, tail \\ nil) do
    receive do: (:owned -> :ok)
    __MODULE__.stderr_loop(proc, owner, prefix, "", tail)
  end

  # The loop a reader started before `:stderr_tail` existed runs on here.
  @doc false
  def stderr_loop(proc, owner, prefix, partial),
    do: __MODULE__.stderr_loop(proc, owner, prefix, partial, nil)

  # `tail` is nil when it is not kept, else the end of stderr so far.
  @doc false
  def stderr_loop(proc, owner, prefix, partial, tail) do
    case Proc.read_stderr(proc, @read_size) do
      {:ok, data} ->
        data = IO.iodata_to_binary(data)
        {lines, rest} = if prefix, do: prefixed_lines(partial, data, prefix), else: {[], ""}
        if lines != [], do: send(owner, {:subprocess_stderr, self(), lines})
        __MODULE__.stderr_loop(proc, owner, prefix, rest, keep_tail(tail, data))

      _eof_or_error ->
        {lines, _} = if prefix, do: prefixed_lines(partial, "\n", prefix), else: {[], ""}
        if lines != [], do: send(owner, {:subprocess_stderr, self(), lines})
        if tail, do: hand_over_tail(tail)
    end
  catch
    :exit, _ -> :ok
  end

  defp keep_tail(nil, _data), do: nil

  defp keep_tail(tail, data) do
    kept = tail <> data
    size = byte_size(kept)

    if size > @tail_bytes,
      do: :binary.copy(binary_part(kept, size - @tail_bytes, @tail_bytes)),
      else: kept
  end

  # The reader outlives the program's stderr until the owner asks for its end, or a
  # while has gone by and nobody will.
  defp hand_over_tail(tail) do
    receive do
      {:stderr_tail, from, ref} -> send(from, {ref, tail})
    after
      10_000 -> :ok
    end
  end

  @doc """
  The last lines a program started with `:stderr_tail` wrote to stderr, without colour
  codes or blank lines: "" when there are none or it was not kept. Asked once the
  program has ended (its output has); a program still running is waited on for at most
  `timeout`.
  """
  @spec stderr_tail(t, timeout) :: String.t()
  def stderr_tail(sub, timeout \\ 1_000)

  def stderr_tail(%__MODULE__{durable: %{dir: dir}}, _timeout),
    do: dir |> Durable.stderr_tail(@tail_bytes) |> last_lines()

  def stderr_tail(%__MODULE__{errors: errors}, timeout) when is_pid(errors) do
    ref = Process.monitor(errors)
    send(errors, {:stderr_tail, self(), ref})

    receive do
      {^ref, tail} ->
        Process.demonitor(ref, [:flush])
        last_lines(tail)

      {:DOWN, ^ref, :process, _, _} ->
        ""
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        ""
    end
  end

  def stderr_tail(_sub, _timeout), do: ""

  @doc false
  def last_lines(text) do
    text
    |> String.replace(~r/\e\[[0-9;?]*[A-Za-z]/, "")
    |> String.replace_invalid()
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-@tail_lines)
    |> Enum.join("\n")
  end

  @doc """
  Splits `partial <> data` into whole lines and keeps those that start with
  `prefix`, without a trailing `\\r`: `{lines, rest}`. A line that outgrows the
  limit is dropped, and so is the rest of it as it arrives (`rest` is then `:skip`
  until the next newline).
  """
  def prefixed_lines(partial, data, prefix) do
    case :binary.split(data, "\n", [:global]) do
      [tail] ->
        {[], grow(partial, tail)}

      [head | parts] ->
        {middle, [tail]} = Enum.split(parts, -1)
        first = if partial == :skip, do: [], else: [partial <> head]

        lines =
          for line <- first ++ middle,
              byte_size(line) <= @max_stderr_line,
              String.starts_with?(line, prefix),
              do: line |> String.trim_trailing("\r") |> :binary.copy()

        {lines, grow("", tail)}
    end
  end

  defp grow(:skip, _data), do: :skip

  defp grow(partial, data) do
    if byte_size(partial) + byte_size(data) > @max_stderr_line,
      do: :skip,
      else: :binary.copy(partial <> data)
  end

  @doc """
  Splits `partial <> data` into whole lines: `{lines, rest}`. A line longer
  than `max` bytes is dropped, and so is the rest of it as it arrives (`rest`
  is then `:skip` until the next newline), so one oversized message neither
  reaches the owner nor piles up in the reader. Lines are copied so a
  retained line never pins the whole read chunk.
  """
  def split_lines(partial, data, max \\ @max_line) do
    case :binary.split(data, "\n", [:global]) do
      [tail] ->
        {[], grow_line(partial, tail, max)}

      [head | parts] ->
        {middle, [tail]} = Enum.split(parts, -1)
        first = if partial == :skip, do: [], else: [partial <> head]

        lines =
          for line <- first ++ middle,
              line != "",
              byte_size(line) <= max,
              do: :binary.copy(line)

        {lines, grow_line("", tail, max)}
    end
  end

  defp grow_line(:skip, _data, _max), do: :skip

  defp grow_line(partial, data, max) do
    if byte_size(partial) + byte_size(data) > max,
      do: :skip,
      else: :binary.copy(partial <> data)
  end
end
