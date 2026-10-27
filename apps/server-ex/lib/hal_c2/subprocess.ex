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
  agent's stderr can carry credentials.

  Exile stops the program when its owner exits, but not when the VM dies;
  `HalC2.Subprocess.Orphans` records each program so the next boot kills those.

  Reader loops recurse through fully qualified calls, so a hot code load moves them
  onto the new module version at the next chunk.
  """

  alias Exile.Process, as: Proc

  require Logger

  @enforce_keys [:proc, :reader]
  defstruct [:proc, :reader]

  @type t :: %__MODULE__{proc: Proc.t(), reader: pid}

  @read_size 65_535
  # A stderr line longer than this is dropped unread; prefixed lines are short.
  @max_stderr_line 65_536

  @spec start([String.t()], keyword) :: {:ok, t} | {:error, term}
  def start(cmd, opts \\ []) do
    cmd = spawn_command(cmd)
    {prefix, opts} = Keyword.pop(opts, :stderr_prefix)
    stderr = if prefix, do: :consume, else: :disable

    with :ok <- trackable(),
         {:ok, proc} <- Proc.start_link(cmd, Keyword.put_new(opts, :stderr, stderr)),
         :ok <- track(proc) do
      owner = self()
      reader = spawn_link(fn -> reader_init(proc, owner) end)
      :ok = Proc.change_pipe_owner(proc, :stdout, reader)
      send(reader, :owned)

      if prefix do
        # Unlinked: stderr closing on its own must not stop the owner. The reader
        # dies with the program, when its read fails.
        errors = spawn(fn -> stderr_init(proc, owner, prefix) end)
        :ok = Proc.change_pipe_owner(proc, :stderr, errors)
        send(errors, :owned)
      end

      {:ok, %__MODULE__{proc: proc, reader: reader}}
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
  # `Orphans.track/2`.
  defp track(proc) do
    case os_pid_of(proc) do
      {:ok, os_pid} ->
        track(proc, os_pid)

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

  defp track(proc, os_pid) do
    with {:error, reason} <- HalC2.Subprocess.Orphans.track(proc.pid, os_pid) do
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
  def os_pid(%__MODULE__{proc: proc}) do
    {:ok, pid} = Proc.os_pid(proc)
    pid
  end

  @doc "Closes stdin and waits for the program to exit, escalating to signals after `timeout`."
  @spec stop(t, timeout) :: {:ok, non_neg_integer} | term
  def stop(%__MODULE__{proc: proc}, timeout \\ 2_000) do
    Proc.close_stdin(proc)
    Proc.await_exit(proc, timeout)
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
        {lines, rest} = split_lines(partial <> IO.iodata_to_binary(data))

        if lines != [] do
          send(owner, {:subprocess_lines, self(), lines})
          receive do: (:ack -> :ok)
        end

        __MODULE__.reader_loop(proc, owner, rest)

      _eof_or_error ->
        if partial != "", do: send(owner, {:subprocess_lines, self(), [partial]})
        send(owner, {:subprocess_eof, self()})
    end
  end

  @doc false
  def stderr_init(proc, owner, prefix) do
    receive do: (:owned -> :ok)
    __MODULE__.stderr_loop(proc, owner, prefix, "")
  end

  @doc false
  def stderr_loop(proc, owner, prefix, partial) do
    case Proc.read_stderr(proc, @read_size) do
      {:ok, data} ->
        {lines, rest} = prefixed_lines(partial, IO.iodata_to_binary(data), prefix)
        if lines != [], do: send(owner, {:subprocess_stderr, self(), lines})
        __MODULE__.stderr_loop(proc, owner, prefix, rest)

      _eof_or_error ->
        {lines, _} = prefixed_lines(partial, "\n", prefix)
        if lines != [], do: send(owner, {:subprocess_stderr, self(), lines})
    end
  catch
    :exit, _ -> :ok
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

  # Lines are copied so a retained line never pins the whole read chunk.
  @doc false
  def split_lines(buffer) do
    case :binary.split(buffer, "\n", [:global]) do
      [rest] ->
        {[], rest}

      parts ->
        {lines, [rest]} = Enum.split(parts, -1)
        {for(l <- lines, l != "", do: :binary.copy(l)), :binary.copy(rest)}
    end
  end
end
