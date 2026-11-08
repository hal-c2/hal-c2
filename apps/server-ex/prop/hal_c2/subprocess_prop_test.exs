defmodule HalC2.SubprocessPropTest do
  @moduledoc """
  The line filters of `HalC2.Subprocess`: however a program's output is cut into
  reads, the owner gets exactly the whole lines that fit the line limit, in
  order — on stderr only those that start with the prefix, without a trailing
  `\\r`; on stdout every non-empty one (`split_lines/3`, whose limit is 8 MiB
  in the readers and small here). Reads are pure here, so these are plain
  `forall`s.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Subprocess

  @prefix "Open: "
  @limit 65_536

  property "stderr reads yield the prefixed lines, however they are cut",
    numtests: HalC2.Prop.numtests(200),
    max_size: 30 do
    forall lines <- list(line()) do
      text = Enum.map(lines, fn parts -> parts |> Enum.reject(&(&1 == :cut)) |> Enum.join() end)

      expected =
        for line <- text,
            byte_size(line) <= @limit,
            String.starts_with?(line, @prefix),
            do: String.trim_trailing(line, "\r")

      received = lines |> Enum.flat_map(&(&1 ++ ["\n"])) |> chunks() |> feed()

      (received == expected)
      |> when_fail(IO.puts("expected #{inspect(expected)}\nreceived #{inspect(received)}"))
    end
  end

  @line_limit 64

  property "stdout reads yield the lines that fit, however they are cut",
    numtests: HalC2.Prop.numtests(200),
    max_size: 30 do
    forall lines <- list(stdout_line()) do
      text = Enum.map(lines, fn parts -> parts |> Enum.reject(&(&1 == :cut)) |> Enum.join() end)

      expected =
        for line <- text, line != "", byte_size(line) <= @line_limit, do: line

      received = lines |> Enum.flat_map(&(&1 ++ ["\n"])) |> chunks() |> feed_stdout()

      (received == expected)
      |> when_fail(IO.puts("expected #{inspect(expected)}\nreceived #{inspect(received)}"))
    end
  end

  # What a stdout reader sends: each read's whole lines that fit the limit.
  defp feed_stdout(chunks) do
    {lines, _partial} =
      Enum.reduce(chunks, {[], ""}, fn chunk, {acc, partial} ->
        {lines, rest} = Subprocess.split_lines(partial, chunk, @line_limit)
        {acc ++ lines, rest}
      end)

    lines
  end

  # Lines around the limit, with read boundaries (`:cut`) anywhere in them.
  defp stdout_line do
    let parts <- list(oneof(["abc", "x", "", "hello world", :long, :edge, :cut])) do
      Enum.map(parts, fn
        :long -> String.duplicate("y", @line_limit + 1)
        :edge -> String.duplicate("z", @line_limit - 3)
        part -> part
      end)
    end
  end

  # What the stderr reader sends: each read's lines, then the rest at end of file.
  defp feed(chunks) do
    {lines, partial} =
      Enum.reduce(chunks, {[], ""}, fn chunk, {acc, partial} ->
        {lines, rest} = Subprocess.prefixed_lines(partial, chunk, @prefix)
        {acc ++ lines, rest}
      end)

    {last, _} = Subprocess.prefixed_lines(partial, "\n", @prefix)
    lines ++ last
  end

  # The reads a stream arrives in: a read ends at every `:cut`.
  defp chunks(parts) do
    parts
    |> Enum.chunk_by(&(&1 == :cut))
    |> Enum.reject(&(hd(&1) == :cut))
    |> Enum.map(&Enum.join/1)
  end

  # Lines that start with the prefix or nearly do, with stray carriage returns, some
  # longer than the limit, and read boundaries (`:cut`) anywhere in them.
  defp line do
    let parts <-
          list(oneof([@prefix, "Open:", "O", "x", "\r", "https://a?b", :long, :edge, :cut])) do
      Enum.map(parts, fn
        :long -> String.duplicate("y", @limit + 1)
        :edge -> String.duplicate("z", @limit - byte_size(@prefix))
        part -> part
      end)
    end
  end
end
