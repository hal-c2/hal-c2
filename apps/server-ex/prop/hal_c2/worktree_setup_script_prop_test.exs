defmodule HalC2.WorktreeSetupScriptPropTest do
  @moduledoc """
  Which script `HalC2.WorktreeSetup.setup_script/3` picks for a new worktree: the first
  of the project's saved actions marked to run on worktree creation; only when none is
  marked, the first the worktree's `hal-c2.json` marks, and that one only when the main
  checkout's file marks one with the same command and the same blocking; nothing when
  the file is missing, malformed or does not match the format. Settings are left empty,
  so the saved actions are the project's own (the settings tiers have plain tests).
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.WorktreeSetup

  defp script do
    let {name, command, marked, blocking} <-
          {oneof(~w(a b c d)), oneof(~w(a b c)), boolean(), boolean()} do
      %{"name" => name, "command" => "echo #{command}", "runOnWorktreeCreate" => marked}
      |> then(&if(blocking, do: Map.put(&1, "async", false), else: &1))
    end
  end

  defp scripts, do: resize(4, list(script()))

  defp file,
    do: frequency([{4, {:valid, scripts()}}, {1, :missing}, {1, :malformed}, {1, :invalid}])

  # The main checkout's file: often the branch's own, else any other.
  defp root_file, do: frequency([{3, :same}, {3, file()}])

  property "a file's setup script runs only when no saved action is one and the main checkout's file has it",
    numtests: HalC2.Prop.numtests(200) do
    forall {saved, file, root_file} <- {scripts(), file(), root_file()} do
      root_file = if root_file == :same, do: file, else: root_file
      [root, dir] = for name <- ~w(root worktree), do: HalC2.Prop.scratch_home("setup-#{name}")
      write(dir, file)
      write(root, root_file)
      picked = WorktreeSetup.setup_script(%{"id" => "p1", "scripts" => saved}, root, dir)
      File.rm_rf!(dir)
      File.rm_rf!(root)

      saved_setup = Enum.find(saved, &setup?/1)
      file_setup = Enum.find(declared(file), &setup?/1)

      expected =
        cond do
          saved_setup ->
            {:run, saved_setup}

          file_setup == nil ->
            :none

          Enum.any?(declared(root_file), &(setup?(&1) and same?(&1, file_setup))) ->
            {:run, file_setup}

          true ->
            :skip
        end

      ((match?({:skip, _}, picked) and expected == :skip) or picked == expected)
      |> when_fail(
        IO.inspect({saved, file, root_file, picked}, label: "saved, file, root, picked")
      )
    end
  end

  defp setup?(script), do: script["runOnWorktreeCreate"]

  defp same?(a, b), do: a["command"] == b["command"] and a["async"] == b["async"]

  defp declared({:valid, listed}), do: listed
  defp declared(_), do: []

  defp write(_dir, :missing), do: :ok

  defp write(dir, {:valid, listed}),
    do: File.write!(Path.join(dir, "hal-c2.json"), JSON.encode!(%{"scripts" => listed}))

  defp write(dir, :malformed), do: File.write!(Path.join(dir, "hal-c2.json"), ~s({"scripts": [))

  # A file that does not match the format declares no script, even marked ones.
  defp write(dir, :invalid) do
    script = %{"name" => "x", "command" => "x", "icon" => "rocket", "runOnWorktreeCreate" => true}
    File.write!(Path.join(dir, "hal-c2.json"), JSON.encode!(%{"scripts" => [script]}))
  end
end
