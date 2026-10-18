defmodule HalC2.MachineFiles.Helper do
  @moduledoc """
  The machine-files helper (native/machine-files) as `HalC2.MachineFiles` runs it: a
  port whose stdin and stdout carry 9P, and the FUSE mount it keeps at the root.

  The port is the only link to it. When this MC stops, however it stops, the
  helper's input ends and it unmounts; only a helper killed outright leaves a stale
  mount, which `recover/1` clears before the next one mounts there.
  """

  require Logger

  @name "hal-c2-machine-files"
  # Built by `vp run build:machine-files` in a checkout; a release bundles it in priv/bin.
  @checkout Path.expand("../../../../../native/machine-files/target", __DIR__)

  @doc """
  Whether this machine can show the folders: `:ok`, or `{:error, reason}` with
  `:unsupported` (not Linux yet), `:no_fuse` (no /dev/fuse or fusermount3) or
  `:no_helper` (no helper binary).
  """
  @spec available() :: :ok | {:error, :unsupported | :no_fuse | :no_helper}
  def available do
    cond do
      :os.type() != {:unix, :linux} -> {:error, :unsupported}
      not File.exists?("/dev/fuse") or fusermount() == nil -> {:error, :no_fuse}
      binary() == nil -> {:error, :no_helper}
      true -> :ok
    end
  end

  @doc "The helper binary: the configured one, the release's, the checkout's, or PATH's."
  @spec binary() :: String.t() | nil
  def binary do
    candidates = [
      Application.get_env(:hal_c2, :machine_files_helper),
      Application.app_dir(:hal_c2, "priv/bin/#{@name}"),
      Path.join([@checkout, "release", @name]),
      Path.join([@checkout, "debug", @name])
    ]

    Enum.find(candidates, &(is_binary(&1) and File.regular?(&1))) ||
      System.find_executable(@name)
  end

  @doc "Starts the helper mounting at `root`: `{:ok, port, os_pid}`."
  @spec open(String.t(), keyword) :: {:ok, port, non_neg_integer} | {:error, term}
  def open(root, opts) do
    args = [root, "--ttl-ms", Integer.to_string(Keyword.get(opts, :ttl_ms, 1_000))]

    port =
      Port.open({:spawn_executable, binary()}, [:binary, :stream, :exit_status, args: args])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {:ok, port, os_pid}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  @doc "Sends 9P bytes to the helper."
  def send(port, iodata), do: Port.command(port, iodata)

  @doc "Closes the port; the helper unmounts what is left and exits."
  def close(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  @doc "Unmounts `root` if mounted, waiting for it; lazily if it is busy."
  def unmount(root) do
    if mounted?(root) do
      case fusermount(["-u", root]) do
        {_, 0} -> :ok
        _busy -> fusermount(["-u", "-z", root])
      end
    end

    :ok
  end

  @doc """
  Readies `root` to mount at: clears a mount left by a helper that did not get to
  unmount (one the kernel still lists, or one that answers ENOTCONN), then makes it
  and the directory it sits in this user's alone.
  """
  def prepare(root) do
    if mounted?(root) or File.stat(root) == {:error, :enotconn} do
      Logger.info("clearing the stale machines folder at #{root}")
      fusermount(["-u", "-z", root])
    end

    HalC2.Paths.mkdir_private!(root)
    File.chmod!(Path.dirname(Path.expand(root)), 0o700)
  rescue
    e in File.Error -> {:error, Exception.message(e)}
  end

  @doc "Whether the kernel lists a mount at `root` for this process."
  @spec mounted?(String.t()) :: boolean
  def mounted?(root) do
    root = Path.expand(root)

    case File.read("/proc/self/mountinfo") do
      {:ok, info} ->
        info
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line ->
          case String.split(line, " ") do
            [_id, _parent, _dev, _root, point | _] -> unescape(point) == root
            _ -> false
          end
        end)

      {:error, _} ->
        false
    end
  end

  @doc "The options the kernel lists for the mount at `root`, or nil."
  @spec mount_options(String.t()) :: String.t() | nil
  def mount_options(root) do
    root = Path.expand(root)

    with {:ok, info} <- File.read("/proc/self/mountinfo") do
      Enum.find_value(String.split(info, "\n", trim: true), fn line ->
        case String.split(line, " - ") do
          [left, right] ->
            point = left |> String.split(" ") |> Enum.at(4)
            if point && unescape(point) == root, do: right

          _ ->
            nil
        end
      end)
    else
      _ -> nil
    end
  end

  # mountinfo writes space, tab, newline and backslash as octal escapes.
  defp unescape(field),
    do: Regex.replace(~r/\\([0-7]{3})/, field, fn _, oct -> <<String.to_integer(oct, 8)>> end)

  defp fusermount, do: System.find_executable("fusermount3")

  defp fusermount(args) do
    case fusermount() do
      nil -> {"no fusermount3", 1}
      exe -> System.cmd(exe, args, stderr_to_stdout: true)
    end
  end
end
