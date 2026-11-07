defmodule HalC2.ProjectClonesRedactPropTest do
  @moduledoc """
  `HalC2.ProjectClones.redact/1`: whatever credentials a pasted clone address carries,
  the reported address has none, and the rest of the address is untouched.
  """
  use ExUnit.Case, async: true
  use PropCheck

  defp word,
    do:
      let(
        chars <- non_empty(list(oneof(Enum.to_list(?a..?z) ++ ~c"0123456789"))),
        do: to_string(chars)
      )

  property "credentials never survive redaction" do
    forall {scheme, user, pass, host, path} <-
             {oneof(["https", "http", "ssh", "git"]), word(), word(), word(), word()} do
      url = "#{scheme}://#{user}:#{pass}@#{host}.com/#{path}.git"
      redacted = HalC2.ProjectClones.redact(url)

      redacted == "#{scheme}://#{host}.com/#{path}.git" and
        HalC2.ProjectClones.redact(redacted) == redacted
    end
  end

  property "an address without credentials is unchanged" do
    forall {host, path} <- {word(), word()} do
      url = "https://#{host}.com/#{path}"
      HalC2.ProjectClones.redact(url) == url
    end
  end
end
