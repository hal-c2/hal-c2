defmodule HalC2.WorktreeSetupScriptPropTest do
  @moduledoc """
  Which script `HalC2.WorktreeSetup.setup_script/2` picks for a new worktree: the first
  of the project's saved actions marked to run on worktree creation; only when none is
  marked, the first the worktree's `hal-c2.json` marks; nothing when the file is
  missing, malformed or does not match the format. Settings are left empty, so the
  saved actions are the project's own (the settings tiers have plain tests).
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.WorktreeSetup

  defp script do
    let {name, marked, blocking} <- {oneof(~w(a b c d)), boolean(), boolean()} do
      %{"name" => name, "command" => "echo #{name}", "runOnWorktreeCreate" => marked}
      |> then(&if(blocking, do: Map.put(&1, "async", false), else: &1))
    end
  end

  defp scripts, do: resize(4, list(script()))

  defp file,
    do: frequency([{4, {:valid, scripts()}}, {1, :missing}, {1, :malformed}, {1, :invalid}])

  property "a file's setup script runs only when no saved action is one",
    numtests: HalC2.Prop.numtests(200) do
    forall {saved, file} <- {scripts(), file()} do
      dir = HalC2.Prop.scratch_home("worktree-setup-script")
      write(dir, file)
      picked = WorktreeSetup.setup_script(%{"id" => "p1", "scripts" => saved}, dir)
      File.rm_rf!(dir)

      declared =
        case file do
          {:valid, listed} -> listed
          _ -> []
        end

      expected =
        Enum.find(saved, & &1["runOnWorktreeCreate"]) ||
          Enum.find(declared, & &1["runOnWorktreeCreate"])

      (picked == expected)
      |> when_fail(IO.inspect({saved, file, picked}, label: "saved, file, picked"))
    end
  end

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
