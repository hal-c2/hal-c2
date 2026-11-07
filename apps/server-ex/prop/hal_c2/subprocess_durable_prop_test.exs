defmodule HalC2.SubprocessDurablePropTest do
  @moduledoc """
  `HalC2.Subprocess.Durable` against its lifecycle promises: whichever order lines
  are sent, read, and the MC leaves and comes back in, the program stays the same one
  and every line it wrote reaches the MC once, in order, from the last checkpoint.
  Files made in its launch directory survive those same restarts and go with its final
  stop, or with the uninstall that stops what a leaving MC kept.
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.Orchestration.Recovery
  alias HalC2.Subprocess
  alias HalC2.Subprocess.Durable
  alias HalC2.Subprocess.Orphans

  @moduletag timeout: :infinity
  @moduletag capture_log: true
  @echo ["sh", "-c", ~s(while read l; do echo "$l"; done)]

  property "lines and launch files survive restarts, and final stop or uninstall removes them",
    numtests: HalC2.Prop.numtests(15) do
    forall {ops, ending} <- {list(oneof([:send, :drain, :restart])), oneof([:stop, :uninstall])} do
      HalC2.Prop.scratch_home("durable")
      flush()
      Application.put_env(:hal_c2, :durable_programs, true)

      launch = fn dir ->
        path = Path.join(dir, "launch-config")
        File.write!(path, "secret")
        File.chmod!(path, 0o600)
        @echo
      end

      {:ok, sub} = Subprocess.start(launch, durable: "t1")
      pid = Subprocess.os_pid(sub)
      dir = sub.durable.dir
      config = Path.join(dir, "launch-config")
      world = %{sub: sub, n: 0, read: [], offset: 0}
      world = Enum.reduce(ops ++ [:drain], world, &step/2)
      same = Subprocess.os_pid(world.sub) == pid
      kept = File.read!(config) == "secret"
      finish(ending, world.sub)
      removed = not File.exists?(dir) and Orphans.gone?(pid)
      Application.put_env(:hal_c2, :durable_programs, false)
      expected = Enum.map(1..world.n//1, &"#{&1}")

      (same and kept and removed and world.read == expected)
      |> when_fail(
        IO.puts(
          "ending: #{ending}, same program: #{same}, config kept: #{kept}, removed: #{removed}, " <>
            "read #{inspect(world.read)}, sent #{world.n}"
        )
      )
    end
  end

  defp step(:send, world) do
    n = world.n + 1
    :ok = Subprocess.write_line(world.sub, "#{n}")
    %{world | n: n}
  end

  # Whatever it has, up to everything once it is told to wait for it.
  defp step(:drain, %{sub: %{reader: reader}} = world) do
    if length(world.read) >= world.n do
      world
    else
      receive do
        {:subprocess_lines, ^reader, lines} ->
          Subprocess.ack(world.sub)
          step(:drain, %{world | read: world.read ++ lines})

        {:subprocess_offset, ^reader, offset} ->
          step(:drain, %{world | offset: offset})
      after
        5_000 -> world
      end
    end
  end

  # Only what a checkpoint accounts for counts as read: the rest comes again.
  defp step(:restart, world) do
    world = settle(world)
    Recovery.leaving(true)
    :detached = Subprocess.stop(world.sub)
    Recovery.leaving(false)
    flush()
    true = Durable.attachable?(world.sub.durable.dir)
    {:ok, sub} = Subprocess.adopt(world.sub.durable.dir, world.offset)
    %{world | sub: sub}
  end

  defp finish(:stop, sub), do: Subprocess.stop(sub)

  # The MC leaves the program running, then its service is removed for good.
  defp finish(:uninstall, sub) do
    Recovery.leaving(true)
    :detached = Subprocess.stop(sub)
    Recovery.leaving(false)
    flush()
    Durable.stop_all()
  end

  defp settle(%{sub: %{reader: reader}} = world) do
    receive do
      {:subprocess_lines, ^reader, lines} ->
        Subprocess.ack(world.sub)
        settle(%{world | read: world.read ++ lines})

      {:subprocess_offset, ^reader, offset} ->
        settle(%{world | offset: offset})
    after
      20 -> world
    end
  end

  defp flush do
    receive do
      {tag, _, _} when tag in [:subprocess_lines, :subprocess_offset] -> flush()
      {:subprocess_eof, _} -> flush()
    after
      0 -> :ok
    end
  end
end
