defmodule HalC2.AcpStderrPropTest do
  @moduledoc """
  `HalC2.Acp.Stderr.sanitize/2`: whatever an agent wrote around a secret, the shown
  error output keeps none of the secret's body and fits in the room it is given.
  """
  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Acp.Stderr

  defp word(chars),
    do: let(cs <- non_empty(list(oneof(chars))), do: to_string(cs))

  defp alnum, do: Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z) ++ ~c"0123456789"

  # Filler an agent might print: words, spaces and newlines, never a secret prefix.
  defp filler,
    do:
      let(
        parts <- list(oneof([word(Enum.to_list(?a..?j)), " ", "\n", ": "])),
        do: Enum.join(parts)
      )

  # A key's body, as long as real ones are (`sk-` keys shorter than eight are not keys).
  defp key(chars), do: let(cs <- vector(8, oneof(chars)), do: to_string(cs))

  # A secret, and the body of it that must not survive.
  defp secret do
    body = let({k, b} <- {key(alnum() ++ ~c"_-"), word(alnum() ++ ~c"_-")}, do: k <> b)

    oneof([
      let(b <- body, do: {"sk-ant-api03-Q#{b}", "Q#{b}"}),
      let(b <- body, do: {"sk-proj-Q#{b}", "Q#{b}"}),
      let(b <- word(alnum()), do: {"ghp_Q#{b}", "Q#{b}"}),
      let(b <- word(alnum()), do: {"Bearer Q#{b}", "Q#{b}"}),
      let(b <- word(alnum()), do: {"x-api-key: Q#{b}", "Q#{b}"}),
      let(b <- word(alnum()), do: {"https://mc.example/pair#token=Q#{b}", "Q#{b}"})
    ])
  end

  property "no secret's body survives, and the result fits" do
    forall {before, {secret, body}, rest, room} <-
             {filler(), secret(), filler(), integer(1, 4_096)} do
      shown = Stderr.sanitize("#{before} #{secret} #{rest}", room)
      not String.contains?(shown, body) and String.length(shown) <= room
    end
  end

  property "text without secrets or the home directory is only trimmed" do
    forall text <- filler() do
      Stderr.sanitize(text) == text |> String.slice(-4_096..-1//1) |> String.trim()
    end
  end
end
