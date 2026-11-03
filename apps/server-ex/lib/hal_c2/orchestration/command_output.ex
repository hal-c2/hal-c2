defmodule HalC2.Orchestration.CommandOutput do
  @moduledoc """
  Whether a command's output says it failed though the provider reported it completed:
  a missing file or command, a PowerShell error, or a non-zero exit code in the text
  (`toolOutput.ts`). Clients never receive the output, so the MC marks the command
  `outputIndicatesFailure` when it finishes.
  """

  # A missing file or command counts only on a line that reads as a diagnostic: one that
  # starts with the phrase; with a program's name, a colon and a space (`cat: x: No such
  # file`); or with a program's path, as a shell or `env` names what it ran
  # (`/bin/bash: line 1: foo: command not found`, `/usr/bin/env: 'python': No such file`).
  # A file that merely mentions ENOENT is not a failure, nor is a search match, which
  # starts with a path, a line number, or both. Accepted at the edges: a match in an
  # extensionless file at the search's root (`Makefile:    # no such file`) still reads as
  # one, and a path-named program reporting a plain name (`/bin/bash: foo: command not
  # found`, bash before 5.1) does not.
  @missing ~r/^(?:(?:[a-z][\w-]*:\s|[\w.\/~-]+:\s(?:line \d+:|'[^'\n]*':|"[^"\n]*":)).*)?(?:file not found|no files found|enoent|no such file|command not found)/im
  @powershell ~r/commandnotfoundexception|is not recognized as the name of a cmdlet|a parameter cannot be found that matches parameter name/i
  @exit_codes [
    ~r/<exited with exit code\s+[1-9]\d*\s*>/i,
    ~r/exit(?:ed)? with exit code\s+[1-9]\d*/i,
    ~r/exit code\s*[:\s]\s*[1-9]\d*\b/i
  ]

  @doc "Whether `output` reads as a failure."
  @spec failed?(term) :: boolean
  def failed?(output) when is_binary(output) do
    output = ends(output)
    lower = String.downcase(output)

    Regex.match?(@missing, output) or Regex.match?(@powershell, output) or
      (String.contains?(lower, "cannot find path") and
         String.contains?(lower, "because it does not exist")) or
      (String.contains?(lower, "is not recognized") and String.contains?(lower, "the term '")) or
      Enum.any?(@exit_codes, &Regex.match?(&1, output))
  end

  def failed?(_output), do: false

  @half 16_384

  # A long output's first and last 16 KB: an error shows near its start, an exit code at
  # its end, and reading all of it costs.
  defp ends(output) when byte_size(output) <= 2 * @half, do: output

  defp ends(output),
    do: binary_part(output, 0, @half) <> "\n" <> binary_part(output, byte_size(output), -@half)
end
