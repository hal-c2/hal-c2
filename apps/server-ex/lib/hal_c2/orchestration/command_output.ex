defmodule HalC2.Orchestration.CommandOutput do
  @moduledoc """
  Whether a command's output says it failed though the provider reported it completed:
  a missing file or command, a PowerShell error, or a non-zero exit code in the text
  (`toolOutput.ts`). Clients never receive the output, so the MC marks the command
  `outputIndicatesFailure` when it finishes.
  """

  @failures ~r/file not found|no files found|enoent|no such file|commandnotfoundexception|command not found|is not recognized as the name of a cmdlet|a parameter cannot be found that matches parameter name/i
  @exit_codes [
    ~r/<exited with exit code\s+[1-9]\d*\s*>/i,
    ~r/exit(?:ed)? with exit code\s+[1-9]\d*/i,
    ~r/exit code\s*[:\s]\s*[1-9]\d*\b/i
  ]

  @doc "Whether `output` reads as a failure."
  @spec failed?(term) :: boolean
  def failed?(output) when is_binary(output) do
    # A long output says how it ended near its start or not at all; reading all of it costs.
    output = binary_part(output, 0, min(byte_size(output), 32_768))
    lower = String.downcase(output)

    Regex.match?(@failures, output) or
      (String.contains?(lower, "cannot find path") and
         String.contains?(lower, "because it does not exist")) or
      (String.contains?(lower, "is not recognized") and String.contains?(lower, "the term '")) or
      Enum.any?(@exit_codes, &Regex.match?(&1, output))
  end

  def failed?(_output), do: false
end
